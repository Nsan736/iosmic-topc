import Foundation

/// 映像フレームの TCP 送信用ヘッダ。1 フレーム = ヘッダ + JPEG 本体。
///
/// レイアウト (リトルエンディアン、ヘッダ 20 バイト固定):
///   0..3   magic 'I' 'V' 'I' 'D'
///   4      version = 1
///   5      flags (bit0: 内カメラ)
///   6..7   width
///   8..9   height
///   10..11 reserved (0)
///   12..15 JPEG のバイト数
///   16..19 frame number
enum VideoPacket {
    static let magic: [UInt8] = [0x49, 0x56, 0x49, 0x44]
    static let version: UInt8 = 1
    static let headerSize = 20

    static let flagFrontCamera: UInt8 = 0x01

    static func make(jpeg: Data, width: Int, height: Int, frameNumber: UInt32, flags: UInt8) -> Data {
        var data = Data(capacity: headerSize + jpeg.count)
        data.append(contentsOf: magic)
        data.append(version)
        data.append(flags)
        withUnsafeBytes(of: UInt16(clamping: width).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: height).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(0).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(jpeg.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        data.append(jpeg)
        return data
    }
}
