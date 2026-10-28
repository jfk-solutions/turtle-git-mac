import Foundation

/// Pinned TortoiseGit lanes.h element order, consumed by the native Log/Blame renderer.
public enum HistoryLane: Int, CaseIterable, Sendable {
    case empty, active, notActive, mergeFork, mergeForkRight, mergeForkLeft, mergeForkLeftInitial
    case join, joinRight, joinLeft, head, headRight, headLeft, tail, tailRight, tailLeft
    case cross, crossEmpty, initial, branch, unapplied, applied, boundary, boundaryCenter, boundaryRight, boundaryLeft
    public var isHead: Bool { self == .head || self == .headRight || self == .headLeft }
    public var isTail: Bool { self == .tail || self == .tailRight || self == .tailLeft }
    public var isJoin: Bool { self == .join || self == .joinRight || self == .joinLeft }
    public var isBoundary: Bool { [.boundary,.boundaryCenter,.boundaryRight,.boundaryLeft].contains(self) }
    /// Matches upstream isMerge, including its exclusion of MERGE_FORK_L_INITIAL.
    public var isMerge: Bool { [.mergeFork,.mergeForkRight,.mergeForkLeft].contains(self) || isBoundary }
}

/// Swift adaptation of Lanes and CLogDataVector::updateLanes. Lanes are not
/// compacted after every record: empty/cross-empty slots are reused in order.
public struct HistoryLanes: Sendable {
    private var types: [HistoryLane] = []
    private var next: [String] = []
    public private(set) var activeLane = 0
    private var boundary = false
    private var node: HistoryLane = .mergeFork, nodeLeft: HistoryLane = .mergeForkLeft, nodeRight: HistoryLane = .mergeForkRight
    public init() {}
    private func find(_ hash: String, from: Int = 0, checkingCancellation check: () throws -> Void) rethrows -> Int? { try next.indices.dropFirst(from).first { try check(); return next[$0] == hash } }
    private mutating func add(_ type: HistoryLane, hash: String, from position: Int, checkingCancellation check: () throws -> Void) rethrows -> (Int,Bool) {
        try check()
        if position < types.count, let index = try types.indices.dropFirst(position).first(where: { try check(); return types[$0] == .empty || types[$0] == .crossEmpty }) {
            let cross = types[index] == .crossEmpty; types[index] = type; next[index] = hash; return (index,cross)
        }
        types.append(type); next.append(hash); return (types.count-1,false)
    }
    private func isNode(_ type: HistoryLane) -> Bool { type == node || type == nodeLeft || type == nodeRight }
    private mutating func changeActive(_ hash: String, checkingCancellation check: () throws -> Void) rethrows {
        types[activeLane] = types[activeLane] == .initial || types[activeLane].isBoundary ? .empty : .notActive
        if let index = try find(hash, checkingCancellation: check) { types[index] = .active; activeLane = index }
        else { activeLane = try add(.branch,hash: hash,from: activeLane, checkingCancellation: check).0 }
    }
    private mutating func setBoundary(_ value: Bool, initial: Bool) {
        node = value ? .boundaryCenter : .mergeFork
        nodeRight = value ? .boundaryRight : .mergeForkRight
        nodeLeft = value ? .boundaryLeft : initial ? .mergeForkLeftInitial : .mergeForkLeft
        boundary = value
        if value { types[activeLane] = .boundary }
    }
    private mutating func fork(_ hash: String, checkingCancellation check: () throws -> Void) rethrows {
        let start = try find(hash, checkingCancellation: check)!
        var end = start, index: Int? = start
        while let current = index { try check(); end = current; types[current] = .tail; index = try find(hash,from: current+1, checkingCancellation: check) }
        types[activeLane] = node
        if types[start] == node { types[start] = nodeLeft }
        if types[end] == node { types[end] = nodeRight }
        if types[start] == .tail { types[start] = .tailLeft }
        if types[end] == .tail { types[end] = .tailRight }
        if start+1 < end {
            for i in (start+1)..<end {
                try check()
                if types[i] == .notActive { types[i] = .cross }
                else if types[i] == .empty { types[i] = .crossEmpty }
            }
        }
    }
    private mutating func merge(_ parents: [String], firstParent: Bool, checkingCancellation check: () throws -> Void) rethrows {
        guard !boundary else { return }
        let previous = types[activeLane]
        let wasFork = previous == node, wasForkLeft = previous == nodeLeft, wasForkRight = previous == nodeRight
        var start = activeLane, end = activeLane
        var startCross = false, endCross = false, endEmptyCross = false
        types[activeLane] = node
        if !firstParent {
            for parent in parents.dropFirst() {
                try check()
                if let i = try find(parent, checkingCancellation: check) {
                    if i > end { end = i; endCross = types[i] == .cross }
                    if i < start { start = i; startCross = types[i] == .cross }
                    types[i] = .join
                } else { let added = try add(.head,hash: parent,from: end+1, checkingCancellation: check); end = added.0; endEmptyCross = added.1 }
            }
        }
        if types[start] == node && !wasFork && !wasForkRight { types[start] = nodeLeft }
        if types[end] == node && !wasFork && !wasForkLeft { types[end] = nodeRight }
        if types[start] == .join && !startCross { types[start] = .joinLeft }
        if types[end] == .join && !endCross { types[end] = .joinRight }
        if types[start] == .head { types[start] = .headLeft }
        if types[end] == .head && !endEmptyCross { types[end] = .headRight }
        if start+1 < end {
            for i in (start+1)..<end {
                try check()
                if types[i] == .notActive { types[i] = .cross }
                else if types[i] == .empty { types[i] = .crossEmpty }
                else if types[i] == .tailRight || types[i] == .tailLeft { types[i] = .tail }
            }
        }
    }
    private mutating func initial() { if !isNode(types[activeLane]) && types[activeLane] != .applied { types[activeLane] = boundary ? .boundary : .initial } }
    private mutating func afterMerge(checkingCancellation check: () throws -> Void) rethrows {
        guard !boundary else { return }
        for i in types.indices {
            try check()
            let type = types[i]
            if type.isHead || type.isJoin || type == .cross { types[i] = .notActive }
            else if type == .crossEmpty { types[i] = .empty }
            else if isNode(type) { types[i] = .active }
        }
    }
    private mutating func afterFork(checkingCancellation check: () throws -> Void) rethrows {
        for i in types.indices {
            try check()
            let type = types[i]
            if type == .cross { types[i] = .notActive }
            else if type.isTail || type == .crossEmpty { types[i] = .empty }
            if !boundary && isNode(types[i]) { types[i] = .active }
        }
        while types.last == .empty { try check(); types.removeLast(); next.removeLast() }
    }
    /// Snapshot occurs before nextParent/afterMerge/afterFork, as in upstream.
    /// `mergeCommit` retains actual merge identity when graph parents are rewritten.
    public mutating func consume(hash: String, parents: [String], mergeCommit: Bool? = nil, boundary: Bool = false, firstParent: Bool = false) -> [HistoryLane] {
        consume(hash: hash, parents: parents, mergeCommit: mergeCommit, boundary: boundary, firstParent: firstParent, checkingCancellation: {})
    }
    /// The cancellable projection owns this machine and discards it on failure;
    /// its partially advanced internal state must never be reused after a throw.
    mutating func consume(hash: String, parents: [String], mergeCommit: Bool? = nil, boundary: Bool = false, firstParent: Bool = false, checkingCancellation check: () throws -> Void) rethrows -> [HistoryLane] {
        try check()
        guard !hash.isEmpty else { return [] } // synthetic working-tree row has no source graph
        if types.isEmpty { activeLane = 0; setBoundary(false,initial: false); _ = try add(.branch,hash: hash,from: 0, checkingCancellation: check) }
        let first = try find(hash, checkingCancellation: check), discontinuity = first != activeLane
        let isFork = try first.map { try find(hash,from: $0+1, checkingCancellation: check) != nil } ?? false
        let isMerge = mergeCommit ?? (parents.count > 1), isInitial = parents.isEmpty
        if discontinuity { try changeActive(hash, checkingCancellation: check) }
        setBoundary(boundary,initial: isInitial)
        if isFork { try fork(hash, checkingCancellation: check) }
        if isMerge { try merge(parents,firstParent: firstParent, checkingCancellation: check) }
        if isInitial { initial() }
        let result = types
        next[activeLane] = boundary ? "" : parents.first ?? ""
        if isMerge { try afterMerge(checkingCancellation: check) }
        if isFork { try afterFork(checkingCancellation: check); if isInitial { initial() } }
        if types[activeLane] == .branch { types[activeLane] = .active }
        try check()
        return result
    }
}
