import XCTest
@testable import TurtleGitCore
final class ImageComparisonBlendTests: XCTestCase {
    func testSourceEndpointsAndSeventeenSliderPositions() {
        XCTAssertEqual(ImageComparisonBlend.toggled(0.5), 0)
        XCTAssertEqual(ImageComparisonBlend.toggled(0.01), 0)
        XCTAssertEqual(ImageComparisonBlend.toggled(0), 1)
        XCTAssertEqual(ImageComparisonBlend.sliderValue(0.52), 0.5)
        XCTAssertEqual(ImageComparisonBlend.sliderValue(0.54), 9.0/16)
        XCTAssertEqual(ImageComparisonBlend.sliderValue(-1), 0)
        XCTAssertEqual(ImageComparisonBlend.sliderValue(2), 1)
    }
    func testSourceQuarterStepWheelAndBounds() {
        XCTAssertEqual(ImageComparisonBlend.wheel(0.5, steps: 1), 0.25)
        XCTAssertEqual(ImageComparisonBlend.wheel(0.5, steps: -1), 0.75)
        XCTAssertEqual(ImageComparisonBlend.wheel(0.1, steps: 1), 0)
        XCTAssertEqual(ImageComparisonBlend.wheel(0.9, steps: -1), 1)
    }
}
