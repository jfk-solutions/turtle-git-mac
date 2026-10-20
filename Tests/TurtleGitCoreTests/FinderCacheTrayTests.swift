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
    func testServiceMenuModeTransactionPreservesAdvancedPolicyAndRejectsOldReaders()throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        let overlays=folder.appendingPathComponent("overlay-settings.json"),status=folder.appendingPathComponent("status.json"),store=FinderSnapshotStore(url:status)
        var settings=FinderOverlaySettings();settings.cacheMode = .shellExtended;settings.includePaths="/repo/*";settings.iconSet = .modern;_ = try settings.write(to:overlays)
        let advanced=FinderStatusPolicyPreferences(caseSensitive:false,contentCheckLimitKiB:777,blockStatus:true);_ = try advanced.write(to:status)
        let original=FinderStatusPolicy(settings:settings,preferences:advanced),owner=try store.startSession();defer{_ = try? store.endSession(owner)}
        let pending=try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:original)
        try FinderCacheTrayStatusPolicy.setCacheMode(.none,overlaysURL:overlays,statusURL:status)
        var expected=settings;expected.cacheMode = .none
        XCTAssertEqual(try FinderOverlaySettings.readChecked(from:overlays),expected)
        XCTAssertEqual(try FinderStatusPolicyPreferences.read(from:status),advanced)
        XCTAssertThrowsError(try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:original))
        var stale=FinderSnapshot(roots:["/repo"],states:["/repo/file":.modified]);stale.recordOverlay(policy:original,caseSensitive:false,entries:stale.states,indexFlags:[:])
        XCTAssertFalse(try store.publish(pending,snapshots:[stale]).published)
        let accepted=FinderStatusPolicy(settings:expected,preferences:advanced)
        XCTAssertNoThrow(try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:accepted))
        try FinderCacheTrayStatusPolicy.setCacheMode(.standard,overlaysURL:overlays,statusURL:status)
        XCTAssertEqual(try FinderStatusPolicy.read(from:status).cacheMode,.standard)
        XCTAssertEqual(try FinderStatusPolicyPreferences.read(from:status),advanced)
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
