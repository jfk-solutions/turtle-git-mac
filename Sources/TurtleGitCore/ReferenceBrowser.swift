// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

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
    public func referenceBrowser(filter: ReferenceBrowserMergeFilter = .all, cancellation: OperationCancellation? = nil) throws -> ReferenceBrowserSnapshot {
        let atoms = ["refname", "objectname", "objecttype", "symref", "upstream", "subject", "authorname", "authoremail", "authordate:unix", "committername", "committeremail", "committerdate:unix", "taggername", "taggeremail", "taggerdate:unix"]
        var arguments = ["for-each-ref", "--sort=refname", "--format=" + atoms.map { "%(" + $0 + ")" }.joined(separator: "%00") + "%00"]
        if filter != .all { arguments += [filter == .merged ? "--merged=HEAD" : "--no-merged=HEAD"] }
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
        return ReferenceBrowserSnapshot(references: references, currentBranch: head.exitCode == 0 ? GitReferenceName(head.text.trimmingCharacters(in: .newlines)) : nil)
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
