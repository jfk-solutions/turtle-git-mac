// Adapted from TortoiseGit GitLogListBase::DrawTagBranchMessage/GetTrackingBranch.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct HistoryBranchTracking: Equatable, Sendable {
    public let remote: String, branch: String
    public init(remote: String, branch: String) { self.remote = remote; self.branch = branch }
}
public struct HistoryReferenceLabel: Equatable, Sendable {
    public let reference: RevisionReference
    public var text: String
    public var hasTracking = false, singleRemote = false, sameName = false
    public init(reference: RevisionReference) { self.reference = reference; self.text = reference.label }
}
public struct HistoryReferenceContext: Equatable, Sendable {
    public var remotes: [String], tracking: [String: HistoryBranchTracking]
    public init(remotes: [String] = [], tracking: [String: HistoryBranchTracking] = [:]) { self.remotes = remotes; self.tracking = tracking }
    public func labels(_ references: [RevisionReference], visibility: HistoryReferenceVisibility = .all, symbolize: Bool = false) -> [HistoryReferenceLabel] {
        let singleRemote = remotes.count == 1 ? remotes[0] : nil
        var result: [HistoryReferenceLabel] = [], consumed = Set<String>()
        for (index, reference) in references.enumerated() where visibility.shows(reference) {
            var label = HistoryReferenceLabel(reference: reference)
            if reference.name.hasPrefix("refs/heads/"), let upstream = tracking[reference.label], !upstream.remote.isEmpty, !upstream.branch.isEmpty {
                label.hasTracking = true
                let fullName = "refs/remotes/" + upstream.remote + "/" + upstream.branch
                if visibility.contains(.remoteBranches), let remote = references.dropFirst(index + 1).first(where: { $0.name == fullName }) {
                    result.append(label)
                    var paired = HistoryReferenceLabel(reference: remote); paired.hasTracking = true
                    if symbolize {
                        paired.sameName = upstream.branch == reference.label
                        if singleRemote == upstream.remote {
                            paired.text = "/" + (paired.sameName ? "≡" : upstream.branch); paired.singleRemote = true
                        } else if paired.sameName { paired.text = upstream.remote + "/≡" }
                    }
                    result.append(paired); consumed.insert(fullName); continue
                }
            } else if reference.name.hasPrefix("refs/remotes/") {
                if consumed.contains(reference.name) { continue }
                if symbolize, let singleRemote, reference.label.hasPrefix(singleRemote + "/") {
                    label.text = "/" + String(reference.label.dropFirst(singleRemote.count + 1)); label.singleRemote = true
                }
            }
            result.append(label)
        }
        return result
    }
}
extension GitRepository {
    /// Read configuration rather than resolved upstream refs: absent/diverged refs still track.
    public func historyReferenceContext(cancellation: OperationCancellation? = nil) throws -> HistoryReferenceContext {
        let remotes = try run(["remote"], cancellation: cancellation).text.split(separator: "\n").map(String.init)
        let data = try run(["config", "--null", "--get-regexp", "^branch\\..*\\.(remote|merge)$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        var remoteValues: [String: String] = [:], mergeValues: [String: String] = [:]
        for record in data.split(separator: 0) {
            try cancellation?.check()
            guard let newline = record.firstIndex(of: 10) else { continue }
            let key = String(decoding: record[..<newline], as: UTF8.self), value = String(decoding: record[record.index(after: newline)...], as: UTF8.self)
            if key.hasSuffix(".remote") { remoteValues[String(key.dropFirst(7).dropLast(7))] = value }
            else if key.hasSuffix(".merge") { mergeValues[String(key.dropFirst(7).dropLast(6))] = value }
        }
        var tracking: [String: HistoryBranchTracking] = [:]
        for (branch, remote) in remoteValues {
            var merge = mergeValues[branch] ?? ""
            if merge.hasPrefix("refs/heads/") { merge = String(merge.dropFirst(11)) }
            else if merge.hasPrefix("refs/") { merge = String(merge.dropFirst(5)) }
            merge = String(merge.reversed().drop(while: { $0.isWhitespace }).reversed())
            tracking[branch] = HistoryBranchTracking(remote: remote, branch: merge)
        }
        return HistoryReferenceContext(remotes: remotes, tracking: tracking)
    }
}
