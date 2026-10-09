import XCTest
@testable import TurtleGitCore
final class MessageCaretPositionTests: XCTestCase {
    func testLogicalLinesTabsAndScalarColumns() {
        for (text, offset, expected) in [("", 0, "1/1"), ("ab\tX", 3, "1/9"), ("ab\tX", 4, "1/10"), ("a\r\nb", 2, "1/2"), ("a\r\nb", 3, "2/1"), ("a\rb", 2, "2/1"), ("a\nb\n", 4, "3/1"), ("e\u{301}😀", 4, "1/4"), ("👩‍💻", 5, "1/4"), ("a\u{2028}b", 3, "1/4")] {
            XCTAssertEqual(MessageCaretPosition.at(text, utf16Offset: offset).text, expected)
        }
        XCTAssertEqual(MessageCaretPosition.at("a", utf16Offset: -1).text, "1/1")
        XCTAssertEqual(MessageCaretPosition.at("a", utf16Offset: Int.max).text, "1/2")
    }
    func testForwardBackwardAndCrossAnchorSelections() {
        var caret = MessageSelectionCaret()
        XCTAssertEqual(caret.observe(NSRange(location: 7, length: 0)), 7)
        XCTAssertEqual(caret.observe(NSRange(location: 7, length: 3)), 10)
        XCTAssertEqual(caret.observe(NSRange(location: 7, length: 1)), 8)
        XCTAssertEqual(caret.observe(NSRange(location: 4, length: 3)), 4)
        XCTAssertEqual(caret.observe(NSRange(location: 7, length: 2)), 9)
        XCTAssertEqual(caret.observe(NSRange(location: 2, length: 2)), 4)
        XCTAssertEqual(caret.observe(NSRange(location: NSNotFound, length: 0)), 0)
    }
}
