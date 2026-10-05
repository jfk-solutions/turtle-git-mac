import XCTest
@testable import TurtleGitCore

final class MessageFormattingTests: XCTestCase {
    func testMarkerContentsAndWordBoundaries() throws {
        let message = "*bold* ^italic^ _underlined_ word_inside_name x*not bold* * space* *end *"
        let styles = try IssueTrackerProperties().messageStyles(in: message)
        XCTAssertEqual(styles.map(\.kind), [.bold, .italic, .underlined])
        XCTAssertEqual(styles.map { (message as NSString).substring(with: $0.range) }, ["bold", "italic", "underlined"])
        XCTAssertTrue(styles.allSatisfy { $0.url == nil })
    }
    func testNestedPassesOverwriteRatherThanCombineTraits() throws {
        let message = "*bold ^italic _under_ end^ bold*"
        let styles = try IssueTrackerProperties().messageStyles(in: message)
        XCTAssertEqual(styles.map(\.kind), [.bold, .italic, .underlined, .italic, .bold])
        XCTAssertEqual(styles.map { (message as NSString).substring(with: $0.range) }, ["bold ^", "italic _", "under", "_ end", "^ bold"])
    }
    func testLineBoundariesBMPAndSupplementarySourceQuirk() throws {
        let message = "*one\n two*\r\n雪 *标题*\n🦎 *bold*\n*reset*"
        let styles = try IssueTrackerProperties().messageStyles(in: message)
        XCTAssertEqual(styles.map { (message as NSString).substring(with: $0.range) }, ["标题", "reset"])
        XCTAssertTrue(styles.allSatisfy { $0.kind == .bold })
        XCTAssertTrue(try IssueTrackerProperties().messageStyles(in: "*before\0after*").isEmpty)
    }
    func testPreferenceAndIssueFormattingURLPrecedence() throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "(.*)", "bugtraq.url": "https://tracker.invalid/%BUGID%"])
        let message = "*bold* ^https://example.invalid^"
        let styles = try properties.messageStyles(in: message, executable: executable)
        XCTAssertEqual(styles.map(\.kind), [.identifier, .bold, .identifier, .url, .identifier])
        XCTAssertEqual(styles[1].url, nil); XCTAssertEqual(styles[3].url, "https://example.invalid")
        let disabled = try properties.messageStyles(in: message, executable: executable, formattingEnabled: false)
        XCTAssertEqual(disabled.map(\.kind), [.identifier, .url, .identifier])
        XCTAssertEqual(try IssueTrackerProperties().messageStyles(in: "*bold* https://example.invalid", formattingEnabled: false).map(\.kind), [.url])
    }
}
