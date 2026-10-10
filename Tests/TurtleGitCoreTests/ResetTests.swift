import Darwin
import XCTest
@testable import TurtleGitCore

final class ResetTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String, String) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "base-tag"])
        try Data("latest\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "latest")
        let latest = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("indexed\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("keep.txt"))
        return (root, repo, base, latest)
    }
    func testResetModesHaveExactHeadIndexAndWorkingTreeEffects() async throws {
        for mode in ResetMode.allCases {
            let (root, repo, base, latest) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let plan = try await repo.prepareReset(to: "refs/tags/base-tag", mode: mode)
            XCTAssertEqual(plan.revision, base); XCTAssertEqual(plan.originalHead, latest)
            _ = try await repo.reset(plan)
            let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            let index = try await repo.run(["show", ":file.txt"]).text
            let oldHead = try await repo.run(["rev-parse", "ORIG_HEAD"]).text.trimmingCharacters(in: .newlines)
            let branch = try await repo.branch(), tag = try await repo.run(["rev-parse", "base-tag"]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(head, base); XCTAssertEqual(oldHead, latest); XCTAssertEqual(branch, "main"); XCTAssertEqual(tag, base)
            XCTAssertEqual(index, mode == .soft ? "indexed\n" : "base\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), mode == .hard ? "base\n" : "working\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("keep.txt")), "untracked\n")
        }
    }
    func testChangedHeadOrBranchAndInvalidRevisionRejectWithoutReset() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initialIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let blob = try await repo.run(["rev-parse", "HEAD:file.txt"]).text.trimmingCharacters(in: .newlines)
        for revision in ["", "--hard", "missing-revision", blob, "bad\0revision"] {
            do { _ = try await repo.prepareReset(to: revision, mode: .hard); XCTFail("Accepted invalid revision") } catch ResetFailure.invalidRevision {}
        }
        let plan = try await repo.prepareReset(to: "HEAD^", mode: .hard)
        _ = try await repo.run(["switch", "-c", "same-head"])
        let refs = try await repo.run(["show-ref"]).stdout
        do { _ = try await repo.reset(plan); XCTFail("Accepted changed branch") } catch ResetFailure.changedHead {}
        let afterRefs = try await repo.run(["show-ref"]).stdout, index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(refs, afterRefs); XCTAssertEqual(index, initialIndex)
        let second = try await repo.prepareReset(to: "HEAD^", mode: .hard)
        _ = try await repo.commit(message: "new head from staged contents")
        let changedHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        do { _ = try await repo.reset(second); XCTFail("Accepted changed head") } catch ResetFailure.changedHead {}
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, changedHead); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "working\n")
    }
    func testBareRepositoryOnlyAllowsSoftAndDetachedResetDoesNotMoveBranch() async throws {
        let (root, repo, base, latest) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bareRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bareRoot) }
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot)
        for mode in [ResetMode.mixed, .hard] {
            do { _ = try await bare.prepareReset(to: base, mode: mode); XCTFail("Bare non-soft reset") } catch ResetFailure.workingTreeRequired {}
        }
        let plan = try await bare.prepareReset(to: base, mode: .soft); _ = try await bare.reset(plan)
        let bareHead = try await bare.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(bareHead, base)
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "file.txt"])
        _ = try await repo.run(["checkout", "--detach", latest])
        let detached = try await repo.prepareReset(to: base, mode: .mixed); XCTAssertNil(detached.originalReference)
        _ = try await repo.reset(detached)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), main = try await repo.run(["rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, base); XCTAssertEqual(main, latest)
    }
}

final class MergeAbortResetTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String) {
        let (root, original, path) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? original.executable)
        try Data("notes\n".utf8).write(to: root.appendingPathComponent("notes")); try await repo.stage(["notes"]); _ = try await repo.commit(message: "notes")
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "ours")
        try Data("local notes\n".utf8).write(to: root.appendingPathComponent("notes"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked"))
        do { var options = MergeOptions(); options.revision = "feature"; _ = try await repo.merge(options); XCTFail("Expected merge conflict") } catch is GitFailure {}
        return (root, repo, path)
    }
    func testThreeAbortModesMatchSourceResetSemanticsWithoutMovingHead() async throws {
        for mode in MergeAbortMode.allCases {
            let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout
            let conflict = try Data(contentsOf: root.appendingPathComponent(path))
            _ = try await repo.abortMerge(mode: mode)
            let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, unmerged = try await repo.conflicts()
            let mergeHead = try await repo.run(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], successfulExitCodes: 0...1).exitCode
            XCTAssertEqual(head, afterHead); XCTAssertTrue(unmerged.isEmpty); XCTAssertEqual(mergeHead, 1)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes")), mode == .hard ? "notes\n" : "local notes\n")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), mode == .mixed ? conflict : Data("ours\n".utf8))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("untracked")), "untracked\n")
        }
    }
    func testPreCancellationPreservesConflictStateAndBareRepositoriesAreRejected() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, merge = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent(path))
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.abortMerge(mode: .hard, cancellation: cancellation); XCTFail("Pre-cancelled reset ran") } catch is OperationCancellationFailure {}
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterMerge = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(merge, afterMerge)
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(file, try Data(contentsOf: root.appendingPathComponent(path)))
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        do { _ = try await bare.abortMerge(); XCTFail("Bare abort accepted") } catch MergeAbortFailure.workingTreeRequired {}
    }
    func testCancellationDuringEitherAbortPreflightReapsProcessesWithoutResetting() async throws {
        for argument in ["--is-bare-repository", "HEAD^{commit}"] {
            let (root, repo, path) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            let beforeFile = try Data(contentsOf: root.appendingPathComponent(path))
            let beforeMerge = try Data(contentsOf: root.appendingPathComponent(".git/MERGE_HEAD"))
            let ready = root.appendingPathComponent("abort-processes")
            let reset = root.appendingPathComponent("unexpected-reset")
            let helper = root.appendingPathComponent("abort-git")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = """
            #!/bin/sh
            for arg in "$@"; do
              if [ "$arg" = reset ]; then /usr/bin/touch \(quote(reset.path)); fi
              if [ "$arg" = \(quote(argument)) ]; then
                /bin/sleep 30 &
                child=$!
                /usr/bin/printf '%s\\n%s\\n' "$$" "$child" > \(quote(ready.path))
                wait "$child"
              fi
            done
            exec \(quote(repo.executable.path)) "$@"
            """
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
            let task = Task { try await slow.abortMerge(mode: .hard, cancellation: token) }
            defer { token.cancel() }
            var pids: [Int32] = []
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                pids = ((try? String(contentsOf: ready)) ?? "").split(separator: "\n").compactMap { Int32($0) }
                if pids.count == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard pids.count == 2 else { token.cancel(); _ = await task.result; XCTFail("Preflight never started"); continue }
            XCTAssertEqual(getpgid(pids[1]), pids[0])
            token.cancel()
            do { _ = try await task.value; XCTFail("Cancelled preflight continued") } catch is GitCommandCancellationFailure {}
            let stopped = Date().addingTimeInterval(5)
            while Date() < stopped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
            for pid in pids { XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: reset.path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeIndex)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), beforeFile)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/MERGE_HEAD")), beforeMerge)
        }
    }

    func testPreCancelledResetPreservesHeadIndexAndWorkingTree() async throws {
        let (root, original, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? original.executable)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "next"])
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        let plan = try await repo.prepareReset(to: "HEAD^", mode: .hard)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try await repo.run(["diff", "--cached", "--binary"]).stdout, working = try await repo.run(["diff", "--binary"]).stdout
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.reset(plan, cancellation: token); XCTFail("Pre-cancelled") } catch is OperationCancellationFailure {}
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["diff", "--cached", "--binary"]).stdout, afterWorking = try await repo.run(["diff", "--binary"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }

}
