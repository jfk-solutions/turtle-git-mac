import Foundation

public enum RenameFailure: LocalizedError {
    case name, outsideWorkingTree, unchanged, exists, source
    public var errorDescription: String? {
        switch self {
        case .name: return "Enter a relative file or folder name."
        case .outsideWorkingTree: return "The destination must be in the same working tree, outside Git’s administrative directories."
        case .unchanged: return "Enter a name different from the original name."
        case .exists: return "A file or folder already exists at the destination."
        case .source: return "Select one existing versioned file or folder to rename."
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
        let sourceURL = root.appendingPathComponent(source).standardizedFileURL
        let target = sourceURL.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard sourceURL.path.hasPrefix(base + "/"), target.path.hasPrefix(base + "/"),
              RepositoryAccessLease.pathIsContained(sourceURL.deletingLastPathComponent(), by: root),
              RepositoryAccessLease.pathIsContained(target.deletingLastPathComponent(), by: root) else { throw RenameFailure.outsideWorkingTree }
        let relative = String(target.path.dropFirst(base.count + 1))
        guard !source.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              !relative.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw RenameFailure.outsideWorkingTree }
        guard target.path != sourceURL.path else { throw RenameFailure.unchanged }
        return relative
    }
}
extension GitRepository {
    public func rename(_ options: RenameOptions) throws -> String {
        guard try !isBare() else { throw RenameFailure.source }
        let target = try options.destination(root: root)
        let source = options.source, manager = FileManager.default
        let sourceURL = root.appendingPathComponent(source), targetURL = root.appendingPathComponent(target)
        let parent = try CloneOptions.workingDirectory(for: targetURL.deletingLastPathComponent())
        var rootBytes = try run(["-C", parent.path, "rev-parse", "--show-toplevel"]).stdout
        if rootBytes.last == 10 { rootBytes.removeLast() }
        let targetRoot = URL(fileURLWithPath: String(decoding: rootBytes, as: UTF8.self), isDirectory: true)
        guard targetRoot.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { throw RenameFailure.outsideWorkingTree }
        // Do not follow the final component: renaming a tracked symlink moves the
        // link itself, including a dangling link, without touching its target.
        guard (try? manager.attributesOfItem(atPath: sourceURL.path)) != nil else { throw RenameFailure.source }
        let tracked = try trackedPaths()
        guard tracked.contains(source) || tracked.contains(where: { $0.hasPrefix(source + "/") }) else { throw RenameFailure.source }
        let caseOnly = source.caseInsensitiveCompare(target) == .orderedSame
        if (try? manager.attributesOfItem(atPath: targetURL.path)) != nil {
            // A case-insensitive volume can resolve the new spelling to the source.
            // A separately listed destination (including a symlink or hard link)
            // must never be overwritten, even if the names differ only by case.
            let names = try manager.contentsOfDirectory(atPath: targetURL.deletingLastPathComponent().path)
            guard caseOnly && !names.contains(targetURL.lastPathComponent) else { throw RenameFailure.exists }
        }
        return try run(["mv"] + (caseOnly ? ["-f"] : []) + ["--", source, target]).text
    }
}
