import Foundation
import Darwin

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
