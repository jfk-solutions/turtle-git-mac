import XCTest
@testable import TurtleGitCore

final class MergeFoldingTests: XCTestCase {
    func testPinnedForwardContextAndMarkers() {
        let folding = MergeFolding(unchanged: [true, true, true, false, true, true, true, true, true, false, true, true, true])
        // Pin the source's forward loop: it starts at i+1, retaining a hidden
        // first unchanged row after a change; the subsequent reverse-context
        // pass can expose it again before the marker.
        XCTAssertEqual(folding.visibility, [.marker, .hidden, .shown, .shown, .shown, .shown, .marker, .hidden, .shown, .shown, .shown, .shown, .marker])
        XCTAssertEqual(folding.visibleRows(collapsed: false), Array(0..<13))
    }
    func testAllUnchangedAndEmptyOrSingleLine() {
        XCTAssertEqual(MergeFolding(unchanged: []).visibility, [])
        XCTAssertEqual(MergeFolding(unchanged: [true]).visibility, [.hidden])
        XCTAssertEqual(MergeFolding(unchanged: [false]).visibility, [.shown])
        let folding = MergeFolding(unchanged: Array(repeating: true, count: 8))
        XCTAssertEqual(folding.visibleRows(collapsed: true), [0])
        XCTAssertEqual(folding.hiddenRange(at: 0), 0..<8)
    }
    func testSourceRangesAndSharedExpansion() {
        var folding = MergeFolding(unchanged: [true, true, true, true, false, false, true, true, true, true], contextLines: 0)
        let projection = MergeFoldProjection(folding: folding, collapsed: true)
        XCTAssertEqual(projection.rows, [.marker(0..<4), .source(4), .source(5), .marker(7..<10)])
        XCTAssertEqual(projection.screenRow(containing: 2), 0)
        XCTAssertNil(projection.sourceRow(at: -1))
        XCTAssertNil(projection.sourceRow(at: 50))
        XCTAssertEqual(folding.expand(marker: 0), 0..<4)
        XCTAssertNil(folding.expand(marker: 0))
        XCTAssertEqual(folding.reveal(row: 9), 7..<10)
        XCTAssertEqual(folding.reveal(row: 6), 6..<7)
        XCTAssertTrue(folding.visibility.allSatisfy { $0 == .shown })
    }
    func testUnlimitedContextAndChangedRowsRemainVisible() {
        let folding = MergeFolding(unchanged: [true, true, false, true, true, false, true, true], contextLines: Int.max)
        XCTAssertTrue(folding.visibility.allSatisfy { $0 == .shown })
        XCTAssertEqual(MergeFolding(unchanged: [false, false, false]).visibility, [.shown, .shown, .shown])
    }
    func testSavedDefaultAndSharedContextSentinel() {
        let name = "MergeFoldingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MergeFoldingPreferences.load(from: defaults), .init())
        MergeFoldingPreferences(collapsed: true).saveCollapsed(to: defaults)
        XCTAssertTrue(MergeFoldingPreferences.load(from: defaults).collapsed)
        defaults.set(-1, forKey: "TurtleGitMerge.ContextLines")
        XCTAssertEqual(MergeFoldingPreferences.load(from: defaults).contextLines, Int.max)
        defaults.set(3, forKey: "TurtleGitMerge.ContextLines")
        XCTAssertEqual(MergeFoldingPreferences.load(from: defaults).contextLines, 3)
    }
    func testResultAnchorsShiftWithoutRepeatedTextGuessing() {
        var anchors = MergeFoldAnchors(offsets: [0: 0, 1: 5, 2: 10])
        anchors.reconcile(old: "same\nsame\nlast\n", new: "new\nsame\nsame\nlast\n")
        XCTAssertEqual(anchors.offsets, [0: 4, 1: 9, 2: 14])
        XCTAssertEqual(anchors.resultRows(in: "new\nsame\nsame\nlast\n"), [0: 1, 1: 2, 2: 3])
        anchors.reconcile(old: "new\nsame\nsame\nlast\n", new: "new\nchanged\nsame\nlast\n")
        XCTAssertNil(anchors.offsets[0])
        XCTAssertEqual(anchors.resultRows(in: "new\nchanged\nsame\nlast\n")[1], 2)
    }
    func testResultPresentationUndoSnapshotIncludesAnchors() {
        let original = MergeResultPresentation(text: "head\ntail\n", states: [.normal, .normal], foldAnchors: .init(offsets: [0: 0, 1: 5]))
        let edited = original.replacing(NSRange(location: 0, length: 0), with: "new\n")!
        XCTAssertEqual(edited.foldAnchors.offsets, [0: 4, 1: 9])
        XCTAssertEqual(original.foldAnchors.offsets, [0: 0, 1: 5])
    }

}
