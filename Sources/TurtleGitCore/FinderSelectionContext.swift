// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Immutable exact-component nearest-root index. One node per path component
/// avoids both repeated ancestor reconstruction and per-byte trie amplification.
/// No filesystem aliasing/case/Unicode normalization participates here.
struct FinderExactRootIndex {
    private struct Node {var children:[GitReferenceName:Int]=[:];var root:String?}
    private let nodes:[Node]
    private let names:GitPathSet
    private let hasNoncanonicalRoots:Bool
    init(_ roots:[String]) {
        var nodes=[Node()]
        names=GitPathSet(roots)
        hasNoncanonicalRoots=roots.contains { $0 != "/" && ($0.hasSuffix("/") || $0.contains("//")) }
        for root in roots where root.hasPrefix("/") {
            var position=0
            for component in root.utf8.split(separator:47) {
                let key=GitReferenceName(String(decoding:component,as:UTF8.self))
                if let next=nodes[position].children[key] {position=next}
                else {let next=nodes.count;nodes.append(Node());nodes[position].children[key]=next;position=next}
            }
            nodes[position].root=root
        }
        self.nodes=nodes
    }
    func root(for path:String)->String? {
        guard path.hasPrefix("/") else{return nil}
        // Public snapshots may contain noncanonical input. Preserve the old
        // ancestor algorithm there, rather than broadening its root matches.
        if hasNoncanonicalRoots || path.contains("//") {return legacyRoot(for:path)}
        var position=0,best=nodes[0].root
        for component in path.utf8.split(separator:47) {
            let key=GitReferenceName(String(decoding:component,as:UTF8.self))
            guard let next=nodes[position].children[key] else{return best}
            position=next
            if let terminal=nodes[position].root {best=terminal}
        }
        return best
    }
    private func legacyRoot(for path:String)->String? {
        var candidate=path
        while candidate.utf8.count>1,candidate.hasSuffix("/") {candidate.removeLast()}
        while true {
            if names.contains(candidate) {return candidate}
            if candidate=="/" {return nil}
            candidate=FinderSnapshot.parentPath(candidate)
        }
    }
}

/// Snapshot values share lazy immutable query data until one of their path or
/// owner fields changes. The lock covers construction/publication only; returned
/// Swift values use copy-on-write storage and are never mutated by a reader.
final class FinderSnapshotQueries: @unchecked Sendable {
    typealias Descendants=[GitReferenceName:[GitReferenceName:Set<FileState>]]
    private let lock=NSLock()
    private var exactRootIndex:FinderExactRootIndex?
    private var pathNames:FileTransferIndex?
    private var descendantStates:Descendants?
    func rootIndex(_ create:()->FinderExactRootIndex)->FinderExactRootIndex {
        lock.lock();defer{lock.unlock()}
        if let exactRootIndex{return exactRootIndex}
        let value=create();exactRootIndex=value;return value
    }
    func paths(_ create:()->FileTransferIndex) -> FileTransferIndex {
        lock.lock();defer {lock.unlock()}
        if let pathNames {return pathNames}
        let value=create();pathNames=value;return value
    }
    func descendants(_ create:()->Descendants) -> Descendants {
        lock.lock();defer {lock.unlock()}
        if let descendantStates {return descendantStates}
        let value=create();descendantStates=value;return value
    }
}

extension FinderSnapshot {
    static func parentPath(_ path: String) -> String {
        let parts = path.utf8.split(separator: 47).dropLast()
        return "/" + parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }
    /// Prefer the exact cached namespace at every component; permit only a
    /// unique canonical spelling when Finder supplies a filesystem alias.
    private func cachedPath(for url: URL) -> String? {
        let path = FileTransferPaths.lexicalPath(url.path)
        let index = queries.paths {
            FileTransferIndex(paths: GitPathSet(states.keys).union(GitPathSet(overlayEntries?.keys ?? [])).union(roots).union(repositories.keys).map { String($0.dropFirst()) }, caseSensitive: true)
        }
        return (try? index.resolvingForIndex(String(path.dropFirst()))).map { "/" + $0 }
    }

    /// Nearest cached owner, so a nested checkout never falls back to its parent
    /// merely because other selected paths happen to be under that parent.
    public func repositoryRoot(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        guard let path = cachedPath(for:url) else { return nil }
        return exactRepositoryRoot(for:path)
    }
    /// Badge aggregation uses the recorded namespace directly, without asking
    /// the filesystem to alias a root or scanning every watched root per file.
    func exactRepositoryRoot(for path:String) -> String? {
        queries.rootIndex {FinderExactRootIndex(roots)}.root(for:path)
    }
    func isRepositoryRoot(_ url:URL, root:String) -> Bool {
        cachedPath(for:url).map { GitReferenceName.equal($0,root) } == true
    }
    public func commonRepositoryRoot(for paths: [URL]) -> String? {
        guard let first = paths.first, let owner = repositoryRoot(for: first),
              paths.dropFirst().allSatisfy({ repositoryRoot(for: $0).map { GitReferenceName.equal($0,owner) } == true }) else { return nil }
        return owner
    }
    /// Direct entries beat ignored ancestry, notably tracked files beneath an
    /// ignored folder. Only explicit ignore entries propagate in modern caches;
    /// aggregated directory badge states are not ignore rules.
    public func cachedState(for url: URL) -> FileState? {
        guard url.isFileURL,let path=cachedPath(for:url),let root=exactRepositoryRoot(for:path) else {return nil}
        if let direct = overlayEntries?[path] { return direct }
        if overlayEntries == nil, let state = states[path] { return state }
        let entries = overlayEntries ?? states
        var parent = Self.parentPath(path)
        while Self.contains(parent,root:root) {
            if entries[parent] == .ignored { return .ignored }
            if GitReferenceName.equal(parent,root) { break }
            parent = Self.parentPath(parent)
        }
        // An aggregated ignored folder can still be a tracked folder whose only
        // dirty children are ignored. Treat it as neutral, not an ignore rule.
        return states[path] == .ignored ? nil : states[path]
    }
    func fileOperationOwner(for url: URL) -> String? {
        guard url.isFileURL,let path=cachedPath(for:url),let owner=exactRepositoryRoot(for:path) else {return nil}
        return fileOperationOwner(path:path,root:owner)
    }
    private func fileOperationOwner(path:String,root:String) -> String {
        if GitReferenceName.equal(path,root),let parent=repositories[root]?.submoduleParentRoot {return parent}
        return root
    }
    public func commonFileOperationOwner(for paths: [URL]) -> String? {
        guard let first = paths.first, let owner = fileOperationOwner(for: first),
              paths.dropFirst().allSatisfy({ fileOperationOwner(for: $0).map { GitReferenceName.equal($0,owner) } == true }) else { return nil }
        return owner
    }
    func hasFileState(_ statesToMatch: Set<FileState>, at url: URL, includingDescendants: Bool) -> Bool {
        guard url.isFileURL,let path=cachedPath(for:url),let root=exactRepositoryRoot(for:path) else {return false}
        let owner=fileOperationOwner(path:path,root:root),entries=overlayEntries ?? states
        if let state=entries[path],statesToMatch.contains(state) {return true}
        guard includingDescendants else {return false}
        // Build from exact recorded entries, never alias filesystem names during
        // propagation. A child checkout's contents belong to that child; its
        // parent's gitlink remains a separately owned direct entry.
        let rootIndex=queries.rootIndex {FinderExactRootIndex(roots)}
        let descendants=queries.descendants {
            var result=FinderSnapshotQueries.Descendants()
            for (entry,state) in entries {
                guard let root=rootIndex.root(for:entry) else {continue}
                let owner=fileOperationOwner(path:entry,root:root)
                var parent=Self.parentPath(entry)
                while Self.contains(parent,root:owner) {
                    result[GitReferenceName(owner),default:[:]][GitReferenceName(parent),default:[]].insert(state)
                    if GitReferenceName.equal(parent,owner) {break}
                    parent=Self.parentPath(parent)
                }
            }
            return result
        }
        guard let present=descendants[GitReferenceName(owner)]?[GitReferenceName(path)] else {return false}
        return !present.isDisjoint(with:statesToMatch)
    }
}
