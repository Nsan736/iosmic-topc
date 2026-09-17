import AVFoundation
import CoreImage
import ImageIO
import Network
import UIKit

/// カメラ映像を 1 フレームずつ JPEG にして TCP で送り続ける。
///
/// 前のフレームの送信が完了するまで次のフレームはエンコードせずに捨てるので、
/// 回線が細くなってもフレームレートが落ちるだけで遅延は溜まらない。
final class CameraStreamer: NSObject, ObservableObject {
    enum Position: String, CaseIterable, Identifiable {
        case front
        case back

        var id: String { rawValue }

        var label: String {
            switch self {
            case .front: return "内カメラ"
            case .back: return "外カメラ"
            }
        }

        var capturePosition: AVCaptureDevice.Position {
            switch self {
            case .front: return .front
            case .back: return .back
            }
        }
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case sd480
        case hd720
        case hd1080

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sd480: return "480p"
            case .hd720: return "720p"
            case .hd1080: return "1080p"
            }
        }

        var preset: AVCaptureSession.Preset {
            switch self {
            case .sd480: return .vga640x480
            case .hd720: return .hd1280x720
            case .hd1080: return .hd1920x1080
            }
        }
    }

    enum State: Equatable {
        case idle
        case waitingForReceiver
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var framesSent: UInt64 = 0
    @Published private(set) var bytesSent: UInt64 = 0
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var isInterrupted = false
    /// PC に繋がらないときの直近の理由。繋がったら nil に戻る。
    @Published private(set) var connectionIssue: String?

    /// 以下の設定は送信中に変えてもそのまま反映される。
    @Published var position: Position = .back {
        didSet { if position != oldValue { reconfigure() } }
    }

    @Published var resolution: Resolution = .hd720 {
        didSet { if resolution != oldValue { reconfigure() } }
    }

    @Published var mirrorFront: Bool = false {
        didSet { if mirrorFront != oldValue { reconfigure() } }
    }

    /// JPEG の画質。0.1 から 1.0。
    @Published var jpegQuality: Double = 0.6 {
        didSet {
            let clamped = CGFloat(min(max(jpegQuality, 0.1), 1.0))
            lock.lock()
            qualityValue = clamped
            lock.unlock()
        }
    }

    var isActive: Bool {
        switch state {
        case .waitingForReceiver, .streaming: return true
        case .idle, .failed: return false
        }
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.example.micsender.camera.session")
    private let videoQueue = DispatchQueue(label: "com.example.micsender.camera.video", qos: .userInitiated)
    private let netQueue = DispatchQueue(label: "com.example.micsender.camera.net")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // sessionQueue 専用
    private var currentInput: AVCaptureDeviceInput?
    private var outputAdded = false

    // netQueue 専用
    private var connection: NWConnection?
    private var connected = false
    private var generation = 0
    private var host = ""
    private var port: UInt16 = 0
    private var fpsWindowStart = Date()
    private var fpsWindowFrames = 0
    private var sendStartedAt: Date?
    private var watchdog: DispatchSourceTimer?
    /// 開始と停止のたびに進める。前の回に予約した再接続が新しい回に紛れ込まないようにする。
    private var runToken = 0

    // videoQueue と他のキューで共有するので lock で守る
    private let lock = NSLock()
    private var running = false
    private var readyToSend = false
    private var qualityValue: CGFloat = 0.6
    private var flagsValue: UInt8 = 0
    private var frameNumber: UInt32 = 0

    // main 専用
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var generatingOrientation = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.deviceOrientationChanged()
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("AVCaptureSessionWasInterruptedNotification"), object: session, queue: .main
        ) { [weak self] _ in
            self?.isInterrupted = true
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("AVCaptureSessionInterruptionEndedNotification"), object: session, queue: .main
        ) { [weak self] _ in
            self?.isInterrupted = false
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("AVCaptureSessionRuntimeErrorNotification"), object: session, queue: .main
        ) { [weak self] _ in
            self?.restartSessionIfNeeded()
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reconnectNowIfWaiting()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 開始 / 停止

    func start(host: String, port: UInt16) {
        guard !isActive else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0 else {
            state = .failed("送信先の IP アドレスとポートを確認してください。")
            return
        }

        state = .waitingForReceiver
        framesSent = 0
        bytesSent = 0
        framesPerSecond = 0
        frameSize = .zero

        requestPermission { [weak self] granted in
            guard let self = self, self.state == .waitingForReceiver else { return }
            guard granted else {
                self.state = .failed("カメラの使用が許可されていません。設定アプリから許可してください。")
                return
            }
            self.beginCapture(host: trimmedHost, port: port)
        }
    }

    func stop() {
        lock.lock()
        running = false
        readyToSend = false
        lock.unlock()

        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        netQueue.async {
            self.runToken += 1
            self.watchdog?.cancel()
            self.watchdog = nil
            self.generation += 1
            self.connected = false
            self.sendStartedAt = nil
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }

        if generatingOrientation {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            generatingOrientation = false
        }

        state = .idle
        framesPerSecond = 0
        isInterrupted = false
        connectionIssue = nil
    }

    private func beginCapture(host: String, port: UInt16) {
        if !generatingOrientation {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            generatingOrientation = true
        }
        orientation = currentInterfaceOrientation() ?? orientation
        deviceOrientationChanged()

        lock.lock()
        running = true
        readyToSend = false
        frameNumber = 0
        lock.unlock()

        let settings = currentSettings()
        sessionQueue.async {
            do {
                try self.apply(settings)
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                DispatchQueue.main.async {
                    self.stop()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }

        netQueue.async {
            self.host = host
            self.port = port
            self.fpsWindowStart = Date()
            self.fpsWindowFrames = 0
            self.runToken += 1
            self.startWatchdog()
            self.connect()
        }
    }

    // MARK: - キャプチャ構成

    private struct CaptureSettings {
        let position: Position
        let resolution: Resolution
        let mirrorFront: Bool
        let orientation: AVCaptureVideoOrientation
    }

    private func currentSettings() -> CaptureSettings {
        CaptureSettings(
            position: position,
            resolution: resolution,
            mirrorFront: mirrorFront,
            orientation: orientation
        )
    }

    private func reconfigure() {
        guard isActive else { return }
        let settings = currentSettings()
        sessionQueue.async {
            do {
                try self.apply(settings)
            } catch {
                DispatchQueue.main.async {
                    self.stop()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// sessionQueue から呼ぶ。
    private func apply(_ settings: CaptureSettings) throws {
        guard let device = Self.device(for: settings.position.capturePosition) else {
            throw CameraError.deviceUnavailable
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if currentInput?.device.uniqueID != device.uniqueID {
            let input = try AVCaptureDeviceInput(device: device)
            // 新しいカメラが今のプリセットに対応していないと追加できないため、いったん汎用プリセットに戻す。
            session.sessionPreset = .high
            let previous = currentInput
            if let previous = previous { session.removeInput(previous) }
            guard session.canAddInput(input) else {
                if let previous = previous, session.canAddInput(previous) { session.addInput(previous) }
                throw CameraError.configurationFailed
            }
            session.addInput(input)
            currentInput = input
        }

        if !outputAdded {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
            outputAdded = true

            // Split View や Stage Manager で他のアプリと並べてもカメラを止めない。
            if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
            }
        }

        let preset = settings.resolution.preset
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = settings.orientation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = settings.position == .front && settings.mirrorFront
            }
        }

        lock.lock()
        flagsValue = settings.position == .front ? VideoPacket.flagFrontCamera : 0
        lock.unlock()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iPad の内カメラは機種によって超広角として見えるので、候補を順に探す。
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTrueDepthCamera,
        ]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: position
        ).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return nil
    }

    /// バックグラウンドから戻った直後は接続が壊れていることがあるので、待たずに作り直す。
    private func reconnectNowIfWaiting() {
        guard state == .waitingForReceiver else { return }
        netQueue.async {
            guard !self.connected else { return }
            self.connect()
        }
    }

    private func restartSessionIfNeeded() {
        guard isActive else { return }
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - 向き

    private func deviceOrientationChanged() {
        let newOrientation: AVCaptureVideoOrientation
        switch UIDevice.current.orientation {
        case .portrait: newOrientation = .portrait
        case .portraitUpsideDown: newOrientation = .portraitUpsideDown
        // デバイスの向きと映像の向きは左右の定義が逆になる。
        case .landscapeLeft: newOrientation = .landscapeRight
        case .landscapeRight: newOrientation = .landscapeLeft
        default: return
        }
        guard newOrientation != orientation else { return }
        orientation = newOrientation

        guard isActive else { return }
        sessionQueue.async {
            guard let connection = self.output.connection(with: .video),
                  connection.isVideoOrientationSupported else { return }
            connection.videoOrientation = newOrientation
        }
    }

    private func currentInterfaceOrientation() -> AVCaptureVideoOrientation? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        switch scene?.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }

    // MARK: - ネットワーク (netQueue)

    private func connect() {
        lock.lock()
        let shouldRun = running
        lock.unlock()
        guard shouldRun, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connected = false

        generation += 1
        let myGeneration = generation

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self = self, self.generation == myGeneration else { return }
            switch newState {
            case .ready:
                self.connected = true
                self.sendStartedAt = nil
                self.lock.lock()
                self.readyToSend = self.running
                self.lock.unlock()
                DispatchQueue.main.async {
                    self.connectionIssue = nil
                    if self.isActive { self.state = .streaming }
                }
            case .waiting(let error), .failed(let error):
                let reason = Self.describe(error, path: connection?.currentPath)
                self.dropConnectionAndRetry(reason: reason)
            default:
                break
            }
        }
        connection.start(queue: netQueue)
    }

    /// 受信側が落ちていても 1 秒ごとに繋ぎ直す。
    private func dropConnectionAndRetry(reason: String) {
        lock.lock()
        readyToSend = false
        let shouldRun = running
        lock.unlock()

        generation += 1
        connected = false
        sendStartedAt = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        guard shouldRun else { return }
        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.state = .waitingForReceiver
            self.connectionIssue = reason
        }
        let token = runToken
        netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.runToken == token else { return }
            self.connect()
        }
    }

    private func send(_ packet: Data, width: Int, height: Int) {
        guard connected, let connection = connection else { return }
        let myGeneration = generation
        sendStartedAt = Date()

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.generation == myGeneration else { return }
            self.sendStartedAt = nil
            if let error = error {
                self.dropConnectionAndRetry(reason: Self.describe(error, path: nil))
                return
            }
            self.lock.lock()
            self.readyToSend = self.running
            self.lock.unlock()
            self.recordSent(bytes: packet.count, width: width, height: height)
        })
    }

    /// Wi-Fi が一瞬切れると、TCP はエラーを返さないまま送信だけが止まることがある。
    /// 1 フレームの送信が 5 秒終わらなければ、切れたとみなして繋ぎ直す。
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.connected,
                  let startedAt = self.sendStartedAt,
                  Date().timeIntervalSince(startedAt) > 5 else { return }
            self.dropConnectionAndRetry(reason: "PC への送信が止まったため接続し直しています")
        }
        watchdog = timer
        timer.resume()
    }

    private static func describe(_ error: NWError, path: NWPath?) -> String {
        if #available(iOS 14.2, *), path?.unsatisfiedReason == .localNetworkDenied {
            return localNetworkDeniedMessage
        }
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return "PC に届いたが拒否された。PC 側で video_receiver.py が起動しているか確認"
            case .ETIMEDOUT:
                return "PC から応答がない。IP アドレス、Wi-Fi、PC のファイアウォールを確認"
            case .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN:
                return "PC に到達できない。iPad と PC が同じ Wi-Fi に繋がっているか確認"
            case .ECONNRESET, .EPIPE, .ECONNABORTED:
                return "PC 側で接続が切られた。受信スクリプトが再起動されたかもしれない"
            default:
                return "接続エラー (POSIX \(code.rawValue))"
            }
        case .dns(let code) where Int(code) == -65570:
            // kDNSServiceErr_PolicyDenied。ローカルネットワークの許可がないと返る。
            return localNetworkDeniedMessage
        default:
            return "接続エラー: \(error.localizedDescription)"
        }
    }

    private static let localNetworkDeniedMessage =
        "ローカルネットワークへのアクセスが許可されていない。設定アプリ → プライバシーとセキュリティ → ローカルネットワークで LiveContainer を許可"

    private func markReadyIfConnected() {
        netQueue.async {
            guard self.connected else { return }
            self.lock.lock()
            self.readyToSend = self.running
            self.lock.unlock()
        }
    }

    private func recordSent(bytes: Int, width: Int, height: Int) {
        fpsWindowFrames += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        var fps: Double?
        if elapsed >= 1 {
            fps = Double(fpsWindowFrames) / elapsed
            fpsWindowFrames = 0
            fpsWindowStart = now
        }

        let size = CGSize(width: width, height: height)
        DispatchQueue.main.async {
            self.framesSent &+= 1
            self.bytesSent &+= UInt64(bytes)
            if self.frameSize != size { self.frameSize = size }
            if let fps = fps { self.framesPerSecond = fps }
        }
    }

    enum CameraError: LocalizedError {
        case deviceUnavailable
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "選択したカメラが見つかりません。"
            case .configurationFailed: return "カメラを構成できませんでした。"
            }
        }
    }
}

extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let shouldSend = running && readyToSend
        if shouldSend {
            readyToSend = false
            frameNumber &+= 1
        }
        let quality = qualityValue
        let flags = flagsValue
        let number = frameNumber
        lock.unlock()

        guard shouldSend else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            markReadyIfConnected()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            markReadyIfConnected()
            return
        }

        let packet = VideoPacket.make(
            jpeg: jpeg, width: width, height: height, frameNumber: number, flags: flags
        )
        netQueue.async {
            self.send(packet, width: width, height: height)
        }
    }
}
