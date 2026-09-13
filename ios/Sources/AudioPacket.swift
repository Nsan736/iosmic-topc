import Foundation

/// iPad と Windows 受信側で共有するパケット仕様。
///
/// レイアウト (リトルエンディアン、ヘッダ 16 バイト固定):
///   0..3   magic 'I' 'M' 'I' 'C'
///   4      version = 1
///   5      channels
///   6..7   frames per packet (サンプル数 / チャンネル)
///   8..11  sample rate (Hz)
///   12..15 sequence number
///   16..   Int16 リニア PCM
enum AudioPacket {
    static let magic: [UInt8] = [0x49, 0x4D, 0x49, 0x43]
    static let version: UInt8 = 1
    static let headerSize = 16

    static let sampleRate: Double = 48_000
    static let channels: UInt8 = 1
    /// 10 ms 分。48 kHz モノラルで 960 バイト、MTU に余裕で収まる。
    static let framesPerPacket = 480

    static var payloadSize: Int { framesPerPacket * Int(channels) * MemoryLayout<Int16>.size }

    static func header(sequence: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        data.append(contentsOf: magic)
        data.append(version)
        data.append(channels)
        withUnsafeBytes(of: UInt16(framesPerPacket).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}
