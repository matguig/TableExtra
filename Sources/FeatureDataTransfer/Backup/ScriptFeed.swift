import Foundation
import zlib

/// Decompresses gzip files in-process (no /usr/bin/gunzip, which a sandboxed app cannot run).
public enum Gunzip {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
    }

    /// Writes the decompressed bytes of `input` to `fd`. Returns quietly when the reader closes its end (EPIPE): the tool
    /// exited or was cancelled.
    public static func stream(_ input: URL, to fd: Int32) throws {
        try stream(input) { try writeAll($0, to: fd) }
    }

    /// Hands the decompressed bytes of `input` to `sink`, which returns false to stop. Handles concatenated members,
    /// as `gzip` and `cat a.gz b.gz` produce.
    public static func stream(_ input: URL, into sink: (UnsafeRawBufferPointer) throws -> Bool) throws {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        var z = z_stream()
        // 15 window bits + 32: detect the gzip (or zlib) header.
        guard inflateInit2_(&z, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure(errorDescription: "gunzip: cannot initialise zlib")
        }
        defer { inflateEnd(&z) }
        let chunk = 1 << 16
        var out = [UInt8](repeating: 0, count: chunk)
        var midMember = false
        while let data = try handle.read(upToCount: chunk), !data.isEmpty {
            var input = [UInt8](data)
            var offset = 0
            while offset < input.count {
                let status: Int32 = input.withUnsafeMutableBufferPointer { inBuf in
                    out.withUnsafeMutableBufferPointer { outBuf in
                        z.next_in = inBuf.baseAddress! + offset
                        z.avail_in = uInt(inBuf.count - offset)
                        z.next_out = outBuf.baseAddress
                        z.avail_out = uInt(chunk)
                        let s = inflate(&z, Z_NO_FLUSH)
                        offset = inBuf.count - Int(z.avail_in)
                        return s
                    }
                }
                let produced = chunk - Int(z.avail_out)
                if produced > 0, try !out.withUnsafeBytes({ try sink(UnsafeRawBufferPointer(rebasing: $0.prefix(produced))) }) { return }
                switch status {
                case Z_STREAM_END:
                    midMember = false
                    inflateReset(&z)
                case Z_OK, Z_BUF_ERROR:
                    midMember = true
                default:
                    let message = z.msg.map { String(cString: $0) } ?? "status \(status)"
                    throw Failure(errorDescription: "gunzip: \(message) (is the file valid gzip data?)")
                }
            }
        }
        if midMember { throw Failure(errorDescription: "gunzip: unexpected end of file (truncated archive?)") }
    }

    /// False when the reader closed the pipe.
    static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws -> Bool {
        var done = 0
        while done < buffer.count {
            let n = write(fd, buffer.baseAddress! + done, buffer.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EPIPE { return false }
                throw Failure(errorDescription: "Could not feed the script to the tool: \(String(cString: strerror(errno)))")
            }
            done += n
        }
        return true
    }
}

/// Feeds a plain SQL script, gzip-compressed or not, into psql's stdin.
public enum ScriptFeed {
    /// pg_dump 17+ writes this line, which PostgreSQL 16 and older reject (aborting a single-transaction restore).
    static let transactionTimeout = Data("SET transaction_timeout = 0;\n".utf8)
    /// pg_dump writes its SET lines first: only the leading bytes are searched.
    static let headerSize = 64 * 1024

    /// Shell equivalent, for the log.
    public static func label(_ input: URL, gzip: Bool, skipTransactionTimeout: Bool) -> String {
        let source = (gzip ? "gunzip -c " : "cat ") + input.path
        return skipTransactionTimeout ? source + " | grep -vx 'SET transaction_timeout = 0;'" : source
    }

    public static func stream(_ input: URL, gzip: Bool, skipTransactionTimeout: Bool, to fd: Int32) throws {
        var header = Data()
        var headerDone = !skipTransactionTimeout
        // Buffers the header, drops the line once, then passes everything through. False when the reader is gone.
        func emit(_ bytes: UnsafeRawBufferPointer) throws -> Bool {
            if headerDone { return try Gunzip.writeAll(bytes, to: fd) }
            header.append(contentsOf: bytes)
            guard header.count >= headerSize else { return true }
            return try flushHeader()
        }
        func flushHeader() throws -> Bool {
            headerDone = true
            let cleaned = removingTransactionTimeout(header)
            header = Data()
            return try cleaned.withUnsafeBytes { try Gunzip.writeAll($0, to: fd) }
        }
        if gzip {
            try Gunzip.stream(input) { try emit($0) }
        } else {
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1 << 16), !data.isEmpty {
                guard try data.withUnsafeBytes({ try emit($0) }) else { return }
            }
        }
        if !headerDone { _ = try flushHeader() }
    }

    /// Drops the first `SET transaction_timeout = 0;` line of `data`.
    static func removingTransactionTimeout(_ data: Data) -> Data {
        var start = data.startIndex
        while let r = data.range(of: transactionTimeout, in: start..<data.endIndex) {
            if r.lowerBound == data.startIndex || data[r.lowerBound - 1] == 0x0A {
                var out = data
                out.removeSubrange(r)
                return out
            }
            start = r.upperBound
        }
        return data
    }
}
