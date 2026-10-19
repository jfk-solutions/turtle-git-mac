// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
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
        let direct = try await client.fetchForRebase(options)
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

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Owned libgit2 fixture did not reach its boundary"); throw GitLibGit2Failure.runtimeMissing
    }
    @MainActor private func withHTTPS(_ f: Fixture, _ body: (URL, String) async throws -> Void) async throws {
        let root = f.root.appendingPathComponent("https")
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
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertTrue((state["requests"] as? [[String: Any]] ?? []).contains { $0["authenticated"] as? Bool == true })
            try Data().write(to: root.appendingPathComponent("reject"))
            let checkpoint = try Data(contentsOf: root.appendingPathComponent("state.json"))
            do { _ = try await repo.clone(options, to: f.root.appendingPathComponent("rejected"), backend: f.backend); XCTFail("Rejected certificate transferred objects") }
            catch is GitFailure {}
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
            _ = try await f.runner.run(["config", "--global", "http." + url + ".sslCAInfo", root.appendingPathComponent("cert.pem").path])
            _ = try await f.runner.run(["config", "--global", "--add", "http.extraHeader", "X-TurtleGit-Fixture: invalid"])
            for header in ["", "X-TurtleGit-Fixture: private-fixture", "X-Second-Fixture: retained"] {
                _ = try await f.runner.run(["config", "--global", "--add", "http." + url + ".extraHeader", header])
            }
            _ = try await cloned.fetch(fetch, backend: f.backend)
            let deepened = try await cloned.run(["rev-list", "--count", "HEAD"]).text
            XCTAssertEqual(deepened, "2\n")
            let finalPrompts = try String(contentsOf: root.appendingPathComponent("prompts.jsonl"), encoding: .utf8).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertEqual(finalPrompts.filter { $0["kind"] as? String == "trust" }.count, priorTrust, "Actual configured CA still required a trust exception")
            let configuredState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertTrue((configuredState["requests"] as? [[String: Any]] ?? []).contains { $0["authenticated"] as? Bool == true && $0["fixture_header"] as? Bool == true }, "URL-scoped multivalue/reset headers were lost")
        }
        let finalHead = try await f.remote.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, sourceHead); XCTAssertEqual(try Data(contentsOf: f.remote.root.appendingPathComponent("config")), sourceConfig)
    }

    @MainActor func testActualHelperCancellationWaitsPromptLockThenReapsOwnedProcessGroup() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Caller explicitly disabled interactive authentication.") }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await withHTTPS(f) { root, url in
            let askpass = root.appendingPathComponent("held native prompt"), ready = root.appendingPathComponent("held.json"), release = root.appendingPathComponent("release")
            let script = """
            #!/usr/bin/python3
            import base64, fcntl, json, os, pathlib, time
            root = pathlib.Path(__file__).parent
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
        }
    }
}
