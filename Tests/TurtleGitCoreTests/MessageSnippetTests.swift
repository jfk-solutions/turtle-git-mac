import XCTest
@testable import TurtleGitCore

final class MessageSnippetTests: XCTestCase {
    func testLiteralLinesEscapesAndOverride() {
        var snippets = MessageSnippets()
        snippets.overlay("#comment=ignored\r\n=invalid\nplain=first\n spaces =  value=more \nempty=\ninvalid\n")
        snippets.overlay(#"plain=Line one\nLine two\tTabbed\rReturn\\Slash\qUnknown\"#)
        XCTAssertNil(snippets.expansion(for: "#comment"))
        XCTAssertNil(snippets.expansion(for: ""))
        XCTAssertEqual(snippets.expansion(for: " spaces "), "  value=more ")
        XCTAssertEqual(snippets.expansion(for: "empty"), "")
        XCTAssertEqual(snippets.expansion(for: "plain"), "Line one\nLine two\tTabbed\rReturn\\Slash\\qUnknown")
    }
    func testLiteralUnicodeKeysAndFilenameCollision() {
        var snippets = MessageSnippets()
        snippets.overlay("é=one\ne\u{301}=two\nWidget.swift=expansion")
        XCTAssertEqual(snippets.keys.count, 3)
        XCTAssertEqual(snippets.expansion(for: "é"), "one")
        XCTAssertEqual(snippets.expansion(for: "e\u{301}"), "two")
        XCTAssertEqual(snippets.candidates(files: ["Widget.swift", "Window.swift"]).count, 4)
        XCTAssertEqual(snippets.expansion(for: "Widget.swift"), "expansion")
    }
    func testSnippetReplacementUsesTrimmedWordEvenAfterRawMatchFallback() {
        let message = "Fix _Spe", end = NSRange(location: 8, length: 0)
        let request = MessageCompletion.request(message: message, selection: end, candidates: ["_Special"], minimum: 3, styling: true)
        XCTAssertEqual(request?.range, NSRange(location: 4, length: 4))
        let range = MessageCompletion.wordRange(message: message, selection: end, styling: true)!
        XCTAssertEqual((message as NSString).replacingCharacters(in: range, with: "Expanded"), "Fix _Expanded")
    }
    func testLoaderReadsUserDefinitionsAndMissingFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("snippet.txt"), loader = MessageSnippetLoader()
        let absent = await loader.load(userURL: url)
        XCTAssertTrue(absent.keys.isEmpty) // Shipped sample keys remain commented out.
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            var data = "custom=雪\\nSecond".data(using: encoding)!
            if encoding == .utf16LittleEndian { data = Data([0xff, 0xfe]) + data }
            if encoding == .utf16BigEndian { data = Data([0xfe, 0xff]) + data }
            try data.write(to: url)
            let loaded = await loader.load(userURL: url)
            XCTAssertEqual(loaded.expansion(for: "custom"), "雪\nSecond")
        }
    }
}
