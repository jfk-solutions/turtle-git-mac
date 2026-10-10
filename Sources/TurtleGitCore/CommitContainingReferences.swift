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
    public func commitContainingReferences(_ revision: String, cancellation: OperationCancellation? = nil) throws -> CommitContainingReferences {
        try cancellation?.check()
        let resolved = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: cancellation)
        let hash = String(decoding: resolved.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw GitFailure(arguments: [], code: -1, message: "Invalid resolved commit.")
        }
        let shown = try run(["show", "--encoding=UTF-8", "-s", "--format=%h%x00%s%x00%aN%x00%aI", hash, "--"], cancellation: cancellation)
        let metadata = String(decoding: shown.stdout, as: UTF8.self).trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard metadata.count == 4 else { throw GitFailure(arguments: [], code: -1, message: "Malformed commit metadata.") }
        func names(_ arguments: [String]) throws -> [GitReferenceName] {
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
        let references = try names(["for-each-ref", "--contains=" + hash, "--format=%(refname)", "refs/heads/", "refs/remotes/", "refs/tags/"])
        let completion = try names(["for-each-ref", "--format=%(refname)"])
        let bare = try isBare(cancellation: cancellation)
        try cancellation?.check()
        return CommitContainingReferences(hash: hash, abbreviatedHash: metadata[0], subject: metadata[1], author: metadata[2], authorDate: metadata[3], references: references, completion: completion, bare: bare)
    }
}
