import XCTest
@testable import TurtleGitCore

final class FinderMenuSettingsTests: XCTestCase {
    func testSeparatePreferenceDefaultsAndNonzero() throws {
        let suite = "TurtleGit.FinderMenuTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(FinderMenuSettings.from(defaults: defaults).showIcons)
        defaults.set(false, forKey: "ShowAppContextMenuIcons")
        XCTAssertTrue(FinderMenuSettings.from(defaults: defaults).showIcons)
        defaults.set(false, forKey: "ShowContextMenuIcons")
        XCTAssertFalse(FinderMenuSettings.from(defaults: defaults).showIcons)
        defaults.set(2, forKey: "ShowContextMenuIcons")
        XCTAssertTrue(FinderMenuSettings.from(defaults: defaults).showIcons)
        defaults.removeObject(forKey: "ShowContextMenuIcons")
        XCTAssertTrue(FinderMenuSettings.from(defaults: defaults).showIcons)
    }
    func testAtomicHandoffDefaultsAndStatusIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("shared/menu-settings.json")
        XCTAssertTrue(FinderMenuSettings.read(from: url).showIcons)
        XCTAssertTrue(FinderMenuSettings.read(from: nil).showIcons)
        XCTAssertFalse(try FinderMenuSettings(showIcons: false).write(to: nil))
        let snapshot = FinderSnapshot(roots: ["/repo"], states: ["/repo/file": .modified])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statusURL = url.deletingLastPathComponent().appendingPathComponent("status.json")
        let status = try JSONEncoder().encode(snapshot); try status.write(to: statusURL)
        XCTAssertTrue(try FinderMenuSettings(showIcons: false).write(to: url))
        XCTAssertFalse(FinderMenuSettings.read(from: url).showIcons)
        XCTAssertTrue(try FinderMenuSettings().write(to: url))
        XCTAssertTrue(FinderMenuSettings.read(from: url).showIcons)
        XCTAssertEqual(try Data(contentsOf: statusURL), status)
        try Data("broken cache".utf8).write(to: url)
        XCTAssertTrue(FinderMenuSettings.read(from: url).showIcons)
        try Data("{}".utf8).write(to: url)
        XCTAssertTrue(FinderMenuSettings.read(from: url).showIcons)
        let blocker = root.appendingPathComponent("file"); try Data().write(to: blocker)
        XCTAssertThrowsError(try FinderMenuSettings().write(to: blocker.appendingPathComponent("child")))
    }
}
