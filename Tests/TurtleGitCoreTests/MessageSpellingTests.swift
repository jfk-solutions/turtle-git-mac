import XCTest
@testable import TurtleGitCore

final class MessageSpellingTests: XCTestCase {
    func testSuggestionRangeIncludesSuffixPreservesMarkersAndUTF16Offsets() {
        let text = "🐢 Fix _mispelt_ and café"
        let word = (text as NSString).range(of: "mispelt")
        XCTAssertEqual(MessageSpellingPolicy.suggestionRange(message: text, selection: NSRange(location: word.location + 3, length: 0), styling: true), word)
        XCTAssertEqual(MessageSpellingPolicy.suggestionRange(message: text, selection: NSRange(location: word.location, length: word.length), styling: true), word)
        XCTAssertNil(MessageSpellingPolicy.suggestionRange(message: "word", selection: NSRange(location: 0, length: 0), styling: true))
        XCTAssertEqual(MessageSpellingPolicy.suggestionRange(message: "can't", selection: NSRange(location: 3, length: 0), styling: false), NSRange(location: 0, length: 5))
        XCTAssertEqual(MessageSpellingPolicy.suggestionRange(message: "cafe\u{301}", selection: NSRange(location: 3, length: 0), styling: false), NSRange(location: 0, length: 5))
        XCTAssertNil(MessageSpellingPolicy.suggestionRange(message: "word", selection: NSRange(location: NSNotFound, length: 0), styling: false))
        XCTAssertNil(MessageSpellingPolicy.suggestionRange(message: "word", selection: NSRange(location: 4, length: 1), styling: false))
    }

    func testKnownTokensFilenamesAndNumericIdentifiers() {
        let policy = MessageSpellingPolicy(candidates: ["Widget.zzz", "turtlegit"])
        for text in ["Widget.zzz", "turtlegit", "42zzzz"] {
            XCTAssertTrue(policy.suppresses(message: text, range: NSRange(location: 0, length: 3), misspelled: { _ in true }), text)
        }
        XCTAssertFalse(policy.suppresses(message: "Turtlegit", range: NSRange(location: 0, length: 9), misspelled: { _ in true }))
        XCTAssertFalse(policy.suppresses(message: "Other.zzz", range: NSRange(location: 6, length: 3), misspelled: { _ in true }))
    }
    func testCamelCaseAndAcronymComponentsUseDictionary() {
        let policy = MessageSpellingPolicy()
        let accepted: Set<String> = ["camel", "Case", "Request", "Parser"]
        for text in ["camelCase", "HTTPRequest", "XMLParser", "myID"] {
            XCTAssertTrue(policy.suppresses(message: text, range: NSRange(location: 0, length: (text as NSString).length), misspelled: { !accepted.contains($0) }))
        }
        XCTAssertFalse(policy.suppresses(message: "camelMispeling", range: NSRange(location: 0, length: 14), misspelled: { !accepted.contains($0) }))
        XCTAssertFalse(policy.suppresses(message: "mispeling", range: NSRange(location: 0, length: 9), misspelled: { _ in false }))
    }
    func testUTF16OffsetsAndInvalidRanges() {
        let message = "🐢 Widget.zzz misspelt"
        let policy = MessageSpellingPolicy(candidates: ["Widget.zzz"])
        XCTAssertTrue(policy.suppresses(message: message, range: (message as NSString).range(of: "zzz"), misspelled: { _ in true }))
        XCTAssertFalse(policy.suppresses(message: message, range: (message as NSString).range(of: "misspelt"), misspelled: { _ in true }))
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1), NSRange(location: 0, length: 0), NSRange(location: 100, length: 1), NSRange(location: 3, length: Int.max)] {
            XCTAssertFalse(policy.suppresses(message: message, range: range, misspelled: { _ in true }))
        }
    }
}
