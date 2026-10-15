import XCTest
@testable import TurtleGitCore

final class MergeEditorPreferencesTests: XCTestCase {
    func testSourceStateAliasesUsePaletteChannelsAndSourceStatusCounts() {
        for state in [MergeSourceState.identicalRemoved,.yoursRemoved,.theirsRemoved] {XCTAssertEqual(state.colorRole,.removed)}
        for state in [MergeSourceState.identicalAdded,.yoursAdded,.theirsAdded] {XCTAssertEqual(state.colorRole,.added)}
        for state in [MergeSourceState.conflictAdded,.conflictEmpty,.conflictedIgnored] {XCTAssertEqual(state.colorRole,.conflicted)}
        var palette=MergeColorPreferences()
        for dark in [false,true] {
            for state in MergeSourceState.allCases {
                let value=palette.stateColors(state,dark:dark)
                XCTAssertEqual(value.background,palette.colors(state.colorRole,dark:dark).background)
                XCTAssertEqual(value.foreground,palette.colors(state == .edited ? .added:state.colorRole,dark:dark).foreground)
            }
        }
        palette.light[.empty]=UnifiedDiffColors(0x112233,0x234567)
        palette.light[.conflicted]=UnifiedDiffColors(0x345678,0x456789)
        XCTAssertEqual(palette.stateColors(.conflictEmpty,dark:false,applied:false),UnifiedDiffColors(0x345678,0x456789))
        XCTAssertEqual(palette.stateColors(.conflictEmpty,dark:false,applied:true),UnifiedDiffColors(0x345678,0x234567))
        let counts=MergeLineStatistics(states:MergeSourceState.allCases)
        XCTAssertEqual(counts.added,5);XCTAssertEqual(counts.removed,4);XCTAssertEqual(counts.conflicted,2)
        XCTAssertTrue(MergeLineStatistics(states:[.normal,.empty,.conflictEmpty,.filtered]).isEmpty)
    }
    func testDefaultsPersistenceAndBounds() throws {
        let name = "TurtleGitMerge.PreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults), MergeEditorPreferences())
        let saved = MergeEditorPreferences(tabWidth: 7, useSpaces: true, smartTab: true, showLineNumbers: false, enableEditorConfig: true)
        saved.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), saved)
        defaults.removeObject(forKey: "TurtleGitMerge.EnableEditorConfig")
        XCTAssertFalse(MergeEditorPreferences.load(from: defaults).enableEditorConfig)
        defaults.removeObject(forKey: "TurtleGitMerge.ShowLineNumbers")
        XCTAssertTrue(MergeEditorPreferences.load(from: defaults).showLineNumbers)
        defaults.set(-5, forKey: "TurtleGitMerge.TabSize")
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1)
        defaults.set(1001, forKey: "TurtleGitMerge.TabSize")
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1000)
        var edited = MergeEditorPreferences(); edited.tabWidth = 0; edited.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1)
        edited.tabWidth = 2000; edited.save(to: defaults)
        XCTAssertEqual(MergeEditorPreferences.load(from: defaults).tabWidth, 1000)
    }
}
