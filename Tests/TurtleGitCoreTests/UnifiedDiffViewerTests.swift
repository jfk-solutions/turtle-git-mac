import XCTest
@testable import TurtleGitCore

final class UnifiedDiffViewerTests: XCTestCase {
    func testReadOnlyDocumentSavePreservesBytesAndCapturedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("saved.patch")
        for bytes in [Data(), Data([0xef, 0xbb, 0xbf]) + Data("diff --git a/a b/a\r\n+last line".utf8), Data("@@ -1 +1 @@\n-".utf8) + Data([0xff, 10, 43, 0xfe])] {
            var current = UnifiedDiffDocument(bytes: bytes)
            let captured = current
            current = UnifiedDiffDocument(bytes: Data("refreshed while chooser open\n".utf8))
            try captured.write(to: target)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertNotEqual(current.bytes, captured.bytes)
            if bytes.contains(0xff) { XCTAssertNotEqual(Data(captured.displayText.utf8), captured.bytes) }
        }
        do { try UnifiedDiffDocument(bytes: Data("must fail".utf8)).write(to: directory); XCTFail("Saved over a directory") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: target).last, 0xfe)
    }
    func testStagedUnstagedAndWholeWorkingPatchKeepNonUTF8Bytes() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Data([0xff, 0x0a]), stagedBytes = Data([0xfe, 0x0a]), workingBytes = Data([0xfd, 0x0a])
        try base.write(to: root.appendingPathComponent(path))
        try await repository.stage([path]); _ = try await repository.commit(message: "Raw text base")
        try stagedBytes.write(to: root.appendingPathComponent(path)); try await repository.stage([path])
        try workingBytes.write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let staged = try await repository.patchData(paths: [path], staged: true)
        let unstaged = try await repository.patchData(paths: [path], staged: false)
        let whole = try await repository.workingTreeDiffData(paths: [path])
        let readOnly = try await repository.workingTreePatchData(paths: [path])
        XCTAssertNotNil(readOnly.range(of: Data([0x2b, 0xfd, 0x0a])))
        for (patch, old, new) in [(staged, UInt8(0xff), UInt8(0xfe)), (unstaged, UInt8(0xfe), UInt8(0xfd)), (whole, UInt8(0xff), UInt8(0xfd))] {
            XCTAssertNotNil(patch.range(of: Data([0x2d, old, 0x0a])))
            XCTAssertNotNil(patch.range(of: Data([0x2b, new, 0x0a])))
        }
        let preview = try UnifiedDiffPreview.create(staged)
        defer { preview.discard() }
        _ = try await repository.run(["apply", "--cached", "--reverse", "--check", "--", preview.file.path])
        do { _ = try await repository.patch(paths: [path], staged: true); XCTFail("Partial staging must retain its UTF-8 restriction") }
        catch PatchFailure.encoding {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), workingBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, finalHead)
    }
    func testShiftInvertsConfiguredExternalChoiceAndEmptyAlwaysUsesBuiltin() throws {
        let app = URL(fileURLWithPath: "/Applications/Viewer 雪.app", isDirectory: true)
        for enabled in [false, true] {
            let preferences = UnifiedDiffViewerPreferences(enabled: enabled, applicationPath: app.path)
            XCTAssertEqual(try preferences.choice(), enabled ? .external(app) : .builtin)
            XCTAssertEqual(try preferences.choice(alternate: true), enabled ? .builtin : .external(app))
            let empty = UnifiedDiffViewerPreferences(enabled: enabled)
            XCTAssertEqual(try empty.choice(), .builtin); XCTAssertEqual(try empty.choice(alternate: true), .builtin)
        }
        for invalid in ["relative.app", "/Applications/tool", "/Applications/tool.app\0"] {
            let active = UnifiedDiffViewerPreferences(enabled: true, applicationPath: invalid)
            XCTAssertFalse(active.valid); XCTAssertThrowsError(try active.choice())
            XCTAssertEqual(try active.choice(alternate: true), .builtin)
            let disabled = UnifiedDiffViewerPreferences(enabled: false, applicationPath: invalid)
            XCTAssertEqual(try disabled.choice(), .builtin); XCTAssertThrowsError(try disabled.choice(alternate: true))
        }
    }
    func testDisabledViewerRetainsApplicationAndBookmarkIndependentlyOfEditor() throws {
        let suite = "TurtleGitUnifiedDiffViewerTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = AlternativeEditorPreferences(custom: true, applicationPath: "/Applications/Editor.app", bookmark: Data([1, 2]))
        editor.save(to: defaults)
        var preferences = UnifiedDiffViewerPreferences(enabled: true, applicationPath: "/Applications/Viewer.app", bookmark: Data([3, 4]))
        preferences.save(to: defaults); preferences.enabled = false; preferences.save(to: defaults)
        XCTAssertEqual(UnifiedDiffViewerPreferences.load(from: defaults), preferences)
        XCTAssertEqual(AlternativeEditorPreferences.load(from: defaults), editor)
        XCTAssertEqual(try UnifiedDiffViewerPreferences.load(from: defaults).choice(alternate: true), .external(URL(fileURLWithPath: preferences.applicationPath, isDirectory: true)))
    }
    func testPreviewPreservesRawBytesPrivatePermissionsAndIndependentLifetime() throws {
        let bytes = Data([0, 255, 13, 10]) + Data("diff --git a/雪 b/雪\n".utf8)
        let first = try UnifiedDiffPreview.create(bytes)
        defer { first.discard() }
        let second = try UnifiedDiffPreview.create(Data("other".utf8))
        defer { second.discard() }
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(try Data(contentsOf: first.file), bytes)
        XCTAssertEqual(first.file.lastPathComponent, "diff.patch")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: first.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        second.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertEqual(try Data(contentsOf: first.file), bytes)
        first.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
    }
}
