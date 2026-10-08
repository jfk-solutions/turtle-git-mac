import XCTest
@testable import TurtleGitCore

final class LFSLocksTests: XCTestCase {
    func testCLIArrayParsingEmptyIDsAndMalformedRecords() throws {
        let bytes = Data("[{\"id\":\"\"},{\"id\":\"42\",\"path\":\"雪\\t🦎.bin\",\"owner\":{\"name\":\"Jochen\"},\"locked_at\":\"ignored\"}]".utf8)
        XCTAssertEqual(try LFSLock.parse(bytes), [LFSLock(id: "42", path: "雪\t🦎.bin", owner: "Jochen")])
        XCTAssertEqual(try LFSLock.parse(Data()), [])
        for text in ["{}", "{\"locks\":[]}", "[{\"id\":\"1\",\"path\":2}]", "[{\"id\":\"1\",\"path\":\"x\",\"owner\":{}}]", "invalid"] {
            XCTAssertThrowsError(try LFSLock.parse(Data(text.utf8)))
        }
    }
    func fixture() async throws -> (URL, GitRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-lfs-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = GitRepository(root: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "LFS QA"]); _ = try await git.run(["config", "user.email", "qa@example.invalid"])
        _ = try await git.run(["config", "commit.gpgsign", "false"]); _ = try await git.run(["config", "core.hooksPath", "/dev/null"])
        try Data("original\n".utf8).write(to: root.appendingPathComponent("tracked")); try await git.stage(["tracked"]); _ = try await git.commit(message: "base")
        let wrapper = root.appendingPathComponent(".git/lfs-qa-git")
        let script = """
        #!/usr/bin/python3
        import sys,json,os,pathlib
        args=sys.argv[1:]; offset=args.index('-C'); root=pathlib.Path(args[offset+1]); command=args[offset+2:]
        if not command or command[0]!='lfs': os.execv('/usr/bin/git',['/usr/bin/git']+args)
        with (root/'.git/lfs-qa-arguments').open('a') as log: log.write(json.dumps(command)+'\\n')
        if command==['lfs','locks','--json']:
            print('[{"id":"7","path":"tracked","owner":{"name":"QA"}}]'); sys.exit(0)
        if command[-1]=='fail' and '--force' not in command:
            print('owned by another user',file=sys.stderr); sys.exit(1)
        print('Changed '+command[-1]); sys.exit(0)
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return (root, GitRepository(root: root, executable: wrapper), root.appendingPathComponent(".git/lfs-qa-arguments"))
    }
    func testLiteralCommandsContinuationForceAndRepositoryPreservation() async throws {
        let (root, repository, log) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeFile = try Data(contentsOf: root.appendingPathComponent("tracked"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let locks = try await repository.lfsLocks(); XCTAssertEqual(locks.first?.owner, "QA")
        let unusual = "-雪\t\n:(glob)*.bin"
        let batch = try await repository.setLFSLocked(paths: [unusual, "fail", "tracked", unusual], locked: false)
        XCTAssertEqual(batch.files.map(\.path), [unusual, "fail", "tracked"]); XCTAssertEqual(batch.files.map(\.success), [true, false, true]); XCTAssertFalse(batch.cancelled)
        let forced = try await repository.setLFSLocked(paths: ["fail"], locked: false, force: true); XCTAssertTrue(forced.files[0].success)
        _ = try await repository.setLFSLocked(paths: ["tracked"], locked: true, force: true)
        let commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(commands, [["lfs", "locks", "--json"], ["lfs", "unlock", "--", unusual], ["lfs", "unlock", "--", "fail"], ["lfs", "unlock", "--", "tracked"], ["lfs", "unlock", "--force", "--", "fail"], ["lfs", "lock", "--", "tracked"]])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeIndex); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tracked")), beforeFile)
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, afterHead)
    }
    func testCancellationBetweenFilesRetainsCompletedProgress() async throws {
        let (root, repository, log) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = OperationCancellation()
        let result = try await repository.setLFSLocked(paths: ["tracked", "never"], locked: false, cancellation: token, onResult: { _ in token.cancel() })
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.files.map(\.path), ["tracked"]); XCTAssertTrue(result.files[0].success)
        let commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 1); XCTAssertFalse(commands[0].contains("never"))
    }
    func testWholeSelectionPreflightAndPrecancelNeverInvokeLFS() async throws {
        let (root, repository, log) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for paths in [[String](), ["tracked", "../escape"], [".git/index"], ["/tmp/escape"], ["folder"], ["bad\0path"]] {
            do { _ = try await repository.setLFSLocked(paths: paths, locked: false); XCTFail("Invalid selection accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        }
        let cancellation = OperationCancellation(); cancellation.cancel()
        let cancelled = try await repository.setLFSLocked(paths: ["tracked"], locked: false, cancellation: cancellation)
        XCTAssertEqual(cancelled, LFSBatchResult(files: [], cancelled: true)); XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        let initial = try await repository.hasLFS(); XCTAssertFalse(initial)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let installed = try await repository.hasLFS(); XCTAssertTrue(installed)
    }
}
