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
}
public struct GitBlameSnapshot: Sendable {
    public let revision: String
    public let path: String
    public let contents: Data
    public let lines: [GitBlameLine]
}
public struct GitBlameParentComparison: Identifiable, Sendable {
    public var id: String { revision }
    public let parentNumber: Int
    public let revision: String
    public let path: String
    public let comparison: RevisionComparisonSnapshot
}
public enum GitBlameFailure: LocalizedError {
    case format, unsupported
    public var errorDescription: String? {
        switch self { case .format: return "Git returned incomplete or invalid line annotation data."; case .unsupported: return "Blame currently supports regular UTF-8 text files." }
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
    public static func parse(_ data: Data) throws -> [GitBlameLine] {
        guard data.isEmpty || data.last == 10, !data.contains(0) else { throw GitBlameFailure.format }
        var output: [GitBlameLine] = [], hash: String?, original = 0, final = 0, fields: [String: String] = [:]
        let records = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, bytes) in records.enumerated() {
            if bytes.isEmpty, index == records.count - 1 { continue }
            guard let text = String(data: Data(bytes), encoding: .utf8) else { throw GitBlameFailure.unsupported }
            if bytes.first == 9 {
                guard let revisionHash = hash, let author = fields["author"], let mail = fields["author-mail"],
                      let seconds = fields["author-time"].flatMap(Int64.init), let timezone = fields["author-tz"], validTimezone(timezone),
                      let summary = fields["summary"], let path = fields["filename"], final == output.count + 1 else { throw GitBlameFailure.format }
                output.append(GitBlameLine(hash: revisionHash, originalLine: original, number: final, author: author,
                    email: mail.hasPrefix("<") && mail.hasSuffix(">") ? String(mail.dropFirst().dropLast()) : mail,
                    date: Date(timeIntervalSince1970: TimeInterval(seconds)), timezone: timezone, summary: summary,
                    filename: try filename(path), boundary: fields["boundary"] != nil, source: String(text.dropFirst())))
                // line-porcelain repeats metadata for every source line.
                fields = [:]; hash = nil
            } else if hash == nil {
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
        guard ["100644", "100755"].contains(content.mode ?? ""), !content.bytes.contains(0), String(data: content.bytes, encoding: .utf8) != nil,
              case .revision(let hash) = content.revision else { throw GitBlameFailure.unsupported }
        var args = ["-c", "blame.blankBoundary=false", "blame", "--line-porcelain", "--no-progress", "--no-textconv"]
        if options.ignoreWhitespace { args.append("-w") }
        if options.detectMoved { args.append("-M") }
        if options.detectCopied { args.append("-C") }
        let lines = try GitBlameParser.parse(run(args + [hash, "--", path]).stdout)
        // Git appends LF to each porcelain record even when the source has no final LF.
        // Compare individual source bytes to the pinned blob, preserving CR, tabs and BOM.
        let records = content.bytes.split(separator: UInt8(10), omittingEmptySubsequences: false)
        var source = records.map { Data($0) }
        if content.bytes.isEmpty || content.bytes.last == 10 { source.removeLast() }
        guard source == lines.map({ Data($0.source.utf8) }) else { throw GitBlameFailure.format }
        return GitBlameSnapshot(revision: hash, path: path, contents: content.bytes, lines: lines)
    }
}
