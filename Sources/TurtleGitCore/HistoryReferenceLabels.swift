// Adapted from TortoiseGit GitLogListBase::DrawTagBranchMessage/GetTrackingBranch.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum HistoryReferenceKind: String, Sendable {
    case unknown, localBranch, remoteBranch, tag, annotatedTag, stash, bisectGood, bisectBad, bisectSkip, notes
}
public struct HistoryBisectTerms: Equatable, Sendable {
    public let good: String, bad: String
    public init(good: String = "good", bad: String = "bad") { self.good = good; self.bad = bad }
    public static func == (lhs: Self, rhs: Self) -> Bool { GitReferenceName.equal(lhs.good, rhs.good) && GitReferenceName.equal(lhs.bad, rhs.bad) }
    /// GetBisectTerms' two bounded fgets(260) reads, LF removal and NUL termination.
    public static func parse(_ data: Data?) -> Self {
        guard let data else { return Self() }
        let bytes = Array(data.prefix(518)); var position = 0
        func line() -> String {
            let start = position
            while position < bytes.count && position - start < 259 {
                let byte = bytes[position]; position += 1; if byte == 10 { break }
            }
            var value = Array(bytes[start..<position])
            if let nul = value.firstIndex(of: 0) { value = Array(value[..<nul]) }
            if value.last == 10 { value.removeLast() }
            return String(decoding: value, as: UTF8.self)
        }
        let bad = line(), good = line(); return Self(good: good, bad: bad)
    }
}
public struct HistoryBranchTracking: Equatable, Sendable {
    public let remote: String, branch: String
    public init(remote: String, branch: String) { self.remote = remote; self.branch = branch }
    public static func == (lhs: Self, rhs: Self) -> Bool { GitReferenceName.equal(lhs.remote, rhs.remote) && GitReferenceName.equal(lhs.branch, rhs.branch) }
}
public struct HistoryReferenceLabel: Equatable, Sendable {
    public let reference: RevisionReference
    public var text: String
    public let kind: HistoryReferenceKind
    public var hasTracking = false, singleRemote = false, sameName = false
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference && GitReferenceName.equal(lhs.text, rhs.text) && lhs.kind == rhs.kind
            && lhs.hasTracking == rhs.hasTracking && lhs.singleRemote == rhs.singleRemote && lhs.sameName == rhs.sameName
    }
    public init(reference: RevisionReference, terms: HistoryBisectTerms = HistoryBisectTerms()) {
        self.reference = reference
        let short = Self.shortName(reference.name, terms: terms)
        self.text = reference.displayName ?? short.text; self.kind = reference.kind ?? short.kind
    }
    /// CGit::GetShortName, preserving canonical ref names separately from display text.
    public static func shortName(_ name: String, terms: HistoryBisectTerms = HistoryBisectTerms()) -> (text: String, kind: HistoryReferenceKind) {
        func strip(_ prefix: String) -> String? {
            guard var text = GitReferenceName.removingPrefix(prefix, from: name) else { return nil }
            text = GitReferenceName.removingSuffix("^{}", from: text) ?? text
            return text
        }
        if let text = strip("refs/heads/") { return (text, .localBranch) }
        if let text = strip("refs/remotes/") { return (text, .remoteBranch) }
        if let text = strip("refs/tags/") { return (text, name.hasSuffix("^{}") ? .annotatedTag : .tag) }
        if strip("refs/stash") != nil { return ("stash", .stash) }
        if var text = strip("refs/bisect/") {
            var kind = HistoryReferenceKind.unknown
            func matches(_ term: String) -> Bool { GitReferenceName.equal(text, term) || text.utf8.starts(with: (term + "-").utf8) }
            // Upstream tests sequentially against the possibly already shortened name.
            if matches(terms.good) { text = terms.good; kind = .bisectGood }
            if matches(terms.bad) { text = terms.bad; kind = .bisectBad }
            if matches("skip") { text = "skip"; kind = .bisectSkip }
            return (text, kind)
        }
        if let text = strip("refs/notes/") { return (text, .notes) }
        if let text = strip("refs/") { return (text, .unknown) }
        return (name, .unknown)
    }
}
public struct HistoryReferenceContext: Equatable, Sendable {
    public var remotes: [String], tracking: [GitReferenceName: HistoryBranchTracking]
    public init(remotes: [String] = [], tracking: [GitReferenceName: HistoryBranchTracking] = [:]) { self.remotes = remotes; self.tracking = tracking }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.remotes.count == rhs.remotes.count && zip(lhs.remotes, rhs.remotes).allSatisfy { GitReferenceName.equal($0.0, $0.1) } && lhs.tracking == rhs.tracking
    }
    public func labels(_ references: [RevisionReference], visibility: HistoryReferenceVisibility = .all, symbolize: Bool = false, terms: HistoryBisectTerms = HistoryBisectTerms()) -> [HistoryReferenceLabel] {
        let singleRemote = remotes.count == 1 ? remotes[0] : nil
        var result: [HistoryReferenceLabel] = [], consumed = Set<GitReferenceName>()
        for (index, reference) in references.enumerated() where visibility.shows(reference) {
            var label = HistoryReferenceLabel(reference: reference, terms: terms)
            if reference.name.utf8.starts(with: "refs/heads/".utf8), let upstream = tracking[GitReferenceName(label.text)], !upstream.remote.isEmpty, !upstream.branch.isEmpty {
                label.hasTracking = true
                let fullName = "refs/remotes/" + upstream.remote + "/" + upstream.branch
                if visibility.contains(.remoteBranches), let remote = references.dropFirst(index + 1).first(where: { GitReferenceName.equal($0.name, fullName) }) {
                    result.append(label)
                    var paired = HistoryReferenceLabel(reference: remote, terms: terms); paired.hasTracking = true
                    if symbolize {
                        paired.sameName = GitReferenceName.equal(upstream.branch, label.text)
                        if singleRemote.map({ GitReferenceName.equal($0, upstream.remote) }) == true {
                            paired.text = "/" + (paired.sameName ? "≡" : upstream.branch); paired.singleRemote = true
                        } else if paired.sameName { paired.text = upstream.remote + "/≡" }
                    }
                    result.append(paired); consumed.insert(GitReferenceName(fullName)); continue
                }
            } else if reference.name.utf8.starts(with: "refs/remotes/".utf8) {
                if consumed.contains(GitReferenceName(reference.name)) { continue }
                if symbolize, let singleRemote, label.text.utf8.starts(with: (singleRemote + "/").utf8) {
                    label.text = "/" + GitReferenceName.removingPrefix(singleRemote + "/", from: label.text)!; label.singleRemote = true
                }
            }
            result.append(label)
        }
        return result
    }
}
extension GitRepository {
    public func historyBisectTerms(cancellation: OperationCancellation? = nil) throws -> HistoryBisectTerms {
        var bytes = try run(["rev-parse", "--git-path", "BISECT_TERMS"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        try cancellation?.check()
        guard let file = try? FileHandle(forReadingFrom: url) else { return HistoryBisectTerms() }
        defer { try? file.close() }
        return HistoryBisectTerms.parse(try file.read(upToCount: 518))
    }
    /// Read configuration rather than resolved upstream refs: absent/diverged refs still track.
    public func historyReferenceContext(cancellation: OperationCancellation? = nil) throws -> HistoryReferenceContext {
        let remotes = try run(["remote"], cancellation: cancellation).text.split(separator: "\n").map(String.init)
        let data = try run(["config", "--null", "--get-regexp", "^branch\\..*\\.(remote|merge)$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        var remoteValues: [GitReferenceName: String] = [:], mergeValues: [GitReferenceName: String] = [:]
        for record in data.split(separator: 0) {
            try cancellation?.check()
            guard let newline = record.firstIndex(of: 10) else { continue }
            let key = String(decoding: record[..<newline], as: UTF8.self), value = String(decoding: record[record.index(after: newline)...], as: UTF8.self)
            guard let branchKey = GitReferenceName.removingPrefix("branch.", from: key) else { continue }
            if let branch = GitReferenceName.removingSuffix(".remote", from: branchKey) { remoteValues[GitReferenceName(branch)] = value }
            else if let branch = GitReferenceName.removingSuffix(".merge", from: branchKey) { mergeValues[GitReferenceName(branch)] = value }
        }
        var tracking: [GitReferenceName: HistoryBranchTracking] = [:]
        for (branch, remote) in remoteValues {
            var merge = mergeValues[branch] ?? ""
            merge = GitReferenceName.removingPrefix("refs/heads/", from: merge) ?? GitReferenceName.removingPrefix("refs/", from: merge) ?? merge
            merge = String(merge.reversed().drop(while: { $0.isWhitespace }).reversed())
            tracking[branch] = HistoryBranchTracking(remote: remote, branch: merge)
        }
        return HistoryReferenceContext(remotes: remotes, tracking: tracking)
    }
}
