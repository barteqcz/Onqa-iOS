import Foundation
import Compression

/// Detects what a downloaded station logo really is. The URL extension is not
/// trustworthy: many logo URLs have no extension, carry query strings, or serve
/// SVG under another name, and `.svgz` files are gzip-compressed SVG.
enum StationLogoFormat {
    /// Returns plain SVG bytes if `data` is an SVG (optionally gzip-compressed),
    /// otherwise nil so the caller decodes it as a raster image (PNG, JPEG, WebP, ...).
    static func svgData(from data: Data) -> Data? {
        var bytes = data
        if bytes.count > 2, bytes[bytes.startIndex] == 0x1f, bytes[bytes.startIndex + 1] == 0x8b {
            guard let inflated = gunzip(bytes) else { return nil }
            bytes = inflated
        }
        let head = bytes.prefix(2048)
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return nil }
        return text.range(of: "<svg", options: .caseInsensitive) != nil ? bytes : nil
    }

    static let maximumDecompressedBytes = 8 * 1024 * 1024

    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        let trailerStart = b.count - 8
        // The three high bits are reserved by RFC 1952 and must be zero.
        guard flags & 0xE0 == 0 else { return nil }

        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= trailerStart else { return nil }
            let extraLength = Int(b[offset]) | (Int(b[offset + 1]) << 8)
            offset += 2
            guard extraLength <= trailerStart - offset else { return nil }
            offset += extraLength
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < trailerStart, b[offset] != 0 { offset += 1 }
            guard offset < trailerStart else { return nil }
            offset += 1
        }
        if flags & 0x02 != 0 {
            guard offset + 2 <= trailerStart else { return nil }
            offset += 2
        }
        guard offset < trailerStart else { return nil }

        // ISIZE is modulo 2^32, so it is only an early rejection hint. The
        // streaming inflater below enforces the real output limit.
        let uncompressedSize = UInt32(b[b.count - 4])
            | (UInt32(b[b.count - 3]) << 8)
            | (UInt32(b[b.count - 2]) << 16)
            | (UInt32(b[b.count - 1]) << 24)
        guard uncompressedSize <= UInt32(maximumDecompressedBytes) else { return nil }

        // Gzip wraps a raw DEFLATE payload. Stream it into a fixed-size buffer
        // so an expansion bomb cannot allocate an unbounded decompressed Data.
        let deflated = Data(b[offset..<trailerStart])
        guard let inflated = inflateDeflate(
            deflated,
            maximumBytes: maximumDecompressedBytes
        ), inflated.count == Int(uncompressedSize) else {
            return nil
        }
        return inflated
    }

    private static func inflateDeflate(_ data: Data, maximumBytes: Int) -> Data? {
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        // The C stream structure requires non-optional source and destination
        // pointers even before any input has been assigned.
        let emptySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { emptySource.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: bufferSize,
            src_ptr: UnsafePointer(emptySource),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        return data.withUnsafeBytes { rawBuffer -> Data? in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            stream.src_ptr = source
            stream.src_size = data.count

            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = bufferSize - stream.dst_size
                guard produced <= maximumBytes - output.count else { return nil }
                if produced > 0 {
                    output.append(destination, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // With all input marked final, a no-progress result means
                    // the stream is truncated or cannot be decoded further.
                    guard produced > 0 || stream.src_size > 0 else { return nil }
                default:
                    return nil
                }
            }
        }
    }
}
