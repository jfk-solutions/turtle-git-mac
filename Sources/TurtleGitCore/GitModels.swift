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
    public static func == (lhs:Self,rhs:Self) -> Bool {
        GitReferenceName.equal(lhs.path,rhs.path) && lhs.originalPath.map { GitReferenceName($0) } == rhs.originalPath.map { GitReferenceName($0) } && lhs.index == rhs.index && lhs.worktree == rhs.worktree && lhs.hasUnversionedCopy == rhs.hasUnversionedCopy
    }
    public func hash(into hasher:inout Hasher) {
        hasher.combine(GitReferenceName(path)); hasher.combine(originalPath.map { GitReferenceName($0) })
        hasher.combine(index); hasher.combine(worktree); hasher.combine(hasUnversionedCopy)
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
        var combined: [StatusEntry] = [], positions: [GitReferenceName: Int] = [:]
        for entry in result {
            guard let position = positions[GitReferenceName(entry.path)] else { positions[GitReferenceName(entry.path)] = combined.count; combined.append(entry); continue }
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

/// Parse Git's own global-option grammar before identifying an operation.
/// Values and positional paths never become command/configuration identities.
public struct GitCommandIdentity:Sendable {
    public let command:String?
    public let arguments:[String]
    public let configurationKeys:[String]
    public init(_ argv:[String]) {
        var index=0,keys:[String]=[],found:String?,tail:[String]=[]
        let values:Set<String>=["-c","-C","--git-dir","--work-tree","--namespace","--config-env","--shallow-file","--attr-source"]
        let flags:Set<String>=["-p","--paginate","-P","--no-pager","--no-lazy-fetch","--no-replace-objects","--bare","--literal-pathspecs","--no-literal-pathspecs","--glob-pathspecs","--noglob-pathspecs","--icase-pathspecs","--no-optional-locks","--no-advice"]
        func configKey(_ value:String) {keys.append(String(value.prefix{ $0 != "=" }).lowercased())}
        while index<argv.count {
            let token=argv[index]
            if !token.hasPrefix("-") {found=token;tail=Array(argv.dropFirst(index+1));break}
            if ["--help","-h","--version","-v"].contains(token) {found=["--help","-h"].contains(token) ? "help":"version";tail=Array(argv.dropFirst(index+1));break}
            if flags.contains(token) {index+=1;continue}
            if values.contains(token) {
                guard index+1<argv.count else{break}
                if token=="-c" || token=="--config-env" {configKey(argv[index+1])}
                index+=2;continue
            }
            if let equals=token.firstIndex(of:"=") {
                let option=String(token[..<equals])
                if ["--git-dir","--work-tree","--namespace","--config-env","--attr-source","--exec-path"].contains(option) {
                    if option=="--config-env" {configKey(String(token[token.index(after:equals)...]))}
                    index+=1;continue
                }
                if option=="--list-cmds" {found="--list-cmds";break}
            }
            if ["--exec-path","--html-path","--man-path","--info-path"].contains(token) {found=token;break}
            // Unknown or incomplete options are not a license to guess their value.
            break
        }
        command=found;arguments=tail;configurationKeys=keys
    }
    public func overridesConfiguration(_ key:String)->Bool {configurationKeys.contains(key.lowercased())}
    public var displayName:String? {
        guard let command,!command.isEmpty,command.utf8.count<=128,
              command.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else{return nil}
        let subcommands:[String:Set<String>]=[
            "svn":["clone","fetch","rebase","dcommit","info","init"],
            "stash":["push","save","pop","apply","drop","clear","list","show","branch","create","store"],
            "remote":["add","remove","rename","set-url","update","prune","show"],
            "worktree":["add","move","remove","prune","lock","unlock","list","repair"],
            "submodule":["add","update","sync","init","deinit","status","foreach","absorbgitdirs"],
            "lfs":["fetch","pull","push","lock","locks","unlock","install","uninstall","track","untrack","ls-files","status"],
            "bisect":["start","reset","run","good","bad","skip","log","replay"],
            "notes":["add","append","edit","remove","merge","show","list","copy","prune"]]
        if let first=arguments.first,subcommands[command]?.contains(first)==true {return command+" "+first}
        return command
    }
}

public struct GitFailure: LocalizedError, Sendable {
    public let arguments:[String]
    public let code:Int32
    public let message:String
    /// The failing command's output reached its supplied live-output callback.
    /// A progress consumer may mark this after presenting its bounded fallback.
    public let outputWasDelivered:Bool
    public let standardError:Data?
    public init(arguments:[String],code:Int32,message:String,outputWasDelivered:Bool=false,standardError:Data?=nil) {
        self.arguments=arguments;self.code=code;self.message=message;self.outputWasDelivered=outputWasDelivered;self.standardError=standardError
    }
    public var identity:GitCommandIdentity {GitCommandIdentity(arguments)}
    public var summary:String {identity.displayName.map{"git \($0) failed (\(code))"} ?? "Git command failed (\(code))"}
    public var diagnosticText:String {if let standardError,!standardError.isEmpty {return String(decoding:standardError,as:UTF8.self)};return message}
    public var errorDescription:String? {summary+":\n"+message}
    public func markingOutputDelivered()->Self {.init(arguments:arguments,code:code,message:message,outputWasDelivered:true,standardError:standardError)}
}

public struct GitResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout + stderr, as: UTF8.self) }
}
