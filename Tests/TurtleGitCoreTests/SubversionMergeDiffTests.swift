import XCTest
@testable import TurtleGitCore

final class SubversionMergeDiffTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var helper: URL { root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff") }
    private var runtime: URL { root.appendingPathComponent("build/git-runtime/Git") }
    private var regex: URL { root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex") }
    private func plan(_ base: String, _ mine: String, _ theirs: String? = nil, filter: MergeRegexFilter? = nil) throws -> SubversionDiffPlan {
        try SubversionMergeDiff.plan(base: base, mine: mine, theirs: theirs, filter: filter, executable: helper, runtimeRoot: runtime, regexExecutable: regex)
    }
    func testTwoWayActualSubversionRangesAndEmptySources() throws {
        let result = try plan("head\nold\nlast", "head\nnew\nlast")
        XCTAssertEqual(result.segments.map(\.kind), [.common, .modified, .common])
        XCTAssertEqual(result.segments.map(\.base), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(result.segments.map(\.mine), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(result.base.joined(), "head\nold\nlast")
        XCTAssertNil(result.theirs)
        XCTAssertTrue(try plan("", "").segments.isEmpty)
        let insertion = try plan("", "new\n")
        XCTAssertEqual(insertion.segments[0].kind, .modified)
        XCTAssertTrue(insertion.segments[0].base.isEmpty)
        XCTAssertEqual(insertion.segments[0].mine, 0..<1)
    }
    func testThreeWayCommonOneSideSameAndConflicts() throws {
        let base = "head\nbase\nlast\n", mine = "head\nmine\nlast\n", theirs = "head\ntheirs\nlast\n"
        XCTAssertEqual(try plan(base, mine, base).segments.map(\.kind), [.common, .modified, .common])
        XCTAssertEqual(try plan(base, base, theirs).segments.map(\.kind), [.common, .latest, .common])
        XCTAssertEqual(try plan(base, mine, mine).segments.map(\.kind), [.common, .same, .common])
        let conflict = try plan(base, mine, theirs)
        XCTAssertEqual(conflict.segments.map(\.kind), [.common, .conflict, .common])
        XCTAssertTrue(conflict.hasConflicts)
        XCTAssertEqual(conflict.segments[1].base, 1..<2)
        XCTAssertEqual(conflict.segments[1].mine, 1..<2)
        XCTAssertEqual(conflict.segments[1].theirs, 1..<2)
    }
    func testFilteredThreeWayRemovesOnlyKeyDifferencesAndRetainsOriginals() throws {
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let base = "version 12\r\nbase\r\n", mine = "version 81\r\nmine\r\n", theirs = "version 90\r\ntheirs\r\n"
        let result = try plan(base, mine, theirs, filter: filter)
        XCTAssertEqual(result.segments.map(\.kind), [.common, .conflict])
        XCTAssertEqual(result.base.joined(), base); XCTAssertEqual(result.mine.joined(), mine); XCTAssertEqual(result.theirs?.joined(), theirs)
        let ignoreAll = try plan("date 12", "date 81", "date 90", filter: filter)
        XCTAssertFalse(ignoreAll.hasConflicts)
        XCTAssertEqual(ignoreAll.segments.map(\.kind), [.common])
        let eol = try plan("date 12\r\n", "date 81\n", "date 90\r\n", filter: filter)
        XCTAssertEqual(eol.segments.map(\.kind), [.modified])
    }
    func testAllNineEndingsUnicodeAndReplacementNewlinesRemainOneTokenPerSourceLine() throws {
        for ending in MergeLineEnding.allCases {
            let text = "雪🦎\0value" + ending.rawValue + "last"
            let result = try plan(text, text, text)
            XCTAssertEqual(result.segments.map(\.kind), [.common])
            XCTAssertEqual(result.segments[0].base.count, 2)
            XCTAssertEqual(result.base.joined(), text)
        }
        let filter = MergeRegexFilter(name: "Expanded key", expression: "[0-9]+", replacement: "x\ny")
        let result = try plan("v 12\n", "v 81\n", "v 90\n", filter: filter)
        XCTAssertEqual(result.segments[0].base.count, 1)
        XCTAssertEqual(result.mine, ["v 81\n"])
    }
    func testRepeatedLinesAndAdjacentRegionsAccountForEveryOriginalLine() throws {
        let values = ["", "a\n", "a\na\n", "a\nb\na", "b\na\nb"]
        for base in values {
            for mine in values {
                let theirs = values[(base.utf8.count + mine.utf8.count) % values.count]
                let value = try plan(base, mine, theirs)
                XCTAssertEqual(value.segments.flatMap { Array(value.base[$0.base]) }.joined(), base)
                XCTAssertEqual(value.segments.flatMap { Array(value.mine[$0.mine]) }.joined(), mine)
                XCTAssertEqual(value.segments.flatMap { Array(value.theirs![$0.theirs]) }.joined(), theirs)
            }
        }
    }
    func testCancelledMissingLibrariesAndMalformedMappingAreRejected() throws {
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try SubversionMergeDiff.plan(base: "a", mine: "b", executable: helper, runtimeRoot: runtime, cancellation: token))
        XCTAssertThrowsError(try SubversionMergeDiff.plan(base: "a", mine: "b", executable: helper, runtimeRoot: URL(fileURLWithPath: "/missing/merge-libraries")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBadMergeMapping-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("fake")
        try Data("#!/bin/sh\nprintf 'svn-diff\\t1\\t2\\ncommon\\t0\\t99\\t0\\t99\\t0\\t0\\n'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        XCTAssertThrowsError(try SubversionMergeDiff.plan(base: "a", mine: "a", executable: fake, runtimeRoot: runtime))
    }
}
