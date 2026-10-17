// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// TortoiseProc's primary dialog entry points. Values remain editable input;
/// neither a command line nor a file URL grants sandbox access or runs a mutation.
public struct PrimaryCommandInvocation: Sendable {
    public let request: FinderRequest
    public let message: String?
    public let messageFile: URL?
    public let issueID: String?
    public let wholeProject: Bool
    public let historyExpression: String?
    public let selectedRevision: String?
    public let historyLimit: HistoryLimitScope?
    public let search: String?
    public let searchFields: HistorySearchFields?
    public let searchRegex: Bool?
    public let diffFrom: String?
    public let diffTo: String?

    /// Excludes argv[0]. Legacy /path separates selections with '*'; native
    /// repeated --path arguments are literal, including asterisks and newlines.
    /// Without an explicit command, Launch Services arguments are left alone.
    public static func parse(arguments: [String], currentDirectory: String) throws -> Self? {
        let hasCommand = arguments.contains { value in
            let key = value.lowercased()
            return key == "--command" || key.hasPrefix("--command=") || key.hasPrefix("/command:")
        }
        guard hasCommand else { return nil }
        let flags: Set<String> = ["wholeproject", "alternative", "findtext", "findregex"]
        let valued: Set<String> = ["command", "path", "path2", "logmsg", "logmsgfile", "bugid", "startrev", "endrev", "revstart", "revend", "range", "rev", "limit", "findstring", "findtype"]
        var values: [String: String] = [:], paths: [String] = [], index = 0
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            guard !argument.contains("\0") else { throw Failure("Command arguments cannot contain NUL.") }
            let legacy = argument.hasPrefix("/")
            guard legacy || argument.hasPrefix("--") else { throw Failure("Unexpected command argument: " + argument) }
            let body = String(argument.dropFirst(legacy ? 1 : 2)), separator: Character = legacy ? ":" : "="
            let parts = body.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].lowercased()
            guard flags.contains(key) || valued.contains(key) else { throw Failure("Unsupported command option: " + key) }
            let value: String
            if flags.contains(key) {
                guard parts.count == 1 else { throw Failure("Option takes no value: " + key) }
                value = ""
            } else if parts.count == 2 { value = String(parts[1]) }
            else {
                guard !legacy, index < arguments.count else { throw Failure("Missing value for command option: " + key) }
                value = arguments[index]; index += 1
                guard !value.contains("\0") else { throw Failure("Command arguments cannot contain NUL.") }
            }
            if key == "path" {
                let items = legacy ? value.split(separator: "*", omittingEmptySubsequences: false).map(String.init) : [value]
                guard items.allSatisfy({ !$0.isEmpty }) else { throw Failure("A selected path is empty.") }
                paths += items
            } else {
                guard values[key] == nil else { throw Failure("Duplicate command option: " + key) }
                values[key] = value
            }
        }
        let action: RepositoryAction
        switch values["command"]?.lowercased() {
        case "commit": action = .commit
        case "repostatus", "status": action = .status
        case "log": action = .log
        case "diff": action = .diff
        case "revert": action = .revert
        case "resolve": action = .resolve
        default: throw Failure("Unsupported command: " + (values["command"] ?? ""))
        }
        var allowed: Set<String> = ["command"]
        switch action {
        case .commit: allowed.formUnion(["logmsg", "logmsgfile", "bugid", "wholeproject"])
        case .log: allowed.formUnion(["startrev", "endrev", "revstart", "revend", "range", "rev", "limit", "findstring", "findtype", "findtext", "findregex"])
        case .diff: allowed.formUnion(["path2", "alternative", "startrev", "endrev"])
        default: break
        }
        for key in values.keys.sorted() where !allowed.contains(key) { throw Failure("Option “" + key + "” is not valid for this command.") }
        if values["logmsg"] != nil && values["logmsgfile"] != nil { throw Failure("Use either logmsg or logmsgfile, not both.") }
        func file(_ path: String) throws -> URL {
            guard !path.isEmpty, !path.contains("\0"), currentDirectory.hasPrefix("/") else { throw Failure("A command path is empty or invalid.") }
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(path.hasPrefix("/") ? path : currentDirectory + "/" + path))
        }
        var urls = try (paths.isEmpty ? [currentDirectory] : paths).map(file)
        if let second = values["path2"] {
            guard urls.count == 1, values["startrev"] == nil, values["endrev"] == nil else { throw Failure("path2 needs one selected file and cannot be combined with revisions.") }
            urls.append(try file(second))
            guard FinderRequest.normalizedSelection(urls).count == 2 else { throw Failure("Select two different comparison files.") }
        }
        func revision(_ value: String) throws -> String {
            guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(where: { $0.isWhitespace }), !value.contains("\0") else { throw Failure("Invalid command revision: " + value) }
            return value
        }
        let start = values["startrev"] ?? values["revstart"], end = values["endrev"] ?? values["revend"]
        var expression: String?
        if action == .log {
            let raw = values["range"] ?? start.map { $0 + ".." + (end ?? "HEAD") } ?? end
            if let raw {
                guard let selection = HistoryReferenceSelection(expression: raw) else { throw Failure("Invalid Log revision expression.") }
                switch selection {
                case .tips(let tips): _ = try tips.map(revision)
                case .range(let range): _ = try revision(range.from); _ = try revision(range.to)
                }
                expression = selection.expression
            }
        }
        if action == .diff, (start == nil) != (end == nil) { throw Failure("Revision comparison requires both startrev and endrev.") }
        let from = action == .diff ? try start.map(revision) : nil, to = action == .diff ? try end.map(revision) : nil
        let selected = try values["rev"].map(revision)
        var limit: HistoryLimitScope?
        if let raw = values["limit"]?.lowercased() {
            let digits = raw.prefix(while: { $0.isASCII && $0.isNumber }), suffix = raw.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            guard let number = UInt32(digits), number <= UInt32(Int32.max) else { throw Failure("Invalid Log limit.") }
            let scale: HistoryLimitScale
            switch suffix {
            case "", "commit", "commits": scale = number == 0 ? .noLimit : .commits
            case "week", "weeks": scale = .weeks
            case "month", "months": scale = .months
            case "year", "years": scale = .years
            default: throw Failure("Invalid Log limit unit.")
            }
            guard number > 0 || scale == .noLimit else { throw Failure("A dated Log limit must be positive.") }
            limit = HistoryLimitScope(defaults: HistoryLimitDefaults(scale: scale, number: number))
        }
        var fields: HistorySearchFields?
        if let raw = values["findtype"] {
            guard let mask = UInt16(raw), mask == 0xFFFF || mask & ~0x07FF == 0 else { throw Failure("Invalid Log findtype mask.") }
            let mapping: [(UInt16, HistorySearchFields)] = [(1,.messages),(2,.paths),(4,.authors),(8,.revisions),(32,.bugIDs),(64,.subject),(128,.referenceNames),(256,.emails),(512,.notes),(1024,.tagInfo)]
            fields = mapping.reduce(into: HistorySearchFields()) { result, item in if mask & item.0 != 0 { result.formUnion(item.1) } }
        }
        return Self(request: FinderRequest(action: action, paths: urls, alternateTool: action == .diff ? values["alternative"] != nil : nil), message: values["logmsg"], messageFile: try values["logmsgfile"].map(file), issueID: values["bugid"], wholeProject: values["wholeproject"] != nil, historyExpression: expression, selectedRevision: selected, historyLimit: limit, search: values["findstring"], searchFields: fields, searchRegex: values["findregex"] != nil ? true : values["findtext"] != nil ? false : nil, diffFrom: from, diffTo: to)
    }

    /// Read only after the caller has acquired the requested file's permission.
    /// A bounded, cancellable descriptor read refuses directories and devices.
    public func readMessageFile(cancellation: OperationCancellation) throws -> String? {
        guard let messageFile else { return message }
        try cancellation.check()
        let descriptor = open(messageFile.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure("The commit message must be a regular text file.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try cancellation.check()
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.EIO) }
            if count == 0 { break }
            guard data.count + count <= 16 * 1024 * 1024 else { throw Failure("The commit message file exceeds 16 MiB.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        // CStringUtils::ReadStringFromTextFile uses GetUnicode(CP_UTF8),
        // including replacement for malformed UTF-8 and a BOM as content.
        return String(decoding: data, as: UTF8.self)
    }
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
