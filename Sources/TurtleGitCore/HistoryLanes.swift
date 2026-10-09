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
    private func find(_ hash: String, from: Int = 0) -> Int? { next.indices.dropFirst(from).first { next[$0] == hash } }
    private mutating func add(_ type: HistoryLane, hash: String, from position: Int) -> (Int,Bool) {
        if position < types.count, let index = types.indices.dropFirst(position).first(where: { types[$0] == .empty || types[$0] == .crossEmpty }) {
            let cross = types[index] == .crossEmpty; types[index] = type; next[index] = hash; return (index,cross)
        }
        types.append(type); next.append(hash); return (types.count-1,false)
    }
    private func isNode(_ type: HistoryLane) -> Bool { type == node || type == nodeLeft || type == nodeRight }
    private mutating func changeActive(_ hash: String) {
        types[activeLane] = types[activeLane] == .initial || types[activeLane].isBoundary ? .empty : .notActive
        if let index = find(hash) { types[index] = .active; activeLane = index }
        else { activeLane = add(.branch,hash: hash,from: activeLane).0 }
    }
    private mutating func setBoundary(_ value: Bool, initial: Bool) {
        node = value ? .boundaryCenter : .mergeFork
        nodeRight = value ? .boundaryRight : .mergeForkRight
        nodeLeft = value ? .boundaryLeft : initial ? .mergeForkLeftInitial : .mergeForkLeft
        boundary = value
        if value { types[activeLane] = .boundary }
    }
    private mutating func fork(_ hash: String) {
        let start = find(hash)!
        var end = start, index: Int? = start
        while let current = index { end = current; types[current] = .tail; index = find(hash,from: current+1) }
        types[activeLane] = node
        if types[start] == node { types[start] = nodeLeft }
        if types[end] == node { types[end] = nodeRight }
        if types[start] == .tail { types[start] = .tailLeft }
        if types[end] == .tail { types[end] = .tailRight }
        if start+1 < end {
            for i in (start+1)..<end {
                if types[i] == .notActive { types[i] = .cross }
                else if types[i] == .empty { types[i] = .crossEmpty }
            }
        }
    }
    private mutating func merge(_ parents: [String], firstParent: Bool) {
        guard !boundary else { return }
        let previous = types[activeLane]
        let wasFork = previous == node, wasForkLeft = previous == nodeLeft, wasForkRight = previous == nodeRight
        var start = activeLane, end = activeLane
        var startCross = false, endCross = false, endEmptyCross = false
        types[activeLane] = node
        if !firstParent {
            for parent in parents.dropFirst() {
                if let i = find(parent) {
                    if i > end { end = i; endCross = types[i] == .cross }
                    if i < start { start = i; startCross = types[i] == .cross }
                    types[i] = .join
                } else { let added = add(.head,hash: parent,from: end+1); end = added.0; endEmptyCross = added.1 }
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
                if types[i] == .notActive { types[i] = .cross }
                else if types[i] == .empty { types[i] = .crossEmpty }
                else if types[i] == .tailRight || types[i] == .tailLeft { types[i] = .tail }
            }
        }
    }
    private mutating func initial() { if !isNode(types[activeLane]) && types[activeLane] != .applied { types[activeLane] = boundary ? .boundary : .initial } }
    private mutating func afterMerge() {
        guard !boundary else { return }
        for i in types.indices {
            let type = types[i]
            if type.isHead || type.isJoin || type == .cross { types[i] = .notActive }
            else if type == .crossEmpty { types[i] = .empty }
            else if isNode(type) { types[i] = .active }
        }
    }
    private mutating func afterFork() {
        for i in types.indices {
            let type = types[i]
            if type == .cross { types[i] = .notActive }
            else if type.isTail || type == .crossEmpty { types[i] = .empty }
            if !boundary && isNode(types[i]) { types[i] = .active }
        }
        while types.last == .empty { types.removeLast(); next.removeLast() }
    }
    /// Snapshot occurs before nextParent/afterMerge/afterFork, as in upstream.
    /// `mergeCommit` retains actual merge identity when graph parents are rewritten.
    public mutating func consume(hash: String, parents: [String], mergeCommit: Bool? = nil, boundary: Bool = false, firstParent: Bool = false) -> [HistoryLane] {
        guard !hash.isEmpty else { return [] } // synthetic working-tree row has no source graph
        if types.isEmpty { activeLane = 0; setBoundary(false,initial: false); _ = add(.branch,hash: hash,from: 0) }
        let first = find(hash), discontinuity = first != activeLane
        let isFork = first.map { find(hash,from: $0+1) != nil } ?? false
        let isMerge = mergeCommit ?? (parents.count > 1), isInitial = parents.isEmpty
        if discontinuity { changeActive(hash) }
        setBoundary(boundary,initial: isInitial)
        if isFork { fork(hash) }
        if isMerge { merge(parents,firstParent: firstParent) }
        if isInitial { initial() }
        let result = types
        next[activeLane] = boundary ? "" : parents.first ?? ""
        if isMerge { afterMerge() }
        if isFork { afterFork(); if isInitial { initial() } }
        if types[activeLane] == .branch { types[activeLane] = .active }
        return result
    }
}
