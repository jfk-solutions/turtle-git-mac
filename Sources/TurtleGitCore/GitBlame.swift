import Foundation
import CoreFoundation

public enum GitBlameDetectionMode: Int, CaseIterable, Identifiable, Sendable {
    case disabled, withinFile, modifiedFiles, fileCreation, existingFiles
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .withinFile: return "Within file"
        case .modifiedFiles: return "From modified files"
        case .fileCreation: return "At file creation"
        case .existingFiles: return "From existing files"
        }
    }
    public var betweenFiles: Bool { rawValue >= Self.modifiedFiles.rawValue }
}
public struct GitBlameOptions: Equatable, Sendable {
    public var ignoreWhitespace = false
    public var onlyFirstParent = false
    public var showCompleteLog = true
    public var followRenames = false
    public var detectionMode = GitBlameDetectionMode.disabled
    public var withinFileCharacters: UInt32 = 20
    public var betweenFileCharacters: UInt32 = 40
    public var encoding: GitBlameEncoding?
    public init() {}
    public var canShowCompleteLog: Bool { !detectionMode.betweenFiles && !onlyFirstParent }
    public var usesCompleteLog: Bool { canShowCompleteLog && showCompleteLog }
    public var usesFollowRenames: Bool { usesCompleteLog && followRenames }
    /// Settings clears unavailable choices; viewer menus retain the saved flags
    /// and use the effective gates while switching annotation modes.
    public mutating func normalizeLogSettings() {
        if !canShowCompleteLog { showCompleteLog = false }
        if !usesCompleteLog { followRenames = false }
    }
    var detectionArguments: [String] {
        switch detectionMode {
        case .disabled: return []
        case .withinFile: return ["-M\(withinFileCharacters)"]
        case .modifiedFiles: return ["-C\(betweenFileCharacters)"]
        case .fileCreation: return ["-C", "-C\(betweenFileCharacters)"]
        case .existingFiles: return ["-C", "-C", "-C\(betweenFileCharacters)"]
        }
    }
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
public struct GitBlameEncoding: Hashable, Identifiable, Sendable, CustomStringConvertible {
    public let id: UInt
    public let rawValue: String
    public var description: String { rawValue }
    public var windowsCodePage: UInt32 { CFStringConvertEncodingToWindowsCodepage(CFStringConvertNSStringEncodingToEncoding(id)) }
    public static let utf8 = GitBlameEncoding(id: String.Encoding.utf8.rawValue, rawValue: "UTF-8")
    public static let utf16LE = GitBlameEncoding(id: String.Encoding.utf16LittleEndian.rawValue, rawValue: "UTF-16 LE")
    public static let utf16BE = GitBlameEncoding(id: String.Encoding.utf16BigEndian.rawValue, rawValue: "UTF-16 BE")
    /// Offer installed codecs whose line delimiter is Git's byte LF. Decode
    /// legacy content as a whole so stateful encodings retain their shift state.
    public static let available: [GitBlameEncoding] = {
        var values = [utf8, utf16LE, utf16BE], seen = Set(values.map(\.id))
        guard let pointer = CFStringGetListOfAvailableEncodings() else { return values }
        var index = 0
        while pointer[index] != kCFStringEncodingInvalidId {
            let cf = pointer[index]; index += 1
            let raw = CFStringConvertEncodingToNSStringEncoding(cf), encoding = String.Encoding(rawValue: raw)
            guard !seen.contains(raw), "\n".data(using: encoding) == Data([10]),
                  "ASCII".data(using: encoding) == Data("ASCII".utf8) else { continue }
            seen.insert(raw)
            let name = CFStringGetNameOfEncoding(cf).map { $0 as String } ?? String.localizedName(of: encoding)
            let page = CFStringConvertEncodingToWindowsCodepage(cf)
            values.append(GitBlameEncoding(id: raw, rawValue: name + (page == kCFStringEncodingInvalidId ? "" : " (CP \(page))")))
        }
        return Array(values.prefix(3)) + values.dropFirst(3).sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }()
    func validate(_ bytes: Data) throws {
        if self == .utf16LE || self == .utf16BE {
            let bom: [UInt8] = self == .utf16LE ? [255, 254] : [254, 255]
            try Self.validateUTF16(bytes.starts(with: bom) ? bytes.dropFirst(2) : bytes, little: self == .utf16LE)
        } else {
            guard !bytes.contains(0), String(data: bytes, encoding: String.Encoding(rawValue: id)) != nil else { throw GitBlameFailure.unsupported }
        }
    }
    func legacyLines(_ bytes: Data) throws -> [String]? {
        guard self != .utf8, self != .utf16LE, self != .utf16BE else { return nil }
        guard let text = String(data: bytes, encoding: String.Encoding(rawValue: id)) else { throw GitBlameFailure.unsupported }
        var lines = Data(text.utf8).split(separator: UInt8(10), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if bytes.isEmpty || bytes.last == 10 { lines.removeLast() }
        return lines
    }
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
        if self != .utf16LE, self != .utf16BE {
            guard !raw.contains(0), let text = String(data: raw, encoding: String.Encoding(rawValue: id)) else { throw GitBlameFailure.unsupported }; return text
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
        switch self { case .format: return "Git returned incomplete or invalid line annotation data."; case .unsupported: return "The source is not valid for this encoding. Choose an encoding for a regular text file." }
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
        try parse(data, encoding: encoding, decodedSources: nil)
    }
    static func parse(_ data: Data, encoding: GitBlameEncoding, decodedSources: [String]?) throws -> [GitBlameLine] {
        guard data.isEmpty || data.last == 10 else { throw GitBlameFailure.format }
        var output: [GitBlameLine] = [], hash: String?, original = 0, final = 0, fields: [String: String] = [:]
        let records = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, bytes) in records.enumerated() {
            if bytes.isEmpty, index == records.count - 1 { continue }
            if bytes.first == 9 {
                guard let revisionHash = hash, let author = fields["author"], let mail = fields["author-mail"],
                      let seconds = fields["author-time"].flatMap(Int64.init), let timezone = fields["author-tz"], validTimezone(timezone),
                      let summary = fields["summary"], let path = fields["filename"], final == output.count + 1 else { throw GitBlameFailure.format }
                let source: String
                if let decodedSources {
                    guard decodedSources.indices.contains(final - 1) else { throw GitBlameFailure.format }
                    source = decodedSources[final - 1]
                } else { source = try encoding.decode(Data(bytes.dropFirst()), line: final) }
                output.append(GitBlameLine(hash: revisionHash, originalLine: original, number: final, author: author,
                    email: mail.hasPrefix("<") && mail.hasSuffix(">") ? String(mail.dropFirst().dropLast()) : mail,
                    date: Date(timeIntervalSince1970: TimeInterval(seconds)), timezone: timezone, summary: summary,
                    filename: try filename(path), boundary: fields["boundary"] != nil,
                    source: source, sourceBytes: Data(bytes.dropFirst())))
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
        guard hash == nil, decodedSources == nil || decodedSources?.count == output.count else { throw GitBlameFailure.format }; return output
    }
    private static func validTimezone(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[0] == 43 || bytes[0] == 45,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) else { return false }
        return (bytes[1] - 48) * 10 + bytes[2] - 48 < 24 && (bytes[3] - 48) * 10 + bytes[4] - 48 < 60
    }
}
extension GitRepository {
    public func blameHistory(_ snapshot: GitBlameSnapshot, options: GitBlameOptions) throws -> [LogEntry] {
        let format = "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00%ct%x00%cn%x00%ce%x00%cI%x00"
        func records(_ data: Data) throws -> [(LogEntry, Int64)] {
            let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
            var result: [(LogEntry, Int64)] = []
            var index = 0
            while index + 10 < fields.count {
                let hash = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hash.isEmpty, let timestamp = Int64(fields[index + 7]) else { throw GitBlameFailure.format }
                result.append((LogEntry(hash: hash, author: fields[index + 2], date: fields[index + 4], subject: fields[index + 5],
                    parents: fields[index + 1].split(separator: " ").map(String.init), email: fields[index + 3], message: fields[index + 6],
                    committer: fields[index + 8], committerEmail: fields[index + 9], committerDate: fields[index + 10]), timestamp))
                index += 11
            }
            return result
        }
        if options.usesCompleteLog {
            let args = ["log", "--encoding=UTF-8", "--topo-order", format] + (options.usesFollowRenames ? ["--follow"] : [])
            return try records(run(args + [snapshot.revision, "--", snapshot.path]).stdout).map { $0.0 }
        }
        let hashes = Set(snapshot.lines.map(\.hash)).sorted()
        var entries: [(LogEntry, Int64)] = []
        // Bound argv size for large files with many distinct originating commits.
        for start in stride(from: 0, to: hashes.count, by: 128) {
            entries += try records(run(["log", "--encoding=UTF-8", "--no-walk=unsorted", format] + Array(hashes[start..<min(start + 128, hashes.count)]) + ["--"]).stdout)
        }
        guard Set(entries.map { $0.0.hash }) == Set(hashes), entries.count == hashes.count else { throw GitBlameFailure.format }
        return entries.sorted { lhs, rhs in
            if lhs.0.parents.contains(rhs.0.hash) { return true }
            if rhs.0.parents.contains(lhs.0.hash) { return false }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.hash < rhs.0.hash
        }.map { $0.0 }
    }
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
        let encoding = try options.encoding ?? GitBlameEncoding.detect(content.bytes)
        try encoding.validate(content.bytes)
        var args = ["-c", "blame.blankBoundary=false", "blame", "--line-porcelain", "--no-progress", "--no-textconv"]
        if options.ignoreWhitespace { args.append("-w") }
        if options.onlyFirstParent { args.append("--first-parent") }
        args += options.detectionArguments
        let lines = try GitBlameParser.parse(run(args + [hash, "--", path]).stdout, encoding: encoding, decodedSources: try encoding.legacyLines(content.bytes))
        // Git appends LF to each porcelain record even when the source has no final LF.
        // Compare individual source bytes to the pinned blob, preserving CR, tabs and BOM.
        let records = content.bytes.split(separator: UInt8(10), omittingEmptySubsequences: false)
        var source = records.map { Data($0) }
        if content.bytes.isEmpty || content.bytes.last == 10 { source.removeLast() }
        guard source == lines.map(\.sourceBytes) else { throw GitBlameFailure.format }
        return GitBlameSnapshot(revision: hash, path: path, contents: content.bytes, encoding: encoding, lines: lines)
    }
}
