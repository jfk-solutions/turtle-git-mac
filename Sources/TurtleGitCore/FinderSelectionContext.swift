// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

extension FinderSnapshot {
    /// Nearest cached owner, so a nested checkout never falls back to its parent
    /// merely because other selected paths happen to be under that parent.
    public func repositoryRoot(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
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
        let path = url.standardizedFileURL.path
        if let direct = overlayEntries?[path] { return direct }
        if overlayEntries == nil, let state = states[path] { return state }
        let entries = overlayEntries ?? states
        var parent = url.standardizedFileURL.deletingLastPathComponent()
        while parent.path == root || parent.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            if entries[parent.path] == .ignored { return .ignored }
            if parent.path == root { break }
            parent.deleteLastPathComponent()
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
        if let state = entries[url.standardizedFileURL.path], statesToMatch.contains(state) { return true }
        guard includingDescendants else { return false }
        let path = url.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return entries.contains { path, state in
            path.hasPrefix(prefix) && statesToMatch.contains(state) && fileOperationOwner(for: URL(fileURLWithPath: path)) == owner
        }
    }
}
