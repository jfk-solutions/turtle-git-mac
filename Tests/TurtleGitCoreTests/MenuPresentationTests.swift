import XCTest
import AppKit
@testable import TurtleGitCore

final class MenuPresentationTests: XCTestCase {
    func testDefaultAndIndependentShellPreference() throws {
        let suite = "TurtleGit.MenuPolicy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MenuPresentationSettings.applicationContextIcons(defaults: defaults))
        defaults.set(false, forKey: "ShowContextMenuIcons")
        XCTAssertTrue(MenuPresentationSettings.applicationContextIcons(defaults: defaults), "Shell and app controls are independent")
        defaults.set(false, forKey: "ShowAppContextMenuIcons")
        XCTAssertFalse(MenuPresentationSettings.applicationContextIcons(defaults: defaults))
        defaults.removeObject(forKey: "ShowAppContextMenuIcons")
        XCTAssertTrue(MenuPresentationSettings.applicationContextIcons(defaults: defaults))
    }
    func testDisabledContextKeepsButtonBadgeAndArtworkImages() throws {
        let suite = "TurtleGit.MenuImages." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ShowAppContextMenuIcons")
        for icon in MenuIcon.allCases {
            XCTAssertNil(icon.contextImage(defaults: defaults), icon.rawValue)
            XCTAssertNotNil(icon.image(), "The original image remains available for buttons/badges: \(icon.rawValue)")
        }
        defaults.set(true, forKey: "ShowAppContextMenuIcons")
        let image = try XCTUnwrap(MenuIcon.lock.contextImage(defaults: defaults))
        XCTAssertFalse(image.isTemplate)
        defaults.set(2, forKey: "ShowAppContextMenuIcons")
        XCTAssertNotNil(MenuIcon.lock.contextImage(defaults: defaults), "Source DWORD flags treat any nonzero value as enabled")
    }
}
