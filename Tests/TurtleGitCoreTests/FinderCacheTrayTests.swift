import XCTest
@testable import TurtleGitCore

final class FinderCacheTrayTests:XCTestCase {
    func testSourceDefaultsExactEnabledValueAndPrivateCodec() throws {
        let suite="CacheTrayTests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        XCTAssertEqual(FinderCacheTrayPreferences.from(defaults:defaults),.init())
        defaults.set(2,forKey:"CacheTrayIcon");XCTAssertFalse(FinderCacheTrayPreferences.from(defaults:defaults).enabled)
        defaults.set(true,forKey:"CacheTrayIcon");defaults.set(false,forKey:"ShowAppContextMenuIcons")
        let value=FinderCacheTrayPreferences.from(defaults:defaults);XCTAssertTrue(value.enabled);XCTAssertFalse(value.showMenuIcons)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:folder)}
        let url=folder.appendingPathComponent("tray.json");try value.write(to:url);XCTAssertEqual(FinderCacheTrayPreferences.read(from:url),value)
        try Data("invalid".utf8).write(to:url);XCTAssertFalse(FinderCacheTrayPreferences.read(from:url).enabled)
    }
    func testSourceActivityRingAndUTF16BoundDoNotSplitGraphemes() {
        var log=FinderCacheActivityLog()
        for index in 0..<30{log.append("Updating path: \(index)")}
        XCTAssertEqual(log.lines.count,15);XCTAssertEqual(log.lines.first,"Updating path: 15");XCTAssertEqual(log.lines.last,"Updating path: 29")
        log.append(String(repeating:"👩🏽‍💻",count:600));XCTAssertLessThanOrEqual(log.lines.last!.utf16.count,520)
        XCTAssertTrue(log.lines.last!.allSatisfy{$0==Character("👩🏽‍💻")})
    }
    func testMenuModePatchPreservesOtherFieldsAndDamagedRecord() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        let url=folder.appendingPathComponent("overlays.json");var value=FinderOverlaySettings();value.excludePaths="/private/*";value.hiddenStates=[.ignored];value.iconSet = .modern
        try value.write(to:url);try FinderOverlaySettings.updateCacheMode(.none,at:url)
        var expected=value;expected.cacheMode = .none;XCTAssertEqual(FinderOverlaySettings.read(from:url),expected)
        let suite="CacheOverlay."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        try value.save(to:defaults);XCTAssertEqual(FinderOverlaySettings.effective(defaults:defaults,shared:url),expected)
        let damaged=Data("damaged".utf8);try damaged.write(to:url)
        XCTAssertThrowsError(try FinderOverlaySettings.updateCacheMode(.standard,at:url));XCTAssertEqual(try Data(contentsOf:url),damaged)
        XCTAssertEqual(FinderOverlaySettings.effective(defaults:defaults,shared:url),value)
    }
}
