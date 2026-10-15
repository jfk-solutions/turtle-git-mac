import XCTest
@testable import TurtleGitCore

final class MergeBlockNavigationTests: XCTestCase {
    func target(_ states: [MergeSourceState], _ caret: Int, _ direction: Int, visible: [Int]? = nil, conflicts: Bool = false, skip: Bool = true) -> MergeBlockNavigation.Target? {
        MergeBlockNavigation.target(states: states, visibleRows: visible ?? Array(states.indices), caret: caret, direction: direction, conflictsOnly: conflicts, skipCurrent: skip)
    }
    func testWhitespaceAliasesAreSeparateBlocksEvenThoughTheyUseNormalColors() {
        let states: [MergeSourceState] = [.normal,.removedWhitespace,.addedWhitespace,.normal,.removed,.removed,.added,.normal]
        XCTAssertEqual(target(states, 0, 1)?.rows, 1..<2)
        XCTAssertEqual(target(states, 1, 1)?.rows, 2..<3)
        XCTAssertEqual(target(states, 2, 1)?.rows, 4..<6)
        XCTAssertEqual(target(states, 4, 1)?.rows, 6..<7)
        XCTAssertEqual(target(states, 6, -1)?.rows, 4..<6)
        XCTAssertEqual(target(states, 6, -1)?.caret, 5)
        XCTAssertEqual(target(states, 5, -1)?.rows, 2..<3)
    }
    func testDirectionalEmptyPaddingAndFixedInitialState() {
        let states: [MergeSourceState] = [.normal,.removed,.empty,.added,.normal]
        XCTAssertEqual(target(states, 0, 1)?.rows, 1..<3)
        XCTAssertEqual(target(states, 4, -1)?.rows, 3..<4)
        XCTAssertEqual(target(states, 3, -1)?.rows, 1..<3)
        // Source compares every row against the entry state, not the previous row.
        XCTAssertEqual(target([.normal,.empty,.added,.removed,.normal], 4, -1)?.rows, 3..<4)
        XCTAssertEqual(target([.normal,.empty,.added,.removed,.normal], 1, -1, skip:false)?.rows, 1..<2)
    }
    func testFilteredRowsAreExcludedAndConflictStatesRemainDistinct() {
        let states: [MergeSourceState] = [.normal,.filtered,.added,.conflictAdded,.conflictEmpty,.conflictedIgnored,.conflicted,.resolved]
        XCTAssertEqual(target(states, 0, 1)?.rows, 2..<3)
        XCTAssertEqual(target(states, 0, 1, conflicts:true)?.rows, 3..<5)
        XCTAssertEqual(target(states, 3, 1, conflicts:true)?.rows, 5..<6)
        XCTAssertEqual(target(states, 5, 1, conflicts:true)?.rows, 6..<7)
        XCTAssertNil(target(states, 6, 1, conflicts:true))
        XCTAssertEqual(target(states, 7, -1, conflicts:true)?.rows, 6..<7)
        XCTAssertEqual(target(states, 5, -1, conflicts:true)?.rows, 3..<5)
        XCTAssertEqual(target(states, 5, -1, conflicts:true)?.caret, 4)
    }
    func testVisibleProjectionOmitsHiddenRowsButRetainsMarkerState() {
        let states: [MergeSourceState] = [.normal,.removedWhitespace,.addedWhitespace,.normal,.added,.normal]
        XCTAssertEqual(target(states, 0, 1, visible:[0,3,4,5])?.rows, 4..<5)
        XCTAssertEqual(target(states, 0, 1, visible:[0,1,4,5])?.rows, 1..<2)
        XCTAssertEqual(target([.normal,.added,.normal,.added], 0, 1, visible:[0,1,3])?.rows, 1..<4)
    }
    func testNoWrapBoundariesFirstDifferenceAndClampedCaret() {
        let states: [MergeSourceState] = [.added,.normal,.removed]
        XCTAssertNil(target(states, 0, -1))
        XCTAssertNil(target(states, 2, 1))
        XCTAssertEqual(target(states, 0, 1, skip:false)?.rows, 0..<1)
        XCTAssertEqual(target(states, 100, -1)?.rows, 0..<1)
        XCTAssertNil(target([], 0, 1))
        XCTAssertNil(target(states, 0, 0))
        XCTAssertNil(target(states, 0, 1, visible:[0,4]))
        XCTAssertNil(target(states, 0, 1, visible:[1,0]))
    }
    func testContextBlockUsesClickedStateInBothDirections() {
        let states: [MergeSourceState] = [.normal,.removed,.empty,.added,.normal,.normal]
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:1)?.rows,1..<3)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:2)?.rows,1..<3)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:3)?.rows,3..<4)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:4)?.rows,4..<6)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:2)?.caret,2)
        XCTAssertNil(MergeBlockNavigation.block(states:states,containing:-1))
        XCTAssertNil(MergeBlockNavigation.block(states:[],containing:0))
    }
    func testContextBlockKeepsWhitespaceAndConflictAliasesDistinct() {
        let states: [MergeSourceState] = [.removedWhitespace,.addedWhitespace,.conflictAdded,.conflictEmpty,.filtered,.filtered]
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:0)?.rows,0..<1)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:1)?.rows,1..<2)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:2)?.rows,2..<4)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:3)?.rows,2..<4)
        XCTAssertEqual(MergeBlockNavigation.block(states:states,containing:4)?.rows,4..<6)
    }
    func testEveryStateEligibilityAndEquality() {
        for state in MergeSourceState.allCases {
            let states: [MergeSourceState] = [.normal,state,state,.normal]
            XCTAssertEqual(target(states, 0, 1)?.rows, state.isUnchanged ? nil : 1..<3, "\(state)")
            XCTAssertEqual(target(states, 3, -1, conflicts:true)?.rows, state.isConflict ? 1..<3 : nil, "\(state)")
        }
    }
}

final class MergeNavigationMapTests: XCTestCase {
    let entries: [MergeNavigationMap.Entry] = [
        .init(sourceRows:0..<1,resultRange:NSRange(location:0,length:5)),
        .init(sourceRows:1..<5,resultRange:NSRange(location:5,length:20)),
        .init(sourceRows:5..<6,resultRange:NSRange(location:25,length:5))]
    func testEngineGroupCoordinatesAreIndependent() {
        let map=MergeNavigationMap(entries:entries)
        XCTAssertEqual(map.resultRange(sourceRows:2..<3),NSRange(location:5,length:20))
        XCTAssertEqual(map.sourceRows(resultRange:NSRange(location:8,length:2)),1..<5)
        XCTAssertEqual(map.sourceRows(resultRange:NSRange(location:4,length:22)),0..<6)
        XCTAssertEqual(map.resultRange(sourceRows:0..<6),NSRange(location:0,length:30))
        XCTAssertNil(map.resultRange(sourceRows:8..<9))
        XCTAssertNil(map.sourceRows(resultRange:NSRange(location:30,length:0)))
    }
    func testResolvedReplacementAndOutsideEditShiftRelationships() {
        let map=MergeNavigationMap(entries:entries).replacing(NSRange(location:5,length:20),replacementLength:3)
        XCTAssertEqual(map.entries.map(\.resultRange),[NSRange(location:0,length:5),NSRange(location:5,length:3),NSRange(location:8,length:5)])
        let after=map.replacing(NSRange(location:1,length:2),replacementLength:4)
        XCTAssertEqual(after.entries.map(\.resultRange),[NSRange(location:0,length:7),NSRange(location:7,length:3),NSRange(location:10,length:5)])
    }
    func testCrossBoundaryEditInvalidatesOnlyAmbiguousGroups() {
        let map=MergeNavigationMap(entries:entries).replacing(NSRange(location:3,length:6),replacementLength:2)
        XCTAssertEqual(map.entries,[.init(sourceRows:5..<6,resultRange:NSRange(location:21,length:5))])
    }
    func testInsertionBoundariesAndDeletionAnchors() {
        let map=MergeNavigationMap(entries:entries).replacing(NSRange(location:5,length:0),replacementLength:2)
        XCTAssertEqual(map.entries.map(\.resultRange),[NSRange(location:0,length:5),NSRange(location:7,length:20),NSRange(location:27,length:5)])
        let empty=MergeNavigationMap(entries:[.init(sourceRows:0..<2,resultRange:NSRange(location:0,length:0))])
        XCTAssertEqual(empty.resultRange(sourceRows:0..<1),NSRange(location:0,length:0))
        XCTAssertEqual(empty.sourceRows(resultRange:NSRange(location:0,length:0)),0..<2)
        XCTAssertTrue(empty.replacing(NSRange(location:0,length:0),replacementLength:1).entries.isEmpty)
    }
    func testPresentationSnapshotsCarryMappingsThroughResolutionAndUndo() throws {
        let text="head\nconflict contentsxx\nlast\n"
        let map=MergeNavigationMap(entries:entries)
        let before=MergeResultPresentation(text:text,states:[],navigationMap:map)
        let next=try XCTUnwrap(before.replacing(NSRange(location:5,length:20),with:"ok\n",state:.resolved))
        XCTAssertEqual(next.navigationMap.resultRange(sourceRows:2..<3),NSRange(location:5,length:3))
        XCTAssertEqual(before.navigationMap,map)
        XCTAssertNotEqual(before,MergeResultPresentation(text:text,states:[]))
        XCTAssertEqual(before.reconciling(text),before)
    }
}
