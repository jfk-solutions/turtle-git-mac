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
        let second = try XCTUnwrap(value.createBar(name: "Second"))
        let epoch = value.generation
        XCTAssertTrue(value.moveBar(id: second, offset: -1))
        XCTAssertEqual(value.customBars.map(\.id), [second, id])
        XCTAssertNotEqual(value.generation, epoch)
        let unchanged = value.generation
        XCTAssertFalse(value.moveBar(id: id, offset: Int.max))
        XCTAssertFalse(value.moveBar(id: id, offset: Int.min))
        XCTAssertFalse(value.moveBar(id: BlameToolbarConfiguration.standardID, offset: 1))
        XCTAssertEqual(value.generation, unchanged)
        XCTAssertTrue(value.removeBar(id: second))
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

extension BlameToolbarConfigurationTests {
    func testPlacementRoundTripAndLegacyV1Decoding() throws {
        let (defaults, suite) = privateDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = BlameToolbarConfigurationStore(defaults: defaults)
        var value = BlameToolbarConfiguration.defaults
        for placement in BlameToolbarPlacement.allCases {
            let id = try XCTUnwrap(value.createBar(name: placement.rawValue))
            var bar = try XCTUnwrap(value.customBars.first(where: { $0.id == id }))
            bar.placement = placement; bar.dockOrder = 4; bar.lastDockPlacement = .right; bar.lastDockOrder = 3; bar.items = ["find", "space", "copy"]
            bar.floatingRect = .init(x: -240, y: 320, width: 480, height: 64)
            value.updateBar(bar)
        }
        let top = try XCTUnwrap(value.customBars.first(where: { $0.placement == .top }))
        XCTAssertFalse(value.reorderDockBars([top.id, top.id], at: .top))
        XCTAssertFalse(value.reorderDockBars([top.id], at: .top))
        XCTAssertFalse(value.reorderDockBars([], at: .floating))
        XCTAssertTrue(value.reorderDockBars([top.id, BlameToolbarConfiguration.standardID], at: .top))
        XCTAssertEqual(value.standard.dockOrder, 1)
        XCTAssertEqual(value.standard.lastDockOrder, 1)
        XCTAssertEqual(value.customBars.first(where: { $0.id == top.id })?.dockOrder, 0)
        value.standard.placement = .bottom
        store.save(value)
        XCTAssertEqual(store.load(), value)
        XCTAssertEqual(store.load().generation, value.generation)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        legacy.removeValue(forKey: "generation")
        func oldBar(_ bar: [String: Any]) -> [String: Any] { var bar = bar; bar.removeValue(forKey: "placement"); bar.removeValue(forKey: "dockOrder"); bar.removeValue(forKey: "lastDockPlacement"); bar.removeValue(forKey: "lastDockOrder"); bar.removeValue(forKey: "floatingRect"); return bar }
        legacy["standard"] = oldBar(try XCTUnwrap(legacy["standard"] as? [String: Any]))
        legacy["customBars"] = try XCTUnwrap(legacy["customBars"] as? [[String: Any]]).map(oldBar)
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: BlameToolbarConfigurationStore.defaultKey)
        let migrated = store.load()
        XCTAssertTrue(migrated.allBars.allSatisfy { $0.placement == .top && $0.floatingRect == nil && $0.dockOrder == 0 && $0.lastDockPlacement == .top && $0.lastDockOrder == 0 })
        XCTAssertEqual(migrated.customBars.map(\.id), value.customBars.map(\.id))
        XCTAssertEqual(migrated.customBars.map(\.items), value.customBars.map(\.items))
        XCTAssertEqual(migrated.generation, store.load().generation)
    }
    func testFloatingGeometryRejectsInvalidAndClampsFiniteCoordinates() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(BlameToolbarFloatingRect(x: bad, y: 0, width: 200, height: 50).sanitized())
            XCTAssertNil(BlameToolbarFloatingRect(x: 0, y: bad, width: 200, height: 50).sanitized())
            XCTAssertNil(BlameToolbarFloatingRect(x: 0, y: 0, width: bad, height: 50).sanitized())
            XCTAssertNil(BlameToolbarFloatingRect(x: 0, y: 0, width: 200, height: bad).sanitized())
        }
        XCTAssertNil(BlameToolbarFloatingRect(x: 0, y: 0, width: 0, height: 50).sanitized())
        XCTAssertNil(BlameToolbarFloatingRect(x: 0, y: 0, width: 50, height: -1).sanitized())
        let clamped = BlameToolbarFloatingRect(x: -1e12, y: 1e12, width: 1, height: 1e12).sanitized()
        XCTAssertEqual(clamped, .init(x: -100_000, y: 100_000, width: 32, height: 4096))
        var value = BlameToolbarConfiguration.defaults
        value.standard.placement = .floating
        value.standard.floatingRect = .init(x: 0, y: 0, width: .nan, height: 50)
        XCTAssertNil(value.sanitized().standard.floatingRect)
        XCTAssertEqual(value.sanitized().standard.placement, .floating)
        value.standard.dockOrder = -1
        XCTAssertEqual(value.sanitized().standard.dockOrder, 0)
        value.standard.dockOrder = 1001
        XCTAssertEqual(value.sanitized().standard.dockOrder, 1000)
        value.standard.lastDockPlacement = .floating; value.standard.lastDockOrder = -100
        XCTAssertEqual(value.sanitized().standard.lastDockPlacement, .top)
        XCTAssertEqual(value.sanitized().standard.lastDockOrder, 0)
        value.standard.lastDockOrder = 1001
        XCTAssertEqual(value.sanitized().standard.lastDockOrder, 1000)
    }
    func testMoveWithinAndBetweenBarsPreservesPlacementAndRejectsDuplicates() throws {
        var value = BlameToolbarConfiguration.defaults
        let targetID = try XCTUnwrap(value.createBar(name: "Side"))
        var target = value.customBars[0]; target.placement = .right; target.items = ["find"]; value.updateBar(target)
        let first = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 0))
        XCTAssertTrue(value.transfer(first, to: BlameToolbarConfiguration.standardID, at: 8))
        XCTAssertEqual(value.standard.items, ["space", "previousChange", "nextChange", "space", "copy", "space", "about", "open"])
        let moved = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 7))
        XCTAssertTrue(value.transfer(moved, to: targetID, at: 0))
        XCTAssertEqual(value.customBars[0].items, ["open", "find"])
        XCTAssertEqual(value.customBars[0].placement, .right)
        let receipt = try XCTUnwrap(value.captureItem(barID: targetID, index: 1))
        XCTAssertTrue(value.transfer(receipt, to: BlameToolbarConfiguration.standardID, at: 0, copy: true))
        XCTAssertEqual(value.customBars[0].items, ["open", "find"])
        let duplicate = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 0))
        let before = value, epoch = value.generation
        XCTAssertFalse(value.transfer(duplicate, to: targetID, at: 0))
        XCTAssertEqual(value, before); XCTAssertEqual(value.generation, epoch)
    }
    func testRepeatedSpacerReceiptsStaleEpochAndNoOpDropsAreSafe() throws {
        var value = BlameToolbarConfiguration.defaults
        value.standard.items = ["find", "space", "copy", "space", "about"]
        let secondSpace = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 3))
        let unchanged = value, epoch = value.generation
        XCTAssertFalse(value.transfer(secondSpace, to: BlameToolbarConfiguration.standardID, at: 4))
        XCTAssertFalse(value.transfer(secondSpace, to: UUID(), at: 0))
        XCTAssertFalse(value.transfer(secondSpace, to: BlameToolbarConfiguration.standardID, at: -1))
        XCTAssertFalse(value.transfer(secondSpace, to: BlameToolbarConfiguration.standardID, at: 6))
        XCTAssertEqual(value, unchanged); XCTAssertEqual(value.generation, epoch)
        XCTAssertTrue(value.transfer(secondSpace, to: BlameToolbarConfiguration.standardID, at: 1))
        XCTAssertEqual(value.standard.items, ["find", "space", "space", "copy", "about"])
        XCTAssertFalse(value.transfer(secondSpace, to: BlameToolbarConfiguration.standardID, at: 0))
        let fresh = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 2))
        value.reset()
        XCTAssertFalse(value.transfer(fresh, to: BlameToolbarConfiguration.standardID, at: 0))
        XCTAssertEqual(value.standard.placement, .top); XCTAssertNil(value.standard.floatingRect)
    }
    func testDirectSourceChangesAndFullDestinationRefuseTransferWithoutLosingItems() throws {
        var value = BlameToolbarConfiguration.defaults
        let receipt = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 2))
        value.standard.items.swapAt(0, 1) // Defend callers that changed public composition without a model mutation.
        let changed = value
        XCTAssertFalse(value.transfer(receipt, to: BlameToolbarConfiguration.standardID, at: 0))
        XCTAssertEqual(value, changed)
        let targetID = try XCTUnwrap(value.createBar(name: "Full"))
        value.customBars[0].items = Array(repeating: "space", count: BlameToolbarConfiguration.maximumItemsPerBar)
        let fresh = try XCTUnwrap(value.captureItem(barID: BlameToolbarConfiguration.standardID, index: 2))
        let before = value
        XCTAssertFalse(value.transfer(fresh, to: targetID, at: 0))
        XCTAssertEqual(value, before)
        XCTAssertNil(value.captureItem(barID: targetID, index: 100))
        XCTAssertNil(value.captureItem(barID: UUID(), index: 0))
    }
    func testCancelledCapturePreservesPersistenceAndTransferSurvivesReload() throws {
        let (defaults, suite) = privateDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = BlameToolbarConfigurationStore(defaults: defaults)
        let initial = store.load()
        let receipt = try XCTUnwrap(initial.captureItem(barID: BlameToolbarConfiguration.standardID, index: 0))
        // Drag preparation and cancellation write nothing to the user's layout.
        XCTAssertNil(defaults.data(forKey: BlameToolbarConfigurationStore.defaultKey))
        var reloaded = store.load()
        XCTAssertTrue(reloaded.transfer(receipt, to: BlameToolbarConfiguration.standardID, at: 8))
        store.save(reloaded)
        XCTAssertEqual(store.load(), reloaded)
        XCTAssertEqual(store.load().generation, reloaded.generation)
        XCTAssertFalse(reloaded.transfer(receipt, to: BlameToolbarConfiguration.standardID, at: 0))
        let before = store.load()
        _ = before.captureItem(barID: BlameToolbarConfiguration.standardID, index: 1)
        XCTAssertEqual(store.load(), before)
        XCTAssertEqual(store.load().generation, before.generation)
    }
}
