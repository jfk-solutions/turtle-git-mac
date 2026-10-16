// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of contrib/diff-scripts/diff-zip.js: top-level metadata only.
import Foundation

public enum ZIPInventoryFailure: LocalizedError {
    case malformed, limit, encoding, multipart
    public var errorDescription: String? {
        switch self {
        case .malformed: return "The ZIP archive directory is incomplete or invalid."
        case .limit: return "The ZIP archive directory exceeds the comparison limit (100,000 entries or 64 MiB of metadata/text)."
        case .encoding: return "A ZIP archive filename has invalid Unicode encoding."
        case .multipart: return "Split ZIP archives cannot be compared as a single file."
        }
    }
}
public struct ZIPInventory: Sendable {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let size: UInt64
        public let modified: String
        public let directory: Bool
    }
    public let items: [Item]
    /// Inspect the central directory only. No member is decompressed, executed or
    /// interpreted as a filesystem path. Metadata comparison intentionally does
    /// not detect changed contents with unchanged name/date/size, like upstream.
    public init(_ data: Data, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        let bytes = [UInt8](data.suffix(min(data.count, 65_557)))
        func word(_ array: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(array[offset + $1]) << ($1 * 8) }
        }
        var footer: Int?
        if bytes.count >= 22 {
            for position in stride(from: bytes.count - 22, through: 0, by: -1) {
                if word(bytes, position, 4) == 0x06054b50 && position + 22 + Int(word(bytes, position + 20, 2)) == bytes.count { footer = position; break }
            }
        }
        guard let footer else { throw ZIPInventoryFailure.malformed }
        guard word(bytes, footer + 4, 2) == 0, word(bytes, footer + 6, 2) == 0, word(bytes, footer + 8, 2) == word(bytes, footer + 10, 2) else { throw ZIPInventoryFailure.multipart }
        let footerOffset = data.count - bytes.count + footer
        func read(_ offset: Int, _ length: Int) throws -> [UInt8] {
            guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { throw ZIPInventoryFailure.malformed }
            return Array(data[data.startIndex + offset..<data.startIndex + offset + length])
        }
        var count = word(bytes, footer + 10, 2), size = word(bytes, footer + 12, 4), offset = word(bytes, footer + 16, 4)
        var directoryEnd = footerOffset
        if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
            let locator = try read(footerOffset - 20, 20)
            guard word(locator, 0, 4) == 0x07064b50, word(locator, 4, 4) == 0, word(locator, 16, 4) == 1 else { throw ZIPInventoryFailure.multipart }
            let location = word(locator, 8, 8)
            guard location <= UInt64(Int.max) else { throw ZIPInventoryFailure.malformed }
            let record = try read(Int(location), 56)
            guard word(record, 0, 4) == 0x06064b50, word(record, 4, 8) >= 44,
                  word(record, 16, 4) == 0, word(record, 20, 4) == 0,
                  word(record, 24, 8) == word(record, 32, 8) else { throw ZIPInventoryFailure.multipart }
            count = word(record, 32, 8); size = word(record, 40, 8); offset = word(record, 48, 8); directoryEnd = Int(location)
        }
        guard count <= 100_000, size <= 64 * 1024 * 1024 else { throw ZIPInventoryFailure.limit }
        guard offset <= UInt64(directoryEnd), size <= UInt64(directoryEnd) - offset else { throw ZIPInventoryFailure.malformed }
        let directory = try read(Int(offset), Int(size))
        var cursor = 0, rows: [Item] = [], positions: [String: Int] = [:], explicit = Set<String>()
        for _ in 0..<Int(count) {
            try cancellation?.check()
            guard cursor <= directory.count, directory.count - cursor >= 46, word(directory, cursor, 4) == 0x02014b50 else { throw ZIPInventoryFailure.malformed }
            let length = Int(word(directory, cursor + 28, 2)), extrasLength = Int(word(directory, cursor + 30, 2)), commentLength = Int(word(directory, cursor + 32, 2))
            let next = cursor + 46 + length + extrasLength + commentLength
            guard next <= directory.count, length > 0, word(directory, cursor + 34, 2) == 0 else { throw ZIPInventoryFailure.malformed }
            let nameBytes = Array(directory[cursor + 46..<cursor + 46 + length])
            let flags = word(directory, cursor + 8, 2), date = word(directory, cursor + 14, 2), time = word(directory, cursor + 12, 2)
            var uncompressed = word(directory, cursor + 24, 4), compressed = word(directory, cursor + 20, 4), name: String?
            let extrasStart = cursor + 46 + length, extrasEnd = extrasStart + extrasLength
            var extra = extrasStart
            while extra < extrasEnd {
                guard extrasEnd - extra >= 4 else { throw ZIPInventoryFailure.malformed }
                let kind = word(directory, extra, 2), amount = Int(word(directory, extra + 2, 2)); extra += 4
                guard amount <= extrasEnd - extra else { throw ZIPInventoryFailure.malformed }
                if kind == 1 {
                    var index = extra
                    if uncompressed == 0xffffffff { guard amount >= 8 else { throw ZIPInventoryFailure.malformed }; uncompressed = word(directory, index, 8); index += 8 }
                    if compressed == 0xffffffff { guard index + 8 <= extra + amount else { throw ZIPInventoryFailure.malformed }; compressed = word(directory, index, 8) }
                } else if kind == 0x7075, amount >= 5, directory[extra] == 1, word(directory, extra + 1, 4) == UInt64(Self.crc32(nameBytes)) {
                    name = String(bytes: directory[extra + 5..<extra + amount], encoding: .utf8)
                }
                extra += amount
            }
            guard uncompressed != 0xffffffff, compressed != 0xffffffff else { throw ZIPInventoryFailure.malformed }
            if flags & 0x800 != 0 { name = String(bytes: nameBytes, encoding: .utf8); guard name != nil else { throw ZIPInventoryFailure.encoding } }
            if name == nil { name = Self.legacyName(nameBytes) }
            guard let name, !name.contains("\0") else { throw ZIPInventoryFailure.encoding }
            // ZIP uses '/', independently of the host filesystem. A dangerous
            // spelling remains display data; nothing is ever extracted.
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let top = String(components[0]), isFolder = components.count > 1
            let ownRecord = components.count == 1 || components.count == 2 && components[1].isEmpty
            let modified = String(format: "%04d-%02d-%02d %02d:%02d:%02d", Int(date >> 9) + 1980, Int((date >> 5) & 15), Int(date & 31), Int(time >> 11), Int((time >> 5) & 63), Int(time & 31) * 2)
            let row = Item(name: top, size: isFolder ? 0 : uncompressed, modified: modified, directory: isFolder)
            if let index = positions[top] {
                if ownRecord && !explicit.contains(top) { rows[index] = row; explicit.insert(top) }
            } else { positions[top] = rows.count; rows.append(row); if ownRecord { explicit.insert(top) } }
            cursor = next
        }
        guard cursor == directory.count else { throw ZIPInventoryFailure.malformed }
        try cancellation?.check(); items = rows
    }
    public func text(title: String, cancellation: OperationCancellation? = nil) throws -> String {
        // Long member names remain intact; cap padding so one very long name
        // cannot multiply into gigabytes of blank columns for every other row.
        let width = min(256, max(20, items.map { $0.name.count }.max() ?? 0))
        var output = title + "\n\n"
        for item in items {
            try cancellation?.check()
            let name = item.name.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
            let line = name + String(repeating: " ", count: max(1, width - name.count + 1)) + item.modified + " " + String(item.size) + "\n"
            guard output.utf8.count <= 64 * 1024 * 1024 - line.utf8.count else { throw ZIPInventoryFailure.limit }
            output += line
        }
        return output + "\n\(items.count) items\n"
    }
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) } }
        return crc ^ UInt32.max
    }
    private static func legacyName(_ bytes: [UInt8]) -> String {
        let upper = Array("ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ".unicodeScalars)
        return String(String.UnicodeScalarView(bytes.map { $0 < 128 ? UnicodeScalar(Int($0))! : upper[Int($0) - 128] }))
    }
}


extension FileComparisonDocument {
    public func zipInventories(cancellation: OperationCancellation? = nil) throws -> Self {
        func inventory(_ content: ComparisonFileContent) throws -> ComparisonFileContent {
            try cancellation?.check()
            let text = content.isDeleted ? "File absent\n" : try ZIPInventory(content.bytes, cancellation: cancellation).text(title: content.path, cancellation: cancellation)
            return ComparisonFileContent(path: content.path + ".inventory.txt", revision: content.revision, bytes: Data(text.utf8), mode: nil, encoding: .utf8, isDeleted: content.isDeleted)
        }
        return try Self(base: inventory(base), destination: inventory(destination))
    }
}
