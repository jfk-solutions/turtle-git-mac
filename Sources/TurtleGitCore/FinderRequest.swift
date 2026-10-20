import Foundation
import Darwin

/// Native Services is an explicit first-use route, independent of Finder cache.
/// Its wire envelope conveys selection and tool choice, never repository access.
public enum FinderServiceCommand:String,CaseIterable,Hashable,Sendable {
    case log,commit,status,diff,clone,initialize
    case pull,fetch,push,synchronize,rebase,stash,stashApply,stashPop,stashList,switchBranch,merge,branch,tag
    case add,revert,resolve,resolveCurrent,resolveMine,resolveTheirs,blame,previousDiff,editConflict,ignore,ignoreMask,ignoreDelete,ignoreDeleteMask
    case rename,remove,removeKeep,clean
    case worktreeList,worktreeCreate,submoduleAdd,submoduleUpdate,submoduleSync,logSubmodule
    public static let maximumPaths=10000
    public static let maximumRequestBytes=1048576
    public struct Failure:LocalizedError,Sendable {
        public let message:String
        public var errorDescription:String? {message}
        public init(_ message:String){self.message=message}
    }
    public var action:RepositoryAction {RepositoryAction(rawValue:rawValue)!}
    /// The original six Services retain their established explicit-selection
    /// behavior. New repository Services apply MenuInfo's actual state clauses
    /// after the app obtains access and reads fresh repository/status metadata.
    public var requiresSourceEligibility:Bool {
        switch self {case .log,.commit,.status,.diff,.clone,.initialize:return false;default:return true}
    }
    /// Services has no separate Explorer folder context. Worktree List therefore
    /// requires one explicit folder even though MenuInfo permits a bare context
    /// without ONLYONE. New Worktree is the direct macOS source-root adaptation.
    public var requiresSingleSelection:Bool {
        switch self {
        case .clone,.initialize,.synchronize,.rebase,.stash,.stashApply,.stashPop,.stashList,.switchBranch,.merge,.branch,.tag,.blame,.previousDiff,.rename,.worktreeList,.worktreeCreate,.submoduleAdd,.logSubmodule:return true
        default:return false
        }
    }
    /// Dynamic Resolve/Ignore children inherit their parent's MenuInfo clauses.
    public var sourceAction:RepositoryAction {
        switch self {
        case .resolveCurrent,.resolveMine,.resolveTheirs:return .resolve
        case .ignoreMask:return .ignore
        case .ignoreDeleteMask:return .ignoreDelete
        default:return action
        }
    }
    public var capturesAlternateTool:Bool {self == .diff || self == .previousDiff || self == .editConflict}
    public func isEligible(flags:FinderShellFlags)->Bool {
        !requiresSourceEligibility || FinderShellRules.allows(sourceAction,flags:flags)
    }
    /// Called only after access and a fresh status read. Parent menu clauses
    /// alone do not establish usable conflict or ignore targets for children.
    public func isEligible(paths:[URL],snapshot:FinderSnapshot)->Bool {
        let paths=FinderRequest.normalizedSelection(paths)
        let flags=FinderShellRules.flags(paths:paths,snapshot:snapshot)
        guard !paths.isEmpty,(!requiresSingleSelection || paths.count==1),isEligible(flags:flags) else{return false}
        if self == .resolveCurrent || self == .resolveMine || self == .resolveTheirs {return snapshot.canResolve(paths)}
        if action.isIgnore {
            guard snapshot.canIgnore(paths,deleting:action.removesWhenIgnoring) else{return false}
            if action.ignoresByExtension {
                // InsertIgnoreSubmenus offers the multi-selection child even
                // when every extension is empty; rule generation skips those
                // names while Delete and Ignore still consumes the selection.
                if paths.count>1 {return true}
                let path=paths[0]
                return !flags.contains(.folder) && IgnoreOptions.extensionSuffix(for:path.path) != nil
            }
        }
        return true
    }
    public func request(paths:[URL],alternateTool:Bool?=nil)throws->FinderRequest {
        guard !paths.isEmpty,paths.count<=Self.maximumPaths else{throw Failure("Select between 1 and 10,000 files or folders for TurtleGit.")}
        guard capturesAlternateTool || alternateTool == nil else{throw Failure("The tool choice is valid only for Diff, Diff with previous version, or Edit conflicts.")}
        for path in paths {
            guard path.isFileURL,let parts=URLComponents(url:path,resolvingAgainstBaseURL:false),
                  parts.user==nil,parts.password==nil,parts.port==nil,parts.query==nil,parts.fragment==nil,
                  parts.host==nil || parts.host=="" || parts.host?.lowercased()=="localhost",
                  let decodedPath=parts.percentEncodedPath.removingPercentEncoding,!decodedPath.contains("\0"),
                  path.path.hasPrefix("/"),!path.path.contains("\0"),
                  !path.pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame}) else {
                throw Failure("Choose local files or folders outside Git's administrative directory.")
            }
        }
        let normalized=FinderRequest.normalizedSelection(paths)
        guard normalized.allSatisfy({!$0.pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame})}) else{throw Failure("Git's administrative directory cannot be selected.")}
        guard !requiresSingleSelection || normalized.count==1 else{throw Failure("Select one item for "+action.title)}
        if self == .clone || self == .initialize {
            guard normalized.count==1,normalized[0].path != "/",
                  let attributes=try? FileManager.default.attributesOfItem(atPath:normalized[0].path),attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw Failure("Select one existing directory for Clone or Create repository.")
            }
        }
        let request=FinderRequest(action:action,paths:normalized,alternateTool:alternateTool)
        _=try Self.envelope(request)
        return request
    }
    private static func envelope(_ request:FinderRequest)throws->URL {
        guard let url=request.url,var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else{throw Failure("The TurtleGit selection cannot be encoded.")}
        parts.host="service"
        guard let result=parts.url,result.absoluteString.utf8.count<=maximumRequestBytes else{throw Failure("The selected paths are too large. Select fewer items and try again.")}
        return result
    }
    public func serviceURL(paths:[URL],alternateTool:Bool?=nil)throws->URL {try Self.envelope(request(paths:paths,alternateTool:alternateTool))}
    public static func request(serviceURL:URL)throws->FinderRequest {
        guard serviceURL.absoluteString.utf8.count<=maximumRequestBytes,
              let parts=URLComponents(url:serviceURL,resolvingAgainstBaseURL:false),parts.scheme=="turtlegit",parts.host=="service",
              parts.user==nil,parts.password==nil,parts.port==nil,parts.fragment==nil,parts.path.isEmpty,
              let fields=parts.queryItems,fields.allSatisfy({["command","path","alternate"].contains($0.name)}),
              fields.filter({$0.name=="command"}).count==1,
              let value=fields.first(where:{$0.name=="command"})?.value,let command=Self(rawValue:value),
              fields.filter({$0.name=="path"}).count<=maximumPaths else{throw Failure("Invalid TurtleGit Services request.")}
        // Validate the raw selection before FinderRequest normalizes it. An
        // administrative component such as .git/../file must not disappear first.
        let pathFields=fields.filter{$0.name=="path"},toolFields=fields.filter{$0.name=="alternate"}
        guard pathFields.allSatisfy({$0.value != nil && $0.value?.hasPrefix("/")==true && $0.value?.contains("\0")==false}),
              toolFields.count<=1,toolFields.allSatisfy({$0.value=="0" || $0.value=="1"}) else{throw Failure("Invalid TurtleGit Services selection.")}
        return try command.request(paths:pathFields.compactMap(\.value).map{FileTransferPaths.fileURL($0)},alternateTool:toolFields.first.map{$0.value=="1"})
    }
}

/// A Finder request carries selection, never permission. Repeated path fields keep
/// spaces, Unicode, newlines and URL punctuation intact without delimiter guessing.
public struct FinderRequest: Sendable {
    public let action: RepositoryAction
    public let paths: [URL]
    public let sources: [URL]
    /// nil preserves legacy URL behavior; explicit false captures the default tool.
    public let alternateTool: Bool?
    /// Request Pull command presets remain editable input, never authorization.
    public let requestPullEnd: String?
    public let requestPullURL: String?
    /// One-use App Group receipt; never a path or authorization.
    public let clipboardPatch: String?
    public init(action: RepositoryAction, paths: [URL], sources: [URL] = [], alternateTool: Bool? = nil, requestPullEnd: String? = nil, requestPullURL: String? = nil, clipboardPatch: String? = nil) {
        self.action = action; self.alternateTool = alternateTool
        self.requestPullEnd = requestPullEnd; self.requestPullURL = requestPullURL; self.clipboardPatch = clipboardPatch
        self.paths = Self.normalizedSelection(paths)
        self.sources = Self.normalizedSelection(sources)
    }
    /// Menu eligibility and the captured request must use the same cardinality,
    /// order and literal-leaf normalization.
    public static func normalizedSelection(_ urls: [URL]) -> [URL] {
        var seen = GitPathSet()
        return urls.map(normalizedSelectionURL).filter { seen.insert($0.path).inserted }
    }
    private static func normalizedSelectionURL(_ url: URL) -> URL {
        guard url.isFileURL, url.path != "/" else { return url.standardizedFileURL }
        // Foundation may keep /private/tmp for a missing leaf while normalizing
        // its existing repository root to /tmp. Normalize the existing ancestor
        // and append missing components. Keep the selected leaf itself literal:
        // a tracked symlink is a Git path, not a request for its external target.
        let literal = FileTransferPaths.lexicalPath(url.path)
        var parentPath = FinderSnapshot.parentPath(literal)
        var components = [String(literal.utf8.split(separator:47).last.map { String(decoding:$0,as:UTF8.self) } ?? "")]
        while parentPath != "/", (try? FileManager.default.attributesOfItem(atPath:parentPath)) == nil {
            components.append(String(decoding:parentPath.utf8.split(separator:47).last!,as:UTF8.self))
            parentPath = FinderSnapshot.parentPath(parentPath)
        }
        let physicalParent = FileTransferPaths.fileURL(parentPath).standardizedFileURL.path
        // Unicode-only differences are filesystem aliases, not permission to
        // rewrite the captured Git namespace. Retain every literal component.
        let literalParent = physicalParent == parentPath ? parentPath : physicalParent
        let path = components.reversed().reduce(literalParent) { $0 + ($0 == "/" ? "":"/") + $1 }
        return FileTransferPaths.fileURL(path)
    }
    /// Direct Finder selection and reviewed destination use separate payload forms.
    /// Neither form conveys source/destination sandbox authority.
    public var isTransferSourceSelection: Bool {
        action == .transferFiles && sources.isEmpty && Self.validTransferPayload(action: action, paths: paths, sources: sources) && url != nil
    }
    public var isTransferDestinationReview: Bool {
        action == .transferFiles && !sources.isEmpty && Self.validTransferPayload(action: action, paths: paths, sources: sources) && url != nil
    }
    private static func validTransferPayload(action: RepositoryAction, paths: [URL], sources: [URL]) -> Bool {
        guard action.isFileTransfer else { return sources.isEmpty }
        let valid: (URL) -> Bool = { url in
            url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") &&
                !url.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame })
        }
        guard paths.allSatisfy(valid), sources.allSatisfy(valid) else { return false }
        if action == .transferFiles && sources.isEmpty {
            return (1...256).contains(paths.count) && paths.allSatisfy { $0.path != "/" }
        }
        return paths.count == 1 && (1...256).contains(sources.count) && sources.allSatisfy { $0.path != "/" }
    }
    public init?(url: URL) {
        guard url.scheme == "turtlegit", url.host == "action",
              let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              fields.filter({ $0.name == "command" }).count == 1,
              let command = fields.first(where: { $0.name == "command" })?.value,
              let action = RepositoryAction(rawValue: command), !action.isMenuHeader else { return nil }
        let toolFields=fields.filter {$0.name=="alternate"}
        guard toolFields.count <= 1,toolFields.allSatisfy({$0.value=="0" || $0.value=="1"}) else {return nil}
        let alternateTool=toolFields.first.map {$0.value=="1"}
        let endFields = fields.filter { $0.name == "endrev" }, urlFields = fields.filter { $0.name == "url" }
        guard endFields.count <= 1, urlFields.count <= 1,
              (endFields + urlFields).allSatisfy({ $0.value != nil && $0.value?.contains("\0") == false }),
              action == .requestPull || (endFields.isEmpty && urlFields.isEmpty) else { return nil }
        let clipboardFields = fields.filter { $0.name == "clipboardpatch" }
        guard clipboardFields.count <= 1, clipboardFields.allSatisfy({ field in
            guard action == .reviewPatch, let value = field.value else { return false }
            return value == FinderPatchHandoff.unavailable || FinderPatchHandoff.validReceipt(value)
        }) else { return nil }
        let paths = fields.filter { $0.name == "path" }.compactMap(\.value)
        guard (!paths.isEmpty || action.allowsEmptySelection), paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              paths.count == fields.filter({ $0.name == "path" }).count else { return nil }
        let sourceFields = fields.filter { $0.name == "source" }, sources = sourceFields.compactMap(\.value)
        guard sources.count == sourceFields.count, sources.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              Self.validTransferPayload(action: action, paths: paths.map { FileTransferPaths.fileURL($0) }, sources: sources.map { FileTransferPaths.fileURL($0) }),
              !action.isFileTransfer || url.absoluteString.utf8.count <= 131072 else { return nil }
        guard clipboardFields.isEmpty || paths.count == 1 else { return nil }
        self.init(action: action, paths: paths.map { FileTransferPaths.fileURL($0) }, sources: sources.map { FileTransferPaths.fileURL($0) }, alternateTool:alternateTool, requestPullEnd: endFields.first?.value, requestPullURL: urlFields.first?.value, clipboardPatch: clipboardFields.first?.value)
    }
    public var url: URL? {
        guard clipboardPatch == nil || (action == .reviewPatch && paths.count == 1 && (clipboardPatch == FinderPatchHandoff.unavailable || FinderPatchHandoff.validReceipt(clipboardPatch!))) else { return nil }
        guard !action.isMenuHeader, !paths.isEmpty || action.allowsEmptySelection,
              action == .requestPull || (requestPullEnd == nil && requestPullURL == nil),
              [requestPullEnd, requestPullURL].compactMap({ $0 }).allSatisfy({ !$0.contains("\0") }) else { return nil }
        guard paths.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }), sources.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }),
              Self.validTransferPayload(action: action, paths: paths, sources: sources) else { return nil }
        var components = URLComponents()
        components.scheme = "turtlegit"; components.host = "action"
        components.queryItems = [URLQueryItem(name: "command", value: action.rawValue)] + paths.map { URLQueryItem(name: "path", value: $0.path) } + sources.map { URLQueryItem(name: "source", value: $0.path) }
        if let requestPullEnd { components.queryItems?.append(URLQueryItem(name: "endrev", value: requestPullEnd)) }
        if let requestPullURL { components.queryItems?.append(URLQueryItem(name: "url", value: requestPullURL)) }
        if let clipboardPatch { components.queryItems?.append(URLQueryItem(name: "clipboardpatch", value: clipboardPatch)) }
        if let alternateTool {components.queryItems?.append(URLQueryItem(name:"alternate",value:alternateTool ? "1":"0"))}
        guard let result = components.url, !action.isFileTransfer || result.absoluteString.utf8.count <= 131072 else { return nil }; return result
    }
    public func relativePaths(root: URL) -> [String] {
        let prefix = Self.normalizedSelectionURL(root).path
        return paths.compactMap { item in
            if GitReferenceName.equal(item.path,prefix) { return "." }
            let boundary=prefix == "/" ? "/" : prefix + "/"
            guard item.path.utf8.starts(with:boundary.utf8) else { return nil }
            return String(decoding:item.path.utf8.dropFirst(boundary.utf8.count),as:UTF8.self)
        }
    }
    /// Expand selected directories to changed rows, with component boundaries.
    /// Selecting the repository itself includes its complete status list.
    public func selectedStatusPaths(root: URL, entries: [StatusEntry]) -> GitPathSet {
        let index = FileTransferIndex(paths:entries.map(\.path),caseSensitive:(try? root.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true)
        let selected = relativePaths(root:root).compactMap {path -> String? in
            if path == "." {return "."}
            return try? index.resolvingForIndex(path)
        }
        return GitPathSet(entries.filter {entry in selected.contains {path in path == "." || FileTransferPaths.contains(entry.path,in:path)} }.map(\.path))
    }
}


/// Exact clipboard bytes cross the Finder/app process boundary only after an
/// explicit Review action. Receipts are random one-use names in the entitled
/// container, not clipboard text embedded in an open URL or a source-file grant.
public struct FinderPatchHandoff: Sendable {
    public static let unavailable = "unavailable"
    public static let clipboardType = "org.turtlegit.unified-diff"
    public static let legacyClipboardType = "org.tortoisegit.unified-diff"
    public static let maximumBytes = 128 * 1024 * 1024
    public static var current: Self? { FinderIntegration.container.map { Self(root: $0.appendingPathComponent("Library/Caches/PatchHandoffs-v1", isDirectory: true)) } }
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func validReceipt(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private func directory(create: Bool) throws -> Int32 {
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if create && fchmod(descriptor, 0o700) != 0 { close(descriptor); throw POSIXError(.EACCES) }
        return descriptor
    }
    private func prune(_ descriptor: Int32, incoming: Int) throws {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw POSIXError(.EIO) }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw POSIXError(.EIO) }
        defer { closedir(stream) }
        var files: [(String, Int, Int64)] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 2, Self.validReceipt(String(pieces[0])), ["patch", "tmp", "claimed"].contains(String(pieces[1])) else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 600 {
                _ = unlinkat(descriptor, name, 0)
            } else { files.append((name, info.st_mtimespec.tv_sec, max(0, info.st_size))) }
        }
        var bytes = files.reduce(Int64(incoming)) { sum, file in sum > Int64.max - file.2 ? Int64.max : sum + file.2 }, count = files.count
        for file in files.sorted(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }) {
            if count < 32 && bytes <= 256 * 1024 * 1024 { break }
            if unlinkat(descriptor, file.0, 0) == 0 { bytes -= file.2; count -= 1 }
        }
    }
    public func publish(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
        let descriptor = try directory(create: true); defer { close(descriptor) }
        try prune(descriptor, incoming: bytes.count)
        let receipt = UUID().uuidString.lowercased(), temporary = receipt + ".tmp"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(.EIO) }
        defer { close(file); unlinkat(descriptor, temporary, 0) }
        guard fchmod(file, 0o600) == 0 else { throw POSIXError(.EACCES) }
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(file, data.baseAddress!.advanced(by: offset), min(65536, data.count - offset))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(.EIO) }; offset += written
            }
        }
        guard renameat(descriptor, temporary, descriptor, receipt + ".patch") == 0 else { throw POSIXError(.EIO) }
        return receipt
    }
    public func consume(_ receipt: String) throws -> Data {
        guard Self.validReceipt(receipt) else { throw POSIXError(.EINVAL) }
        let descriptor = try directory(create: false); defer { close(descriptor) }
        let claimed = UUID().uuidString.lowercased() + ".claimed"
        guard renameat(descriptor, receipt + ".patch", descriptor, claimed) == 0 else { throw POSIXError(.ENOENT) }
        defer { unlinkat(descriptor, claimed, 0) }
        var info = stat()
        guard fstatat(descriptor, claimed, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) <= 600 else { throw POSIXError(.EINVAL) }
        let bytes = try HistoryFileCache.readFile(claimed, directory: descriptor, limit: Self.maximumBytes, noFollow: true, cancellation: nil)
        guard !bytes.isEmpty else { throw POSIXError(.EINVAL) }; return bytes
    }
    public func discard(_ receipt: String) {
        guard Self.validReceipt(receipt), let descriptor = try? directory(create: false) else { return }
        defer { close(descriptor) }; _ = unlinkat(descriptor, receipt + ".patch", 0)
    }
}
