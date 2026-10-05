import XCTest
@testable import TurtleGitCore

final class EditorConfigTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/editorconfig-runtime/EditorConfig/editorconfig")
    }
    func testOfficialRuntimeResolvesInheritedRulesAndMapsOnlyPaneIndentation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorConfigTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child 雪")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("root=true\n[*.{txt,md}]\nindent_style=space\nindent_size=3\ntab_width=5\n[part{1..3}.txt]\ntab_width=7\n".utf8).write(to: root.appendingPathComponent(".editorconfig"))
        try Data("[part2.txt]\nindent_size=unset\ntab_width=6\ncharset=utf-16le\n".utf8).write(to: child.appendingPathComponent(".editorconfig"))
        let defaults = MergeEditorPreferences(tabWidth: 4, useSpaces: false, smartTab: true, showLineNumbers: false)
        let first = try EditorConfigRuntime.resolve(file: child.appendingPathComponent("part1.txt"), executable: parser)
        XCTAssertTrue(first.loaded); XCTAssertEqual(first.tabWidth, 7)
        let next = try EditorConfigRuntime.resolve(file: child.appendingPathComponent("part2.txt"), executable: parser)
        XCTAssertEqual(next.properties["indent_size"], "unset")
        XCTAssertEqual(next.properties["charset"], "utf-16le")
        XCTAssertEqual(next.applying(to: defaults), MergeEditorPreferences(tabWidth: 6, useSpaces: true, smartTab: true, showLineNumbers: false))
        let before = try Data(contentsOf: child.appendingPathComponent(".editorconfig"))
        let unmatched = try EditorConfigRuntime.resolve(file: child.appendingPathComponent("unmatched.bin"), executable: parser)
        XCTAssertFalse(unmatched.loaded); XCTAssertEqual(unmatched.applying(to: defaults), defaults)
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent(".editorconfig")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("part2.txt").path))
    }
    func testUpstreamNumericWidthCoercionAndUnusedSaveProperties() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorConfigWidth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MergeEditorPreferences(tabWidth: 4, smartTab: true, enableEditorConfig: true)
        for (value, expected) in [("unset", 1), ("0", 1), ("-4", 1), ("1200", 1000), ("12suffix", 12)] {
            let configuration = "root=true\n[*.txt]\ntab_width=\(value)\nindent_style=space\ncharset=utf-16le\nend_of_line=crlf\ntrim_trailing_whitespace=true\ninsert_final_newline=true\n"
            try Data(configuration.utf8).write(to: root.appendingPathComponent(".editorconfig"))
            let resolved = try EditorConfigRuntime.resolve(file: root.appendingPathComponent("file.txt"), executable: parser)
            XCTAssertEqual(resolved.tabWidth, expected, value)
            let settings = resolved.applying(to: defaults)
            XCTAssertEqual(settings.tabWidth, expected); XCTAssertTrue(settings.useSpaces)
            XCTAssertTrue(settings.smartTab); XCTAssertTrue(settings.enableEditorConfig)
            XCTAssertEqual(resolved.properties["charset"], "utf-16le")
            XCTAssertEqual(resolved.properties["end_of_line"], "crlf")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
        }
    }
    func testMissingParserAndMalformedConfigurationFailWithoutWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorConfigFailure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        do { _ = try EditorConfigRuntime.resolve(file: file, executable: root.appendingPathComponent("absent")); XCTFail("Missing helper accepted") }
        catch EditorConfigFailure.runtimeMissing {}
        let bytes = Data("root=true\n[*.txt]\ninvalid syntax\n".utf8)
        try bytes.write(to: root.appendingPathComponent(".editorconfig"))
        do { _ = try EditorConfigRuntime.resolve(file: file, executable: parser); XCTFail("Invalid configuration accepted") }
        catch EditorConfigFailure.failed(let detail) { XCTAssertFalse(detail.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".editorconfig")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
