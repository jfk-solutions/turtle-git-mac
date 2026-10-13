import XCTest
@testable import TurtleGitCore

final class ReplayRowDragTests: XCTestCase {
    func rows() -> [RebaseEntry] {
        (0..<5).map { index in RebaseEntry(commit:LogEntry(hash:String(index),author:"a",date:"d",subject:String(index))) }
    }
    func testContiguousRotationBeforeAfterAndSourceNoOpRange() throws {
        let rows = rows(), drag = try XCTUnwrap(ReplayRowDrag(visible:rows,selected:["1","2"]))
        XCTAssertEqual(drag.reordered(visible:rows,before:0)?.map(\.id),["1","2","0","3","4"])
        XCTAssertEqual(drag.reordered(visible:rows,before:5)?.map(\.id),["0","3","4","1","2"])
        for destination in [1,2,3,-1,6] { XCTAssertNil(drag.reordered(visible:rows,before:destination)) }
        XCTAssertNil(ReplayRowDrag(visible:rows,selected:["0","2"])); XCTAssertNil(ReplayRowDrag(visible:rows,selected:["missing"]))
    }
    func testOccurrenceIdentityActionsMainlineAndStaleSnapshots() throws {
        var rows = rows(); var repeated = rows[0]; repeated.occurrence = 1; repeated.action = .edit; repeated.mainline = 2
        rows.insert(repeated,at:1)
        let drag = try XCTUnwrap(ReplayRowDrag(visible:rows,selected:["0","0:1"]))
        let moved = try XCTUnwrap(drag.reordered(visible:rows,before:rows.count))
        XCTAssertEqual(moved.suffix(2).map(\.id),["0","0:1"]); XCTAssertEqual(moved.last?.action,.edit); XCTAssertEqual(moved.last?.mainline,2)
        var changed = rows; changed[0].action = .skip; XCTAssertFalse(drag.matches(changed))
        changed = rows; changed[0].progress = .current; XCTAssertFalse(drag.matches(changed))
        changed = rows; changed.swapAt(3,4); XCTAssertFalse(drag.matches(changed))
        changed = rows; changed[0].mainline = 1; XCTAssertFalse(drag.matches(changed))
        XCTAssertNil(ReplayRowDrag(visible:[rows[0],rows[0]],selected:["0"]))
    }
}
