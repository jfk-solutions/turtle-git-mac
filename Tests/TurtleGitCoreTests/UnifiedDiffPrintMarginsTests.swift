import XCTest
@testable import TurtleGitCore

final class UnifiedDiffPrintMarginsTests: XCTestCase {
    func testSourceDefaultsAndLocaleIndependentUnits() {
        let margins = UnifiedDiffPrintMargins()
        XCTAssertEqual(margins.left, 72); XCTAssertEqual(margins.top, 72)
        XCTAssertEqual(margins.right, 72); XCTAssertEqual(margins.bottom, 72)
        XCTAssertEqual(25.4 * UnifiedDiffMarginUnit.millimeters.pointsPerUnit, 72, accuracy: 0.000001)
        XCTAssertEqual(UnifiedDiffMarginUnit.inches.pointsPerUnit, 72)
    }
    func testStoredMarginsSurviveInvalidEditsAndCorruptDataRecovers() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = UnifiedDiffPrintMargins(); saved.left = 0; saved.top = 36; saved.right = 90; saved.bottom = 144
        XCTAssertTrue(saved.save(to: defaults)); XCTAssertEqual(UnifiedDiffPrintMargins.load(from: defaults), saved)
        var invalid = saved; invalid.left = -1
        XCTAssertFalse(invalid.save(to: defaults)); XCTAssertEqual(UnifiedDiffPrintMargins.load(from: defaults), saved)
        invalid.left = .infinity; XCTAssertFalse(invalid.save(to: defaults))
        defaults.set(Data("{\"left\":-1,\"top\":0,\"right\":0,\"bottom\":0}".utf8), forKey: "TurtleGit.UnifiedDiffPrintMargins")
        XCTAssertEqual(UnifiedDiffPrintMargins.load(from: defaults), UnifiedDiffPrintMargins())
    }
    func testMarginValidationLeavesPositivePrintableArea() {
        var margins = UnifiedDiffPrintMargins()
        XCTAssertTrue(margins.fits(width: 612, height: 792))
        margins.left = 540; XCTAssertFalse(margins.fits(width: 612, height: 792))
        margins.left = 0; margins.right = 0; margins.top = 0; margins.bottom = 0
        XCTAssertTrue(margins.fits(width: 612, height: 792))
        XCTAssertFalse(margins.fits(width: 0, height: 792))
        XCTAssertFalse(margins.fits(width: .nan, height: 792))
    }
}
