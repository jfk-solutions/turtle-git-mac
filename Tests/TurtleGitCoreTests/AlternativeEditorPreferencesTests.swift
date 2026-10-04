import XCTest
@testable import TurtleGitCore

final class AlternativeEditorPreferencesTests: XCTestCase {
    func testDefaultCustomAndDisabledChoiceRetainApplicationAndBookmark() {
        let suite = "TurtleGitEditorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AlternativeEditorPreferences.load(from: defaults), .init())
        var preferences = AlternativeEditorPreferences(custom: true, applicationPath: "/Applications/Editor 雪.app", bookmark: Data([1, 2, 3]))
        preferences.save(to: defaults)
        XCTAssertEqual(AlternativeEditorPreferences.load(from: defaults), preferences)
        XCTAssertEqual(preferences.customApplication?.path, preferences.applicationPath)
        preferences.custom = false; preferences.save(to: defaults)
        let disabled = AlternativeEditorPreferences.load(from: defaults)
        XCTAssertEqual(disabled.applicationPath, preferences.applicationPath)
        XCTAssertEqual(disabled.bookmark, preferences.bookmark)
        XCTAssertNil(disabled.customApplication)
        XCTAssertTrue(disabled.valid)
    }
    func testApplicationPathValidationAndBlankCustomFallback() {
        for path in ["", "/Applications/Editor With Spaces.app", "/Applications/雪.APP"] {
            XCTAssertTrue(AlternativeEditorPreferences(custom: true, applicationPath: path).valid)
        }
        XCTAssertNil(AlternativeEditorPreferences(custom: true).customApplication)
        for path in ["relative.app", "/bin/sh", "/Applications/Editor.app\0extra", "https://example.com/editor.app"] {
            XCTAssertFalse(AlternativeEditorPreferences(custom: true, applicationPath: path).valid, path)
        }
    }
}
