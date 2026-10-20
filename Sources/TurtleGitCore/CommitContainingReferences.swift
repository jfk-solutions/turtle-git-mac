// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// CommitIsOnRefsDlg data: refs containing the commit, not just pointing at it.
public struct CommitContainingReferences: Sendable {
    public let hash: String
    public let abbreviatedHash: String
    public let subject: String
    public let author: String
    public let authorDate: String
    public let references: [GitReferenceName]
    public let completion: [GitReferenceName]
    public let bare: Bool
    public func filtered(_ query: String) -> [GitReferenceName] {
        query.isEmpty ? references : references.filter { ($0.rawValue as NSString).range(of: query, options: .literal).location != NSNotFound }
    }
}

extension GitRepository {
    public func commitContainingReferences(_ revision: String, includeCompletion: Bool = true, useMailmap: Bool = GitIdentityDisplay().useMailmap, cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws -> CommitContainingReferences {
        let selectedBackend = backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        let details=try singleCommitDetails(revision:revision,useMailmap:useMailmap,cancellation:cancellation,backend:selectedBackend).asLogEntry()
        let hash=details.hash
        let abbreviated=try run(["rev-parse","--short",hash],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        let references: [GitReferenceName]
        if selectedBackend.requests(.branchContains) {
            let reply = try localReferenceReply(verb:"turtlegit-containing-refs",operation:"contains",request:["version":1,"revision":hash,"includeTags":true,"includeLocal":true,"includeRemote":true],backend:selectedBackend,command:.branchContains,cancellation:cancellation)
            references = sortedContainingNames(reply.names.map { GitReferenceName($0) })
        } else {
            references = try containingReferenceNames(["for-each-ref", "--contains=" + hash, "--format=%(refname)", "refs/heads/", "refs/remotes/", "refs/tags/"], cancellation: cancellation)
        }
        let completion = includeCompletion ? try commitContainingReferenceCompletion(cancellation:cancellation,backend:selectedBackend) : []
        let bare = try isBare(cancellation: cancellation)
        try cancellation?.check()
        return CommitContainingReferences(hash: hash, abbreviatedHash: abbreviated, subject: details.subject, author: details.author, authorDate: details.date, references: references, completion: completion, bare: bare)
    }
    /// Completion is initialized independently of commit validity and cached by the dialog.
    public func commitContainingReferenceCompletion(cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws -> [GitReferenceName] {
        try cancellation?.check()
        let selected = backend ?? libgit2Configuration ?? .load()
        let names:[GitReferenceName]
        if selected.enabled {
            // CGit::GetRefList uses the master flag, not FOREACHREF's bit.
            let executorConfiguration = GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.forEachRef.mask,helperURL:selected.helperURL)
            let reply = try localReferenceReply(verb:"turtlegit-ref-names",operation:"names",request:["version":1],backend:executorConfiguration,command:.forEachRef,cancellation:cancellation)
            names = reply.names.map { GitReferenceName($0) }
        } else {
            let output = try run(["show-ref","-d"],successfulExitCodes:0...1,cancellation:cancellation).stdout
            guard let text=String(data:output,encoding:.utf8) else {throw GitLocalReferenceEngineFailure.output}
            var values=[GitReferenceName]()
            for line in text.split(separator:"\n") {
                guard let space=line.firstIndex(of:" ") else {throw GitLocalReferenceEngineFailure.output}
                let raw=String(line[line.index(after:space)...])
                let name=GitReferenceName.removingSuffix("^{}",from:raw) ?? raw
                guard GitLocalReferenceProtocol.validName(name) else {throw GitLocalReferenceEngineFailure.output}
                values.append(GitReferenceName(name))
            }
            names=values
        }
        try cancellation?.check();return sortedContainingNames(names)
    }
    private func sortedContainingNames(_ names:[GitReferenceName]) -> [GitReferenceName] {
        Array(Set(names)).sorted {
            let order=$0.rawValue.localizedStandardCompare($1.rawValue)
            return order == .orderedSame ? $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) : order == .orderedAscending
        }
    }
    private func containingReferenceNames(_ arguments: [String], cancellation: OperationCancellation?) throws -> [GitReferenceName] {
        let executed = try run(arguments, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation)
        let output = String(decoding: executed.stdout, as: UTF8.self)
        var seen = Set<GitReferenceName>()
        let result = try output.split(separator: "\n").map { line -> GitReferenceName in
            try cancellation?.check()
            guard line.hasPrefix("refs/") else { throw GitFailure(arguments: arguments, code: -1, message: "Malformed reference name.") }
            return GitReferenceName(String(line))
        }.filter { seen.insert($0).inserted }
        return result.sorted {
            let order = $0.rawValue.localizedStandardCompare($1.rawValue)
            return order == .orderedSame ? $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) : order == .orderedAscending
        }
    }
}
