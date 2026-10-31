// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import XCTest
@testable import TurtleGitCore

final class FinderContextMenuSettingsTests: XCTestCase {
    func testSourceCatalogOrderLabelsMasksAndOriginalPixels() throws {
        struct Row: Decodable { let key: String, mask: String, title: String, icon: String }
        struct Source: Decodable { let upstreamCommit: String; let rows: [Row]; let defaultTop: [String]; let defaultExtended: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: root.appendingPathComponent("docs/upstream-context-menu-settings.json")))
        XCTAssertEqual(source.upstreamCommit, "7338078f8ddd924b8cddee35f512f2286072136d")
        XCTAssertEqual(source.rows.count, 55); XCTAssertEqual(FinderMenuEntry.configurableCases.map(\.rawValue), source.rows.map(\.key))
        for (entry, row) in zip(FinderMenuEntry.configurableCases, source.rows) {
            XCTAssertEqual(entry.mask, UInt64(row.mask.dropFirst(2), radix: 16))
            XCTAssertEqual(entry.title, row.title); XCTAssertEqual(entry.iconResource, row.icon)
            let image = try XCTUnwrap(entry.image(), entry.rawValue)
            var rect = NSRect(origin: .zero, size: image.size)
            XCTAssertNotNil(image.cgImage(forProposedRect: &rect, context: nil, hints: nil), entry.rawValue)
        }
        func mask(_ names: [String]) throws -> UInt64 { try names.reduce(0) { $0 | (try XCTUnwrap(FinderMenuEntry(rawValue: $1))).mask } }
        XCTAssertEqual(FinderMenuEntry.defaultTopMask, try mask(source.defaultTop))
        XCTAssertEqual(FinderMenuEntry.defaultExtendedMask, try mask(source.defaultExtended))
    }
    func testPlacementVisibilityAndGroupedCommandIdentities() {
        var settings = FinderMenuSettings()
        XCTAssertTrue(settings.firstLevel(.commit)); XCTAssertTrue(settings.firstLevel(.clone)); XCTAssertTrue(settings.firstLevel(.createRepo)); XCTAssertFalse(settings.firstLevel(.diff))
        XCTAssertFalse(settings.visible(.stashApply, extended: false)); XCTAssertTrue(settings.visible(.stashApply, extended: true))
        XCTAssertFalse(settings.visible(.submoduleSync, extended: false)); XCTAssertTrue(settings.visible(.stashPop, extended: false))
        settings.topLevelMask |= UInt64(1) << 53
        settings.set(.bisect, checked: true, extendedOnly: false)
        settings.set(.merge, checked: true, extendedOnly: true)
        for action in [RepositoryAction.bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset] { XCTAssertEqual(FinderMenuEntry.entry(for: action), .bisect) }
        XCTAssertEqual(FinderMenuEntry.entry(for: .mergeAbort), .merge)
        for action in [RepositoryAction.ignore, .ignoreDelete, .ignoreMask, .ignoreDeleteMask] { XCTAssertEqual(FinderMenuEntry.entry(for: action), .ignore) }
        settings.set(.bisect, checked: false, extendedOnly: false)
        XCTAssertEqual(settings.topLevelMask & (UInt64(1) << 53), UInt64(1) << 53)
        XCTAssertFalse(settings.visible(.merge, extended: false)); XCTAssertTrue(settings.visible(.merge, extended: true))
    }
    func testExclusionGrammarExactDirectoryPrefixHomeAndCase() {
        var settings = FinderMenuSettings(); settings.excludedPaths = "/repo/exact\r\n/repo/directory/\n/repo/prefix*\n"
        XCTAssertTrue(settings.valid)
        XCTAssertFalse(settings.allowsPath("/repo/exact")); XCTAssertTrue(settings.allowsPath("/repo/exact/child"))
        XCTAssertFalse(settings.allowsPath("/repo/directory")); XCTAssertFalse(settings.allowsPath("/repo/directory/child")); XCTAssertTrue(settings.allowsPath("/repo/directory-other"))
        XCTAssertFalse(settings.allowsPath("/repo/prefix-other")); XCTAssertTrue(settings.allowsPath("/repo/pre"))
        XCTAssertTrue(settings.allowsPath("/Repo/exact")); XCTAssertFalse(settings.allowsPath("/Repo/exact", caseSensitive: false))
        settings.excludedPaths = "~?"; XCTAssertFalse(settings.valid)
        let home = UserAccountPaths.homeDirectory.path
        for rule in ["~", "$HOME"] { settings.excludedPaths = rule; XCTAssertTrue(settings.valid); XCTAssertFalse(settings.allowsPath(home)); XCTAssertTrue(settings.allowsPath(home + "/child")) }
        for rule in ["~*", "$HOME/"] { settings.excludedPaths = rule; XCTAssertTrue(settings.valid); XCTAssertFalse(settings.allowsPath(home + "/child")) }
        for rule in ["relative", "../repo", "/repo\0path"] { settings.excludedPaths = rule; XCTAssertFalse(settings.valid) }
    }
    func testAccountHomeMenuPatternsPreserveExactDescendantsAndExplicitContainerInjection() {
        let account = URL(fileURLWithPath: "/Users/person", isDirectory: true)
        let container = account.appendingPathComponent("Library/Containers/org.turtlegit.macos/Data", isDirectory: true)
        var settings = FinderMenuSettings()
        for spelling in ["~", "$HOME"] {
            settings.excludedPaths = spelling + "/Projects/"
            XCTAssertTrue(settings.valid)
            XCTAssertFalse(settings.allowsPath("/Users/person/Projects", home: account))
            XCTAssertFalse(settings.allowsPath("/Users/person/Projects/repo/file", home: account))
            XCTAssertTrue(settings.allowsPath("/Users/person/Projects-other/repo", home: account))
            XCTAssertTrue(settings.allowsPath(container.path + "/Projects/repo", home: account))
            XCTAssertFalse(settings.allowsPath(container.path + "/Projects/repo", home: container))
            XCTAssertTrue(settings.allowsPath("/Users/person/Projects/repo", home: container))
            XCTAssertTrue(settings.allowsPath("/users/PERSON/Projects/repo", home: account))
            XCTAssertFalse(settings.allowsPath("/users/PERSON/Projects/repo", caseSensitive: false, home: account))
            settings.excludedPaths = spelling
            XCTAssertFalse(settings.allowsPath(account.path, home: account))
            XCTAssertTrue(settings.allowsPath(account.path + "/child", home: account))
            XCTAssertTrue(settings.allowsPath(container.path, home: account))
            settings.excludedPaths = spelling + "/Projects*"
            XCTAssertFalse(settings.allowsPath("/Users/person/Projects-other", home: account), "Menu terminal * remains a spelling prefix")
            XCTAssertTrue(settings.allowsPath("/Users/person/Project", home: account))
        }
        for invalid in ["~other/Projects/", "$HOMELESS/Projects/", "~/Projects\0/private"] {
            settings.excludedPaths = invalid; XCTAssertFalse(settings.valid)
        }
        // Default callers (including FinderMenuBuilder) get account identity;
        // explicit container injection is still available and never persisted.
        let current = UserAccountPaths.homeDirectory
        settings.excludedPaths = "~/Projects/"
        XCTAssertEqual(settings.allowsPath(current.path + "/Projects/repo"), settings.allowsPath(current.path + "/Projects/repo", home: current))
        XCTAssertFalse(settings.allowsPath(current.path + "/Projects/repo"))
        XCTAssertEqual(settings, try? JSONDecoder().decode(FinderMenuSettings.self, from: JSONEncoder().encode(settings)))
    }
    func testHideUnversionedUsesRepositoryMembershipAndShiftOverride() {
        var settings = FinderMenuSettings(); settings.hideForUnversioned = true
        XCTAssertFalse(settings.allowsMenu(flags: [.onlyOne, .folder], extended: false))
        XCTAssertTrue(settings.allowsMenu(flags: [.onlyOne, .folder], extended: true))
        for flag in [FinderShellFlags.inGit, .inVersionedFolder, .folderInGit, .bare, .inaccessible] {
            XCTAssertTrue(settings.allowsMenu(flags: flag, extended: false))
        }
    }
    func testOldCacheAndPreferencesPreserveIndependentIconSettingAndHighBits() throws {
        let old = try JSONDecoder().decode(FinderMenuSettings.self, from: Data(#"{"showIcons":false}"#.utf8))
        XCTAssertFalse(old.showIcons); XCTAssertEqual(old.topLevelMask, FinderMenuEntry.defaultTopMask); XCTAssertEqual(old.extendedOnlyMask, FinderMenuEntry.defaultExtendedMask)
        let suite = "TurtleGit.ContextMenuTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var edited = old; edited.topLevelMask = FinderMenuEntry.about.mask | FinderMenuEntry.diff.mask; edited.hideForUnversioned = true; edited.excludedPaths = "/repo/"
        try edited.save(to: defaults)
        defaults.set(true, forKey: "ShowContextMenuIcons")
        var loaded = FinderMenuSettings.from(defaults: defaults); XCTAssertTrue(loaded.showIcons)
        XCTAssertEqual(loaded.topLevelMask, edited.topLevelMask); XCTAssertTrue(loaded.hideForUnversioned); XCTAssertEqual(loaded.excludedPaths, edited.excludedPaths)
        defaults.set(false, forKey: "ShowContextMenuIcons"); loaded = FinderMenuSettings.from(defaults: defaults)
        XCTAssertFalse(loaded.showIcons); XCTAssertEqual(loaded.topLevelMask, edited.topLevelMask)
        XCTAssertEqual(try JSONDecoder().decode(FinderMenuSettings.self, from: JSONEncoder().encode(loaded)), loaded)
        loaded.excludedPaths = "relative"; XCTAssertThrowsError(try loaded.save(to: defaults)); XCTAssertThrowsError(try loaded.write(to: nil))
    }
}
