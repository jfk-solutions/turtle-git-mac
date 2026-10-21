// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class GitBlameReferenceMetadataTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, GitBlameSnapshot, String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("BlameRefs-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false))
        do {
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Blame Refs"),("user.email","blame@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] { _ = try await repo.run(["config",key,value]) }
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
            try Data("origin\n".utf8).write(to:root.appendingPathComponent("other"));try await repo.stage(["other"]);_ = try await repo.commit(message:"tooltip origin")
            let origin=try await repo.blame(path:"other")
            try Data("displayed\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"displayed")
            let displayed=try await repo.blame(path:"file")
            let snapshot=GitBlameSnapshot(revision:displayed.revision,path:displayed.path,contents:displayed.contents,encoding:displayed.encoding,lines:displayed.lines+origin.lines)
            return (root,repo,snapshot,origin.revision)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func details(_ repo:GitRepository,_ snapshot:GitBlameSnapshot) async throws -> GitBlameHistoryDetails {
        var options=GitBlameOptions();options.followRenames=true
        return try await repo.blameHistoryDetails(snapshot,options:options)
    }

    func testAllReferenceDecorationsPreserveVisibleRowsTooltipOriginsAndCapturedLifetime() async throws {
        let (root,repo,snapshot,origin)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","origin-label",origin])
        _ = try await repo.run(["tag","light",origin]);_ = try await repo.run(["tag","-a","annotated","-m","tag body",origin]);_ = try await repo.run(["tag","-a","nested","-m","nested body","annotated"])
        for name in ["refs/remotes/origin/main","refs/custom/outside","refs/stash","refs/bisect/good-test"] { _ = try await repo.run(["update-ref",name,origin]) }
        _ = try await repo.run(["config","remote.origin.url",root.path]);_ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")), captured=try await details(repo,snapshot)
        XCTAssertEqual(captured.currentBranch,"refs/heads/main");XCTAssertEqual(captured.head,snapshot.revision)
        XCTAssertTrue(captured.entries.first{$0.hash==snapshot.revision}?.isHead==true)
        XCTAssertFalse(captured.entries.contains{$0.hash==origin});XCTAssertEqual(captured.tooltipEntries.map(\.hash),[origin])
        let refs=try XCTUnwrap(captured.referencesByHash[origin])
        for name in ["refs/heads/origin-label","refs/tags/light","refs/tags/annotated","refs/tags/nested","refs/remotes/origin/main","refs/custom/outside","refs/stash","refs/bisect/good-test"] {XCTAssertTrue(refs.contains{GitReferenceName.equal($0.name,name)},name)}
        XCTAssertEqual(refs.first{$0.name=="refs/tags/annotated"}?.kind,.annotatedTag)
        XCTAssertEqual(refs.first{$0.name=="refs/tags/nested"}?.kind,.annotatedTag)
        XCTAssertEqual(refs.first{$0.name=="refs/bisect/good-test"}?.kind,.bisectGood)
        XCTAssertFalse(refs.contains{$0.name.hasSuffix("^{}")},"Peeled identity is metadata, not a second visible tag")
        XCTAssertEqual(captured.tooltipEntries.first?.references,refs)
        XCTAssertTrue(captured.entries.first{$0.hash==snapshot.revision}?.references.contains{$0.name=="refs/heads/main" && $0.isCurrent}==true)
        XCTAssertEqual(captured.referenceContext.remotes,["origin"])
        XCTAssertEqual(captured.referenceContext.tracking[GitReferenceName("main")],HistoryBranchTracking(remote:"origin",branch:"main"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        _ = try await repo.run(["tag","-d","light"]);_ = try await repo.run(["update-ref","refs/heads/main",origin])
        let next=try await details(repo,snapshot)
        XCTAssertEqual(captured.head,snapshot.revision);XCTAssertTrue(captured.referencesByHash[origin]?.contains{$0.name=="refs/tags/light"}==true)
        XCTAssertEqual(next.head,origin);XCTAssertFalse(next.referencesByHash[origin]?.contains{$0.name=="refs/tags/light"}==true)
        XCTAssertEqual(next.entries.map(\.hash),captured.entries.map(\.hash));XCTAssertTrue(next.tooltipEntries.first?.isHead==true)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file")),snapshot.contents)
    }

    func testDetachedUnbornAndBareHEADMetadataDoNotInventCurrentReference() async throws {
        let (root,repo,snapshot,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["checkout","--detach",snapshot.revision])
        let detached=try await details(repo,snapshot)
        XCTAssertNil(detached.currentBranch);XCTAssertEqual(detached.head,snapshot.revision)
        XCTAssertFalse(detached.referencesByHash.values.flatMap{$0}.contains{$0.isCurrent})
        _ = try await repo.run(["symbolic-ref","HEAD","refs/heads/unborn"])
        let unborn=try await details(repo,snapshot)
        XCTAssertNil(unborn.head);XCTAssertEqual(unborn.currentBranch,"refs/heads/unborn")
        XCTAssertFalse(unborn.entries.contains{$0.isHead});XCTAssertFalse(unborn.referencesByHash.values.flatMap{$0}.contains{$0.isCurrent})
        _ = try await repo.run(["symbolic-ref","HEAD","refs/heads/main"])
        let bare=root.deletingLastPathComponent().appendingPathComponent("BlameBare-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:bare)}
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,bare.path])
        let bareRepo=GitRepository(root:bare,executable:repo.executable,askpass:nil,libgit2Configuration:.init(enabled:false)), result=try await details(bareRepo,snapshot)
        XCTAssertFalse(result.hasWorkingTree);XCTAssertEqual(result.currentBranch,"refs/heads/main");XCTAssertEqual(result.head,snapshot.revision)
        XCTAssertTrue(result.entries.first{$0.hash==snapshot.revision}?.references.contains{$0.isCurrent}==true)
    }

    func testCanonicalEquivalentReferenceIDsRemainDistinctAndVisibilityMasksArePresentationOnly() async throws {
        let (root,repo,snapshot,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let a="refs/heads/caf\u{e9}",b="refs/heads/cafe\u{301}"
        // Loose ref filenames alias on macOS. Git's packed representation can
        // genuinely retain both exact names without changing the working tree.
        let names=[a,b].sorted{$0.utf8.lexicographicallyPrecedes($1.utf8)}
        let packed="# pack-refs with: sorted\n"+names.map{snapshot.revision+" "+$0+"\n"}.joined()
        try Data(packed.utf8).write(to:root.appendingPathComponent(".git/packed-refs"))
        let value=try await details(repo,snapshot),refs=try XCTUnwrap(value.referencesByHash[snapshot.revision])
        let pair=refs.filter{GitReferenceName.equal($0.name,a) || GitReferenceName.equal($0.name,b)}
        XCTAssertEqual(pair.count,2);XCTAssertEqual(Set(pair).count,2)
        XCTAssertEqual(Set(pair.map{Data($0.name.utf8)}),Set([Data(a.utf8),Data(b.utf8)]))
        XCTAssertEqual(value.entries.first{$0.hash==snapshot.revision}?.references,refs)
        XCTAssertTrue(value.referenceContext.labels(refs,visibility:[]).isEmpty)
        XCTAssertEqual(value.referenceContext.labels(pair,visibility:.localBranches).count,2)
        XCTAssertEqual(value.referencesByHash[snapshot.revision]?.count,refs.count,"Hiding labels must not mutate captured metadata")
    }

    func testReferenceReadCancellationSettlesOwnedProcessAndPreservesIndex() async throws {
        let (root,repo,snapshot,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let wrapper=root.appendingPathComponent("held-references"),marker=root.appendingPathComponent("held-references.ready")
        let git=repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")
        let script="""
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = 'show-ref' ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec '\(git)' "$@"
        """
        try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),token=OperationCancellation(),held=GitRepository(root:root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        defer{token.cancel()}
        let work=Task{try await held.blameHistoryDetails(snapshot,options:GitBlameOptions(),cancellation:token)}
        var pids:[Int32]=[]
        for _ in 0..<1000 {
            if let text=try? String(contentsOf:marker){pids=text.split(whereSeparator:\.isWhitespace).compactMap{Int32($0)};if pids.count==2{break}}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        token.cancel()
        do{_ = try await work.value;XCTFail("Cancelled reference metadata returned")}catch is OperationCancellationFailure{}catch is GitCommandCancellationFailure{}
        XCTAssertEqual(pids.count,2,"Reference read was not reached")
        for _ in 0..<500 {if pids.allSatisfy({kill($0,0) != 0}){break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(pids.allSatisfy{kill($0,0) != 0})
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file")),snapshot.contents)
    }
}
