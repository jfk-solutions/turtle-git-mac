import XCTest
@testable import TurtleGitCore

final class EditorConfigTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/editorconfig-runtime/EditorConfig/editorconfig")
    }
    func testCancelledReadNeverLaunchesParser() {
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try EditorConfigRuntime.resolve(file:URL(fileURLWithPath:"/tmp/file"),executable:URL(fileURLWithPath:"/missing/parser"),cancellation:token)) {
            XCTAssertTrue($0 is OperationCancellationFailure)
        }
    }
    func testLiveParserCancellationReapsOwnedProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorConfigCancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let helper = folder.appendingPathComponent("parser"), marker = folder.appendingPathComponent("pid")
        try "#!/bin/sh\nprintf '%s' $$ > \"$0.pid.tmp\"\nmv \"$0.pid.tmp\" \"$0.pid\"\nexec /bin/sleep 60\n".write(to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let token = OperationCancellation(), pidFile = URL(fileURLWithPath:helper.path+".pid")
        let task = Task.detached { try EditorConfigRuntime.resolve(file:marker,executable:helper,cancellation:token) }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath:pidFile.path) { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf:pidFile,encoding:.utf8)))
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read returned settings") }
        catch { XCTAssertTrue(error is OperationCancellationFailure) }
        XCTAssertEqual(kill(pid,0),-1); XCTAssertEqual(errno,ESRCH)
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
