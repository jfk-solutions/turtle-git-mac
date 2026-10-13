import XCTest
@testable import TurtleGitCore

final class WorkingCopyRevisionTests: XCTestCase {
    func testCompleteKeywordsDatesNumbersAndMalformedTokens() {
        var value = WorkingCopyRevision(); value.revision = String(repeating: "a", count: 40); value.branch = "topic/雪"; value.authorTime = 0; value.commitCount = 258
        value.fileModifications = true; value.tagged = true; value.versioned = true
        let source = "$WCREV$|$WCREV=7$|$WCREV=0x4$|$WCBRANCH$|$WCLOGCOUNT$|$WCLOGCOUNT&0xff$|$WCLOGCOUNT+100$|$WCLOGCOUNT-300$|$WCDATEUTC$|$WCNOWUTC=%Y$|$WCDATE=$|$WCDATE=%q$"
        let output = String(decoding: WorkingCopyRevisionTemplate.expand(Data(source.utf8), revision: value, now: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        XCTAssertEqual(output, String(repeating: "a", count: 40) + "|aaaaaaa|aaaa|topic/雪|258|2|358|-42|1970/01/01 00:00:00|1970||Invalid Time Format Specified")
        for (key, condition) in value.conditions {
            let template = "$\(key)?yes:no$"
            XCTAssertEqual(String(decoding: WorkingCopyRevisionTemplate.expand(Data(template.utf8), revision: value), as: UTF8.self), condition ? "yes" : "no", key)
        }
        let malformed = "$UNKNOWN$|$WCMODS?no colon$|$WCREV="
        XCTAssertEqual(WorkingCopyRevisionTemplate.expand(Data(malformed.utf8), revision: value), Data(malformed.utf8))
        let long = "$WCREV=" + String(repeating: "1", count: 1025) + "$"
        XCTAssertEqual(WorkingCopyRevisionTemplate.expand(Data(long.utf8), revision: value), Data(long.utf8))
    }
    func testBinaryLegacyAndWideTemplatesPreserveUnrelatedBytes() throws {
        var value = WorkingCopyRevision(); value.branch = "雪"; value.versioned = true
        let binary = Data([0xff,0,0x81]) + Data("$WCREV=2$".utf8) + Data([0xfe])
        XCTAssertEqual(WorkingCopyRevisionTemplate.expand(binary, revision: value), Data([0xff,0,0x81,48,48,0xfe]))
        let legacy = Data("$WCINGIT?".utf8) + Data([0xe9]) + Data(":no$".utf8)
        XCTAssertEqual(WorkingCopyRevisionTemplate.expand(legacy, revision: value), Data([0xe9]))
        for (encoding, bom) in [(String.Encoding.utf16LittleEndian, Data([255,254])), (.utf16BigEndian, Data([254,255]))] {
            let template = "// 雪\r\n$WCBRANCH$ $WCINGIT?é:ø$\r\n"
            let input = bom + template.data(using: encoding)!
            XCTAssertEqual(WorkingCopyRevisionTemplate.expand(input, revision: value), bom + "// 雪\r\n雪 é\r\n".data(using: encoding)!)
        }
        let plainWide = "// template\n$WCREV=2$".data(using: .utf16LittleEndian)!
        XCTAssertEqual(WorkingCopyRevisionTemplate.expand(plainWide, revision: value), "// template\n00".data(using: .utf16LittleEndian)!)
    }
    func testRepositoryScopeStagedAddsIgnoreFileTagsDetachedAndReadOnly() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertTrue(initial.versioned); XCTAssertFalse(initial.unborn); XCTAssertGreaterThan(initial.commitCount, 0)
        _ = try await repo.run(["tag", "-a", "build-tag", "-m", "Version"])
        let tracked = root.appendingPathComponent(path)
        try Data("changed\n".utf8).write(to: tracked)
        try Data("new\n".utf8).write(to: root.appendingPathComponent("new file")); try await repo.stage(["new file"])
        try Data("noise\n".utf8).write(to: root.appendingPathComponent("ignored-output"))
        try Data("ignored-output\n.GitWCRevignore\n".utf8).write(to: root.appendingPathComponent(".GitWCRevignore"))
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let all = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertTrue(all.fileModifications && all.unversioned && all.tagged)
        let one = try await WorkingCopyRevisionReader.read(path: tracked)
        XCTAssertTrue(one.fileModifications && one.versioned); XCTAssertFalse(one.unversioned)
        let added = try await WorkingCopyRevisionReader.read(path: root.appendingPathComponent("new file"))
        XCTAssertFalse(added.versioned); XCTAssertTrue(added.unversioned)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        _ = try await repo.run(["checkout", "--detach", "HEAD"])
        let detached = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertEqual(detached.branch, detached.revision); XCTAssertFalse(detached.unversioned)
        let detachedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), detachedIndex)
    }
    func testUnbornDirectoryScopeAndMissingPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root); _ = try await repo.run(["init", "-b", "empty"])
        let directory = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: directory.appendingPathComponent("untracked"))
        let value = try await WorkingCopyRevisionReader.read(path: directory)
        XCTAssertTrue(value.unborn && value.unversioned); XCTAssertFalse(value.versioned)
        XCTAssertEqual(value.branch, "empty"); XCTAssertEqual(value.commitCount, 0)
        do { _ = try await WorkingCopyRevisionReader.read(path: root.appendingPathComponent("missing")); XCTFail() }
        catch let error as WorkingCopyRevisionFailure { XCTAssertEqual(error.exitCode, 2) }
    }
    func testSubmoduleStatusPrecedenceAndSkip() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        let (child, _, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: child) }
        _ = try await repo.run(["-c", "protocol.file.allow=always", "submodule", "add", child.path, "module"])
        _ = try await repo.commit(message: "Submodule")
        let module = root.appendingPathComponent("module"), moduleRepo = GitRepository(root: module)
        let clean = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertFalse(clean.hasSubmodule) // source visits only changed status entries
        try Data("dirty".utf8).write(to: module.appendingPathComponent(path))
        try Data("new".utf8).write(to: module.appendingPathComponent("untracked"))
        let dirty = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertTrue(dirty.hasSubmodule && dirty.submoduleModifications); XCTAssertFalse(dirty.submoduleUnversioned)
        let skip = try await WorkingCopyRevisionReader.read(path: root, skipSubmodules: true)
        XCTAssertFalse(skip.hasSubmodule || skip.fileModifications || skip.unversioned)
        _ = try await moduleRepo.run(["checkout", "--", path])
        let untracked = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertTrue(untracked.submoduleUnversioned); XCTAssertTrue(untracked.conditions["WCMODSFULL"] == true)
        // Advance the checked-out child HEAD, keeping its untracked file.
        for (key, val) in [("user.name", "WCRev"), ("user.email", "wcrev@example.invalid")] { _ = try await moduleRepo.run(["config", key, val]) }
        try Data("new child commit\n".utf8).write(to: module.appendingPathComponent(path))
        try await moduleRepo.stage([path]); _ = try await moduleRepo.commit(message: "Advance child")
        let moved = try await WorkingCopyRevisionReader.read(path: root)
        XCTAssertTrue(moved.hasSubmodule && moved.submoduleNewCommits)
        XCTAssertFalse(moved.submoduleModifications || moved.submoduleUnversioned)
        XCTAssertTrue(moved.conditions["WCMODS"] == true)
        XCTAssertTrue(moved.conditions["WCMODSFULL"] == false)
    }
}
