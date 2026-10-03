import Foundation

public enum FileState: String, Codable, CaseIterable, Sendable {
    case normal, modified, added, deleted, untracked, ignored, conflicted
    public var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .modified: return "exclamationmark.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .ignored: return "nosign"
        case .conflicted: return "bolt.trianglebadge.exclamationmark.fill"
        }
    }
}

public struct StatusEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let index: Character
    public let worktree: Character
    public var staged: Bool { index != " " && index != "?" && index != "!" }
    public var state: FileState {
        let code = String([index, worktree])
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(code) { return .conflicted }
        if code == "??" { return .untracked }
        if code == "!!" { return .ignored }
        if code.contains("D") { return .deleted }
        if code.contains("A") { return .added }
        return .modified
    }
    /// Porcelain v1 -z uses NUL-terminated raw paths and destination before source for renames.
    public static func parse(_ data: Data) -> [StatusEntry] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var result: [StatusEntry] = []
        var i = 0
        while i < records.count {
            let bytes = Array(records[i]); i += 1
            guard bytes.count >= 4, bytes[2] == 32 else { continue }
            let x = Character(UnicodeScalar(bytes[0])), y = Character(UnicodeScalar(bytes[1]))
            let path = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            var source: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < records.count { source = String(decoding: records[i], as: UTF8.self); i += 1 }
            }
            result.append(StatusEntry(path: path, originalPath: source, index: x, worktree: y))
        }
        return result
    }
}

public struct LogEntry: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let author: String
    public let date: String
    public let subject: String
    public var parents: [String] = []
    public var email: String = ""
    public var message: String = ""
    public var references: [RevisionReference] = []
    public var isHead = false
    public init(hash: String, author: String, date: String, subject: String, parents: [String] = [], email: String = "", message: String = "") {
        self.hash = hash; self.author = author; self.date = date; self.subject = subject
        self.parents = parents; self.email = email; self.message = message
    }
    public static func parseHistory(_ data: Data) -> [LogEntry] {
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var entries: [LogEntry] = []
        var i = 0
        while i + 6 < fields.count {
            let hash = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty {
                entries.append(LogEntry(hash: hash, author: fields[i+2], date: fields[i+4], subject: fields[i+5],
                    parents: fields[i+1].split(separator: " ").map(String.init), email: fields[i+3], message: fields[i+6]))
            }
            i += 7
        }
        return entries
    }
    public static func parse(_ data: Data) -> [LogEntry] {
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var entries: [LogEntry] = []
        var i = 0
        while i + 3 < fields.count {
            let hash = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty { entries.append(LogEntry(hash: hash, author: fields[i+1], date: fields[i+2], subject: fields[i+3])) }
            i += 4
        }
        return entries
    }
}

public struct GitFailure: LocalizedError, Sendable {
    public let arguments: [String]
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "git \(arguments.first ?? "") failed (\(code)):\n\(message)" }
}

public struct GitResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout + stderr, as: UTF8.self) }
}
