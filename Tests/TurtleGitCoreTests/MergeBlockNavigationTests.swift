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
    func testEveryStateEligibilityAndEquality() {
        for state in MergeSourceState.allCases {
            let states: [MergeSourceState] = [.normal,state,state,.normal]
            XCTAssertEqual(target(states, 0, 1)?.rows, state.isUnchanged ? nil : 1..<3, "\(state)")
            XCTAssertEqual(target(states, 3, -1, conflicts:true)?.rows, state.isConflict ? 1..<3 : nil, "\(state)")
        }
    }
}
