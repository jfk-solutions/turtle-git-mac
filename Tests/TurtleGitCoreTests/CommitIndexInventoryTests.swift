import XCTest
@testable import TurtleGitCore

final class CommitIndexInventoryTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let (root, original) = try await CommitSelectionTests().fixture()
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path)
        return (root, GitRepository(root: root, executable: executable, libgit2Configuration: .init(enabled: false)))
    }
    private func capture(_ repo: GitRepository) throws -> (GitRepository, URL, URL) {
        let wrapper = repo.root.appendingPathComponent(".git/index-reader"), output = repo.root.appendingPathComponent(".git/index-output"), calls = repo.root.appendingPathComponent(".git/index-calls")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = ls-files ]; then
            printf 'call\\n' >> \(quote(calls.path))
            part=\(quote(output.path + ".part"))
            trap 'rm -f "$part"' EXIT
            \(quote(repo.executable.path)) "$@" > "$part"
            result=$?
            cat "$part" >> \(quote(output.path))
            cat "$part"
            exit "$result"
          fi
        done
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return (GitRepository(root: repo.root, executable: wrapper, libgit2Configuration: .init(enabled: false)), output, calls)
    }
    private func paths(_ output: URL) throws -> [Data] {
        try Data(contentsOf: output).split(separator: 0).map { record in
            guard let tab = record.firstIndex(of: 9) else { throw CommitDialogReadFailure.malformedIndex }
            return Data(record[record.index(after: tab)...])
        }
    }
    func testCapturedAndFallbackReadsExcludeUnrelatedCleanIndexRows() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let names = (0..<300).map { "clean-\($0)" } + [":changed[1]\n雪"]
        for name in names { try Data("base\n".utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(names); _ = try await repo.commit(message: "baseline")
        let changed = names.last!
        try Data("changed\n".utf8).write(to: root.appendingPathComponent(changed))
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let (reader, output, calls) = try capture(repo)
        let read = try await reader.commitDialogRead(amend: false, amendDiffToLastCommit: true)
        XCTAssertEqual(read.entries.map(\.path), [changed])
        XCTAssertEqual(try paths(output), [Data(changed.utf8)])
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "call\n")
        try FileManager.default.removeItem(at: output); try FileManager.default.removeItem(at: calls)
        let flags = try await reader.workingTreeIndexFlags(entries: read.entries)
        XCTAssertEqual(flags.map(\.id), [changed])
        XCTAssertEqual(try paths(output), [Data(changed.utf8)])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
    }
    func testCleanReadSkipsIndexInventoryAndPrecancelLaunchesNothing() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("clean"))
        try await repo.stage(["clean"]); _ = try await repo.commit(message: "baseline")
        let (reader, output, calls) = try capture(repo)
        let read = try await reader.commitDialogRead(amend: false, amendDiffToLastCommit: true)
        XCTAssertTrue(read.entries.isEmpty); XCTAssertTrue(read.indexFlags.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await reader.commitDisplayIndex(paths: ["clean"], cancellation: token); XCTFail("Precancelled index read launched") }
        catch OperationCancellationFailure.cancelled {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
        for path in ["/outside", "../outside", "folder/../outside", "bad\0name"] {
            do { _ = try await reader.commitDisplayIndex(paths: [path]); XCTFail("Invalid index path accepted") }
            catch CommitDialogReadFailure.malformedIndex {}
        }
        do { _ = try await reader.commitDisplayIndex(paths: ["clean"], argumentByteLimit: 1); XCTFail("Impossible argument budget accepted") }
        catch CommitDialogReadFailure.malformedIndex {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    }
    func testUntrackedEmbeddedRepositoryKeepsDirectoryRowWithoutIndexQuery() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("clean"))
        try await repo.stage(["clean"]); _ = try await repo.commit(message: "baseline")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let embedded = GitRepository(root: nested, executable: repo.executable, libgit2Configuration: .init(enabled: false))
        _ = try await embedded.run(["init", "-b", "main"])
        try Data("nested\n".utf8).write(to: nested.appendingPathComponent("file"))
        let (reader, output, calls) = try capture(repo)
        let read = try await reader.commitDialogRead(amend: false, amendDiffToLastCommit: true)
        XCTAssertTrue(read.entries.contains { $0.path == "nested/" && $0.state == .untracked })
        XCTAssertTrue(read.indexFlags.contains { $0.id == "nested/" && !$0.assumeUnchanged && !$0.skipWorktree })
        let fallback = try await reader.workingTreeIndexFlags(entries: read.entries)
        XCTAssertEqual(fallback.map(\.id), read.entries.map(\.path))
        XCTAssertTrue(fallback.allSatisfy { !$0.assumeUnchanged && !$0.skipWorktree })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    }
    func testIndexProjectionRejectsDirectoryDescendantsAndMalformedRecords() throws {
        let record = "H 100644 " + String(repeating: "1", count: 40) + " 0\tfolder/clean\0"
        let projected = try CommitDisplayIndex(Data(record.utf8), requested: ["folder"], cancellation: nil)
        XCTAssertTrue(projected.flags.isEmpty); XCTAssertTrue(projected.submodules.isEmpty)
        for invalid in [String(record.dropLast()), "H invalid\tfolder/clean\0"] {
            XCTAssertThrowsError(try CommitDisplayIndex(Data(invalid.utf8), requested: ["folder"], cancellation: nil))
        }
    }
    func testBoundedInventoryKeepsExactByteNamesAndDeduplicatesCandidates() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "core.precomposeunicode", "false"])
        _ = try await repo.run(["config", "core.ignorecase", "false"])
        let names = (0..<40).map { "candidate-\($0)-" + String(repeating: "x", count: 30) } + ["Case", "case", "Caf\u{e9}", "Cafe\u{301}", ":literal*\t\n"]
        let blob = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("base\n".utf8)).text.trimmingCharacters(in: .newlines)
        let packet = Data(names.flatMap { Array(("100644 " + blob + "\t" + $0).utf8) + [0] })
        _ = try await repo.run(["update-index", "-z", "--index-info"], input: packet)
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let (reader, output, calls) = try capture(repo)
        let inventory = try await reader.commitDisplayIndex(paths: names + [names[0]], argumentByteLimit: 1024)
        XCTAssertEqual(Set(inventory.flags.keys.map { Data($0.utf8) }), Set(names.map { Data($0.utf8) }))
        XCTAssertEqual(Set(try paths(output)), Set(names.map { Data($0.utf8) }))
        XCTAssertEqual(try paths(output).count, names.count)
        XCTAssertGreaterThan(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
    }
}
