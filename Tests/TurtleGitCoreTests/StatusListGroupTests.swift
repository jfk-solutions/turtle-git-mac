import XCTest
@testable import TurtleGitCore

final class StatusListGroupTests: XCTestCase {
    private func entry(_ path: String, _ status: String = " M") -> StatusEntry {
        let characters = Array(status)
        return StatusEntry(path: path, originalPath: nil, index: characters[0], worktree: characters[1])
    }
    func testStatusCategoriesMembershipPrecedenceAndIgnoreLast() {
        let entries = [entry("z-ignore"), entry("modified"), entry("a-named", "??"), entry("untracked", "??"), entry("ignored", "!!"), entry("flagged"), entry("b-named")]
        let lists = GitChangelists(assignments: ["z-ignore": GitChangelists.ignored, "a-named": "Alpha 雪", "b-named": "Beta", "not-shown": "Empty"])
        let rows = StatusListGroups.rows(entries: entries, changelists: lists, locallyIgnored: ["flagged", "a-named"])
        XCTAssertEqual(rows.compactMap(\.group), [.modified, .unversioned, .ignored, .localChangesIgnored, .changelist("Alpha 雪"), .changelist("Beta"), .changelist(GitChangelists.ignored)])
        XCTAssertEqual(rows.compactMap(\.entry).map(\.path), ["modified", "untracked", "ignored", "flagged", "a-named", "b-named", "z-ignore"])
        XCTAssertEqual(StatusListGroups.files(in: .changelist("Alpha 雪"), rows: rows).map(\.path), ["a-named"])
        XCTAssertEqual(StatusListGroups.files(in: .changelist("Empty"), rows: rows), [])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
    func testHeadersRetainNativeRowSlotsWithoutBecomingFileTargets() {
        let a = entry("literal\n雪.txt"), b = entry("b", "??"), c = entry("c", "??")
        let rows = StatusListGroups.rows(entries: [a, b, c], changelists: GitChangelists(assignments: [a.path: "Not Versioned Files"]))
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].group, .unversioned); XCTAssertEqual(rows[1].entry, b)
        XCTAssertEqual(rows[3].group, .changelist("Not Versioned Files")); XCTAssertEqual(rows[4].entry, a)
        XCTAssertEqual(StatusListGroups.files(at: IndexSet([0, 1, 3, 4, 99]), in: rows), [b, a])
        XCTAssertEqual(StatusListGroups.files(at: IndexSet([0, 3]), in: rows), [])
        XCTAssertEqual(StatusListGroups.files(at: IndexSet(integersIn: 0..<5), in: rows), [b, c, a])
        XCTAssertNotEqual(rows[0].id, rows[3].id)
        XCTAssertTrue(rows[0].id.contains("\0"))
    }
    func testNativeNavigationSkipsHeadersAndStopsAtEnds() {
        let rows: [StatusListRow] = [.group(.modified), .file(entry("a")), .group(.unversioned), .file(entry("b", "??")), .group(.changelist("Empty"))]
        XCTAssertEqual(StatusListGroups.nextFileRow(after: nil, forward: true, in: rows), 1)
        XCTAssertEqual(StatusListGroups.nextFileRow(after: 1, forward: true, in: rows), 3)
        XCTAssertEqual(StatusListGroups.nextFileRow(after: 3, forward: false, in: rows), 1)
        XCTAssertEqual(StatusListGroups.nextFileRow(after: nil, forward: false, in: rows), 3)
        XCTAssertNil(StatusListGroups.nextFileRow(after: 3, forward: true, in: rows))
        XCTAssertNil(StatusListGroups.nextFileRow(after: 1, forward: false, in: rows))
        XCTAssertNil(StatusListGroups.nextFileRow(after: nil, forward: true, in: []))
        XCTAssertNil(StatusListGroups.nextFileRow(after: nil, forward: false, in: [.group(.modified)]))
    }
    func testGroupingVisibilityAndStableFileOrder() {
        let entries = [entry("z"), entry("a")]
        let plain = StatusListGroups.rows(entries: entries, changelists: GitChangelists())
        XCTAssertEqual(plain, entries.map(StatusListRow.file))
        let hiddenMembership = StatusListGroups.rows(entries: entries, changelists: GitChangelists(assignments: ["outside": "Hidden"]))
        XCTAssertEqual(hiddenMembership.compactMap(\.group), [.modified])
        XCTAssertEqual(hiddenMembership.compactMap(\.entry), entries)
        let flagged = StatusListGroups.rows(entries: entries, changelists: GitChangelists(), locallyIgnored: ["z"])
        XCTAssertEqual(flagged.compactMap(\.group), [.modified, .localChangesIgnored])
        XCTAssertEqual(StatusListGroups.files(in: .localChangesIgnored, rows: flagged), [entries[0]])
        XCTAssertEqual(StatusListGroups.rows(entries: [], changelists: GitChangelists(assignments: ["outside": "Hidden"])), [])
    }
}
