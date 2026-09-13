import AVFoundation
import Combine
import Network

/// マイク入力を 48 kHz / モノラル / Int16 に変換して UDP で送り続ける。
final class AudioStreamer: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var packetsSent: UInt64 = 0
    @Published private(set) var bytesSent: UInt64 = 0

    /// 送信直前に掛ける倍率。送信中でも即座に反映される。
    @Published var gain: Float = 1.0 {
        didSet {
            let clamped = min(max(gain, 0.1), 16)
            stateLock.lock()
            gainValue = clamped
            stateLock.unlock()
        }
    }

    /// iOS 側のマイク処理 (自動ゲイン制御・ノイズ抑制) を使うかどうか。
    /// 切ると生の音がそのまま出るぶん小さくなる。切り替えは次回の開始時に効く。
    @Published var useMicProcessing: Bool = true

    var isActive: Bool {
        switch state {
        case .connecting, .streaming: return true
        case .idle, .failed: return false
        }
    }

    private let engine = AVAudioEngine()
    private let netQueue = DispatchQueue(label: "com.example.micsender.net")
    private let stateLock = NSLock()

    private var connection: NWConnection?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var pending = Data()
    private var sequence: UInt32 = 0
    private var tapInstalled = false
    private var gainValue: Float = 1.0

    // MARK: - 開始 / 停止

    func start(host: String, port: UInt16) {
        guard !isActive else { return }
        state = .connecting

        requestMicrophonePermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.state = .failed("マイクの使用が許可されていません。設定アプリから許可してください。")
                return
            }
            do {
                try self.beginStreaming(host: host, port: port)
            } catch {
                self.teardown()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        teardown()
        state = .idle
        level = 0
    }

    private func beginStreaming(host: String, port: UInt16) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw StreamError.invalidHost }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw StreamError.invalidPort }

        try configureAudioSession()

        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch newState {
                case .ready:
                    if self.isActive { self.state = .streaming }
                case .failed(let error):
                    self.teardown()
                    self.state = .failed("接続に失敗しました: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }

        stateLock.lock()
        self.connection = connection
        pending.removeAll(keepingCapacity: true)
        sequence = 0
        stateLock.unlock()

        packetsSent = 0
        bytesSent = 0

        connection.start(queue: netQueue)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw StreamError.noInput }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioPacket.sampleRate,
            channels: AVAudioChannelCount(AudioPacket.channels),
            interleaved: true
        ) else { throw StreamError.formatUnavailable }

        guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw StreamError.formatUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        stateLock.lock()
        self.outputFormat = outFormat
        self.converter = converter
        stateLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }

        stateLock.lock()
        let connection = self.connection
        self.connection = nil
        self.converter = nil
        self.outputFormat = nil
        pending.removeAll(keepingCapacity: false)
        stateLock.unlock()

        connection?.stateUpdateHandler = nil
        connection?.cancel()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - オーディオセッション

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .default は iOS のマイク処理が効いて実用的な音量になる。
        // .measurement は一切の加工がない代わりにかなり小さい。
        try session.setCategory(
            .playAndRecord,
            mode: useMicProcessing ? .default : .measurement,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(AudioPacket.sampleRate)
        // 5 ms を要求しておくとタップが細かく回り、送出の粒度が安定する。
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true, options: [])
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        let handler: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handler)
        }
    }

    // MARK: - 音声処理

    /// オーディオスレッドから呼ばれる。
    private func handle(buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let converter = self.converter
        let outFormat = self.outputFormat
        let gain = gainValue
        stateLock.unlock()

        guard let converter = converter, let outFormat = outFormat else { return }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let sampleCount = Int(out.frameLength) * Int(AudioPacket.channels)
        let pointer = channel[0]

        if gain != 1.0 {
            // 自前で作ったバッファなので、その場で書き換えてよい。
            for i in 0..<sampleCount {
                let amplified = Int32((Float(pointer[i]) * gain).rounded())
                pointer[i] = Int16(clamping: amplified)
            }
        }

        let samples = UnsafeBufferPointer(start: pointer, count: sampleCount)
        var peak: Int32 = 0
        for sample in samples {
            peak = max(peak, abs(Int32(sample)))
        }
        let chunk = Data(buffer: samples)

        flush(chunk: chunk, peak: Float(peak) / Float(Int16.max))
    }

    private func flush(chunk: Data, peak: Float) {
        let packetSize = AudioPacket.payloadSize
        var packets: [Data] = []

        stateLock.lock()
        pending.append(chunk)
        while pending.count >= packetSize {
            var packet = AudioPacket.header(sequence: sequence)
            packet.append(pending.prefix(packetSize))
            pending.removeFirst(packetSize)
            sequence &+= 1
            packets.append(packet)
        }
        let connection = self.connection
        stateLock.unlock()

        guard let connection = connection else { return }

        var bytes: UInt64 = 0
        for packet in packets {
            bytes += UInt64(packet.count)
            connection.send(content: packet, completion: .idempotent)
        }

        let count = UInt64(packets.count)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.packetsSent &+= count
            self.bytesSent &+= bytes
            // 目視しやすいよう、下降だけ緩やかにする。
            self.level = max(peak, self.level * 0.8)
        }
    }

    enum StreamError: LocalizedError {
        case invalidHost
        case invalidPort
        case noInput
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidHost: return "送信先 IP アドレスを入力してください。"
            case .invalidPort: return "ポート番号が不正です。"
            case .noInput: return "マイク入力を取得できませんでした。"
            case .formatUnavailable: return "音声フォーマットを構成できませんでした。"
            }
        }
    }
}
