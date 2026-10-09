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
    /// `git rm --cached` can emit D and ??/!! records for the same literal path.
    /// Keep one list identity while retaining the copy outside the index.
    public var hasUnversionedCopy = false
    public var isDeleteModifyConflict: Bool { ["DU", "UD", "AU", "UA"].contains(String([index, worktree])) }
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
    /// The status-list menu gates base/unified comparisons by the marked row.
    /// Unversioned and ignored rows still support their double-click preview.
    public var canCompareWithBaseFromStatusList: Bool {
        ![FileState.untracked, .ignored].contains(state) && !hasUnversionedCopy
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
        var combined: [StatusEntry] = [], positions: [String: Int] = [:]
        for entry in result {
            guard let position = positions[entry.path] else { positions[entry.path] = combined.count; combined.append(entry); continue }
            let previous = combined[position]
            let local = [FileState.untracked, .ignored].contains(entry.state)
            let previousLocal = [FileState.untracked, .ignored].contains(previous.state)
            var versioned = previousLocal && !local ? entry : previous
            if (local || previousLocal) && versioned.index == "D" { versioned.hasUnversionedCopy = true }
            combined[position] = versioned
        }
        return combined
    }
}

public struct LogEntry: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let author: String
    public let date: String
    public let subject: String
    public var parents: [String] = []
    /// Git's history-simplified edges; `parents` always describes the actual commit.
    public var graphParents: [String]?
    public var email: String = ""
    public var message: String = ""
    public var committer: String = ""
    public var committerEmail: String = ""
    public var committerDate: String = ""
    public var notes: String = ""
    public var tagInfo: String = ""
    public var issueIDs: String = ""
    public var references: [RevisionReference] = []
    public var isHead = false
    /// Excluded range endpoint emitted by Git --boundary (the source minus mark).
    public var isBoundary = false
    /// Display-filter result when a history read retains the complete walked batch.
    public var matchesHistoryFilter = true
    /// GitRev splits the raw message at the first LF, not Git's folded %s paragraph.
    public static func splitHistoryMessage(_ message: String) -> (subject: String, body: String) {
        let raw = message as NSString
        let newline = raw.range(of: "\n")
        guard newline.location != NSNotFound else { return (message, "") }
        return (raw.substring(to: newline.location), raw.substring(from: NSMaxRange(newline)))
    }
    public var historySubject: String { message.isEmpty ? subject : Self.splitHistoryMessage(message).subject }
    public var historyBody: String { Self.splitHistoryMessage(message).body }
    /// Keep raw message and Git summary metadata unchanged.
    public func logLine(fullMessage: Bool = false) -> String {
        guard !hash.isEmpty, !message.isEmpty else { return subject }
        let parts = Self.splitHistoryMessage(message)
        guard fullMessage, !parts.body.isEmpty else { return parts.subject }
        return (parts.subject + " " + parts.body).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
    /// CGitLogListBase's Subjects/Messages clipboard formats, including CRLF separators.
    public static func historyClipboard(_ entries: [LogEntry], subjectsOnly: Bool) -> String {
        entries.map { entry in
            if subjectsOnly { return "* " + entry.historySubject.trimmingCharacters(in: .whitespacesAndNewlines) + "\r\n\r\n" }
            let heading = String(entry.historySubject.reversed().drop(while: { $0.isWhitespace }).reversed())
            let body = entry.historyBody.replacingOccurrences(of: "\n", with: "\r\n")
            let trimmedBody = String(body.reversed().drop(while: { $0.isWhitespace }).reversed())
            return "* " + heading + "\r\n" + trimmedBody + "\r\n\r\n"
        }.joined()
    }
    public init(hash: String, author: String, date: String, subject: String, parents: [String] = [], email: String = "", message: String = "", committer: String = "", committerEmail: String = "", committerDate: String = "") {
        self.hash = hash; self.author = author; self.date = date; self.subject = subject
        self.parents = parents; self.email = email; self.message = message
        self.committer = committer; self.committerEmail = committerEmail; self.committerDate = committerDate
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
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout + stderr, as: UTF8.self) }
}
