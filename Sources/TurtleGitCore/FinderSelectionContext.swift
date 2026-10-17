// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

extension FinderSnapshot {
    static func parentPath(_ path: String) -> String {
        let parts = path.utf8.split(separator: 47).dropLast()
        return "/" + parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }
    /// Prefer the exact cached namespace at every component; permit only a
    /// unique canonical spelling when Finder supplies a filesystem alias.
    private func cachedPath(for url: URL) -> String? {
        let path = FileTransferPaths.lexicalPath(url.path)
        let index = FileTransferIndex(paths: GitPathSet(states.keys).union(GitPathSet(overlayEntries?.keys ?? [])).map { String($0.dropFirst()) }, caseSensitive: true)
        return (try? index.resolvingForIndex(String(path.dropFirst()))).map { "/" + $0 }
    }

    /// Nearest cached owner, so a nested checkout never falls back to its parent
    /// merely because other selected paths happen to be under that parent.
    public func repositoryRoot(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = FileTransferPaths.lexicalPath(url.path)
        return roots.filter { root in path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
            .max { $0.utf8.count < $1.utf8.count }
    }
    public func commonRepositoryRoot(for paths: [URL]) -> String? {
        guard let first = paths.first, let owner = repositoryRoot(for: first),
              paths.dropFirst().allSatisfy({ repositoryRoot(for: $0) == owner }) else { return nil }
        return owner
    }
    /// Direct entries beat ignored ancestry, notably tracked files beneath an
    /// ignored folder. Only explicit ignore entries propagate in modern caches;
    /// aggregated directory badge states are not ignore rules.
    public func cachedState(for url: URL) -> FileState? {
        guard let root = repositoryRoot(for: url) else { return nil }
        guard let path = cachedPath(for: url) else { return nil }
        if let direct = overlayEntries?[path] { return direct }
        if overlayEntries == nil, let state = states[path] { return state }
        let entries = overlayEntries ?? states
        var parent = FileTransferPaths.fileURL(Self.parentPath(path))
        while parent.path == root || parent.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            if entries[parent.path] == .ignored { return .ignored }
            if parent.path == root { break }
            parent = FileTransferPaths.fileURL(Self.parentPath(parent.path))
        }
        // An aggregated ignored folder can still be a tracked folder whose only
        // dirty children are ignored. Treat it as neutral, not an ignore rule.
        return states[path] == .ignored ? nil : states[path]
    }
    func fileOperationOwner(for url: URL) -> String? {
        guard let owner = repositoryRoot(for: url) else { return nil }
        if url.standardizedFileURL.path == owner, let parent = repositories[owner]?.submoduleParentRoot { return parent }
        return owner
    }
    public func commonFileOperationOwner(for paths: [URL]) -> String? {
        guard let first = paths.first, let owner = fileOperationOwner(for: first),
              paths.dropFirst().allSatisfy({ fileOperationOwner(for: $0) == owner }) else { return nil }
        return owner
    }
    func hasFileState(_ statesToMatch: Set<FileState>, at url: URL, includingDescendants: Bool) -> Bool {
        guard let owner = fileOperationOwner(for: url) else { return false }
        let entries = overlayEntries ?? states
        guard let path = cachedPath(for: url) else { return false }
        if let state = entries[path], statesToMatch.contains(state) { return true }
        guard includingDescendants else { return false }
        let prefix = path
        return entries.contains { path, state in
            FileTransferPaths.contains(path, in: prefix) && statesToMatch.contains(state) && fileOperationOwner(for: FileTransferPaths.fileURL(path)) == owner
        }
    }
}
