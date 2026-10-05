import XCTest
@testable import TurtleGitCore

final class IssueRegexTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func match(_ message: String, _ check: String, _ extract: String = "") throws -> IssueRegexMatch {
        try IssueRegexRuntime.match(message: message, check: check, extract: extract, executable: parser)
    }
    func testPinnedUpstreamCaptureAndTwoExpressionExamples() throws {
        let captureless = try match("This is a test for PAF-88", "PAF-[0-9]+")
        XCTAssertTrue(captureless.hasMatch); XCTAssertTrue(captureless.ranges.isEmpty)
        let single = try match("Testing issue #99", "[Ii]ssue #?(\\d+)")
        XCTAssertEqual(single.identifiers(in: "Testing issue #99"), ["99"])
        let multi = "This is a test for Issue #7463,#666"
        let check = "[Ii]ssues?:?(\\s*(,|and)?\\s*#\\d+)+"
        let values = try match(multi, check, "(\\d+)")
        XCTAssertTrue(values.hasMatch); XCTAssertEqual(values.identifiers(in: multi), ["7463", "666"])
        XCTAssertFalse(try match("This is a test for Issue 7463,666", check, "(\\d+)").hasMatch)
        let padded = "[000815] some error fixed"
        XCTAssertEqual(try match(padded, "^\\[(\\d+)\\].*").identifiers(in: padded), ["000815"])
        let brackets = "test test [[000815]]] some error fixed"
        XCTAssertEqual(try match(brackets, "\\[\\[(\\d+)\\]\\]\\]").identifiers(in: brackets), ["000815"])
    }
    func testUTF16OffsetsAndWholeSecondExpressionMatches() throws {
        let text = "雪🦎 issues #42 and #73"
        let result = try match(text, "issues.*", "#(\\d+)")
        XCTAssertEqual(result.identifiers(in: text), ["#42", "#73"])
        XCTAssertEqual(result.ranges, [(text as NSString).range(of: "#42"), (text as NSString).range(of: "#73")])
        let surrogate = "🦎 issue #42"
        XCTAssertEqual(try match(surrogate, "[Ii]ssue #?(\\d+)").ranges, [NSRange(location: 10, length: 2)])
        XCTAssertFalse(try match("prefix\0issue #42", "[Ii]ssue #?(\\d+)").hasMatch)
    }
    func testECMAScriptSyntaxFailuresAndMissingRuntime() throws {
        do { _ = try match("issue #42", "(?<=#)(\\d+)"); XCTFail("ECMAScript lookbehind unexpectedly accepted") }
        catch IssueRegexFailure.failed(let detail) { XCTAssertFalse(detail.isEmpty) }
        do { _ = try IssueRegexRuntime.match(message: "42", check: "(\\d+)", executable: URL(fileURLWithPath: "/no-such-turtlegit-issue-helper")); XCTFail("Missing runtime accepted") }
        catch IssueRegexFailure.runtimeMissing {}
        XCTAssertEqual(try match("42", ""), IssueRegexMatch(hasMatch: false, ranges: []))
    }
}
