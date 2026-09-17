import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var audio: AudioStreamer
    @EnvironmentObject private var camera: CameraStreamer

    @AppStorage("host") private var host: String = "192.168.1.10"
    @AppStorage("port") private var audioPortText: String = "50005"
    @AppStorage("videoPort") private var videoPortText: String = "50006"

    @AppStorage("sendAudio") private var sendAudio: Bool = true
    @AppStorage("gainDb") private var gainDb: Double = 6
    @AppStorage("micProcessing") private var micProcessing: Bool = true

    @AppStorage("sendVideo") private var sendVideo: Bool = false
    @AppStorage("cameraPosition") private var cameraPosition: CameraStreamer.Position = .back
    @AppStorage("cameraResolution") private var cameraResolution: CameraStreamer.Resolution = .hd720
    @AppStorage("jpegQuality") private var jpegQuality: Double = 0.6
    @AppStorage("mirrorFront") private var mirrorFront: Bool = false

    private var isActive: Bool { audio.isActive || camera.isActive }

    private var audioPort: UInt16? { UInt16(audioPortText.trimmingCharacters(in: .whitespaces)) }
    private var videoPort: UInt16? { UInt16(videoPortText.trimmingCharacters(in: .whitespaces)) }

    private var canStart: Bool {
        guard sendAudio || sendVideo else { return false }
        if sendAudio && audioPort == nil { return false }
        if sendVideo && videoPort == nil { return false }
        return true
    }

    var body: some View {
        NavigationView {
            Form {
                destinationSection
                audioSection
                cameraSection
                controlSection
            }
            .navigationTitle("MicSender")
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: applySettings)
        .onChange(of: gainDb) { _ in applySettings() }
        .onChange(of: micProcessing) { _ in applySettings() }
        .onChange(of: cameraPosition) { _ in applySettings() }
        .onChange(of: cameraResolution) { _ in applySettings() }
        .onChange(of: jpegQuality) { _ in applySettings() }
        .onChange(of: mirrorFront) { _ in applySettings() }
        .onChange(of: isActive) { active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
    }

    // MARK: - セクション

    private var destinationSection: some View {
        Section("送信先") {
            LabeledField(title: "IP アドレス", placeholder: "192.168.1.10", text: $host, keyboard: .decimalPad)
                .disabled(isActive)
            LabeledField(title: "音声ポート (UDP)", placeholder: "50005", text: $audioPortText, keyboard: .numberPad)
                .disabled(isActive)
            LabeledField(title: "映像ポート (TCP)", placeholder: "50006", text: $videoPortText, keyboard: .numberPad)
                .disabled(isActive)
        }
    }

    private var audioSection: some View {
        Section {
            Toggle("音声を送る", isOn: $sendAudio)
                .disabled(isActive)

            if sendAudio {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("ゲイン")
                        Spacer()
                        Text(gainLabel)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $gainDb, in: -12...24, step: 1)
                }
                Toggle("マイク処理を使う", isOn: $micProcessing)
                    .disabled(isActive)

                StatusRow(color: audioIndicatorColor, text: audioStatusText)
                LevelMeter(level: audio.level)
                    .frame(height: 16)
                ValueRow(title: "送信量", value: "\(audio.packetsSent) パケット / \(megabytes(audio.bytesSent))")
            }
        } header: {
            Text("音声")
        } footer: {
            if sendAudio {
                Text("ゲインは送信中でもすぐ反映される。マイク処理は iOS の自動音量調整とノイズ抑制で、切ると加工のない音になるかわりにかなり小さくなる。切り替えは次に送信を開始したときに効く。")
            }
        }
    }

    private var cameraSection: some View {
        Section {
            Toggle("映像を送る", isOn: $sendVideo)
                .disabled(isActive)

            if sendVideo {
                Picker("カメラ", selection: $cameraPosition) {
                    ForEach(CameraStreamer.Position.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)

                Picker("解像度", selection: $cameraResolution) {
                    ForEach(CameraStreamer.Resolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("画質")
                        Spacer()
                        Text(String(format: "%.0f%%", jpegQuality * 100))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $jpegQuality, in: 0.2...0.95, step: 0.05)
                }

                Toggle("内カメラを左右反転して送る", isOn: $mirrorFront)

                if camera.isActive {
                    CameraPreview(session: camera.session)
                        .aspectRatio(previewAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .listRowInsets(EdgeInsets())
                }

                StatusRow(color: cameraIndicatorColor, text: cameraStatusText)
                ValueRow(title: "フレーム", value: cameraFrameText)
                ValueRow(title: "送信量", value: megabytes(camera.bytesSent))
            }
        } header: {
            Text("カメラ")
        } footer: {
            if sendVideo {
                Text("カメラ・解像度・画質・反転は送信中でも切り替えられる。アプリを背面に回すと iOS の制限でカメラは止まり、前面に戻ると再開する。")
            }
        }
    }

    private var controlSection: some View {
        Section {
            Button(action: toggle) {
                HStack {
                    Spacer()
                    Text(isActive ? "停止" : "送信開始")
                        .bold()
                    Spacer()
                }
            }
            .disabled(!isActive && !canStart)
            .foregroundColor(isActive ? .red : .accentColor)
        } footer: {
            Text("音声は 48 kHz / モノラル / 16 bit PCM を UDP で、映像は JPEG を TCP で送る。PC 側で receiver.py と video_receiver.py を起動しておく。")
        }
    }

    // MARK: - 操作

    private func applySettings() {
        audio.gain = Float(pow(10, gainDb / 20))
        audio.useMicProcessing = micProcessing
        camera.position = cameraPosition
        camera.resolution = cameraResolution
        camera.jpegQuality = jpegQuality
        camera.mirrorFront = mirrorFront
    }

    private func toggle() {
        if isActive {
            audio.stop()
            camera.stop()
            return
        }
        applySettings()
        if sendAudio, let port = audioPort {
            audio.start(host: host, port: port)
        }
        if sendVideo, let port = videoPort {
            camera.start(host: host, port: port)
        }
    }

    // MARK: - 表示用

    private var gainLabel: String {
        let multiplier = pow(10, gainDb / 20)
        return String(format: "%+.0f dB (%.1f 倍)", gainDb, multiplier)
    }

    private var audioStatusText: String {
        switch audio.state {
        case .idle: return "停止中"
        case .connecting: return "接続中..."
        case .streaming: return "送信中"
        case .failed(let message): return message
        }
    }

    private var audioIndicatorColor: Color {
        switch audio.state {
        case .idle: return .gray
        case .connecting: return .orange
        case .streaming: return .green
        case .failed: return .red
        }
    }

    private var cameraStatusText: String {
        if camera.isInterrupted && camera.isActive {
            return "カメラが一時停止中"
        }
        switch camera.state {
        case .idle: return "停止中"
        case .waitingForReceiver: return "PC の受信待ち..."
        case .streaming: return "送信中"
        case .failed(let message): return message
        }
    }

    private var cameraIndicatorColor: Color {
        if camera.isInterrupted && camera.isActive { return .orange }
        switch camera.state {
        case .idle: return .gray
        case .waitingForReceiver: return .orange
        case .streaming: return .green
        case .failed: return .red
        }
    }

    private var cameraFrameText: String {
        guard camera.frameSize != .zero else { return "-" }
        return String(
            format: "%.0f x %.0f / %.1f fps",
            camera.frameSize.width, camera.frameSize.height, camera.framesPerSecond
        )
    }

    private var previewAspectRatio: CGFloat {
        let size = camera.frameSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - 部品

private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboard: UIKeyboardType

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
        }
    }
}

private struct StatusRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
            Spacer()
        }
    }
}

private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(level > 0.95 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
