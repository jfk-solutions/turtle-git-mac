import XCTest
@testable import TurtleGitCore

final class HistoryPresentationTests: XCTestCase {
    func testPathQueryUsesCurrentAndOldNamesWithSourceWordRules() {
        let renamed = CommitFile(path: "Sources/New Core.swift", oldPath: "Legacy/Old Core.swift", action: "R100", added: 0, removed: 0, hasStatistics: true, isSubmodule: false)
        for query in ["", "new core", "old legacy", "\"old core\"", "missing +legacy", "legacy -tests", "!tests", "NEW"] {
            XCTAssertTrue(HistoryFileFilter(query).matches(renamed), query)
        }
        for query in ["missing", "new -legacy", "!legacy", "\"new missing\"", "!"] {
            XCTAssertFalse(HistoryFileFilter(query).matches(renamed), query)
        }
    }
    func testInformationRetainsSourceRangeWorkingRowAndSelectionRules() {
        let working = LogEntry(hash: "", author: "", date: "", subject: "Working tree")
        let latest = LogEntry(hash: String(repeating: "a", count: 40), author: "", date: "", subject: "latest")
        let oldest = LogEntry(hash: String(repeating: "b", count: 40), author: "", date: "", subject: "oldest")
        let files = [CommitFile(path: "one", oldPath: nil, action: "M", added: 3, removed: 1, hasStatistics: true, isSubmodule: false), CommitFile(path: "two", oldPath: nil, action: "A", added: nil, removed: nil, hasStatistics: true, isSubmodule: false)]
        let info = HistoryInformation(entries: [working, latest, oldest], selected: [working.hash], files: files, selectedFiles: ["one", "two", "stale"], visibleFileIDs: ["one"])
        XCTAssertEqual(info.revisionCount, 2); XCTAssertEqual(info.oldest, "bbbbbbbb"); XCTAssertEqual(info.newest, "aaaaaaaa")
        XCTAssertEqual(info.selectedRevisionCount, 1); XCTAssertEqual(info.selectedFileCount, 1)
        XCTAssertTrue(info.text.contains("line: 3(+) 1(-) files: Modified = 1 Added = 1 Deleted = 0 Renamed = 0"))
        let multiple = HistoryInformation(entries: [latest, oldest], selected: [latest.hash, oldest.hash], files: files, selectedFiles: ["one"], visibleFileIDs: ["one"])
        XCTAssertFalse(multiple.text.contains("line:")); XCTAssertEqual(multiple.selectedRevisionCount, 2)
        let none = HistoryInformation(entries: [], selected: ["stale"], files: files, selectedFiles: ["one"], visibleFileIDs: ["one"])
        XCTAssertEqual(none.selectedFileCount, 0); XCTAssertEqual(none.revisionCount, 0)
        XCTAssertEqual(HistoryInformation(entries: [working], selected: [], files: [], selectedFiles: [], visibleFileIDs: []).revisionCount, 1)
    }
    func testStatisticsIncludeAllParentOccurrencesAndHiddenFiles() {
        let row = LogEntry(hash: "hash", author: "", date: "", subject: "merge")
        func file(_ path: String, _ action: String, _ added: Int?, _ removed: Int?, parent: Int? = nil) -> CommitFile { .init(path: path, oldPath: nil, action: action, added: added, removed: removed, hasStatistics: added != nil, isSubmodule: false, parentIndex: parent) }
        let files = [file("same", "R100", 2, 1, parent: 0), file("same", "M", 4, 3, parent: 1), file("copy", "C100", 1, 0), file("binary", "D", nil, nil), file("type", "T", 0, 0), file("unknown", "?", nil, nil)]
        let info = HistoryInformation(entries: [row], selected: [row.hash], files: files, selectedFiles: Set(files.map(\.id)), visibleFileIDs: [files[0].id])
        XCTAssertEqual(info.modified, 3); XCTAssertEqual(info.added, 1); XCTAssertEqual(info.deleted, 1); XCTAssertEqual(info.renamed, 1)
        XCTAssertEqual(info.addedLines, 7); XCTAssertEqual(info.removedLines, 4); XCTAssertEqual(info.selectedFileCount, 1)
    }
    func testExactFileSelectionCountsKeepUnicodeAndParentOccurrences() {
        let a = "café.txt", b = "cafe\u{301}.txt"
        let row = LogEntry(hash: "hash", author: "", date: "", subject: "merge")
        let files = [a,b].flatMap { path in (0...1).map { parent in
            CommitFile(path: path, oldPath: nil, action: "M", added: 1, removed: 1, hasStatistics: true, isSubmodule: false, parentIndex: parent)
        } }
        let ids = files.map(\.id)
        let all = HistoryInformation(entries: [row], selected: [row.hash], files: files, selectedFiles: ids, visibleFileIDs: ids)
        XCTAssertEqual(all.selectedFileCount, 4)
        let oneSpelling = files.filter { GitReferenceName.equal($0.path,a) }.map(\.id)
        XCTAssertEqual(HistoryInformation(entries: [row], selected: [row.hash], files: files, selectedFiles: ids, visibleFileIDs: oneSpelling).selectedFileCount, 2)
        XCTAssertEqual(HistoryInformation(entries: [row], selected: [row.hash], files: files, selectedFiles: [files[0].id], visibleFileIDs: [files[2].id]).selectedFileCount, 0)
    }
    func testReferenceScopeUsesSourceNumericValuesAndRepositoryStore() {
        let suite = "TurtleGit.LogScope." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let root = URL(fileURLWithPath:"/tmp/Harbor"), other = URL(fileURLWithPath:"/tmp/Other")
        XCTAssertEqual(HistoryReferenceScopePreference.load(root:root,defaults:prefs),.current)
        for (scope,value) in [(HistoryReferenceScope.current,0),(.all,1),(.local,2),(.basic,3)] {
            HistoryReferenceScopePreference.save(scope,root:root,defaults:prefs)
            XCTAssertEqual(prefs.integer(forKey:HistoryReferenceScopePreference.key(root:root)),value)
            XCTAssertEqual(HistoryReferenceScopePreference.load(root:root.appendingPathComponent("."),defaults:prefs),scope)
            XCTAssertEqual(HistoryReferenceScopePreference.load(root:other,defaults:prefs),.current)
        }
        prefs.set(99,forKey:HistoryReferenceScopePreference.key(root:root))
        XCTAssertEqual(HistoryReferenceScopePreference.load(root:root,defaults:prefs),.current)
    }
    func testPaneLayoutKeepsProportionsAndClampsAllThreeMinimums() throws {
        let layout = try XCTUnwrap(HistoryPaneLayout(heights:[600,200,200]))
        XCTAssertEqual(layout.heights(available:1000),[600,200,200])
        let small = layout.heights(available:500)
        XCTAssertEqual(small.reduce(0,+),500,accuracy:0.0001)
        for (height,minimum) in zip(small,HistoryPaneLayout.minimumHeights) { XCTAssertGreaterThanOrEqual(height,minimum) }
        XCTAssertEqual(layout.heights(available:440),[200,110,130])
        XCTAssertEqual(layout.heights(available:220),[100,55,65])
        XCTAssertEqual(layout.heights(available:.infinity),[0,0,0])
        XCTAssertEqual(layout.heights(available:0),[0,0,0])
    }
    func testPaneLayoutRejectsCorruptionAndRestoresSuppliedPreferenceStore() throws {
        let suite = "TurtleGit.LogPanes." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        for invalid in [[Double](),[1,2],[1,0,1],[-1,2,3],[.nan,1,1],[.infinity,1,1],[Double.leastNonzeroMagnitude,Double.greatestFiniteMagnitude,1]] { XCTAssertNil(HistoryPaneLayout(heights:invalid)) }
        XCTAssertNil(HistoryPaneLayout.load(defaults:prefs))
        let layout = try XCTUnwrap(HistoryPaneLayout(heights:[450,160,290])); layout.save(defaults:prefs)
        XCTAssertEqual(HistoryPaneLayout.load(defaults:prefs)?.heights(available:900),[450,160,290])
        prefs.set([1,2],forKey:HistoryPaneLayout.key); XCTAssertNil(HistoryPaneLayout.load(defaults:prefs))
        prefs.set([1,2,3],forKey:HistoryPaneLayout.key); prefs.set(2,forKey:HistoryPaneLayout.key + ".Version")
        XCTAssertNil(HistoryPaneLayout.load(defaults:prefs))
    }
    func testWholeProjectDefaultsAndPersistenceAreRepositoryAndStoreScoped() {
        let suite = "TurtleGit.HistoryPresentation." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/tmp/Harbor"), other = URL(fileURLWithPath: "/tmp/Other")
        XCTAssertFalse(HistoryWholeProjectPreference.load(root: root, defaults: defaults))
        HistoryWholeProjectPreference.save(true, root: root, defaults: defaults)
        XCTAssertTrue(HistoryWholeProjectPreference.load(root: root.appendingPathComponent("."), defaults: defaults))
        XCTAssertFalse(HistoryWholeProjectPreference.load(root: other, defaults: defaults))
        HistoryWholeProjectPreference.save(false, root: root, defaults: defaults)
        XCTAssertFalse(HistoryWholeProjectPreference.load(root: root, defaults: defaults))
    }
}
