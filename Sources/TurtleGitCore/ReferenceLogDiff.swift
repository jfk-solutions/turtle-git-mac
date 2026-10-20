import Foundation

public enum ReferenceLogDiffMode: Hashable, Sendable {
    case parent(Int), allParents, onlyMergedFiles, extraChanges
}
public struct ReferenceLogDiffResult: Sendable {
    public let bytes: Data
    public let noExtraChanges: Bool
}
extension GitRepository {
    private func referenceLogCommit(_ revision:String,cancellation:OperationCancellation?) throws -> String {
        String(decoding:try run(["rev-parse","--verify","--end-of-options",revision + "^{commit}"],cancellation:cancellation).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
    }
    public func referenceLogDiffParents(_ revision:String,cancellation:OperationCancellation? = nil) throws -> [LogParentChoice] {
        let hash = try referenceLogCommit(revision,cancellation:cancellation)
        let parents=String(decoding:try run(["rev-list","--parents","-n","1",hash,"--"],cancellation:cancellation).stdout,as:UTF8.self).split(whereSeparator:\.isWhitespace).dropFirst().map(String.init)
        return try parents.enumerated().map { index, parent in
            try cancellation?.check()
            let subject=(try? singleCommitDetails(revision:parent,cancellation:cancellation).asLogEntry())?.subject
            try cancellation?.check()
            return LogParentChoice(number: index + 1, hash: parent, subject: subject)
        }
    }
    public func referenceLogUnifiedDiff(_ revision:String,mode:ReferenceLogDiffMode,cancellation:OperationCancellation? = nil) throws -> ReferenceLogDiffResult {
        let hash = try referenceLogCommit(revision,cancellation:cancellation)
        let parents=String(decoding:try run(["rev-list","--parents","-n","1",hash,"--"],cancellation:cancellation).stdout,as:UTF8.self).split(whereSeparator:\.isWhitespace).dropFirst().map(String.init)
        let flags = ["--no-ext-diff", "--no-textconv", "--no-color"]
        let arguments: [String]
        switch mode {
        case .parent(let number):
            guard number > 0 && number <= parents.count else { throw RevisionComparisonFailure.range }
            arguments = ["diff-tree", "-r", "-p", "--stat"] + flags + [parents[number - 1], hash, "--"]
        case .allParents, .onlyMergedFiles:
            guard parents.count > 1 else { throw RevisionComparisonFailure.range }
            arguments = ["diff-tree", "-r", "-p", mode == .allParents ? "-m" : "-c", "--stat"] + flags + [hash, "--"]
        case .extraChanges:
            guard parents.count > 1 else { throw RevisionComparisonFailure.range }
            arguments = ["diff-tree", "--cc"] + flags + [hash, "--"]
        }
        let bytes = try run(arguments,cancellation:cancellation).stdout
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        let noExtra = mode == .extraChanges && (lines.count < 2 || lines[0] != Data(hash.utf8) || lines[1].isEmpty)
        return ReferenceLogDiffResult(bytes: bytes, noExtraChanges: noExtra)
    }
    public func referenceLogUnifiedDiff(from:String,to:String,cancellation:OperationCancellation? = nil) throws -> Data {
        let old = try referenceLogCommit(from,cancellation:cancellation), new = try referenceLogCommit(to,cancellation:cancellation)
        return try run(["diff-tree", "-r", "-p", "--stat", "--no-ext-diff", "--no-textconv", "--no-color", old, new, "--"],cancellation:cancellation).stdout
    }
}
