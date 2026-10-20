// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import zlib

/// A bounded, lossless map of OPC/OOXML ZIP members. Interpretation of XML and
/// relationships belongs to the presentation layer; opaque member bytes survive.
public struct PresentationPackage: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let detail): return "The presentation package is invalid or unsupported: " + detail }
        }
    }
    public static let maximumEntries = 20_000
    public static let maximumEntryBytes = 128 * 1024 * 1024
    public static let maximumTotalBytes = 512 * 1024 * 1024
    public static let maximumArchiveBytes = 768 * 1024 * 1024
    public var entries: [String: Data]

    public init(entries: [String: Data]) throws {
        try Self.validate(entries)
        self.entries = entries
    }
    public static func read(from url: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= maximumArchiveBytes else { throw Failure.invalid("The archive exceeds the size limit.") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        return try Self(data: bytes, cancellation: cancellation)
    }
    public init(data: Data, cancellation: OperationCancellation) throws {
        try cancellation.check()
        guard data.count >= 22, data.count <= Self.maximumArchiveBytes else { throw Failure.invalid("The ZIP header is missing or the archive exceeds the size limit.") }
        // Data slices can have a nonzero startIndex; all ZIP offsets are absolute.
        let bytes = Data(data)
        func word(_ offset: Int) throws -> Int { try Self.integer(bytes, offset, 2) }
        func long(_ offset: Int) throws -> Int { try Self.integer(bytes, offset, 4) }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try long(offset) == 0x06054b50, offset + 22 + (try word(offset + 20)) == bytes.count { end = offset; break }
        }
        guard let end else { throw Failure.invalid("The ZIP end record is missing or truncated.") }
        let count = try word(end + 10), directorySize = try long(end + 12), directoryOffset = try long(end + 16)
        guard try word(end + 4) == 0, try word(end + 6) == 0, try word(end + 8) == count else { throw Failure.invalid("Multipart ZIP archives are not supported.") }
        guard count != 0xffff, directorySize != 0xffffffff, directoryOffset != 0xffffffff else { throw Failure.invalid("ZIP64 packages are not supported.") }
        guard count <= Self.maximumEntries, directoryOffset + directorySize == end else { throw Failure.invalid("The ZIP directory bounds or member count are invalid.") }
        // ZIP64 locator without sentinel values is also unsupported.
        if end >= 20, try long(end - 20) == 0x07064b50 { throw Failure.invalid("ZIP64 packages are not supported.") }
        var result: [String: Data] = [:], aliases = Set<String>(), offset = directoryOffset, total = 0
        var occupied: [Range<Int>] = []
        for _ in 0..<count {
            try cancellation.check()
            guard offset + 46 <= end, try long(offset) == 0x02014b50 else { throw Failure.invalid("A ZIP directory member is truncated.") }
            let version = try word(offset + 6), flags = try word(offset + 8), method = try word(offset + 10)
            let crc = try long(offset + 16), compressed = try long(offset + 20), expanded = try long(offset + 24)
            let nameCount = try word(offset + 28), extraCount = try word(offset + 30), commentCount = try word(offset + 32)
            let disk = try word(offset + 34), external = try long(offset + 38), local = try long(offset + 42)
            let recordEnd = offset + 46 + nameCount + extraCount + commentCount
            guard recordEnd <= end, compressed != 0xffffffff, expanded != 0xffffffff, local != 0xffffffff, version < 45 else { throw Failure.invalid("A ZIP64 or truncated directory member is unsupported.") }
            guard disk == 0 else { throw Failure.invalid("Multipart ZIP members are not supported.") }
            guard flags & ~0x080e == 0, flags & 1 == 0 else { throw Failure.invalid("Encrypted or unsupported ZIP flags were found.") }
            guard method == 0 || method == 8 else { throw Failure.invalid("ZIP compression method \(method) is unsupported.") }
            guard method == 8 || flags & 6 == 0 else { throw Failure.invalid("A stored member has invalid compression flags.") }
            // Unix symlinks/devices are not package parts, even without extraction.
            let fileType = (external >> 16) & 0xf000
            guard fileType == 0 || fileType == 0x8000 || fileType == 0x4000 else { throw Failure.invalid("A ZIP member is a symbolic link or special file.") }
            let nameData = bytes.subdata(in: offset + 46..<offset + 46 + nameCount)
            guard let name = String(data: nameData, encoding: .utf8), flags & 0x800 != 0 || nameData.allSatisfy({ $0 < 128 }) else { throw Failure.invalid("A ZIP member name is not UTF-8 or ASCII.") }
            try Self.validateName(name)
            guard aliases.insert(Self.alias(name)).inserted else { throw Failure.invalid("Duplicate or aliased ZIP member: \(name)") }
            guard expanded <= Self.maximumEntryBytes, total <= Self.maximumTotalBytes - expanded else { throw Failure.invalid("The expanded package exceeds the size limit.") }
            total += expanded
            try Self.validateExtra(bytes, offset: offset + 46 + nameCount, length: extraCount)
            guard local + 30 <= directoryOffset, try long(local) == 0x04034b50 else { throw Failure.invalid("The local header for \(name) is missing.") }
            let localFlags = try word(local + 6), localMethod = try word(local + 8), localNameCount = try word(local + 26), localExtraCount = try word(local + 28)
            let payload = local + 30 + localNameCount + localExtraCount, payloadEnd = payload + compressed
            guard payload <= directoryOffset, payloadEnd <= directoryOffset,
                  try word(local + 4) == version, localFlags == flags, localMethod == method,
                  try word(local + 10) == word(offset + 12), try word(local + 12) == word(offset + 14),
                  bytes.subdata(in: local + 30..<local + 30 + localNameCount) == nameData else { throw Failure.invalid("The local and central headers disagree for \(name).") }
            try Self.validateExtra(bytes, offset: local + 30 + localNameCount, length: localExtraCount)
            let localCRC = try long(local + 14), localCompressed = try long(local + 18), localExpanded = try long(local + 22)
            var memberEnd = payloadEnd
            if flags & 8 == 0 {
                guard localCRC == crc, localCompressed == compressed, localExpanded == expanded else { throw Failure.invalid("The local member sizes or checksum disagree for \(name).") }
            } else {
                guard (localCRC == 0 || localCRC == crc), (localCompressed == 0 || localCompressed == compressed), (localExpanded == 0 || localExpanded == expanded) else { throw Failure.invalid("The streaming local header disagrees for \(name).") }
                var descriptor = payloadEnd
                if descriptor + 4 <= directoryOffset, try long(descriptor) == 0x08074b50 {
                    // CRC can equal the optional signature; prefer a complete
                    // unsigned descriptor when its remaining fields match.
                    let unsignedMatches = try descriptor + 12 <= directoryOffset && long(descriptor + 4) == compressed && long(descriptor + 8) == expanded
                    if !unsignedMatches { descriptor += 4 }
                }
                guard descriptor + 12 <= directoryOffset, try long(descriptor) == crc, try long(descriptor + 4) == compressed, try long(descriptor + 8) == expanded else { throw Failure.invalid("The ZIP data descriptor disagrees for \(name).") }
                memberEnd = descriptor + 12
            }
            occupied.append(local..<memberEnd)
            let content: Data
            if method == 0 {
                guard compressed == expanded else { throw Failure.invalid("Stored ZIP sizes disagree for \(name).") }
                content = bytes.subdata(in: payload..<payloadEnd)
            } else {
                content = try Self.inflate(bytes.subdata(in: payload..<payloadEnd), expected: expanded, cancellation: cancellation)
            }
            guard Self.checksum(content) == UInt32(crc) else { throw Failure.invalid("The checksum is invalid for \(name).") }
            guard !name.hasSuffix("/") || content.isEmpty else { throw Failure.invalid("A ZIP directory contains data.") }
            result[name] = content
            offset = recordEnd
        }
        guard offset == end else { throw Failure.invalid("The ZIP directory contains unaccounted bytes.") }
        let sorted = occupied.sorted { $0.lowerBound < $1.lowerBound }
        var nextLocalOffset = 0
        for range in sorted {
            guard range.lowerBound == nextLocalOffset else { throw Failure.invalid("ZIP members overlap or contain unaccounted data.") }
            nextLocalOffset = range.upperBound
        }
        guard nextLocalOffset == directoryOffset else { throw Failure.invalid("The ZIP package has unaccounted local data.") }
        try cancellation.check()
        self.entries = result
    }

    /// Deterministic ZIP32 output. Stored members preserve every opaque part
    /// without requiring an Office installation or a compression process.
    public func encoded(cancellation: OperationCancellation) throws -> Data {
        try cancellation.check()
        try Self.validate(entries)
        var output = Data(), directory = Data()
        for name in entries.keys.sorted() {
            try cancellation.check()
            let content = entries[name]!, path = Data(name.utf8), crc = Self.checksum(content), offset = output.count
            Self.append([0x04034b50,20,0x800,0,0,0x21,Int(crc),content.count,content.count,path.count,0], widths: [4,2,2,2,2,2,4,4,4,2,2], to: &output)
            output.append(path)
            // Chunked appends retain cancellation responsiveness for large media.
            for start in stride(from: 0, to: content.count, by: 64 * 1024) {
                try cancellation.check(); output.append(content.subdata(in: (content.startIndex + start)..<(content.startIndex + min(start + 64 * 1024, content.count))))
            }
            Self.append([0x02014b50,20,20,0x800,0,0,0x21,Int(crc),content.count,content.count,path.count,0,0,0,0,0,offset], widths: [4,2,2,2,2,2,2,4,4,4,2,2,2,2,2,4,4], to: &directory)
            directory.append(path)
        }
        let directoryOffset = output.count
        output.append(directory)
        Self.append([0x06054b50,0,0,entries.count,entries.count,directory.count,directoryOffset,0], widths: [4,2,2,2,2,4,4,2], to: &output)
        guard output.count <= Self.maximumArchiveBytes else { throw Failure.invalid("The encoded archive exceeds the size limit.") }
        try cancellation.check()
        return output
    }

    private static func validate(_ entries: [String: Data]) throws {
        guard entries.count <= maximumEntries else { throw Failure.invalid("Too many ZIP members.") }
        var total = 0, encodedSize = 22, aliases = Set<String>()
        for (name, bytes) in entries {
            try validateName(name)
            guard aliases.insert(alias(name)).inserted else { throw Failure.invalid("Duplicate or aliased ZIP member: \(name)") }
            guard bytes.count <= maximumEntryBytes, total <= maximumTotalBytes - bytes.count else { throw Failure.invalid("The expanded package exceeds the size limit.") }
            guard !name.hasSuffix("/") || bytes.isEmpty else { throw Failure.invalid("A ZIP directory contains data.") }
            total += bytes.count
            encodedSize += 76 + 2 * name.utf8.count + bytes.count
            guard encodedSize <= maximumArchiveBytes else { throw Failure.invalid("The encoded archive exceeds the size limit.") }
        }
    }
    private static func alias(_ name: String) -> String {
        let normalized = name.hasSuffix("/") ? String(name.dropLast()) : name
        return (normalized.removingPercentEncoding ?? normalized).precomposedStringWithCanonicalMapping.lowercased()
    }
    private static func validateName(_ name: String) throws {
        let raw = name.hasSuffix("/") ? String(name.dropLast()) : name
        guard !raw.isEmpty, name.utf8.count <= 65_535, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"), !raw.contains("?"), !raw.contains("#"),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              raw.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalid("Unsafe ZIP member path: \(name)") }
        // OPC names are URI paths. Encoded separators/dot segments must not create
        // a different package graph from the literal ZIP member names.
        guard let decoded = raw.removingPercentEncoding, !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              decoded.split(separator: "/", omittingEmptySubsequences: false).count == raw.split(separator: "/", omittingEmptySubsequences: false).count,
              decoded.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.invalid("Unsafe encoded ZIP member path: \(name)") }
    }
    private static func integer(_ bytes: Data, _ offset: Int, _ length: Int) throws -> Int {
        guard offset >= 0, offset <= bytes.count - length else { throw Failure.invalid("A ZIP record is truncated.") }
        var value = 0
        for index in 0..<length { value |= Int(bytes[offset + index]) << (8 * index) }
        return value
    }
    private static func validateExtra(_ bytes: Data, offset: Int, length: Int) throws {
        let end = offset + length
        guard end <= bytes.count else { throw Failure.invalid("ZIP extra fields are truncated.") }
        var cursor = offset
        while cursor < end {
            guard cursor + 4 <= end else { throw Failure.invalid("ZIP extra field header is truncated.") }
            let kind = try integer(bytes, cursor, 2), size = try integer(bytes, cursor + 2, 2)
            guard kind != 1 else { throw Failure.invalid("ZIP64 extra fields are unsupported.") }
            cursor += 4 + size
            guard cursor <= end else { throw Failure.invalid("ZIP extra field data is truncated.") }
        }
    }
    private static func append(_ values: [Int], widths: [Int], to bytes: inout Data) {
        for (value, width) in zip(values, widths) { for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) } }
    }
    private static func checksum(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { pointer in UInt32(crc32(0, pointer.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
    }
    private static func inflate(_ bytes: Data, expected: Int, cancellation: OperationCancellation) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid("The ZIP inflater could not initialize.") }
        defer { inflateEnd(&stream) }
        return try bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try cancellation.check()
                let status = buffer.withUnsafeMutableBytes { pointer -> Int32 in
                    stream.next_out = pointer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(pointer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard output.count <= expected - produced else { throw Failure.invalid("A DEFLATE member exceeds its declared size.") }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, output.count == expected else { throw Failure.invalid("A DEFLATE member has trailing bytes or an incorrect size.") }
                    return output
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw Failure.invalid("A DEFLATE stream is corrupt or truncated.") }
            }
        }
    }
}
