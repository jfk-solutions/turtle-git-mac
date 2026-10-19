// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

extension GitRepository {
    /// GetOneFile is an output operation: selected libgit2 applies checkout
    /// filters, while the upstream command-line fallback returns the raw blob.
    /// Keep historicalFile/comparisonFile raw for attribution and comparisons.
    public func materializedHistoricalFile(revision: String, path: String, cancellation: OperationCancellation? = nil,
                                           backend: GitLibGit2Configuration? = nil) throws -> ComparisonFileContent {
        let backend = backend ?? libgit2Configuration ?? .load()
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard RepositoryBrowserListing.validPath(path, allowRoot: false) else { throw RevisionComparisonFailure.selection }
        let object = try comparisonObject(revision, cancellation: token)
        let records = try run(["-c", "core.precomposeunicode=false", "ls-tree", "--full-tree", "-z", object, "--", path], cancellation: token).stdout.split(separator: 0)
        for record in records {
            guard let tab = record.firstIndex(of: 9), record[record.index(after: tab)...].elementsEqual(path.utf8) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, fields[1] == "blob" else { throw RevisionComparisonFailure.selection }
            return try materializedBlob(objectID: String(fields[2]), path: path, revision: object, mode: String(fields[0]), cancellation: token, backend: backend)
        }
        throw RevisionComparisonFailure.selection
    }

    func materializedBlob(objectID: String, path: String, revision: String, mode: String,
                          cancellation: OperationCancellation, backend: GitLibGit2Configuration) throws -> ComparisonFileContent {
        try cancellation.check()
        guard [40, 64].contains(objectID.utf8.count), objectID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ["100644", "100755", "120000"].contains(mode), RepositoryBrowserListing.validPath(path, allowRoot: false) else { throw RevisionComparisonFailure.selection }
        let executor = try backend.executor(for: .getOneFile)
        let arguments = executor == nil ? ["cat-file", "blob", objectID] : ["-c", "core.precomposeunicode=false", "cat-file", "--filters", "--path=" + path, objectID]
        let bytes = try run(arguments, cancellation: cancellation, executorOverride: executor).stdout
        try cancellation.check()
        return ComparisonFileContent(path: path, revision: .revision(revision), bytes: bytes, mode: mode)
    }
}
