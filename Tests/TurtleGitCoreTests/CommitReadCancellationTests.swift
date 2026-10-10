import XCTest
@testable import TurtleGitCore

final class CommitReadCancellationTests: XCTestCase {
    func testCancelledCommitReadsDoNotFallBackToDefaultOrSpawnGit() async throws {
        let repo = GitRepository(root: URL(fileURLWithPath: "/nonexistent-TurtleGit-cancellation-fixture"), executable: URL(fileURLWithPath: "/usr/bin/false"))
        let token = OperationCancellation(); token.cancel()
        let reads: [() async throws -> Void] = [
            { _ = try await repo.commitPreferences(cancellation: token) },
            { _ = try await repo.commitOperation(cancellation: token) },
            { _ = try await repo.commitComparisonBase(amendToParent: false, cancellation: token) },
            { _ = try await repo.commitComparisonBase(amendToParent: true, cancellation: token) },
            { _ = try await repo.commitDialogStatus(amendToParent: false, cancellation: token) },
            { _ = try await repo.commitDialogStatus(amendToParent: true, cancellation: token) },
            { _ = try await repo.workingTreeFiles(cancellation: token) },
            { _ = try await repo.stagingFiles(staged: true, cancellation: token) },
            { _ = try await repo.stagingFiles(staged: false, cancellation: token) },
            { _ = try await repo.workingTreeStatus(cancellation: token) },
            { _ = try await repo.hasLFS(cancellation: token) },
            { _ = try await repo.conflictIsRebase(cancellation: token) },
            { _ = try await repo.changelists(cancellation: token) },
            { _ = try await repo.commitMessageHistoryIdentity(cancellation: token) },
            { _ = try await repo.commitMessageSeed(cancellation: token) }
        ]
        for (index, read) in reads.enumerated() {
            do { try await read(); XCTFail("Cancelled read \(index) succeeded") }
            catch OperationCancellationFailure.cancelled {}
            catch { XCTFail("Cancelled read \(index) fell through to Git/defaults: \(error)") }
        }
    }
}
