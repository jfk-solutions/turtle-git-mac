import XCTest
@testable import TurtleGitCore

final class StatusListClipboardTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/repository")
    let entries = [StatusEntry(path: "雪/new.txt", originalPath: "old.txt", index: "R", worktree: " "), StatusEntry(path: "raw.bin", originalPath: nil, index: "?", worktree: "?")]
    func text(_ copy: StatusListCopy) -> String { StatusListClipboard.text(entries, root: root, statistics: [:], copy: copy) }
    func testOptionalMetadataClipboardUsesVisibleColumnsAndNativeFormatting() {
        let metadata = StatusListMetadata(modificationDate: Date(timeIntervalSince1970: 1700000000), size: 12345, isDirectory: false)
        let output = StatusListClipboard.text(entries, root: root, statistics: [:], copy: .all, metadata: [entries[0].path: metadata], visibleColumns: [.fileName, .lastModified, .fileSize])
        XCTAssertEqual(output, "Filename\tLast modified\tFile size\nnew.txt\t" + metadata.dateText + "\t" + metadata.sizeText + "\nraw.bin\t–\t–\n")
        XCTAssertEqual(StatusListColumn.nativeColumn(2, columns: StatusListColumn.allCases), .fileName)
    }
    func testCopyAllKeepsHeadingWithOneVisibleColumnButExplicitColumnOmitsIt() {
        XCTAssertEqual(StatusListClipboard.text(entries, root: root, statistics: [:], copy: .all, visibleColumns: [.path]), "Path\n雪/new.txt (from old.txt)\nraw.bin\n")
        XCTAssertEqual(text(.column(.path)), "雪/new.txt (from old.txt)\nraw.bin\n")
        let file = CommitFile(path: "dir/雪\tname\n.txt", oldPath: nil, action: "M", added: 1, removed: 0, hasStatistics: true, isSubmodule: false)
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .all, visibleColumns: [.path]), "Path\n" + file.path + "\n")
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .column(.path)), file.path + "\n")
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .all, visibleColumns: [.added]), "Lines added\n1\n")
    }
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
    func testLogOccurrencesRetainParentStatisticsDisplayedFlagsAndRenameLabels() {
        let first = CommitFile(path: "雪/new.txt", oldPath: "old.txt", action: "R100", added: 2, removed: 1, hasStatistics: true, isSubmodule: false, parentIndex: 0)
        let second = CommitFile(path: first.path, oldPath: nil, action: "M", added: 7, removed: 0, hasStatistics: true, isSubmodule: false, parentIndex: 1)
        let module = CommitFile(path: "module.name", oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: true)
        let files = [second, first, module], statuses = [second.id: "Skip worktree"]
        XCTAssertEqual(StatusListClipboard.text(files, root: root, statuses: statuses, copy: .all), "Path\tExtension\tStatus\tLines added\tLines removed\n雪/new.txt\t.txt\tSkip worktree\t7\t0\n雪/new.txt (from old.txt)\t.txt\tRenamed\t2\t1\nmodule.name\t\tModified\t–\t–\n")
        XCTAssertEqual(StatusListClipboard.text(files, root: root, statuses: statuses, copy: .relativePaths), "雪/new.txt\n雪/new.txt\nmodule.name\n")
        XCTAssertEqual(StatusListClipboard.text(files, root: root, statuses: statuses, copy: .names), "new.txt\nnew.txt\nmodule.name\n")
        XCTAssertEqual(StatusListClipboard.text(files, root: root, statuses: statuses, copy: .all, visibleColumns: [.status, .path]), "Status\tPath\nSkip worktree\t雪/new.txt\nRenamed\t雪/new.txt (from old.txt)\nModified\tmodule.name\n")
    }
    func testLogSingleColumnAndLiteralPathsUseMacNewlinesWithoutHeadings() {
        let file = CommitFile(path: "dir/[雪]\n.gitignore", oldPath: "old\tname", action: "C100", added: nil, removed: nil, hasStatistics: true, isSubmodule: false)
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .column(.path)), "dir/[雪]\n.gitignore (from old\tname)\n")
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .column(.fileExtension)), ".gitignore\n")
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .fullPaths), "/tmp/repository/dir/[雪]\n.gitignore\n")
        XCTAssertEqual(StatusListClipboard.text([file], root: root, statuses: [:], copy: .all, visibleColumns: []), "")
        XCTAssertEqual(StatusListClipboard.text([CommitFile](), root: root, statuses: [:], copy: .all), "")
    }
}
