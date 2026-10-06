import XCTest
@testable import TurtleGitCore

final class IssueTrackerTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func testFieldDefaultsNumericValidationAndTemplateExtraction() throws {
        let empty = IssueTrackerProperties()
        XCTAssertFalse(empty.showsIssueField); XCTAssertTrue(empty.numbersOnly); XCTAssertTrue(empty.append)
        XCTAssertTrue(empty.validatesIssueID(" 1, 22 ")); XCTAssertFalse(empty.validatesIssueID("١")); XCTAssertFalse(empty.validatesIssueID("1\t2"))
        let properties = IssueTrackerProperties(values: ["bugtraq.message": "Issues: %BUGID%.", "bugtraq.label": "Ticket:"])
        let separated = properties.separateIssueLine(from: "雪🦎 fix\n\nIssues: 42,73.\n\n")
        XCTAssertEqual(separated.message, "雪🦎 fix"); XCTAssertEqual(separated.issueID, "42,73")
        XCTAssertEqual(try properties.identifiers(in: "雪🦎 fix\nIssues: 42,73.\n"), ["42", "73"])
        XCTAssertEqual(properties.separateIssueLine(from: "Issues: 42.\n\nBody").message, "Body")
        XCTAssertEqual(properties.separateIssueLine(from: "Body\n").message, "Body")
        XCTAssertEqual(properties.separateIssueLine(from: "Body\r\n").message, "Body\r")
        XCTAssertEqual(properties.separateIssueLine(from: "Issues: 42.").issueID, "42")
        let prepended = IssueTrackerProperties(values: ["bugtraq.message": "Issue %BUGID%", "bugtraq.append": "false", "bugtraq.number": "false"])
        XCTAssertEqual(try prepended.prepareCommit(message: "Body", issueID: "ABC-42").message, "Issue ABC-42\nBody")
        XCTAssertEqual(prepended.separateIssueLine(from: "Issue ABC-42\nBody").message, "Body")
        XCTAssertEqual(properties.label, "Ticket:")
    }
    func testLogColumnVisibilityExtractionOrderingAndInvalidRegex() throws {
        XCTAssertFalse(IssueTrackerProperties().showsBugIDColumn)
        XCTAssertFalse(IssueTrackerProperties(values: ["bugtraq.message": "Issue %BUGID%"]).showsBugIDColumn)
        XCTAssertTrue(IssueTrackerProperties(values: ["bugtraq.url": "https://example.invalid/%BUGID%"]).showsBugIDColumn)
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "issue #(\\d+)"])
        XCTAssertTrue(properties.showsBugIDColumn)
        XCTAssertEqual(try properties.logIssueIDs(in: "issue #100 issue #2 issue #2", executable: parser), "2 100")
        let invalid = IssueTrackerProperties(values: ["bugtraq.logregex": "(?<=#)42"])
        XCTAssertEqual(try invalid.logIssueIDs(in: "#42", executable: parser), "")
        XCTAssertThrowsError(try invalid.identifiers(in: "#42", executable: parser))
        let stopped = OperationCancellation(); stopped.cancel()
        XCTAssertThrowsError(try properties.logIssueIDs(in: "issue #2", executable: parser, cancellation: stopped)) { XCTAssertTrue($0 is OperationCancellationFailure) }
    }
    func testWarningsDuplicateComparisonAndURLComponentEscaping() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.message": "Issue %BUGID%", "bugtraq.warnifnoissue": "true", "bugtraq.logregex": " issues (\\d+) \n (\\d+) ", "bugtraq.url": "https://example.invalid/%BUGID%"])
        XCTAssertEqual(properties.checkExpression, "issues (\\d+)"); XCTAssertEqual(properties.extractionExpression, "(\\d+)")
        let crlf = IssueTrackerProperties(values: ["bugtraq.logregex": "(\\d+)\r\n#\\d+"])
        XCTAssertEqual(crlf.checkExpression, "(\\d+)"); XCTAssertEqual(crlf.extractionExpression, "#\\d+")
        XCTAssertFalse(try properties.prepareCommit(message: "issues 42", issueID: "", executable: parser).requiresIssueWarning)
        XCTAssertTrue(try properties.prepareCommit(message: "Body", issueID: "", executable: parser).requiresIssueWarning)
        XCTAssertFalse(try properties.prepareCommit(message: "Body", issueID: " ", executable: parser).requiresIssueWarning)
        XCTAssertEqual(try properties.prepareCommit(message: "issues 42", issueID: "42", executable: parser).message, "issues 42")
        XCTAssertEqual(try properties.prepareCommit(message: "Body", issueID: " 42 , 73 ", executable: parser).message, "Body\nIssue 42,73\n")
        XCTAssertEqual(properties.issueURL(for: "雪 #%/ä"), "https://example.invalid/%E9%9B%AA%20%23%25%2F%C3%A4")
        XCTAssertThrowsError(try properties.prepareCommit(message: "Body", issueID: "42x", executable: parser))
        let simple = IssueTrackerProperties(values: ["bugtraq.message": "Issue %BUGID%", "bugtraq.warnifnoissue": "true"])
        XCTAssertTrue(try simple.prepareCommit(message: "Issue 42", issueID: "").requiresIssueWarning)
        let captureless = IssueTrackerProperties(values: ["bugtraq.warnifnoissue": "true", "bugtraq.logregex": "ID-[0-9]+"])
        XCTAssertFalse(try captureless.prepareCommit(message: "ID-42", issueID: "", executable: parser).requiresIssueWarning)
    }
    func testProjectPrecedenceIncludesAndReadOnlyPreparation() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system.config"), global = root.appendingPathComponent("global.config")
        try "[bugtraq]\nlabel = System\nnumber = false\n".write(to: system, atomically: true, encoding: .utf8)
        try "[bugtraq]\nlabel = Global\nmessage = Global %BUGID%\n".write(to: global, atomically: true, encoding: .utf8)
        try helper.write(root, ".tgitconfig", "[include]\npath = issue.config\n[bugtraq]\nmessage = Issue %BUGID%\nappend = false\nwarnifnoissue\n[tgit]\nwarnnosignedoffby = true\n")
        try helper.write(root, "issue.config", "[bugtraq]\nlabel = Project\nnumber = true\n")
        let environment = ["GIT_CONFIG_SYSTEM": system.path, "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "0", "GIT_CONFIG_COUNT": "0"]
        var properties = try await repo.issueTrackerProperties(environmentOverrides: environment)
        XCTAssertEqual(properties.label, "Project"); XCTAssertEqual(properties.messageTemplate, "Issue %BUGID%")
        XCTAssertTrue(properties.numbersOnly); XCTAssertTrue(properties.warnIfNoIssue); XCTAssertTrue(properties.warnNoSignedOffBy); XCTAssertFalse(properties.append)
        _ = try await repo.run(["config", "bugtraq.label", "Local"])
        _ = try await repo.run(["config", "bugtraq.warnifnoissue", "false"])
        properties = try await repo.issueTrackerProperties(environmentOverrides: environment)
        XCTAssertEqual(properties.label, "Local"); XCTAssertFalse(properties.warnIfNoIssue)
        try helper.write(root, "tracked.txt", "base\n"); try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "tracked.txt", "staged\n"); try await repo.stage(["tracked.txt"]); try helper.write(root, "tracked.txt", "working\n")
        let indexURL = root.appendingPathComponent(".git/index"), beforeIndex = try Data(contentsOf: indexURL)
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let result = try properties.prepareCommit(message: "Body", issueID: "42")
        XCTAssertEqual(result.message, "Issue 42\nBody")
        XCTAssertEqual(try Data(contentsOf: indexURL), beforeIndex)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(head, afterHead); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8), "working\n")
    }
    func testBareAndLinkedWorktreeProjectConfiguration() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        let bare = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bare); try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        try helper.write(root, ".tgitconfig", "[bugtraq]\nlabel = Tracked\nmessage = Issue %BUGID%\n")
        try await repo.stage([".tgitconfig"]); _ = try await repo.commit(message: "config")
        _ = try await repo.run(["clone", "--bare", root.path, bare.path])
        let bareProperties = try await GitRepository(root: bare).issueTrackerProperties()
        XCTAssertEqual(bareProperties.label, "Tracked")
        _ = try await repo.run(["worktree", "add", "-b", "issue-worktree", linked.path])
        try helper.write(linked, ".tgitconfig", "[bugtraq]\nlabel = Linked\nmessage = Task %BUGID%\n")
        _ = try await repo.run(["config", "bugtraq.number", "false"])
        let linkedProperties = try await GitRepository(root: linked).issueTrackerProperties()
        XCTAssertEqual(linkedProperties.label, "Linked"); XCTAssertFalse(linkedProperties.numbersOnly)
    }
    func testSignOffPlacementUsesExistingTrailerAndExactIdentity() {
        let line = "Signed-off-by: Test <test@example.invalid>"
        XCTAssertEqual(IssueTrackerProperties.addingSignOff(line, to: "Body\n\n"), "Body\n\n" + line + "\n")
        XCTAssertEqual(IssueTrackerProperties.addingSignOff(line, to: "Body\nReviewed-by: Another <a@example.invalid>\n"), "Body\nReviewed-by: Another <a@example.invalid>\n" + line + "\n")
        XCTAssertEqual(IssueTrackerProperties.addingSignOff(line, to: "Body\n" + line), "Body\n" + line)
    }
}
