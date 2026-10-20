// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

/// Independent Git/index oracles for the source Commit3 conflicted-checkbox policy.
final class CommitConflictSelectionTests: XCTestCase {
    let chosen="checked 雪\n[*].clean",unchecked="unchecked.clean",missing="missing.clean"
    func fixture() async throws -> (URL,GitRepository,String,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("commit-conflicts-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Conflict selection tests"),("user.email","conflicts@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("filter.fixture.clean","sed 's/WORK/CLEAN/g'"),("filter.fixture.smudge","cat"),("filter.fixture.required","true")] {_=try await repo.run(["config",key,value])}
        try Data("*.clean filter=fixture -text\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
        for name in [chosen,unchecked,missing] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage([chosen,unchecked,missing,".gitattributes"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","side"])
        for name in [chosen,unchecked,missing] {try Data("side\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage([chosen,unchecked,missing]);_=try await repo.commit(message:"side")
        let side=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["checkout","main"])
        for name in [chosen,unchecked,missing] {try Data("main\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage([chosen,unchecked,missing]);_=try await repo.commit(message:"main")
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        do {_=try await repo.run(["merge","--no-ff","side"]);XCTFail("Fixture merge did not conflict")}catch is GitFailure{}
        return(root,repo,head,side)
    }
    func options()->CommitOptions {var value=CommitOptions();value.ignoreUnresolvedConflicts=true;value.checkboxIndexPolicy = .init(paths:[chosen,unchecked,missing],readdUnchecked:false);return value}
    func testCheckedConflictRequiresExplicitPermissionAndPreCancellationPreservesIndex() async throws {
        let(root,repo,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:root.appendingPathComponent(chosen))
        do {_=try await repo.commitSelected(message:"no permission",paths:[chosen]);XCTFail("Conflicts accepted without Ignore")}catch is GitFailure{}
        let token=OperationCancellation();token.cancel()
        do {_=try await repo.commitSelected(message:"cancelled",paths:[chosen],options:options(),cancellation:token);XCTFail("Precancelled commit accepted")}catch is OperationCancellationFailure{}
        let rows=try await repo.status()
        do {try await repo.setCommitFilesStaged(rows.filter{$0.state == .conflicted},staged:true,cancellation:token);XCTFail("Precancelled staging accepted")}catch is OperationCancellationFailure{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(chosen)),working)
        let after=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(after,head)
    }
    func testManualStageResolvesCurrentLiteralBytesAndMissingFileWithoutTouchingOtherConflict() async throws {
        let(root,repo,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let untouched=try await repo.run(["ls-files","--unmerged","-z","--",unchecked]).stdout
        try Data("WORK manual\n".utf8).write(to:root.appendingPathComponent(chosen));try FileManager.default.removeItem(at:root.appendingPathComponent(missing))
        let rows=try await repo.status();try await repo.setCommitFilesStaged(rows.filter{GitPathSet([chosen,missing]).contains($0.path)},staged:true)
        let unresolved=try await repo.run(["ls-files","--unmerged","-z","--",chosen,missing]).stdout,indexed=try await repo.run(["show",":"+chosen]).text
        XCTAssertTrue(unresolved.isEmpty);XCTAssertEqual(indexed,"CLEAN manual\n")
        let absent=try await repo.run(["ls-files","--stage","-z","--",missing]).stdout;XCTAssertTrue(absent.isEmpty)
        let after=try await repo.run(["ls-files","--unmerged","-z","--",unchecked]).stdout;XCTAssertEqual(after,untouched)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(chosen)),"WORK manual\n")
        let now=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(now,head)
    }
    func commitChecked(using backend:GitLibGit2Configuration) async throws {
        let(root,repo,head,side)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("WORK chosen\n".utf8).write(to:root.appendingPathComponent(chosen));let other=try Data(contentsOf:root.appendingPathComponent(unchecked));try FileManager.default.removeItem(at:root.appendingPathComponent(missing))
        _=try await repo.commitSelected(message:"accepted explicit Ignore",paths:[chosen],options:options(),backend:backend)
        let parents=try await repo.run(["show","-s","--format=%P","HEAD"]).text,blob=try await repo.run(["show","HEAD:"+chosen]).text
        XCTAssertEqual(parents,head+" "+side+"\n");XCTAssertEqual(blob,"CLEAN chosen\n")
        for path in [unchecked,missing] {let tree=try await repo.run(["show","HEAD:"+path]).text,index=try await repo.run(["show",":"+path]).text;XCTAssertEqual(tree,"main\n");XCTAssertEqual(index,"main\n")}
        let stages=try await repo.run(["ls-files","--unmerged","-z"]).stdout;XCTAssertTrue(stages.isEmpty)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(unchecked)),other);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(missing).path))
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(chosen)),"WORK chosen\n")
        let operation=try await repo.commitOperation();XCTAssertNil(operation)
    }
    func testIgnoredCheckedConflictAndUncheckedTrackedConflictsUseSourceIndexPolicyCLI() async throws {try await commitChecked(using:.init(enabled:false))}
    func testIgnoredCheckedConflictAndUncheckedTrackedConflictsUseSourceIndexPolicyLibrary() async throws {
        let backend=GitLibGit2Configuration(mask:GitLibGit2Operation.commitUpdateIndex.mask)
        guard try backend.executor(for:.commitUpdateIndex) != nil else{throw XCTSkip("Bundled libgit2 Commit index helper unavailable")}
        try await commitChecked(using:backend)
    }
    func testFailedHookRetainsPreparedConflictIndexEffectsWithoutChangingHeadOrWorkingFiles() async throws {
        let(root,repo,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let filter=root.appendingPathComponent(".git/counting-clean")
        try Data(#"""
        #!/bin/sh
        n=0
        if [ -f "$0.count" ]; then n=$(/bin/cat "$0.count"); fi
        n=$((n+1))
        printf '%s' "$n" > "$0.count"
        printf 'call%s\n' "$n"
        sed 's/WORK/CLEAN/g'
        """#.utf8).write(to:filter)
        let quotedFilter="'"+filter.path.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"
        _=try await repo.run(["config","filter.fixture.clean","/bin/sh "+quotedFilter])
        try Data("WORK rejected\n".utf8).write(to:root.appendingPathComponent(chosen));let other=try Data(contentsOf:root.appendingPathComponent(unchecked))
        let hooks=root.appendingPathComponent(".git/hooks"),hook=hooks.appendingPathComponent("pre-commit")
        let receipt=root.appendingPathComponent(".git/hook-private-index"),quotedGit="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\"'\"'")+"'",quotedReceipt="'"+receipt.path.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"
        try Data(("#!/bin/sh\n"+quotedGit+" ls-files --stage -z > "+quotedReceipt+"\nexit 29\n").utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path);_=try await repo.run(["config","core.hooksPath",hooks.path])
        do {_=try await repo.commitSelected(message:"rejected",paths:[chosen],options:options());XCTFail("Rejecting hook accepted")}catch is GitFailure{}
        let now=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),chosenIndex=try await repo.run(["show",":"+chosen]).text,uncheckedIndex=try await repo.run(["show",":"+unchecked]).text
        XCTAssertEqual(now,head);XCTAssertTrue(chosenIndex.hasPrefix("call") && chosenIndex.hasSuffix("CLEAN rejected\n"));XCTAssertEqual(uncheckedIndex,"main\n")
        let published=try await repo.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(published,try Data(contentsOf:receipt),"Real index reconciliation must publish the prepared stage-zero objects, not reclean working files")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(unchecked)),other);XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(chosen)),"WORK rejected\n")
        let operation=try await repo.commitOperation();XCTAssertEqual(operation,.merge)
    }
    func preparationFailure(library:Bool) async throws {
        let(root,original,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        func q(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let marker=root.appendingPathComponent(".git/preparation-started"),filter=root.appendingPathComponent(".git/failing-clean"),git=root.appendingPathComponent(".git/group-git")
        try Data(("#!/bin/sh\nif [ -f "+q(marker.path)+" ]; then echo required-clean-refused >&2; exit 74; fi\ncat\n").utf8).write(to:filter)
        _=try await original.run(["config","filter.fixture.clean","/bin/sh "+q(filter.path)])
        try Data("new first group\n".utf8).write(to:root.appendingPathComponent("new-loose"));try Data("WORK required failure\n".utf8).write(to:root.appendingPathComponent(chosen))
        let before=try await original.run(["ls-files","--stage","-z"]).stdout,untouched=try await original.run(["ls-files","--unmerged","-z","--",unchecked]).stdout
        let backend:GitLibGit2Configuration
        if library {
            let configured=GitLibGit2Configuration(mask:GitLibGit2Operation.commitUpdateIndex.mask)
            guard let actual=try configured.executor(for:.commitUpdateIndex) else{throw XCTSkip("Bundled libgit2 Commit helper unavailable")}
            let helper=root.appendingPathComponent(".git/group-helper")
            try Data(("#!/bin/sh\n/usr/bin/touch "+q(marker.path)+"\nexec "+q(actual.path)+" \"$@\"\n").utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            backend = .init(mask:GitLibGit2Operation.commitUpdateIndex.mask,helperURL:helper)
        } else {backend = .init(enabled:false)}
        try Data(("#!/bin/sh\nadd=0; force=0\nfor a in \"$@\"; do [ \"$a\" != add ] || add=1; [ \"$a\" != -f ] || force=1; done\nif [ \"$add$force\" = 11 ]; then /usr/bin/touch "+q(marker.path)+"; fi\nexec "+q(original.executable.path)+" \"$@\"\n").utf8).write(to:git);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:git.path)
        let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false));var value=options();value.checkboxIndexPolicy = .init(paths:[chosen,unchecked,missing,"new-loose"],readdUnchecked:false)
        do{_=try await repo.commitSelected(message:"preparation must fail",paths:[chosen,"new-loose"],options:value,backend:backend);XCTFail("Required clean failure accepted")}catch is GitFailure{}
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"Fixture did not reach actual preparation phase")
        let after=try await original.run(["ls-files","--stage","-z"]).stdout,remaining=try await original.run(["ls-files","--unmerged","-z","--",unchecked]).stdout,now=try await original.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(remaining,untouched,"Unchecked conflict reset ran after failed earlier source preparation group");XCTAssertEqual(now,head)
        if library {XCTAssertEqual(after,before,"Failed one-write library preparation changed original index")}
        else {let added=try await original.run(["show",":new-loose"]).text;XCTAssertEqual(added,"new first group\n","Successful earlier source add group was rolled back");XCTAssertNotEqual(after,before)}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(chosen)),"WORK required failure\n")
    }
    func testCLIPreparationGroupFailureRetainsEarlierAddAndDoesNotResetUncheckedConflict() async throws {try await preparationFailure(library:false)}
    func testLibraryPreparationFailureKeepsOriginalConflictIndex() async throws {try await preparationFailure(library:true)}

}
