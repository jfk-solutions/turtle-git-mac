import XCTest
@testable import TurtleGitCore

final class GitWorktreeTests: XCTestCase {
    private final class OutputCapture: @unchecked Sendable {
        let lock = NSLock(); var stdout = Data(), stderr = Data()
        func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; if chunk.stream == .stdout { stdout.append(chunk.data) } else { stderr.append(chunk.data) } }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdout + stderr, as: UTF8.self) }
    }
    func testWorktreeCommandOutputCallbacksExcludeValidationAndRetainDiagnostics() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("streamed")
        let creation = OutputCapture()
        let raw = try await repo.createWorktree(at: path, onOutput: creation.append)
        XCTAssertFalse(raw.isEmpty); XCTAssertEqual(creation.text, raw)
        let lock = OutputCapture(); let locked = try await repo.lockWorktree(at: path, onOutput: lock.append)
        XCTAssertEqual(lock.text, locked)
        let duplicate = OutputCapture()
        do { _ = try await repo.lockWorktree(at: path, onOutput: duplicate.append); XCTFail("Duplicate lock accepted") }
        catch let error as GitFailure { XCTAssertFalse(duplicate.text.isEmpty); XCTAssertEqual(duplicate.text, error.message) }
        let unlock = OutputCapture(); let unlocked = try await repo.unlockWorktree(at: path, onOutput: unlock.append); XCTAssertEqual(unlock.text, unlocked)
        let removal = OutputCapture(); let removed = try await repo.removeWorktree(at: path, onOutput: removal.append); XCTAssertEqual(removal.text, removed)
        let prune = OutputCapture(); let pruned = try await repo.pruneWorktrees(onOutput: prune.append); XCTAssertEqual(prune.text, pruned)
        let remaining = try await repo.worktrees(); XCTAssertEqual(remaining.count, 1)
    }

    func fixture() async throws -> (URL, GitRepository) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWorktrees-" + UUID().uuidString)
        let root = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Worktree Test"])
        _ = try await repo.run(["config", "user.email", "worktree@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("original\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "Initial")
        return (base, repo)
    }

    func testHeadDefaultsToDirectoryBranchAndPreservesMainIndexAndFiles() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try Data("staged\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        try Data("working\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        let before = try await repo.run(["rev-parse", "HEAD"]).text
        let path = base.appendingPathComponent("topic")
        _ = try await repo.createWorktree(at: path)
        let records = try await repo.worktrees()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isMain)
        XCTAssertEqual(records[1].branch, "refs/heads/topic")
        let after = try await repo.run(["rev-parse", "HEAD"]).text
        let index = try await repo.run(["show", ":file.txt"]).text
        XCTAssertEqual(before, after); XCTAssertEqual(index, "staged\n")
        XCTAssertEqual(try String(contentsOf: repo.root.appendingPathComponent("file.txt"), encoding: .utf8), "working\n")
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("file.txt"), encoding: .utf8), "original\n")
        let fromLinked = try await GitRepository(root: path).worktrees()
        XCTAssertEqual(records, fromLinked)
    }

    func testDetachedNoCheckoutAndNewBranchAtHistoricalRevision() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let initial = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("later\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Later")
        var options = WorktreeCreationOptions(); options.detach = true; options.checkout = false
        let detached = base.appendingPathComponent("detached")
        _ = try await repo.createWorktree(at: detached, options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: detached.appendingPathComponent("file.txt").path))
        var records = try await repo.worktrees()
        XCTAssertTrue(try XCTUnwrap(records.first(where: { $0.path.lastPathComponent == "detached" })).isDetached)
        options.detach = false; options.checkout = true; options.newBranch = "historical"; options.revision = initial
        let historical = base.appendingPathComponent("historical-files")
        _ = try await repo.createWorktree(at: historical, options: options)
        records = try await repo.worktrees()
        let record = try XCTUnwrap(records.first(where: { $0.path.lastPathComponent == "historical-files" }))
        XCTAssertEqual(record.head, initial); XCTAssertEqual(record.branch, "refs/heads/historical")
        XCTAssertEqual(try String(contentsOf: historical.appendingPathComponent("file.txt"), encoding: .utf8), "original\n")
    }

    func testNewlinePathsAndLockReasonsRoundTripAndLockedRemovalFails() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("turtle ü\n checkout")
        var options = WorktreeCreationOptions(); options.detach = true
        _ = try await repo.createWorktree(at: path, options: options)
        _ = try await repo.lockWorktree(at: path, reason: "Portable disk\nnot connected")
        var records = try await repo.worktrees()
        let record = try XCTUnwrap(records.first(where: { !$0.isMain }))
        XCTAssertEqual(record.path.path, path.standardizedFileURL.path)
        XCTAssertEqual(record.lockReason, "Portable disk\nnot connected")
        do { _ = try await repo.removeWorktree(at: path, force: true); XCTFail("A single Force must not override a lock") } catch is GitFailure {}
        _ = try await repo.unlockWorktree(at: path)
        records = try await repo.worktrees(); XCTAssertNil(records.last?.lockReason)
        _ = try await repo.removeWorktree(at: path)
        records = try await repo.worktrees(); XCTAssertEqual(records.count, 1)
    }

    func testManagementAcceptsPathsWithoutDirectoryURLHint() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = URL(fileURLWithPath: base.appendingPathComponent("directory-hint").path, isDirectory: false)
        _ = try await repo.createWorktree(at: path)
        let records = try await repo.worktrees()
        let registered = try XCTUnwrap(records.first(where: { !$0.isMain }))
        XCTAssertTrue(registered.path.hasDirectoryPath)
        XCTAssertFalse(path.hasDirectoryPath)
        _ = try await repo.lockWorktree(at: path)
        _ = try await repo.unlockWorktree(at: path)
        _ = try await repo.removeWorktree(at: path)
        let remaining = try await repo.worktrees()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].isMain)
    }

    func testDirtyRemovalRequiresForceAndMainAndUnregisteredPathsAreProtected() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("dirty")
        _ = try await repo.createWorktree(at: path)
        try Data("untracked".utf8).write(to: path.appendingPathComponent("new.txt"))
        do { _ = try await repo.removeWorktree(at: path); XCTFail("Dirty worktree requires Force") } catch is GitFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("new.txt").path))
        for target in [repo.root, base] {
            do { _ = try await repo.removeWorktree(at: target, force: true); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
            do { _ = try await repo.lockWorktree(at: target); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
            do { _ = try await repo.unlockWorktree(at: target); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
        }
        _ = try await repo.removeWorktree(at: path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.path))
    }

    func testPruneProtectsLockedMissingWorktreesAndUnlockWorksForMissingPaths() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let locked = base.appendingPathComponent("locked"), missing = base.appendingPathComponent("missing")
        _ = try await repo.createWorktree(at: locked); _ = try await repo.createWorktree(at: missing)
        _ = try await repo.lockWorktree(at: locked)
        let before = try await repo.worktrees()
        let lockedID = try XCTUnwrap(before.first(where: { $0.path.lastPathComponent == "locked" })).id
        try FileManager.default.removeItem(at: locked); try FileManager.default.removeItem(at: missing)
        _ = try await repo.pruneWorktrees()
        var records = try await repo.worktrees(); XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.id, lockedID, "Registered identity must survive Foundation's missing-path alias change")
        XCTAssertEqual(records.last?.lockReason, "")
        _ = try await repo.unlockWorktree(at: locked); _ = try await repo.pruneWorktrees()
        records = try await repo.worktrees(); XCTAssertEqual(records.count, 1)
    }

    func testForceNeverResetsExistingBranchAndInvalidOptionsDoNotCreateDirectories() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("target")
        let before = try await repo.run(["rev-parse", "main"]).text
        var options = WorktreeCreationOptions(); options.force = true; options.newBranch = "main"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Force is not -B") } catch is GitFailure {}
        options.newBranch = "--help"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Invalid name") } catch WorktreeFailure.invalidBranch {}
        options.newBranch = "valid"; options.detach = true
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Contradictory options") } catch WorktreeFailure.conflictingOptions {}
        options.detach = false; options.revision = "--help"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Invalid revision") } catch WorktreeFailure.invalidRevision {}
        let after = try await repo.run(["rev-parse", "main"]).text
        XCTAssertEqual(before, after); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        // An explicit existing branch remains checked out elsewhere unless Force is enabled.
        options.newBranch = nil; options.revision = "main"; options.force = false
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Branch already checked out") } catch is GitFailure {}
        options.force = true; _ = try await repo.createWorktree(at: path, options: options)
        let branch = try await GitRepository(root: path).branch(); XCTAssertEqual(branch, "main")
    }

    func testBareMainAndUnknownPorcelainAttributes() {
        let records = GitWorktree.parse(Data("worktree /repo.git\0bare\0\0worktree /linked\0HEAD abc\0branch refs/heads/main\0future attribute\0prunable missing\0\0".utf8))
        XCTAssertEqual(records.count, 2); XCTAssertTrue(records[0].isMain); XCTAssertTrue(records[0].isBare)
        XCTAssertFalse(records[1].isMain); XCTAssertEqual(records[1].pruneReason, "missing")
    }

    func testCancelledCreationDoesNotCreateCheckoutOrBranch() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("cancelled")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.createWorktree(at: path, cancellation: token); XCTFail("Already cancelled") } catch OperationCancellationFailure.cancelled {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let records = try await repo.worktrees(); XCTAssertEqual(records.count, 1)
        let exists = try await repo.run(["show-ref", "--verify", "--quiet", "refs/heads/cancelled"], successfulExitCodes: 0...1).exitCode
        XCTAssertEqual(exists, 1)
    }

    func testCancelledManagementLeavesCheckoutAndLockStateIntact() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("managed")
        _ = try await repo.createWorktree(at: path)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.lockWorktree(at: path, cancellation: token); XCTFail("Cancelled lock") } catch OperationCancellationFailure.cancelled {}
        _ = try await repo.lockWorktree(at: path)
        do { _ = try await repo.unlockWorktree(at: path, cancellation: token); XCTFail("Cancelled unlock") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.removeWorktree(at: path, force: true, cancellation: token); XCTFail("Cancelled removal") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.pruneWorktrees(cancellation: token); XCTFail("Cancelled prune") } catch OperationCancellationFailure.cancelled {}
        let rows = try await repo.worktrees()
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.last?.lockReason, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testBareRepositoryCanCreateAndManageLinkedCheckout() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let barePath = base.appendingPathComponent("source.git")
        _ = try await repo.run(["clone", "--bare", "--", repo.root.path, barePath.path])
        let bare = GitRepository(root: barePath), linked = base.appendingPathComponent("from-bare")
        _ = try await bare.createWorktree(at: linked)
        let records = try await bare.worktrees()
        XCTAssertEqual(records.count, 2); XCTAssertTrue(records[0].isMain); XCTAssertTrue(records[0].isBare)
        XCTAssertEqual(records[1].branch, "refs/heads/from-bare")
        _ = try await bare.lockWorktree(at: linked)
        _ = try await bare.unlockWorktree(at: linked)
        _ = try await bare.removeWorktree(at: linked)
        let remaining = try await bare.worktrees(); XCTAssertEqual(remaining.count, 1)
    }
    func testCancelledWorktreeListDoesNotRead() async throws {
        let (base,repo)=try await fixture(); defer { try? FileManager.default.removeItem(at:base) }
        let token=OperationCancellation();token.cancel()
        do { _ = try await repo.worktrees(cancellation:token); XCTFail("Cancelled list") } catch OperationCancellationFailure.cancelled {}
    }

    func testRunningCreationAndManagementPreflightsCancelWithoutMutation() async throws {
        let (base,repo)=try await fixture();defer { try? FileManager.default.removeItem(at:base) }
        let managed=base.appendingPathComponent("managed")
        _ = try await repo.createWorktree(at:managed)
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let beforeRefs=try await repo.run(["show-ref"]).stdout
        let beforeIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        for phase in ["check-ref-format","rev-parse","worktree"] {
            let wrapper=base.appendingPathComponent("preflight-"+phase)
            try """
            #!/bin/sh
            if [ "$4" = "\(phase)" ]; then
                : > "$0.started"
                /bin/sleep 30
            fi
            exec /usr/bin/git "$@"

            """.write(to:wrapper,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            let delayed=GitRepository(root:repo.root,executable:wrapper),token=OperationCancellation()
            let destination=base.appendingPathComponent("cancel-"+phase)
            let task=Task {
                if phase == "worktree" { _ = try await delayed.lockWorktree(at:managed,cancellation:token) }
                else {
                    var options=WorktreeCreationOptions()
                    if phase == "check-ref-format" { options.newBranch="new-preflight" } else { options.revision="HEAD~0" }
                    _ = try await delayed.createWorktree(at:destination,options:options,cancellation:token)
                }
            }
            let marker=URL(fileURLWithPath:wrapper.path+".started"),deadline=Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath:marker.path),Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"Observed running \(phase) preflight")
            let cancelledAt=Date();token.cancel()
            do { try await task.value; XCTFail("Preflight completed after cancellation") }
            catch is GitCommandCancellationFailure {} catch OperationCancellationFailure.cancelled {}
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt),10)
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let afterRefs=try await repo.run(["show-ref"]).stdout
        let afterIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        XCTAssertEqual(beforeHead,afterHead);XCTAssertEqual(beforeRefs,afterRefs);XCTAssertEqual(beforeIndex,afterIndex)
        let records=try await repo.worktrees();XCTAssertEqual(records.count,2)
        XCTAssertNil(records.last?.lockReason)
    }

}
