// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class LibGit2CommitIndexTests: XCTestCase {
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func executable(_ file: URL, _ text: String) throws {
        try Data(text.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    private struct Fixture {
        let root: URL, repo: GitRepository, helper: URL
        var backend: GitLibGit2Configuration { .init(mask: GitLibGit2Operation.commitUpdateIndex.mask, helperURL: helper) }
        var index: URL { repo.root.appendingPathComponent(".git/index") }
    }
    private func fixture(initial: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("commit-index ' 雪-" + UUID().uuidString), folder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let actual = try XCTUnwrap(GitLibGit2Configuration(mask: 8).executor(for: .commitUpdateIndex)), wrapper = root.appendingPathComponent("git"), helper = root.appendingPathComponent("selected-helper")
        let global = root.appendingPathComponent("global.config"); try Data().write(to: global)
        let runtime = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let environment = "unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(global.path) + " HOME=" + quote(root.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n" + runtime + "\n"
        // Preserve Core's private GIT_INDEX_FILE for original Git operations.
        let gitEnvironment = environment.replacingOccurrences(of: " GIT_INDEX_FILE", with: "")
        try executable(wrapper, "#!/bin/sh\n" + gitEnvironment + "exec " + quote(git.path) + " \"$@\"\n")
        try executable(helper, "#!/bin/sh\n" + environment + "printf '%s\\0' \"$@\" > \"$0.argv\"\nexec " + quote(actual.path) + " \"$@\"\n")
        let repo = GitRepository(root: folder, executable: wrapper, askpass: nil, libgit2Configuration: .init())
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Commit index fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false"), ("core.symlinks", "true")] { _ = try await repo.run(["config", key, value]) }
        if initial {
            for path in ["base", "other", "deleted", "old"] { try Data((path + "\n").utf8).write(to: folder.appendingPathComponent(path)) }
            try await repo.stage(["base", "other", "deleted", "old"]); _ = try await repo.commit(message: "base")
        }
        return .init(root: root, repo: repo, helper: helper)
    }
    private func blob(_ repo: GitRepository, _ path: String, revision: String = "HEAD") async throws -> Data { try await repo.run(["-c", "core.precomposeunicode=false", "show", revision + ":" + path]).stdout }
    private func head(_ repo: GitRepository) async throws -> Data { try await repo.run(["rev-parse", "HEAD"]).stdout }
    private func clean(_ f: Fixture, required: Bool = true, process: Bool = false) async throws {
        let script = f.root.appendingPathComponent("clean ' literal")
        try executable(script, """
        #!/usr/bin/python3
        import json, os, pathlib, sys
        root=pathlib.Path(__file__).parent
        with (root/'clean.calls').open('ab') as calls: calls.write(b'1\\n')
        (root/'clean.json').write_text(json.dumps({'cwd':os.getcwd(),'args':sys.argv[1:],'index':os.environ.get('GIT_INDEX_FILE')}))
        sys.stderr.buffer.write(b'filter-diagnostic' * 8192)
        sys.stdout.buffer.write(b'CLEAN[' + sys.stdin.buffer.read() + b']')
        """)
        try Data("*.clean filter=fixture -text\n*.text text eol=lf\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        _ = try await f.repo.run(["config", "--global", "filter.fixture.clean", quote(script.path) + " %f '%%'"])
        _ = try await f.repo.run(["config", "--global", "filter.fixture.required", required ? "true" : "false"])
        if process { _ = try await f.repo.run(["config", "--global", "filter.fixture.process", "exit 86"]) }
    }

    func testSelectedCleanRunsOnceForUntrackedLiteralBinaryAndRetainsUnselectedIndexAndRawStaging() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(GitLibGit2Operation.commitUpdateIndex.mask, 8); XCTAssertFalse(GitLibGit2Configuration().requests(.commitUpdateIndex))
        try Data("unchecked staged\n".utf8).write(to: f.repo.root.appendingPathComponent("other")); try await f.repo.stage(["other"])
        let retained = try await f.repo.run(["ls-files", "--stage", "-z", "--", "other"]).stdout
        try await clean(f, process: true)
        let path = ":(literal) % ' cafe\u{301}\n.clean", bytes = Data(repeating: 0x41, count: 131_072) + Data([0, 255, 10])
        try bytes.write(to: f.repo.root.appendingPathComponent(path)); try Data("one\r\ntwo\r\n".utf8).write(to: f.repo.root.appendingPathComponent("line.text"))
        // This test isolates source one-shot preparation. Ordinary Git commit
        // refreshes its index and may legitimately re-run configured process
        // filters for stat-racy files; that distinct boundary is tested below.
        for selected in [path,"line.text"] {
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_000_000_000)],ofItemAtPath:f.repo.root.appendingPathComponent(selected).path)
        }
        let config = try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), global = try Data(contentsOf: f.root.appendingPathComponent("global.config"))
        _ = try await f.repo.commitSelected(message: "library clean", paths: [path, "line.text"], backend: f.backend)
        let stored = try await blob(f.repo, path), line = try await blob(f.repo, "line.text")
        XCTAssertEqual(stored, Data("CLEAN[".utf8) + bytes + Data("]".utf8)); XCTAssertEqual(line, Data("one\ntwo\n".utf8))
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(path)), bytes)
        let after = try await f.repo.run(["ls-files", "--stage", "-z", "--", "other"]).stdout; XCTAssertEqual(after, retained)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), config); XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
        let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appendingPathComponent("clean.json"))) as? [String: Any])
        XCTAssertEqual(details["args"] as? [String], [path, "%"])
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(details["cwd"] as? String)).resolvingSymlinksInPath(), f.repo.root.resolvingSymlinksInPath())
        XCTAssertNotEqual(details["index"] as? String, f.index.path)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("clean.calls")), Data("1\n".utf8))
        // The staging-area path commits its exact existing OIDs without invoking
        // either selected Commit preparation or the poisoned process driver.
        // Remove the working leaf so Git's ordinary stat refresh cannot clean it;
        // a raw index commit must retain its already staged blob regardless.
        try FileManager.default.removeItem(at: f.repo.root.appendingPathComponent(path))
        _ = try await f.repo.commitIndex(message: "raw staging")
        let stagedOther = try await blob(f.repo, "other"); XCTAssertEqual(stagedOther, Data("unchecked staged\n".utf8))
        let retainedClean = try await blob(f.repo, path); XCTAssertEqual(retainedClean, stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.root.appendingPathComponent(path).path))
    }

    func testRacyPreparedSelectionPropagatesOrdinaryGitProcessFailureAndRetainsRetryState()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try Data("unchecked staged\n".utf8).write(to:f.repo.root.appendingPathComponent("other"));try await f.repo.stage(["other"])
        let unselected=try await f.repo.run(["ls-files","--stage","-z","--","other"]).stdout
        let originalFlags=try await f.repo.run(["ls-files","-v","-z","--","other"]).stdout
        let beforeHead=try await head(f.repo)
        try await clean(f,process:true)
        let path="racy literal %.clean",bytes=Data([65,0,255,10]),expected=Data("CLEAN[".utf8)+bytes+Data("]".utf8)
        let file=f.repo.root.appendingPathComponent(path);try bytes.write(to:file)
        // A real future file mtime forces Git's documented racy-index content
        // verification regardless of subsecond support or machine speed. We do
        // not modify private index clocks, flags, hooks or filter configuration.
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(3600)],ofItemAtPath:file.path)
        let config=try Data(contentsOf:f.repo.root.appendingPathComponent(".git/config")),global=try Data(contentsOf:f.root.appendingPathComponent("global.config"))
        do {_ = try await f.repo.commitSelected(message:"racy process refusal",paths:[path],backend:f.backend);XCTFail("Ordinary Git ignored the required failing process filter")}
        catch let error as GitFailure {
            XCTAssertEqual(error.arguments.first,"commit");XCTAssertEqual(error.code,128)
            let appleHandshakeFailure=error.message.contains("remote end hung up unexpectedly")
            let currentHandshakeFailure=error.message.contains("could not read greeting from subprocess") && error.message.contains("initialization for subprocess") && error.message.contains("exit 86")
            XCTAssertTrue(appleHandshakeFailure || currentHandshakeFailure,error.message)
        }
        let unchangedHead=try await head(f.repo);XCTAssertEqual(unchangedHead,beforeHead)
        let staged=try await blob(f.repo,path,revision:"");XCTAssertEqual(staged,expected)
        let retained=try await f.repo.run(["ls-files","--stage","-z","--","other"]).stdout;XCTAssertEqual(retained,unselected)
        let retainedFlags=try await f.repo.run(["ls-files","-v","-z","--","other"]).stdout;XCTAssertEqual(retainedFlags,originalFlags)
        let selectedFlags=try await f.repo.run(["ls-files","-v","-z","--",path]).stdout
        XCTAssertEqual(selectedFlags,Data(("H "+path+"\0").utf8),"Preparation must not hide ordinary Git refresh using assume-unchanged/skip-worktree")
        XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertFalse(FileManager.default.fileExists(atPath:f.index.path+".lock"))
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/config")),config);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("global.config")),global)
        let details=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:f.root.appendingPathComponent("clean.json"))) as? [String:Any])
        XCTAssertNotEqual(details["index"] as? String,f.index.path)
        // The user's actual repair, rather than a production override, permits
        // retry using the same one-shot source engine and ordinary Git hooks.
        _ = try await f.repo.run(["config","--global","--unset","filter.fixture.process"])
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_000_000_000)],ofItemAtPath:file.path)
        let repairedGlobal=try Data(contentsOf:f.root.appendingPathComponent("global.config"))
        _ = try await f.repo.commitSelected(message:"retry repaired process",paths:[path],backend:f.backend)
        let committed=try await blob(f.repo,path);XCTAssertEqual(committed,expected)
        let afterHead=try await head(f.repo);XCTAssertNotEqual(afterHead,beforeHead)
        let afterUnselected=try await f.repo.run(["ls-files","--stage","-z","--","other"]).stdout;XCTAssertEqual(afterUnselected,unselected)
        let afterFlags=try await f.repo.run(["ls-files","-v","-z","--","other"]).stdout;XCTAssertEqual(afterFlags,originalFlags)
        XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("global.config")),repairedGlobal)
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/config")),config)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.index.path+".lock"))
    }

    func testCheckedModesRenameDeletionRetainedCopyAndExactUnicodePaths() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for (name, mode) in [("explicit-exe", "100755"), ("explicit-link", "120000")] {
            try Data("old target".utf8).write(to: f.repo.root.appendingPathComponent(name)); try await f.repo.stage([name])
            let hash = try await f.repo.run(["rev-parse", ":" + name]).text.trimmingCharacters(in: .newlines)
            _ = try await f.repo.run(["update-index", "--cacheinfo", mode + "," + hash + "," + name])
            try Data("latest target".utf8).write(to: f.repo.root.appendingPathComponent(name))
        }
        _ = try await f.repo.run(["mv", "old", "renamed"])
        _ = try await f.repo.run(["rm", "--cached", "deleted"])
        let literal = "caf\u{e9}: %.txt"; try Data("Unicode\n".utf8).write(to: f.repo.root.appendingPathComponent(literal))
        // With precomposeunicode=false, an untracked APFS filename is reported
        // using the filesystem's decomposed spelling. Seed the intended exact
        // tracked identity before exercising current-content Commit preparation.
        let originalUnicode = try await f.repo.run(["hash-object", "-w", "--stdin"], input: Data("old Unicode\n".utf8)).text.trimmingCharacters(in: .newlines)
        _ = try await f.repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "100644," + originalUnicode + "," + literal])
        let link = f.repo.root.appendingPathComponent("actual-link")
        XCTAssertEqual(link.path.withCString { symlink("../../never-follow-target", $0) }, 0)
        var options = CommitOptions(); options.newBranch = "commit-engine"
        _ = try await f.repo.commitSelected(message: "modes and deletion", paths: ["explicit-exe", "explicit-link", "actual-link", "renamed", "deleted", literal], options: options, backend: f.backend)
        for (name, mode) in [("explicit-exe", "100755"), ("explicit-link", "120000")] {
            let tree = try await f.repo.run(["ls-tree", "HEAD", "--", name]).text, data = try await blob(f.repo, name)
            XCTAssertTrue(tree.hasPrefix(mode + " ")); XCTAssertEqual(data, Data("latest target".utf8))
            XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(name)), data)
        }
        let names = try await f.repo.run(["ls-tree", "-r", "--name-only", "-z", "HEAD"]).stdout.split(separator: UInt8(0)).map { (bytes: Data.SubSequence) in Data(bytes) }
        XCTAssertTrue(names.contains(Data(literal.utf8))); XCTAssertTrue(names.contains(Data("renamed".utf8))); XCTAssertFalse(names.contains(Data("old".utf8))); XCTAssertFalse(names.contains(Data("deleted".utf8)))
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent("deleted")), Data("deleted\n".utf8))
        let linkBytes = try await blob(f.repo, "actual-link"); XCTAssertEqual(linkBytes, Data("../../never-follow-target".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../../never-follow-target")
        let branch = try await f.repo.branch(); XCTAssertEqual(branch, "commit-engine")
    }

    func testCheckboxRestorationUsesLibraryForUncheckedAddAndPreservesSourceResetAndHookFailurePolicy() async throws {
        for reject in [false, true] {
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            try Data("checked\n".utf8).write(to: f.repo.root.appendingPathComponent("base"))
            try Data("staged other\n".utf8).write(to: f.repo.root.appendingPathComponent("other")); try await f.repo.stage(["other"])
            try await clean(f)
            let added = "unchecked.clean"; try Data("staged".utf8).write(to: f.repo.root.appendingPathComponent(added)); try await f.repo.stage([added])
            try Data("working".utf8).write(to: f.repo.root.appendingPathComponent(added))
            _ = try await f.repo.run(["rm", "deleted"]); _ = try await f.repo.run(["mv", "old", "renamed"])
            if reject {
                let hooks = f.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
                try executable(hooks.appendingPathComponent("pre-commit"), "#!/bin/sh\nexit 1\n"); _ = try await f.repo.run(["config", "core.hooksPath", hooks.path])
            }
            var options = CommitOptions(); options.checkboxIndexPolicy = .init(paths: ["base", "other", added, "deleted", "renamed"])
            let initialHead = try await head(f.repo)
            do { _ = try await f.repo.commitSelected(message: "checkbox", paths: ["base"], options: options, backend: f.backend); XCTAssertFalse(reject) } catch is GitFailure { XCTAssertTrue(reject) }
            let indexedOther = try await blob(f.repo, "other", revision: ""), indexedAdded = try await blob(f.repo, added, revision: "")
            XCTAssertEqual(indexedOther, Data("other\n".utf8)); XCTAssertEqual(indexedAdded, Data("CLEAN[working]".utf8))
            let status = try await f.repo.status(); XCTAssertTrue(status.contains { $0.path == "deleted" && $0.index == "D" }); XCTAssertTrue(status.contains { $0.path == "renamed" && $0.index == "R" })
            if reject { let after = try await head(f.repo); XCTAssertEqual(after, initialHead) }
            XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(added)), Data("working".utf8))
        }
    }

    func testSelectedRequiredFailuresAndCapturedBackendKeepRealIndexAndHeadExact() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let suite = "CommitIndex." + UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(8, forKey: "UseLibgit2_mask")
        let captured = GitLibGit2Configuration.load(from: preferences, helperURL: f.helper)
        preferences.set(false, forKey: "UseLibgit2"); preferences.set(0, forKey: "UseLibgit2_mask")
        try Data("*.clean filter=fixture -text\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try Data("new".utf8).write(to: f.repo.root.appendingPathComponent("new.clean"))
        try Data("staged other".utf8).write(to: f.repo.root.appendingPathComponent("other")); try await f.repo.stage(["other"])
        _ = try await f.repo.run(["config", "filter.fixture.required", "true"]); _ = try await f.repo.run(["config", "filter.fixture.clean", "exit 31"])
        var options = CommitOptions(); options.checkboxIndexPolicy = .init(paths: ["new.clean", "other"])
        let index = try Data(contentsOf: f.index), beforeHead = try await head(f.repo)
        for missing in [false, true] {
            if missing { _ = try await f.repo.run(["config", "--unset", "filter.fixture.clean"]) }
            do { _ = try await f.repo.commitSelected(message: "must fail", paths: ["new.clean"], options: options, backend: captured); XCTFail("Required failure committed") } catch is GitFailure {}
            XCTAssertEqual(try Data(contentsOf: f.index), index); let after = try await head(f.repo); XCTAssertEqual(after, beforeHead)
        }
        let missing = GitLibGit2Configuration(mask: 8, helperURL: f.root.appendingPathComponent("absent"))
        do { _ = try await f.repo.commitSelected(message: "missing", paths: ["new.clean"], backend: missing); XCTFail("Missing runtime fell back") } catch GitLibGit2Failure.runtimeMissing {}
        XCTAssertEqual(try Data(contentsOf: f.index), index)
        _ = try await f.repo.run(["config", "filter.fixture.required", "false"])
        _ = try await f.repo.commitSelected(message: "optional missing", paths: ["new.clean"], backend: captured)
        let optional = try await blob(f.repo, "new.clean"); XCTAssertEqual(optional, Data("new".utf8))
        for backend in [GitLibGit2Configuration(enabled: false, mask: 8, helperURL: missing.helperURL), .init(mask: 0, helperURL: missing.helperURL)] {
            try Data(UUID().uuidString.utf8).write(to: f.repo.root.appendingPathComponent("base"))
            _ = try await f.repo.commitSelected(message: "CLI selected", paths: ["base"], backend: backend)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.index.path + ".lock"))
    }

    func testUnbornParentAmendMessageOnlyAndPendingMergeUseSelectedPreparedTree() async throws {
        let f = try await fixture(initial: false); defer { try? FileManager.default.removeItem(at: f.root) }
        for name in ["first", "other"] { try Data((name + "\n").utf8).write(to: f.repo.root.appendingPathComponent(name)) }
        try await f.repo.stage(["other"])
        _ = try await f.repo.commitSelected(message: "unborn", paths: ["first"], backend: f.backend)
        let firstTree = try await f.repo.run(["ls-tree", "--name-only", "HEAD"]).text; XCTAssertEqual(firstTree, "first\n")
        _ = try await f.repo.commitIndex(message: "other")
        try Data("replacement\n".utf8).write(to: f.repo.root.appendingPathComponent("first"))
        var amend = CommitOptions(); amend.amend = true; amend.amendDiffToLastCommit = false; amend.checkboxIndexPolicy = .init(paths: ["first", "other"], readdUnchecked: false)
        _ = try await f.repo.commitSelected(message: "parent amend", paths: ["first"], options: amend, backend: f.backend)
        let amendedTree = try await f.repo.run(["ls-tree", "--name-only", "HEAD"]).text; XCTAssertEqual(amendedTree, "first\n")
        let beforeTree = try await f.repo.run(["rev-parse", "HEAD^{tree}"]).stdout
        amend.messageOnly = true; amend.amendDiffToLastCommit = true; amend.checkboxIndexPolicy = nil
        _ = try await f.repo.commitSelected(message: "message only", paths: [], options: amend, backend: f.backend)
        let afterTree = try await f.repo.run(["rev-parse", "HEAD^{tree}"]).stdout; XCTAssertEqual(beforeTree, afterTree)
        _ = try await f.repo.run(["checkout", "-b", "side"])
        try Data("side".utf8).write(to: f.repo.root.appendingPathComponent("side")); try await f.repo.stage(["side"]); _ = try await f.repo.commit(message: "side")
        _ = try await f.repo.run(["checkout", "main"])
        try Data("main".utf8).write(to: f.repo.root.appendingPathComponent("main")); try await f.repo.stage(["main"]); _ = try await f.repo.commit(message: "main")
        _ = try await f.repo.run(["merge", "--no-commit", "--no-ff", "side"])
        _ = try await f.repo.commitSelected(message: "merge", paths: ["side"], backend: f.backend)
        let parents = try await f.repo.run(["show", "-s", "--format=%P", "HEAD"]).text.split(separator: " ")
        XCTAssertEqual(parents.count, 2); let pending = try await f.repo.commitOperation(); XCTAssertNil(pending)
    }

    @MainActor func testActualPreparationCancellationDrainsFilterAndRetainsRealIndexCheckboxRows() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let script = f.root.appendingPathComponent("held-clean"), ready = f.root.appendingPathComponent("ready.json")
        try executable(script, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, time
        child=subprocess.Popen(['/bin/sleep','30']); root=pathlib.Path(__file__).parent
        (root/'ready.tmp').write_text(json.dumps({'pid':os.getpid(),'child':child.pid})); (root/'ready.tmp').replace(root/'ready.json')
        while True: time.sleep(.02)
        """)
        try Data("*.clean filter=fixture -text\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try Data("held".utf8).write(to: f.repo.root.appendingPathComponent("held.clean"))
        try Data("unchecked staged".utf8).write(to: f.repo.root.appendingPathComponent("other")); try await f.repo.stage(["other"])
        _ = try await f.repo.run(["config", "filter.fixture.clean", quote(script.path)]); _ = try await f.repo.run(["config", "filter.fixture.required", "true"])
        let original = try Data(contentsOf: f.index), originalHead = try await head(f.repo), token = OperationCancellation()
        var options = CommitOptions(); options.checkboxIndexPolicy = .init(paths: ["held.clean", "other"])
        let task = Task { try await f.repo.commitSelected(message: "cancel", paths: ["held.clean"], options: options, cancellation: token, backend: f.backend) }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: ready.path) else { token.cancel(); _ = try? await task.value; XCTFail("Filter did not reach owned boundary"); return }
        let pids = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancellation committed") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        for name in ["pid", "child"] { let pid = pid_t(try XCTUnwrap(pids[name])); XCTAssertEqual(kill(pid, 0), -1, "Owned filter descendant survived actual drain") }
        XCTAssertEqual(try Data(contentsOf: f.index), original); let after = try await head(f.repo); XCTAssertEqual(after, originalHead)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent("held.clean")), Data("held".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.index.path + ".lock"))
    }
}
