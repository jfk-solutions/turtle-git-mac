import Foundation

public struct GitBlameOptions: Sendable {
    public var ignoreWhitespace = false, detectMoved = false, detectCopied = false
    public init() {}
}
public struct GitBlameLine: Identifiable, Sendable {
    public var id: Int { number }
    public let hash: String
    public let originalLine: Int
    public let number: Int
    public let author: String
    public let email: String
    public let date: Date
    public let timezone: String
    public let summary: String
    public let filename: String
    public let boundary: Bool
    public let source: String
    /// Exact payload bytes between Git's tab prefix and LF record delimiter.
    public let sourceBytes: Data
}
public struct GitBlameSnapshot: Sendable {
    public let revision: String
    public let path: String
    public let contents: Data
    public let encoding: GitBlameEncoding
    public let lines: [GitBlameLine]
}
public struct GitBlameParentComparison: Identifiable, Sendable {
    public var id: String { revision }
    public let parentNumber: Int
    public let revision: String
    public let path: String
    public let comparison: RevisionComparisonSnapshot
}
public enum GitBlameEncoding: String, Sendable {
    case utf8 = "UTF-8", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE"
    static func detect(_ bytes: Data) throws -> GitBlameEncoding {
        if bytes.starts(with: [0xff, 0xfe]) { try validateUTF16(bytes.dropFirst(2), little: true); return .utf16LE }
        if bytes.starts(with: [0xfe, 0xff]) { try validateUTF16(bytes.dropFirst(2), little: false); return .utf16BE }
        if !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil { return .utf8 }
        // Without a BOM, require ASCII-compatible zero-byte evidence rather than
        // treating arbitrary binary bytes as UTF-16. Ambiguous files need a chooser.
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { throw GitBlameFailure.unsupported }
        let data = Array(bytes), pairs = data.count / 2
        let littleZeros = stride(from: 1, to: data.count, by: 2).filter { data[$0] == 0 }.count
        let bigZeros = stride(from: 0, to: data.count, by: 2).filter { data[$0] == 0 }.count
        let little = littleZeros > bigZeros
        guard max(littleZeros, bigZeros) * 2 >= pairs else { throw GitBlameFailure.unsupported }
        try validateUTF16(bytes, little: little)
        guard let text = String(data: bytes, encoding: little ? .utf16LittleEndian : .utf16BigEndian),
              text.unicodeScalars.contains(where: { $0.value >= 32 && $0.value != 127 }) else { throw GitBlameFailure.unsupported }
        return little ? .utf16LE : .utf16BE
    }
    private static func validateUTF16(_ data: Data, little: Bool) throws {
        let bytes = Array(data); guard bytes.count % 2 == 0 else { throw GitBlameFailure.unsupported }
        var index = 0, high = false
        while index < bytes.count {
            let value = little ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            // Git counts byte LF, not Unicode lines. Reject ambiguous LF bytes
            // within another code unit rather than display truncated characters.
            guard value != 0, !(value != 10 && (bytes[index] == 10 || bytes[index + 1] == 10)) else { throw GitBlameFailure.unsupported }
            if high { guard (0xdc00...0xdfff).contains(value) else { throw GitBlameFailure.unsupported }; high = false }
            else if (0xd800...0xdbff).contains(value) { high = true }
            else if (0xdc00...0xdfff).contains(value) { throw GitBlameFailure.unsupported }
            index += 2
        }
        guard !high else { throw GitBlameFailure.unsupported }
    }
    func decode(_ raw: Data, line: Int) throws -> String {
        if self == .utf8 {
            guard !raw.contains(0), String(data: raw, encoding: .utf8) != nil else { throw GitBlameFailure.unsupported }; return String(decoding: raw, as: UTF8.self)
        }
        var bytes = raw
        if line == 1, bytes.starts(with: self == .utf16LE ? [0xff, 0xfe] : [0xfe, 0xff]) { bytes.removeFirst(2) }
        else if self == .utf16LE, line > 1 { guard bytes.first == 0 else { throw GitBlameFailure.format }; bytes.removeFirst() }
        if bytes.count % 2 != 0 { guard self == .utf16BE, bytes.last == 0 else { throw GitBlameFailure.format }; bytes.removeLast() }
        try Self.validateUTF16(bytes, little: self == .utf16LE)
        let data = Array(bytes)
        let units = stride(from: 0, to: data.count, by: 2).map { index in
            self == .utf16LE ? UInt16(data[index]) | UInt16(data[index + 1]) << 8 : UInt16(data[index]) << 8 | UInt16(data[index + 1])
        }
        return String(decoding: units, as: UTF16.self)
    }
}
public enum GitBlameFailure: LocalizedError {
    case format, unsupported
    public var errorDescription: String? {
        switch self { case .format: return "Git returned incomplete or invalid line annotation data."; case .unsupported: return "Blame supports regular UTF-8 and unambiguous UTF-16 text files." }
    }
}
public enum GitBlameParser {
    static func filename(_ value: String) throws -> String {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw GitBlameFailure.format }
        guard value.hasPrefix("\"") else { return value }
        guard value.hasSuffix("\"") else { throw GitBlameFailure.format }
        let input = Array(value.utf8.dropFirst().dropLast()); var output: [UInt8] = [], i = 0
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
        while i < input.count {
            let byte = input[i]; i += 1
            if byte != 92 { output.append(byte); continue }
            guard i < input.count else { throw GitBlameFailure.format }
            let escaped = input[i]; i += 1
            if let byte = escapes[escaped] { output.append(byte) }
            else if (48...55).contains(escaped) {
                guard i + 1 < input.count, (48...55).contains(input[i]), (48...55).contains(input[i + 1]) else { throw GitBlameFailure.format }
                let number = Int(escaped - 48) * 64 + Int(input[i] - 48) * 8 + Int(input[i + 1] - 48)
                guard number <= 255 else { throw GitBlameFailure.format }; output.append(UInt8(number)); i += 2
            } else { throw GitBlameFailure.format }
        }
        guard !output.isEmpty, !output.contains(0), let result = String(bytes: output, encoding: .utf8) else { throw GitBlameFailure.format }
        return result
    }
    public static func parse(_ data: Data, encoding: GitBlameEncoding = .utf8) throws -> [GitBlameLine] {
        guard data.isEmpty || data.last == 10 else { throw GitBlameFailure.format }
        var output: [GitBlameLine] = [], hash: String?, original = 0, final = 0, fields: [String: String] = [:]
        let records = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, bytes) in records.enumerated() {
            if bytes.isEmpty, index == records.count - 1 { continue }
            if bytes.first == 9 {
                guard let revisionHash = hash, let author = fields["author"], let mail = fields["author-mail"],
                      let seconds = fields["author-time"].flatMap(Int64.init), let timezone = fields["author-tz"], validTimezone(timezone),
                      let summary = fields["summary"], let path = fields["filename"], final == output.count + 1 else { throw GitBlameFailure.format }
                output.append(GitBlameLine(hash: revisionHash, originalLine: original, number: final, author: author,
                    email: mail.hasPrefix("<") && mail.hasSuffix(">") ? String(mail.dropFirst().dropLast()) : mail,
                    date: Date(timeIntervalSince1970: TimeInterval(seconds)), timezone: timezone, summary: summary,
                    filename: try filename(path), boundary: fields["boundary"] != nil,
                    source: try encoding.decode(Data(bytes.dropFirst()), line: final), sourceBytes: Data(bytes.dropFirst())))
                // line-porcelain repeats metadata for every source line.
                fields = [:]; hash = nil
            } else {
                guard !bytes.contains(0), let text = String(data: Data(bytes), encoding: .utf8) else { throw GitBlameFailure.format }
                if hash == nil {
                    let header = text.split(separator: " ")
                    guard header.count == 3 || header.count == 4, [40, 64].contains(header[0].count),
                          header[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                          let a = Int(header[1]), let b = Int(header[2]), a > 0, b > 0,
                          header.count == 3 || (Int(header[3]).map { $0 > 0 } ?? false) else { throw GitBlameFailure.format }
                    hash = String(header[0]); original = a; final = b
                } else {
                    let pair = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let key = pair.first, !key.isEmpty, fields[String(key)] == nil else { throw GitBlameFailure.format }
                    fields[String(key)] = pair.count == 2 ? String(pair[1]) : ""
                }
            }
        }
        guard hash == nil else { throw GitBlameFailure.format }; return output
    }
    private static func validTimezone(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[0] == 43 || bytes[0] == 45,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) else { return false }
        return (bytes[1] - 48) * 10 + bytes[2] - 48 < 24 && (bytes[3] - 48) * 10 + bytes[4] - 48 < 60
    }
}
extension GitRepository {
    /// Only parents that changed an existing origin file are relevant, matching
    /// TortoiseBlame's menu gates. Preserve each parent's old rename path.
    public func blameParentComparisons(revision: String, path: String) throws -> [GitBlameParentComparison] {
        let file = try historicalFile(revision: revision, path: path)
        guard case .revision(let hash) = file.revision, ["100644", "100755"].contains(file.mode ?? "") else { throw GitBlameFailure.unsupported }
        let parents = try run(["rev-list", "--parents", "-n", "1", hash]).text.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        var result: [GitBlameParentComparison] = []
        for (index, parent) in parents.enumerated() {
            let range = try revisionComparison(from: .revision(parent), to: .revision(hash))
            guard let changed = range.files.first(where: { $0.path == path }), !changed.isSubmodule,
                  ["M", "R", "T"].contains(String(changed.action.prefix(1))) else { continue }
            let comparison = RevisionComparisonSnapshot(root: root, from: range.from, to: range.to,
                fromDetails: range.fromDetails, toDetails: range.toDetails, files: [changed], options: range.options)
            result.append(GitBlameParentComparison(parentNumber: index + 1, revision: parent,
                path: changed.oldPath ?? changed.path, comparison: comparison))
        }
        return result
    }
    public func blame(path: String, revision: String = "HEAD", options: GitBlameOptions = GitBlameOptions()) throws -> GitBlameSnapshot {
        let content = try historicalFile(revision: revision, path: path)
        guard ["100644", "100755"].contains(content.mode ?? ""),
              case .revision(let hash) = content.revision else { throw GitBlameFailure.unsupported }
        let encoding = try GitBlameEncoding.detect(content.bytes)
        var args = ["-c", "blame.blankBoundary=false", "blame", "--line-porcelain", "--no-progress", "--no-textconv"]
        if options.ignoreWhitespace { args.append("-w") }
        if options.detectMoved { args.append("-M") }
        if options.detectCopied { args.append("-C") }
        let lines = try GitBlameParser.parse(run(args + [hash, "--", path]).stdout, encoding: encoding)
        // Git appends LF to each porcelain record even when the source has no final LF.
        // Compare individual source bytes to the pinned blob, preserving CR, tabs and BOM.
        let records = content.bytes.split(separator: UInt8(10), omittingEmptySubsequences: false)
        var source = records.map { Data($0) }
        if content.bytes.isEmpty || content.bytes.last == 10 { source.removeLast() }
        guard source == lines.map(\.sourceBytes) else { throw GitBlameFailure.format }
        return GitBlameSnapshot(revision: hash, path: path, contents: content.bytes, encoding: encoding, lines: lines)
    }
}
