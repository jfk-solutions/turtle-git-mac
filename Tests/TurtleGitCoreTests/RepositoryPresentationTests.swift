import XCTest
@testable import TurtleGitCore

final class RepositoryPresentationTests: XCTestCase {
    func testSourceModesScopeAndNeighborBoundary() {
        let suite = "TurtleGit.Presentation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/Users/qa/work/repo")
        XCTAssertEqual(RepositoryPresentationSettings(defaults: defaults).title(repository: root, dialog: "Commit"), "/Users/qa/work/repo – Commit – TurtleGit")
        defaults.set(1, forKey: "DialogTitles")
        let policy = RepositoryPresentationSettings(defaults: defaults)
        XCTAssertEqual(policy.title(repository: root, location: root.appendingPathComponent("Sources/🐢.swift"), dialog: "Commit"), "repo/Sources/🐢.swift – Commit – TurtleGit")
        XCTAssertEqual(policy.title(repository: root, location: URL(fileURLWithPath: "/Users/qa/work/repo-other/a"), dialog: "Log"), "/Users/qa/work/repo-other/a – Log – TurtleGit")
        XCTAssertEqual(policy.title(repository: URL(fileURLWithPath: "/"), dialog: "Log"), "/ – Log – TurtleGit")
        defaults.set(2, forKey: "DialogTitles")
        XCTAssertEqual(RepositoryPresentationSettings(defaults: defaults).title(repository: root, dialog: "Log"), "/Users/qa/work/repo – Log – TurtleGit")
    }
    func testScopedSelectionCommonDirectory() {
        let root = URL(fileURLWithPath: "/repo")
        func location(_ paths: [String], whole: Bool = false) -> String {
            RepositoryPresentationSettings.scopedLocation(repository: root, paths: paths, wholeProject: whole).path
        }
        XCTAssertEqual(location(["a/b.swift"]), "/repo/a/b.swift")
        XCTAssertEqual(location(["a/b.swift", "a/c.swift"]), "/repo/a")
        XCTAssertEqual(location(["a/b.swift", "c/d.swift"]), "/repo")
        XCTAssertEqual(location(["a/b.swift"], whole: true), "/repo")
        XCTAssertEqual(location([]), "/repo")
    }
    func testFullPathTooltipDefaultsDisableResetAndLiteralNames() throws {
        let suite = "TurtleGit.Tooltip." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/repo with space")
        func tip() -> String? { RepositoryPresentationSettings(defaults: defaults).fileTooltip(repository: root, path: "a/%20 🐢.swift") }
        XCTAssertEqual(tip(), "/repo with space/a/%20 🐢.swift")
        try AdvancedSettingsStore(defaults: defaults).apply(["ShowListFullPathTooltip": "false"])
        XCTAssertNil(tip())
        defaults.set(2, forKey: "ShowListFullPathTooltip")
        XCTAssertNil(tip())
        try AdvancedSettingsStore(defaults: defaults).apply(["ShowListFullPathTooltip": ""])
        XCTAssertEqual(tip(), "/repo with space/a/%20 🐢.swift")
    }
    func testCompactionKeepsUnicodeWholeAndBoundsUTF16() {
        let root = URL(fileURLWithPath: "/Users/qa/" + String(repeating: "🐢e\u{301}/", count: 45) + "last.swift")
        let title = RepositoryPresentationSettings().title(repository: root, dialog: "Commit")
        let path = String(title.components(separatedBy: " – ")[0])
        XCTAssertLessThanOrEqual(path.utf16.count, 73)
        XCTAssertTrue(path.contains("…")); XCTAssertTrue(path.hasSuffix("last.swift"))
        XCTAssertFalse(path.contains("�"))
    }
}
