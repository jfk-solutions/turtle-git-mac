import XCTest
@testable import TurtleGitCore

final class MessageCodeSymbolsTests: XCTestCase {
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func testAllCaptureGroupsCaseInsensitiveAndDeduplicated() throws {
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "Foo bar Foo", pattern: "(foo)|(bar)", executable: helper), ["Foo", "bar"])
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "Foo", pattern: "foo", executable: helper), [])
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "name Foo", pattern: "(name) (Foo)()", executable: helper), ["Foo", "name"])
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "first\nclass Later", pattern: "^class (\\w+)", executable: helper), [])
    }
    func testUTF16AndExplicitFileLengthIncludingNul() throws {
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "雪🦎 Foo", pattern: "(Foo)", executable: helper), ["Foo"])
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "before\0after", pattern: "(after)", executable: helper), ["after"])
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "a\0b", pattern: "(a\\x00b)", executable: helper), ["a"])
        XCTAssertEqual(try MessageCodeSymbols.captureUnits(in: [0xfeff, 0xd800], pattern: "(\\uD800)", executable: helper), [[0xd800]])
    }
    func testInvalidECMAScriptRejectedAndEmptyDefinitionSkipped() throws {
        XCTAssertEqual(try MessageCodeSymbols.captures(in: "anything", pattern: "", executable: helper), [])
        XCTAssertThrowsError(try MessageCodeSymbols.captures(in: "name", pattern: "(?<=n)(ame)", executable: helper))
    }
    func testDefinitionOverrideAndUntrimmedEarlyKeys() {
        var definitions = MessageCodeDefinitions()
        definitions.overlay("# comment=skip\r\n.c, .cpp = (symbol)\r\n.h , .hpp=(header)\n.invalid=  \n")
        XCTAssertEqual(definitions.pattern(for: ".CPP"), "(symbol)")
        XCTAssertNil(definitions.pattern(for: ".h"))
        XCTAssertEqual(definitions.pattern(for: ".h "), "(header)")
        XCTAssertEqual(definitions.pattern(for: ".hpp"), "(header)")
        definitions.overlay(".cpp=(custom)\n")
        XCTAssertEqual(definitions.pattern(for: ".cpp"), "(custom)")
        XCTAssertEqual(definitions.pattern(for: ".invalid"), "")
        // ParseRegexFile retains its original eqpos when consuming comma keys.
        definitions.overlay(".longext, .b=([x,y])\n")
        XCTAssertEqual(definitions.pattern(for: ".longext"), "([x,y])")
        XCTAssertNil(definitions.pattern(for: ".b"))
    }
}
