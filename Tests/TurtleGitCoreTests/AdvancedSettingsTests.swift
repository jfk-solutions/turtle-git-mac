import XCTest
@testable import TurtleGitCore

final class AdvancedSettingsTests: XCTestCase {
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
