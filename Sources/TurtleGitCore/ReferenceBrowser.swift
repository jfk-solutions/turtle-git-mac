// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum ReferenceBrowserScope: Sendable { case all, remotes }
public enum ReferenceBrowserMergeFilter: String, CaseIterable, Sendable { case all = "All", merged = "Only merged", unmerged = "Only unmerged" }
public struct BrowserReference: Sendable {
    public let name: GitReferenceName
    public let hash: String
    public let objectType: String
    public let symbolicTarget: String?
    public let upstream: String
    public let subject: String
    public let author: String
    public let authorDate: TimeInterval?
    public let committer: String
    public let committerDate: TimeInterval?
    public let description: String
}
public struct ReferenceBrowserRow: Sendable {
    public let reference: BrowserReference
    public let name: String
}
public struct ReferenceBrowserSnapshot: Sendable {
    public let references: [BrowserReference]
    public let currentBranch: GitReferenceName?
    public let headFile: URL
    public let remotes: [String]
    public func remote(for reference: GitReferenceName) -> String? {
        guard let name = GitReferenceName.removingPrefix("refs/remotes/", from: reference.rawValue) else { return nil }
        return remotes.first { GitReferenceName.equal(name, $0) || GitReferenceName.removingPrefix($0 + "/", from: name) != nil }
    }
    public var folders: [GitReferenceName] {
        var paths: Set<GitReferenceName> = ["refs"]
        for reference in references {
            let parts = reference.name.rawValue.utf8.split(separator: 47)
            guard parts.count > 1 else { continue }
            for count in 1..<parts.count { paths.insert(GitReferenceName(String(decoding: Array(parts.prefix(count).joined(separator: [47])), as: UTF8.self))) }
        }
        return paths.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
    }
    public func rows(folder: GitReferenceName, nested: Bool, query: String = "", fields: HistorySearchFields = [.referenceNames, .subject, .authors, .revisions]) -> [ReferenceBrowserRow] {
        let pattern = HistoryTextQuery(query, caseSensitive: false)
        return references.compactMap { reference in
            guard let relative = GitReferenceName.removingPrefix(folder.rawValue + "/", from: reference.name.rawValue),
                  nested || !relative.utf8.contains(47) else { return nil }
            var text = ""
            for (field, value) in [(HistorySearchFields.referenceNames, relative), (.subject, reference.subject), (.authors, reference.author), (.revisions, reference.hash)] where fields.contains(field) { text += value + "\n" }
            guard pattern.matches(text) else { return nil }
            return ReferenceBrowserRow(reference: reference, name: relative)
        }
    }
    public func initialSelection(_ requested: String) -> (folder: GitReferenceName, reference: GitReferenceName?) {
        let candidate = requested.isEmpty || requested == "HEAD" ? currentBranch?.rawValue ?? "refs/heads" : requested
        if let folder = folders.first(where: { GitReferenceName.equal($0.rawValue, candidate) }) { return (folder, nil) }
        let canonical = candidate == "refs" || GitReferenceName.removingPrefix("refs/", from: candidate) != nil
        let found = references.first { $0.name == GitReferenceName(candidate) }
            ?? (canonical ? nil : references.first { GitReferenceName.removingSuffix("/" + candidate, from: $0.name.rawValue) != nil })
        if let found {
            let bytes = Array(found.name.rawValue.utf8); let slash = bytes.lastIndex(of: 47)!
            return (GitReferenceName(String(decoding: bytes[..<slash], as: UTF8.self)), found.name)
        }
        // SelectRef/GetTreeNode keeps the deepest surviving namespace when a
        // canonical reference disappears (for example after inline rename).
        if GitReferenceName.removingPrefix("refs/", from: candidate) != nil {
            var bytes = Array(candidate.utf8)
            while let slash = bytes.lastIndex(of: 47) {
                bytes = Array(bytes[..<slash])
                let ancestor = GitReferenceName(String(decoding: bytes, as: UTF8.self))
                if folders.contains(ancestor) { return (ancestor, nil) }
            }
        }
        return (folders.contains("refs/heads") ? "refs/heads" : "refs", nil)
    }
}
public enum ReferenceBrowserFailure: LocalizedError {
    case output
    public var errorDescription: String? { "Git returned an invalid reference-browser record." }
}
extension GitRepository {
    /// BrowseRefsDlg's Current Branch accepts live HEAD, independently of the
    /// displayed catalog/filter. Keep local names canonical for native typed
    /// chooser consumers; detached HEAD returns its full object ID.
    public func referenceBrowserCurrentBranch(cancellation: OperationCancellation? = nil) throws -> String {
        let head = try run(["symbolic-ref", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation)
        if head.exitCode == 0 {
            let name = head.text.trimmingCharacters(in: .newlines)
            return GitReferenceName.removingPrefix("refs/heads/", from: name) == nil ? "HEAD" : name
        }
        return try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
    }
    public func referenceBrowser(filter: ReferenceBrowserMergeFilter = .all, scope: ReferenceBrowserScope = .all, cancellation: OperationCancellation? = nil) throws -> ReferenceBrowserSnapshot {
        let atoms = ["refname", "objectname", "objecttype", "symref", "upstream", "subject", "authorname", "authoremail", "authordate:unix", "committername", "committeremail", "committerdate:unix", "taggername", "taggeremail", "taggerdate:unix"]
        var arguments = ["for-each-ref", "--sort=refname", "--format=" + atoms.map { "%(" + $0 + ")" }.joined(separator: "%00") + "%00"]
        if filter != .all { arguments += [filter == .merged ? "--merged=HEAD" : "--no-merged=HEAD"] }
        if scope == .remotes { arguments.append("refs/remotes/") }
        let bytes = try run(arguments, cancellation: cancellation).stdout
        let values = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\0")
        var records: [[String]] = []
        var index = 0
        while index + atoms.count <= values.count {
            var record = Array(values[index..<(index + atoms.count)])
            if record[0].hasPrefix("\n") { record[0].removeFirst() }
            guard !record[0].isEmpty else { break }
            records.append(record); index += atoms.count
        }
        guard values.dropFirst(index).allSatisfy({ $0.isEmpty || $0 == "\n" }) else { throw ReferenceBrowserFailure.output }
        // Include all remote names in the gone check, independently of merge filtering.
        let remoteNames = Set(try checkoutReferences(includeAll: true, cancellation: cancellation).filter(\.remote).map { GitReferenceName($0.name) })
        var descriptions: [GitReferenceName: String] = [:]
        let configuration = try run(["config", "--null", "--get-regexp", "^branch\\..*\\.description$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        for item in String(decoding: configuration, as: UTF8.self).components(separatedBy: "\0") {
            guard let separator = item.firstIndex(of: "\n") else { continue }
            let key = String(item[..<separator])
            guard let branch = GitReferenceName.removingPrefix("branch.", from: key).flatMap({ GitReferenceName.removingSuffix(".description", from: $0) }) else { continue }
            descriptions[GitReferenceName("refs/heads/" + branch)] = String(item[item.index(after: separator)...])
        }
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func identity(_ record: [String], committer: Bool) -> (String, String, TimeInterval?) {
            let offset = committer ? 9 : 6
            let useTagger = record[offset].isEmpty
            let start = useTagger ? (record[2] == "commit" ? 9 : 12) : offset
            let date = TimeInterval(record[start + 2]).flatMap { $0 == 0 ? nil : $0 }
            return (clean(record[start]), clean(record[start + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")), date)
        }
        var contacts: [GitReferenceName] = [], unique = Set<GitReferenceName>()
        for record in records { for committer in [false, true] {
            let (name, email, _) = identity(record, committer: committer)
            guard !name.isEmpty, !email.isEmpty else { continue }
            let contact = GitReferenceName(name + " <" + email + ">")
            if unique.insert(contact).inserted { contacts.append(contact) }
        } }
        var mailmap: [GitReferenceName: String] = [:]
        for start in stride(from: 0, to: contacts.count, by: 200) {
            let batch = Array(contacts[start..<min(start + 200, contacts.count)])
            let output = try run(["check-mailmap", "--"] + batch.map(\.rawValue), cancellation: cancellation).text
            var lines = output.components(separatedBy: "\n"); if lines.last == "" { lines.removeLast() }
            guard lines.count == batch.count else { throw ReferenceBrowserFailure.output }
            for (contact, value) in zip(batch, lines) { if let email = value.range(of: " <", options: .backwards) { mailmap[contact] = String(value[..<email.lowerBound]) } }
        }
        let references = records.map { record -> BrowserReference in
            let name = GitReferenceName(record[0]), author = identity(record, committer: false), committer = identity(record, committer: true)
            let upstream = record[4]
            var upstreamLabel = GitReferenceName.removingPrefix("refs/", from: upstream) ?? upstream
            upstreamLabel = GitReferenceName.removingPrefix("remotes/", from: upstreamLabel) ?? upstreamLabel
            if !upstream.isEmpty, !remoteNames.contains(GitReferenceName(upstream)) { upstreamLabel = "(gone: " + upstreamLabel + ")" }
            func display(_ identity: (String, String, TimeInterval?)) -> String { mailmap[GitReferenceName(identity.0 + " <" + identity.1 + ">")] ?? identity.0 }
            return BrowserReference(name: name, hash: record[1], objectType: record[2], symbolicTarget: record[3].isEmpty ? nil : record[3], upstream: upstreamLabel, subject: clean(record[5]), author: display(author), authorDate: author.2, committer: display(committer), committerDate: committer.2, description: descriptions[name] ?? "")
        }
        let head = try run(["symbolic-ref", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation)
        let path = try run(["rev-parse", "--git-path", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let headFile = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return ReferenceBrowserSnapshot(references: references, currentBranch: head.exitCode == 0 ? GitReferenceName(head.text.trimmingCharacters(in: .newlines)) : nil, headFile: headFile, remotes: try self.remoteNames(cancellation: cancellation))
    }
}

// BrowseRefsDlg's inline label editor composes the new canonical name from the
// selected tree folder, and delegates non-forcing rename semantics to Git.
extension GitRepository {
    public func renameBrowserBranch(_ reference: GitReferenceName, folder: GitReferenceName, label: String, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard let old = GitReferenceName.removingPrefix("refs/heads/", from: reference.rawValue) else { throw ReferenceBrowserRenameFailure.localBranchOnly }
        let canonical = folder.rawValue + "/" + label
        guard let new = GitReferenceName.removingPrefix("refs/heads/", from: canonical) else { throw ReferenceBrowserRenameFailure.namespaceChange }
        _ = try run(["-c", "core.precomposeunicode=false", "branch", "-m", old, "--", new], cancellation: cancellation)
    }
}
public enum ReferenceBrowserRenameFailure: LocalizedError {
    case localBranchOnly, namespaceChange
    public var errorDescription: String? {
        switch self {
        case .localBranchOnly: return "Only local branches can be renamed."
        case .namespaceChange: return "The reference type cannot be changed. Keep the new name within refs/heads/."
        }
    }
}

// BrowseRefsDlg's tracked-branch commands. Git validates the remote fetch mapping
// for Set; Drop removes just remote and merge rather than other branch settings.
extension GitRepository {
    public func updateBrowserTracking(_ reference: GitReferenceName, upstream: GitReferenceName?, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard let local = GitReferenceName.removingPrefix("refs/heads/", from: reference.rawValue) else { throw ReferenceBrowserRenameFailure.localBranchOnly }
        if let upstream {
            guard let short = GitReferenceName.removingPrefix("refs/remotes/", from: upstream.rawValue) else { throw ReferenceBrowserTrackingFailure.remoteBranchRequired }
            let remotes = try run(["remote"], cancellation: cancellation).text.split(separator: "\n").map(String.init)
            guard remotes.contains(where: { GitReferenceName.removingPrefix($0 + "/", from: short) != nil || GitReferenceName.equal($0, short) }) else { throw ReferenceBrowserTrackingFailure.remoteBranchRequired }
            do { _ = try run(["-c", "core.precomposeunicode=false", "branch", "--set-upstream-to=" + short, "--", local], cancellation: cancellation) }
            catch let failure as GitFailure { throw ReferenceBrowserTrackingFailure.fetchMapping(failure.message) }
        } else {
            for suffix in ["remote", "merge"] {
                try cancellation?.check()
                do { _ = try run(["-c", "core.precomposeunicode=false", "config", "--local", "--unset-all", "branch." + local + "." + suffix], cancellation: cancellation) }
                catch let failure as GitFailure where failure.code == 5 { /* Already absent. */ }
            }
        }
    }
}
public enum ReferenceBrowserTrackingFailure: LocalizedError {
    case remoteBranchRequired, fetchMapping(String)
    public var errorDescription: String? {
        switch self {
        case .remoteBranchRequired: return "Select a remote-tracking branch belonging to a configured remote."
        case .fetchMapping(let message): return message + "\n\nThis is usually caused when the remote's fetch setting does not include the desired branch."
        }
    }
}

/// Single-reference BrowseRefsDlg deletion; remote branches are deleted by Push.
public enum ReferenceBrowserDeletionKind: Sendable {
    case branch, remoteBranch, tag
    public init?(reference: GitReferenceName) {
        if GitReferenceName.removingPrefix("refs/heads/", from: reference.rawValue)?.isEmpty == false { self = .branch }
        else if GitReferenceName.removingPrefix("refs/remotes/", from: reference.rawValue)?.isEmpty == false { self = .remoteBranch }
        else if GitReferenceName.removingPrefix("refs/tags/", from: reference.rawValue)?.isEmpty == false { self = .tag }
        else { return nil }
    }
    public var title: String {
        switch self { case .branch: return "Delete branch"; case .remoteBranch: return "Delete remote branch"; case .tag: return "Delete tag" }
    }
    fileprivate var prefix: String {
        switch self { case .branch: return "refs/heads/"; case .remoteBranch: return "refs/remotes/"; case .tag: return "refs/tags/" }
    }
}
public struct ReferenceBrowserDeletionConfirmation: Sendable {
    public let reference: GitReferenceName
    public let kind: ReferenceBrowserDeletionKind
    public let name: String
    public let unmerged: Bool
    public var warning: Bool { unmerged || kind == .remoteBranch }
    public var message: String {
        var text = "Do you really want to delete \"" + name + "\"?"
        if unmerged { text += "\n\nThis branch is not fully merged into HEAD." }
        if kind == .remoteBranch { text += "\n\nThis action will remove the branches on the remote." }
        return text
    }
}
public enum ReferenceBrowserDeletionFailure: LocalizedError {
    case namespace
    public var errorDescription: String? { "Only local branches, remote branches and tags can be deleted here." }
}
extension GitRepository {
    public func browserDeletionConfirmation(_ reference: GitReferenceName, cancellation: OperationCancellation? = nil) throws -> ReferenceBrowserDeletionConfirmation {
        let token = cancellation ?? OperationCancellation()
        guard let kind = ReferenceBrowserDeletionKind(reference: reference), !reference.rawValue.contains("\0") else { throw ReferenceBrowserDeletionFailure.namespace }
        _ = try run(["check-ref-format", reference.rawValue], cancellation: token)
        var unmerged = false
        if kind != .tag {
            do { unmerged = try run(["-c", "core.precomposeunicode=false", "merge-base", "--is-ancestor", reference.rawValue, "HEAD"], successfulExitCodes: 0...1, cancellation: token).exitCode != 0 }
            catch { try token.check(); unmerged = true }
        }
        return ReferenceBrowserDeletionConfirmation(reference: reference, kind: kind, name: GitReferenceName.removingPrefix(kind.prefix, from: reference.rawValue)!, unmerged: unmerged)
    }
    public func deleteBrowserReference(_ reference: GitReferenceName, cancellation: OperationCancellation? = nil) throws {
        // The POSIX argv path retains canonical UTF-8 even without caller cancellation.
        let token = cancellation ?? OperationCancellation()
        guard let kind = ReferenceBrowserDeletionKind(reference: reference), !reference.rawValue.contains("\0") else { throw ReferenceBrowserDeletionFailure.namespace }
        _ = try run(["check-ref-format", reference.rawValue], cancellation: token)
        let name = GitReferenceName.removingPrefix(kind.prefix, from: reference.rawValue)!
        switch kind {
        case .branch: _ = try run(["-c", "core.precomposeunicode=false", "branch", "-D", "--", name], cancellation: token)
        case .tag: _ = try run(["-c", "core.precomposeunicode=false", "tag", "-d", "--", name], cancellation: token)
        case .remoteBranch:
            // Source scans configured names in order; unknown remote refs do no work.
            let remotes = try remoteNames(cancellation: token)
            guard let remote = remotes.first(where: { GitReferenceName.equal(name, $0) || GitReferenceName.removingPrefix($0 + "/", from: name) != nil }) else { return }
            let branch = GitReferenceName.removingPrefix(remote + "/", from: name) ?? ""
            _ = try run(["-c", "core.precomposeunicode=false", "push", "--", remote, ":refs/heads/" + branch], cancellation: token)
        }
    }
}

/// BrowseRefsDlg puts the last selected reference on the right of Log ranges.
public struct ReferenceBrowserRange: Sendable {
    public let from: GitReferenceName
    public let to: GitReferenceName
    public init?(references: [GitReferenceName], lastSelected: GitReferenceName?) {
        guard references.count == 2, references[0] != references[1] else { return nil }
        if lastSelected == references[0] { from = references[1]; to = references[0] }
        else { from = references[0]; to = references[1] }
    }
    public func history(symmetric: Bool = false) -> HistoryRevisionRange { HistoryRevisionRange(from: from.rawValue, to: to.rawValue, kind: symmetric ? .symmetricDifference : .difference) }
    public func revision(symmetric: Bool = false) -> String { from.rawValue + (symmetric ? "..." : "..") + to.rawValue }
    public func label(symmetric: Bool = false) -> String {
        func short(_ name: GitReferenceName) -> String {
            GitReferenceName.removingPrefix("refs/heads/", from: name.rawValue) ?? GitReferenceName.removingPrefix("refs/", from: name.rawValue) ?? name.rawValue
        }
        return short(from) + (symmetric ? "..." : "..") + short(to)
    }
}
