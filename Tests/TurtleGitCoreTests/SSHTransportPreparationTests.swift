// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

private actor TransportEvents {
    var remotes: [[String]] = []
    var directories: [URL] = []
    func record(_ names: [String], _ directory: URL) { remotes.append(names); directories.append(directory) }
    func snapshot() -> ([[String]], [URL]) { (remotes, directories) }
}
final class SSHTransportPreparationTests: XCTestCase {
    enum FixtureFailure: Error { case denied }
    struct Fixture: Sendable {
        let root: URL, key: URL, realGit: URL, agentHelper: URL, wrapper: URL
        let source: GitRepository, repo: GitRepository
        var log: URL { root.appendingPathComponent("transport.log") }
        func agent(_ token: OperationCancellation) throws -> SSHAgentSession {
            let session = try SSHAgentSession(runtime: SSHAgentRuntime(agent: agentHelper, add: URL(fileURLWithPath: "/usr/bin/ssh-add")), temporaryRoot: root, cancellation: token)
            do { try session.add(keys: [key], cancellation: token); return session } catch { session.close(); throw error }
        }
    }
    func fixture() async throws -> Fixture {
        let root = try SSHAgentSessionTests().fixture()
        do {
            let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
            let source = GitRepository(root: root.appendingPathComponent("source"), executable: git)
            try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: false)
            _ = try await source.run(["init", "-b", "main"])
            for (name,value) in [("user.name","Fixture"),("user.email","fixture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await source.run(["config",name,value]) }
            try Data("base\n".utf8).write(to: source.root.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "base")
            let consumer = root.appendingPathComponent("consumer")
            _ = try await source.run(["clone",source.root.path,consumer.path])
            let plain = GitRepository(root: consumer, executable: git)
            for (name,value) in [("user.name","Fixture"),("user.email","fixture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await plain.run(["config",name,value]) }
            let key = root.appendingPathComponent("fixture-key"), agent = root.appendingPathComponent("agent")
            try SSHAgentSessionTests().command("/usr/bin/ssh-keygen", ["-q","-t","ed25519","-N","","-C","transport-fixture","-f",key.path])
            try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid\"\nexec /usr/bin/ssh-agent \"$@\"\n".utf8).write(to: agent)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],ofItemAtPath: agent.path)
            func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let wrapper = root.appendingPathComponent("git-wrapper")
            let script = """
            #!/bin/sh
            operation=
            for argument in "$@"; do
              case "$argument" in fetch|pull|push|ls-remote) operation="$argument";; esac
            done
            if [ -n "$operation" ]; then
              # Refuse before invoking ssh-add unless this is our private socket.
              case "${SSH_AUTH_SOCK:-}" in \(quote(root.path))/tg-agent-*/s) ;; *) exit 74;; esac
              [ -S "$SSH_AUTH_SOCK" ] || exit 75
              [ -z "${SSH_AGENT_PID:-}" ] || exit 78
              /usr/bin/ssh-add -L > "$0.public" || exit 76
              /usr/bin/grep -q transport-fixture "$0.public" || exit 77
              printf '%s\\n' "$operation" >> \(quote(root.appendingPathComponent("transport.log").path))
              if [ -f "$0.pause" ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.started"
                wait "$task_child"
              fi
            fi
            exec \(quote(git.path)) "$@"
            """
            try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755],ofItemAtPath: wrapper.path)
            return Fixture(root: root, key: key, realGit: git, agentHelper: agent, wrapper: wrapper, source: source, repo: GitRepository(root: consumer, executable: wrapper))
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func testFetchRebasePullAndBrowseReceiveLivePrivateAgentThenReleaseIt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("next\n".utf8).write(to: f.source.root.appendingPathComponent("file")); try await f.source.stage(["file"]); _ = try await f.source.commit(message: "next")
        let events = TransportEvents()
        let prepare: SSHTransportPreparation = { names, token in
            // Reenter the same repository actor during preparation: native grant
            // coordination must be able to read settings without deadlocking.
            _ = try await f.repo.remoteSettings(name: "origin", cancellation: token)
            let agent = try f.agent(token); await events.record(names, agent.directory); return agent
        }
        var fetch = FetchOptions(); fetch.remote = "origin"; fetch.branch = "main"
        _ = try await f.repo.fetch(fetch, prepareTransport: prepare)
        let branches = try await f.repo.remoteBranches(remote: "origin", prepareTransport: prepare); XCTAssertEqual(branches, ["main"])
        let target = try await f.repo.fetchForRebase(fetch, prepareTransport: prepare)
        let expected = try await f.source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(target.upstream, expected)
        var pull = PullOptions(); pull.fetch = fetch; pull.fastForwardOnly = true
        _ = try await f.repo.pull(pull, prepareTransport: prepare)
        let head = try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, expected)
        let recorded = await events.snapshot(); XCTAssertEqual(recorded.0, Array(repeating: ["origin"], count: 4)); XCTAssertTrue(recorded.1.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try String(contentsOf: f.log), "fetch\nls-remote\nfetch\npull\n")
        let pid = try XCTUnwrap(Int32(String(contentsOf: URL(fileURLWithPath: f.agentHelper.path+".pid")).trimmingCharacters(in: .newlines))); XCTAssertNotEqual(kill(pid,0),0)
    }
    func testFetchAllPreparesEveryRemoteOnceBeforeTransport() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.repo.run(["remote","add","second",f.source.root.path])
        let names = try await f.repo.remoteNames(), events = TransportEvents()
        var options = FetchOptions(); options.allRemotes = true
        _ = try await f.repo.fetch(options, prepareTransport: { supplied, token in let agent = try f.agent(token); await events.record(supplied, agent.directory); return agent })
        let recorded = await events.snapshot(); XCTAssertEqual(recorded.0, [names]); XCTAssertEqual(try String(contentsOf: f.log), "fetch\n"); XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.1[0].path))
        _ = try await f.repo.run(["show-ref","--verify","refs/remotes/second/main"])
    }
    func testPushPreparationFailurePreservesEarlierRemoteAndSkipsLaterOnes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var receivers: [GitRepository] = []
        _ = try await f.repo.run(["remote","rm","origin"])
        for name in ["a-good","z-denied","zz-never"] {
            let url = f.root.appendingPathComponent(name+".git"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let receiver = GitRepository(root: url, executable: f.realGit); _ = try await receiver.run(["init","--bare"]); receivers.append(receiver)
            _ = try await f.repo.run(["remote","add",name,url.path])
        }
        let first = receivers[0], events = TransportEvents()
        var options = PushOptions(); options.source = "refs/heads/main"; options.allRemotes = true
        do {
            _ = try await f.repo.push(options, prepareTransport: { names, token in
                if names == ["z-denied"] {
                    // The first remote must already be committed when the next
                    // preparation runs; do not preload all Push keys up front.
                    _ = try await first.run(["show-ref","--verify","refs/heads/main"])
                    await events.record(names, f.root); throw FixtureFailure.denied
                }
                let agent = try f.agent(token); await events.record(names, agent.directory); return agent
            }); XCTFail("Denied preparation continued")
        } catch let failure as PushExecutionFailure { XCTAssertEqual(failure.completed,["a-good"]); XCTAssertEqual(failure.failedRemote,"z-denied"); XCTAssertNil(failure.commandFailure) }
        let recorded = await events.snapshot(); XCTAssertEqual(recorded.0, [["a-good"],["z-denied"]]); XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.1[0].path)); XCTAssertEqual(try String(contentsOf: f.log), "push\n")
        for receiver in receivers.dropFirst() { let refs = try await receiver.checkoutReferences(); XCTAssertTrue(refs.isEmpty) }
    }
    func testAllBranchesAndTagsShareOnePreparationAndLiveSession() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("receiver.git"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let receiver = GitRepository(root: url, executable: f.realGit); _ = try await receiver.run(["init","--bare"])
        _ = try await f.repo.run(["remote","set-url","origin",url.path]); _ = try await f.repo.run(["tag","fixture-tag"])
        let events = TransportEvents(); var options = PushOptions(); options.remote = "origin"; options.allBranches = true; options.includeTags = true
        _ = try await f.repo.push(options, prepareTransport: { names, token in let agent = try f.agent(token); await events.record(names, agent.directory); return agent })
        let recorded = await events.snapshot(); XCTAssertEqual(recorded.0, [["origin"]]); XCTAssertEqual(try String(contentsOf: f.log), "push\npush\n"); XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.1[0].path))
        _ = try await receiver.run(["show-ref","--verify","refs/tags/fixture-tag"])
    }
    func testInvalidAndPreCanceledRequestsSkipPreparationAndLateCancelSkipsGit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let events = TransportEvents()
        let prepare: SSHTransportPreparation = { names, token in let agent = try f.agent(token); await events.record(names, agent.directory); return agent }
        var options = FetchOptions(); options.remote = "missing"
        do { _ = try await f.repo.fetch(options, prepareTransport: prepare); XCTFail("Invalid remote accepted") } catch FetchFailure.remote {}
        options.remote = "origin"; let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await f.repo.fetch(options, cancellation: cancelled, prepareTransport: prepare); XCTFail("Pre-cancel ran") } catch OperationCancellationFailure.cancelled {}
        let before = await events.snapshot(); XCTAssertTrue(before.0.isEmpty)
        do {
            _ = try await f.repo.fetch(options, prepareTransport: { names, token in let agent = try f.agent(token); await events.record(names, agent.directory); token.cancel(); return agent }); XCTFail("Late canceled preparation ran Git")
        } catch OperationCancellationFailure.cancelled {}
        let recorded = await events.snapshot(); XCTAssertEqual(recorded.0, [["origin"]]); XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.1[0].path)); XCTAssertFalse(FileManager.default.fileExists(atPath: f.log.path))
    }
    func testLiveTransportCancellationReapsGitChildrenAndAgent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data().write(to: URL(fileURLWithPath: f.wrapper.path+".pause"))
        let events = TransportEvents(), token = OperationCancellation(); var options = FetchOptions(); options.remote = "origin"
        let snapshot = options
        let task = Task {
            do { return Result<String,Error>.success(try await f.repo.fetch(snapshot, cancellation: token, prepareTransport: { names, token in let agent = try f.agent(token); await events.record(names, agent.directory); return agent })) }
            catch { return Result<String,Error>.failure(error) }
        }
        let marker = URL(fileURLWithPath: f.wrapper.path+".started")
        for _ in 0..<500 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }; XCTAssertEqual(ids.count,2); XCTAssertTrue(ids.allSatisfy { kill($0,0)==0 })
        let agentPID = try XCTUnwrap(Int32(String(contentsOf: URL(fileURLWithPath: f.agentHelper.path+".pid")).trimmingCharacters(in: .newlines))); XCTAssertEqual(kill(agentPID,0),0)
        token.cancel(); let result = await task.value; if case .success = result { XCTFail("Canceled live transport succeeded") }
        XCTAssertTrue(ids.allSatisfy { kill($0,0) != 0 }); XCTAssertNotEqual(kill(agentPID,0),0)
        let recorded = await events.snapshot(); XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.1[0].path))
    }
}
