import XCTest
@testable import TurtleGitCore

final class IssueMessageStyleTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func testUTF8StylingMapsEmojiOffsetsAndStylesOnlyCaptureOne() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "issue #(\\d+)", "bugtraq.url": "https://example.invalid/tickets/%BUGID%"])
        let message = "🦎 issue #42 after"
        let styles = try properties.messageStyles(in: message, executable: parser)
        XCTAssertEqual(styles.map(\.kind), [.context, .identifier])
        XCTAssertEqual(styles.map(\.range), [NSRange(location: 3, length: 7), NSRange(location: 10, length: 2)])
        XCTAssertNil(styles[0].url); XCTAssertEqual(styles[1].url, "https://example.invalid/tickets/42")
        let captureless = IssueTrackerProperties(values: ["bugtraq.logregex": "issue #\\d+"])
        XCTAssertTrue(try captureless.messageStyles(in: message, executable: parser).isEmpty)
    }
    func testTwoExpressionStylesContextAndCompleteInnerMatch() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "issues.*\n#(\\d+)", "bugtraq.url": "https://example.invalid/%BUGID%"])
        let message = "雪🦎 issues #42 and #73 done"
        let styles = try properties.messageStyles(in: message, executable: parser)
        XCTAssertEqual(styles.map(\.kind), [.context, .identifier, .context, .identifier, .context])
        XCTAssertEqual(styles.map { (message as NSString).substring(with: $0.range) }, ["issues ", "#42", " and ", "#73", " done"])
        XCTAssertEqual(styles[1].url, "https://example.invalid/%2342")
        XCTAssertEqual(styles[3].url, "https://example.invalid/%2373")
    }
    func testByteRegexDiffersFromValidationAndAdjacentHotspotsMerge() throws {
        let splitScalar = IssueTrackerProperties(values: ["bugtraq.logregex": "(.{2})"])
        XCTAssertEqual(try splitScalar.identifiers(in: "🦎", executable: parser), ["🦎"])
        XCTAssertTrue(try splitScalar.messageStyles(in: "🦎", executable: parser).isEmpty)
        let literal = IssueTrackerProperties(values: ["bugtraq.logregex": "(雪)"])
        XCTAssertEqual(try literal.messageStyles(in: "🦎雪", executable: parser).map(\.range), [NSRange(location: 2, length: 1)])
        let adjacent = IssueTrackerProperties(values: ["bugtraq.logregex": "(\\d)", "bugtraq.url": "https://example.invalid/%BUGID%"])
        let styles = try adjacent.messageStyles(in: "42", executable: parser)
        XCTAssertEqual(styles.count, 1); XCTAssertEqual(styles[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(styles[0].url, "https://example.invalid/42")
    }
    func testHistoryFieldUsesWideMatchingNaturalOrderAndTemplateFallback() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.message": "Refs: %BUGID%", "bugtraq.logregex": "Refs: (\\d+)"])
        XCTAssertEqual(try properties.issueFieldValue(in: "Refs: 73\nRefs: 42\nRefs: 73", executable: parser), "42 73")
        XCTAssertEqual(try properties.issueFieldValue(in: "No issue", executable: parser), "")
        let simple = IssueTrackerProperties(values: ["bugtraq.message": "Refs: %BUGID%"])
        XCTAssertEqual(try simple.issueFieldValue(in: "Body\nRefs: 73,42", executable: parser), "42 73")
    }
}
