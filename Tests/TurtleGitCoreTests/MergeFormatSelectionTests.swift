import XCTest
@testable import TurtleGitCore
final class MergeFormatSelectionTests: XCTestCase {
    func testSourceChoicesAndAutomaticMixedEndings() throws {
        XCTAssertEqual(MergeFormatSelection.encodings.count,9)
        XCTAssertEqual(MergeFormatSelection.encodings.first,.windows1252)
        let text = "first\r\nsecond\nlast"
        let selection = MergeFormatSelection.initial(encoding:.utf8BOM,text:text)
        XCTAssertNil(selection.ending); XCTAssertEqual(try selection.applying(to:text),text)
        XCTAssertEqual(MergeFormatSelection.initial(encoding:.utf8,text:"one\r\ntwo\r\n").ending,.crlf)
    }
    func testAllEndingsPreserveMissingFinalTerminatorAndUnicode() throws {
        for ending in MergeLineEnding.allCases {
            let selection = MergeFormatSelection(encoding:.utf16LEBOM,ending:ending)
            let result = try selection.applying(to:"🦎 one\r\n雪 two\nlast")
            XCTAssertTrue(result.hasSuffix("last"))
            XCTAssertEqual(MergeLineEndings.styles(in:result),[ending])
            XCTAssertEqual(ComparisonTextEncoding.utf16LEBOM.decode(try ComparisonTextEncoding.utf16LEBOM.encode(result)),result)
        }
    }
    func testValidationUsesConvertedTextAndRejectsLossyEncoding() throws {
        XCTAssertThrowsError(try MergeFormatSelection(encoding:.windows1252,ending:.lf).applying(to:"雪\r\n"))
        XCTAssertEqual(try MergeFormatSelection(encoding:.windows1252,ending:.lf).applying(to:"one\u{2028}two"),"one\ntwo")
    }
}
