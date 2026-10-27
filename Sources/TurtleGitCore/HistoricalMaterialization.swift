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
        guard RepositoryBrowserListing.validNamespaceKey(path,allowRoot:false) else {throw RevisionComparisonFailure.selection}
        let object=try comparisonObject(revision,cancellation:token)
        guard let record=try historicalTreeRecord(revision:object,path:path,cancellation:token) else {throw RevisionComparisonFailure.selection}
        return try materializedBlob(objectID:record.oid,path:path,revision:object,mode:record.mode,cancellation:token,backend:backend)
    }

    func materializedBlob(objectID: String, path: String, revision: String, mode: String,
                          cancellation: OperationCancellation, backend: GitLibGit2Configuration) throws -> ComparisonFileContent {
        try cancellation.check()
        guard [40, 64].contains(objectID.utf8.count), objectID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ["100644", "100755", "120000"].contains(mode), RepositoryBrowserListing.validNamespaceKey(path, allowRoot: false) else { throw RevisionComparisonFailure.selection }
        let executor = try backend.executor(for: .getOneFile)
        let bytes:Data
        if let executor,path.utf8.contains(0) {
            let value=try RepositoryBrowserGitPath(key:path)
            let request=try JSONSerialization.data(withJSONObject:["version":1,"oid":objectID,"pathData":value.rawData.base64EncodedString()],options:.sortedKeys)
            bytes=try run(["-c","core.precomposeunicode=false","turtlegit-materialize-blob"],cancellation:cancellation,input:request,executorOverride:executor).stdout
        } else {
            let arguments=executor == nil ? ["cat-file","blob",objectID] : ["-c","core.precomposeunicode=false","cat-file","--filters","--path="+path,objectID]
            bytes=try run(arguments,cancellation:cancellation,executorOverride:executor).stdout
        }
        try cancellation.check()
        return ComparisonFileContent(path: path, revision: .revision(revision), bytes: bytes, mode: mode, objectID:objectID)
    }
}
