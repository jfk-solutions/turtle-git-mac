// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class BisectOperationTests: XCTestCase {
    func fixture() async throws -> (URL,GitRepository,[String]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-bisect-operation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root)
        do {
            _ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Bisect Operation"),("user.email","bisect@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
            var hashes:[String]=[]
            for index in 0..<6 {try Data("\(index)\n".utf8).write(to:root.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"step \(index)");hashes.append(try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))}
            return (root,repository,hashes)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    func testTypedStashStartAndResetReceiptsRetainActualCommandsAndState() async throws {
        let (root,repository,hashes)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        try Data("dirty\n".utf8).write(to:root.appendingPathComponent("file"))
        do {_ = try await repository.startBisectWorkflow(good:hashes[0],bad:"HEAD");XCTFail("Dirty review started a mutation")}
        catch BisectFailure.dirty {}
        let stash=try await repository.stashBeforeBisectWorkflow()
        XCTAssertTrue(stash.stash.created);XCTAssertTrue(stash.mutation.attempted && stash.mutation.success)
        XCTAssertEqual(stash.mutation.commands.map(\.arguments),[["stash","push"]]);XCTAssertEqual(stash.mutation.output,stash.stash.output)
        let started=try await repository.startBisectWorkflow(good:hashes[0],bad:hashes.last!)
        XCTAssertTrue(started.mutation.success && started.execution.state.active)
        XCTAssertEqual(started.mutation.commands.map(\.arguments),[["bisect","start"],["bisect","good",hashes[0]],["bisect","bad",hashes.last!]])
        XCTAssertEqual(started.mutation.output,started.execution.output)
        let reset=try await repository.bisectWorkflow(.reset)
        XCTAssertTrue(reset.mutation.success);XCTAssertFalse(reset.execution.state.active);XCTAssertEqual(reset.execution.state.head,hashes.last)
        XCTAssertEqual(reset.mutation.commands.map(\.arguments),[["bisect","reset"]])
        let stashes=try await repository.run(["stash","list","--format=%H"]).text.split(separator:"\n");XCTAssertEqual(stashes.count,1)
    }
    func testAmbiguousBranchAndTagDiagnosticsDoNotBecomeCanonicalCommitArguments() async throws {
        let (root,repository,hashes)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repository.run(["branch","boundary",hashes[1]])
        _ = try await repository.run(["tag","boundary",hashes[0]])
        let resolution=try await repository.run(["rev-parse","--verify","--end-of-options","boundary^{commit}"])
        XCTAssertTrue(String(decoding:resolution.stderr,as:UTF8.self).contains("ambiguous"))
        let start=try await repository.startBisectWorkflow(good:"boundary",bad:"HEAD")
        XCTAssertTrue(start.mutation.success && start.execution.state.active)
        XCTAssertEqual(start.mutation.commands[1].arguments,["bisect","good",hashes[0]])
        XCTAssertEqual(start.mutation.commands[2].arguments,["bisect","bad",hashes.last!])
        _ = try await repository.bisect(.reset)
    }
    func testCancelledStartCarriesCompletedAndInterruptedCommandsWithoutHidingSession() async throws {
        let (root,real,hashes)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let wrapper=root.appendingPathComponent("git-bisect-wrapper"),marker=root.appendingPathComponent("started")
        let script="""
        #!/bin/sh
        if [ "$4-$5" = bisect-good ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$3/started"
          wait "$task_child"
        fi
        exec /usr/bin/git "$@"
        """
        try script.write(to:wrapper,atomically:false,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repository=GitRepository(root:root,executable:wrapper),token=OperationCancellation()
        let work=Task {try await repository.startBisectWorkflow(good:hashes[0],bad:"HEAD",cancellation:token)}
        for _ in 0..<500 {if FileManager.default.fileExists(atPath:marker.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        guard FileManager.default.fileExists(atPath:marker.path) else {token.cancel();_ = try? await work.value;XCTFail("Owned classifier did not start");return}
        let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap {Int32($0)};token.cancel()
        do {_ = try await work.value;XCTFail("Cancelled Start succeeded")}
        catch let failure as BisectMutationFailure {
            XCTAssertTrue(failure.mutation.attempted && failure.mutation.cancelled);XCTAssertFalse(failure.mutation.success)
            XCTAssertEqual(failure.mutation.commands.map {Array($0.arguments.prefix(2))},[["bisect","start"],["bisect","good"]])
            XCTAssertEqual(failure.mutation.commands.first?.exitCode,0)
            XCTAssertTrue(failure.underlying is GitCommandCancellationFailure || failure.underlying is OperationCancellationFailure)
        }
        XCTAssertEqual(pids.count,2);XCTAssertTrue(pids.allSatisfy {kill($0,0) != 0})
        let state=try await real.bisectState();XCTAssertTrue(state.active)
        _ = try await real.bisect(.reset)
        let reset=try await real.bisectState();XCTAssertEqual(reset.head,hashes.last)
    }
}
