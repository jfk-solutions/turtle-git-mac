// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
import CryptoKit
@testable import TurtleGitCore

private final class AddedPathReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ path: String) { lock.lock(); storage.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return storage }

}

final class LibGit2AddTests: XCTestCase {
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func executable(_ url: URL, _ script: String) throws {
        try Data(script.utf8).write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private struct Fixture {
        let root: URL, repo: GitRepository, helper: URL
        var backend: GitLibGit2Configuration { .init(helperURL: helper) }
        var index: URL { repo.root.appendingPathComponent(".git/index") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libgit2-add ' 雪-" + UUID().uuidString), folder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let helper = try XCTUnwrap(GitLibGit2Configuration().executor(for: .add)), wrapper = root.appendingPathComponent("git"), selected = root.appendingPathComponent("selected-helper")
        let global = root.appendingPathComponent("global.config"); try Data().write(to: global)
        let runtime = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let environment = "unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(global.path) + " HOME=" + quote(root.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n" + runtime + "\n"
        try executable(wrapper, "#!/bin/sh\n" + environment + "exec " + quote(git.path) + " \"$@\"\n")
        try executable(selected, "#!/bin/sh\n" + environment + "printf '%s\\0' \"$@\" > \"$0.argv\"\nexec " + quote(helper.path) + " \"$@\"\n")
        let repo = GitRepository(root: folder, executable: wrapper, askpass: nil, libgit2Configuration: .init(helperURL: selected))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Add fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false"), ("core.symlinks", "true")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: folder.appendingPathComponent("base")); try await repo.stage(["base"]); _ = try await repo.commit(message: "base")
        return .init(root: root, repo: repo, helper: selected)
    }
    private func blob(_ repo: GitRepository, _ path: String) async throws -> Data { try await repo.run(["-c", "core.precomposeunicode=false", "show", ":" + path]).stdout }
    private func head(_ repo: GitRepository) async throws -> Data { try await repo.run(["rev-parse", "HEAD"]).stdout }

    func testSelectedDefaultAddModesIgnoredLiteralSymlinkDirectoryAndGitlinkKeepWorkingBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertTrue(f.backend.requests(.add)); XCTAssertEqual(GitLibGit2Operation.add.mask, 0x400)
        try Data("*.ignored\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitignore"))
        let initialHead = try await head(f.repo), originalBase = try await blob(f.repo, "base")
        let receipts = AddedPathReceipts()
        for (offset, mode) in WorkingFileAddMode.allCases.enumerated() {
            let path = ":(glob) % ' 雪\n\(offset).ignored", bytes = Data([0, 255, 10, UInt8(offset)])
            let file = f.repo.root.appendingPathComponent(path); try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try await f.repo.addReviewedPaths([path], mode: mode, onAdded: receipts.add, backend: f.backend)
            let record = try await f.repo.run(["-c", "core.precomposeunicode=false", "ls-files", "--stage", "-z", "--", path]).stdout
            XCTAssertTrue(String(decoding: record, as: UTF8.self).hasPrefix((mode.indexMode ?? "100644") + " "))
            let stored = try await blob(f.repo, path); XCTAssertEqual(stored, bytes)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o644)
        }
        XCTAssertEqual(receipts.paths.count, 3)
        for path in ["z-context", "a-context", "m-context"] { try Data(path.utf8).write(to: f.repo.root.appendingPathComponent(path)) }
        let contextReceipts = AddedPathReceipts()
        _ = try await f.repo.addReviewedPaths(["z-context", "a-context", "z-context", "m-context"], onAdded: contextReceipts.add, backend: f.backend, preservePathOrder: true)
        XCTAssertEqual(contextReceipts.paths, ["z-context", "a-context", "m-context"])
        let selectorReceipts = AddedPathReceipts()
        _ = try await f.repo.addReviewedPaths(["z-context", "m-context", "a-context"], onAdded: selectorReceipts.add, backend: f.backend)
        XCTAssertEqual(selectorReceipts.paths, ["a-context", "m-context", "z-context"])
        let directory = f.repo.root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: directory.appendingPathComponent("child.ignored"))
        try await f.repo.addWorkingFiles(paths: ["folder"], mode: .executable, backend: f.backend)
        let child = try await f.repo.run(["ls-files", "--stage", "-z", "--", "folder/child.ignored"]).stdout
        XCTAssertTrue(String(decoding: child, as: UTF8.self).hasPrefix("100644 "))
        let link = f.repo.root.appendingPathComponent("actual-link")
        XCTAssertEqual(link.path.withCString { symlink("../../outside-unread", $0) }, 0)
        try await f.repo.addWorkingFiles(paths: ["actual-link"], backend: f.backend)
        let linkBlob = try await blob(f.repo, "actual-link"); XCTAssertEqual(linkBlob, Data("../../outside-unread".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../../outside-unread")
        let nested = f.repo.root.appendingPathComponent("module")
        _ = try await f.repo.run(["clone", "--no-hardlinks", "--", f.repo.root.path, nested.path])
        try await f.repo.addWorkingFiles(paths: ["module"], mode: .symlink, backend: f.backend)
        let gitlink = try await f.repo.run(["ls-files", "--stage", "-z", "--", "module"]).stdout
        XCTAssertTrue(String(decoding: gitlink, as: UTF8.self).hasPrefix("160000 "))
        let finalHead = try await head(f.repo), finalBase = try await blob(f.repo, "base")
        XCTAssertEqual(finalHead, initialHead); XCTAssertEqual(finalBase, originalBase)
    }

    func testCleanFiltersBuiltinNormalizationBinaryLargeStreamsAndPrivateIndexEnvironment() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let script = f.root.appendingPathComponent("clean ' filter"), path = "literal % ':雪.clean", large = Data(repeating: 0x41, count: 262_144) + Data([0, 255, 10])
        try executable(script, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, sys
        root = pathlib.Path(__file__).parent
        base = subprocess.check_output(['/usr/bin/git','show',':base'])
        (root / 'clean.json').write_text(json.dumps({'cwd':os.getcwd(),'args':sys.argv[1:],'index':os.environ.get('GIT_INDEX_FILE'),'base':base.decode()}))
        sys.stderr.buffer.write(b'diagnostic' * 16384); sys.stderr.buffer.flush()
        sys.stdout.buffer.write(b'CLEAN[' + sys.stdin.buffer.read() + b']')
        """)
        try Data("*.clean filter=fixture -text\n*.text text eol=lf\n*.ident ident text eol=lf\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try await f.repo.stage([".gitattributes"]); _ = try await f.repo.commit(message: "filter rules")
        for (key, value) in [("filter.fixture.clean", quote(script.path) + " %f '%%'"), ("filter.fixture.required", "true"), ("filter.fixture.process", "exit 71")] { _ = try await f.repo.run(["config", "--global", key, value]) }
        try large.write(to: f.repo.root.appendingPathComponent(path))
        try Data("one\r\ntwo\r\n".utf8).write(to: f.repo.root.appendingPathComponent("line.text"))
        try Data(("$Id: " + String(repeating: "1", count: 40) + " $\r\n").utf8).write(to: f.repo.root.appendingPathComponent("id.ident"))
        let config = try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), global = try Data(contentsOf: f.root.appendingPathComponent("global.config")), initialHead = try await head(f.repo)
        _ = try await f.repo.run(["config", "core.sharedRepository", "group"])
        _ = try await f.repo.run(["update-index", "--split-index"])
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: f.index.path)
        let sharedConfig = try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config"))
        try await f.repo.addWorkingFiles(paths: [path, "line.text", "id.ident"], backend: f.backend)
        let cleaned = try await blob(f.repo, path), line = try await blob(f.repo, "line.text"), ident = try await blob(f.repo, "id.ident")
        XCTAssertEqual(cleaned, Data("CLEAN[".utf8) + large + Data("]".utf8)); XCTAssertEqual(line, Data("one\ntwo\n".utf8)); XCTAssertEqual(ident, Data("$Id$\n".utf8))
        let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appendingPathComponent("clean.json"))) as? [String: Any])
        XCTAssertEqual(details["args"] as? [String], [path, "%"]); XCTAssertEqual(details["base"] as? String, "base\n")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(details["cwd"] as? String)).resolvingSymlinksInPath(), f.repo.root.resolvingSymlinksInPath())
        XCTAssertNotEqual(details["index"] as? String, f.index.path)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(path)), large)
        XCTAssertNotEqual(sharedConfig, config)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), sharedConfig); XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.index.path)[.posixPermissions] as? NSNumber)?.intValue, 0o660)
        let afterHead = try await head(f.repo); XCTAssertEqual(afterHead, initialHead)
        // Force Git to run the configured process filter instead of accepting
        // libgit2's unchanged stat-cache entry for the already-added work file.
        let changedWorking = large + Data("changed for CLI process filter".utf8)
        try changedWorking.write(to: f.repo.root.appendingPathComponent(path))
        let beforeCLI = try Data(contentsOf: f.index)
        do { try await f.repo.addWorkingFiles(paths: [path], backend: .init(enabled: false)); XCTFail("CLI ignored its configured process filter") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: f.index), beforeCLI)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(path)), changedWorking)
    }
    func testBackendSnapshotFailureAtomicityOptionalFiltersAndModePostactionsNeverRereadWorkingBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let suite = "TurtleGit.AddBackend." + UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let captured = GitLibGit2Configuration.load(from: preferences, helperURL: f.helper)
        preferences.set(false, forKey: "UseLibgit2"); preferences.set(0, forKey: "UseLibgit2_mask")
        try Data("kept staged".utf8).write(to: f.repo.root.appendingPathComponent("postmode"))
        _ = try await f.repo.addReviewedPaths(["postmode"], backend: captured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.helper.path + ".argv"))
        let stored = try await blob(f.repo, "postmode")
        try Data("new disk bytes".utf8).write(to: f.repo.root.appendingPathComponent("postmode"))
        try await f.repo.setAddedFileMode(paths: ["postmode"], mode: .executable, backend: .init(enabled: false, mask: 0, helperURL: f.helper))
        let afterMode = try await blob(f.repo, "postmode"); XCTAssertEqual(afterMode, stored)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent("postmode")), Data("new disk bytes".utf8))
        try FileManager.default.removeItem(at: f.repo.root.appendingPathComponent("postmode"))
        try await f.repo.setAddedFileMode(paths: ["postmode"], mode: .symlink, backend: .init(enabled: false, mask: 0, helperURL: f.helper))
        let afterDeletion = try await blob(f.repo, "postmode"); XCTAssertEqual(afterDeletion, stored)
        let mode = try await f.repo.run(["ls-files", "--stage", "-z", "--", "postmode"]).stdout
        XCTAssertTrue(String(decoding: mode, as: UTF8.self).hasPrefix("120000 "))
        try Data("*.clean filter=fixture -text\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try Data("optional raw".utf8).write(to: f.repo.root.appendingPathComponent("optional.clean"))
        _ = try await f.repo.run(["config", "filter.fixture.clean", "exit 31"])
        _ = try await f.repo.run(["config", "filter.fixture.required", "false"])
        try await f.repo.addWorkingFiles(paths: ["optional.clean"], backend: captured)
        let optional = try await blob(f.repo, "optional.clean"); XCTAssertEqual(optional, Data("optional raw".utf8))
        _ = try await f.repo.run(["config", "--unset", "filter.fixture.clean"])
        try await f.repo.addWorkingFiles(paths: ["optional.clean"], backend: captured)
        let missingOptional = try await blob(f.repo, "optional.clean"); XCTAssertEqual(missingOptional, optional)
        _ = try await f.repo.run(["config", "filter.fixture.clean", "exit 31"])
        _ = try await f.repo.run(["config", "filter.fixture.required", "true"])
        let before = try Data(contentsOf: f.index), initialHead = try await head(f.repo)
        let deletedTracked = f.repo.root.appendingPathComponent("base")
        try FileManager.default.removeItem(at: deletedTracked)
        do { _ = try await f.repo.addReviewedPaths(["base"], backend: captured); XCTFail("Selected add_bypath silently staged a tracked deletion") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: f.index), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedTracked.path))
        let retainedDeletedBlob = try await blob(f.repo, "base")
        XCTAssertEqual(retainedDeletedBlob, Data("base\n".utf8))
        for missingCommand in [false, true] {
            if missingCommand { _ = try await f.repo.run(["config", "--unset", "filter.fixture.clean"]) }
            do { try await f.repo.addWorkingFiles(paths: ["optional.clean"], backend: captured); XCTFail("Required clean failure published an index") } catch is GitFailure {}
            XCTAssertEqual(try Data(contentsOf: f.index), before)
        }
        try Data("new".utf8).write(to: f.repo.root.appendingPathComponent("new"))
        for invalid in [["new", "absent"], ["../escape"], [".git/index"]] {
            do { try await f.repo.addWorkingFiles(paths: invalid, backend: captured); XCTFail("Invalid batch published") } catch {}
            XCTAssertEqual(try Data(contentsOf: f.index), before)
        }
        let missing = GitLibGit2Configuration(helperURL: f.root.appendingPathComponent("missing-helper"))
        do { try await f.repo.addWorkingFiles(paths: ["new"], backend: missing); XCTFail("Requested engine silently fell back") } catch GitLibGit2Failure.runtimeMissing {}
        XCTAssertEqual(try Data(contentsOf: f.index), before)
        try FileManager.default.removeItem(atPath: f.helper.path + ".argv")
        // The required/missing driver above intentionally poisons refreshes of
        // optional.clean. Restore that private fixture's optional policy before
        // independently checking that master-disabled Add selects actual Git.
        _ = try await f.repo.run(["config", "filter.fixture.required", "false"])
        try await f.repo.addWorkingFiles(paths: ["new"], backend: .init(enabled: false, helperURL: missing.helperURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.helper.path + ".argv"))
        let finalHead = try await head(f.repo); XCTAssertEqual(finalHead, initialHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.index.path + ".lock"))
    }

    func testSelectedAddPreservesByteDistinctUnicodeIndexPeersAndUnrelatedFlags() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let nfc = "caf\u{e9}.txt", nfd = "cafe\u{301}.txt"
        XCTAssertEqual(nfc, nfd); XCTAssertNotEqual(Data(nfc.utf8), Data(nfd.utf8))
        let original = try await f.repo.run(["hash-object", "-w", "--stdin"], input: Data("peer original\n".utf8)).text.trimmingCharacters(in: .newlines)
        for path in [nfc, nfd] { _ = try await f.repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "100644," + original + "," + path]) }
        _ = try await f.repo.run(["update-index", "--assume-unchanged", "--", "base"])
        let flags = try await f.repo.run(["ls-files", "-v", "-z", "--", "base"]).stdout
        try Data("new NFC target\n".utf8).write(to: f.repo.root.appendingPathComponent(nfc))
        _ = try await f.repo.run(["config", "core.precomposeunicode", "true"])
        try await f.repo.addWorkingFiles(paths: [nfc], backend: f.backend)
        let changed = try await blob(f.repo, nfc), peer = try await blob(f.repo, nfd)
        XCTAssertEqual(changed, Data("new NFC target\n".utf8)); XCTAssertEqual(peer, Data("peer original\n".utf8))
        let names = try await f.repo.run(["-c", "core.precomposeunicode=false", "ls-files", "-z"]).stdout.split(separator: UInt8(0)).map { (bytes: Data.SubSequence) in Data(bytes) }
        XCTAssertTrue(names.contains(Data(nfc.utf8))); XCTAssertTrue(names.contains(Data(nfd.utf8)))
        let afterFlags = try await f.repo.run(["ls-files", "-v", "-z", "--", "base"]).stdout; XCTAssertEqual(afterFlags, flags)
        let folder = f.repo.root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let indexed = "directory/caf\u{e9}.txt", physical = "directory/cafe\u{301}.txt"
        _ = try await f.repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "100644," + original + "," + indexed])
        try Data("folder update\n".utf8).write(to: f.repo.root.appendingPathComponent(physical))
        try await f.repo.addWorkingFiles(paths: ["directory"], backend: f.backend)
        let directoryNames = try await f.repo.run(["-c", "core.precomposeunicode=false", "ls-files", "-z", "--", "directory"]).stdout.split(separator: UInt8(0)).map { (bytes: Data.SubSequence) in Data(bytes) }
        XCTAssertEqual(directoryNames, [Data(indexed.utf8)], "Directory enumeration retargeted the existing Git spelling")
        let directoryBlob = try await blob(f.repo, indexed); XCTAssertEqual(directoryBlob, Data("folder update\n".utf8))
        _ = try await f.repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "100644," + original + "," + physical])
        try Data("both selected folder peers\n".utf8).write(to: f.repo.root.appendingPathComponent(physical))
        try await f.repo.addWorkingFiles(paths: ["directory"], backend: f.backend)
        let both = try await f.repo.run(["-c", "core.precomposeunicode=false", "ls-files", "-z", "--", "directory"]).stdout.split(separator: UInt8(0)).map { (bytes: Data.SubSequence) in Data(bytes) }
        XCTAssertEqual(Set(both), Set([Data(indexed.utf8), Data(physical.utf8)]))
        for name in [indexed, physical] { let data = try await blob(f.repo, name); XCTAssertEqual(data, Data("both selected folder peers\n".utf8)) }
    }

    func testActualBundledGitLFSCleanWritesPointerAndLocalObjectWithoutChangingWorkingBytes() async throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let candidates = [git.deletingLastPathComponent().appendingPathComponent("git-lfs"), sourceRoot.appendingPathComponent("build/git-runtime/Git/bin/git-lfs")]
        guard let lfs = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("The actual bundled Git LFS binary is not prepared.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = Data([0, 255, 10, 0]) + Data(repeating: 0x41, count: 131_072), path = "actual-lfs.bin"
        let oid = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Data("*.bin filter=lfs -text\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try bytes.write(to: f.repo.root.appendingPathComponent(path))
        // Git LFS 3.8.0 commands.go verifyRepositoryVersion initializes this
        // local key on first use. Initialize the owned fixture before capturing
        // the config whose exact preservation the Add operation must retain.
        for (key, value) in [("filter.lfs.clean", quote(lfs.path) + " clean -- %f"), ("filter.lfs.required", "true"), ("filter.lfs.process", "exit 87"), ("lfs.url", "http://127.0.0.1:1/network-disabled"), ("lfs.repositoryformatversion", "0")] { _ = try await f.repo.run(["config", key, value]) }
        let config = try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), initialHead = try await head(f.repo)
        try await f.repo.addWorkingFiles(paths: [path], backend: f.backend)
        let pointer = try await blob(f.repo, path)
        XCTAssertEqual(pointer, Data(("version https://git-lfs.github.com/spec/v1\noid sha256:" + oid + "\nsize " + String(bytes.count) + "\n").utf8))
        let cached = f.repo.root.appendingPathComponent(".git/lfs/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2).prefix(2) + "/" + oid)
        XCTAssertEqual(try Data(contentsOf: cached), bytes)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), config)
        let afterHead = try await head(f.repo); XCTAssertEqual(afterHead, initialHead)
    }

    @MainActor func testActualCleanCancellationDrainsFilterDescendantAndNeverPublishesPrivateIndex() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ready = f.root.appendingPathComponent("clean-ready.json"), script = f.root.appendingPathComponent("held-clean")
        try executable(script, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, time
        root = pathlib.Path(__file__).parent; child = subprocess.Popen(['/bin/sleep','30'])
        temporary = root / 'clean-ready.tmp'
        temporary.write_text(json.dumps({'pid':os.getpid(),'child':child.pid})); temporary.replace(root / 'clean-ready.json')
        while True: time.sleep(.02)
        """)
        try Data("*.clean filter=fixture\n".utf8).write(to: f.repo.root.appendingPathComponent(".gitattributes"))
        try Data("worktree remains".utf8).write(to: f.repo.root.appendingPathComponent("held.clean"))
        _ = try await f.repo.run(["config", "filter.fixture.clean", quote(script.path)])
        _ = try await f.repo.run(["config", "filter.fixture.required", "true"])
        let index = try Data(contentsOf: f.index), initialHead = try await head(f.repo), config = try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), token = OperationCancellation()
        let operation = Task { try await f.repo.addWorkingFiles(paths: ["held.clean"], cancellation: token, backend: f.backend) }
        var pids: [Int32] = []
        do {
            try await wait { FileManager.default.fileExists(atPath: ready.path) }
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any])
            pids = [try XCTUnwrap(state["pid"] as? NSNumber).int32Value, try XCTUnwrap(state["child"] as? NSNumber).int32Value]
            token.cancel()
        } catch { token.cancel(); _ = await operation.result; throw error }
        do { try await operation.value; XCTFail("Cancelled clean published") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
        XCTAssertEqual(try Data(contentsOf: f.index), index)
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent("held.clean")), Data("worktree remains".utf8))
        XCTAssertEqual(try Data(contentsOf: f.repo.root.appendingPathComponent(".git/config")), config)
        let afterHead = try await head(f.repo); XCTAssertEqual(afterHead, initialHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.index.path + ".lock"))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Owned clean filter did not reach its boundary"); throw GitLibGit2Failure.runtimeMissing
    }
}
