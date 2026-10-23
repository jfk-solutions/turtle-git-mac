// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
import CryptoKit
@testable import TurtleGitCore

private final class LibGit2Receipts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GitCommandInvocation] = []
    func add(_ invocation: GitCommandInvocation) { lock.lock(); storage.append(invocation); lock.unlock() }
    var values: [GitCommandInvocation] { lock.lock(); defer { lock.unlock() }; return storage }
}
final class GitLibGit2Tests: XCTestCase {
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private var git: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git") }
    private func helper() throws -> URL { try XCTUnwrap(GitLibGit2Configuration(mask: 6).executor(for: .clone)) }
    private func executable(_ file: URL, _ text: String) throws {
        try Data(text.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    private struct Fixture {
        let root: URL, source: GitRepository, remote: GitRepository, runner: GitRepository, helper: URL
        var backend: GitLibGit2Configuration { .init(mask: 6, helperURL: helper) }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libgit2 ' 雪-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let global = root.appendingPathComponent("global.config"); try Data().write(to: global)
        let runtime = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let environment = "unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_SSL_NO_VERIFY GIT_SSL_CAINFO SSL_CERT_FILE CURL_CA_BUNDLE http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY\nexport NO_PROXY=localhost,127.0.0.1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(global.path) + " HOME=" + quote(root.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n" + runtime + "\n"
        let original = root.appendingPathComponent("original git"), transport = root.appendingPathComponent("selected libgit2")
        try executable(original, "#!/bin/sh\n" + environment + "exec " + quote(git.path) + " \"$@\"\n")
        try executable(transport, "#!/bin/sh\n" + environment + "printf '%s\\0' \"$@\" > \"$0.argv\"\nexec " + quote(try helper().path) + " \"$@\"\n")
        let sourceURL = root.appendingPathComponent("source"), runnerURL = root.appendingPathComponent("runner")
        for folder in [sourceURL, runnerURL] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let source = GitRepository(root: sourceURL, executable: original, askpass: nil), runner = GitRepository(root: runnerURL, executable: original, askpass: nil)
        _ = try await source.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "libgit2 fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await source.run(["config", key, value]) }
        for text in ["base", "tip"] { try Data((text + "\n").utf8).write(to: sourceURL.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: text) }
        _ = try await source.run(["branch", "topic", "HEAD~1"]); _ = try await source.run(["tag", "v1"])
        let bare = root.appendingPathComponent("repo.git")
        _ = try await source.run(["clone", "--bare", "--", sourceURL.path, bare.path])
        return Fixture(root: root, source: source, remote: GitRepository(root: bare, executable: original, askpass: nil), runner: runner, helper: transport)
    }

    func testSourceMaskSnapshotMissingRuntimeAndSVNRemainExplicit() async throws {
        let suite = "TurtleGit.LibGit2." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = GitLibGit2Configuration.load(from: defaults)
        XCTAssertTrue(initial.enabled); XCTAssertEqual(initial.mask, 0x66780)
        XCTAssertFalse(initial.requests(.clone)); XCTAssertFalse(initial.requests(.fetch))
        defaults.set(6, forKey: "UseLibgit2_mask")
        let selected = GitLibGit2Configuration.load(from: defaults)
        defaults.set(false, forKey: "UseLibgit2"); defaults.set(0, forKey: "UseLibgit2_mask")
        XCTAssertTrue(selected.requests(.clone)); XCTAssertTrue(selected.requests(.fetch))
        XCTAssertFalse(GitLibGit2Configuration.load(from: defaults).requests(.clone))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = GitLibGit2Configuration(mask: 6, helperURL: root.appendingPathComponent("missing"))
        do { _ = try missing.executor(for: .clone); XCTFail("Missing requested backend silently fell back") }
        catch GitLibGit2Failure.runtimeMissing {}
        XCTAssertNil(try GitLibGit2Configuration(enabled: false, mask: 6, helperURL: root.appendingPathComponent("missing")).executor(for: .fetch))
        let fakeSVN = root.appendingPathComponent("git"), events = LibGit2Receipts()
        try executable(fakeSVN, "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$0.argv\"\nexit 0\n")
        let repo = GitRepository(root: root, executable: fakeSVN, askpass: nil)
        var options = CloneOptions(); options.svn = true; options.source = "https://example.invalid/svn"
        _ = try await repo.clone(options, to: root.appendingPathComponent("svn"), onCommand: events.add, backend: missing)
        XCTAssertEqual(events.values.first?.executable, fakeSVN)
        XCTAssertEqual(events.values.first.map { Array($0.arguments.dropFirst(3).prefix(2)) }, ["svn", "clone"])
        options.svn = false
        let refused = root.appendingPathComponent("refused")
        do { _ = try await repo.clone(options, to: refused, backend: missing); XCTFail("Clone ignored its missing selected executor") }
        catch GitLibGit2Failure.runtimeMissing {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    }

    func testActualCloneOptionsUseSelectedExecutorAndLeaveSourceUnchanged() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.source.run(["rev-parse", "HEAD"]).stdout, sourceConfig = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        var options = CloneOptions(); options.source = f.remote.root.path; options.branch = "topic"; options.origin = "upstream"; options.noCheckout = true
        let destination = f.root.appendingPathComponent("topic no checkout"), events = LibGit2Receipts()
        _ = try await f.runner.clone(options, to: destination, onCommand: events.add, backend: f.backend)
        XCTAssertEqual(events.values.count, 1); XCTAssertEqual(events.values.first?.executable, f.helper)
        let expected = ["--no-literal-pathspecs", "-C", f.runner.root.path] + (try options.arguments(destination: destination))
        let actual = try Data(contentsOf: URL(fileURLWithPath: f.helper.path + ".argv")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(actual, expected); XCTAssertEqual(events.values.first?.arguments, expected)
        let cloned = GitRepository(root: destination, executable: f.runner.executable, askpass: nil)
        let target = try await cloned.run(["rev-parse", "HEAD"]).stdout, topic = try await f.remote.run(["rev-parse", "refs/heads/topic"]).stdout
        XCTAssertEqual(target, topic); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path))
        let remote = try await cloned.run(["config", "branch.topic.remote"]).text
        XCTAssertEqual(remote, "upstream\n")
        options = CloneOptions(); options.source = f.remote.root.path; options.bare = true
        let bare = f.root.appendingPathComponent("bare.git")
        _ = try await f.runner.clone(options, to: bare, backend: f.backend)
        let bareRepo = GitRepository(root: bare, executable: f.runner.executable, askpass: nil)
        let isBare = try await bareRepo.isBare(), after = try await f.source.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(isBare); XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), sourceConfig)
    }

    func testActualFetchNamedAllRemotesTagsPruneAndRebaseKeepWorkingBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var clone = CloneOptions(); clone.source = f.remote.root.path
        let destination = f.root.appendingPathComponent("client")
        _ = try await f.runner.clone(clone, to: destination, backend: f.backend)
        let client = GitRepository(root: destination, executable: f.runner.executable, askpass: nil, libgit2Configuration: f.backend)
        _ = try await client.run(["remote", "add", "mirror", f.remote.root.path])
        let head = try await client.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: destination.appendingPathComponent(".git/index")), working = try Data(contentsOf: destination.appendingPathComponent("file"))
        _ = try await f.remote.run(["update-ref", "refs/tags/new-tag", "HEAD"])
        _ = try await f.remote.run(["update-ref", "-d", "refs/heads/topic"])
        var options = FetchOptions(); options.remote = "origin"; options.tags = .disabled; options.prune = .disabled
        let events = LibGit2Receipts()
        _ = try await client.fetch(options, onCommand: events.add)
        let absent = try await client.run(["rev-parse", "--verify", "refs/tags/new-tag"], successfulExitCodes: 0...128)
        XCTAssertNotEqual(absent.exitCode, 0)
        let retained = try await client.run(["rev-parse", "--verify", "refs/remotes/origin/topic"])
        XCTAssertEqual(retained.exitCode, 0)
        options.allRemotes = true; options.tags = .enabled; options.prune = .enabled
        _ = try await client.fetch(options, onCommand: events.add)
        let tag = try await client.run(["rev-parse", "--verify", "refs/tags/new-tag"]), mirror = try await client.run(["rev-parse", "--verify", "refs/remotes/mirror/main"])
        XCTAssertEqual(tag.exitCode, 0); XCTAssertEqual(mirror.exitCode, 0)
        let removed = try await client.run(["rev-parse", "--verify", "refs/remotes/origin/topic"], successfulExitCodes: 0...128)
        XCTAssertNotEqual(removed.exitCode, 0)
        options.allRemotes = false; options.branch = "main"
        let rebase = try await client.fetchForRebase(options)
        XCTAssertEqual(rebase.upstream, String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines))
        options.arbitraryURL = true; options.remote = f.remote.root.absoluteString
        let namedConfig = try Data(contentsOf: destination.appendingPathComponent(".git/config"))
        do { _ = try await client.fetchForRebase(options); XCTFail("Anonymous source Fetch accepted a nonempty refspec without named configuration authority") }
        catch let error as GitFailure { XCTAssertNotEqual(error.code, 0) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".git/config")), namedConfig)
        // CLI keeps the existing anonymous URL + selected branch success path.
        let direct = try await client.fetchForRebase(options, backend: .init(enabled: false))
        XCTAssertEqual(direct.upstream, rebase.upstream)
        XCTAssertTrue(events.values.allSatisfy { $0.executable == f.helper && $0.arguments.first == "--literal-pathspecs" })
        let finalHead = try await client.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), working)
    }

    func testActualRecursiveClonePopulatesPinnedSubmoduleWithoutSourceMutation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.source.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", f.remote.root.path, "vendor/sub"])
        _ = try await f.source.commit(message: "add submodule")
        _ = try await f.source.run(["push", f.remote.root.path, "main"])
        let before = try await f.source.run(["rev-parse", "HEAD"]).stdout
        var options = CloneOptions(); options.source = f.remote.root.path; options.recursive = true
        let destination = f.root.appendingPathComponent("recursive")
        _ = try await f.runner.clone(options, to: destination, backend: f.backend)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("vendor/sub/file")), Data("tip\n".utf8))
        let cloned = GitRepository(root: destination, executable: f.runner.executable, askpass: nil)
        let status = try await cloned.run(["status", "--porcelain"]), after = try await f.source.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(status.stdout.isEmpty); XCTAssertEqual(after, before)
    }

    func testActualRemoteListingsPreservePeeledTagsNamespacesAndBackendSpecificHead() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backend = GitLibGit2Configuration(mask: 0x804, helperURL: f.helper)
        XCTAssertEqual(GitLibGit2Operation.push.mask, 0x800)
        XCTAssertFalse(GitLibGit2Configuration().requests(.push))
        _ = try await f.source.run(["tag", "-a", "annotated-雪", "-m", "annotated target"])
        _ = try await f.source.run(["push", f.remote.root.path, "refs/tags/annotated-雪"])
        _ = try await f.remote.run(["update-ref", "refs/changes/private", "HEAD"])
        _ = try await f.source.run(["remote", "add", "upstream", f.remote.root.path])
        let head = try await f.source.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        let remoteRefs = try await f.remote.run(["show-ref"]).stdout
        for remote in ["upstream", f.remote.root.path] {
            let rows = try await f.source.remoteTags(remote: remote, includingPeeled: true, backend: backend)
            XCTAssertTrue(rows.contains { $0.name == GitReferenceName("annotated-雪") })
            let peeled = try XCTUnwrap(rows.first { $0.name == GitReferenceName("annotated-雪^{}") })
            XCTAssertEqual(Data((peeled.hash + "\n").utf8), head)
            let simple = try await f.source.remoteTags(remote: remote, backend: backend)
            XCTAssertFalse(simple.contains { $0.name.rawValue.hasSuffix("^{}") })
            let choices = try await f.source.remoteReferenceChoices(remote: remote, backend: backend)
            XCTAssertTrue(choices.contains("HEAD")); XCTAssertTrue(choices.contains("main")); XCTAssertTrue(choices.contains("topic"))
            XCTAssertTrue(choices.contains("refs/changes/private")); XCTAssertFalse(choices.contains { $0.contains("annotated-雪") })
            let cli = try await f.source.remoteReferenceChoices(remote: remote, backend: .init(enabled: false))
            XCTAssertEqual(Set(choices.filter { $0 != "HEAD" }), Set(cli)); XCTAssertFalse(cli.contains("HEAD"))
        }
        let plain = try await f.runner.remoteReferenceChoices(remote: f.remote.root.path, backend: backend)
        XCTAssertTrue(plain.contains("HEAD")); XCTAssertFalse(FileManager.default.fileExists(atPath: f.runner.root.appendingPathComponent(".git").path))
        let afterHead = try await f.source.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await f.remote.run(["show-ref"]).stdout
        XCTAssertEqual(afterHead, head); XCTAssertEqual(afterRefs, remoteRefs)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), config)
        do { _ = try RemoteReferenceChoices.parse(Data((String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines) + "\tHEAD\n").utf8)); XCTFail("CLI parser accepted pseudoref") }
        catch RemoteReferenceChoicesFailure.output {}
    }

    func testActualRemoteDeletionGroupsStaleGuardsAndPartialServerFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backend = GitLibGit2Configuration(mask: 0x804, helperURL: f.helper)
        _ = try await f.source.run(["remote", "add", "a", f.remote.root.path])
        _ = try await f.source.run(["fetch", "a"])
        let reference = GitReferenceName("refs/remotes/a/topic")
        let expected = try await f.source.run(["rev-parse", reference.rawValue]).text.trimmingCharacters(in: .newlines)
        let head = try await f.source.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), working = try Data(contentsOf: f.source.root.appendingPathComponent("file"))
        do { try await f.source.deleteBrowserReferences([reference], expectedHashes: [reference: String(repeating: "0", count: 40)], backend: backend); XCTFail("Stale ref was deleted") } catch ReferenceBrowserRenameFailure.changed {}
        try await f.source.deleteBrowserReferences([reference], expectedHashes: [reference: expected], backend: backend)
        let removed = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/heads/topic"], successfulExitCodes: 0...1)
        XCTAssertEqual(removed.exitCode, 1)
        // Source calls git_remote_push: its successful update-tips phase removes
        // the matching tracking ref, while local branches/tags remain intact.
        let tracking = try await f.source.run(["show-ref", "--verify", "--quiet", reference.rawValue], successfulExitCodes: 0...1)
        XCTAssertEqual(tracking.exitCode, 1)
        let localTopic = try await f.source.run(["rev-parse", "refs/heads/topic"]).text.trimmingCharacters(in: .newlines)
        let localTag = try await f.source.run(["show-ref", "--verify", "--quiet", "refs/tags/v1"], successfulExitCodes: 0...1)
        XCTAssertEqual(localTopic, expected); XCTAssertEqual(localTag.exitCode, 0)
        _ = try await f.remote.run(["update-ref", "refs/heads/accepted", "HEAD"])
        _ = try await f.source.run(["fetch", "a"])
        _ = try await f.source.run(["remote", "add", "b", f.root.appendingPathComponent("missing.git").path])
        _ = try await f.source.run(["update-ref", "refs/remotes/b/rejected", "HEAD"])
        do { try await f.source.deleteBrowserReferences([.init("refs/remotes/a/accepted"), .init("refs/remotes/b/rejected")], backend: backend); XCTFail("Failed later remote reported success") } catch is GitFailure {}
        let accepted = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/heads/accepted"], successfulExitCodes: 0...1)
        XCTAssertEqual(accepted.exitCode, 1, "Earlier source-ordered remote deletion was rolled back")
        _ = try await f.source.run(["tag", "local-only"])
        _ = try await f.remote.run(["update-ref", "refs/tags/remote-only", "HEAD"])
        let tags = try await f.source.synchronizationTags(remote: "a", backend: backend)
        let remoteOnly = try XCTUnwrap(tags.rows.first { $0.name == GitReferenceName("remote-only") })
        _ = try await f.source.synchronizeTag(.deleteRemote, row: remoteOnly, snapshot: tags, deletionAuthorized: true, backend: backend)
        let deletedTag = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/tags/remote-only"], successfulExitCodes: 0...1)
        XCTAssertEqual(deletedTag.exitCode, 1)
        let localOnly = try XCTUnwrap(tags.rows.first { $0.name == GitReferenceName("local-only") })
        // The source's ordinary tag Push remains CLI even with push enabled and
        // an unavailable helper; only remote deletion selects that backend.
        _ = try await f.source.synchronizeTag(.push, row: localOnly, snapshot: tags, backend: .init(mask: 0x800, helperURL: f.root.appendingPathComponent("missing-helper")))
        let pushedTag = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/tags/local-only"], successfulExitCodes: 0...1)
        XCTAssertEqual(pushedTag.exitCode, 0)
        let finalHead = try await f.source.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head); XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent("file")), working)
    }

    private func materializationFixture(_ f: Fixture) async throws -> (String, [String: Data]) {
        _ = try await f.source.run(["config", "core.precomposeunicode", "false"])
        let filter = f.root.appendingPathComponent("smudge ' 雪")
        try executable(filter, "#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write(b'SMUDGE[' + sys.stdin.buffer.read() + b']')\n")
        _ = try await f.source.run(["config", "filter.fixture.smudge", quote(filter.path)])
        _ = try await f.source.run(["config", "filter.fixture.clean", "cat"])
        _ = try await f.source.run(["config", "filter.fixture.required", "true"])
        let files = ["line.txt": Data("line one\nline two\n".utf8), "colon:雪.filtered": Data("stored\n".utf8), "cafe\u{301}.filtered": Data("decomposed\n".utf8), "binary.filtered": Data([0, 255, 10, 1])]
        try Data("*.txt text eol=crlf\n*.filtered filter=fixture\n".utf8).write(to: f.source.root.appendingPathComponent(".gitattributes"))
        for (path, bytes) in files { try bytes.write(to: f.source.root.appendingPathComponent(path)) }
        let link = f.source.root.appendingPathComponent("link.filtered")
        let result = link.path.withCString { symlink("../../outside-target", $0) }; XCTAssertEqual(result, 0)
        try await f.source.stage([".gitattributes"] + Array(files.keys) + ["link.filtered"])
        _ = try await f.source.commit(message: "historical filters")
        let hash = try await f.source.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await f.source.run(["config", "core.precomposeunicode", "true"])
        return (hash, files)
    }

    func testActualHistoricalMaterializationFiltersBinaryEOLSignedTagAndLiteralLinksButRawReadersStayRaw() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (hash, files) = try await materializationFixture(f)
        let backend = GitLibGit2Configuration(mask: 0x200, helperURL: f.helper), disabled = GitLibGit2Configuration(enabled: false)
        XCTAssertTrue(GitLibGit2Configuration().requests(.getOneFile)); XCTAssertEqual(GitLibGit2Operation.getOneFile.mask, 0x200)
        // Peeling a signature-bearing annotated tag must not try to parse its
        // signature bytes as commit/blob contents. This fixture does not verify signatures.
        let tag = "object " + hash + "\ntype commit\ntag signed-fixture\ntagger Fixture <qa@example.invalid> 1700000000 +0000\n\nfixture\n-----BEGIN PGP SIGNATURE-----\nfixture payload\n-----END PGP SIGNATURE-----\n"
        let object = try await f.source.run(["hash-object", "-t", "tag", "-w", "--stdin"], input: Data(tag.utf8)).text.trimmingCharacters(in: .newlines)
        _ = try await f.source.run(["update-ref", "refs/tags/signed-fixture", object])
        let index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        for (path, raw) in files {
            let source = try await f.source.historicalFile(revision: hash, path: path)
            XCTAssertEqual(source.bytes, raw)
            let content = try await f.source.materializedHistoricalFile(revision: "signed-fixture", path: path, backend: backend)
            let expected = path.hasSuffix(".txt") ? Data("line one\r\nline two\r\n".utf8) : Data("SMUDGE[".utf8) + raw + Data("]".utf8)
            XCTAssertEqual(content.bytes, expected, path); XCTAssertEqual(content.revision, .revision(hash))
            let fallback = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: disabled)
            XCTAssertEqual(fallback.bytes, raw)
        }
        let symlink = try await f.source.materializedHistoricalFile(revision: hash, path: "link.filtered", backend: backend)
        XCTAssertEqual(symlink.mode, "120000"); XCTAssertEqual(symlink.bytes, Data("SMUDGE[../../outside-target]".utf8))
        let listing = try await f.source.browseRepository(revision: hash)
        let entry = try XCTUnwrap(listing.entries.first { $0.path == "binary.filtered" })
        let browserRaw = try await f.source.repositoryBrowserFile(listing, entry: entry)
        let browserOutput = try await f.source.materializedRepositoryBrowserFile(listing, entry: entry, backend: backend)
        let binary = try XCTUnwrap(files[entry.path])
        XCTAssertEqual(browserRaw.bytes, binary); XCTAssertEqual(browserOutput.bytes, Data("SMUDGE[".utf8) + binary + Data("]".utf8))
        let finalHead = try await f.source.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(finalHead, hash); XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), config)
    }

    func testHistoricalExportPlansCaptureBackendAndKeepExistingOutputOnFilterFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (hash, files) = try await materializationFixture(f), path = "binary.filtered"
        let suite = "TurtleGit.Materialization." + UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(0x200, forKey: "UseLibgit2_mask")
        let backend = GitLibGit2Configuration.load(from: preferences, helperURL: f.helper)
        let folder = f.root.appendingPathComponent("export"), second = f.root.appendingPathComponent("comparison")
        for directory in [folder, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let file = CommitFile(path: path, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let historical = try await f.source.prepareHistoricalExport(revision: hash, files: [file], to: folder, backend: backend)
        let comparison = try await f.source.revisionFileComparison(from: .emptyTree, to: .revision(hash), paths: [path])
        let compared = try await f.source.prepareComparisonExport(comparison, files: comparison.files, to: second, backend: backend)
        preferences.set(false, forKey: "UseLibgit2")
        try await f.source.exportHistoricalFile(historical, path: path)
        try await f.source.exportComparisonFile(compared, path: path)
        let stored = try XCTUnwrap(files[path]), expected = Data("SMUDGE[".utf8) + stored + Data("]".utf8)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), expected)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent(path)), expected)
        let browser = try await f.source.browseRepository(revision: hash)
        let entry = try XCTUnwrap(browser.entries.first { $0.path == path })
        let exported = try await f.source.exportRepositoryBrowser(browser, entry: entry, backend: backend)
        defer { try? FileManager.default.removeItem(at: exported.directory) }
        XCTAssertEqual(try Data(contentsOf: exported.item), expected)
        let sentinel = Data("existing output remains".utf8)
        try sentinel.write(to: folder.appendingPathComponent(path)); try sentinel.write(to: second.appendingPathComponent(path))
        _ = try await f.source.run(["config", "filter.fixture.smudge", "exit 37"])
        let index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        do { try await f.source.exportHistoricalFile(historical, path: path); XCTFail("Required filter failure replaced output") } catch is GitFailure {}
        do { try await f.source.exportComparisonFile(compared, path: path); XCTFail("Comparison export ignored required filter failure") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), sentinel)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent(path)), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".TurtleGit") })
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), config)
        _ = try await f.source.run(["config", "--unset", "filter.fixture.smudge"])
        do { _ = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: backend); XCTFail("Required filter without a smudge command succeeded") } catch is GitFailure {}
        let raw = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: .init(enabled: false))
        XCTAssertEqual(raw.bytes, files[path])
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        // Only the fixture's deliberate --unset changes configuration.
        let current = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        _ = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: .init(enabled: false))
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), current)
        XCTAssertNotEqual(current, config)
    }

    func testStandaloneCatPreservesSelectedFilteringAndSourceDisabledShowContract() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (hash, files) = try await materializationFixture(f), path = "colon:雪.filtered"
        let backend = GitLibGit2Configuration(mask: 0x200, helperURL: f.helper), token = OperationCancellation()
        let blob = try await f.source.run(["rev-parse", hash + ":" + path]).text.trimmingCharacters(in: .newlines)
        let raw = try XCTUnwrap(files[path]), expected = Data("SMUDGE[".utf8) + raw + Data("]".utf8)
        for revision in [hash, blob] {
            let output = try await f.source.commandHistoricalFile(revision: revision, path: path, cancellation: token, backend: backend)
            XCTAssertEqual(output, expected)
        }
        let rawBlob = try await f.source.commandHistoricalFile(revision: blob, path: path, cancellation: token, backend: .init(enabled: false))
        XCTAssertEqual(rawBlob, raw)
        let rootBlob = try await f.source.commandHistoricalFile(revision: blob, path: ".", cancellation: token, backend: backend)
        XCTAssertEqual(rootBlob, raw, "Direct blobs without a filename retain the repository-root attribute context")
        let show = try await f.source.run(["-c", "core.precomposeunicode=false", "show", "--end-of-options", hash, "--", path]).stdout
        let disabledCommit = try await f.source.commandHistoricalFile(revision: hash, path: path, cancellation: token, backend: .init(enabled: false))
        XCTAssertEqual(disabledCommit, show); XCTAssertNotEqual(disabledCommit, raw)
        let missing = GitLibGit2Configuration(mask: 0x200, helperURL: f.root.appendingPathComponent("missing-helper"))
        do { _ = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: missing); XCTFail("Requested runtime silently fell back") } catch GitLibGit2Failure.runtimeMissing {}
    }

    func testHistoricalMaterializationLiteralFilterArgumentsLargeStreamsOptionalFailureAndBareAttributes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await materializationFixture(f)
        let path = "percent % ':雪.filtered", raw = Data(repeating: 0x41, count: 524_288) + Data([0, 255, 10])
        try raw.write(to: f.source.root.appendingPathComponent(path)); try await f.source.stage([path]); _ = try await f.source.commit(message: "large literal filter input")
        let hash = try await f.source.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let script = f.root.appendingPathComponent("argument-filter"), argv = f.root.appendingPathComponent("filter-arguments.json")
        try executable(script, """
        #!/usr/bin/python3
        import json, pathlib, sys
        (pathlib.Path(__file__).parent / 'filter-arguments.json').write_text(json.dumps(sys.argv[1:]))
        sys.stderr.buffer.write(b'diagnostic' * 32768); sys.stderr.buffer.flush()
        sys.stdout.buffer.write(b'FILTER[' + sys.stdin.buffer.read() + b']'); sys.stdout.buffer.flush()
        """)
        let command = quote(script.path) + " %f '%%'", backend = GitLibGit2Configuration(mask: 0x200, helperURL: f.helper)
        _ = try await f.source.run(["config", "filter.fixture.smudge", command])
        let content = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: backend)
        let expected = Data("FILTER[".utf8) + raw + Data("]".utf8)
        XCTAssertEqual(content.bytes, expected)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: argv)) as? [String], [path, "%"])
        _ = try await f.source.run(["config", "filter.fixture.required", "false"])
        _ = try await f.source.run(["config", "filter.fixture.smudge", "exit 29"])
        let optional = try await f.source.materializedHistoricalFile(revision: hash, path: path, backend: backend)
        XCTAssertEqual(optional.bytes, raw)
        let bare = f.root.appendingPathComponent("materialization.git")
        _ = try await f.source.run(["clone", "--bare", "--", f.source.root.path, bare.path])
        let repository = GitRepository(root: bare, executable: f.source.executable, askpass: nil)
        _ = try await repository.run(["config", "filter.fixture.smudge", command])
        _ = try await repository.run(["config", "filter.fixture.required", "true"])
        // Source's default libgit2 flags don't request HEAD attributes in bare
        // repositories. An explicit info/attributes rule remains applicable.
        let withoutRule = try await repository.materializedHistoricalFile(revision: hash, path: path, backend: backend)
        XCTAssertEqual(withoutRule.bytes, raw)
        try Data("*.filtered filter=fixture\n".utf8).write(to: bare.appendingPathComponent("info/attributes"))
        let config = try Data(contentsOf: bare.appendingPathComponent("config")), refs = try await repository.run(["show-ref"]).stdout
        let withRule = try await repository.materializedHistoricalFile(revision: hash, path: path, backend: backend)
        XCTAssertEqual(withRule.bytes, expected)
        XCTAssertEqual(try Data(contentsOf: bare.appendingPathComponent("config")), config)
        let finalRefs = try await repository.run(["show-ref"]).stdout; XCTAssertEqual(finalRefs, refs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent("index").path))
    }

    @MainActor func testHistoricalSmudgeCancellationDrainsActualChildAndPreservesExport() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (hash, _) = try await materializationFixture(f), path = "binary.filtered"
        let filter = f.root.appendingPathComponent("held-smudge"), ready = f.root.appendingPathComponent("smudge-ready.json")
        try executable(filter, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, time
        root = pathlib.Path(__file__).parent
        child = subprocess.Popen(['/bin/sleep','30'])
        temporary = root / 'smudge-ready.tmp'
        temporary.write_text(json.dumps({'pid':os.getpid(),'child':child.pid}))
        temporary.replace(root / 'smudge-ready.json')
        while True: time.sleep(.02)
        """)
        _ = try await f.source.run(["config", "filter.fixture.smudge", quote(filter.path)])
        let folder = f.root.appendingPathComponent("cancel-export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sentinel = Data("retain destination".utf8); try sentinel.write(to: folder.appendingPathComponent(path))
        let file = CommitFile(path: path, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let plan = try await f.source.prepareHistoricalExport(revision: hash, files: [file], to: folder, backend: .init(mask: 0x200, helperURL: f.helper))
        let index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), token = OperationCancellation()
        let operation = Task { try await f.source.exportHistoricalFile(plan, path: path, cancellation: token) }
        var pids: [Int32] = []
        do {
            try await wait { FileManager.default.fileExists(atPath: ready.path) }
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any])
            pids = [try XCTUnwrap(state["pid"] as? NSNumber).int32Value, try XCTUnwrap(state["child"] as? NSNumber).int32Value]
            token.cancel()
        } catch { token.cancel(); _ = await operation.result; throw error }
        do { try await operation.value; XCTFail("Cancelled filter published output") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), sentinel)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        let after = try await f.source.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, hash)
    }

    private func cloneFilterFixture(_ f: Fixture, repository: GitRepository? = nil) async throws -> String {
        let repository = repository ?? f.source, script = f.root.appendingPathComponent("clone-smudge"), path = "literal % ':雪.filtered"
        try executable(script, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, sys
        root = pathlib.Path(__file__).parent
        with (root / 'clone-filters.jsonl').open('a') as stream:
            repository = subprocess.check_output(['/usr/bin/git','rev-parse','--show-toplevel'], text=True).rstrip('\\n')
            stream.write(json.dumps({'cwd':os.getcwd(),'repository':repository,'args':sys.argv[1:]}) + '\\n')
        sys.stdout.buffer.write(b'CHECKOUT[' + sys.stdin.buffer.read() + b']')
        """)
        for (key, value) in [("filter.clonefixture.smudge", quote(script.path) + " %f '%%'"), ("filter.clonefixture.clean", "cat"), ("filter.clonefixture.required", "true")] { _ = try await f.source.run(["config", "--global", key, value]) }
        try Data("*.filtered filter=clonefixture\n*.txt text eol=crlf\n".utf8).write(to: repository.root.appendingPathComponent(".gitattributes"))
        try Data("payload\n".utf8).write(to: repository.root.appendingPathComponent(path))
        try Data([0, 255, 10, 1]).write(to: repository.root.appendingPathComponent("binary.filtered"))
        let link = repository.root.appendingPathComponent("link.filtered")
        XCTAssertEqual(link.path.withCString { symlink("../../outside-target", $0) }, 0)
        try Data("one\ntwo\n".utf8).write(to: repository.root.appendingPathComponent("ending.txt"))
        try await repository.stage([".gitattributes", path, "binary.filtered", "link.filtered", "ending.txt"]); _ = try await repository.commit(message: "checkout filter inputs")
        return path
    }

    func testActualCloneCheckoutAppliesBuiltinAndCustomFiltersInEachRecursiveRepository() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try await cloneFilterFixture(f), childFolder = f.root.appendingPathComponent("child-source")
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: false)
        let child = GitRepository(root: childFolder, executable: f.source.executable, askpass: nil)
        _ = try await child.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Child fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await child.run(["config", key, value]) }
        _ = try await cloneFilterFixture(f, repository: child)
        _ = try await f.source.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", childFolder.path, "vendor/child"])
        _ = try await f.source.commit(message: "recursive filtered checkout")
        let head = try await f.source.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), global = try Data(contentsOf: f.root.appendingPathComponent("global.config"))
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("clone-filters.jsonl"))
        var options = CloneOptions(); options.source = f.source.root.path; options.recursive = true
        let contaminated = f.root.appendingPathComponent("inherited-repository-helper")
        let originalScript = try String(contentsOf: f.helper, encoding: .utf8)
        let insertion = try XCTUnwrap(originalScript.range(of: "\nexec ")).lowerBound
        let inherited = "\nexport GIT_DIR=" + quote(f.source.root.appendingPathComponent(".git").path) + " GIT_WORK_TREE=" + quote(f.source.root.path) + " GIT_INDEX_FILE=" + quote(f.source.root.appendingPathComponent(".git/index").path) + "\n"
        try executable(contaminated, String(originalScript[..<insertion]) + inherited + String(originalScript[insertion...]))
        let destination = f.root.appendingPathComponent("recursive filtered"), backend = GitLibGit2Configuration(mask: 2, helperURL: contaminated)
        _ = try await f.runner.clone(options, to: destination, backend: backend)
        for directory in [destination, destination.appendingPathComponent("vendor/child")] {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)), Data("CHECKOUT[payload\n]".utf8))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("binary.filtered")), Data("CHECKOUT[".utf8) + Data([0, 255, 10, 1]) + Data("]".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("link.filtered").path), "../../outside-target")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("ending.txt")), Data("one\r\ntwo\r\n".utf8))
        }
        let calls = try String(contentsOf: f.root.appendingPathComponent("clone-filters.jsonl"), encoding: .utf8).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(calls.count, 4)
        let directories = calls.compactMap { $0["cwd"] as? String }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(Set(directories), Set([destination, destination.appendingPathComponent("vendor/child")].map { $0.resolvingSymlinksInPath().path }))
        let repositories = calls.compactMap { $0["repository"] as? String }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(repositories.count, 4); XCTAssertEqual(Set(repositories), Set(directories), "Nested Git inherited the caller's source repository instead of the actual checkout")
        XCTAssertTrue(calls.allSatisfy { $0["args"] as? [String] == [path, "%"] || $0["args"] as? [String] == ["binary.filtered", "%"] })
        let finalHead = try await f.source.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), config)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(path)), Data("payload\n".utf8))
        // Repository snapshots must honor the explicit global filename, then
        // ordinary local and invocation-only APP precedence without persisting
        // the temporary command override into either configuration file.
        let selected = GitLibGit2Configuration(mask: 0x200, helperURL: f.helper)
        let fromGlobal = try await f.source.materializedHistoricalFile(revision: "HEAD", path: path, backend: selected)
        XCTAssertEqual(fromGlobal.bytes, Data("CHECKOUT[payload\n]".utf8))
        _ = try await f.source.run(["config", "filter.clonefixture.smudge", "printf LOCAL; cat"])
        let localConfig = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config"))
        let fromLocal = try await f.source.materializedHistoricalFile(revision: "HEAD", path: path, backend: selected)
        XCTAssertEqual(fromLocal.bytes, Data("LOCALpayload\n".utf8))
        let appHelper = f.root.appendingPathComponent("app-config-helper")
        try executable(appHelper, "#!/bin/sh\nexec " + quote(f.helper.path) + " -c " + quote("filter.clonefixture.smudge=printf APP; cat") + " \"$@\"\n")
        let fromApplication = try await f.source.materializedHistoricalFile(revision: "HEAD", path: path, backend: .init(mask: 0x200, helperURL: appHelper))
        XCTAssertEqual(fromApplication.bytes, Data("APPpayload\n".utf8))
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), localConfig)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
    }

    func testCloneCheckoutOptionalRequiredAndSuppressedFiltersRetainSourceCleanupSemantics() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try await cloneFilterFixture(f), backend = GitLibGit2Configuration(mask: 2, helperURL: f.helper)
        var options = CloneOptions(); options.source = f.source.root.path
        _ = try await f.source.run(["config", "--global", "filter.clonefixture.smudge", "exit 37"])
        _ = try await f.source.run(["config", "--global", "filter.clonefixture.required", "false"])
        let optional = f.root.appendingPathComponent("optional")
        _ = try await f.runner.clone(options, to: optional, backend: backend)
        XCTAssertEqual(try Data(contentsOf: optional.appendingPathComponent(path)), Data("payload\n".utf8))
        _ = try await f.source.run(["config", "--global", "filter.clonefixture.required", "true"])
        for existing in [false, true] {
            let target = f.root.appendingPathComponent(existing ? "existing-empty" : "new-failed")
            if existing { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            do { _ = try await f.runner.clone(options, to: target, backend: backend); XCTFail("Required checkout filter failure reported success") } catch is GitFailure {}
            if existing { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), []) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
        }
        _ = try await f.source.run(["config", "--global", "--unset", "filter.clonefixture.smudge"])
        let missing = f.root.appendingPathComponent("missing-required")
        do { _ = try await f.runner.clone(options, to: missing, backend: backend); XCTFail("Missing required filter was skipped") } catch is GitFailure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        options.noCheckout = true
        let noCheckout = f.root.appendingPathComponent("no-checkout-filter")
        _ = try await f.runner.clone(options, to: noCheckout, backend: backend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noCheckout.appendingPathComponent(path).path))
        options.noCheckout = false; options.bare = true
        let bare = f.root.appendingPathComponent("bare-filter.git")
        _ = try await f.runner.clone(options, to: bare, backend: backend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(path)), Data("payload\n".utf8))
    }

    @MainActor func testRecursiveCloneFilterFailureRetainsSuperprojectAndCancellationDrainsActualChild() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try await cloneFilterFixture(f), childFolder = f.root.appendingPathComponent("child-source")
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: false)
        let child = GitRepository(root: childFolder, executable: f.source.executable, askpass: nil)
        _ = try await child.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Child fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false")] { _ = try await child.run(["config", key, value]) }
        _ = try await cloneFilterFixture(f, repository: child)
        _ = try await f.source.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", childFolder.path, "vendor/child"])
        _ = try await f.source.commit(message: "recursive filter failure input")
        let conditional = f.root.appendingPathComponent("conditional-filter")
        try executable(conditional, """
        #!/usr/bin/python3
        import os, sys
        if os.getcwd().endswith('/vendor/child'): sys.exit(43)
        sys.stdout.buffer.write(b'SUPER[' + sys.stdin.buffer.read() + b']')
        """)
        _ = try await f.source.run(["config", "--global", "filter.clonefixture.smudge", quote(conditional.path)])
        var options = CloneOptions(); options.source = f.source.root.path; options.recursive = true
        let backend = GitLibGit2Configuration(mask: 2, helperURL: f.helper), destination = f.root.appendingPathComponent("recursive-failed")
        let originalHead = try await f.source.run(["rev-parse", "HEAD"]).stdout, originalIndex = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index"))
        do { _ = try await f.runner.clone(options, to: destination, backend: backend); XCTFail("Required recursive filter failure reported success") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), Data("SUPER[payload\n]".utf8))
        let retained = GitRepository(root: destination, executable: f.source.executable, askpass: nil)
        let retainedHead = try await retained.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(retainedHead, originalHead, "A later submodule failure erased the successfully cloned superproject")
        let held = f.root.appendingPathComponent("held-clone-smudge"), ready = f.root.appendingPathComponent("clone-smudge-ready.json")
        try executable(held, """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, time
        child = subprocess.Popen(['/bin/sleep','30'])
        root = pathlib.Path(__file__).parent
        temporary = root / 'clone-smudge-ready.tmp'
        temporary.write_text(json.dumps({'pid':os.getpid(),'child':child.pid})); temporary.replace(root / 'clone-smudge-ready.json')
        while True: time.sleep(.02)
        """)
        _ = try await f.source.run(["config", "--global", "filter.clonefixture.smudge", quote(held.path)])
        let config = try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), global = try Data(contentsOf: f.root.appendingPathComponent("global.config")), token = OperationCancellation()
        options.recursive = false
        let capturedOptions = options
        let operation = Task { try await f.runner.clone(capturedOptions, to: f.root.appendingPathComponent("cancel-checkout"), cancellation: token, backend: backend) }
        var pids: [Int32] = []
        do {
            try await wait { FileManager.default.fileExists(atPath: ready.path) }
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any])
            pids = [try XCTUnwrap(state["pid"] as? NSNumber).int32Value, try XCTUnwrap(state["child"] as? NSNumber).int32Value]
            token.cancel()
        } catch { token.cancel(); _ = await operation.result; throw error }
        do { _ = try await operation.value; XCTFail("Canceled checkout filter succeeded") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
        let finalHead = try await f.source.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, originalHead)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), originalIndex)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/config")), config)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
    }

    func testActualCloneOneShotGitLFSSmudgeUsesOfflineCachedContent() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [git.deletingLastPathComponent().appendingPathComponent("git-lfs"), root.appendingPathComponent("build/git-runtime/Git/bin/git-lfs")]
        guard let lfs = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("The actual bundled Git LFS binary is not prepared.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = Data("actual cached LFS content\n".utf8), oid = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let storage = f.root.appendingPathComponent("lfs-storage"), object = storage.appendingPathComponent("objects/" + oid.prefix(2) + "/" + oid.dropFirst(2).prefix(2) + "/" + oid)
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: object)
        let pointer = Data(("version https://git-lfs.github.com/spec/v1\noid sha256:" + oid + "\nsize " + String(bytes.count) + "\n").utf8)
        try Data("*.lfs filter=lfs -text\n".utf8).write(to: f.source.root.appendingPathComponent(".gitattributes"))
        try pointer.write(to: f.source.root.appendingPathComponent("cached.lfs"))
        try await f.source.stage([".gitattributes", "cached.lfs"]); _ = try await f.source.commit(message: "cached LFS pointer")
        for (key, value) in [("filter.lfs.smudge", quote(lfs.path) + " smudge -- %f"), ("filter.lfs.required", "true"), ("lfs.storage", storage.path), ("lfs.url", "http://127.0.0.1:1/network-disabled"), ("filter.lfs.process", "exit 87")] { _ = try await f.source.run(["config", "--global", key, value]) }
        let global = try Data(contentsOf: f.root.appendingPathComponent("global.config")), index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index"))
        var options = CloneOptions(); options.source = f.source.root.path
        let destination = f.root.appendingPathComponent("cached-lfs-clone")
        _ = try await f.runner.clone(options, to: destination, backend: .init(mask: 2, helperURL: f.helper))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("cached.lfs")), bytes)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent("cached.lfs")), pointer)
        XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("global.config")), global)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Owned libgit2 fixture did not reach its boundary"); throw GitLibGit2Failure.runtimeMissing
    }
    @MainActor private func withHTTPS(_ f: Fixture, name: String = "https", _ body: (URL, String) async throws -> Void) async throws {
        let root = f.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
        try Data(configuration.utf8).write(to: root.appendingPathComponent("openssl.cnf"))
        let certificate = Process(); certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        certificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", root.appendingPathComponent("openssl.cnf").path, "-keyout", root.appendingPathComponent("key.pem").path, "-out", root.appendingPathComponent("cert.pem").path]
        certificate.standardOutput = FileHandle.nullDevice; certificate.standardError = FileHandle.nullDevice
        try certificate.run(); certificate.waitUntilExit(); XCTAssertEqual(certificate.terminationStatus, 0)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [try XCTUnwrap(Bundle.module.url(forResource: "git_https_server", withExtension: "py")).path, root.path, git.path, f.remote.root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) || !server.isRunning }
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ready.json"))) as? [String: Any])
        try await body(root, try XCTUnwrap(ready["url"] as? String))
    }
    private func mockAskpass(_ root: URL) throws -> URL {
        let file = root.appendingPathComponent("literal askpass ' 雪")
        let script = """
        #!/usr/bin/python3
        import base64, json, os, pathlib, sys
        root = pathlib.Path(__file__).parent
        prefix = 'TurtleGit Git transport prompt v1:'
        if len(sys.argv) != 2 or not sys.argv[1].startswith(prefix): sys.exit(1)
        prompt = json.loads(base64.b64decode(sys.argv[1][len(prefix):]))
        with (root / 'prompts.jsonl').open('a') as stream: stream.write(json.dumps(prompt) + '\\n')
        if prompt.get('kind') == 'trust':
            answer = {'version':1, 'decision':'reject' if (root / 'reject').exists() else 'temporary', 'save':False}
        else:
            answer = {'version':1, 'username':'fixture-user', 'password':'fixture-password', 'save':False}
        print(base64.b64encode(json.dumps(answer).encode()).decode(), flush=True)
        """
        try executable(file, script); return file
    }
    @MainActor func testActualHTTPSRemoteListingsAndDeleteRefStatusesUseReviewedAuthenticatedTransport() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backend = GitLibGit2Configuration(mask: 0x804, helperURL: f.helper)
        for tag in ["accepted", "rejected"] { _ = try await f.remote.run(["update-ref", "refs/tags/" + tag, "HEAD"]) }
        _ = try await f.remote.run(["config", "http.receivepack", "true"])
        try executable(f.remote.root.appendingPathComponent("hooks/update"), "#!/bin/sh\nif [ \"$1\" = refs/tags/rejected ]; then echo 'fixture refusal' >&2; exit 1; fi\nexit 0\n")
        let before = try await f.source.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: f.source.root.appendingPathComponent(".git/index"))
        try await withHTTPS(f) { root, url in
            let askpass = try self.mockAskpass(root), repo = GitRepository(root: f.source.root, executable: f.source.executable, askpass: askpass)
            let choices = try await repo.remoteReferenceChoices(remote: url, backend: backend)
            XCTAssertTrue(choices.contains("HEAD")); XCTAssertTrue(choices.contains("topic"))
            let tags = try await repo.remoteTags(remote: url, backend: backend)
            XCTAssertTrue(tags.contains { $0.name == .init("accepted") })
            do { try await repo.deleteRemoteTags(remote: url, tags: [.init("accepted"), .init("rejected")], backend: backend); XCTFail("Partial remote rejection was hidden") } catch is GitFailure {}
            let deleted = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/tags/accepted"], successfulExitCodes: 0...1)
            let retained = try await f.remote.run(["show-ref", "--verify", "--quiet", "refs/tags/rejected"], successfulExitCodes: 0...1)
            XCTAssertEqual(deleted.exitCode, 1); XCTAssertEqual(retained.exitCode, 0)
            let prompts = try String(contentsOf: root.appendingPathComponent("prompts.jsonl"), encoding: .utf8).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertEqual(prompts.filter { $0["kind"] as? String == "trust" }.count, 1, "Repeated listing/deletion helpers lost source-process certificate acceptance")
            XCTAssertEqual(prompts.first?["kind"] as? String, "trust")
            XCTAssertTrue(prompts.contains { $0["kind"] as? String == "credentials" })
            try Data().write(to: root.appendingPathComponent("reject"))
            _ = try await repo.remoteTags(remote: url, backend: backend)
            let reused = try String(contentsOf: root.appendingPathComponent("prompts.jsonl"), encoding:.utf8).split(separator:"\n").filter { (try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any])?["kind"] as? String == "trust" }.count
            XCTAssertEqual(reused,1,"Accepted authority asked again across real helper processes")
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            try await self.withHTTPS(f,name:"listing-rejected-peer") { rejectedRoot, rejectedURL in
                for _ in 0..<2 {
                    do { _ = try await repo.remoteTags(remote: rejectedURL, backend: backend); XCTFail("Rejected peer listed refs") } catch is GitFailure {}
                }
                let rejectedState = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:rejectedRoot.appendingPathComponent("state.json"))) as? [String:Any])
                XCTAssertEqual((rejectedState["requests"] as? [[String:Any]])?.count,0,"Rejected TLS peer received HTTP")
            }
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertEqual((state["requests"] as? [[String: Any]])?.count, (after["requests"] as? [[String: Any]])?.count)
        }
        let after = try await f.source.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, before); XCTAssertEqual(try Data(contentsOf: f.source.root.appendingPathComponent(".git/index")), index)
    }

    @MainActor func testActualHTTPSPeerReviewAuthenticationDepthAndRejectedPeerKeepSourceBytes() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sourceHead = try await f.remote.run(["rev-parse", "HEAD"]).stdout, sourceConfig = try Data(contentsOf: f.remote.root.appendingPathComponent("config"))
        try await withHTTPS(f) { root, url in
            let askpass = try self.mockAskpass(root), repo = GitRepository(root: f.runner.root, executable: f.runner.executable, askpass: askpass)
            var options = CloneOptions(); options.source = url; options.depth = 1
            let destination = f.root.appendingPathComponent("https-clone")
            _ = try await repo.clone(options, to: destination, backend: f.backend)
            let cloned = GitRepository(root: destination, executable: f.runner.executable, askpass: askpass)
            let head = try await cloned.run(["rev-parse", "HEAD"]).stdout, count = try await cloned.run(["rev-list", "--count", "HEAD"]).text
            XCTAssertEqual(head, sourceHead); XCTAssertEqual(count, "1\n")
            let prompts = try String(contentsOf: root.appendingPathComponent("prompts.jsonl"), encoding: .utf8).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let trustIndex = try XCTUnwrap(prompts.firstIndex { $0["kind"] as? String == "trust" }), credentialsIndex = try XCTUnwrap(prompts.firstIndex { $0["kind"] as? String == "credentials" })
            XCTAssertLessThan(trustIndex, credentialsIndex)
            XCTAssertEqual(prompts[trustIndex]["hostname"] as? String, "localhost")
            let certificate = try XCTUnwrap(prompts[trustIndex]["certificate"] as? String), details = try GitCertificateDetails(base64DER: certificate)
            XCTAssertEqual(details.subject, "localhost")
            XCTAssertEqual(prompts[trustIndex]["issuer"] as? String, "localhost")
            XCTAssertFalse((prompts[trustIndex]["validationError"] as? String ?? "").isEmpty)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertTrue((state["requests"] as? [[String: Any]] ?? []).contains { $0["authenticated"] as? Bool == true })
            try Data().write(to: root.appendingPathComponent("reject"))
            let checkpoint = try Data(contentsOf: root.appendingPathComponent("state.json"))
            try await self.withHTTPS(f,name:"clone-rejected-peer") { rejectedRoot, rejectedURL in
                var rejectedOptions=options;rejectedOptions.source=rejectedURL
                do { _ = try await repo.clone(rejectedOptions, to:f.root.appendingPathComponent("rejected"),backend:f.backend);XCTFail("Rejected certificate transferred objects") } catch is GitFailure {}
                let rejectedState=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:rejectedRoot.appendingPathComponent("state.json"))) as? [String:Any])
                XCTAssertEqual((rejectedState["requests"] as? [[String:Any]])?.count,0)
            }
            // Rejecting the actual TLS peer cannot send an authenticated HTTP
            // request; the server may only record its failed TLS handshake.
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertEqual((before["requests"] as? [[String: Any]])?.count, (after["requests"] as? [[String: Any]])?.count)
            var fetch = FetchOptions(); fetch.remote = "origin"; fetch.depth = 2
            try FileManager.default.removeItem(at: root.appendingPathComponent("reject"))
            let priorTrust = try String(contentsOf: root.appendingPathComponent("prompts.jsonl"), encoding: .utf8).split(separator: "\n").filter { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["kind"] as? String == "trust"
            }.count
            _ = try await cloned.fetch(fetch, backend:f.backend)
            let deepened=try await cloned.run(["rev-list","--count","HEAD"]).text;XCTAssertEqual(deepened,"2\n")
            try await self.withHTTPS(f,name:"configured-ca-peer") { caRoot,caURL in
                _ = try await f.runner.run(["config","--global","http."+caURL+".sslCAInfo",caRoot.appendingPathComponent("cert.pem").path])
                _ = try await f.runner.run(["config","--global","--add","http.extraHeader","X-TurtleGit-Fixture: invalid"])
                for header in ["","X-TurtleGit-Fixture: private-fixture","X-Second-Fixture: retained"] {
                    _ = try await f.runner.run(["config","--global","--add","http."+caURL+".extraHeader",header])
                }
                var caOptions=options;caOptions.source=caURL;caOptions.depth=2
                _ = try await repo.clone(caOptions,to:f.root.appendingPathComponent("configured-ca-clone"),backend:f.backend)
                let finalPrompts=try String(contentsOf:root.appendingPathComponent("prompts.jsonl"),encoding:.utf8).split(separator:"\n").map{try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any])}
                XCTAssertEqual(finalPrompts.filter{$0["kind"] as? String == "trust"}.count,priorTrust,"Fresh uncached actual configured CA still required a trust exception")
                let configuredState=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:caRoot.appendingPathComponent("state.json"))) as? [String:Any])
                XCTAssertTrue((configuredState["requests"] as? [[String:Any]] ?? []).contains{$0["authenticated"] as? Bool == true && $0["fixture_header"] as? Bool == true},"URL-scoped multivalue/reset headers were lost")
            }
        }
        let finalHead = try await f.remote.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, sourceHead); XCTAssertEqual(try Data(contentsOf: f.remote.root.appendingPathComponent("config")), sourceConfig)
    }

    @MainActor func testActualHTTPSCertificateAcceptanceSurvivesRemoteFailureAndProcessIsolation() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.remote.run(["update-ref","refs/tags/blocked","HEAD"])
        _ = try await f.remote.run(["config","http.receivepack","true"])
        try executable(f.remote.root.appendingPathComponent("hooks/update"),"#!/bin/sh\nexit 1\n")
        try await withHTTPS(f) { root,url in
            let askpass=try self.mockAskpass(root),repo=GitRepository(root:f.source.root,executable:f.source.executable,askpass:askpass),backend=GitLibGit2Configuration(mask:0x804,helperURL:f.helper)
            do{try await repo.deleteRemoteTags(remote:url,tags:[.init("blocked")],backend:backend);XCTFail("Rejected first remote mutation reported success")}catch is GitFailure{}
            _ = try await repo.remoteTags(remote:url,backend:backend)
            func trustCount()throws->Int{try String(contentsOf:root.appendingPathComponent("prompts.jsonl"),encoding:.utf8).split(separator:"\n").filter{(try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any])?["kind"] as? String == "trust"}.count}
            XCTAssertEqual(try trustCount(),1,"Actual trust acceptance was discarded by later remote rejection")
            // A fresh helper without the source-process snapshot has no global
            // acceptance file to discover. Each isolated invocation asks again.
            let isolated=f.root.appendingPathComponent("isolated helper")
            try self.executable(isolated,"#!/bin/sh\nunset TURTLEGIT_LIBGIT2_CERTIFICATE_ACCEPTANCES\nexec "+self.quote(f.helper.path)+" \"$@\"\n")
            for _ in 0..<2{_ = try await repo.remoteTags(remote:url,backend:.init(mask:4,helperURL:isolated))}
            XCTAssertEqual(try trustCount(),3,"Independent helper processes retained an undisclosed disk/global acceptance")
            try Data().write(to:root.appendingPathComponent("reject"))
            let changedHost=url.replacingOccurrences(of:"localhost",with:"127.0.0.1")
            for _ in 0..<2{do{_ = try await repo.remoteTags(remote:changedHost,backend:backend);XCTFail("Changed-host rejection was cached or bypassed")}catch is GitFailure{}}
            XCTAssertEqual(try trustCount(),5,"Changed hostname did not review exact authority or rejection was cached")
            _ = try await repo.remoteTags(remote:url,backend:backend)
            XCTAssertEqual(try trustCount(),5,"Previously accepted exact authority was lost")
        }
    }

    @MainActor func testActualRemoteListingCancellationWaitsForOwnedPromptDrain() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await withHTTPS(f) { root, url in
            let askpass = root.appendingPathComponent("held-listing-prompt"), ready = root.appendingPathComponent("listing-ready.json"), release = root.appendingPathComponent("release")
            try self.executable(askpass, """
            #!/usr/bin/python3
            import base64, fcntl, json, os, pathlib, time
            root = pathlib.Path(__file__).parent
            lock = os.open(os.environ['TURTLEGIT_REMOTE_PROMPT_LOCK'], os.O_RDWR | os.O_NOFOLLOW)
            fcntl.flock(lock, fcntl.LOCK_EX)
            temporary = root / 'listing-ready.tmp'
            temporary.write_text(json.dumps({'pid':os.getpid(),'parent':os.getppid(),'cancel':os.environ['TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE']}))
            temporary.replace(root / 'listing-ready.json')
            while not (root / 'release').exists(): time.sleep(.01)
            print(base64.b64encode(json.dumps({'version':1,'decision':'reject','save':False}).encode()).decode(), flush=True)
            fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
            """)
            let repo = GitRepository(root: f.source.root, executable: f.source.executable, askpass: askpass), token = OperationCancellation()
            var finished = false
            let operation = Task { defer { finished = true }; return try await repo.remoteReferenceChoices(remote: url, cancellation: token, backend: .init(mask: 4, helperURL: f.helper)) }
            var pids: [Int32] = []
            do {
                try await self.wait { FileManager.default.fileExists(atPath: ready.path) }
                let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any])
                pids = [try XCTUnwrap(state["pid"] as? NSNumber).int32Value, try XCTUnwrap(state["parent"] as? NSNumber).int32Value]
                token.cancel()
                let marker = try XCTUnwrap(state["cancel"] as? String)
                try await self.wait { FileManager.default.fileExists(atPath: marker) }
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(finished); XCTAssertTrue(pids.allSatisfy { kill($0, 0) == 0 })
                try Data().write(to: release)
            } catch { token.cancel(); try? Data().write(to: release); _ = await operation.result; throw error }
            do { _ = try await operation.value; XCTFail("Canceled remote listing succeeded") }
            catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
            try await self.wait { pids.allSatisfy { kill($0, 0) != 0 } }
        }
    }

    @MainActor func testActualHelperCancellationWaitsPromptLockThenReapsOwnedProcessGroup() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await withHTTPS(f) { root, url in
            let askpass = root.appendingPathComponent("held native prompt"), ready = root.appendingPathComponent("held.json"), release = root.appendingPathComponent("release")
            let script = """
            #!/usr/bin/python3
            import base64, fcntl, json, os, pathlib, sys, time
            root = pathlib.Path(__file__).parent
            prompt = json.loads(base64.b64decode(sys.argv[1].split(':',1)[1]))
            if prompt['kind'] == 'trust':
                (root / 'accepted-before-cancel').write_text(prompt['certificate'])
                print(base64.b64encode(json.dumps({'version':1,'decision':'temporary','save':False}).encode()).decode(), flush=True)
                sys.exit(0)
            lock = os.open(os.environ['TURTLEGIT_REMOTE_PROMPT_LOCK'], os.O_RDWR | os.O_NOFOLLOW)
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker = pathlib.Path(os.environ['TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE'])
            temporary = root / 'held.tmp'
            temporary.write_text(json.dumps({'pid':os.getpid(), 'parent':os.getppid(), 'cancel':str(marker)})); temporary.replace(root / 'held.json')
            while not (root / 'release').exists(): time.sleep(.01)
            print(base64.b64encode(json.dumps({'version':1,'decision':'reject','save':False}).encode()).decode(), flush=True)
            fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
            """
            try self.executable(askpass, script)
            let repo = GitRepository(root: f.runner.root, executable: f.runner.executable, askpass: askpass), token = OperationCancellation()
            var options = CloneOptions(); options.source = url
            var finished = false
            let operation = Task { defer { finished = true }; return try await repo.clone(options, to: f.root.appendingPathComponent("cancelled"), cancellation: token, backend: f.backend) }
            var pids: [Int32] = []
            do {
                try await self.wait { FileManager.default.fileExists(atPath: ready.path) }
                let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any])
                pids = [try XCTUnwrap(state["pid"] as? NSNumber).int32Value, try XCTUnwrap(state["parent"] as? NSNumber).int32Value]
                let marker = try XCTUnwrap(state["cancel"] as? String)
                token.cancel(); try await self.wait { FileManager.default.fileExists(atPath: marker) }
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(finished, "Cancellation released a live prompt/export worker")
                XCTAssertTrue(pids.allSatisfy { kill($0, 0) == 0 }, "Cancellation killed the prompt before its actual lock drain")
                try Data().write(to: release)
            } catch {
                token.cancel(); try? Data().write(to: release); _ = await operation.result; throw error
            }
            do { _ = try await operation.value; XCTFail("Cancelled actual helper succeeded") }
            catch is GitCommandCancellationFailure {}
            catch is OperationCancellationFailure {}
            try await self.wait { pids.allSatisfy { kill($0, 0) != 0 } }
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("accepted-before-cancel").path))
            let retry=GitRepository(root:f.runner.root,executable:f.runner.executable,askpass:try self.mockAskpass(root))
            _ = try await retry.remoteTags(remote:url,backend:.init(mask:4,helperURL:f.helper))
            let retryPrompts=try String(contentsOf:root.appendingPathComponent("prompts.jsonl"),encoding:.utf8).split(separator:"\n").map{try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any])}
            XCTAssertEqual(retryPrompts.filter{$0["kind"] as? String == "trust"}.count,1,"Cancellation imported an earlier acceptance from the canceled helper")
        }
    }
}
