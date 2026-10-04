import XCTest
@testable import TurtleGitCore

final class MergeEditorPreferencesTests: XCTestCase {
    func testDefaultsPersistenceAndBounds() throws {
        let name = "TurtleGitMerge.PreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults), MergeEditorPreferences())
        let saved = MergeEditorPreferences(tabWidth: 7, useSpaces: true, smartTab: true, showLineNumbers: false)
        saved.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), saved)
        defaults.removeObject(forKey: "TurtleGitMerge.ShowLineNumbers")
        XCTAssertTrue(MergeEditorPreferences.load(from: defaults).showLineNumbers)
        defaults.set(-5, forKey: "TurtleGitMerge.TabSize")
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1)
        defaults.set(1001, forKey: "TurtleGitMerge.TabSize")
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1000)
        var edited = MergeEditorPreferences(); edited.tabWidth = 0; edited.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1)
        edited.tabWidth = 2000; edited.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1000)
    }
}
