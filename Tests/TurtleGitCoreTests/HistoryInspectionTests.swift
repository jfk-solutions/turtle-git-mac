import XCTest
@testable import TurtleGitCore

final class HistoryInspectionTests:XCTestCase {
    private func configuration(_ operations:[GitLibGit2Operation]=[.mergeBase,.checkCleanWorktree],helper:URL?=nil)->GitLibGit2Configuration {
        .init(enabled:true,mask:operations.reduce(0){$0|$1.mask},helperURL:helper)
    }
    private func captured(_ repo:GitRepository,_ backend:GitLibGit2Configuration)->GitRepository {
        .init(root:repo.root,executable:repo.executable,askpass:repo.askpass,diffDetection:repo.diffDetection,libgit2Configuration:backend)
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func script(_ root:URL,_ content:String) throws -> URL {
        let path=root.appendingPathComponent("inspection-helper-"+UUID().uuidString)
        try Data(("#!/bin/sh\n"+content+"\n").utf8).write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path);return path
    }
    func testDirectionalFastForwardJumpsUseActualGraphForFilteredRowsAndBothEngines() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let tree=try await base.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let independent=try await base.run(["commit-tree",tree],input:Data("independent\n".utf8)).text.trimmingCharacters(in:.newlines)
        func row(_ oid:String)->LogEntry {var value=LogEntry(hash:oid,author:"",date:"",subject:"");value.references=[.init(name:"refs/tags/release"),.init(name:"refs/remotes/origin/main")];return value}
        let rows=[LogEntry(hash:"working",author:"",date:"",subject:""),row(entries[0].hash),row(independent),row(entries[2].hash),row(entries[3].hash)]
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for backend in [configuration(),GitLibGit2Configuration(enabled:false)] {
            let repo=captured(base,backend)
            let up=try await repo.historyJump(entries:rows,selected:[entries[2].hash],kind:.branchFF,up:true)
            let down=try await repo.historyJump(entries:rows,selected:[entries[0].hash],kind:.tagFF,up:false)
            let ordinary=try await repo.historyJump(entries:rows,selected:[entries[2].hash],kind:.branch,up:true)
            XCTAssertEqual(up,1);XCTAssertEqual(down,3);XCTAssertEqual(ordinary,2)
        }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
    }
    func testDeletionWarningsUseSingleBranchAndHeadsOnlySourceBoundaries() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let tree=try await base.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let other=try await base.run(["commit-tree",tree],input:Data("other\n".utf8)).text.trimmingCharacters(in:.newlines)
        for(name,oid) in [("refs/heads/merged",entries[1].hash),("refs/heads/unmerged",other),("refs/remotes/origin/other",other),("refs/tags/other",other)] {_ = try await base.run(["update-ref",name,oid])}
        for backend in [configuration(),GitLibGit2Configuration(enabled:false)] {
            let repo=captured(base,backend)
            let merged=try await repo.browserDeletionConfirmation("refs/heads/merged"),unmerged=try await repo.browserDeletionConfirmation("refs/heads/unmerged"),remote=try await repo.browserDeletionConfirmation("refs/remotes/origin/other"),tag=try await repo.browserDeletionConfirmation("refs/tags/other")
            XCTAssertFalse(merged.unmerged);XCTAssertTrue(unmerged.unmerged);XCTAssertTrue(remote.unmerged);XCTAssertFalse(tag.unmerged)
            let shared=try await repo.prepareHistoryReferenceDeletion("refs/heads/unmerged"),sharedRemote=try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/other")
            XCTAssertTrue(shared.unmerged);XCTAssertFalse(sharedRemote.unmerged)
        }
    }
    func testMissingSelectedHelperFailsEligibleReadsButDoesNotGateTagsMultipleOrOrdinaryJump() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["refs/heads/one","refs/heads/two","refs/tags/one","refs/remotes/origin/one"] {_ = try await base.run(["update-ref",name,entries[0].hash])}
        let repo=captured(base,configuration(helper:root.appendingPathComponent("missing")))
        do {_ = try await repo.browserDeletionConfirmation("refs/heads/one");XCTFail("Single branch bypassed selected engine")}catch{}
        do {_ = try await repo.prepareHistoryReferenceDeletion("refs/heads/one");XCTFail("Shared local warning bypassed selected engine")}catch{}
        do {_ = try await repo.browserDeletionConfirmation("refs/remotes/origin/one");XCTFail("Browser remote branch bypassed selected engine")}catch{}
        _ = try await repo.browserDeletionConfirmation("refs/tags/one")
        let multiple=try await repo.browserDeletionConfirmation(["refs/heads/one","refs/heads/two"]);XCTAssertTrue(multiple.uncheckedMerge)
        // Shared deletion now captures a selected-engine object receipt even
        // though remote references still skip the local-head merge warning.
        do {_ = try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/one");XCTFail("Shared remote lookup bypassed missing selected engine")}catch GitLibGit2Failure.runtimeMissing{}
        let helper=try XCTUnwrap(configuration().executor(for:.mergeBase))
        let trace=root.appendingPathComponent("remote-inspection-trace")
        let selective=try script(root,"""
        for argument in "$@"; do
          case "$argument" in
            turtlegit-*) printf '%s\\n' "$argument" >> \(quote(trace.path)) ;;
          esac
          case "$argument" in
            turtlegit-merge-base|turtlegit-check-clean) printf 'unexpected-inspection\\n'; exit 0 ;;
          esac
        done
        exec \(quote(helper.path)) "$@"
        """)
        let selected=captured(base,configuration(helper:selective))
        let remote=try await selected.prepareHistoryReferenceDeletion("refs/remotes/origin/one");XCTAssertFalse(remote.unmerged)
        let commands=try String(contentsOf:trace,encoding:.utf8).split(separator:"\n").map(String.init)
        XCTAssertTrue(commands.contains("turtlegit-revision-lookup"))
        XCTAssertFalse(commands.contains("turtlegit-merge-base"));XCTAssertFalse(commands.contains("turtlegit-check-clean"))
        var rows=entries;rows[1].references=[.init(name:"refs/tags/one")]
        let ordinary=try await repo.historyJump(entries:rows,selected:[rows[2].hash],kind:.tag,up:true);XCTAssertEqual(ordinary,1)
        do {_ = try await repo.historyJump(entries:rows,selected:[rows[2].hash],kind:.tagFF,up:true);XCTFail("FF jump bypassed selected engine")}catch{}
        do {_ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash);XCTFail("Combine bypassed selected clean engine")}catch{}
    }
    func testCombineBothCleanGatesRejectStagedAndUnstagedChangesWithoutResetting() async throws {
        for backend in [configuration(),GitLibGit2Configuration(enabled:false)] {
            for staged in [false,true] {
                let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
                let repo=captured(base,backend),hashes=entries.prefix(2).map(\.hash)
                let plan=try await repo.prepareHistoryCombine(hashes:hashes,firstOffset:0,expectedHead:entries[0].hash)
                try Data("approved local bytes\n".utf8).write(to:root.appendingPathComponent("a"));if staged {try await base.stage(["a"])}
                let index=try await base.run(["write-tree"]).stdout
                do {_ = try await repo.prepareHistoryCombine(hashes:hashes,firstOffset:0,expectedHead:entries[0].hash);XCTFail("Dirty preparation accepted")}catch HistoryCombineFailure.dirty{}
                do {_ = try await repo.beginHistoryCombine(plan);XCTFail("Dirty accepted plan mutated HEAD")}catch HistoryCombineFailure.dirty{}
                let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),afterIndex=try await base.run(["write-tree"]).stdout
                XCTAssertEqual(head,entries[0].hash);XCTAssertEqual(afterIndex,index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("a")),Data("approved local bytes\n".utf8))
            }
        }
    }
    func testCombineIgnoresUntrackedAndIgnoredFilesAndPreservesThemAcrossBeginAbort() async throws {
        for backend in [configuration(),GitLibGit2Configuration(enabled:false)] {
            let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            try Data("ignored\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
            for name in ["untracked","ignored"] {try Data((name+" bytes\n").utf8).write(to:root.appendingPathComponent(name))}
            let repo=captured(base,backend),plan=try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)
            _ = try await repo.beginHistoryCombine(plan);_ = try await repo.abortHistoryCombine(plan)
            for name in ["untracked","ignored"] {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(name)),Data((name+" bytes\n").utf8))}
            let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,entries[0].hash)
        }
    }
    func testCombineReadinessExcludesDirtySubmoduleWorktreeWithoutIgnoringTrackedChanges() async throws {
        let(root,base,_)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let child=root.appendingPathComponent("child-origin");try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        let childRepo=GitRepository(root:child);_ = try await childRepo.run(["init"]);_ = try await childRepo.run(["config","user.name","Child"]);_ = try await childRepo.run(["config","user.email","child@example.invalid"]);_ = try await childRepo.run(["config","commit.gpgsign","false"])
        try Data("child\n".utf8).write(to:child.appendingPathComponent("file"));try await childRepo.stage(["file"]);_ = try await childRepo.commit(message:"child")
        _ = try await base.run(["-c","protocol.file.allow=always","submodule","add","--",child.path,"module"]);_ = try await base.commit(message:"module")
        _ = try await base.run(["commit","--allow-empty","-m","tip"])
        let entries=try await base.history(),head=entries[0].hash
        try Data("dirty child\n".utf8).write(to:root.appendingPathComponent("module/file"))
        for backend in [configuration(),GitLibGit2Configuration(enabled:false)] {
            let repo=captured(base,backend)
            let plan=try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:head)
            XCTAssertEqual(plan.originalHead,head)
        }
        try Data("tracked parent dirty\n".utf8).write(to:root.appendingPathComponent("a"))
        do {_ = try await captured(base,configuration()).prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:head);XCTFail("Parent dirtiness ignored with submodule")}catch HistoryCombineFailure.dirty{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("module/file")),Data("dirty child\n".utf8))
    }
    func testCombineRevalidatesHeadAfterSelectedCleanReadForPreparationAndMutation() async throws {
        let helper=try XCTUnwrap(configuration().executor(for:.checkCleanWorktree))
        for preparation in [false,true] {
            let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            let tree=try await base.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
            let external=try await base.run(["commit-tree",tree,"-p",entries[0].hash],input:Data("external same tree\n".utf8)).text.trimmingCharacters(in:.newlines)
            let plan=try await base.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)
            let wrapper=try script(root,"/usr/bin/git -C "+quote(root.path)+" update-ref HEAD "+quote(external)+" "+quote(entries[0].hash)+" || exit 1\nexec "+quote(helper.path)+" \"$@\"")
            let repo=captured(base,configuration([.checkCleanWorktree],helper:wrapper))
            do {
                if preparation {_ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)} else {_ = try await repo.beginHistoryCombine(plan)}
                XCTFail("HEAD changed inside clean read was reset or accepted")
            }catch HistoryCombineFailure.changed{}
            let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),actual=try await base.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(head,external);XCTAssertEqual(actual,tree)
        }
    }
    func testCombineRevalidatesCheckedOutBranchAfterSelectedCleanReadWithSameHead() async throws {
        let helper=try XCTUnwrap(configuration().executor(for:.checkCleanWorktree))
        for preparation in [false,true] {
            let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            _ = try await base.run(["branch","other",entries[0].hash])
            let plan=try await base.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)
            let wrapper=try script(root,"/usr/bin/git -C "+quote(root.path)+" symbolic-ref HEAD refs/heads/other || exit 1\nexec "+quote(helper.path)+" \"$@\"")
            let repo=captured(base,configuration([.checkCleanWorktree],helper:wrapper))
            do {
                if preparation {_ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)} else {_ = try await repo.beginHistoryCombine(plan)}
                XCTFail("Same-OID branch switch during clean read was accepted")
            }catch HistoryCombineFailure.changed{}
            let ref=try await base.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines),head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(ref,"refs/heads/other");XCTAssertEqual(head,entries[0].hash)
        }
    }
    func testInspectionProtocolFailureAndCancellationNeverBecomeDeletionWarningsOrCombineApproval() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await base.run(["update-ref","refs/heads/other",entries[1].hash])
        let helper=try XCTUnwrap(configuration().executor(for:.mergeBase)),trace=root.appendingPathComponent("protocol-inspection-trace")
        // Corrupt the protocol under test, while allowing the independent
        // selected revision preflight to reach the actual inspection boundary.
        let wrapper=try script(root,"""
        for argument in "$@"; do
          case "$argument" in
            turtlegit-*) printf '%s\\n' "$argument" >> \(quote(trace.path)) ;;
          esac
          case "$argument" in
            turtlegit-merge-base|turtlegit-check-clean) printf 'not-a-private-frame\\n'; exit 0 ;;
          esac
        done
        exec \(quote(helper.path)) "$@"
        """),repo=captured(base,configuration(helper:wrapper))
        do {_ = try await repo.browserDeletionConfirmation("refs/heads/other");XCTFail("Invalid metadata became a warning")}catch is GitReplayInspectionFailure{}
        do {_ = try await repo.prepareHistoryReferenceDeletion("refs/heads/other");XCTFail("Invalid metadata became a shared warning")}catch is GitReplayInspectionFailure{}
        do {_ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash);XCTFail("Invalid clean metadata accepted")}catch is GitReplayInspectionFailure{}
        let commands=try String(contentsOf:trace,encoding:.utf8).split(separator:"\n").map(String.init)
        XCTAssertTrue(commands.contains("turtlegit-revision-lookup"));XCTAssertTrue(commands.contains("turtlegit-merge-base"));XCTAssertTrue(commands.contains("turtlegit-check-clean"))
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.browserDeletionConfirmation("refs/heads/other",cancellation:token);XCTFail("Cancelled warning accepted")}catch is OperationCancellationFailure{}
        do {_ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash,cancellation:token);XCTFail("Cancelled preparation accepted")}catch is OperationCancellationFailure{}
        let head=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,entries[0].hash)
    }
    func testMalformedSelectedRevisionPreflightNeverBecomesDeletionApproval() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let names=["refs/heads/other","refs/remotes/origin/other","refs/tags/other"]
        for name in names {_ = try await base.run(["update-ref",name,entries[1].hash])}
        let helper=try XCTUnwrap(configuration().executor(for:.mergeBase)),trace=root.appendingPathComponent("revision-preflight-trace")
        let wrapper=try script(root,"""
        for argument in "$@"; do
          case "$argument" in
            turtlegit-*) printf '%s\\n' "$argument" >> \(quote(trace.path)) ;;
          esac
          case "$argument" in
            turtlegit-revision-lookup) printf 'not-a-private-frame\\n'; exit 0 ;;
          esac
        done
        exec \(quote(helper.path)) "$@"
        """)
        let repo=captured(base,configuration(helper:wrapper))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let head=try Data(contentsOf:root.appendingPathComponent(".git/HEAD"))
        let config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        for name in names {
            do {_ = try await repo.prepareHistoryReferenceDeletion(name);XCTFail("Malformed selected revision metadata became deletion approval for \(name)")}catch GitRevisionLookupFailure.output{}
            let oid=try await base.run(["rev-parse","--verify",name]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(oid,entries[1].hash)
        }
        let commands=try String(contentsOf:trace,encoding:.utf8).split(separator:"\n").map(String.init)
        XCTAssertEqual(commands.filter{$0=="turtlegit-revision-lookup"}.count,names.count)
        XCTAssertFalse(commands.contains("turtlegit-merge-base"));XCTAssertFalse(commands.contains("turtlegit-check-clean"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/HEAD")),head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),config)
        let actualHead=try await base.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(actualHead,entries[0].hash)
    }
    func testExplicitDeletionBackendControlsWarningRevalidationAndKeepsCapturedCAS() async throws {
        let(root,base,entries)=try await HistoryWorkflowTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["refs/heads/remove","refs/heads/changed"] {_ = try await base.run(["update-ref",name,entries[1].hash])}
        let repo=captured(base,configuration(helper:root.appendingPathComponent("missing"))),cli=GitLibGit2Configuration(enabled:false)
        let remove=try await repo.prepareHistoryReferenceDeletion("refs/heads/remove",backend:cli)
        _ = try await repo.deleteHistoryReference(remove,choice:.delete,backend:cli)
        let absent=try await base.run(["show-ref","--verify","--quiet","refs/heads/remove"],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)
        let stale=try await repo.prepareHistoryReferenceDeletion("refs/heads/changed",backend:cli)
        _ = try await base.run(["update-ref","refs/heads/changed",entries[0].hash,entries[1].hash])
        do {_ = try await repo.deleteHistoryReference(stale,choice:.delete,backend:cli);XCTFail("New engine bypassed captured reference CAS")}catch HistoryReferenceDeletionFailure.changed{}
        let remaining=try await base.run(["rev-parse","refs/heads/changed"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(remaining,entries[0].hash)
    }
}
