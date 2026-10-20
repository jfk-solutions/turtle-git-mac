import XCTest
@testable import TurtleGitCore

final class AdvancedSettingsTests: XCTestCase {
    func testListThresholdDwordsAndLegacyWarningMigrationMatchSource() throws {
        let suite = "TurtleGit.ListBehavior." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AdvancedListBehavior(defaults: defaults)
        XCTAssertTrue(initial.localBranchesFirst); XCTAssertFalse(initial.hidesFileList(count: 1000)); XCTAssertTrue(initial.hidesFileList(count: 1001))
        XCTAssertFalse(initial.warnsBeforeDiffs(count: 10)); XCTAssertTrue(initial.warnsBeforeDiffs(count: 11))
        defaults.set(0, forKey: "NumDiffWarning"); defaults.set(0, forKey: "LogTooManyItemsThreshold"); defaults.set(true, forKey: "NoSortLocalBranchesFirst")
        let changed = AdvancedListBehavior(defaults: defaults)
        XCTAssertFalse(changed.localBranchesFirst); XCTAssertTrue(changed.hidesFileList(count: 1)); XCTAssertFalse(changed.warnsBeforeDiffs(count: 3)); XCTAssertTrue(changed.warnsBeforeDiffs(count: 4))
        defaults.set(-1, forKey: "LogTooManyItemsThreshold"); XCTAssertFalse(AdvancedListBehavior(defaults: defaults).hidesFileList(count: 1000000))
        defaults.removeObject(forKey: "NumDiffWarning"); defaults.set(25, forKey: "TurtleGit.NumDiffWarning")
        let store = AdvancedSettingsStore(defaults: defaults), setting = AdvancedSettingDefinition.all.first { $0.name == "NumDiffWarning" }!
        XCTAssertEqual(store.value(for: setting), "25"); XCTAssertFalse(AdvancedListBehavior(defaults: defaults).warnsBeforeDiffs(count: 20))
        try store.apply(["NumDiffWarning": "3"])
        XCTAssertNil(defaults.object(forKey: "TurtleGit.NumDiffWarning")); XCTAssertTrue(AdvancedListBehavior(defaults: defaults).warnsBeforeDiffs(count: 4))
        try store.apply(["NumDiffWarning": ""]); XCTAssertEqual(AdvancedListBehavior(defaults: defaults).diffWarning, 10)
    }

    func withDefaults(_ body: (UserDefaults, AdvancedSettingsStore) throws -> Void) throws {
        let name = "TurtleGit.Advanced.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, AdvancedSettingsStore(defaults: defaults))
    }
    func testCatalogueMatchesPinnedSourceDefinitions() throws {
        struct Fixture: Decodable { let settings: [Item] }
        struct Item: Decodable { let name: String; let type: String; let `default`: Value }
        enum Value: Decodable { case boolean(Bool), number(UInt32)
            init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let b = try? c.decode(Bool.self) { self = .boolean(b) } else { self = .number(try c.decode(UInt32.self)) } }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("docs/upstream-advanced-settings.json")))
        XCTAssertEqual(fixture.settings.count, 52)
        XCTAssertEqual(AdvancedSettingDefinition.all.map(\.name), fixture.settings.map(\.name))
        for (actual, expected) in zip(AdvancedSettingDefinition.all, fixture.settings) {
            switch (actual.kind, expected.default) {
            case (.boolean(let a), .boolean(let b)): XCTAssertEqual(expected.type, "boolean"); XCTAssertEqual(a, b, actual.name)
            case (.dword(let a), .number(let b)): XCTAssertEqual(expected.type, "dword"); XCTAssertEqual(a, b, actual.name)
            default: XCTFail("Type mismatch for \(actual.name)")
            }
        }
    }
    func testBooleanEditingAndBlankRestoresDefaultWithoutWritingUnchangedDefaults() throws {
        try withDefaults { defaults, store in
            try store.apply(store.values()); XCTAssertNil(defaults.object(forKey: "ShowListBackgroundImage"))
            XCTAssertTrue(AdvancedListBehavior(defaults:defaults).fullRowSelect)
            XCTAssertNil(defaults.object(forKey:"FullRowSelect"))
            try store.apply(["FullRowSelect":"false"])
            XCTAssertFalse(AdvancedListBehavior(defaults:defaults).fullRowSelect)
            let accepted=AdvancedListBehavior(defaults:defaults)
            XCTAssertThrowsError(try store.apply(["FullRowSelect":"true","AutoCompleteMinChars":"invalid"]))
            XCTAssertEqual(AdvancedListBehavior(defaults:defaults).fullRowSelect,accepted.fullRowSelect)
            try store.apply(["FullRowSelect":""])
            XCTAssertNil(defaults.object(forKey:"FullRowSelect"))
            XCTAssertTrue(AdvancedListBehavior(defaults:defaults).fullRowSelect)
            defaults.set(2,forKey:"FullRowSelect")
            XCTAssertTrue(AdvancedListBehavior(defaults:defaults).fullRowSelect,"Source treats any nonzero stored DWORD as enabled")
            defaults.removeObject(forKey:"FullRowSelect")
            try store.apply(["ShowListBackgroundImage": "false", "AutocompleteParseUnversioned": "true"])
            XCTAssertFalse(defaults.bool(forKey: "ShowListBackgroundImage")); XCTAssertTrue(defaults.bool(forKey: "AutocompleteParseUnversioned"))
            try store.apply(["ShowListBackgroundImage": "", "AutocompleteParseUnversioned": ""])
            XCTAssertNil(defaults.object(forKey: "ShowListBackgroundImage")); XCTAssertNil(defaults.object(forKey: "AutocompleteParseUnversioned"))
            XCTAssertEqual(store.values()["ShowListBackgroundImage"], "true"); XCTAssertEqual(store.values()["AutocompleteParseUnversioned"], "false")
        }
    }
    func testValidationRejectsInvalidBatchBeforeMutation() throws {
        try withDefaults { defaults, store in
            for invalid in ["TRUE", "False", " true", "1"] { XCTAssertThrowsError(try store.apply(["StyleCommitMessages": invalid])) }
            for invalid in ["-1", "+1", "1.0", " 3", "3 ", "٣"] {
                XCTAssertThrowsError(try store.apply(["ShowListBackgroundImage": "false", "AutoCompleteMinChars": invalid]))
                XCTAssertNil(defaults.object(forKey: "ShowListBackgroundImage")); XCTAssertNil(defaults.object(forKey: "AutoCompleteMinChars"))
            }
        }
    }
    func testDWORDZeroLeadingZerosOverflowAndSignedStoredDisplay() throws {
        try withDefaults { defaults, store in
            try store.apply(["AutoCompleteMinChars": "0003"])
            XCTAssertNil(defaults.object(forKey: "AutoCompleteMinChars"), "Equivalent numeric input must not create an override")
            try store.apply(["AutoCompleteMinChars": "0"]); XCTAssertEqual(store.values()["AutoCompleteMinChars"], "0")
            try store.apply(["AutoCompleteMinChars": String(repeating: "0", count: 200) + "12"]); XCTAssertEqual(store.values()["AutoCompleteMinChars"], "12")
            try store.apply(["AutoCompleteMinChars": String(repeating: "9", count: 200)]); XCTAssertEqual(store.values()["AutoCompleteMinChars"], "2147483647")
            defaults.set(Int(UInt32.max), forKey: "AutoCompleteMinChars")
            XCTAssertEqual(store.values()["AutoCompleteMinChars"], "-1")
            try store.apply(store.values()); XCTAssertEqual((defaults.object(forKey: "AutoCompleteMinChars") as? NSNumber)?.uint32Value, UInt32.max)
            try store.apply(["AutoCompleteMinChars": ""]); XCTAssertEqual(store.values()["AutoCompleteMinChars"], "3")
        }
    }
}
