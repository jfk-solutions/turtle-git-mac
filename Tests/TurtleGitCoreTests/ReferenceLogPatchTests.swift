import XCTest
@testable import TurtleGitCore

final class ReferenceLogPatchTests: XCTestCase {
    func testEventSelectorsPreserveSourceRangeRulesWithDuplicateHashes() {
        let rows = (0..<5).map { index in ReferenceLogEntry(hash: index < 2 ? "same" : "hash\(index)", selector: "HEAD@{\(index)}", timestamp: "0 +0000", subject: "event") }
        let single = FormatPatchPreset.referenceLogSelection(entries: rows, selected: [rows[1].id])
        XCTAssertEqual(single, FormatPatchPreset(startRevision: "same"))
        let duplicate = FormatPatchPreset.referenceLogSelection(entries: rows, selected: [rows[0].id,rows[1].id])
        XCTAssertEqual(duplicate, FormatPatchPreset(startRevision: "same~1", endRevision: "same"))
        XCTAssertEqual(FormatPatchPreset.referenceLogSelection(entries: rows, selected: [rows[0].id,rows[4].id]), FormatPatchPreset(startRevision: "hash4~1", endRevision: "same"))
        XCTAssertNotNil(FormatPatchPreset.referenceLogSelection(entries: rows, selected: Set(rows[1...3].map(\.id))))
        XCTAssertNil(FormatPatchPreset.referenceLogSelection(entries: rows, selected: [rows[0].id,rows[2].id,rows[4].id]))
        XCTAssertNil(FormatPatchPreset.referenceLogSelection(entries: rows, selected: ["absent"]))
        XCTAssertNil(FormatPatchPreset.referenceLogSelection(entries: rows, selected: []))
    }
}
