import XCTest
@testable import TurtleGitCore

final class StatusListClipboardTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/repository")
    let entries = [StatusEntry(path: "雪/new.txt", originalPath: "old.txt", index: "R", worktree: " "), StatusEntry(path: "raw.bin", originalPath: nil, index: "?", worktree: "?")]
    func text(_ copy: StatusListCopy) -> String { StatusListClipboard.text(entries, root: root, statistics: [:], copy: copy) }
    func testPathCommandsKeepRawPathsAndSelectedOrder() {
        XCTAssertEqual(text(.relativePaths), "雪/new.txt\nraw.bin\n")
        XCTAssertEqual(text(.fullPaths), "/tmp/repository/雪/new.txt\n/tmp/repository/raw.bin\n")
        XCTAssertEqual(text(.names), "new.txt\nraw.bin\n")
        XCTAssertEqual(text(.pathsAndStatus), "Path\tStatus\n雪/new.txt\tRenamed\nraw.bin\tUntracked\n")
    }
    func testSingleColumnCopiesDisplayedRenamesExtensionsAndUnavailableStatisticsWithoutHeader() {
        XCTAssertEqual(text(.column(.path)), "雪/new.txt (from old.txt)\nraw.bin\n")
        XCTAssertEqual(text(.column(.fileExtension)), ".txt\n.bin\n")
        XCTAssertEqual(text(.column(.status)), "Renamed\nUntracked\n")
        XCTAssertEqual(text(.column(.added)), "–\n–\n")
        XCTAssertEqual(StatusListClipboard.fileExtension(".gitignore"), ".gitignore")
        XCTAssertEqual(StatusListClipboard.fileExtension("folder.name/"), "")
        XCTAssertEqual(StatusListClipboard.fileExtension("submodule.name", isDirectory: true), "")
        XCTAssertEqual(StatusListClipboard.fileExtension("dir.name/no-extension"), "")
        XCTAssertNil(StatusListColumn.nativeColumn(0)); XCTAssertNil(StatusListColumn.nativeColumn(6))
        XCTAssertEqual(StatusListColumn.nativeColumn(3), .status)
    }
    func testAllVisibleColumnsAndStagedStatisticsUseCorrectHeadingsAndOrder() {
        let stats = ["raw.bin": CommitFile(path: "raw.bin", oldPath: nil, action: "A", added: 2, removed: 0, hasStatistics: true, isSubmodule: false)]
        XCTAssertEqual(StatusListClipboard.text(entries, root: root, statistics: stats, copy: .all), "Path\tExtension\tStatus\tLines added\tLines removed\n雪/new.txt (from old.txt)\t.txt\tRenamed\t–\t–\nraw.bin\t.bin\tAdded\t2\t0\n")
        XCTAssertEqual(StatusListClipboard.text(entries, root: root, statistics: stats, copy: .all, visibleColumns: [.status, .path]), "Status\tPath\nRenamed\t雪/new.txt (from old.txt)\nAdded\traw.bin\n")
        XCTAssertEqual(StatusListClipboard.text(entries, root: root, statistics: stats, copy: .all, visibleColumns: []), "")
        XCTAssertEqual(StatusListClipboard.text([], root: root, statistics: stats, copy: .all), "")
    }
}
