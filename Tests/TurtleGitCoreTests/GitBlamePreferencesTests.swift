import XCTest
@testable import TurtleGitCore

final class GitBlamePreferencesTests: XCTestCase {
    func testDefaultsReopenAndInvalidStoredCounts() throws {
        let name = "TurtleGitBlamePreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(GitBlamePreferences.load(from: defaults), GitBlameOptions())
        var options = GitBlameOptions(); options.detectionMode = .existingFiles
        options.withinFileCharacters = 0; options.betweenFileCharacters = .max
        options.ignoreWhitespace = true; options.onlyFirstParent = true
        options.showCompleteLog = false; options.followRenames = true
        GitBlamePreferences.save(options, to: defaults)
        XCTAssertEqual(GitBlamePreferences.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), options)
        defaults.set(-1, forKey: "TurtleGitBlame.WithinFileCharacters")
        defaults.set("4294967296", forKey: "TurtleGitBlame.BetweenFileCharacters")
        defaults.set(99, forKey: "TurtleGitBlame.DetectMovedOrCopiedLines")
        let corrected = GitBlamePreferences.load(from: defaults)
        XCTAssertEqual(corrected.withinFileCharacters, 20); XCTAssertEqual(corrected.betweenFileCharacters, 40)
        XCTAssertEqual(corrected.detectionMode, .disabled)
        XCTAssertTrue(corrected.ignoreWhitespace); XCTAssertTrue(corrected.onlyFirstParent)
    }
    func testFieldEditsRetainOtherViewersChoicesAndDoNotSaveEncoding() throws {
        let name = "TurtleGitBlamePreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var oldViewer = GitBlamePreferences.load(from: defaults)
        GitBlamePreferences.update(in: defaults) { $0.betweenFileCharacters = 17; $0.onlyFirstParent = true }
        oldViewer.detectionMode = .fileCreation
        GitBlamePreferences.update(in: defaults) { $0.detectionMode = oldViewer.detectionMode }
        let current = GitBlamePreferences.load(from: defaults)
        XCTAssertEqual(current.betweenFileCharacters, 17); XCTAssertTrue(current.onlyFirstParent)
        XCTAssertEqual(current.detectionMode, .fileCreation)
        var encoded = current; encoded.encoding = .utf16LE
        GitBlamePreferences.save(encoded, to: defaults)
        XCTAssertEqual(GitBlamePreferences.load(from: defaults), current)
    }
}
