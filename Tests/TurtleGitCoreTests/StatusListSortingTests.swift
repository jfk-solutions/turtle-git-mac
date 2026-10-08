import XCTest
@testable import TurtleGitCore

final class StatusListSortingTests: XCTestCase {
    private func entry(_ path: String, _ code: String = " M") -> StatusEntry {
        StatusEntry(path: path, originalPath: nil, index: code.first!, worktree: code.last!)
    }
    private func stats(_ path: String, _ added: Int?, _ removed: Int?, present: Bool = true) -> CommitFile {
        CommitFile(path: path, oldPath: nil, action: "M", added: added, removed: removed, hasStatistics: present, isSubmodule: false)
    }
    func testOptionalFilenameDateAndSizeUseRawValuesWithPathTie() {
        let a = entry("z/file2"), b = entry("a/file10")
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .fileName), .orderedAscending)
        let early = StatusListMetadata(modificationDate: Date(timeIntervalSince1970: 10), size: 10000, isDirectory: false)
        let late = StatusListMetadata(modificationDate: Date(timeIntervalSince1970: 20), size: 2, isDirectory: false)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .lastModified, lhsMetadata: early, rhsMetadata: late), .orderedAscending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .fileSize, lhsMetadata: early, rhsMetadata: late), .orderedDescending)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .fileSize, rhsMetadata: late), .orderedAscending)
        XCTAssertEqual(StatusListMetadata(modificationDate: nil, size: 9999, isDirectory: true).size, 0)
        let old = StatusListMetadata(modificationDate: Date(timeIntervalSince1970: -1), size: 1, isDirectory: false)
        XCTAssertEqual(StatusListSorting.compare(a, b, column: .lastModified, rhsMetadata: old), .orderedAscending)
        let directory = StatusListMetadata(modificationDate: nil, size: 9999, isDirectory: true)
        XCTAssertEqual(StatusListSorting.compare(entry("z.ext"), entry("a.ext"), column: .fileExtension, lhsMetadata: directory), .orderedAscending)
    }
    func testColumnDefaultsVersionPathProtectionAndRoundTrip() {
        let suite = "TurtleGit.ColumnSettings.Core.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StatusListColumnSettings.load(from: defaults).visible, Set(StatusListColumn.defaultColumns))
        defaults.set(["File size"], forKey: "Commit.FileColumns")
        XCTAssertEqual(StatusListColumnSettings.load(from: defaults).visible, Set(StatusListColumn.defaultColumns))
        defaults.set(1, forKey: "Commit.FileColumns.Version"); defaults.set(["Filename", "File size", "bad"], forKey: "Commit.FileColumns")
        let selected = StatusListColumnSettings.load(from: defaults)
        XCTAssertEqual(selected.visible, [.path, .fileName, .fileSize]); selected.save(to: defaults)
        XCTAssertEqual(StatusListColumnSettings.load(from: defaults), selected)
        defaults.set(99, forKey: "Commit.FileColumns.Version")
        XCTAssertEqual(StatusListColumnSettings.load(from: defaults).visible, Set(StatusListColumn.defaultColumns))
    }
    func testLayoutPreferenceMigrationOrderWidthValidationAndReset() {
        let suite = "TurtleGit.ColumnLayout.Core.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "Commit.FileColumns.Version")
        defaults.set(["Path", "Filename"], forKey: "Commit.FileColumns")
        let legacy = StatusListColumnSettings.load(from: defaults)
        XCTAssertEqual(legacy.order, StatusListColumn.allCases); XCTAssertTrue(legacy.widths.isEmpty)
        defaults.set(["Filename", "bad", "Path", "Filename"], forKey: "Commit.FileColumns.Order")
        defaults.set(["Filename": 252.5, "File size": -5, "Status": 100001, "bad": 32], forKey: "Commit.FileColumns.Widths")
        let loaded = StatusListColumnSettings.load(from: defaults)
        XCTAssertEqual(Array(loaded.order.prefix(2)), [.fileName, .path]); XCTAssertEqual(Set(loaded.order).count, StatusListColumn.allCases.count)
        XCTAssertEqual(loaded.widths, [.fileName: 252.5, .status: 10000])
        loaded.save(to: defaults); XCTAssertEqual(StatusListColumnSettings.load(from: defaults), loaded)
        StatusListColumnSettings().save(to: defaults)
        XCTAssertEqual(StatusListColumnSettings.load(from: defaults), StatusListColumnSettings())
        XCTAssertTrue(StatusListColumnSettings(widths: [.path: .infinity, .status: .nan, .added: 0]).widths.isEmpty)
    }
    func testMetadataLiteralFileDirectoryLinkMissingAndEscapingParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-metadata-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "雪\t🦎.txt", bytes = Data("payload".utf8), date = Date(timeIntervalSince1970: 1700000000)
        try bytes.write(to: root.appendingPathComponent(name))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(name).path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/missing/external")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        let metadata = await GitRepository(root: root).statusListMetadata(paths: [name, "dir", "link", "gone", "../outside", "escape/foreign", ".git/index"])
        XCTAssertEqual(metadata[name]?.size, Int64(bytes.count)); XCTAssertEqual(metadata[name]?.modificationDate, date)
        XCTAssertEqual(metadata["dir"]?.size, 0); XCTAssertEqual(metadata["dir"]?.isDirectory, true)
        XCTAssertEqual(metadata["link"]?.size, Int64("/missing/external".utf8.count))
        for path in ["gone", "../outside", "escape/foreign", ".git/index"] { XCTAssertNil(metadata[path]?.size); XCTAssertNil(metadata[path]?.modificationDate) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes)
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
