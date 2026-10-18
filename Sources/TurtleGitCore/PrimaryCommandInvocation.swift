// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// TortoiseProc's primary dialog entry points. Values remain editable input;
/// neither a command line nor a file URL grants sandbox access or runs a mutation.
public struct PrimaryCommandInvocation: Sendable {
    public private(set) var request: FinderRequest
    public private(set) var pathFile: URL?
    public let deletePathFile: Bool
    public let nulPathFile: Bool
    private let currentDirectory: String
    private let secondaryPath: URL?
    public let outputFile: URL?
    public let unified: Bool
    public let line: Int?
    public let sourceURL: String?
    public let exactClonePath: Bool
    public let remote: String?
    public let creationName: String?
    public let pushBranch: String?
    public let reflogReference: String?
    public let upstream: String?
    public let forceRebase: Bool
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
        let flags: Set<String> = ["wholeproject", "alternative", "findtext", "findregex", "deletepathfile", "pathfile0", "unified", "exactpath", "force"]
        let valued: Set<String> = ["command", "path", "path2", "logmsg", "logmsgfile", "bugid", "startrev", "endrev", "revstart", "revend", "range", "rev", "limit", "findstring", "findtype", "pathfile", "outfile", "line", "url", "remote", "name", "branch", "ref", "upstream"]
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
        case "clone": action = .clone
        case "fetch": action = .fetch
        case "pull": action = .pull
        case "push": action = .push
        case "branch": action = .branch
        case "tag": action = .tag
        case "switch": action = .switchBranch
        case "refbrowse": action = .referenceBrowser
        case "repobrowser": action = .repositoryBrowser
        case "reflog": action = .reflog
        case "rebase": action = .rebase
        default: throw Failure("Unsupported command: " + (values["command"] ?? ""))
        }
        var allowed: Set<String> = ["command", "pathfile", "deletepathfile", "pathfile0"]
        switch action {
        case .commit: allowed.formUnion(["logmsg", "logmsgfile", "bugid", "wholeproject"])
        case .log: allowed.formUnion(["startrev", "endrev", "revstart", "revend", "range", "rev", "limit", "findstring", "findtype", "findtext", "findregex", "outfile"])
        case .diff: allowed.formUnion(["path2", "alternative", "startrev", "endrev", "unified", "line"])
        case .clone: allowed.formUnion(["url", "exactpath"])
        case .fetch: allowed.insert("remote")
        case .push: allowed.insert("branch")
        case .branch, .tag: allowed.formUnion(["rev", "name"])
        case .switchBranch, .repositoryBrowser: allowed.insert("rev")
        case .reflog: allowed.insert("ref")
        case .rebase: allowed.formUnion(["upstream", "force"])
        default: break
        }
        for key in values.keys.sorted() where !allowed.contains(key) { throw Failure("Option “" + key + "” is not valid for this command.") }
        if values["logmsg"] != nil && values["logmsgfile"] != nil { throw Failure("Use either logmsg or logmsgfile, not both.") }
        func file(_ path: String) throws -> URL {
            guard !path.isEmpty, !path.contains("\0"), currentDirectory.hasPrefix("/") else { throw Failure("A command path is empty or invalid.") }
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(path.hasPrefix("/") ? path : currentDirectory + "/" + path))
        }
        if values["pathfile"] != nil && !paths.isEmpty { throw Failure("Use either path or pathfile, not both.") }
        if values["pathfile"] == nil && (values["deletepathfile"] != nil || values["pathfile0"] != nil) { throw Failure("Path-file options require pathfile.") }
        var line: Int?
        if let raw = values["line"] {
            guard let number = Int(raw), (0...Int(Int32.max)).contains(number) else { throw Failure("Invalid comparison line number.") }
            line = number == 0 ? nil : number
        }
        var urls = try (paths.isEmpty ? [currentDirectory] : paths).map(file)
        if let second = values["path2"] {
            guard urls.count == 1, values["startrev"] == nil, values["endrev"] == nil else { throw Failure("path2 needs one selected file and cannot be combined with revisions.") }
            if values["pathfile"] == nil { urls.append(try file(second)) }
            guard values["pathfile"] != nil || FinderRequest.normalizedSelection(urls).count == 2 else { throw Failure("Select two different comparison files.") }
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
        let selected = try values["rev"].flatMap { $0.isEmpty ? nil : try revision($0) }
        let reflog = try values["ref"].flatMap { $0.isEmpty ? nil : try revision($0) }
        let upstream = try values["upstream"].flatMap { $0.isEmpty ? nil : try revision($0) }
        if action == .clone && urls.count != 1 { throw Failure("Select one Clone destination.") }
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
        return Self(request: FinderRequest(action: action, paths: urls, alternateTool: action == .diff ? values["alternative"] != nil : nil), pathFile: try values["pathfile"].map(file), deletePathFile: values["deletepathfile"] != nil, nulPathFile: values["pathfile0"] != nil, currentDirectory: currentDirectory, secondaryPath: try values["path2"].map(file), outputFile: try values["outfile"].map(file), unified: values["unified"] != nil, line: line, sourceURL: values["url"], exactClonePath: values["exactpath"] != nil, remote: values["remote"], creationName: values["name"], pushBranch: values["branch"], reflogReference: reflog, upstream: upstream, forceRebase: values["force"] != nil, message: values["logmsg"], messageFile: try values["logmsgfile"].map(file), issueID: values["bugid"], wholeProject: values["wholeproject"] != nil, historyExpression: expression, selectedRevision: selected, historyLimit: limit, search: values["findstring"], searchFields: fields, searchRegex: values["findregex"] != nil ? true : values["findtext"] != nil ? false : nil, diffFrom: from, diffTo: to)
    }

    /// Read only after the caller has acquired the requested file's permission.
    /// A bounded, cancellable descriptor read refuses directories and devices.
    public func readMessageFile(cancellation: OperationCancellation) throws -> String? {
        guard let messageFile else { return message }
        let (data, _) = try Self.readFile(messageFile, cancellation: cancellation)
        // CStringUtils::ReadStringFromTextFile uses GetUnicode(CP_UTF8),
        // including replacement for malformed UTF-8 and a BOM as content.
        return String(decoding: data, as: UTF8.self)
    }
    private static func readFile(_ file: URL, cancellation: OperationCancellation, noFollow: Bool = false) throws -> (Data, stat) {
        try cancellation.check()
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure("A command input must be a regular file.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try cancellation.check()
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.EIO) }
            if count == 0 { break }
            guard data.count + count <= 16 * 1024 * 1024 else { throw Failure("The command input file exceeds 16 MiB.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, info)
    }
    /// Resolve only after the caller authorizes the list file. Its contents are
    /// selections, never grants for the repositories or files they name.
    public func resolvingPathFile(cancellation: OperationCancellation) throws -> Self {
        guard let pathFile else { return self }
        let (data, identity) = try Self.readFile(pathFile, cancellation: cancellation, noFollow: deletePathFile)
        let names: [String]
        if nulPathFile {
            var records = data.split(separator: 0, omittingEmptySubsequences: false)
            if records.last?.isEmpty == true { records.removeLast() }
            guard records.allSatisfy({ !$0.isEmpty }) else { throw Failure("The NUL path file contains an empty selection.") }
            names = try records.map { guard let name = String(data: Data($0), encoding: .utf8) else { throw Failure("The path file is not valid UTF-8.") }; return name }
        } else {
            let text: String?
            if data.starts(with: [0xFF,0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
            else if data.starts(with: [0xFE,0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
            else if data.contains(0) { text = String(data: data, encoding: .utf16LittleEndian) }
            else { text = String(data: data.starts(with: [0xEF,0xBB,0xBF]) ? data.dropFirst(3) : data[...], encoding: .utf8) }
            guard let text, !text.contains("\0") else { throw Failure("The path list is not valid UTF-8 or UTF-16 text.") }
            names = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        }
        guard !names.isEmpty, names.count <= 4096 else { throw Failure("Select between one and 4096 paths in a command file.") }
        var urls = names.map { FileTransferPaths.fileURL(FileTransferPaths.lexicalPath($0.hasPrefix("/") ? $0 : currentDirectory + "/" + $0)) }
        if let secondaryPath {
            guard urls.count == 1 else { throw Failure("path2 requires one primary path in the path file.") }
            urls.append(secondaryPath)
            guard FinderRequest.normalizedSelection(urls).count == 2 else { throw Failure("Select two different comparison files.") }
        }
        if request.action == .clone && urls.count != 1 { throw Failure("Select one Clone destination.") }
        try cancellation.check()
        if deletePathFile {
            var current = stat()
            guard lstat(pathFile.path, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino, current.st_mode & S_IFMT == S_IFREG else { throw Failure("The path file changed before it could be deleted.") }
            guard unlink(pathFile.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var resolved = self
        resolved.pathFile = nil
        resolved.request = FinderRequest(action: request.action, paths: urls, alternateTool: request.alternateTool)
        return resolved
    }
    /// Split a captured multi-repository transport selection without losing its
    /// presets or interpreting one root's paths relative to another repository.
    public func selecting(_ paths: [URL]) -> Self {
        var value = self
        value.request = FinderRequest(action: request.action, paths: paths, alternateTool: request.alternateTool)
        return value
    }
    public static func writeSelectedRevision(_ revision: String?, to file: URL, cancellation: OperationCancellation) throws {
        let value = revision ?? ""
        guard value.isEmpty || ((value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else { throw Failure("Invalid selected commit for command output.") }
        try cancellation.check()
        try Data(value.utf8).write(to: file, options: .atomic)
    }
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

extension GitRepository {
    /// The CLI unified route uses the same scoped Git content as native Diff;
    /// literal pathspecs and command-only precomposition preserve exact names.
    public func commandUnifiedDiff(from: String?, to: String?, paths: [String], cancellation: OperationCancellation) throws -> Data {
        try cancellation.check()
        guard (from == nil) == (to == nil), paths.allSatisfy({ !$0.contains("\0") }) else { throw RevisionComparisonFailure.range }
        var arguments = ["--literal-pathspecs", "-c", "core.precomposeunicode=false", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary"] + diffDetection.comparisonArguments
        if let from, let to { arguments += [try rebaseCommit(from, cancellation: cancellation).hash, try rebaseCommit(to, cancellation: cancellation).hash] }
        else {
            let head = try run(["rev-parse", "--verify", "HEAD"], successfulExitCodes: 0...128, cancellation: cancellation)
            arguments += head.exitCode == 0 ? ["HEAD"] : ["--cached"]
        }
        return try run(arguments + ["--"] + paths.filter { $0 != "." }, cancellation: cancellation).stdout
    }
}
