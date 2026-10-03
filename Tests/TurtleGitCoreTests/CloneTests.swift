import XCTest
@testable import TurtleGitCore

final class CloneTests: XCTestCase {
    func fixture() async throws -> (URL, URL, GitRepository) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = parent.appendingPathComponent("source 雪.git")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let repo = GitRepository(root: source)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Clone Tests"])
        _ = try await repo.run(["config", "user.email", "clone@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "feature/review"])
        try Data("feature\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "feature")
        _ = try await repo.run(["checkout", "main"])
        return (parent, source, repo)
    }
    func testShallowSelectedBranchCustomOriginPreservesSource() async throws {
        let (parent, source, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let before = try await repo.run(["rev-parse", "HEAD"]).text
        let destination = parent.appendingPathComponent("nested/clone '雪'")
        let cwd = try CloneOptions.workingDirectory(for: destination)
        XCTAssertEqual(cwd.standardizedFileURL, parent.standardizedFileURL)
        var options = CloneOptions(); options.source = source.absoluteString; options.branch = "feature/review"; options.origin = "upstream"; options.depth = 1
        _ = try await GitRepository(root: cwd).clone(options, to: destination)
        let cloned = GitRepository(root: destination)
        let branch = try await cloned.branch(), count = try await cloned.run(["rev-list", "--count", "HEAD"]).text
        let shallow = try await cloned.run(["rev-parse", "--is-shallow-repository"]).text
        let remotes = try await cloned.remoteNames(), url = try await cloned.run(["remote", "get-url", "upstream"]).text
        let after = try await repo.run(["rev-parse", "HEAD"]).text, changes = try await repo.status()
        XCTAssertEqual(branch, "feature/review"); XCTAssertEqual(count, "1\n"); XCTAssertEqual(shallow, "true\n")
        XCTAssertEqual(remotes, ["upstream"]); XCTAssertEqual(url, source.absoluteString + "\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tracked.txt")), "feature\n")
        XCTAssertEqual(before, after); XCTAssertTrue(changes.isEmpty)
    }
    func testBareAndNoCheckoutHaveDifferentWorkingTreeAndIndexSemantics() async throws {
        let (parent, source, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let runner = GitRepository(root: parent)
        var options = CloneOptions(); options.source = source.path; options.bare = true
        let bare = parent.appendingPathComponent("bare.git"); _ = try await runner.clone(options, to: bare)
        let isBare = try await GitRepository(root: bare).run(["rev-parse", "--is-bare-repository"]).text
        let refs = try await GitRepository(root: bare).run(["show-ref"]).text
        XCTAssertEqual(isBare, "true\n"); XCTAssertTrue(refs.contains("refs/heads/feature/review"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent("tracked.txt").path))
        options.bare = false; options.noCheckout = true
        let empty = parent.appendingPathComponent("no checkout"); _ = try await runner.clone(options, to: empty)
        let index = try await GitRepository(root: empty).trackedPaths(), branch = try await GitRepository(root: empty).branch()
        XCTAssertTrue(index.isEmpty); XCTAssertEqual(branch, "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.appendingPathComponent("tracked.txt").path))
    }
    func testRecursiveInitializesSubmoduleUsingFixtureOnlyTransportPermission() async throws {
        let (parent, source, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("child")
        _ = try await GitRepository(root: parent).run(["clone", "--", source.path, child.path])
        _ = try await repo.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", child.path, "modules/child"])
        _ = try await repo.commit(message: "submodule")
        // Local-file submodules are allowed only by this disposable test executable.
        let wrapper = parent.appendingPathComponent("git-test")
        try Data("#!/bin/sh\nexec /usr/bin/git -c protocol.file.allow=always \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        var options = CloneOptions(); options.source = source.absoluteString; options.recursive = true
        let destination = parent.appendingPathComponent("recursive")
        _ = try await GitRepository(root: parent, executable: wrapper).clone(options, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("modules/child/tracked.txt")), "base\n")
        let status = try await GitRepository(root: destination).run(["submodule", "status"]).text
        XCTAssertTrue(status.hasPrefix(" ")); XCTAssertTrue(status.contains("modules/child"))
    }
    func testInvalidOptionsAndOccupiedDestinationPreserveUserFiles() async throws {
        let (parent, source, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let runner = GitRepository(root: parent), destination = parent.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent("keep.txt"); try Data("keep\n".utf8).write(to: file)
        var options = CloneOptions(); options.source = source.path
        do { _ = try await runner.clone(options, to: destination); XCTFail("Occupied destination accepted") } catch is GitFailure {}
        XCTAssertEqual(try String(contentsOf: file), "keep\n")
        let invalid = parent.appendingPathComponent("invalid")
        options.branch = "bad..branch"
        do { _ = try await runner.clone(options, to: invalid); XCTFail("Invalid branch accepted") } catch CloneFailure.value {}
        options.branch = nil; options.depth = 0
        do { _ = try await runner.clone(options, to: invalid); XCTFail("Invalid depth accepted") } catch CloneFailure.number {}
        options.depth = nil; options.bare = true; options.recursive = true
        do { _ = try await runner.clone(options, to: invalid); XCTFail("Invalid combination accepted") } catch CloneFailure.combination {}
        options = CloneOptions(); options.source = "invalid\0source"
        do { _ = try await runner.clone(options, to: invalid); XCTFail("NUL accepted") } catch CloneFailure.source {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
    }
    func testSSHConfigurationUsesLiteralKeyPathAndSVNArgumentsRetainOptions() async throws {
        let (parent, source, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        var options = CloneOptions(); options.source = source.path
        options.sshKey = parent.appendingPathComponent("key '$(touch sentinel)' 雪")
        let destination = parent.appendingPathComponent("with key")
        _ = try await GitRepository(root: parent).clone(options, to: destination)
        let config = try await GitRepository(root: destination).run(["config", "--get", "core.sshCommand"]).text
        XCTAssertEqual(config, try options.sshCommand()! + "\n")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.currentDirectoryURL = parent
        process.arguments = ["-c", "set -- " + (try options.sshCommand()!) + "; printf '%s\\0' \"$@\""]
        process.standardOutput = pipe; try process.run()
        let words = pipe.fileHandleForReading.readDataToEndOfFile().split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(words, ["ssh", "-i", options.sshKey!.path, "-o", "IdentitiesOnly=yes"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("sentinel").path))
        options = CloneOptions(); options.source = source.path; options.svn = true
        options.origin = ""; options.trunk = "trunk"; options.branches = "branches/*"; options.tags = "tags"; options.fromRevision = 7; options.username = "User 雪"
        XCTAssertEqual(try options.arguments(destination: destination), ["svn", "clone", "--prefix", "", "-T", "trunk", "-b", "branches/*", "-t", "tags", "-r", "7:HEAD", "--username", "User 雪", "--", source.absoluteString, destination.path])
    }
}
