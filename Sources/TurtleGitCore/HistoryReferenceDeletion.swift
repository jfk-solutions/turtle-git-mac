// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum HistoryReferenceDeleteChoice: Sendable { case abort, delete, remoteAndLocal, remoteLocal, stashAll, stashOne }
public struct HistoryReferenceDeletion: Sendable {
    public enum Kind: Sendable { case ordinary, remote, stash }
    public let name: String, objectID: String
    public let kind: Kind
    public let unmerged: Bool
    public let stashEntries: [ReferenceLogEntry]
    public var message: String {
        switch kind {
        case .ordinary: return "Do you really want to delete \"\(name)\"?" + (unmerged ? "\n\nThis branch is not fully merged into HEAD." : "")
        case .remote: return "The branch \"\(name)\" is a remote-tracking branch which locally represents a remote branch.\n\nDo you really want to delete it?"
        case .stash: return "Do you really want to delete ALL \(stashEntries.count) stash?"
        }
    }
    public var choices: [(title: String, choice: HistoryReferenceDeleteChoice)] {
        switch kind {
        case .ordinary: return [("Delete", .delete), ("Abort", .abort)]
        case .remote: return [("Delete branch on remote & local remote-tracking branch", .remoteAndLocal), ("Delete local remote-tracking branch", .remoteLocal), ("Abort", .abort)]
        case .stash: return [("Delete", .stashAll), ("Drop one stash", .stashOne), ("Abort", .abort)]
        }
    }
}
public enum HistoryReferenceDeletionFailure: LocalizedError {
    case reference, current, changed, choice
    public var errorDescription: String? {
        switch self {
        case .reference: return "The selected reference no longer exists or is invalid."
        case .current: return "The current branch cannot be deleted."
        case .changed: return "The reference changed while deletion was being confirmed. Refresh and try again."
        case .choice: return "This deletion choice does not apply to the selected reference."
        }
    }
}
extension GitRepository {
    public func prepareHistoryReferenceDeletion(_ name: String) throws -> HistoryReferenceDeletion {
        let name = GitReferenceName.removingSuffix("^{}", from: name) ?? name
        guard name.utf8.starts(with: "refs/".utf8), (try? run(["check-ref-format", name])) != nil else { throw HistoryReferenceDeletionFailure.reference }
        let current = try? run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        guard current.map({ !GitReferenceName.equal($0, name) }) ?? true else { throw HistoryReferenceDeletionFailure.current }
        let oid: String
        do { oid = try run(["rev-parse", "--verify", "--end-of-options", name]).text.trimmingCharacters(in: .newlines) }
        catch { throw HistoryReferenceDeletionFailure.reference }
        let remote = name.utf8.starts(with: "refs/remotes/".utf8)
        let stash = name.utf8.starts(with: "refs/stash".utf8)
        let local = name.utf8.starts(with: "refs/heads/".utf8)
        let merged = !local || (try? run(["merge-base", "--is-ancestor", name, "HEAD"])) != nil
        return HistoryReferenceDeletion(name: name, objectID: oid, kind: remote ? .remote : stash ? .stash : .ordinary, unmerged: !merged, stashEntries: stash ? try referenceLog(name) : [])
    }
    public func deleteHistoryReference(_ snapshot: HistoryReferenceDeletion, choice: HistoryReferenceDeleteChoice) async throws -> String {
        guard choice != .abort, snapshot.choices.contains(where: { $0.choice == choice }) else { throw HistoryReferenceDeletionFailure.choice }
        let fresh = try prepareHistoryReferenceDeletion(snapshot.name)
        guard fresh.objectID == snapshot.objectID, fresh.stashEntries == snapshot.stashEntries else { throw HistoryReferenceDeletionFailure.changed }
        if choice == .stashAll { return try await deleteStashEntries([], expected: snapshot.stashEntries, clear: true) }
        if choice == .stashOne {
            guard let first = snapshot.stashEntries.first else { throw HistoryReferenceDeletionFailure.reference }
            return try await deleteStashEntries([first.selector], expected: snapshot.stashEntries)
        }
        if let short = GitReferenceName.removingPrefix("refs/remotes/", from: snapshot.name) {
            if choice == .remoteAndLocal {
                guard let slash = short.utf8.firstIndex(of: 47) else { throw HistoryReferenceDeletionFailure.reference }
                let remote = String(decoding: short.utf8[..<slash], as: UTF8.self)
                let branch = String(decoding: short.utf8[short.utf8.index(after: slash)...], as: UTF8.self)
                guard !remote.isEmpty, !branch.isEmpty else { throw HistoryReferenceDeletionFailure.reference }
                return try run(["push", "--", remote, ":refs/heads/" + branch]).text
            }
            return try run(["branch", "-D", "-r", "--", short]).text
        }
        if let short = GitReferenceName.removingPrefix("refs/heads/", from: snapshot.name) { return try run(["branch", "-D", "--", short]).text }
        if let short = GitReferenceName.removingPrefix("refs/tags/", from: snapshot.name) { return try run(["tag", "-d", "--", short]).text }
        return try run(["update-ref", "--no-deref", "-d", snapshot.name, snapshot.objectID]).text
    }
}
