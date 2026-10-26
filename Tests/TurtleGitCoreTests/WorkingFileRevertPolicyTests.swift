import XCTest
@testable import TurtleGitCore

private final class RevertPolicyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkingFileRevertProgress] = []
    func append(_ value: WorkingFileRevertProgress) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [WorkingFileRevertProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

final class WorkingFileRevertPolicyTests: XCTestCase {
    func testIndependentDefaultsAndCapturedNonzeroPreferences() throws {
        let name = "TurtleGitRevertPolicy-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        XCTAssertEqual(WorkingFileRevertPolicy.load(from: preferences), .init())
        preferences.set(false, forKey: "RevertWithRecycleBin")
        let captured = WorkingFileRevertPolicy.load(from: preferences)
        XCTAssertEqual(captured, .init(recycle: false))
        preferences.set(2, forKey: "RevertWithRecycleBin")
        preferences.set(0, forKey: "RevertRenamedFilesWithRecycleBin")
        let renamedOff = WorkingFileRevertPolicy.load(from: preferences)
        XCTAssertEqual(renamedOff, .init(recycle: true, recycleRenamedFiles: false))
        XCTAssertFalse(captured.recycle)
        XCTAssertTrue(renamedOff.shouldRecycle(.init(path: "normal", originalPath: nil, index: "M", worktree: " ")))
        XCTAssertFalse(renamedOff.shouldRecycle(.init(path: "renamed", originalPath: "old", index: "R", worktree: "M")))
        XCTAssertFalse(renamedOff.shouldRecycle(.init(path: "added", originalPath: nil, index: "A", worktree: " ")))
    }

    func testPolicyMatrixRestoresFilesAndNamesPreservingAdditionsAndUnselectedIndex() async throws {
        for recycle in [false, true] { for rename in [false, true] {
            let (root, repo, original) = try await GitPatchTests().fixture()
            var copies: [URL] = []
            defer { for url in copies { try? FileManager.default.removeItem(at: url) }; try? FileManager.default.removeItem(at: root) }
            let normal = "normal 雪\n.txt", other = "unselected", added = ":(glob)* addition", destination = "renamed 雪.txt"
            let base = try Data(contentsOf: root.appendingPathComponent(original))
            for path in [normal, other] { try Data("base".utf8).write(to: root.appendingPathComponent(path)) }
            try await repo.stage([normal, other]); _ = try await repo.commit(message: "policy fixture")
            try Data("unselected staged".utf8).write(to: root.appendingPathComponent(other)); try await repo.stage([other])
            try Data("unselected worktree".utf8).write(to: root.appendingPathComponent(other))
            _ = try await repo.run(["mv", "--", original, destination])
            let renamedBytes = base + Data("renamed later work\n".utf8)
            try renamedBytes.write(to: root.appendingPathComponent(destination))
            let collision = Data("distinct old-name obstruction".utf8)
            try collision.write(to: root.appendingPathComponent(original))
            try Data("normal changed".utf8).write(to: root.appendingPathComponent(normal)); try await repo.stage([normal])
            let normalBytes = Data([0, 255, 13, 10]); try normalBytes.write(to: root.appendingPathComponent(normal))
            let addedBytes = Data("preserve added work".utf8); try addedBytes.write(to: root.appendingPathComponent(added)); try await repo.stage([added])
            let selected = try await repo.status().filter { [normal, destination, added].contains($0.path) }
            XCTAssertEqual(selected.count, 3)
            XCTAssertEqual(selected.first { $0.path == destination }?.originalPath, original)
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout
            let recorder = RevertPolicyEvents()
            let result = try await repo.revertWorkingFiles(selected, policy: .init(recycle: recycle, recycleRenamedFiles: rename), progress: { recorder.append($0) })
            copies = result.trashedFiles
            let expectedCopies = (recycle ? [normalBytes] : []) + (recycle && rename ? [renamedBytes, collision] : [])
            let actualCopies = try copies.map { try Data(contentsOf: $0) }
            XCTAssertEqual(Set(actualCopies), Set(expectedCopies), "master=\(recycle), renamed=\(rename)")
            XCTAssertEqual(copies.count, expectedCopies.count)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(original)), base)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(normal)), Data("base".utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(added)), addedBytes)
            let tracked = try await repo.trackedPaths()
            XCTAssertFalse(tracked.contains(added)); XCTAssertFalse(tracked.contains(destination)); XCTAssertTrue(tracked.contains(original))
            let normalIndex = try await repo.run(["show", ":" + normal]).stdout
            let originalIndex = try await repo.run(["show", ":" + original]).stdout
            let unrelatedIndex = try await repo.run(["show", ":" + other]).stdout
            let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
            XCTAssertEqual(normalIndex, Data("base".utf8)); XCTAssertEqual(originalIndex, base)
            XCTAssertEqual(unrelatedIndex, Data("unselected staged".utf8)); XCTAssertEqual(afterHead, head)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(other)), Data("unselected worktree".utf8))
            let events = recorder.snapshot, finished = events.filter(\.finished)
            XCTAssertEqual(finished.filter { $0.step == .recycle }.count, expectedCopies.count)
            XCTAssertEqual(finished.last?.completed, finished.last?.total)
            XCTAssertEqual(finished.count, 4 + expectedCopies.count) // one unstage, three literal restores
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
        } }
    }

    func testNoTrashCancellationKeepsCompletedWorkingChangesButOriginalIndexAndNoRecoveryCopies() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<70).map { String(format: "policy-%03d", $0) }
        for path in paths { try Data("base".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "cancel fixture")
        for path in paths { try Data("working".utf8).write(to: root.appendingPathComponent(path)) }
        let selected = try await repo.status(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(), recorder = RevertPolicyEvents()
        do {
            _ = try await repo.revertWorkingFiles(selected, policy: .init(recycle: false), cancellation: token, progress: { event in
                recorder.append(event); if event.finished && event.completed == 64 { token.cancel() }
            })
            XCTFail("Cancelled no-Trash operation succeeded")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertTrue(failure.wasCancelled); XCTAssertTrue(failure.trashedFiles.isEmpty)
            XCTAssertFalse(failure.localizedDescription.contains("remain recoverable"))
        }
        for path in paths.prefix(64) { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("base".utf8)) }
        for path in paths.suffix(6) { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("working".utf8)) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(recorder.snapshot.filter(\.finished).count, 64)
        XCTAssertTrue(recorder.snapshot.allSatisfy { $0.step == .restore && $0.total == 70 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
        // Retry uses current status after partial effects, without assuming an
        // unchanged original row set or pretending earlier bytes were backed up.
        let refreshed = try await repo.workingFileRevertSelection(selected)
        let result = try await repo.revertWorkingFiles(refreshed, policy: .init(recycle: false))
        XCTAssertTrue(result.trashedFiles.isEmpty)
        let status = try await repo.status(); XCTAssertTrue(status.isEmpty)
    }

    func testDisabledRenameRecyclingStillRefusesDirectoriesAndNeverFollowsOldNameSymlink() async throws {
        for policy in [WorkingFileRevertPolicy(recycle: false), .init(recycleRenamedFiles: false)] {
            let (root, repo, original) = try await GitPatchTests().fixture()
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
            let base = try Data(contentsOf: root.appendingPathComponent(original)), destination = "renamed"
            _ = try await repo.run(["mv", "--", original, destination])
            let location = root.appendingPathComponent(original)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
            try Data("obstruction".utf8).write(to: location.appendingPathComponent("child"))
            let selected = try await repo.status().filter { $0.path == destination }
            let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            do {
                _ = try await repo.revertWorkingFiles(selected, policy: policy)
                XCTFail("Disabling recycling bypassed directory preflight")
            } catch let failure as GitFailure { XCTAssertTrue(failure.localizedDescription.contains("directory")) }
            XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent("child")), Data("obstruction".utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(destination)), base)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
            try FileManager.default.removeItem(at: location)
            try Data("outside untouched".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: outside.path)
            let refreshed = try await repo.workingFileRevertSelection(selected)
            let result = try await repo.revertWorkingFiles(refreshed, policy: policy)
            XCTAssertTrue(result.trashedFiles.isEmpty)
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside untouched".utf8))
            XCTAssertEqual(try Data(contentsOf: location), base)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
        }
    }

    func testNoTrashFilterFailureKeepsIndexAndDoesNotInventRecoveryReceipt() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "filtered", location = root.appendingPathComponent(path)
        try Data("base".utf8).write(to: location)
        try Data("filtered filter=policy\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try await repo.stage([path, ".gitattributes"]); _ = try await repo.commit(message: "filter fixture")
        _ = try await repo.run(["config", "filter.policy.smudge", "false"])
        _ = try await repo.run(["config", "filter.policy.required", "true"])
        try Data("working".utf8).write(to: location)
        let selected = try await repo.status().filter { $0.path == path }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), recorder = RevertPolicyEvents()
        do {
            _ = try await repo.revertWorkingFiles(selected, policy: .init(recycle: false), progress: { recorder.append($0) })
            XCTFail("Failed checkout filter was accepted")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertFalse(failure.wasCancelled); XCTAssertTrue(failure.trashedFiles.isEmpty)
            XCTAssertFalse(failure.localizedDescription.contains("remain recoverable"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(recorder.snapshot.contains { $0.step == .recycle })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
}
