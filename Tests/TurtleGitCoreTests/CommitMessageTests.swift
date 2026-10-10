import XCTest
@testable import TurtleGitCore

final class CommitMessageTests: XCTestCase {
    func testSourceEncodingAliasesAndNativeBytes() throws {
        XCTAssertEqual(CommitMessageEncoding.aliases.count, 156)
        XCTAssertEqual(CommitMessageEncoding.codePage("WINDOWS-1252"), 1252)
        XCTAssertEqual(CommitMessageEncoding.codePage("EUC-JP"), 20932, "First duplicate wins")
        XCTAssertEqual(CommitMessageEncoding.codePage("Arabic"), 709)
        XCTAssertEqual(CommitMessageEncoding.codePage(""), 65001)
        XCTAssertEqual(CommitMessageEncoding.codePage("cp1252"), 65001, "Unlisted source alias uses UTF-8")
        XCTAssertEqual(try CommitMessageEncoding.encode("café €\n", name: "windows-1252"), Data([0x63,0x61,0x66,0xe9,0x20,0x80,0x0a]))
        XCTAssertEqual(try CommitMessageEncoding.encode("café\n", name: "iso-8859-1"), Data([0x63,0x61,0x66,0xe9,0x0a]))
        XCTAssertEqual(try CommitMessageEncoding.encode("Привет\n", name: "cp1251"), Data([0xcf,0xf0,0xe8,0xe2,0xe5,0xf2,0x0a]))
        XCTAssertEqual(try CommitMessageEncoding.encode("日本\n", name: "shift_jis"), Data([0x93,0xfa,0x96,0x7b,0x0a]))
        XCTAssertEqual(try CommitMessageEncoding.encode("雪\n", name: "unrecognized"), Data("雪\n".utf8))
        XCTAssertEqual(try CommitMessageEncoding.encode("雪\n", name: "windows-1252"), Data([0x3f,0x0a]))
        XCTAssertThrowsError(try CommitMessageEncoding.encode("title", name: "utf-16"))
    }
    func testEncodedMessageFilesProtectPermissionsAndCleanUp() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "i18n.commitencoding", "windows-1252"])
        let file = try await repo.makeCommitMessageFile("café\n")
        XCTAssertEqual(try Data(contentsOf: file.url), Data([0x63,0x61,0x66,0xe9,0x0a]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        file.remove(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
    }

    func testMessageFileFormattingMatchesSourceWhitespaceAndDraftMutation() {
        let raw = " \r\nTitle   \r\n\r\n\r\nBody \t \r\n\r\n "
        let result = CommitMessageFile.format(raw)
        XCTAssertEqual(result.draft, "Title   \r\n\r\n\r\nBody \t")
        XCTAssertEqual(result.contents, "Title\n\nBody \t\n")
        XCTAssertEqual(CommitMessageFile.format("a\n\n").contents, "a\n")
        XCTAssertEqual(CommitMessageFile.format("a\n\n", sanitize: false).contents, "a\n\n")
        XCTAssertEqual(CommitMessageFile.format(" \n", sanitize: false).contents, "\n")
        XCTAssertEqual(CommitMessageFile.format("a\n ", sanitize: false).contents, "a\n\n")
        XCTAssertEqual(CommitMessageFile.format("\t", sanitize: true).contents, "\t\n")
        XCTAssertEqual(CommitMessageFile.format("\n\n").contents, "")
        XCTAssertEqual(CommitMessageFile.format("").contents, "")
        XCTAssertEqual(CommitMessageFile.format("雪\u{00A0}  ").contents, "雪\u{00A0}\n")
    }
    func testMessageFileCommentPrefixOrderAndOrdinalUTF16() {
        let raw = " # first\nTitle\n # indented\n# hidden\n\t# tab\nBody\n"
        let result = CommitMessageFile.format(raw, stripComments: true)
        XCTAssertEqual(result.contents, "Title\n # indented\n\t# tab\nBody\n")
        XCTAssertTrue(result.draft.contains("# hidden"), "History draft must retain stripped comments")
        XCTAssertEqual(CommitMessageFile.format("Title\n# keep", stripComments: false).contents, "Title\n# keep\n")
        XCTAssertEqual(CommitMessageFile.format("Title\n; drop\n# keep", stripComments: true, commentPrefix: ";").contents, "Title\n# keep\n")
        XCTAssertEqual(CommitMessageFile.format("Title\n## drop\n# keep", stripComments: true, commentPrefix: "##").contents, "Title\n# keep\n")
        XCTAssertEqual(CommitMessageFile.format("# only", stripComments: true, commentPrefix: "").contents, "")
        XCTAssertEqual(CommitMessageFile.format("auto drop\n# keep", stripComments: true, commentPrefix: "auto").contents, "# keep\n", "Upstream treats auto as a literal prefix")
        let ordinal = CommitMessageFile.format("e\u{0301} keep\né drop", stripComments: true, commentPrefix: "é").contents
        XCTAssertEqual(Data(ordinal.utf8), Data("e\u{0301} keep\n".utf8))
    }
    func testConfiguredCommentPrefixAndConflictHintExemptionAreReadOnly() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "core.commentchar", ";"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let result = try await repo.prepareCommitMessageFile("Title\n; drop\n# retain", stripComments: true)
        XCTAssertEqual(result.contents, "Title\n# retain\n")
        let exempt = try await repo.rebaseMessageContainsConflictHints("Title\n; Conflicts:\n;\tfile", stripComments: true)
        XCTAssertFalse(exempt)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }

    func testTemplateAndOperationMessagesAppendWithoutChangingRepository() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "template 雪.txt", "Subject\r\n\r\nBody\r\n\r\n")
        _ = try await repo.run(["config", "commit.template", "template 雪.txt"])
        try helper.write(root, ".git/SQUASH_MSG", "Squash\r\n")
        try helper.write(root, ".git/MERGE_MSG", "Merge\n\n")
        try helper.write(root, "tracked.txt", "staged\n"); try await repo.stage(["tracked.txt"])
        try helper.write(root, "tracked.txt", "working\n")
        let before = try await repo.status(), index = try await repo.diff(staged: true), working = try await repo.diff()
        let seed = try await repo.commitMessageSeed()
        XCTAssertEqual(seed.template, "Subject\n\nBody\n")
        XCTAssertEqual(seed.message, "Subject\n\nBody\nSquash\nMerge\n")
        XCTAssertTrue(seed.warnings.isEmpty)
        let recommit = try await repo.commitMessageSeed(includeOperationMessages: false)
        XCTAssertEqual(recommit.message, seed.template)
        let after = try await repo.status(), afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(before.map(\.path), after.map(\.path)); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }

    func testRepairedUTF8TemplateAndOperationMessagesPreserveAllInputs() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "base.txt", "base\n"); try await repo.stage(["base.txt"]); _ = try await repo.commit(message: "base")
        let template = root.appendingPathComponent("template 雪.txt"), squash = root.appendingPathComponent(".git/SQUASH_MSG"), merge = root.appendingPathComponent(".git/MERGE_MSG")
        var templateBytes = Data([0xef,0xbb,0xbf]); templateBytes.append(contentsOf: "Subject ".utf8); templateBytes.append(0xff)
        templateBytes.append(contentsOf: "\r\nBody".utf8); templateBytes.append(contentsOf: [0xe2,0x82]); templateBytes.append(contentsOf: "\r\n\r\n".utf8)
        var squashBytes = Data("Squash ".utf8); squashBytes.append(contentsOf: [0xc3,0x28]); squashBytes.append(contentsOf: "\r\n".utf8)
        var mergeBytes = Data([0x80]); mergeBytes.append(contentsOf: "Merge\r\n\r\n".utf8)
        try templateBytes.write(to: template); try squashBytes.write(to: squash); try mergeBytes.write(to: merge)
        _ = try await repo.run(["config", "commit.template", template.path])
        _ = try await repo.run(["config", "i18n.commitencoding", "windows-1252"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let seed = try await repo.commitMessageSeed()
        XCTAssertEqual(seed.template, "\u{FEFF}Subject �\nBody�\n")
        XCTAssertEqual(seed.message, "\u{FEFF}Subject �\nBody�\nSquash �(\n�Merge\n")
        XCTAssertTrue(seed.warnings.isEmpty)
        let recommit = try await repo.commitMessageSeed(includeOperationMessages: false)
        XCTAssertEqual(recommit.message, seed.template); XCTAssertTrue(recommit.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: template), templateBytes); XCTAssertEqual(try Data(contentsOf: squash), squashBytes); XCTAssertEqual(try Data(contentsOf: merge), mergeBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(afterHead, head)
        try Data().write(to: template)
        let empty = try await repo.commitMessageSeed(includeOperationMessages: false)
        XCTAssertEqual(empty.template, "\n"); XCTAssertEqual(empty.message, "\n"); XCTAssertTrue(empty.warnings.isEmpty)
    }

    func testAbsentAndUnreadableTemplateKeepOperationMessageAvailable() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = try await repo.commitMessageSeed()
        XCTAssertEqual(absent.message, ""); XCTAssertEqual(absent.template, ""); XCTAssertTrue(absent.warnings.isEmpty)
        _ = try await repo.run(["config", "commit.template", "missing.txt"])
        try helper.write(root, ".git/MERGE_MSG", "Merge draft\n")
        let missing = try await repo.commitMessageSeed()
        XCTAssertEqual(missing.template, ""); XCTAssertEqual(missing.message, "Merge draft\n")
        XCTAssertEqual(missing.warnings.count, 1); XCTAssertTrue(missing.warnings[0].contains("missing.txt"))
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent("invalid.txt"))
        _ = try await repo.run(["config", "commit.template", "invalid.txt"])
        let invalid = try await repo.commitMessageSeed()
        XCTAssertEqual(invalid.template, "\u{FFFD}\u{FFFD}\u{FFFD}\n")
        XCTAssertEqual(invalid.message, "\u{FFFD}\u{FFFD}\u{FFFD}\nMerge draft\n"); XCTAssertTrue(invalid.warnings.isEmpty)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("template-directory"), withIntermediateDirectories: false)
        _ = try await repo.run(["config", "commit.template", "template-directory"])
        let unreadable = try await repo.commitMessageSeed()
        XCTAssertEqual(unreadable.template, ""); XCTAssertEqual(unreadable.message, "Merge draft\n")
        XCTAssertEqual(unreadable.warnings.count, 1); XCTAssertTrue(unreadable.warnings[0].contains("template-directory"))
    }

    func testLinkedWorktreeReadsOwnMessagesAndAbsoluteTemplate() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        let worktree = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: worktree); try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "base.txt", "base\n"); try await repo.stage(["base.txt"]); _ = try await repo.commit(message: "base")
        let template = root.appendingPathComponent("template\n雪.txt")
        try Data("\u{FEFF}Template\n".utf8).write(to: template)
        _ = try await repo.run(["config", "commit.template", template.path])
        try helper.write(root, ".git/MERGE_MSG", "Main tree message\n")
        _ = try await repo.run(["worktree", "add", "-b", "linked", worktree.path])
        let linked = GitRepository(root: worktree)
        let mainIdentity = try await repo.commitMessageHistoryIdentity(), linkedIdentity = try await linked.commitMessageHistoryIdentity()
        XCTAssertEqual(mainIdentity, linkedIdentity)
        let admin = try await linked.run(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_MSG"]).text
        try Data("Linked tree message\n".utf8).write(to: URL(fileURLWithPath: String(admin.dropLast())))
        let seed = try await linked.commitMessageSeed()
        XCTAssertEqual(seed.message, "\u{FEFF}Template\nLinked tree message\n"); XCTAssertTrue(seed.warnings.isEmpty)
        let mainSeed = try await repo.commitMessageSeed()
        XCTAssertEqual(mainSeed.message, "\u{FEFF}Template\nMain tree message\n")
    }
}
