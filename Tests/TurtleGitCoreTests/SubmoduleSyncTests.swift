// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SubmoduleSyncTests: XCTestCase {
    struct Fixture { let root: URL, repo: GitRepository, first: String, second: String, git: URL, wrapper: URL }
    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-submodule-sync-" + UUID().uuidString)
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
        do {
            func repository(_ name: String) async throws -> GitRepository {
                let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let repo = GitRepository(root: folder, executable: git); _ = try await repo.run(["init", "-b", "main"])
                for (key,value) in [("user.name","Sync Fixture"),("user.email","sync@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
                try Data("fixture\n".utf8).write(to: folder.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "fixture")
                return repo
            }
            let inner = try await repository("inner-source"), source = try await repository("source"), parent = try await repository("parent")
            _ = try await source.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "inner", "--", inner.root.path, "nested"])
            _ = try await source.commit(message: "nested")
            let first = "group/quoted ' 雪\nmodule", second = "group-other/second"
            for (name,path) in [("first",first),("second",second),("third","uninitialized")] { _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", name, "--", source.root.path, path]) }
            _ = try await parent.commit(message: "modules")
            _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])
            _ = try await parent.run(["submodule", "deinit", "-f", "--", "uninitialized"])
            let wrapper = root.appendingPathComponent("git-wrapper")
            let script = """
            #!/bin/sh
            sync=no
            for argument in "$@"; do [ "$argument" = sync ] && sync=yes; done
            if [ "$sync" = yes ]; then
              printf '%s\\n' called >> "$0.calls"
              if [ -f "$0.pause" ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.started"
                wait "$task_child"
              fi
              if [ -f "$0.fail-first" ] && [ ! -f "$0.failed" ]; then touch "$0.failed"; printf '%s\\n' 'fixture command failure' >&2; exit 7; fi
            fi
            exec '\(git.path.replacingOccurrences(of: "'", with: "'\\''"))' "$@"
            """
            try script.write(to: wrapper, atomically: false, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            return Fixture(root:root,repo:GitRepository(root:parent.root,executable:wrapper),first:first,second:second,git:git,wrapper:wrapper)
        } catch { try? FileManager.default.removeItem(at:root); throw error }
    }
    func config(_ repo: GitRepository, _ name: String, file: String? = nil) async throws -> String {
        try await repo.run(["config"] + (file.map { ["--file",$0] } ?? []) + ["--get",name], successfulExitCodes:0...1).text.trimmingCharacters(in:.newlines)
    }
    func testScopedAndWholeSyncPreserveFilesIndexAndDoNotRecurse() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let child = GitRepository(root:f.repo.root.appendingPathComponent(f.first),executable:f.git)
        let nested = GitRepository(root:child.root.appendingPathComponent("nested"),executable:f.git)
        let originalNested = try await config(nested,"remote.origin.url")
        _ = try await child.run(["config","--file",".gitmodules","submodule.inner.url","ssh://sync-fixture.invalid/nested"])
        for name in ["first","second","third"] { _ = try await f.repo.run(["config","--file",".gitmodules","submodule."+name+".url","ssh://sync-fixture.invalid/"+name]) }
        let index = try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")), modules = try Data(contentsOf:f.repo.root.appendingPathComponent(".gitmodules")), head = try await f.repo.run(["rev-parse","HEAD"]).stdout
        let selected = try await f.repo.syncSubmodules(scope:["group"])
        XCTAssertTrue(selected.success); XCTAssertEqual(selected.entries.map { $0.command.arguments }, [["submodule","sync","--","group"]])
        let firstURL = try await config(f.repo,"submodule.first.url"), childURL = try await config(child,"remote.origin.url")
        XCTAssertEqual(firstURL,"ssh://sync-fixture.invalid/first"); XCTAssertEqual(childURL,firstURL)
        let secondURL = try await config(f.repo,"submodule.second.url"); XCTAssertNotEqual(secondURL,"ssh://sync-fixture.invalid/second")
        let nestedURL = try await config(nested,"remote.origin.url"); XCTAssertEqual(nestedURL,originalNested)
        let whole = try await f.repo.syncSubmodules(); XCTAssertTrue(whole.success); XCTAssertEqual(whole.entries[0].command.arguments,["submodule","sync"])
        let nextSecond = try await config(f.repo,"submodule.second.url"), uninitialized = try await config(f.repo,"submodule.third.url")
        XCTAssertEqual(nextSecond,"ssh://sync-fixture.invalid/second"); XCTAssertTrue(uninitialized.isEmpty)
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".gitmodules")),modules)
        let after = try await f.repo.run(["rev-parse","HEAD"]).stdout; XCTAssertEqual(after,head)
        let owner = try await child.discoverSelectionRoot(for:.submoduleSync, selected:child.root); XCTAssertEqual(owner,f.repo.root)
    }
    func testDirectoryPlanAndOrdinaryFailureContinueInSelectionOrder() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let plan = try await f.repo.submoduleSyncPlan(scope:["file",f.second,f.first]); XCTAssertEqual(plan.map(\.scope),[f.second,f.first])
        for path in ["../outside",".git","missing"] { do { _ = try await f.repo.submoduleSyncPlan(scope:[path]); XCTFail("Unsafe scope accepted") } catch {} }
        try FileManager.default.createSymbolicLink(atPath:f.repo.root.appendingPathComponent("linked").path,withDestinationPath:f.root.path)
        do { _ = try await f.repo.syncSubmodules(scope:["linked"]); XCTFail("Escaping directory link accepted") } catch {}
        try Data().write(to:URL(fileURLWithPath:f.wrapper.path+".fail-first"))
        let result = try await f.repo.syncSubmodules(scope:[f.second,f.first])
        XCTAssertEqual(result.entries.map(\.exitCode),[7,0]); XCTAssertEqual(result.exitCode,7); XCTAssertFalse(result.success)
        XCTAssertEqual(result.entries.map { $0.command.scope },[f.second,f.first])
        XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:f.wrapper.path+".calls")),"called\ncalled\n")
    }
    func testFileOnlySyncHasNoCommandsAndSourceFailureStatus() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let index = try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")), head = try await f.repo.run(["rev-parse","HEAD"]).stdout
        let result = try await f.repo.syncSubmodules(scope:["file"])
        XCTAssertTrue(result.entries.isEmpty); XCTAssertEqual(result.exitCode,-1); XCTAssertFalse(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.wrapper.path+".calls"))
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
        let after = try await f.repo.run(["rev-parse","HEAD"]).stdout; XCTAssertEqual(after,head)
    }
    func testLiveCancellationStopsLaterCommandsAndReapsOwnedChildren() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let index = try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")), token = OperationCancellation()
        try Data().write(to:URL(fileURLWithPath:f.wrapper.path+".pause"))
        let work = Task { try await f.repo.syncSubmodules(scope:[f.first,f.second],cancellation:token) }
        let marker = URL(fileURLWithPath:f.wrapper.path+".started")
        for _ in 0..<500 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(nanoseconds:10_000_000) }
        guard FileManager.default.fileExists(atPath:marker.path) else { token.cancel(); _ = try? await work.value; throw SubmoduleSyncFailure.selection }
        let pids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }; token.cancel()
        do { _ = try await work.value; XCTFail("Cancelled Sync succeeded") } catch { XCTAssertTrue(token.isCancelled); XCTAssertTrue(error is GitCommandCancellationFailure || error is OperationCancellationFailure) }
        XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:f.wrapper.path+".calls")),"called\n")
        XCTAssertEqual(pids.count,2); XCTAssertTrue(pids.allSatisfy { kill($0,0) != 0 })
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
    }
}
