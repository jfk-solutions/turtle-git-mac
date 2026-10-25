import XCTest
@testable import TurtleGitCore

final class SynchronizationTests: XCTestCase {
    private final class MailCompletionCapture:@unchecked Sendable {
        private let lock=NSLock()
        private var storage:[SynchronizationCommandCompletion]=[]
        func append(_ value:SynchronizationCommandCompletion){lock.lock();defer{lock.unlock()};storage.append(value)}
        var values:[SynchronizationCommandCompletion]{lock.lock();defer{lock.unlock()};return storage}
    }
    private func fixture(rootSuffix:String = "") async throws -> (URL, GitRepository, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-" + UUID().uuidString + rootSuffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        _ = try await repo.commit(message: "base")
        let base = try await hash(repo)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", base])
        return (root, repo, base)
    }
    private func hash(_ repo: GitRepository) async throws -> String {
        String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func testEmailPatchExportsSelectedRangeAndPreservesGitState() async throws {
        let (root, repo, base) = try await fixture(rootSuffix:"-Cafe\u{301}\n🐢"); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first-mail", "second-mail"] {
            try Data((name + "\n").utf8).write(to: root.appendingPathComponent(name)); try await repo.stage([name])
            _ = try await repo.commit(message: name)
        }
        let local = try await hash(repo)
        _ = try await repo.run(["switch", "-c", "other", base])
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let export = try await repo.synchronizationEmailPatchFiles(localBranch: "main", remote: " origin ", remoteBranch: " main ")
        let result=export.result,files=export.files
        XCTAssertEqual(result.exitCode,0)
        XCTAssertEqual(try FormatPatchExport.exportedFiles(stdout:result.stdout,in:root).map{Data($0.path.utf8)},files.map{Data($0.path.utf8)})
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try files.map { try SerialPatch(file: $0).subject }, ["[PATCH 1/2] first-mail", "[PATCH 2/2] second-mail"])
        XCTAssertTrue(files.allSatisfy { $0.deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath() })
        let after = try await hash(repo), afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(after, base); XCTAssertEqual(afterRefs, refs)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        // FixBranchName selects the sole for-merge FETCH_HEAD record, not Git's
        // first not-for-merge line. An octopus/empty selection cannot export.
        try Data((base + "\tnot-for-merge\tbranch 'other'\n" + local + "\t\tbranch 'main'\n").utf8).write(to: root.appendingPathComponent(".git/FETCH_HEAD"))
        let fetched = try await repo.synchronizationEmailPatches(localBranch: "FETCH_HEAD", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(fetched.stdout, result.stdout)
        try Data((base + "\t\tbranch 'other'\n" + local + "\t\tbranch 'main'\n").utf8).write(to: root.appendingPathComponent(".git/FETCH_HEAD"))
        do { _ = try await repo.synchronizationEmailPatches(localBranch: "FETCH_HEAD", remote: "origin", remoteBranch: "main"); XCTFail("ambiguous FETCH_HEAD exported") } catch is SynchronizationFailure {}
    }
    func testEmailPatchEmptyRangeAndCancelledExport() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let export = try await repo.synchronizationEmailPatchFiles(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertTrue(export.result.stdout.isEmpty);XCTAssertTrue(export.files.isEmpty)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationEmailPatchFiles(localBranch: "main", remote: "origin", remoteBranch: "main", cancellation: token); XCTFail("cancelled export ran") } catch is OperationCancellationFailure {}
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".patch") })
        do { _ = try await repo.synchronizationEmailPatches(localBranch: "main", remote: "origin", remoteBranch: "missing"); XCTFail("missing branch exported") } catch is GitFailure {}
    }
    func testSuccessfulEmailExportWithUnverifiableLaterFileNeverReturnsPartialReceipt() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("mail change\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"])
        _=try await repo.commit(message:"mail attachment")
        let before=try await repo.run(["show-ref"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let helper=root.appendingPathComponent(".git/mail-git"),done=root.appendingPathComponent(".git/export-completed")
        let environment=GitRuntime.environment(executable:repo.executable).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let script="""
        #!/bin/sh
        \(environment)
        if [ "${4-}" = format-patch ]; then
          \(quote(repo.executable.path)) "$@" || exit "$?"
          : > \(quote(done.path))
          printf '%s\\n' "$6/missing.patch"
          exit 0
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper,libgit2Configuration:.init(enabled:false)),receipts=MailCompletionCapture()
        do {
            _=try await wrapped.synchronizationEmailPatchFiles(localBranch:"main",remote:"origin",remoteBranch:"main",onCommandFinished:{receipts.append($0)})
            XCTFail("An unverifiable later attachment must not publish an earlier valid subset")
        }catch FormatPatchFailure.output {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:done.path),"The export itself must have completed successfully")
        XCTAssertEqual(receipts.values.count,1)
        let completed=try XCTUnwrap(receipts.values.first)
        XCTAssertTrue(completed.success);XCTAssertFalse(completed.cancelled);XCTAssertEqual(completed.exitCode,0)
        let written=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension=="patch"}
        XCTAssertEqual(written.count,1)
        XCTAssertEqual(try written.map{try SerialPatch(file:$0).subject},["[PATCH] mail attachment"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("missing.patch").path))
        let after=try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(after,before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testBranchControlsUsePullTrackingRatherThanPushOverrides() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["origin", "publish"] { _ = try await repo.run(["remote", "add", name, "/tmp/" + name]) }
        for (key, value) in [("branch.main.remote", "origin"), ("branch.main.merge", "refs/heads/review/雪"), ("branch.main.pushRemote", "publish"), ("branch.main.pushbranch", "release"), ("remote.pushDefault", "publish")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["branch", "other"])
        _ = try await repo.run(["config", "branch.other.merge", "refs/tags/release \t"])
        // Packed refs can represent both spellings on normalization-insensitive APFS.
        let oid = try await hash(repo)
        let names = ["refs/heads/café", "refs/heads/cafe\u{301}"].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        try Data(("# pack-refs with: sorted\n" + names.map { oid + " " + $0 + "\n" }.joined()).utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let catalog = try await repo.synchronizationBranches()
        XCTAssertEqual(catalog.currentBranch, "main"); XCTAssertEqual(catalog.localBranches.count, 4)
        for spelling in ["café", "cafe\u{301}", "main", "other"] { XCTAssertTrue(catalog.localBranches.contains { GitReferenceName.equal($0, spelling) }) }
        XCTAssertEqual(catalog.remotes, ["origin", "publish"])
        XCTAssertEqual(catalog.trackedRemote, "origin"); XCTAssertEqual(catalog.trackedBranch, "review/雪")
        let other = try await repo.synchronizationBranches(localBranch: "other")
        XCTAssertEqual(other.trackedRemote, ""); XCTAssertEqual(other.trackedBranch, "tags/release")
        let untracked = try await repo.synchronizationBranches(localBranch: "absent")
        XCTAssertEqual(untracked.trackedRemote, ""); XCTAssertEqual(untracked.trackedBranch, "")
        _ = try await repo.run(["switch", "--detach"])
        let detached = try await repo.synchronizationBranches()
        XCTAssertEqual(detached.currentBranch, ""); XCTAssertEqual(detached.trackedRemote, "")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationBranches(cancellation: token); XCTFail("cancelled catalog read ran") } catch is OperationCancellationFailure {}
        do { _ = try await repo.synchronizationBranches(localBranch: "main\0bad"); XCTFail("NUL accepted") } catch SynchronizationFailure.invalidInput {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }
    func testAheadEqualMissingAndIncomingUsePinnedRevisions() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let equal = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(equal.disposition, .upToDate); XCTAssertFalse(equal.canEmailPatch); XCTAssertNil(equal.comparison)
        let path = "new 雪\t🐢.txt"
        try Data("new\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "outgoing")
        let tip = try await hash(repo)
        let ahead = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(ahead.disposition, .outgoing); XCTAssertTrue(ahead.fastForward && ahead.canEmailPatch)
        XCTAssertEqual(ahead.commits.map(\.hash), [tip]); XCTAssertEqual(ahead.comparison?.files.map(\.path), [path]); XCTAssertEqual(ahead.mergeBase, base)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", tip])
        XCTAssertEqual(ahead.remoteHash, base) // The old snapshot remains pinned.
        let incoming = try await repo.synchronizationIncoming(from: base, to: tip)
        XCTAssertEqual(incoming.commits.map(\.hash), [tip]); XCTAssertEqual(incoming.comparison.files.map(\.path), [path])
        let unchanged = try await repo.synchronizationIncoming(from: tip, to: tip)
        XCTAssertTrue(unchanged.commits.isEmpty && unchanged.comparison.files.isEmpty)
        for remote in ["https://example.invalid/repository", "/tmp/repository", "host:path/to/repository", "C:\\repository"] {
            let unknown = try await repo.synchronizationOutgoing(localBranch: "missing", remote: remote, remoteBranch: "main", force: true)
            XCTAssertEqual(unknown.disposition, .unknownURL); XCTAssertNil(unknown.localHash); XCTAssertFalse(unknown.canEmailPatch)
        }
        let missing = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "absent", force: true)
        XCTAssertEqual(missing.disposition, .unknownRemoteBranch); XCTAssertTrue(missing.commits.isEmpty)
    }
    func testDivergedForceUsesMergeBaseAndPreservesIndexAndWorkingTree() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["switch", "-c", "remote-tip"])
        try Data("remote\n".utf8).write(to: root.appendingPathComponent("remote")); try await repo.stage(["remote"]); _ = try await repo.commit(message: "remote change")
        let remote = try await hash(repo); _ = try await repo.run(["update-ref", "refs/remotes/origin/main", remote]); _ = try await repo.run(["switch", "main"])
        try Data("local\n".utf8).write(to: root.appendingPathComponent("local")); try await repo.stage(["local"]); _ = try await repo.commit(message: "local change")
        let tip = try await hash(repo)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("unstaged\n".utf8).write(to: root.appendingPathComponent("file"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let blocked = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(blocked.disposition, .needsForce); XCTAssertNil(blocked.comparison); XCTAssertFalse(blocked.canEmailPatch)
        let forced = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main", force: true)
        XCTAssertFalse(forced.fastForward); XCTAssertEqual(forced.mergeBase, base); XCTAssertEqual(forced.commits.map(\.hash), [tip])
        XCTAssertEqual(forced.comparison?.from, .revision(base)); XCTAssertEqual(forced.comparison?.files.map(\.path), ["local"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "unstaged\n")
        let head = try await hash(repo); XCTAssertEqual(head, tip)
        let behind = try await repo.synchronizationOutgoing(localBranch: base, remote: "origin", remoteBranch: "main", force: true)
        XCTAssertEqual(behind.disposition, .outgoing); XCTAssertTrue(behind.commits.isEmpty && behind.canEmailPatch)
    }
    func testSourceCopyDetectionRetainsOriginalPath() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("copied 雪"))
        try Data("modified\n".utf8).write(to: root.appendingPathComponent("file"))
        try await repo.stage(["file", "copied 雪"]); _ = try await repo.commit(message: "copy source")
        let snapshot = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        let copied = snapshot.comparison!.files.first { $0.path == "copied 雪" }!
        XCTAssertTrue(copied.action.hasPrefix("C")); XCTAssertEqual(copied.oldPath, "file")
        XCTAssertTrue(snapshot.comparison!.options.detectCopies)
    }
    func testFullOutgoingWalkIsNotTruncatedToLogDefault() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = String(decoding: try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        var tip = base
        for number in 0..<205 { tip = String(decoding: try await repo.run(["commit-tree", tree, "-p", tip, "-m", "sync \(number)"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        _ = try await repo.run(["update-ref", "refs/heads/main", tip])
        let snapshot = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(snapshot.commits.count, 205); XCTAssertEqual(snapshot.commits.first?.hash, tip); XCTAssertTrue(snapshot.comparison!.files.isEmpty)
    }
    func testCancellationInvalidInputsAndUnrelatedForceWorkingCopyFallback() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main", cancellation: token); XCTFail("Cancelled projection ran") } catch is OperationCancellationFailure {}
        do { _ = try await repo.synchronizationOutgoing(localBranch: "main\0bad", remote: "origin", remoteBranch: "main"); XCTFail("NUL accepted") } catch SynchronizationFailure.invalidInput {}
        let tree = String(decoding: try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let unrelated = String(decoding: try await repo.run(["commit-tree", tree, "-m", "unrelated root"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try Data("working change\n".utf8).write(to: root.appendingPathComponent("file"))
        let forced = try await repo.synchronizationOutgoing(localBranch: unrelated, remote: "origin", remoteBranch: "main", force: true)
        XCTAssertEqual(forced.disposition, .outgoing); XCTAssertTrue(forced.canEmailPatch); XCTAssertNil(forced.mergeBase)
        XCTAssertEqual(forced.commits.map(\.hash), [unrelated]); XCTAssertEqual(forced.comparison?.from, .workingTree)
        XCTAssertEqual(forced.comparison?.files.map(\.path), ["file"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "working change\n")
        let refs = try await repo.run(["show-ref"]).stdout; XCTAssertEqual(refs, before); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
}
