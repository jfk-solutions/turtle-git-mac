import XCTest
@testable import TurtleGitCore

final class SubversionMergePresentationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func configuration(_ filter: MergeRegexFilter? = nil) -> SubversionMergeConfiguration {
        .init(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"),
              regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"), filter: filter)
    }
    private func presentation(_ base: String, _ mine: String, _ theirs: String, filter: MergeRegexFilter? = nil) throws -> SubversionMergePresentation {
        try .init(plan: configuration(filter).plan(base: base, mine: mine, theirs: theirs))
    }
    func testConflictSourceAliasesKeepActualBytesAndDistinctPadding() throws {
        let mine="mine one\r\nmine two\r\n",theirs="theirs\r\n"
        let value=try presentation("base\r\n",mine,theirs)
        XCTAssertTrue(value.sources.rows.contains {$0.mine.state == .conflictAdded})
        XCTAssertTrue(value.sources.rows.contains {$0.theirs.state == .conflictEmpty})
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows:value.sources.rows,mine:true,keepRemoved:false),mine)
        XCTAssertFalse(MergePaneSaveAs.sourceText(rows:value.sources.rows,mine:true,keepRemoved:false).contains("<<<<<<<"))
        XCTAssertEqual(value.sources.rows.compactMap {$0.theirs.lineNumber == nil ? nil:$0.theirs.text}.joined(),theirs)
        let counts=MergeLineStatistics(states:value.sources.rows.map { $0.mine.state })
        XCTAssertEqual(counts.added,2);XCTAssertEqual(counts.removed,1);XCTAssertEqual(counts.conflicted,0)
        let locator=MergeLocatorMap(columns:[value.sources.rows.map {$0.mine.state},value.sources.rows.map {$0.theirs.state}])
        XCTAssertTrue(locator.columns[1].contains {$0.state == .conflictEmpty})
    }
    func testTwoPaneSubversionPresentationRetainsRowsGapsAndTransferBytes() throws {
        let base = "head\r\nold\r\nlast", destination = "head\r\nnew\r\nextra\r\nlast"
        let value = try SubversionComparisonPresentation(plan: configuration().plan(base: base, mine: destination)).alignment
        XCTAssertEqual(value.rows.compactMap { $0.base.lineNumber == nil ? nil : $0.base.text }.joined(), base)
        XCTAssertEqual(value.rows.compactMap { $0.destination.lineNumber == nil ? nil : $0.destination.text }.joined(), destination)
        XCTAssertEqual(value.differences, [1..<3])
        XCTAssertEqual(value.rows[2].base.state, .empty)
        let edit = try FileComparisonEditing.takingOtherRows(value, rows: value.differences[0], targetBase: true)
        XCTAssertEqual(edit.text, destination)
        let display = value.rows.map { $0.destination.displayText + "\n" }.joined() as NSString
        let range = display.range(of: "extra")
        XCTAssertEqual(try FileComparisonEditing.sourceRange(range, cells: value.rows.map(\.destination)), (destination as NSString).range(of: "extra"))
    }
    func testTwoPaneFilteredKeysAndRepeatedLinesKeepOriginalContentAndAnnotationNumbers() throws {
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let base = "stamp 12\na\na\nold\na", destination = "stamp 81\na\na\nnew\na"
        let value = try SubversionComparisonPresentation(plan: configuration(filter).plan(base: base, mine: destination)).alignment
        XCTAssertEqual(value.rows[0].base.state, .filtered)
        XCTAssertEqual(value.differences, [3..<4])
        XCTAssertEqual(value.rows.map(\.base.text).joined(), base)
        XCTAssertEqual(value.rows.map(\.destination.text).joined(), destination)
        let projection = FileComparisonAlignment(base: base, destination: destination)
        let marks = FileComparisonEditing.Annotations(marked: [3], edited: [3])
        let remapped = marks.remapped(from: projection, to: value, targetBase: false, typing: false)
        XCTAssertEqual(remapped.marked, [3]); XCTAssertEqual(remapped.edited, [3])
    }
    func testIndependentChangesAndOriginalSourceReconstruction() throws {
        let base = "head\nfirst\nmiddle\nsecond\nlast", mine = "head\nMINE\nmiddle\nsecond\nlast", theirs = "head\nfirst\nmiddle\nTHEIRS\nlast"
        let value = try presentation(base, mine, theirs)
        XCTAssertEqual(value.result, "head\nMINE\nmiddle\nTHEIRS\nlast")
        XCTAssertEqual(value.sources.resultLocator?.states, [.normal, .yoursAdded, .normal, .theirsAdded, .normal])
        XCTAssertEqual(value.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), mine)
        XCTAssertEqual(value.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), theirs)
        XCTAssertTrue(value.sources.rows.contains { $0.mine.state == .yoursRemoved && $0.theirs.state == .normal })
        XCTAssertTrue(value.sources.rows.contains { $0.mine.state == .normal && $0.theirs.state == .theirsRemoved })
    }
    func testIdenticalChangesAddAddAndUnequalConflictsPreserveSources() throws {
        let identical = try presentation("base\n", "changed\n", "changed\n")
        XCTAssertEqual(identical.result, "changed\n")
        XCTAssertEqual(identical.sources.rows.map(\.mine.state), [.identicalRemoved, .identicalAdded])
        let added = try presentation("", "mine\n", "theirs\nmore\n")
        XCTAssertEqual(MergeText.conflicts(in: added.result).count, 1)
        XCTAssertEqual(added.sources.resultLocator?.states.count, MergeRegexFilters.lines(added.result).count)
        XCTAssertTrue(added.sources.resultLocator?.states.allSatisfy { $0 == .conflicted } == true)
        XCTAssertEqual(added.sources.rows.last?.mine.state, .conflictEmpty)
        XCTAssertNil(added.sources.rows.last?.mine.lineNumber)
        XCTAssertEqual(added.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), "mine\n")
        XCTAssertEqual(added.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), "theirs\nmore\n")
    }
    func testResolvedFirstChildPadsRemovedBaseWithoutResolvingSharedParent() throws {
        let mine = "shared1\nshared2\nmine\n", theirs = "shared1\nshared2\ntheirs\n"
        let value = try presentation("base\n", mine, theirs)
        XCTAssertEqual(value.sources.rows.count, 5)
        XCTAssertEqual(value.sources.rows[0].mine.text, "base\n")
        XCTAssertEqual(value.sources.rows[1].mine.text, "")
        XCTAssertEqual(value.sources.rows[1].mine.state, .identicalRemoved)
        XCTAssertNil(value.sources.rows[1].mine.lineNumber)
        XCTAssertEqual(value.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), mine)
        XCTAssertEqual(value.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), theirs)
        let blocks = MergeText.conflicts(in: value.result)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].mine, mine); XCTAssertEqual(blocks[0].theirs, theirs)
        XCTAssertEqual(blocks[0].replacement(.mineThenTheirs), mine + theirs)
    }
    func testFilteredCommonChoosesOriginalMineAndRetainsGreenSourceRows() throws {
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let value = try presentation("version 12\r\n", "version 81\r\n", "version 90\r\n", filter: filter)
        XCTAssertEqual(value.result, "version 81\r\n")
        XCTAssertEqual(value.sources.rows[0].mine.state, .filtered)
        XCTAssertEqual(value.sources.rows[0].theirs.text, "version 90\r\n")
        XCTAssertFalse(MergeText.hasMarkers(value.result))
    }
    func testEveryEndingCanDelimitConflictMarkersAndRetainsSourceText() throws {
        for ending in MergeLineEnding.allCases {
            let mine = "mine" + ending.rawValue, theirs = "theirs" + ending.rawValue
            let value = try presentation("base" + ending.rawValue, mine, theirs)
            let blocks = MergeText.conflicts(in: value.result)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?.replacement(.mine), mine)
            XCTAssertEqual(blocks.first?.replacement(.theirs), theirs)
        }
    }
    func testEngineBackedDocumentAndSavePreserveRepositoryUntilExplicitResolution() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEngineMerge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = GitRepository(root: folder, executable: URL(fileURLWithPath: "/usr/bin/git")), file = folder.appendingPathComponent("sample.txt")
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Engine QA"), ("user.email", "engine@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.autocrlf", "false")] { _ = try await repository.run(["config", key, value]) }
        try Data("version 1\nbase".utf8).write(to: file)
        _ = try await repository.run(["add", "--", "sample.txt"]); _ = try await repository.run(["commit", "-m", "base"])
        _ = try await repository.run(["checkout", "-b", "side"])
        try Data("version 3\ntheirs".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "theirs"])
        _ = try await repository.run(["checkout", "main"])
        try Data("version 2\nmine".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "mine"])
        _ = try await repository.run(["merge", "side"], successfulExitCodes: 0...1)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: folder.appendingPathComponent(".git/index")), working = try Data(contentsOf: file)
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let document = try await repository.textConflictDocument(path: "sample.txt", engine: configuration(filter))
        XCTAssertNotNil(document.mergeSources)
        XCTAssertEqual(document.mergeSources?.rows[0].mine.state, .filtered)
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".git/index")), index)
        let result = try MergeText.applying(.mine, block: 0, to: document.initialResult, document: document)
        XCTAssertEqual(result, "version 2\nmine")
        let saved = try await repository.saveTextConflict(document, result: result, markResolved: false)
        XCTAssertNotNil(saved.mergeSources)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".git/index")), index)
        _ = try await repository.saveTextConflict(saved, result: result, markResolved: true)
        let stages = try await repository.conflicts(), afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(stages.isEmpty); XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: file), Data(result.utf8))
    }
}

final class MergeLocatorTests: XCTestCase {
    func testLocatorCompressesActualRowsAndUsesLongestPane() {
        let map = MergeLocatorMap(columns: [[.normal, .normal, .removed, .removed, .empty], [], [.normal, .added]])
        XCTAssertEqual(map.lineCount, 5)
        XCTAssertEqual(map.columns[0].map(\.rows), [0..<2, 2..<4, 4..<5])
        XCTAssertEqual(map.columns[0].map(\.state), [.normal, .removed, .empty])
        XCTAssertTrue(map.columns[1].isEmpty)
        XCTAssertEqual(map.row(at: -2), 0); XCTAssertEqual(map.row(at: 0.5), 2)
        XCTAssertEqual(map.row(at: 2), 4); XCTAssertEqual(map.row(at: .nan), 0)
        XCTAssertEqual(MergeLocatorMap(columns: []).row(at: 1), 0)
    }
    func testLocatorRetainsInitialEngineColorsTracksEditsAndConflicts() {
        let text = "雪🦎\r\nadded\r\ntail", first = "雪🦎\r\n".utf16.count, added = "added\r\n".utf16.count
        let result = MergeLocatorResult(text: text, spans: [(0..<first, .filtered), (first..<first + added, .added), (first + added..<text.utf16.count, .normal)])
        XCTAssertEqual(result.states, [.filtered, .added, .normal])
        XCTAssertEqual(result.states(for: text, conflicts: []), result.states)
        let changed = "雪🦎\r\nmanual\r\nextra\r\ntail"
        XCTAssertEqual(result.states(for: changed, conflicts: []), [.filtered, .added, .added, .normal])
        let range = (changed as NSString).range(of: "manual\r\nextra\r\n")
        XCTAssertEqual(result.states(for: changed, conflicts: [range]), [.filtered, .conflicted, .conflicted, .normal])
        XCTAssertEqual(result.states(for: "", conflicts: []), [])
    }
    func testSourceDefaultsAndSavedLocatorChoicesUsePrivatePreferences() {
        let suite = "TurtleGit.Locator." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), .init(visible: true, fishEye: true))
        let hidden = MergeLocatorPreferences(visible: false, fishEye: false)
        hidden.save(to: defaults); XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), hidden)
        MergeLocatorPreferences().save(to: defaults); XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), .init())
    }
}
