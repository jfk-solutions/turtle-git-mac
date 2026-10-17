// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum FileMoveFailure: LocalizedError {
    case selection, destination, name, occupied, unchanged, changed, ambiguousPath
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select existing versioned files or folders in this working tree."
        case .destination: return "Choose an existing destination folder in the same working tree, outside Git’s administrative directories."
        case .name: return "Enter a file or folder name without folder separators."
        case .occupied: return "An item already exists with this name. Choose a new name before moving."
        case .unchanged: return "Choose a different name or destination folder."
        case .changed: return "The selected file, index entries or repository changed. Refresh before moving."
        case .ambiguousPath: return "Distinct Git paths share this local filename. Resolve the filename collision before moving or copying these files."
        }
    }
}
public struct FileMovePlan: Sendable {
    public let source: String
    public let destination: String
    public let folder: URL
    public let caseOnly: Bool
    let index: Data
    public let head: Data
    let fingerprint: FileMoveFingerprint
}
struct FileMoveFingerprint: Equatable, Sendable {
    let type: String
    let inode: UInt64
    let device: UInt64
    let size: UInt64
    let modified: Date?
    let permissions: UInt64
    init(_ attributes: [FileAttributeKey: Any]) throws {
        guard let type = attributes[.type] as? FileAttributeType,
              [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else { throw FileMoveFailure.selection }
        self.type = type.rawValue
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
        permissions = (attributes[.posixPermissions] as? NSNumber)?.uint64Value ?? 0
    }
}
/// Git identities are byte-exact. Filesystem URL spellings may be canonically
/// equivalent; resolve those only when the index has one possible identity.
public enum FileTransferPaths {
    /// Foundation's fileURLWithPath/appendingPathComponent can decompose Unicode
    /// on Darwin. URLComponents preserves the spelling supplied by Git/providers.
    public static func fileURL(_ absolutePath:String) -> URL {
        precondition(absolutePath.hasPrefix("/"))
        var parts = URLComponents(); parts.scheme = "file"; parts.host = ""; parts.path = absolutePath
        return parts.url!
    }
    public static func lexicalPath(_ path:String) -> String {
        var components:[Substring] = []
        for component in path.split(separator:"/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return (path.hasPrefix("/") ? "/":"") + components.joined(separator:"/")
    }
    public static func contains(_ path: String, in directory: String) -> Bool {
        GitReferenceName.equal(path,directory) || path.utf8.starts(with:(directory + "/").utf8)
    }
    public static func remapping(_ path:String, source:String, destination:String) -> String {
        guard contains(path,in:source) else { return path }
        return destination + String(decoding:path.utf8.dropFirst(source.utf8.count),as:UTF8.self)
    }
    public static func uniqueURLs(_ urls:[URL]) -> [URL] {
        var seen = GitPathSet()
        return urls.filter { $0.isFileURL && seen.insert(lexicalPath($0.path)).inserted }
    }
    /// Match the selected grants once each, preserving captured source order.
    /// A unique filesystem spelling can match one Git spelling; ambiguous peers
    /// must never borrow the same selected grant or silently replace one another.
    public static func authorizedSources(_ selected:[URL], for sources:[URL]) -> [URL]? {
        guard selected.count == sources.count, uniqueURLs(selected).count == selected.count else { return nil }
        var available = Array(selected.indices), result:[URL] = []
        for source in sources {
            let path = lexicalPath(source.path)
            let exact = available.filter { GitReferenceName.equal(lexicalPath(selected[$0].path),path) }
            let matches = exact.isEmpty ? available.filter { lexicalPath(selected[$0].path) == path } : exact
            guard matches.count == 1, let index = matches.first else { return nil }
            if exact.isEmpty && sources.filter({lexicalPath($0.path) == path}).count != 1 { return nil }
            result.append(selected[index]); available.removeAll {$0 == index}
        }
        return result
    }
}

struct FileTransferIndex {
    let paths:[String]
    // Intentional canonical comparison here describes local filename aliases.
    private var prefixes:[String:GitPathSet] = [:]
    private let caseSensitive:Bool
    private func localKey(_ path:String) -> String { caseSensitive ? path : path.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")) }
    init(paths:[String],caseSensitive:Bool = true) {
        self.paths = paths; self.caseSensitive = caseSensitive
        for path in paths {
            var prefix = ""
            for component in path.split(separator:"/") {
                prefix += (prefix.isEmpty ? "":"/") + component
                prefixes[localKey(prefix),default:[]].insert(prefix)
            }
        }
    }
    func resolving(_ path:String) throws -> String {
        var components = path.split(separator:"/").map(String.init)
        for depth in 1...max(1,components.count) {
            guard depth <= components.count else { break }
            let prefix = components.prefix(depth).joined(separator:"/")
            guard let aliases = prefixes[localKey(prefix)] else { continue }
            guard aliases.count == 1, let exact = aliases.first else { throw FileMoveFailure.ambiguousPath }
            components.replaceSubrange(0..<depth,with:exact.split(separator:"/").map(String.init))
        }
        return components.joined(separator:"/")
    }
    /// Index-only reads/adds may select an exact peer without changing its
    /// filesystem alias. Lock each chosen parent before resolving the next name.
    func resolvingForIndex(_ path:String) throws -> String {
        var parent = ""
        for component in path.split(separator:"/") {
            let requested = parent.isEmpty ? String(component) : parent + "/" + component
            let aliases = prefixes[localKey(requested)]?.filter { candidate in
                let owner = candidate.split(separator:"/").dropLast().joined(separator:"/")
                return GitReferenceName.equal(owner,parent)
            } ?? []
            if aliases.contains(where:{GitReferenceName.equal($0,requested)}) {parent=requested}
            else if aliases.count == 1,let candidate=aliases.first {parent=candidate}
            else if aliases.isEmpty {parent=requested}
            else {throw FileMoveFailure.ambiguousPath}
        }
        return parent
    }
    func localEquivalent(_ a:String,_ b:String) -> Bool {localKey(a) == localKey(b)}
    func without(_ source:String) -> Self { Self(paths:paths.filter {!FileTransferPaths.contains($0,in:source)},caseSensitive:caseSensitive) }
}

extension GitRepository {
    func fileTransferIndex(cancellation:OperationCancellation?) throws -> FileTransferIndex {
        let data = try run(["-c","core.precomposeunicode=false","ls-files","--cached","-z"],cancellation:cancellation).stdout
        let paths = try data.split(separator:0).map { record -> String in
            guard let path = String(data:Data(record),encoding:.utf8) else { throw FileMoveFailure.selection };return path
        }
        return FileTransferIndex(paths:paths,caseSensitive:(try? root.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true)
    }
    public func fileMoveDestination(_ folder: URL, cancellation: OperationCancellation? = nil) throws -> URL {
        try cancellation?.check()
        guard folder.isFileURL, !folder.path.contains("\0"), try !isBare(cancellation: cancellation),
              RepositoryAccessLease.pathIsContained(folder, by: root) else { throw FileMoveFailure.destination }
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath(), canonicalRoot = root.resolvingSymlinksInPath()
        guard canonical.path == canonicalRoot.path || canonical.path.hasPrefix(canonicalRoot.path + "/"),
              try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FileMoveFailure.destination }
        let relative = canonical.path == canonicalRoot.path ? "" : String(canonical.path.dropFirst(canonicalRoot.path.count + 1))
        guard !relative.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw FileMoveFailure.destination }
        let top = try run(["-C", canonical.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == canonicalRoot.path else { throw FileMoveFailure.destination }
        try cancellation?.check(); return relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
    }
    public func prepareFileMove(source: String, to folder: URL, name: String? = nil, cancellation: OperationCancellation? = nil) throws -> FileMovePlan {
        try cancellation?.check(); _ = try RemovalRequest(paths: [source], keepLocal: true)
        let folder = try fileMoveDestination(folder, cancellation: cancellation), sourceURL = try restoreLocation(source)
        let owner = try CloneOptions.workingDirectory(for: sourceURL.deletingLastPathComponent())
        let top = try run(["-C", owner.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw FileMoveFailure.selection }
        let proposed = name ?? source.split(separator:"/").last.map(String.init) ?? source
        guard !proposed.isEmpty, name == nil || !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposed != ".", proposed != "..", !proposed.contains("/"), !proposed.contains("\0"), proposed.caseInsensitiveCompare(".git") != .orderedSame else { throw FileMoveFailure.name }
        let tracked = try fileTransferIndex(cancellation:cancellation)
        guard GitReferenceName.equal(try tracked.resolving(source),source), tracked.paths.contains(where:{FileTransferPaths.contains($0,in:source)}) else { throw FileMoveFailure.selection }
        for path in tracked.paths where FileTransferPaths.contains(path,in:source) { _ = try tracked.resolving(path) }
        let relativeFolder = folder.path == root.path ? "" : String(folder.path.dropFirst(root.path.count + 1))
        let exactFolder = relativeFolder.isEmpty ? "" : try tracked.resolving(relativeFolder)
        let requested = exactFolder.isEmpty ? proposed : exactFolder + "/" + proposed
        let destination = try tracked.without(source).resolving(requested)
        _ = try RemovalRequest(paths:[destination],keepLocal:true)
        guard !GitReferenceName.equal(destination,source) else { throw FileMoveFailure.unchanged }
        let destinationURL = FileTransferPaths.fileURL(root.path + "/" + destination)
        guard destinationURL.path.hasPrefix(root.path + "/"), !destinationURL.path.hasPrefix(sourceURL.path + "/") else { throw FileMoveFailure.destination }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path) } catch { throw FileMoveFailure.selection }
        let fingerprint = try FileMoveFingerprint(attributes)
        let caseOnly = source.caseInsensitiveCompare(destination) == .orderedSame
        if let targetAttributes = try? FileManager.default.attributesOfItem(atPath:destinationURL.path) {
            let target = try FileMoveFingerprint(targetAttributes)
            guard caseOnly, target.inode == fingerprint.inode, target.device == fingerprint.device else { throw FileMoveFailure.occupied }
        }
        let index = try run(["-c","core.precomposeunicode=false","ls-files", "--stage", "-z", "--", source], cancellation: cancellation).stdout
        guard !index.isEmpty else { throw FileMoveFailure.selection }
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        try cancellation?.check()
        return FileMovePlan(source: source, destination: destination, folder: folder, caseOnly: caseOnly, index: index, head: head, fingerprint: fingerprint)
    }
    public func executeFileMove(_ plan: FileMovePlan, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let fresh = try prepareFileMove(source: plan.source, to: plan.folder, name: plan.destination.split(separator:"/").last.map(String.init), cancellation: cancellation)
        guard GitReferenceName.equal(fresh.destination,plan.destination), fresh.index == plan.index, fresh.head == plan.head, fresh.fingerprint == plan.fingerprint else { throw FileMoveFailure.changed }
        try cancellation?.check()
        return try run(["-c","core.precomposeunicode=false","mv"] + (fresh.caseOnly ? ["-f"] : []) + ["--", plan.source, plan.destination], cancellation: cancellation, onOutput: onOutput).text
    }
}
