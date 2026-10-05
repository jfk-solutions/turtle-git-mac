import XCTest
@testable import TurtleGitCore

final class MessageCompletionTests: XCTestCase {
    func testAllPathSuffixesAndOptionalExtensionRemoval() {
        let paths = ["src/nested/Widget.swift", "src/nested/Widget.swift", "dot.dir/.hidden", "dot.dir/plain"]
        XCTAssertEqual(MessageCompletion.fileCandidates(paths: paths), [".hidden", "Widget.swift", "dot.dir/.hidden", "dot.dir/plain", "nested/Widget.swift", "plain", "src/nested/Widget.swift"])
        let stripped = MessageCompletion.fileCandidates(paths: paths, removeExtensions: true)
        XCTAssertTrue(stripped.contains("Widget")); XCTAssertFalse(stripped.contains("")); XCTAssertFalse(stripped.contains(".hidden" + ".hidden"))
        XCTAssertEqual(stripped.count, 8)
    }
    func testLiteralUTF16FileIdentityAndOrdering() {
        let paths = ["é.txt", "e\u{301}.txt", "a.txt", "A.txt"]
        let values = MessageCompletion.fileCandidates(paths: paths)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values.map { Array($0.utf16) }, paths.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { Array($0.utf16) })
    }
    func testMinimumCaseVariantsAndHyphenParts() {
        let candidates = ["Foo.swift", "foo.txt", "Bar.swift", "baz.txt"]
        XCTAssertTrue(MessageCompletion.matches(prefix: "fo", candidates: candidates, minimum: 3).isEmpty)
        XCTAssertEqual(MessageCompletion.matches(prefix: "foo", candidates: candidates, minimum: 3), ["Foo.swift", "foo.txt"])
        XCTAssertEqual(MessageCompletion.matches(prefix: "foo-ba", candidates: candidates, minimum: 3), ["Foo.swift", "foo.txt"])
        XCTAssertEqual(MessageCompletion.matches(prefix: "foo-ba", candidates: candidates, minimum: 1), ["Bar.swift", "Foo.swift", "baz.txt", "foo.txt"])
    }
    func testEndOfWordSelectionAndMarkerFallback() {
        let values = ["Widget.swift", "_Special.txt", "src/Widget.swift"]
        XCTAssertNil(MessageCompletion.request(message: "Widget", selection: NSRange(location: 3, length: 0), candidates: values, minimum: 1, styling: true))
        XCTAssertNil(MessageCompletion.request(message: "Wid", selection: NSRange(location: 0, length: 3), candidates: values, minimum: 1, styling: true))
        let word = MessageCompletion.request(message: "Fix _Wid", selection: NSRange(location: 8, length: 0), candidates: values, minimum: 3, styling: true)
        XCTAssertEqual(word?.range, NSRange(location: 5, length: 3)); XCTAssertEqual(word?.candidates, ["Widget.swift"])
        let raw = MessageCompletion.request(message: "_Spe", selection: NSRange(location: 4, length: 0), candidates: values, minimum: 3, styling: true)
        XCTAssertEqual(raw?.range, NSRange(location: 0, length: 4)); XCTAssertEqual(raw?.candidates, ["_Special.txt"])
        XCTAssertEqual(MessageCompletion.request(message: "src/Wid", selection: NSRange(location: 7, length: 0), candidates: values, minimum: 3, styling: true)?.range, NSRange(location: 4, length: 3))
    }
}
