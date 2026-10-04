import XCTest
@testable import TurtleGitCore

final class GitBlamePresentationTests: XCTestCase {
    func testPresentationReopensSeparatelyFromAnnotationDefaults() throws {
        let name = "GitBlamePresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(GitBlamePresentation.load(from: defaults), GitBlamePresentation())
        var value = GitBlamePresentation(); value.fontName = "Courier"; value.fontSize = 14; value.tabSize = 8
        value.recentColor = 0x40ff80; value.oldColor = 0xf0f0ff; value.darkRecentColor = 0x204030; value.darkOldColor = 0x101020
        value.save(to: defaults)
        GitBlamePreferences.update(in: defaults) { $0.onlyFirstParent = true }
        XCTAssertEqual(GitBlamePresentation.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), value)
        XCTAssertTrue(GitBlamePreferences.load(from: defaults).onlyFirstParent)
        defaults.set(-1, forKey: "TurtleGitBlame.FontSize"); defaults.set(1001, forKey: "TurtleGitBlame.TabSize")
        defaults.set("4294967296", forKey: "TurtleGitBlame.RecentColor")
        let loaded = GitBlamePresentation.load(from: defaults)
        XCTAssertEqual(loaded.fontSize, 1); XCTAssertEqual(loaded.tabSize, 1000); XCTAssertEqual(loaded.recentColor, 0xffff50)
    }
    func testAgeInterpolationRetainsUpstreamIntegerPaletteAndCustomEndpoints() {
        var value = GitBlamePresentation()
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: true), 0xffffa7)
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: true, enabled: true), 0x383810)
        XCTAssertEqual(value.ageColor(rank: nil, historyCount: 10, dark: false, enabled: true), 0xffffff)
        value.recentColor = 0x00ff80; value.oldColor = 0x808080
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: true), 0x40bf80)
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: false), 0x808080)
        XCTAssertEqual(value.ageColor(rank: 9, historyCount: 1, dark: false, enabled: true), 0x808080)
    }
}
