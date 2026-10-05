import XCTest
@testable import TurtleGitCore

final class MessageURLFinderTests: XCTestCase {
    func testPinnedUpstreamURLFixtures() {
        XCTAssertTrue(MessageURLFinder.ranges(in: "").isEmpty)
        XCTAssertEqual(MessageURLFinder.ranges(in: "https://tortoisegit.org"), [NSRange(location: 0, length: 23)])
        let first = "here https://user:pw@tortoisegit.org/~user/file_name-123.html?param=val+ue&another=val%20ue2#anchor more http:// text mailto:local_part@sub-domain.example.com text mail@example.com separator text file://c:some/path text"
        XCTAssertEqual(MessageURLFinder.ranges(in: first), [NSRange(location: 5, length: 94), NSRange(location: 118, length: 40), NSRange(location: 164, length: 16), NSRange(location: 196, length: 18)])
        let second = "here <https://tortoisegit.org?param=val ue> text http://tortoisegit.org? text <http://tortoisegit.org?> text https://example.com/;sesionid=747re7fucbd text ftp://example.com/some!string text \\unc\\path\\somewhere text"
        XCTAssertEqual(MessageURLFinder.ranges(in: second), [NSRange(location: 6, length: 36), NSRange(location: 49, length: 22), NSRange(location: 79, length: 23), NSRange(location: 109, length: 41), NSRange(location: 156, length: 29)])
    }
    func testUpstreamDelimitersCaseAndEmailGates() {
        let message = "git@example.com:repo git://example.com/repo ftp://example.com! file:///tmp/example mail@example.com @example.com me@.com me@example me@example. HTTP://example.com custom://example.com http:// mailto:"
        let ranges = MessageURLFinder.ranges(in: message)
        let values = ranges.map { (message as NSString).substring(with: $0) }
        XCTAssertEqual(values, ["git://example.com/repo", "ftp://example.com", "file:///tmp/example", "mail@example.com"])
        XCTAssertEqual(MessageURLFinder.target(for: values[3]), "mailto:mail@example.com")
        XCTAssertEqual(MessageURLFinder.target(for: values[0]), values[0])
    }
    func testUnicodeAndBracketPunctuationRetainNativeOffsets() throws {
        let message = "雪🦎 <https://example.com/雪 (a)?> next https://example.com/path?!;:.- more mail@example.com."
        let ranges = MessageURLFinder.ranges(in: message)
        XCTAssertEqual(ranges.map { (message as NSString).substring(with: $0) }, ["https://example.com/雪 (a)?", "https://example.com/path", "mail@example.com"])
        XCTAssertEqual(ranges.first?.location, 5)
        let styles = try IssueTrackerProperties().messageStyles(in: message)
        XCTAssertEqual(styles.map(\.kind), [.url, .url, .url])
        XCTAssertEqual(styles.map(\.range), ranges)
        XCTAssertEqual(styles.last?.url, "mailto:mail@example.com")
        // URLFinder only enters bracket mode before end-of-text. Preserve that
        // source quirk instead of silently inventing a different delimiter rule.
        XCTAssertTrue(MessageURLFinder.ranges(in: "<https://example.com>").isEmpty)
        XCTAssertEqual(MessageURLFinder.ranges(in: "<https://example.com> ").count, 1)
    }
    func testURLPassOverridesAndSplitsIssueHotspots() throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "(prefixhttps://example.com|#42|https://example.com)", "bugtraq.url": "https://tracker.invalid/%BUGID%"])
        let message = "#42 https://example.com"
        let styles = try properties.messageStyles(in: message, executable: executable)
        XCTAssertEqual(styles.map(\.kind), [.identifier, .url])
        XCTAssertEqual(styles.map(\.url), ["https://tracker.invalid/%2342", "https://example.com"])
        let spanning = IssueTrackerProperties(values: ["bugtraq.logregex": "(.*)", "bugtraq.url": "https://tracker.invalid/%BUGID%"])
        let mixed = try spanning.messageStyles(in: "ID https://example.com tail", executable: executable)
        XCTAssertEqual(mixed.map(\.kind), [.identifier, .url, .identifier])
        XCTAssertEqual(mixed.map(\.url), ["https://tracker.invalid/ID%20", "https://example.com", "https://tracker.invalid/%20tail"])
    }
}
