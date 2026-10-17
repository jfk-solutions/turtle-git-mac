import Foundation

public enum RenameFailure: LocalizedError {
    case name, outsideWorkingTree, unchanged, exists, source, changed, ambiguousPath
    public var errorDescription: String? {
        switch self {
        case .name: return "Enter a relative file or folder name."
        case .outsideWorkingTree: return "The destination must be in the same working tree, outside Git’s administrative directories."
        case .unchanged: return "Enter a name different from the original name."
        case .exists: return "A file or folder already exists at the destination."
        case .changed: return "The source, index or HEAD changed. Refresh before renaming."
        case .source: return "Select one existing versioned file or folder to rename."
        case .ambiguousPath: return FileMoveFailure.ambiguousPath.localizedDescription
        }
    }
}
public struct RenameOptions: Sendable {
    public let source: String
    public let name: String
    public init(source: String, name: String) { self.source = source; self.name = name }
    /// Like RenameCommand, resolve the entered name relative to the source's
    /// containing directory. Parent components are allowed within this worktree.
    public func destination(root: URL) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"), !source.isEmpty,
              !source.hasPrefix("/"), !source.contains("\0") else { throw RenameFailure.name }
        let base = root.standardizedFileURL.path
        let sourcePath = FileTransferPaths.lexicalPath(base + "/" + source)
        let parent = sourcePath.split(separator:"/").dropLast().joined(separator:"/")
        let sourceURL = FileTransferPaths.fileURL(sourcePath)
        let target = FileTransferPaths.fileURL(FileTransferPaths.lexicalPath("/" + parent + "/" + name))
        guard sourceURL.path.hasPrefix(base + "/"), target.path.hasPrefix(base + "/"),
              RepositoryAccessLease.pathIsContained(sourceURL.deletingLastPathComponent(), by: root),
              RepositoryAccessLease.pathIsContained(target.deletingLastPathComponent(), by: root) else { throw RenameFailure.outsideWorkingTree }
        let relative = String(target.path.dropFirst(base.count + 1))
        guard !source.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              !relative.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw RenameFailure.outsideWorkingTree }
        guard !GitReferenceName.equal(target.path,sourceURL.path) else { throw RenameFailure.unchanged }
        return relative
    }
}
extension GitRepository {
    public func prepareRename(_ options: RenameOptions, cancellation: OperationCancellation? = nil) throws -> FileMovePlan {
        try cancellation?.check(); let target = try options.destination(root: root), url = FileTransferPaths.fileURL(root.path + "/" + target)
        do { return try prepareFileMove(source: options.source, to: url.deletingLastPathComponent(), name: url.lastPathComponent, cancellation: cancellation) }
        catch let failure as FileMoveFailure { throw renameFailure(failure) }
    }
    public func executeRename(_ plan: FileMovePlan, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        do { return try executeFileMove(plan, cancellation: cancellation, onOutput: onOutput) }
        catch let failure as FileMoveFailure { throw renameFailure(failure) }
    }
    public func rename(_ options: RenameOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try executeRename(prepareRename(options, cancellation: cancellation), cancellation: cancellation, onOutput: onOutput)
    }
    private func renameFailure(_ failure: FileMoveFailure) -> RenameFailure {
        switch failure { case .selection: return .source; case .destination: return .outsideWorkingTree; case .name: return .name; case .occupied: return .exists; case .unchanged: return .unchanged; case .changed: return .changed; case .ambiguousPath: return .ambiguousPath }
    }
    public func renameDestination(_ target: URL, source: String, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard target.isFileURL, !target.path.contains("\0") else { throw RenameFailure.outsideWorkingTree }
        let parent = try fileMoveDestination(target.deletingLastPathComponent(), cancellation: cancellation)
        let resolved = FileTransferPaths.fileURL(parent.path + "/" + target.lastPathComponent)
        let base = root.appendingPathComponent(source).deletingLastPathComponent().pathComponents, parts = resolved.pathComponents
        var shared = 0; while shared < min(base.count, parts.count), GitReferenceName.equal(base[shared],parts[shared]) { shared += 1 }
        let relative = (Array(repeating: "..", count: base.count - shared) + parts.dropFirst(shared)).joined(separator: "/")
        _ = try RenameOptions(source: source, name: relative).destination(root: root); try cancellation?.check(); return relative
    }
}
