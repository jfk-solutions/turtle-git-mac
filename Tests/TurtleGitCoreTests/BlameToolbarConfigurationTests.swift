import XCTest
@testable import TurtleGitCore

final class BlameToolbarConfigurationTests: XCTestCase {
    private func privateDefaults() -> (UserDefaults, String) {
        let suite = "TurtleGit.Blame.Toolbar.Tests." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }
    func testSourceDefaultAndEntireCommandPalette() {
        XCTAssertEqual(BlameToolbarConfiguration.defaults.standard.items, ["open", "space", "previousChange", "nextChange", "space", "copy", "space", "about"])
        XCTAssertTrue(BlameToolbarConfiguration.defaults.standard.isVisible)
        XCTAssertTrue(BlameToolbarConfiguration.defaults.customBars.isEmpty)
        for command in BlameToolbarCommand.allCases {
            XCTAssertTrue(BlameToolbarCommand.isKnownItem(command.rawValue))
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertNotNil(MenuIcon(rawValue: command.iconName), command.rawValue)
            XCTAssertEqual(command.accessibilityIdentifier, "Blame.Toolbar.Command." + command.rawValue)
        }
        for choice in GitBlameEncodingMenu.unicode + GitBlameEncodingMenu.groups.flatMap(\.choices) where choice.encoding != nil {
            let id = "encoding.\(choice.codePage)"
            XCTAssertTrue(BlameToolbarCommand.availableItemIDs.contains(id))
            XCTAssertEqual(BlameToolbarCommand.encoding(for: id), choice.encoding)
            XCTAssertEqual(BlameToolbarCommand.title(for: id), "Encoding: " + choice.title)
        }
        XCTAssertFalse(BlameToolbarCommand.isKnownItem("encoding.999999"))
        XCTAssertFalse(BlameToolbarCommand.isKnownItem("runArbitraryCommand"))
    }
    func testRoundTripNamedBarsOrderVisibilityDisplayAndContextIsolation() throws {
        let (defaults, suite) = privateDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = BlameToolbarConfigurationStore(defaults: defaults, key: "first")
        var value = store.load()
        let searchID = try XCTUnwrap(value.createBar(name: "Search"))
        let historyID = try XCTUnwrap(value.createBar(name: "History"))
        value.standard.items = []; value.standard.isVisible = false
        value.customBars[0].items = ["find", "space", "findNext", "findPrevious", "flexibleSpace", "encoding.65001"]
        value.customBars[0].displayMode = .labels
        value.customBars[1].items = ["previousChange", "nextChange", "log"]
        value.customBars[1].isVisible = false
        value.customBars.swapAt(0, 1)
        store.save(value)
        XCTAssertEqual(BlameToolbarConfigurationStore(defaults: defaults, key: "first").load(), value)
        XCTAssertEqual(value.customBars.map(\.id), [historyID, searchID])
        // A separate settings key sees only the intentional legacy visibility migration.
        let separate = BlameToolbarConfigurationStore(defaults: defaults, key: "second").load()
        XCTAssertTrue(separate.customBars.isEmpty)
        XCTAssertEqual(separate.standard.items, BlameToolbarConfiguration.defaults.standard.items)
        XCTAssertFalse(separate.standard.isVisible)
        let (otherDefaults, otherSuite) = privateDefaults(); defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        XCTAssertEqual(BlameToolbarConfigurationStore(defaults: otherDefaults).load(), .defaults)
    }
    func testCRUDRejectsDuplicateNamesAndProtectsStandardIdentity() throws {
        var value = BlameToolbarConfiguration.defaults
        let id = try XCTUnwrap(value.createBar(name: "  History\n"))
        XCTAssertEqual(value.customBars[0].name, "History")
        XCTAssertNil(value.createBar(name: "hístory"))
        XCTAssertNil(value.createBar(name: " Standard "))
        XCTAssertNil(value.createBar(name: "\n\0"))
        XCTAssertFalse(value.renameBar(id: id, name: "Standard"))
        XCTAssertFalse(value.removeBar(id: BlameToolbarConfiguration.standardID))
        XCTAssertFalse(value.renameBar(id: BlameToolbarConfiguration.standardID, name: "Mine"))
        XCTAssertTrue(value.renameBar(id: id, name: " Search "))
        XCTAssertEqual(value.customBars[0].name, "Search")
        XCTAssertTrue(value.removeBar(id: id)); XCTAssertFalse(value.removeBar(id: id))
        XCTAssertEqual(value, .defaults)
    }
    func testSanitizationBoundsStaleIdentifiersRepeatedSpacersAndEmptyBars() {
        let id = UUID()
        var value = BlameToolbarConfiguration.defaults
        value.standard.id = UUID(); value.standard.name = "Impostor"
        value.standard.items = ["stale", "find", "find", "space", "space", "flexibleSpace", "flexibleSpace", "encoding.999999", "encoding.65001"]
        value.customBars = [
            .init(id: id, name: "A", items: []),
            .init(id: id, name: "Duplicate ID"),
            .init(name: "a"),
            .init(id: BlameToolbarConfiguration.standardID, name: "Reserved ID")
        ] + (0..<30).map { .init(name: "Bar\($0)", items: Array(repeating: "space", count: 150)) }
        let clean = value.sanitized()
        XCTAssertEqual(clean.standard.id, BlameToolbarConfiguration.standardID)
        XCTAssertEqual(clean.standard.name, "Standard")
        XCTAssertEqual(clean.standard.items, ["find", "space", "space", "flexibleSpace", "flexibleSpace", "encoding.65001"])
        XCTAssertEqual(clean.customBars.count, BlameToolbarConfiguration.maximumCustomBars)
        XCTAssertEqual(clean.customBars[0].items, [])
        XCTAssertEqual(Set(clean.allBars.map(\.id)).count, clean.allBars.count)
        XCTAssertEqual(clean.customBars[1].items.count, BlameToolbarConfiguration.maximumItemsPerBar)
        XCTAssertEqual(clean.sanitized(), clean)
    }
    func testCorruptPersistenceMigrationAndReset() throws {
        let (defaults, suite) = privateDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = BlameToolbarConfigurationStore(defaults: defaults)
        defaults.set(false, forKey: "Blame.ShowToolbar")
        XCTAssertFalse(store.load().standard.isVisible)
        defaults.set(Data("not JSON".utf8), forKey: BlameToolbarConfigurationStore.defaultKey)
        XCTAssertFalse(store.load().standard.isVisible)
        defaults.set(Data(repeating: 65, count: 262_145), forKey: BlameToolbarConfigurationStore.defaultKey)
        XCTAssertFalse(store.load().standard.isVisible)
        var value = BlameToolbarConfiguration.defaults
        value.standard.isVisible = true; value.standard.items = []
        _ = value.createBar(name: "My toolbar")
        store.save(value)
        defaults.set(false, forKey: "Blame.ShowToolbar")
        XCTAssertTrue(store.load().standard.isVisible) // New configuration wins over stale legacy value.
        XCTAssertEqual(store.load().standard.items, [])
        XCTAssertEqual(store.reset(), .defaults)
        XCTAssertEqual(store.load(), .defaults)
        XCTAssertTrue(defaults.bool(forKey: "Blame.ShowToolbar"))
    }
    func testUpdateCompositionPreservesOtherBarsAndVisibility() throws {
        var value = BlameToolbarConfiguration.defaults
        let first = try XCTUnwrap(value.createBar(name: "First"))
        _ = try XCTUnwrap(value.createBar(name: "Second"))
        var bar = try XCTUnwrap(value.customBars.first(where: { $0.id == first }))
        bar.items = ["copy", "space", "find", "copy", "unknown"]
        bar.displayMode = .icons; bar.isVisible = false
        value.updateBar(bar)
        XCTAssertEqual(value.customBars[0].items, ["copy", "space", "find"])
        XCTAssertEqual(value.customBars[0].displayMode, .icons)
        XCTAssertFalse(value.customBars[0].isVisible)
        XCTAssertTrue(value.customBars[1].isVisible)
        let previous = value
        for invalid in ["", "Second", "Standard", "\n\0"] {
            var draft = bar; draft.name = invalid
            value.updateBar(draft)
            XCTAssertEqual(value, previous, "A temporary invalid name must not remove a toolbar")
        }
        var standard = value.standard; standard.items = ["reload", "find"]
        value.updateBar(standard)
        XCTAssertEqual(value.standard.items, ["reload", "find"])
        value.reset(); XCTAssertEqual(value, .defaults)
    }
}
