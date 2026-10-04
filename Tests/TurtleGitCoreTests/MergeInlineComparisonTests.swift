import XCTest
@testable import TurtleGitCore

final class MergeInlineComparisonTests: XCTestCase {
    func testCharacterAndWordModesUseExactUTF16Ranges() throws {
        let a = "let count = 10; // keep this shared text", b = "let count = 20; // keep this shared text"
        let chars = try XCTUnwrap(MergeInlineComparison(base: a, destination: b))
        XCTAssertEqual(chars.base, [NSRange(location: 12, length: 1)])
        XCTAssertEqual(chars.destination, chars.base)
        let words = try XCTUnwrap(MergeInlineComparison(base: a, destination: b, word: true))
        XCTAssertEqual(words.base, [NSRange(location: 12, length: 2)])
        XCTAssertEqual(words.destination, words.base)
        XCTAssertTrue(words.baseMissing.isEmpty); XCTAssertTrue(words.destinationMissing.isEmpty)
        let unicode = try XCTUnwrap(MergeInlineComparison(base: "🐢 shared café tail text", destination: "🐢 shared cafe\u{301} tail text", word: true))
        XCTAssertEqual(("🐢 shared café tail text" as NSString).substring(with: unicode.base[0]), "café")
        XCTAssertEqual(("🐢 shared cafe\u{301} tail text" as NSString).substring(with: unicode.destination[0]), "cafe\u{301}")
    }
    func testWhitespacePunctuationAndMissingTextMarkers() throws {
        let whitespace = try XCTUnwrap(MergeInlineComparison(base: "same\t  value; keep all this", destination: "same value; keep all this", word: true))
        XCTAssertEqual(whitespace.base, [NSRange(location: 4, length: 3)])
        XCTAssertEqual(whitespace.destination, [NSRange(location: 4, length: 1)])
        let punctuation = try XCTUnwrap(MergeInlineComparison(base: "same.name and shared words", destination: "same_name and shared words", word: true))
        XCTAssertEqual(punctuation.base, [NSRange(location: 4, length: 1)])
        let insertion = try XCTUnwrap(MergeInlineComparison(base: "keep shared ending", destination: "keep new shared ending", word: true))
        XCTAssertTrue(insertion.base.isEmpty)
        XCTAssertEqual(insertion.baseMissing, [5])
        XCTAssertEqual(insertion.destination, [NSRange(location: 5, length: 4)])
        let reverse = try XCTUnwrap(MergeInlineComparison(base: "keep new shared ending", destination: "keep shared ending", word: true))
        XCTAssertEqual(reverse.destinationMissing, insertion.baseMissing)
        XCTAssertEqual(reverse.base, insertion.destination)
    }
    func testSimilarityGateEmptyEqualAndLengthLimit() throws {
        XCTAssertNil(MergeInlineComparison(base: "old", destination: "new"))
        XCTAssertNil(MergeInlineComparison(base: "child next", destination: "child last", word: true))
        XCTAssertNil(MergeInlineComparison(base: "", destination: "added"))
        XCTAssertNil(MergeInlineComparison(base: "same", destination: "same"))
        let a = String(repeating: "a", count: 2999) + "x", b = String(repeating: "a", count: 2999) + "y"
        XCTAssertNotNil(MergeInlineComparison(base: a, destination: b))
        XCTAssertNotNil(MergeInlineComparison(base: a + "z", destination: b))
        XCTAssertNotNil(MergeInlineComparison(base: a, destination: b + "z"))
        XCTAssertNil(MergeInlineComparison(base: a + "z", destination: b + "z"))
        XCTAssertNil(MergeInlineComparison(base: "🐢 keep", destination: "🐢 kept", maximumLength: 6))
    }
}
