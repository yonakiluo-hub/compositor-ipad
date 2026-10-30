// PSD channel layout and PackBits decoding adapted from Compositor PSDChannelCoder.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
// Adobe Photoshop File Formats Specification, November 2019. Bounded cursors and strict lengths are iPad adaptations.
import Foundation

enum PSDFileError: LocalizedError, Equatable {
    case invalid(String), unsupported(String), tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "PSD 文件无效：\(detail)。原文件未修改。"
        case .unsupported(let detail): "暂不支持此 PSD 内容：\(detail)。请保留原工程，导出支持的 8 位 RGB 栅格副本。"
        case .tooLarge: "PSD 超出当前安全限制：单边 4096、画布 1600 万像素、图层和蒙版总计 3200 万样本、1024 个记录或 256 MiB 文件。"
        }
    }
}

struct PSDReadCursor {
    let data: Data
    var offset: Int = 0
    let end: Int
    init(_ data: Data) { self.data = data; end = data.count }
    private init(data: Data, offset: Int, end: Int) { self.data = data; self.offset = offset; self.end = end }
    var remaining: Int { end - offset }
    mutating func take(_ count: Int) throws -> PSDReadCursor {
        try need(count)
        defer { offset += count }
        return PSDReadCursor(data: data, offset: offset, end: offset + count)
    }
    func need(_ count: Int) throws {
        guard count >= 0, offset >= 0, offset <= end, count <= end - offset else { throw PSDFileError.invalid("区段或通道长度越界") }
    }
    mutating func bytes(_ count: Int) throws -> Data {
        try need(count); defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }
    mutating func skip(_ count: Int) throws { try need(count); offset += count }
    mutating func u8() throws -> UInt8 { try need(1); defer { offset += 1 }; return data[data.startIndex + offset] }
    mutating func u16() throws -> UInt16 { let a = try u8(), b = try u8(); return UInt16(a) << 8 | UInt16(b) }
    mutating func i16() throws -> Int { Int(Int16(bitPattern: try u16())) }
    mutating func u32() throws -> UInt32 { let a = try u16(), b = try u16(); return UInt32(a) << 16 | UInt32(b) }
    mutating func i32() throws -> Int { Int(Int32(bitPattern: try u32())) }
    mutating func ascii(_ count: Int) throws -> String {
        let value = try bytes(count)
        guard let string = String(data: value, encoding: .ascii) else { throw PSDFileError.invalid("签名不是 ASCII") }
        return string
    }
    mutating func finish(allowZeroPadding maximum: Int = 0) throws {
        guard remaining <= maximum else { throw PSDFileError.invalid("区段存在未解释的内容") }
        guard try bytes(remaining).allSatisfy({ $0 == 0 }) else { throw PSDFileError.invalid("非零区段填充") }
    }
}

struct PSDWriteBuffer {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 255)]) }
    mutating func i16(_ value: Int) { u16(UInt16(bitPattern: Int16(value))) }
    mutating func u32(_ value: UInt32) { data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    mutating func i32(_ value: Int) { u32(UInt32(bitPattern: Int32(value))) }
    mutating func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func zeros(_ count: Int) { data.append(Data(repeating: 0, count: count)) }
    mutating func section(_ value: Data) { u32(UInt32(value.count)); bytes(value) }
}

enum PSDChannelCodec {
    static func decode(_ payload: Data, width: Int, height: Int) throws -> [UInt8] {
        guard width >= 0, height >= 0, width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw PSDFileError.tooLarge }
        var cursor = PSDReadCursor(payload)
        let compression = try cursor.u16(), count = width * height
        switch compression {
        case 0:
            guard cursor.remaining == count else { throw PSDFileError.invalid("未压缩通道长度不符") }
            return Array(try cursor.bytes(count))
        case 1:
            var lengths = [Int](); lengths.reserveCapacity(height)
            for _ in 0..<height { lengths.append(Int(try cursor.u16())) }
            var output = [UInt8](); output.reserveCapacity(count)
            for length in lengths {
                var row = try cursor.take(length), written = 0
                while row.remaining > 0 {
                    let code = Int(Int8(bitPattern: try row.u8()))
                    if code >= 0 {
                        let n = code + 1
                        guard n <= width - written else { throw PSDFileError.invalid("PackBits 行溢出") }
                        output.append(contentsOf: try row.bytes(n)); written += n
                    } else if code >= -127 {
                        let n = 1 - code
                        guard n <= width - written else { throw PSDFileError.invalid("PackBits 行溢出") }
                        output.append(contentsOf: repeatElement(try row.u8(), count: n)); written += n
                    }
                }
                guard written == width else { throw PSDFileError.invalid("PackBits 行长度不符") }
            }
            try cursor.finish()
            return output
        default: throw PSDFileError.unsupported("ZIP 或其他通道压缩")
        }
    }

    static func raw(_ bytes: [UInt8]) -> Data {
        var writer = PSDWriteBuffer(); writer.u16(0); writer.data.append(contentsOf: bytes); return writer.data
    }
}
