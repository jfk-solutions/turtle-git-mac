// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class FetchRefspecCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GitCommandInvocation] = []
    func append(_ value: GitCommandInvocation) { lock.lock(); values.append(value); lock.unlock() }
    var commands: [GitCommandInvocation] { lock.lock(); defer { lock.unlock() }; return values }
}

final class FetchRefspecTests: XCTestCase {
    private let cli = GitLibGit2Configuration(enabled: false)
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func script(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private struct Fixture {
        let root: URL, publisher: GitRepository, remote: GitRepository, consumer: GitRepository
        let command: URL, environment: String
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-refspec-雪-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let config = root.appendingPathComponent("global.config"); try Data().write(to: config)
            let environment = "unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(config.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n"
            let command = root.appendingPathComponent("private-git")
            let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"
            try script(command, "#!/bin/sh\n" + environment + "exec " + quote(git) + " \"$@\"\n")
            func repository(_ name: String) throws -> GitRepository {
                let path = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                return GitRepository(root: path, executable: command, askpass: nil, libgit2Configuration: cli)
            }
            let publisher = try repository("publisher"), remote = try repository("remote.git"), consumer = try repository("consumer")
            _ = try await publisher.run(["init", "-b", "main"])
            _ = try await remote.run(["init", "--bare"])
            for repo in [publisher, remote] {
                for (key, value) in [("user.name", "Refspec QA"), ("user.email", "refspec@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false"), ("protocol.file.allow", "always")] {
                    _ = try await repo.run(["config", key, value])
                }
            }
            try Data("base\n".utf8).write(to: publisher.root.appendingPathComponent("file"))
            _ = try await publisher.run(["add", "file"]); _ = try await publisher.run(["commit", "-m", "base"])
            _ = try await publisher.run(["remote", "add", "origin", remote.root.path])
            _ = try await publisher.run(["push", "origin", "main"])
            _ = try await consumer.run(["clone", "--branch", "main", "--", remote.root.path, "."])
            for (key, value) in [("core.precomposeunicode", "false"), ("core.hooksPath", "/dev/null"), ("pull.rebase", "false"), ("commit.gpgsign", "false")] { _ = try await consumer.run(["config", key, value]) }
            return Fixture(root: root, publisher: publisher, remote: remote, consumer: consumer, command: command, environment: environment)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private func options(_ spec: String) -> FetchOptions {
        var value = FetchOptions(); value.remote = "origin"; value.namedRemoteFetchAll = false; value.branch = spec; return value
    }
    private func hash(_ repo: GitRepository, _ ref: String) async throws -> String {
        try await repo.run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--end-of-options", ref]).text.trimmingCharacters(in: .newlines)
    }
    @discardableResult private func advance(_ f: Fixture) async throws -> String {
        try Data("remote change\n".utf8).write(to: f.publisher.root.appendingPathComponent("new-file"))
        _ = try await f.publisher.run(["add", "new-file"]); _ = try await f.publisher.run(["commit", "-m", "advance"])
        _ = try await f.publisher.run(["push", "origin", "main"])
        return try await hash(f.publisher, "HEAD")
    }
    private func selected(_ f: Fixture) throws -> GitLibGit2Configuration {
        let actual = try XCTUnwrap(GitLibGit2Configuration(mask: 4).executor(for: .fetch))
        let helper = f.root.appendingPathComponent("private-libgit2")
        try script(helper, "#!/bin/sh\n" + f.environment + "exec " + quote(actual.path) + " \"$@\"\n")
        return .init(mask: 4, helperURL: helper)
    }

    func testLiteralUnicodeDestinationIsOneArgumentAndPreservesIndexAndConfig() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let branch = "topic/cafe\u{301}-雪", destination = "refs/remotes/custom/cafe\u{301}-雪"
        _ = try await f.publisher.run(["branch", branch]); _ = try await f.publisher.run(["push", "origin", branch])
        try Data("staged\n".utf8).write(to: f.consumer.root.appendingPathComponent("file")); _ = try await f.consumer.run(["add", "file"])
        _ = try await f.consumer.run(["config", "core.precomposeunicode", "true"])
        let index = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config"))
        let spec = "+refs/heads/" + branch + ":" + destination, capture = FetchRefspecCommands()
        _ = try await f.consumer.fetch(options(" \t" + spec + "\r\n"), onCommand: capture.append, backend: cli)
        let target = try await hash(f.consumer, destination), expected = try await hash(f.publisher, branch)
        XCTAssertEqual(target, expected)
        let argv = try XCTUnwrap(capture.commands.last).arguments
        XCTAssertTrue(argv.contains("core.precomposeunicode=false"))
        XCTAssertEqual(argv.suffix(3), ["--", "origin", spec][...])
        XCTAssertTrue(try XCTUnwrap(argv.last).utf8.elementsEqual(spec.utf8))
        XCTAssertEqual(index, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/index")))
        XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
    }

    func testForcedAndWildcardMappingsUpdateOnlyRequestedDestinations() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try await hash(f.publisher, "HEAD"), new = try await advance(f)
        _ = try await f.publisher.run(["branch", "topic/one"]); _ = try await f.publisher.run(["branch", "topic/two", old])
        _ = try await f.publisher.run(["push", "origin", "topic/one", "topic/two"])
        _ = try await f.consumer.fetch(options("refs/heads/topic/*:refs/remotes/selection/*"), backend: cli)
        let one = try await hash(f.consumer, "refs/remotes/selection/one"), two = try await hash(f.consumer, "refs/remotes/selection/two")
        XCTAssertEqual(one, new); XCTAssertEqual(two, old)
        _ = try await f.remote.run(["update-ref", "refs/heads/topic/one", old])
        do { _ = try await f.consumer.fetch(options("refs/heads/topic/one:refs/heads/local-topic"), backend: cli) } catch { return XCTFail("Initial local mapping failed: \(error)") }
        _ = try await f.consumer.run(["update-ref", "refs/heads/local-topic", new])
        do { _ = try await f.consumer.fetch(options("refs/heads/topic/one:refs/heads/local-topic"), backend: cli); XCTFail("Non-fast-forward local branch unexpectedly accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.arguments.last, "refs/heads/topic/one:refs/heads/local-topic"); XCTAssertNotEqual(failure.code, 0) }
        _ = try await f.consumer.fetch(options("+refs/heads/topic/one:refs/heads/local-topic"), backend: cli)
        let forced = try await hash(f.consumer, "refs/heads/local-topic"), retained = try await hash(f.consumer, "refs/remotes/selection/one")
        XCTAssertEqual(forced, old); XCTAssertEqual(retained, new)
    }

    func testArbitraryURLFetchUsesLiteralMappingWithoutWritingRemoteConfiguration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let new = try await advance(f), config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config"))
        var value = options("+refs/heads/main:refs/remotes/url/main")
        value.remote = f.remote.root.path; value.arbitraryURL = true; value.tags = .disabled; value.prune = .disabled
        let capture = FetchRefspecCommands()
        _ = try await f.consumer.fetch(value, onCommand: capture.append, backend: cli)
        let mapped = try await hash(f.consumer, "refs/remotes/url/main")
        XCTAssertEqual(mapped, new)
        let argv = try XCTUnwrap(capture.commands.last).arguments
        XCTAssertEqual(argv.suffix(3), ["--", f.remote.root.path, value.branch][...])
        XCTAssertTrue(argv.contains("--no-tags")); XCTAssertTrue(argv.contains("--no-prune"))
        XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
        let rebase = try await f.consumer.fetchForRebase(value, backend: cli)
        XCTAssertTrue(rebase.upstreamResolved); XCTAssertEqual(rebase.upstreamPreset, "FETCH_HEAD"); XCTAssertEqual(rebase.upstream, new)
    }

    func testNegativeSingleRefspecMatchesDirectGitWithoutInventedPositiveMapping() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let controlURL = f.root.appendingPathComponent("control"); try FileManager.default.createDirectory(at: controlURL, withIntermediateDirectories: true)
        let control = GitRepository(root: controlURL, executable: f.command, askpass: nil)
        _ = try await control.run(["clone", "--branch", "main", "--", f.remote.root.path, "."])
        _ = try await advance(f)
        // Both repositories retain the same local HEAD and refresh only remote refs.
        _ = try await control.run(["fetch", "origin"])
        _ = try await f.consumer.run(["fetch", "origin"])
        let spec = "^refs/heads/main"
        let direct = try await control.run(["fetch", "--progress", "--verbose", "--", "origin", spec], successfulExitCodes: 0...255)
        var actualCode: Int32 = 0
        do { _ = try await f.consumer.fetch(options(spec), backend: cli) }
        catch let failure as GitFailure { actualCode = failure.code; XCTAssertEqual(failure.arguments.last, spec) }
        XCTAssertEqual(actualCode, direct.exitCode)
        let actualRefs = try await f.consumer.run(["show-ref"]).stdout, expectedRefs = try await control.run(["show-ref"]).stdout
        XCTAssertEqual(actualRefs, expectedRefs)
        XCTAssertEqual(try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/FETCH_HEAD")), try Data(contentsOf: controlURL.appendingPathComponent(".git/FETCH_HEAD")))
    }

    func testPullDestinationMappingFastForwardsAndDelegatesInvalidSyntax() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let new = try await advance(f)
        var pull = PullOptions(); pull.fetch = options("refs/heads/main:refs/remotes/custom/pulled"); pull.fastForwardOnly = true
        let commands=FetchRefspecCommands()
        _ = try await f.consumer.pull(pull,onCommand:commands.append)
        XCTAssertEqual(commands.commands.first?.arguments.last,pull.fetch.branch)
        XCTAssertTrue(String(decoding:try XCTUnwrap(commands.commands.first).preamble,as:UTF8.self).contains(pull.fetch.branch))
        let head = try await hash(f.consumer, "HEAD"), mapped = try await hash(f.consumer, "refs/remotes/custom/pulled")
        XCTAssertEqual(head, new); XCTAssertEqual(mapped, new)
        pull.fetch.branch = "refs/heads/main:bad..destination"
        do { _ = try await f.consumer.pull(pull,onCommand:commands.append); XCTFail("Malformed Pull refspec accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.arguments.first, "pull"); XCTAssertEqual(failure.arguments.last, pull.fetch.branch); XCTAssertFalse(failure.diagnosticText.isEmpty) }
        let finalHead = try await hash(f.consumer, "HEAD"); XCTAssertEqual(finalHead, new)
        XCTAssertEqual(commands.commands.count,2);XCTAssertEqual(commands.commands.last?.arguments.last,pull.fetch.branch)
    }

    func testMalformedFetchIsEngineFailureButEmbeddedNULIsStructuralFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let refs = try await f.consumer.run(["show-ref"]).stdout, config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config"))
        let capture = FetchRefspecCommands(), spec = "refs/heads/main:bad..destination"
        do { _ = try await f.consumer.fetch(options(spec), onCommand: capture.append, backend: cli); XCTFail("Malformed Fetch accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.arguments.first, "fetch"); XCTAssertEqual(failure.arguments.last, spec); XCTAssertFalse(failure.diagnosticText.isEmpty) }
        XCTAssertEqual(capture.commands.count, 1)
        for pull in [false, true] {
            do {
                if pull { var value = PullOptions(); value.fetch = options("main\0:destination"); _ = try await f.consumer.pull(value) }
                else { _ = try await f.consumer.fetch(options("main\0:destination"), onCommand: capture.append, backend: cli) }
                XCTFail("NUL forwarded")
            } catch FetchFailure.branch { }
        }
        XCTAssertEqual(capture.commands.count, 1)
        let finalRefs = try await f.consumer.run(["show-ref"]).stdout
        XCTAssertEqual(refs, finalRefs); XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
    }

    func testInactiveFieldOmissionAndCancelledPreparationPreserveConfiguration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = FetchRefspecCommands(); var value = options("not:a:valid:refspec")
        value.namedRemoteFetchAll = true
        _ = try await f.consumer.fetch(value, onCommand: capture.append, backend: cli)
        value.allRemotes = true
        _ = try await f.consumer.fetch(value, onCommand: capture.append, backend: cli)
        XCTAssertEqual(capture.commands.count, 2)
        XCTAssertEqual(capture.commands[0].arguments.suffix(2), ["--", "origin"][...])
        XCTAssertEqual(capture.commands[1].arguments.last, "--all")
        let config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")), refs = try await f.consumer.run(["show-ref"]).stdout
        value = options("+refs/heads/*:refs/remotes/cancelled/*")
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await f.consumer.fetch(value, cancellation: cancelled, onCommand: capture.append, backend: cli); XCTFail("Pre-cancelled Fetch ran") } catch OperationCancellationFailure.cancelled { }
        let token = OperationCancellation()
        do { _ = try await f.consumer.fetch(value, cancellation: token, prepareTransport: { _, current in current.cancel(); return nil }, onCommand: capture.append, backend: cli); XCTFail("Cancelled preparation ran Fetch") } catch OperationCancellationFailure.cancelled { }
        XCTAssertEqual(capture.commands.count, 2)
        let finalRefs = try await f.consumer.run(["show-ref"]).stdout
        XCTAssertEqual(refs, finalRefs); XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
    }

    func testSelectedLibraryPersistsMappingButFirstFetchUsesLoadedConfiguration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backend = try selected(f), spec = "+refs/heads/main:refs/remotes/deferred/main", new = try await advance(f)
        _ = try await f.consumer.fetch(options(spec), backend: backend)
        let configured = try await f.consumer.run(["config", "--get-all", "remote.origin.fetch"]).text.split(separator: "\n").map(String.init)
        XCTAssertEqual(configured, ["+refs/heads/*:refs/remotes/origin/*", spec])
        let first = try await f.consumer.run(["show-ref", "--verify", "refs/remotes/deferred/main"], successfulExitCodes: 0...255)
        XCTAssertNotEqual(first.exitCode, 0, "First source Fetch must use the already-loaded remote")
        let conventional = try await hash(f.consumer, "refs/remotes/origin/main"); XCTAssertEqual(conventional, new)
        var all = options(""); all.namedRemoteFetchAll = true
        _ = try await f.consumer.fetch(all, backend: backend)
        let deferred = try await hash(f.consumer, "refs/remotes/deferred/main"); XCTAssertEqual(deferred, new)
    }

    func testSelectedLibraryAnonymousAndMalformedRefspecFailuresPreserveConfig() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backend = try selected(f), config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")), refs = try await f.consumer.run(["show-ref"]).stdout
        var value = options("+refs/heads/main:refs/remotes/custom/main"); value.remote = f.remote.root.path; value.arbitraryURL = true
        for request in [value, options("refs/heads/main:bad..destination")] {
            do { _ = try await f.consumer.fetch(request, backend: backend); XCTFail("Invalid source-library operation accepted") }
            catch let failure as GitFailure { XCTAssertEqual(failure.arguments.last, request.branch); XCTAssertFalse(failure.diagnosticText.isEmpty) }
        }
        let finalRefs = try await f.consumer.run(["show-ref"]).stdout
        XCTAssertEqual(refs, finalRefs); XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
    }

    func testRebaseRawPresetsStayEditableWithoutGuessingRefspecDestination() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let new = try await advance(f), spec = "+refs/heads/main:refs/remotes/rebase/main"
        let result = try await f.consumer.fetchForRebase(options(spec), backend: cli)
        XCTAssertEqual(result.upstream, "remotes/origin/" + spec)
        XCTAssertEqual(result.upstreamPreset, result.upstream); XCTAssertFalse(result.upstreamResolved)
        XCTAssertFalse(result.canFastForward); XCTAssertFalse(result.currentIsUpToDate); XCTAssertFalse(result.unchangedAtHEAD)
        let mapped = try await hash(f.consumer, "refs/remotes/rebase/main"); XCTAssertEqual(mapped, new)
        let ordinary = try await f.consumer.fetchForRebase(options("main"), backend: cli)
        XCTAssertTrue(ordinary.upstreamResolved); XCTAssertEqual(ordinary.upstream, new); XCTAssertEqual(ordinary.upstreamPreset, "remotes/origin/main")
        let qualified = try await f.consumer.fetchForRebase(options("refs/heads/main"), backend: cli)
        XCTAssertEqual(qualified.upstreamPreset, "remotes/origin/refs/heads/main"); XCTAssertFalse(qualified.upstreamResolved)
        let backend = try selected(f), deferred = "+refs/heads/main:refs/remotes/rebase-later/main"
        let library = try await f.consumer.fetchForRebase(options(deferred), backend: backend)
        XCTAssertEqual(library.upstream, "remotes/origin/" + deferred); XCTAssertFalse(library.upstreamResolved)
        XCTAssertFalse(library.canFastForward); XCTAssertFalse(library.currentIsUpToDate); XCTAssertFalse(library.output.isEmpty)
        let configs = try await f.consumer.run(["config", "--get-all", "remote.origin.fetch"]).text
        XCTAssertTrue(configs.split(separator: "\n").contains(Substring(deferred)))
        let head = try await hash(f.consumer, "HEAD"); XCTAssertEqual(head, result.head)
    }

    func testRebaseNamedAllOmitsFieldUsesTrackingAndCanOpenEmptyChooser() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let new = try await advance(f), capture = FetchRefspecCommands()
        var value = options("refs/heads/main:deliberately:not:submitted"); value.namedRemoteFetchAll = true
        let result = try await f.consumer.fetchForRebase(value, onCommand: capture.append, backend: cli)
        XCTAssertTrue(result.upstreamResolved); XCTAssertEqual(result.upstream, new); XCTAssertEqual(result.upstreamPreset, "remotes/origin/main")
        XCTAssertEqual(capture.commands.first?.arguments.suffix(2), ["--", "origin"][...])
        _ = try await f.consumer.run(["config", "--unset", "branch.main.merge"])
        value.branch = ""
        let empty = try await f.consumer.fetchForRebase(value, backend: cli)
        XCTAssertEqual(empty.upstreamPreset, ""); XCTAssertEqual(empty.upstream, ""); XCTAssertFalse(empty.upstreamResolved)
        XCTAssertFalse(empty.canFastForward); XCTAssertFalse(empty.currentIsUpToDate); XCTAssertEqual(empty.head, result.head)
    }
    func testPullRebaseNamedAllRetainsNonTrackingMappingAndOmitsMatchingTracking() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let new = try await advance(f), capture = FetchRefspecCommands()
        var value = options("+refs/heads/main:refs/remotes/pull-rebase/main"); value.namedRemoteFetchAll = true
        let mapped = try await f.consumer.fetchForRebase(value, onCommand: capture.append, backend: cli, isPull: true)
        XCTAssertEqual(mapped.upstreamPreset, "remotes/origin/" + value.branch); XCTAssertFalse(mapped.upstreamResolved)
        XCTAssertFalse(mapped.currentIsUpToDate); XCTAssertFalse(mapped.canFastForward)
        XCTAssertEqual(capture.commands.first?.arguments.last, value.branch)
        let destination = try await hash(f.consumer, "refs/remotes/pull-rebase/main"); XCTAssertEqual(destination, new)
        value.branch = "main"
        let matched = try await f.consumer.fetchForRebase(value, onCommand: capture.append, backend: cli, isPull: true)
        XCTAssertTrue(matched.upstreamResolved); XCTAssertEqual(matched.upstream, new)
        XCTAssertEqual(matched.upstreamPreset, "remotes/origin/main")
        XCTAssertEqual(capture.commands.last?.arguments.suffix(2), ["--", "origin"][...])
        let head = try await hash(f.consumer, "HEAD"); XCTAssertEqual(head, mapped.head)
    }

    func testPullAndRebaseDoNotOmitCanonicallyEquivalentButByteDistinctPackedRef() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try await hash(f.consumer, "HEAD"), new = try await advance(f)
        let decomposed = "cafe\u{301}", composed = "café"
        // Packed refs can represent both spellings even on normalizing filesystems.
        let packed = "# pack-refs with: peeled fully-peeled sorted \n" + new + " refs/heads/" + decomposed + "\n" + old + " refs/heads/" + composed + "\n"
        try Data(packed.utf8).write(to: f.remote.root.appendingPathComponent("packed-refs"))
        _ = try await f.consumer.run(["config", "core.precomposeunicode", "true"])
        _ = try await f.consumer.run(["config", "branch.main.merge", "refs/heads/" + composed])
        let config = try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config"))
        var value = options(decomposed); value.namedRemoteFetchAll = true
        var pull = PullOptions(); pull.fetch = value; pull.fastForwardOnly = true
        _ = try await f.consumer.pull(pull)
        let head = try await hash(f.consumer, "HEAD"); XCTAssertEqual(head, new, "Literal NFD selection must not be omitted in favor of the distinct NFC tracking branch")
        let capture = FetchRefspecCommands()
        let rebase = try await f.consumer.fetchForRebase(value, onCommand: capture.append, backend: cli, isPull: true)
        XCTAssertTrue(rebase.upstreamResolved); XCTAssertEqual(rebase.upstream, new)
        XCTAssertTrue(rebase.upstreamPreset.utf8.elementsEqual(("remotes/origin/" + decomposed).utf8))
        XCTAssertTrue(try XCTUnwrap(capture.commands.last?.arguments.last).utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(config, try Data(contentsOf: f.consumer.root.appendingPathComponent(".git/config")))
    }

}
