import XCTest
import Darwin
@testable import TurtleGitCore

final class StashRestoreTests: XCTestCase {
    func testApplyRetainsThenPopDropsStashWithoutRestoringIndexByDefault() async throws {
        let (root, repo, path) = try await StashTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = StashSaveOptions(); options.all = true
        let saved = try await repo.saveStash(options)
        let applied = try await repo.restoreStash(pop: false)
        XCTAssertFalse(applied.conflicted)
        let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
        let index = try await repo.diff(staged: true)
        XCTAssertEqual(stash, saved.current); XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "working\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ignored").path))
        // Restore the clean fixture through Git itself before testing Pop.
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        _ = try await repo.run(["clean", "-fdx"])
        let popped = try await repo.restoreStash(pop: true)
        XCTAssertFalse(popped.conflicted)
        do { _ = try await repo.run(["rev-parse", "--verify", "refs/stash"]); XCTFail("Successful pop must remove the only stash") } catch is GitFailure {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "working\n")
    }
    func testConflictedPopRetainsStashAndUnmergedEntries() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("stashed\n".utf8).write(to: root.appendingPathComponent(path))
        let saved = try await repo.saveStash(StashSaveOptions())
        try Data("new head\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "divergent head")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let result = try await repo.restoreStash(pop: true)
        XCTAssertTrue(result.conflicted)
        let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        let status = try await repo.status()
        XCTAssertEqual(stash, saved.current); XCTAssertEqual(head, afterHead)
        XCTAssertEqual(status.first?.state, .conflicted)
        let unmerged = try await repo.run(["ls-files", "-u", "-z"]).stdout
        XCTAssertFalse(unmerged.isEmpty)
    }
    func testSelectedApplyNormalizesUpstreamRefFormsWithoutDroppingNewerStash() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for text in ["older\n", "newer\n"] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
            _ = try await repo.saveStash(StashSaveOptions())
        }
        let latest = try await repo.run(["rev-parse", "refs/stash"]).text
        for ref in ["refs/stash@{1}", "stash{1}"] {
            let result = try await repo.restoreStash(pop: false, reference: ref)
            XCTAssertFalse(result.conflicted)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "older\n")
            let current = try await repo.run(["rev-parse", "refs/stash"]).text
            XCTAssertEqual(current, latest)
            _ = try await repo.run(["reset", "--hard", "HEAD"])
        }
    }
    func testMissingStashAndOverwrittenLocalChangesFailWithoutDroppingOrMutating() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.restoreStash(pop: false); XCTFail("Missing stash accepted") } catch is GitFailure {}
        try Data("stashed\n".utf8).write(to: root.appendingPathComponent(path))
        let saved = try await repo.saveStash(StashSaveOptions())
        try Data("local\n".utf8).write(to: root.appendingPathComponent(path))
        for pop in [false, true] {
            do { _ = try await repo.restoreStash(pop: pop); XCTFail("Overwrite accepted") } catch is GitFailure {}
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "local\n")
            let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(stash, saved.current)
        }
        do { _ = try await repo.restoreStash(pop: false, reference: "--help"); XCTFail("Option accepted as revision") } catch is GitFailure {}
        do { _ = try await repo.restoreStash(pop: false, reference: "stash\0@{0}"); XCTFail("NUL reference accepted") } catch is GitFailure {}
    }
    func testPreCancelledApplyPopAndSelectedResolutionLeaveStateUnchanged() async throws {
        let (root,repo,path) = try await StashTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try await repo.saveStash(StashSaveOptions())
        let before = try await repo.run(["rev-parse","HEAD","refs/stash"]).stdout
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")), file = try Data(contentsOf:root.appendingPathComponent(path))
        for (pop,reference) in [(false,Optional<String>.none),(true,nil),(false,"stash@{0}")] {
            let token = OperationCancellation(); token.cancel()
            do { _ = try await repo.restoreStash(pop:pop,reference:reference,cancellation:token); XCTFail("Pre-cancelled restore accepted") } catch OperationCancellationFailure.cancelled {}
        }
        let after = try await repo.run(["rev-parse","HEAD","refs/stash"]).stdout
        XCTAssertEqual(before,after); XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
    }
    func testCancellationTerminatesOwnedApplyAndPopProcesses() async throws {
        let (root,repo,path) = try await StashTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try await repo.saveStash(StashSaveOptions())
        let before = try await repo.run(["rev-parse","HEAD","refs/stash"]).stdout
        let file = try Data(contentsOf:root.appendingPathComponent(path)), index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        func quote(_ text:String) -> String { "'" + text.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        for pop in [false,true] {
            let marker = root.appendingPathComponent(pop ? "pop.pid" : "apply.pid"), wrapper = root.appendingPathComponent("restore-wrapper")
            let script = "#!/bin/sh\ncase \" $* \" in *\" stash "+(pop ? "pop":"apply")+" \"*) printf '%s' \"$$\" > "+quote(marker.path)+"; printf 'owned restore waiting\\n' >&2; sleep 30 & wait;; *) exec "+quote(repo.executable.path)+" \"$@\";; esac\n"
            try Data(script.utf8).write(to:wrapper); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            let wrapped = GitRepository(root:root,executable:wrapper), token = OperationCancellation()
            let task = Task { try await wrapped.restoreStash(pop:pop,cancellation:token) }
            var pid:Int32?
            for _ in 0..<1000 { pid = (try? String(contentsOf:marker,encoding:.utf8)).flatMap(Int32.init); if pid != nil { break }; try await Task.sleep(nanoseconds:5_000_000) }
            token.cancel()
            do { _ = try await task.value; XCTFail("Cancelled restore succeeded") } catch let error as GitCommandCancellationFailure { XCTAssertTrue(error.result.text.contains("owned restore waiting")) }
            let owned = try XCTUnwrap(pid); XCTAssertEqual(Darwin.kill(owned,0),-1); XCTAssertEqual(errno,ESRCH)
        }
        let after = try await repo.run(["rev-parse","HEAD","refs/stash"]).stdout
        XCTAssertEqual(before,after); XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testReplayStashConditionChecksTrackedChangesAndGitBooleanWithoutCherryPickAutostash() async throws {
        let (root,repo,path) = try await StashTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        var condition = try await repo.replayStashCondition(cherryPick:false)
        XCTAssertTrue(condition.dirty); XCTAssertFalse(condition.automatic)
        _ = try await repo.run(["config","rebase.autostash","yes"])
        condition = try await repo.replayStashCondition(cherryPick:false)
        XCTAssertTrue(condition.automatic)
        condition = try await repo.replayStashCondition(cherryPick:true)
        XCTAssertTrue(condition.dirty); XCTAssertFalse(condition.automatic)
        _ = try await repo.saveStash(StashSaveOptions())
        condition = try await repo.replayStashCondition(cherryPick:false)
        XCTAssertFalse(condition.dirty); XCTAssertTrue(condition.automatic)
        try Data("staged only\n".utf8).write(to:root.appendingPathComponent(path)); try await repo.stage([path])
        condition = try await repo.replayStashCondition(cherryPick:false); XCTAssertTrue(condition.dirty)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.replayStashCondition(cherryPick:false,cancellation:token); XCTFail("Cancelled condition accepted") } catch OperationCancellationFailure.cancelled {}
    }

}
