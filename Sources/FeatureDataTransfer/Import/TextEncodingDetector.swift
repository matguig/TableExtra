import Foundation

public enum TextFileEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case latin1 = "Latin-1 (ISO 8859-1)"
    public var id: String { rawValue }
}

public struct DetectedEncoding: Equatable, Sendable {
    public var encoding: TextFileEncoding
    /// Bytes to skip at the start of the file.
    public var bomLength: Int

    public init(encoding: TextFileEncoding, bomLength: Int = 0) {
        self.encoding = encoding
        self.bomLength = bomLength
    }
}

public enum TextEncodingDetector {
    /// BOM first, then a UTF-16 zero-byte heuristic, then strict UTF-8 validation, else Latin-1.
    public static func detect(_ sample: Data) -> DetectedEncoding {
        let b = [UInt8](sample.prefix(65_536))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return DetectedEncoding(encoding: .utf8, bomLength: 3) }
        if b.starts(with: [0xFF, 0xFE]) { return DetectedEncoding(encoding: .utf16LE, bomLength: 2) }
        if b.starts(with: [0xFE, 0xFF]) { return DetectedEncoding(encoding: .utf16BE, bomLength: 2) }
        if b.count >= 4 {
            var evenZeros = 0, oddZeros = 0
            for (i, x) in b.prefix(4096).enumerated() where x == 0 {
                if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let pairs = min(b.count, 4096) / 2
            if oddZeros > pairs / 3 && evenZeros <= pairs / 20 { return DetectedEncoding(encoding: .utf16LE, bomLength: 0) }
            if evenZeros > pairs / 3 && oddZeros <= pairs / 20 { return DetectedEncoding(encoding: .utf16BE, bomLength: 0) }
        }
        return DetectedEncoding(encoding: isValidUTF8(b, allowTruncatedTail: true) ? .utf8 : .latin1, bomLength: 0)
    }

    /// Validates UTF-8; a multi-byte sequence cut off by the end of the sample is accepted when `allowTruncatedTail`.
    public static func isValidUTF8(_ b: [UInt8], allowTruncatedTail: Bool) -> Bool {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            let len: Int
            if c >= 0xC2 && c <= 0xDF { len = 2 }
            else if c >= 0xE0 && c <= 0xEF { len = 3 }
            else if c >= 0xF0 && c <= 0xF4 { len = 4 }
            else { return false }
            if i + len > n { return allowTruncatedTail && (i + 1..<n).allSatisfy { b[$0] & 0xC0 == 0x80 } }
            for k in 1..<len where b[i + k] & 0xC0 != 0x80 { return false }
            if len == 3 {
                if c == 0xE0 && b[i + 1] < 0xA0 { return false }
                if c == 0xED && b[i + 1] > 0x9F { return false }
            } else if len == 4 {
                if c == 0xF0 && b[i + 1] < 0x90 { return false }
                if c == 0xF4 && b[i + 1] > 0x8F { return false }
            }
            i += len
        }
        return true
    }

    /// Whole-buffer decode with the given encoding (used for previews and JSON files).
    public static func decode(_ data: Data, as e: DetectedEncoding) -> String {
        let body = data.dropFirst(e.bomLength)
        switch e.encoding {
        case .utf8: return String(decoding: body, as: UTF8.self)
        case .latin1: return String(data: body, encoding: .isoLatin1) ?? ""
        case .utf16LE, .utf16BE:
            var t = UTF16Transcoder(bigEndian: e.encoding == .utf16BE)
            return String(decoding: t.transcode(Data(body), final: true), as: UTF8.self)
        }
    }
}

/// Converts UTF-16 chunks to UTF-8 bytes, carrying odd bytes and split surrogate pairs to the next chunk.
struct UTF16Transcoder {
    let bigEndian: Bool
    private var carry: [UInt8] = []

    init(bigEndian: Bool) { self.bigEndian = bigEndian }

    mutating func transcode(_ data: Data, final: Bool) -> [UInt8] {
        var bytes = carry
        bytes.append(contentsOf: data)
        carry = []
        if bytes.count % 2 == 1 {
            if final { bytes.removeLast() } else { carry = [bytes.removeLast()] }
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
            i += 2
        }
        if !final, let last = units.last, (0xD800...0xDBFF).contains(last) {
            units.removeLast()
            let pair: [UInt8] = bigEndian ? [UInt8(last >> 8), UInt8(last & 0xFF)] : [UInt8(last & 0xFF), UInt8(last >> 8)]
            carry = pair + carry
        }
        return Array(String(decoding: units, as: UTF16.self).utf8)
    }
}

/// Reads a delimited text file in chunks and yields parsed records.
public final class DelimitedFileReader {
    public let url: URL
    public let encoding: DetectedEncoding
    public let totalBytes: Int64
    public private(set) var bytesRead: Int64 = 0
    private let handle: FileHandle
    private var parser: CSVParser
    private var transcoder: UTF16Transcoder?
    private var queue: [CSVRecord] = []
    private var queueStart = 0
    private var eof = false
    private let chunkSize: Int

    public init(url: URL, encoding: DetectedEncoding, delimiter: UInt8, chunkSize: Int = 1 << 20) throws {
        self.url = url
        self.encoding = encoding
        self.chunkSize = chunkSize
        handle = try FileHandle(forReadingFrom: url)
        totalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        parser = CSVParser(delimiter: delimiter, encoding: encoding.encoding == .latin1 ? .latin1 : .utf8)
        if encoding.encoding == .utf16LE || encoding.encoding == .utf16BE {
            transcoder = UTF16Transcoder(bigEndian: encoding.encoding == .utf16BE)
        }
        if encoding.bomLength > 0 {
            _ = try handle.read(upToCount: encoding.bomLength)
            bytesRead = Int64(encoding.bomLength)
        }
    }

    deinit { try? handle.close() }

    public var fractionRead: Double { totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : 0 }
    public var hadUnterminatedQuote: Bool { parser.hadUnterminatedQuote }

    /// Up to `max` records; an empty array means end of file.
    public func next(_ max: Int) throws -> [CSVRecord] {
        while queue.count - queueStart < max && !eof {
            try fill()
        }
        let end = min(queue.count, queueStart + max)
        let out = Array(queue[queueStart..<end])
        queueStart = end
        if queueStart > 50_000 {
            queue.removeFirst(queueStart)
            queueStart = 0
        }
        return out
    }

    private func fill() throws {
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        bytesRead += Int64(data.count)
        let final = data.isEmpty
        var collected: [CSVRecord] = []
        if var t = transcoder {
            let utf8 = t.transcode(data, final: final)
            transcoder = t
            parser.feed(utf8) { collected.append($0) }
        } else {
            parser.feed(data) { collected.append($0) }
        }
        if final {
            parser.finish { collected.append($0) }
            eof = true
        }
        queue.append(contentsOf: collected)
    }
}
