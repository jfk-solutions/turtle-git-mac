import XCTest
@testable import TurtleGitCore

final class GitPropertiesTests: XCTestCase {
    func repo(_ format:String = "sha1") async throws -> (GitRepository,URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitProperties-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try await repo.run(["init","--object-format=" + format,"-b","main"])
        for (key,value) in [("user.name","Property Author"),("user.email","properties@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        return (repo,root)
    }
    func commit(_ repo:GitRepository,_ text:String) async throws -> String { try await repo.run(["commit","-am",text]).stdout; return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines) }
    func testBatchObjectFramingRejectsTruncationAndRetainsLiteralNames() throws {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 64), object = String(repeating: "c", count: 40)
        let queries = [a + ":snow 雪\t:file missing", b + ":absent file"]
        XCTAssertEqual(try GitPropertyObjectBatch.parse(Data((object + "\n" + queries[1] + " missing\n").utf8), expressions: queries), [object, nil])
        XCTAssertEqual(try GitPropertyObjectBatch.parse(Data((object + " submodule\n" + b + " submodule\n").utf8), expressions: queries), [object, b])
        XCTAssertThrowsError(try GitPropertyObjectBatch.parse(Data(("invalid submodule\n" + queries[1] + " missing\n").utf8), expressions: queries))
        XCTAssertEqual(try GitPropertyObjectBatch.parse(Data(), expressions: []), [])
        for data in [Data(), Data((object + "\n").utf8), Data((object + "\nwrong missing\n").utf8), Data((b + "\n" + queries[1] + " missing\n").utf8), Data((object + "\n" + queries[1] + " missing\nextra\n").utf8)] {
            XCTAssertThrowsError(try GitPropertyObjectBatch.parse(data, expressions: queries))
        }
    }
    func testLastModifiedBatchReducesProcessesWithoutChangingSourceWalk() async throws {
        let (repo, root) = try await repo()
        var input = "blob\nmark :1\ndata 5\nbase\n"
        for index in 0..<145 {
            input += "commit refs/heads/main\nmark :\(index + 2)\ncommitter Property Author <properties@example.invalid> \(1700000000 + index) +0000\ndata 1\nx\n"
            if index > 0 { input += "from :\(index + 1)\n" } else { input += "M 100644 :1 file.txt\n" }
            input += "\n"
        }
        _ = try await repo.run(["fast-import", "--quiet"], input: Data(input.utf8)); _ = try await repo.run(["reset", "--hard", "main"])
        let first = try await repo.run(["rev-list", "--max-parents=0", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let engine = repo.executable, helper = root.appendingPathComponent("count-properties"), countFile = root.appendingPathComponent("counts")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nfor task_arg in \"$@\"; do\n case \"$task_arg\" in cat-file|ls-tree) printf '%s\\n' \"$task_arg\" >> " + quote(countFile.path) + ";; esac\ndone\nexec " + quote(engine.path) + " \"$@\"\n"
        try script.write(to: helper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let info = try await GitRepository(root: root, executable: helper).gitProperties(paths: ["file.txt"])
        XCTAssertEqual(info.lastModified?.hash, first)
        let counts = try String(contentsOf: countFile, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(counts.filter { $0 == "cat-file" }.count, 3)
        XCTAssertEqual(counts.filter { $0 == "ls-tree" }.count, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
    func testLiteralNewlinePathsAndUnavailableGitlinkObjectsRetainLastModified() async throws {
        let (repo, root) = try await repo()
        let paths = ["snow 雪\t:name.txt", "line\nname.txt", "line\rname.txt"]
        for path in paths { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); let first = try await commit(repo, "initial")
        _ = try await repo.run(["commit", "--allow-empty", "-m", "unchanged"])
        for path in paths { let info = try await repo.gitProperties(paths: [path]); XCTAssertEqual(info.lastModified?.hash, first) }
        let unavailable = String(repeating: "a", count: 40)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + unavailable + ",module"])
        _ = try await repo.run(["commit", "-m", "gitlink"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let info = try await repo.gitProperties(paths: ["module"])
        XCTAssertEqual(info.lastModified?.hash, head); XCTAssertTrue(info.hasSubmodule)
    }
    func testBranchHeadTrackingConfigurationAndSourceLastContentChange() async throws {
        let (repo,root) = try await repo(); let path = "雪\t:file.txt"
        let unborn = try await repo.gitProperties(paths:["."]); XCTAssertEqual(unborn.branch,"main"); XCTAssertNil(unborn.head); XCTAssertFalse(unborn.allVersioned)
        try Data("base\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);let first = try await commit(repo,"first\n\nbody")
        _ = try await repo.run(["update-index","--chmod=+x","--",path]);_ = try await repo.run(["commit","-m","mode only"]);let mode = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["remote","add","origin","https://example.invalid/雪.git"])
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",mode]);_ = try await repo.run(["branch","--set-upstream-to=origin/main","main"])
        _ = try await repo.run(["config","core.autocrlf","input"])
        let before = try Data(contentsOf:root.appendingPathComponent(".git/index")), info = try await repo.gitProperties(paths:[path])
        XCTAssertEqual(info.head?.hash,mode);XCTAssertEqual(info.lastModified?.hash,first)
        XCTAssertEqual(info.trackedBranch,"origin/main");XCTAssertEqual(info.trackedURL,"https://example.invalid/雪.git");XCTAssertEqual(info.autoCRLF,"input");XCTAssertEqual(info.safeCRLF,"false");XCTAssertEqual(info.userName,"Property Author")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
        _ = try await repo.run(["checkout","--detach",mode]);let detached = try await repo.gitProperties(paths:[path]);XCTAssertEqual(detached.branch,"detached HEAD")
    }
    func testVersionedMixedStatesAtomicModesFlagsAndOriginalObjectsAcrossFormats() async throws {
        for format in ["sha1","sha256"] { for version in [2,3,4] {
            let (repo,root) = try await repo(format), first = "雪\t,line\n.txt", second = "other.txt"
            try Data("first\n".utf8).write(to:root.appendingPathComponent(first));try Data("second\n".utf8).write(to:root.appendingPathComponent(second));try await repo.stage([first,second]);_ = try await commit(repo,"baseline")
            _ = try await repo.run(["update-index","--index-version=\(version)"])
            _ = try await repo.run(["update-index","--assume-unchanged","--",second])
            try Data("unstaged first\n".utf8).write(to:root.appendingPathComponent(first))
            let info = try await repo.gitProperties(paths:[first,second]), objects = info.entries.map(\.object)
            XCTAssertEqual(info.draft.assumeUnchanged,.mixed)
            var draft = info.draft; draft.executable = .on;draft.skipWorktree = .on
            let updated = try await repo.applyGitProperties(draft,snapshot:info)
            XCTAssertEqual(updated.entries.map(\.object),objects);XCTAssertEqual(updated.entries.map(\.mode),["100755","100755"])
            XCTAssertEqual(updated.entries.map(\.assumeUnchanged),[false,true]);XCTAssertTrue(updated.entries.allSatisfy(\.skipWorktree))
            let real = try await repo.gitProperties(paths:[first,second]);XCTAssertEqual(real.entries,updated.entries)
            let tree = try await repo.run(["write-tree"]).text;XCTAssertFalse(tree.isEmpty)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(first)),Data("unstaged first\n".utf8))
            var symlink = real.draft;symlink.executable = .off;symlink.symlink = .on
            let latest = try await repo.gitProperties(paths:[first,second]);let links = try await repo.applyGitProperties(symlink,snapshot:latest);XCTAssertTrue(links.entries.allSatisfy { $0.mode == "120000" });XCTAssertEqual(links.entries.map(\.object),objects)
        } }
    }
    func testSplitIndexIntentToAddAndConflictStagePreservation() async throws {
        let (repo,root) = try await repo()
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await commit(repo,"base")
        try Data("not staged\n".utf8).write(to:root.appendingPathComponent("intent"));_ = try await repo.run(["add","-N","--","intent"])
        _ = try await repo.run(["update-index","--split-index"])
        let info = try await repo.gitProperties(paths:["file"])
        let before = try await repo.run(["diff","--no-ext-diff","--","intent"]).stdout
        var draft = info.draft;draft.executable = .on
        _ = try await repo.applyGitProperties(draft,snapshot:info)
        let after = try await repo.run(["diff","--no-ext-diff","--","intent"]).stdout;XCTAssertEqual(before,after)
        let intent = try await repo.gitProperties(paths:["intent"]);var intentDraft = intent.draft;intentDraft.executable = .on
        _ = try await repo.applyGitProperties(intentDraft,snapshot:intent)
        let cached = try await repo.run(["diff","--cached","--","intent"]).stdout;XCTAssertEqual(cached,Data())
        _ = try await repo.run(["update-index","--no-assume-unchanged","--no-skip-worktree","--","file"])
        _ = try await repo.run(["checkout","-b","side"]);try Data("side\n".utf8).write(to:root.appendingPathComponent("file"));_ = try await commit(repo,"side")
        _ = try await repo.run(["checkout","main"]);try Data("main\n".utf8).write(to:root.appendingPathComponent("file"));_ = try await commit(repo,"main")
        do { _ = try await repo.run(["merge","side"]) } catch {}
        let conflicted = try await repo.gitProperties(paths:["file"]);XCTAssertEqual(conflicted.entries.first?.stage,1)
        let stages = try await repo.run(["ls-files","--stage","-z","--","file"]).stdout
        var flags = conflicted.draft;flags.assumeUnchanged = .on;flags.skipWorktree = .on
        _ = try await repo.applyGitProperties(flags,snapshot:conflicted)
        let afterStages = try await repo.run(["ls-files","--stage","-z","--","file"]).stdout;XCTAssertEqual(afterStages,stages)
        let afterFlags = try await repo.gitProperties(paths:["file"]);XCTAssertEqual(afterFlags.draft.assumeUnchanged,.on)
    }
    func testStaleLockedInvalidAndCancelledRequestsPublishNothing() async throws {
        let (repo,root) = try await repo();try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"])
        let info = try await repo.gitProperties(paths:["file"]);var draft = info.draft;draft.assumeUnchanged = .on
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf:index), token = OperationCancellation();token.cancel()
        do { try await repo.applyGitProperties(draft,snapshot:info,cancellation:token);XCTFail() } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:index),original)
        let lock = root.appendingPathComponent(".git/index.lock");try Data("foreign lock".utf8).write(to:lock)
        do { try await repo.applyGitProperties(draft,snapshot:info);XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf:lock),Data("foreign lock".utf8));try FileManager.default.removeItem(at:lock)
        draft.executable = .on;draft.symlink = .on
        do { try await repo.applyGitProperties(draft,snapshot:info);XCTFail() } catch GitPropertyFailure.mode {}
        XCTAssertEqual(try Data(contentsOf:index),original)
        _ = try await repo.run(["update-index","--assume-unchanged","--","file"])
        let changed = try Data(contentsOf:index)
        do { try await repo.applyGitProperties(info.draft,snapshot:info);XCTFail() } catch GitPropertyFailure.stale {}
        XCTAssertEqual(try Data(contentsOf:index),changed);XCTAssertFalse(FileManager.default.fileExists(atPath:lock.path))
        do { _ = try await repo.gitProperties(paths:["../outside"]);XCTFail() } catch GitPropertyFailure.selection {}
    }
    func testSourceMergeParentPruningAndMissingHeadPath() async throws {
        let (repo,root) = try await repo();try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await commit(repo,"base")
        _ = try await repo.run(["checkout","-b","same"]);try Data("other\n".utf8).write(to:root.appendingPathComponent("other"));try await repo.stage(["other"]);let same = try await commit(repo,"unrelated")
        _ = try await repo.run(["checkout","main"]);try Data("different\n".utf8).write(to:root.appendingPathComponent("file"));let different = try await commit(repo,"different")
        let tree = try await repo.run(["rev-parse",same + "^{tree}"]).text.trimmingCharacters(in:.newlines)
        let merge = try await repo.run(["commit-tree",tree,"-p",same,"-p",different,"-m","merge"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","HEAD",merge]);_ = try await repo.run(["read-tree",merge])
        let info = try await repo.gitProperties(paths:["file"]);XCTAssertEqual(info.lastModified?.hash,same)
        try Data("new\n".utf8).write(to:root.appendingPathComponent("new"));try await repo.stage(["new"])
        let added = try await repo.gitProperties(paths:["new"]);XCTAssertNil(added.lastModified)
    }
}
