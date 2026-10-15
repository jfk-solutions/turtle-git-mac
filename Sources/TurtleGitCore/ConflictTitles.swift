// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct ConflictIdentityOptions: Sendable, Equatable {
    public var guessBranchNames: Bool
    public init(guessBranchNames: Bool = true) { self.guessBranchNames = guessBranchNames }
    public init(defaults: UserDefaults) { guessBranchNames = !defaults.bool(forKey: "ConflictDontGuessBranchNames") }
}

/// Captured operation identities. Stage numbers remain Git's index numbering;
/// presentation swaps Mine/Theirs during rebase without swapping their contents.
public struct ConflictTitles: Sendable, Equatable {
    public struct Side: Sendable, Equatable {
        public let title: String
        public let commit: String?
    }
    public let rebase: Bool
    public let stage2: Side
    public let stage3: Side
    public var mine: Side { rebase ? stage3 : stage2 }
    public var theirs: Side { rebase ? stage2 : stage3 }
    public var base: String { "Base" }
}

extension GitRepository {
    /// GetConflictTitles/GuessRefForHash: heads, then remotes, then tags; pinned
    /// GetShortHASHLength is eight, independent of core.abbrev and hyperlink size.
    public func conflictTitles(rebase: Bool? = nil, options: ConflictIdentityOptions = .init(), cancellation: OperationCancellation? = nil) throws -> ConflictTitles {
        try cancellation?.check()
        let rebasing = try rebase ?? conflictIsRebase(cancellation: cancellation)
        func hash(_ reference: String) throws -> String? {
            let result = try run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], successfulExitCodes: 0...128, cancellation: cancellation)
            try cancellation?.check()
            guard result.exitCode == 0 else { return nil }
            let value = result.text.trimmingCharacters(in: .newlines)
            guard [40, 64].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return value
        }
        func guessed(_ hash: String) throws -> String {
            let short = String(hash.prefix(8))
            guard options.guessBranchNames else { return short }
            let result: GitResult
            do { result = try run(["for-each-ref", "--points-at", hash, "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"], cancellation: cancellation) }
            catch is GitFailure { try cancellation?.check(); return short }
            let refs = result.text.split(separator: "\n").map(String.init)
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
                if let ref = refs.first(where: { $0.hasPrefix(prefix) }) { return String(ref.dropFirst(prefix.count)) + ", " + short }
            }
            return short
        }
        func metadata(_ name: String) throws -> String? {
            let result = try run(["rev-parse", "--git-path", name], cancellation: cancellation)
            var bytes = result.stdout; if bytes.last == 10 { bytes.removeLast() }
            let path = String(decoding: bytes, as: UTF8.self)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            do {
                var text = try String(contentsOf: url, encoding: .utf8)
                if text.last == "\n" { text.removeLast() }; if text.last == "\r" { text.removeLast() }
                try cancellation?.check(); return text.isEmpty ? nil : text
            } catch is CocoaError { try cancellation?.check(); return nil }
        }
        let head = try hash("HEAD")
        if rebasing {
            var onto = "Branch being rebased onto", branch = "Branch being rebased"
            if let named = try metadata("tgitrebase.active/onto") { onto = named }
            else if options.guessBranchNames {
                for directory in ["rebase-merge", "rebase-apply"] {
                    if let value = try metadata(directory + "/onto"), let resolved = try hash(value) { onto = try guessed(resolved); break }
                }
            }
            for directory in ["tgitrebase.active", "rebase-merge", "rebase-apply"] {
                if let name = try metadata(directory + "/head-name") {
                    branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst(11)) : name
                    break
                }
            }
            let replay = try hash("REBASE_HEAD")
            try cancellation?.check()
            return ConflictTitles(rebase: true, stage2: .init(title: onto, commit: head), stage3: .init(title: branch, commit: replay))
        }
        var incoming = ConflictTitles.Side(title: "changes to-be-integrated", commit: nil)
        for reference in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            if let value = try hash(reference) {
                let identity = try reference == "MERGE_HEAD" ? guessed(value) : String(value.prefix(8))
                incoming = .init(title: reference == "REVERT_HEAD" ? "Parent of " + identity : reference + " (" + identity + ")", commit: value)
                break
            }
        }
        try cancellation?.check()
        return ConflictTitles(rebase: false, stage2: .init(title: "HEAD", commit: head), stage3: incoming)
    }
}
