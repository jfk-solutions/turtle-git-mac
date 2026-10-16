import XCTest
@testable import TurtleGitCore

final class CommitCheckboxIndexTests:XCTestCase {
    func setup() async throws -> (URL,GitRepository) {
        let (root,repo)=try await CommitSelectionTests().fixture()
        for (name,text) in [("checked","base checked\n"),("modified","base modified\n"),("deleted","base delete\n"),("rename","base rename\n"),("outside","base outside\n")] {try Data(text.utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["checked","modified","deleted","rename","outside"]);_ = try await repo.commit(message:"base")
        for (name,text) in [("checked","selected\n"),("modified","staged modified\n"),("added 雪\n[*]","staged added\n"),("outside","staged outside\n")] {try Data(text.utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["modified","added 雪\n[*]","outside"])
        try Data("working modified\n".utf8).write(to:root.appendingPathComponent("modified"));try Data("working added\n".utf8).write(to:root.appendingPathComponent("added 雪\n[*]"))
        _ = try await repo.run(["rm","--","deleted"]);_ = try await repo.run(["mv","rename","renamed"])
        return(root,repo)
    }
    func options(_ restore:Bool=true)->CommitOptions {var value=CommitOptions();value.checkboxIndexPolicy = .init(paths:["checked","modified","added 雪\n[*]","deleted","renamed"],readdUnchecked:restore);return value}
    func testCheckboxCommitRestoresOnlySourceAddDeleteRenameQueuesWithCurrentWorkingBytes() async throws {
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        let outside=try await repo.run(["show",":outside"]).stdout
        _ = try await repo.commitSelected(message:"selected",paths:["checked"],options:options())
        let committed=try await repo.run(["diff-tree","--no-commit-id","--name-only","-r","HEAD"]).text
        XCTAssertEqual(committed,"checked\n")
        let added=try await repo.run(["show",":added 雪\n[*]"]).text,modified=try await repo.run(["show",":modified"]).text
        XCTAssertEqual(added,"working added\n");XCTAssertEqual(modified,"base modified\n")
        let state=try await repo.status();XCTAssertTrue(state.contains{$0.path=="deleted" && $0.index=="D"});XCTAssertTrue(state.contains{$0.path=="renamed" && $0.index=="R"})
        let afterOutside=try await repo.run(["show",":outside"]).stdout;XCTAssertEqual(afterOutside,outside)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("modified")),"working modified\n")
    }
    func testDisabledRestorationLeavesAddedUntrackedDeletionUnstagedAndRenameAsWorkingChange() async throws {
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.commitSelected(message:"no restore",paths:["checked"],options:options(false))
        let state=try await repo.status()
        XCTAssertTrue(state.contains{$0.path=="added 雪\n[*]" && $0.state == .untracked})
        XCTAssertTrue(state.contains{$0.path=="deleted" && $0.index==" " && $0.worktree=="D"})
        let staged=try await repo.run(["diff","--cached","--name-only"]).text;XCTAssertEqual(staged,"outside\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("renamed")),"base rename\n")
    }
    func testHookFailureStillRestoresQueuedEntriesWithoutChangingHead() async throws {
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        let hooks=root.appendingPathComponent("hooks");try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        let hook=hooks.appendingPathComponent("pre-commit");try Data("#!/bin/sh\nexit 1\n".utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        _ = try await repo.run(["config","core.hooksPath",hooks.path]);let head=try await repo.run(["rev-parse","HEAD"]).stdout
        do{_ = try await repo.commitSelected(message:"rejected",paths:["checked"],options:options());XCTFail("Hook accepted")}catch is GitFailure{}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,added=try await repo.run(["show",":added 雪\n[*]"]).text,modified=try await repo.run(["show",":modified"]).text
        XCTAssertEqual(after,head);XCTAssertEqual(added,"working added\n");XCTAssertEqual(modified,"base modified\n")
    }
    func testStagingModeIgnoresCheckboxPolicyAndRetainsExactStagedBytes() async throws {
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.commitIndex(message:"staged",options:options(false))
        let added=try await repo.run(["show","HEAD:added 雪\n[*]"]).text,modified=try await repo.run(["show","HEAD:modified"]).text
        XCTAssertEqual(added,"staged added\n");XCTAssertEqual(modified,"staged modified\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("modified")),"working modified\n")
    }
    func testUnbornSelectionAndMessageOnlyAmendFollowCapturedScope() async throws {
        let (root,repo)=try await CommitSelectionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["checked","other"]{try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name))};try await repo.stage(["checked","other"])
        var selected=CommitOptions();selected.checkboxIndexPolicy = .init(paths:["checked","other"],readdUnchecked:false)
        _ = try await repo.commitSelected(message:"initial",paths:["checked"],options:selected)
        let tree=try await repo.run(["ls-tree","--name-only","HEAD"]).text;XCTAssertEqual(tree,"checked\n")
        try await repo.stage(["other"]);selected.amend=true;selected.messageOnly=true
        _ = try await repo.commitSelected(message:"message only",paths:[],options:selected)
        let after=try await repo.run(["ls-tree","--name-only","HEAD"]).text;XCTAssertEqual(after,"checked\n")
        let status=try await repo.status();XCTAssertTrue(status.contains{$0.path=="other" && $0.state == .untracked})
    }
    func testParentAmendUsesParentBaselineForUncheckedModifiedRows() async throws {
        let (root,repo)=try await CommitSelectionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["checked","other"]{try Data("base\n".utf8).write(to:root.appendingPathComponent(name))};try await repo.stage(["checked","other"]);_ = try await repo.commit(message:"parent")
        try Data("old commit\n".utf8).write(to:root.appendingPathComponent("other"));try await repo.stage(["other"]);_ = try await repo.commit(message:"old")
        try Data("replacement\n".utf8).write(to:root.appendingPathComponent("checked"))
        var value=CommitOptions();value.amend=true;value.amendDiffToLastCommit=false;value.checkboxIndexPolicy = .init(paths:["checked","other"])
        _ = try await repo.commitSelected(message:"replacement",paths:["checked"],options:value)
        let indexed=try await repo.run(["show",":other"]).text,committed=try await repo.run(["show","HEAD:other"]).text
        XCTAssertEqual(indexed,"base\n");XCTAssertEqual(committed,"base\n");XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("other")),"old commit\n")
    }
    func testPreCancellationAndIndexLockDoNotMutateCapturedIndex() async throws {
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        let index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index),head=try await repo.run(["rev-parse","HEAD"]).stdout,token=OperationCancellation();token.cancel()
        do{_ = try await repo.commitSelected(message:"cancel",paths:["checked"],options:options(),cancellation:token);XCTFail("Cancelled commit accepted")}catch is OperationCancellationFailure{}
        let lock=root.appendingPathComponent(".git/index.lock");try Data().write(to:lock);defer{try? FileManager.default.removeItem(at:lock)}
        do{_ = try await repo.commitSelected(message:"locked",paths:["checked"],options:options());XCTFail("Locked index accepted")}catch is GitFailure{}
        XCTAssertEqual(try Data(contentsOf:index),before);let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
    }
}

extension CommitCheckboxIndexTests {
    func testExactSourcePreferenceAndCommitSuccessWithRestorationWarning() async throws {
        let suite="CommitCheckbox."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)}
        XCTAssertTrue(CommitCheckboxIndexPolicy(paths:[],defaults:prefs).readdUnchecked)
        prefs.set(2,forKey:"ReaddUnselectedAddedFilesAfterCommit");XCTAssertFalse(CommitCheckboxIndexPolicy(paths:[],defaults:prefs).readdUnchecked)
        let (root,repo)=try await setup();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("failing-restoration-git"),executable="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\''")+"'"
        let script="""
        #!/bin/sh
        if [ "$4" = add ] && [ "$5" = --ignore-errors ]; then exit 7; fi
        exec \(executable) "$@"

        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper)
        let output=try await wrapped.commitSelected(message:"succeeded",paths:["checked"],options:options())
        XCTAssertTrue(output.contains("warning: Restoring unchecked"))
        let selected=try await repo.run(["show","HEAD:checked"]).text,count=try await repo.run(["rev-list","--count","HEAD"]).text
        XCTAssertEqual(selected,"selected\n");XCTAssertEqual(count,"2\n")
    }
}
