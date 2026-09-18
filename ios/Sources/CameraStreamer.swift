import AVFoundation
import CoreImage
import ImageIO
import Network
import UIKit

/// カメラ映像を 1 フレームずつ JPEG にして TCP で送り続ける。
///
/// 前のフレームの送信が完了するまで次のフレームはエンコードせずに捨てるので、
/// 回線が細くなってもフレームレートが落ちるだけで遅延は溜まらない。
///
/// 状態はすべて `lock` で守り、どのキューから触ってもよい。
/// ただし NWConnection や AVCaptureSession の API は lock を持ったまま呼ばない。
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

    /// 不具合調査用に画面へ出す内部状態。
    struct Diagnostics: Equatable {
        var connection = "-"
        var attempts = 0
        var frameAge: Double?
        var sendAge: Double?
        var sendInFlight: Double?
        var droppedFrames = 0
        var lastDropReason: String?
        var captureRestarts = 0
        var reconnects = 0
        var sessionQueueLag: Double?
        var videoQueueLag: Double?
        var memoryMB: Double = 0
        var pressure = "-"
        var encodeInFlight: Double?
        var encoderResets = 0
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var framesSent: UInt64 = 0
    @Published private(set) var bytesSent: UInt64 = 0
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var isInterrupted = false
    /// iOS がカメラを止めた理由。止まっていなければ nil。
    @Published private(set) var interruptionReason: String?
    /// PC に繋がらないときの直近の理由。繋がったら nil に戻る。
    @Published private(set) var connectionIssue: String?
    @Published private(set) var diagnostics = Diagnostics()

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
    private let controlQueue = DispatchQueue(label: "com.example.micsender.camera.control")
    private let watchdogQueue = DispatchQueue(label: "com.example.micsender.camera.watchdog", qos: .utility)
    private let output = AVCaptureVideoDataOutput()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // JPEG 変換はカメラの処理から切り離して専用のキューで行う。
    // 変換が戻ってこなくなったら、監視がキューと CIContext ごと作り直す (lock で守る)。
    private var ciContext = CameraStreamer.makeContext()
    private var encodeQueue = CameraStreamer.makeEncodeQueue(generation: 0)
    private var encoderGeneration = 0
    private var encodeStartedAt: TimeInterval?
    private var encoderResets = 0

    // sessionQueue 専用
    private var currentInput: AVCaptureDeviceInput?
    private var outputAdded = false
    private var pressureObservation: NSKeyValueObservation?

    // main 専用
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var generatingOrientation = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?

    // ここから下は lock で守る
    private let lock = NSLock()
    private var running = false
    private var runToken = 0
    private var host = ""
    private var port: UInt16 = 0

    private var connection: NWConnection?
    /// 接続を作り直すたびに進める。古い接続からのコールバックを無視するのに使う。
    private var connectionID = 0
    private var connected = false
    private var connectStartedAt: TimeInterval?
    private var readyToSend = false
    private var sendStartedAt: TimeInterval?
    private var connectionText = "-"
    private var attempts = 0
    private var reconnects = 0

    private var qualityValue: CGFloat = 0.6
    private var flagsValue: UInt8 = 0
    private var frameNumber: UInt32 = 0

    private var totalFrames: UInt64 = 0
    private var totalBytes: UInt64 = 0
    private var lastFrameSize = CGSize.zero
    private var lastDeliveredAt: TimeInterval = 0
    private var lastSentAt: TimeInterval?
    private var droppedFrames = 0
    private var lastDropReason: String?
    private var captureRestarts = 0
    private var captureInterrupted = false
    private var sessionHeartbeat: TimeInterval = 0
    private var videoHeartbeat: TimeInterval = 0
    private var fpsSampleFrames: UInt64 = 0
    private var fpsSampleAt: TimeInterval = 0
    private var pressureText = "-"
    /// 発熱時に送るフレームの間隔を空けて、iOS にカメラを止められるのを防ぐ。
    private var minFrameInterval: TimeInterval = 0
    private var lastEncodeAt: TimeInterval = 0

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
        ) { [weak self] notification in
            let code = notification.userInfo?["AVCaptureSessionInterruptionReasonKey"] as? Int
            self?.setInterrupted(true, reason: Self.describeInterruption(code))
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("AVCaptureSessionInterruptionEndedNotification"), object: session, queue: .main
        ) { [weak self] _ in
            self?.setInterrupted(false, reason: nil)
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("AVCaptureSessionRuntimeErrorNotification"), object: session, queue: .main
        ) { [weak self] _ in
            self?.restartCapture()
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

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func makeContext() -> CIContext {
        CIContext(options: [.cacheIntermediates: false])
    }

    private static func makeEncodeQueue(generation: Int) -> DispatchQueue {
        DispatchQueue(label: "com.example.micsender.camera.encode.\(generation)", qos: .userInitiated)
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
        connectionIssue = nil
        diagnostics = Diagnostics()

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
        runToken += 1
        let oldConnection = connection
        connection = nil
        connectionID += 1
        connected = false
        readyToSend = false
        sendStartedAt = nil
        connectStartedAt = nil
        connectionText = "停止"
        lock.unlock()

        oldConnection?.stateUpdateHandler = nil
        oldConnection?.forceCancel()

        watchdog?.cancel()
        watchdog = nil

        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }

        if generatingOrientation {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            generatingOrientation = false
        }

        state = .idle
        framesPerSecond = 0
        isInterrupted = false
        interruptionReason = nil
        connectionIssue = nil
    }

    private func beginCapture(host: String, port: UInt16) {
        if !generatingOrientation {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            generatingOrientation = true
        }
        orientation = currentInterfaceOrientation() ?? orientation
        deviceOrientationChanged()

        let now = Self.now()
        lock.lock()
        running = true
        runToken += 1
        self.host = host
        self.port = port
        readyToSend = false
        frameNumber = 0
        totalFrames = 0
        totalBytes = 0
        lastFrameSize = .zero
        lastDeliveredAt = now
        lastSentAt = nil
        droppedFrames = 0
        lastDropReason = nil
        captureRestarts = 0
        attempts = 0
        reconnects = 0
        sessionHeartbeat = now
        videoHeartbeat = now
        fpsSampleFrames = 0
        fpsSampleAt = now
        encodeStartedAt = nil
        encoderResets = 0
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

        startWatchdog()
        controlQueue.async { self.connect() }
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

            pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                self?.updatePressure(device.systemPressureState.level)
            }
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

    private static func describeInterruption(_ code: Int?) -> String {
        // AVCaptureSession.InterruptionReason の値。
        switch code {
        case 1: return "アプリがバックグラウンドにあるため iOS がカメラを止めた"
        case 2: return "マイクを他のアプリが使っているため iOS がカメラを止めた"
        case 3: return "カメラを他のアプリが使っているため iOS がカメラを止めた"
        case 4: return "複数のアプリが前面にあるため iOS がカメラを止めた"
        case 5: return "発熱などでシステムの負荷が高いため iOS がカメラを止めた。しばらく冷ますか解像度を下げる"
        case let code?: return "iOS がカメラを止めた (理由コード \(code))"
        case nil: return "iOS がカメラを止めた (理由不明)"
        }
    }

    private func setInterrupted(_ interrupted: Bool, reason: String?) {
        isInterrupted = interrupted
        interruptionReason = reason
        lock.lock()
        captureInterrupted = interrupted
        // 中断が明けた直後にフレーム停止と誤判定しないよう、基準時刻を進める。
        lastDeliveredAt = Self.now()
        lock.unlock()
    }

    /// 発熱が進むと iOS はカメラを止める。その手前で送るフレームを減らして負荷を下げる。
    private func updatePressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
        let text: String
        let interval: TimeInterval
        switch level {
        case .nominal:
            text = "正常"
            interval = 0
        case .fair:
            text = "やや高い"
            interval = 0
        case .serious:
            text = "高い (15 fps に制限中)"
            interval = 1.0 / 15
        case .critical:
            text = "非常に高い (10 fps に制限中)"
            interval = 1.0 / 10
        case .shutdown:
            text = "限界 (iOS がカメラを止める)"
            interval = 1.0 / 10
        default:
            text = level.rawValue
            interval = 0
        }
        lock.lock()
        pressureText = text
        minFrameInterval = interval
        lock.unlock()
    }

    /// フレームが届かなくなったときや実行時エラーのときに、キャプチャを止めて起動し直す。
    private func restartCapture() {
        lock.lock()
        let shouldRun = running
        if shouldRun {
            captureRestarts += 1
            lastDeliveredAt = Self.now()
        }
        lock.unlock()
        guard shouldRun else { return }

        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
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

    // MARK: - ネットワーク

    private func connect() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        // PC 側が黙って消えたときにも数秒で気付けるようにする。
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3

        lock.lock()
        guard running, let nwPort = NWEndpoint.Port(rawValue: port) else {
            lock.unlock()
            return
        }
        let newConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        let oldConnection = connection
        connectionID += 1
        let id = connectionID
        connection = newConnection
        connected = false
        readyToSend = false
        sendStartedAt = nil
        connectStartedAt = Self.now()
        attempts += 1
        connectionText = "接続中 (\(attempts) 回目)"
        lock.unlock()

        oldConnection?.stateUpdateHandler = nil
        oldConnection?.forceCancel()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.lock.lock()
                guard self.connectionID == id else {
                    self.lock.unlock()
                    return
                }
                self.connected = true
                self.readyToSend = self.running
                self.connectStartedAt = nil
                self.connectionText = "接続済み"
                self.lock.unlock()

                DispatchQueue.main.async {
                    self.connectionIssue = nil
                    if self.isActive { self.state = .streaming }
                }
                if let newConnection = newConnection {
                    self.watchForClose(newConnection, id: id)
                }
            case .waiting(let error), .failed(let error):
                let reason = Self.describe(error, path: newConnection?.currentPath)
                self.drop(id: id, reason: reason)
            case .preparing:
                self.setConnectionText("接続処理中", id: id)
            default:
                break
            }
        }
        // 接続ごとに専用のキューを使い、前の接続の後始末が新しい接続を妨げないようにする。
        newConnection.start(queue: DispatchQueue(label: "com.example.micsender.camera.connection.\(id)"))
    }

    private func setConnectionText(_ text: String, id: Int) {
        lock.lock()
        if connectionID == id { connectionText = text }
        lock.unlock()
    }

    /// PC からデータは来ないが、受信待ちにしておくと PC 側が閉じたことにすぐ気付ける。
    private func watchForClose(_ connection: NWConnection, id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] _, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.drop(id: id, reason: Self.describe(error, path: nil))
            } else if isComplete {
                self.drop(id: id, reason: "PC 側で接続が閉じられた。受信スクリプトが終了したかもしれない")
            } else if let connection = connection {
                self.watchForClose(connection, id: id)
            }
        }
    }

    /// 接続を捨て、動作中なら 1 秒後に繋ぎ直す。
    private func drop(id: Int, reason: String) {
        lock.lock()
        guard connectionID == id else {
            lock.unlock()
            return
        }
        let oldConnection = connection
        connection = nil
        connectionID += 1
        connected = false
        readyToSend = false
        sendStartedAt = nil
        connectStartedAt = nil
        connectionText = "再接続待ち"
        reconnects += 1
        let shouldRun = running
        let token = runToken
        lock.unlock()

        oldConnection?.stateUpdateHandler = nil
        oldConnection?.forceCancel()

        guard shouldRun else { return }
        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.state = .waitingForReceiver
            self.connectionIssue = reason
        }
        controlQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let stillWanted = self.running && self.runToken == token && self.connection == nil
            self.lock.unlock()
            if stillWanted { self.connect() }
        }
    }

    /// バックグラウンドから戻った直後は接続が壊れていることがあるので、待たずに作り直す。
    private func reconnectNowIfWaiting() {
        guard state == .waitingForReceiver else { return }
        controlQueue.async {
            self.lock.lock()
            let needed = self.running && !self.connected
            self.lock.unlock()
            if needed { self.connect() }
        }
    }

    private func send(_ packet: Data, width: Int, height: Int) {
        lock.lock()
        guard connected, let connection = connection else {
            // 接続し直したときに .ready で送信可能に戻る。
            lock.unlock()
            return
        }
        let id = connectionID
        sendStartedAt = Self.now()
        lock.unlock()

        let size = packet.count
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.drop(id: id, reason: Self.describe(error, path: nil))
                return
            }
            self.lock.lock()
            if self.connectionID == id {
                self.sendStartedAt = nil
                self.readyToSend = self.running
                self.totalFrames &+= 1
                self.totalBytes &+= UInt64(size)
                self.lastFrameSize = CGSize(width: width, height: height)
                self.lastSentAt = Self.now()
            }
            self.lock.unlock()
        })
    }

    private func markReadyIfConnected() {
        lock.lock()
        if connected { readyToSend = running }
        lock.unlock()
    }

    // MARK: - 監視

    /// 1 秒ごとに、止まっている箇所がないかを調べて自動で立て直し、画面用の数値をまとめて出す。
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        let now = Self.now()

        // 各キューが応答しているかを測る。固まっていれば値が伸び続ける。
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.sessionHeartbeat = Self.now()
            self.lock.unlock()
        }
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.videoHeartbeat = Self.now()
            self.lock.unlock()
        }

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }

        var stalledConnection: (id: Int, reason: String)?
        if connection != nil, !connected, let startedAt = connectStartedAt, now - startedAt > 6 {
            stalledConnection = (connectionID, "PC への接続が 6 秒たっても終わらないため接続し直しています")
        } else if connected, let startedAt = sendStartedAt, now - startedAt > 5 {
            stalledConnection = (connectionID, "PC への送信が 5 秒止まったため接続し直しています")
        }

        let captureStalled = !captureInterrupted && now - lastDeliveredAt > 4

        // JPEG 変換が 3 秒戻らなければ、キューと CIContext を新しくして次のフレームから再開する。
        if let startedAt = encodeStartedAt, now - startedAt > 3 {
            encoderGeneration += 1
            encodeQueue = Self.makeEncodeQueue(generation: encoderGeneration)
            ciContext = Self.makeContext()
            encodeStartedAt = nil
            encoderResets += 1
            if connected { readyToSend = true }
        }

        var fps: Double?
        if now - fpsSampleAt >= 1 {
            fps = Double(totalFrames - fpsSampleFrames) / (now - fpsSampleAt)
            fpsSampleFrames = totalFrames
            fpsSampleAt = now
        }

        let snapshot = Diagnostics(
            connection: connectionText,
            attempts: attempts,
            frameAge: now - lastDeliveredAt,
            sendAge: lastSentAt.map { now - $0 },
            sendInFlight: sendStartedAt.map { now - $0 },
            droppedFrames: droppedFrames,
            lastDropReason: lastDropReason,
            captureRestarts: captureRestarts,
            reconnects: reconnects,
            sessionQueueLag: now - sessionHeartbeat,
            videoQueueLag: now - videoHeartbeat,
            memoryMB: Self.memoryFootprintMB(),
            pressure: pressureText,
            encodeInFlight: encodeStartedAt.map { now - $0 },
            encoderResets: encoderResets
        )
        let frames = totalFrames
        let bytes = totalBytes
        let size = lastFrameSize
        lock.unlock()

        if let stalled = stalledConnection {
            drop(id: stalled.id, reason: stalled.reason)
        }
        if captureStalled {
            restartCapture()
        }

        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.framesSent = frames
            self.bytesSent = bytes
            if self.frameSize != size { self.frameSize = size }
            if let fps = fps { self.framesPerSecond = fps }
            if self.diagnostics != snapshot { self.diagnostics = snapshot }
        }
    }

    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
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
            case .ECANCELED:
                return "接続を作り直しています"
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
        let now = Self.now()
        lock.lock()
        lastDeliveredAt = now
        var shouldSend = running && connected && readyToSend
        if shouldSend, minFrameInterval > 0, now - lastEncodeAt < minFrameInterval {
            shouldSend = false
        }
        if shouldSend {
            readyToSend = false
            frameNumber &+= 1
            lastEncodeAt = now
            encodeStartedAt = now
        }
        let quality = qualityValue
        let flags = flagsValue
        let number = frameNumber
        let queue = encodeQueue
        let context = ciContext
        let generation = encoderGeneration
        lock.unlock()

        guard shouldSend else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            finishEncode(generation: generation, packet: nil, width: 0, height: 0)
            return
        }

        // カメラの処理はここで返し、変換は専用キューに任せる。
        // 変換が固まってもカメラは止まらず、監視が変換器を作り直せる。
        queue.async { [weak self] in
            guard let self = self else { return }
            // 1 フレームごとに一時オブジェクトを確実に解放する。
            autoreleasepool {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
                ]
                let packet = context.jpegRepresentation(of: image, colorSpace: self.colorSpace, options: options)
                    .map { VideoPacket.make(jpeg: $0, width: width, height: height, frameNumber: number, flags: flags) }
                self.finishEncode(generation: generation, packet: packet, width: width, height: height)
            }
        }
    }

    private func finishEncode(generation: Int, packet: Data?, width: Int, height: Int) {
        lock.lock()
        // 監視が変換器を作り直した後に古い変換が戻ってきた場合は捨てる。
        let current = generation == encoderGeneration
        if current { encodeStartedAt = nil }
        lock.unlock()
        guard current else { return }

        if let packet = packet {
            send(packet, width: width, height: height)
        } else {
            markReadyIfConnected()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let reason = CMGetAttachment(
            sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil
        ) as? String

        lock.lock()
        droppedFrames += 1
        if let reason = reason { lastDropReason = reason }
        lock.unlock()
    }
}
