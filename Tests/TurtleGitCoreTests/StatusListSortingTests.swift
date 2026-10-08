import XCTest
@testable import TurtleGitCore

final class StatusListSortingTests: XCTestCase {
    private func entry(_ path: String, _ code: String = " M") -> StatusEntry {
        StatusEntry(path: path, originalPath: nil, index: code.first!, worktree: code.last!)
    }
    private func stats(_ path: String, _ added: Int?, _ removed: Int?, present: Bool = true) -> CommitFile {
        CommitFile(path: path, oldPath: nil, action: "M", added: added, removed: removed, hasStatistics: present, isSubmodule: false)
    }
    func testNaturalPathExtensionAndPathTie() {
        XCTAssertEqual(StatusListSorting.compare(entry("File2.swift"), entry("file10.swift"), column: .path), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("z.x2"), entry("a.x10"), column: .fileExtension), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("file2.swift"), entry("file10.swift"), column: .fileExtension), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("a.swift"), entry("b.txt"), column: .fileExtension, lhsDirectory: true), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("same"), entry("same"), column: .path), .orderedSame)
    }
    func testNumericCountsMissingAndBinaryBeforeText() {
        let a = entry("a"), b = entry("b")
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .added, lhsStatistics: stats("a", 10, 2), rhsStatistics: stats("b", 2, 10)), .orderedDescending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .removed, lhsStatistics: stats("a", 10, 2), rhsStatistics: stats("b", 2, 10)), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .added, rhsStatistics: stats("b", nil, nil)), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .added, lhsStatistics: stats("a", nil, nil), rhsStatistics: stats("b", 0, 0)), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .added, lhsStatistics: stats("a", 99, 99, present: false), rhsStatistics: stats("b", nil, nil)), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .added, lhsStatistics: stats("a", 2, 2), rhsStatistics: stats("b", 2, 2)), .orderedAscending)
    }
    func testStatusUsesDisplayedNameIncludingRenames() {
        XCTAssertEqual(StatusListSorting.compare(entry("z", "A "), entry("a", " D"), column: .status), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("z", "R "), entry("a", "??"), column: .status), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(entry("z"), entry("a", "R "), column: .status), .orderedAscending)
    }
    func testByteDistinctUnicodeAndCaseNamesHaveDeterministicTies() {
        for pair in [("é", "e\u{301}"), ("A", "a"), ("雪🦎2", "雪🦎10"), ("tab\tname", "tab name")] {
            let forward = StatusListSorting.compare(entry(pair.0), entry(pair.1), column: .path)
            let reverse = StatusListSorting.compare(entry(pair.1), entry(pair.0), column: .path)
            XCTAssertNotEqual(forward, .orderedSame)
            XCTAssertNotEqual(forward, reverse)
        }
    }
    func testSortingWithinGroupsKeepsHeadersAndMembership() {
        let entries = [entry("b10"), entry("b2"), entry("u10", "??"), entry("u2", "??")]
        let ordered = entries.sorted { StatusListSorting.compare($0, $1, column: .path) == .orderedAscending }
        let rows = StatusListGroups.rows(entries: ordered, changelists: GitChangelists())
        XCTAssertEqual(rows.compactMap(\.group), [.modified, .unversioned])
        XCTAssertEqual(rows.compactMap(\.entry).map(\.path), ["b2", "b10", "u2", "u10"])
    }
}
