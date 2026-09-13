import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var streamer: AudioStreamer

    @AppStorage("host") private var host: String = "192.168.1.10"
    @AppStorage("port") private var portText: String = "50005"
    @AppStorage("gainDb") private var gainDb: Double = 6
    @AppStorage("micProcessing") private var micProcessing: Bool = true

    private var port: UInt16? { UInt16(portText.trimmingCharacters(in: .whitespaces)) }

    private var gainLabel: String {
        let multiplier = pow(10, gainDb / 20)
        return String(format: "%+.0f dB (%.1f 倍)", gainDb, multiplier)
    }

    private func applyInputSettings() {
        streamer.gain = Float(pow(10, gainDb / 20))
        streamer.useMicProcessing = micProcessing
    }

    var body: some View {
        NavigationView {
            Form {
                Section("送信先") {
                    HStack {
                        Text("IP アドレス")
                        Spacer()
                        TextField("192.168.1.10", text: $host)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .disabled(streamer.isActive)
                    }
                    HStack {
                        Text("ポート")
                        Spacer()
                        TextField("50005", text: $portText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .disabled(streamer.isActive)
                    }
                }

                Section {
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
                        .disabled(streamer.isActive)
                } header: {
                    Text("入力")
                } footer: {
                    Text("ゲインは送信中でもすぐ反映される。マイク処理は iOS の自動音量調整とノイズ抑制で、切ると加工のない音になるかわりにかなり小さくなる。切り替えは次に送信を開始したときに効く。")
                }

                Section("状態") {
                    HStack {
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: 10, height: 10)
                        Text(statusText)
                        Spacer()
                    }
                    LevelMeter(level: streamer.level)
                        .frame(height: 16)
                    HStack {
                        Text("送信パケット")
                        Spacer()
                        Text("\(streamer.packetsSent)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("送信量")
                        Spacer()
                        Text(formattedBytes)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Section {
                    Button(action: toggle) {
                        HStack {
                            Spacer()
                            Text(streamer.isActive ? "停止" : "送信開始")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(!streamer.isActive && port == nil)
                    .foregroundColor(streamer.isActive ? .red : .accentColor)
                } footer: {
                    Text("48 kHz / モノラル / 16 bit PCM を 10 ms ごとに UDP で送信します。PC 側で receiver.py を先に起動してください。")
                }
            }
            .navigationTitle("MicSender")
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: applyInputSettings)
        .onChange(of: gainDb) { _ in applyInputSettings() }
        .onChange(of: micProcessing) { _ in applyInputSettings() }
        .onChange(of: streamer.isActive) { active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
    }

    private func toggle() {
        if streamer.isActive {
            streamer.stop()
        } else if let port = port {
            streamer.start(host: host, port: port)
        }
    }

    private var statusText: String {
        switch streamer.state {
        case .idle: return "停止中"
        case .connecting: return "接続中..."
        case .streaming: return "送信中"
        case .failed(let message): return message
        }
    }

    private var indicatorColor: Color {
        switch streamer.state {
        case .idle: return .gray
        case .connecting: return .orange
        case .streaming: return .green
        case .failed: return .red
        }
    }

    private var formattedBytes: String {
        let mb = Double(streamer.bytesSent) / 1_048_576
        return String(format: "%.2f MB", mb)
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
