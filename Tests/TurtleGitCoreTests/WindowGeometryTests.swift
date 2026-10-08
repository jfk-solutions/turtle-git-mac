import XCTest
@testable import TurtleGitCore

final class WindowGeometryTests: XCTestCase {
    func fixture(_ body: (UserDefaults, WindowGeometryStore) throws -> Void) throws {
        let suite = "TurtleGit.Geometry.Tests." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        try body(prefs, WindowGeometryStore(preferences: prefs))
    }
    func testRoundTripInvalidFramesAndCorruptData() throws {
        try fixture { prefs, store in
            let frame = SavedWindowGeometry(x: -500, y: 80, width: 1000, height: 700)
            store.save(frame, identifier: "Log"); XCTAssertEqual(store.load("Log"), frame)
            store.save(.init(x: .nan, y: 0, width: 100, height: 100), identifier: "Bad"); XCTAssertNil(store.load("Bad"))
            store.save(.init(x: 0, y: 0, width: -1, height: 100), identifier: "Bad"); XCTAssertNil(store.load("Bad"))
            prefs.set(Data("bad".utf8), forKey: WindowGeometryStore.prefix + "Bad"); XCTAssertNil(store.load("Bad"))
        }
    }
    func testRemovedMonitorOversizeAndMinimumAreFittedToVisibleArea() {
        let screen = SavedWindowGeometry(x: -1200, y: 40, width: 1200, height: 800)
        let removed = SavedWindowGeometry(x: 9000, y: -2000, width: 2000, height: 1400)
        XCTAssertEqual(removed.fitted(to: screen, minimumWidth: 500, minimumHeight: 300), screen)
        let small = SavedWindowGeometry(x: -1100, y: 100, width: 20, height: 20)
        XCTAssertEqual(small.fitted(to: screen, minimumWidth: 500, minimumHeight: 300), .init(x: -1100, y: 100, width: 500, height: 300))
    }
    func testLegacyFramesAreReadAndClearedWithoutResettingUnrelatedLayoutOrSettings() throws {
        try fixture { prefs, store in
            prefs.set("20 30 900 700 0 0 1920 1080", forKey: "NSWindow Frame RenameDialog")
            XCTAssertEqual(store.load("RenameDialog", legacyName: "RenameDialog"), .init(x: 20, y: 30, width: 900, height: 700))
            store.save(.init(x: 40, y: 50, width: 600, height: 400), identifier: "Log")
            for key in ["NSWindow Frame UnrelatedApp", "NSTableView Columns TurtleGit.Log.RevisionColumns", "CommitLastAction", "Clone.URLHistory"] { prefs.set("keep", forKey: key) }
            let data = SavedDataStore(preferences: prefs); XCTAssertEqual(data.summary(.dialogGeometry).histories, 2)
            data.clear(.dialogGeometry); XCTAssertNil(store.load("Log")); XCTAssertNil(store.load("RenameDialog", legacyName: "RenameDialog"))
            for key in ["NSWindow Frame UnrelatedApp", "NSTableView Columns TurtleGit.Log.RevisionColumns", "CommitLastAction", "Clone.URLHistory"] { XCTAssertEqual(prefs.string(forKey: key), "keep") }
        }
    }
}
