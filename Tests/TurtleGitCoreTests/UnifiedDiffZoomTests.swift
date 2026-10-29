// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class UnifiedDiffZoomTests:XCTestCase {
    func testInteractiveBoundsResetAndIndependentInstances() {
        var zoom=UnifiedDiffZoom()
        XCTAssertEqual(zoom.level,0);XCTAssertFalse(zoom.canPerform(.reset));XCTAssertFalse(zoom.perform(.reset))
        for expected in 1...60 {XCTAssertTrue(zoom.perform(.zoomIn));XCTAssertEqual(zoom.level,expected)}
        XCTAssertFalse(zoom.canPerform(.zoomIn));XCTAssertFalse(zoom.perform(.zoomIn));XCTAssertEqual(zoom.level,60)
        for expected in stride(from:59,through:-10,by:-1) {XCTAssertTrue(zoom.perform(.zoomOut));XCTAssertEqual(zoom.level,expected)}
        XCTAssertFalse(zoom.canPerform(.zoomOut));XCTAssertFalse(zoom.perform(.zoomOut));XCTAssertEqual(zoom.level,-10)
        XCTAssertTrue(zoom.perform(.reset));XCTAssertEqual(zoom.level,0)
        XCTAssertEqual(UnifiedDiffZoom().level,0)
    }
    func testEffectiveFontSizeUsesAdditivePointsAndMinimumWithoutClampingBaseToZoomRange() {
        var zoom=UnifiedDiffZoom()
        for _ in 0..<10 {_ = zoom.perform(.zoomOut)}
        for base in 1...1000 {XCTAssertEqual(zoom.effectiveFontSize(base:base),max(1,base-10))}
        _ = zoom.perform(.reset)
        for _ in 0..<60 {_ = zoom.perform(.zoomIn)}
        for base in 1...1000 {XCTAssertEqual(zoom.effectiveFontSize(base:base),base+60)}
        XCTAssertEqual(zoom.effectiveFontSize(base:1000),1060,"A valid large base font is independent of the zoom-level bounds")
        _ = zoom.perform(.reset);XCTAssertEqual(zoom.effectiveFontSize(base:10),10)
    }
    func testWheelPartialTicksAndReversalFollowSignedSourceRemainder() {
        var wheel=UnifiedDiffZoomWheelAccumulator()
        XCTAssertNil(wheel.command(sourceDelta:60))
        XCTAssertNil(wheel.command(sourceDelta:-30))
        XCTAssertEqual(wheel.command(sourceDelta:90),.zoomIn)
        XCTAssertNil(wheel.command(sourceDelta:-119))
        XCTAssertEqual(wheel.command(sourceDelta:-1),.zoomOut)
        XCTAssertNil(wheel.command(sourceDelta:119))
        XCTAssertNil(wheel.command(sourceDelta:-119),"Opposite partial ticks cancel rather than each becoming an action")
        XCTAssertEqual(wheel.command(sourceDelta:-120),.zoomOut)
    }
    func testLargeDeliveredWheelEventProducesOneCommandAndRetainsOnlyPartialTick() {
        var wheel=UnifiedDiffZoomWheelAccumulator()
        XCTAssertEqual(wheel.command(sourceDelta:300),.zoomIn)
        XCTAssertNil(wheel.command(sourceDelta:-120),"The retained +60 source units are first canceled")
        XCTAssertEqual(wheel.command(sourceDelta:-60),.zoomOut)
        XCTAssertEqual(wheel.command(sourceDelta:-12000),.zoomOut)
        XCTAssertNil(wheel.command(sourceDelta:0))
        XCTAssertEqual(wheel.command(sourceDelta:12000),.zoomIn)
        XCTAssertNil(wheel.command(sourceDelta:0))
    }
    func testFractionalInputResetAndNonfiniteEventsDoNotCorruptPendingTick() {
        var wheel=UnifiedDiffZoomWheelAccumulator()
        XCTAssertNil(wheel.command(sourceDelta:119.5))
        for invalid in [Double.nan,Double.infinity,-Double.infinity] {XCTAssertNil(wheel.command(sourceDelta:invalid))}
        XCTAssertEqual(wheel.command(sourceDelta:0.5),.zoomIn)
        XCTAssertNil(wheel.command(sourceDelta:119.5));wheel.reset()
        XCTAssertNil(wheel.command(sourceDelta:0.5))
        XCTAssertEqual(wheel.command(sourceDelta:119.5),.zoomIn)
        XCTAssertEqual(wheel.command(sourceDelta:Double.greatestFiniteMagnitude),.zoomIn)
        wheel.reset();XCTAssertEqual(wheel.command(sourceDelta:-Double.greatestFiniteMagnitude),.zoomOut)
    }
    func testWheelPolicyNeverPersistsOrChangesAnEditorBeyondItsInteractiveBound() {
        var wheel=UnifiedDiffZoomWheelAccumulator(),zoom=UnifiedDiffZoom()
        for _ in 0..<75 {
            if let command=wheel.command(sourceDelta:120) {_ = zoom.perform(command)}
        }
        XCTAssertEqual(zoom.level,60)
        XCTAssertEqual(wheel.command(sourceDelta:-120),.zoomOut)
        XCTAssertTrue(zoom.perform(.zoomOut));XCTAssertEqual(zoom.level,59)
        XCTAssertEqual(UnifiedDiffZoom().level,0)
    }
}
