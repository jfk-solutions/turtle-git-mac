import XCTest
@testable import TurtleGitCore

final class GitBlamePresentationTests: XCTestCase {
    func testAnnotationSelectionReplacesAndIndependentlyTogglesRevisions() {
        XCTAssertEqual(GitBlameSelection.selecting("A", in: [], additive: false), ["A"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: ["A"], additive: false), [])
        XCTAssertEqual(GitBlameSelection.selecting("B", in: ["A"], additive: false), ["B"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: ["A", "B"], additive: false), ["A"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: ["B", "C"], additive: false), ["A"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: [], additive: true), ["A"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: ["A"], additive: true), [])
        XCTAssertEqual(GitBlameSelection.selecting("B", in: ["A"], additive: true), ["A", "B"])
        XCTAssertEqual(GitBlameSelection.selecting("A", in: ["A", "B"], additive: true), ["B"])
        XCTAssertEqual(GitBlameSelection.selecting("C", in: ["A", "B"], additive: true), ["A", "B", "C"])
    }
    func testSelectedCommitChangeNavigationSkipsBlocksAndDoesNotWrap() {
        let hashes = ["A", "A", "X", "A", "A", "Y", "B", "B", "X", "A", "A", "Z", "B", "B"]
        XCTAssertEqual(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: 0, previous: false), 3)
        // Upstream skips a matching block exactly two lines below the viewport.
        XCTAssertEqual(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: 1, previous: false), 9)
        XCTAssertEqual(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: 9, previous: true), 3)
        XCTAssertEqual(GitBlameNavigation.change(hashes: hashes, selected: ["A", "B"], start: 3, previous: false), 6)
        XCTAssertEqual(GitBlameNavigation.change(hashes: hashes, selected: ["A", "B"], start: 12, previous: true), 9)
        XCTAssertNil(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: 9, previous: false))
        XCTAssertNil(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: 3, previous: true))
        for selected: Set<String> in [[], ["missing"]] {
            XCTAssertNil(GitBlameNavigation.change(hashes: hashes, selected: selected, start: 0, previous: false))
        }
        XCTAssertNil(GitBlameNavigation.change(hashes: [], selected: ["A"], start: 0, previous: false))
        XCTAssertNil(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: -1, previous: true))
        XCTAssertNil(GitBlameNavigation.change(hashes: hashes, selected: ["A"], start: hashes.count, previous: false))
    }
    func testLocatorUsesAgeOnlyAndIntegerViewportShading() {
        var value = GitBlamePresentation()
        XCTAssertEqual(value.locatorColor(rank: 0, historyCount: 1, dark: false, enabled: true, visible: false), 0xffffa7)
        XCTAssertEqual(value.locatorColor(rank: 0, historyCount: 1, dark: false, enabled: true, visible: true), 0xe5e596)
        XCTAssertEqual(value.locatorColor(rank: 0, historyCount: 1, dark: true, enabled: true, visible: true), 0x4a4a26)
        value.oldColor = 0x00ff00; value.darkOldColor = 0xff0000
        XCTAssertEqual(value.locatorColor(rank: nil, historyCount: 10, dark: false, enabled: true, visible: false), 0xffffff)
        XCTAssertEqual(value.locatorColor(rank: 0, historyCount: 10, dark: false, enabled: false, visible: true), 0xe5e5e5)
        XCTAssertEqual(value.locatorColor(rank: nil, historyCount: 10, dark: true, enabled: true, visible: false), 0x202020)
        XCTAssertEqual(value.locatorColor(rank: 0, historyCount: 10, dark: true, enabled: false, visible: true), 0x343434)
    }
    func testRevisionPropertiesUseFirstLineAndLocalMinuteDatesWithoutChangingMessage() {
        let message = "Subject 雪\nsecond subject line\n\nBody 🐢\n\nSigned-off-by: Test\n"
        let entry = LogEntry(hash: "abc", author: "Author", date: "2001-09-10T00:33:20-05:00",
            subject: "Subject 雪 second subject line", message: message, committerDate: "2001-09-11T11:50:00+02:30")
        let utc = GitBlameRevisionProperties(entry: entry, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(utc.subject, "Subject 雪")
        XCTAssertEqual(utc.body, "second subject line\n\nBody 🐢\n\nSigned-off-by: Test")
        XCTAssertEqual(utc.authorDate, "2001-09-10 05:33")
        XCTAssertEqual(utc.committerDate, "2001-09-11 09:20")
        let berlin = GitBlameRevisionProperties(entry: entry, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(berlin.authorDate, "2001-09-10 07:33")
        XCTAssertEqual(berlin.committerDate, "2001-09-11 11:20")
        XCTAssertEqual(entry.message, message)
        let winter = LogEntry(hash: "winter", author: "", date: "2026-01-01T23:59:59-05:00", subject: "Only subject", message: "Only subject", committerDate: "invalid")
        let properties = GitBlameRevisionProperties(entry: winter, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(properties.authorDate, "2026-01-02 05:59")
        XCTAssertEqual(properties.committerDate, "invalid"); XCTAssertEqual(properties.body, "")
        let empty = GitBlameRevisionProperties(entry: LogEntry(hash: "", author: "", date: "", subject: "Fallback"))
        XCTAssertEqual(empty.subject, "Fallback"); XCTAssertEqual(empty.body, ""); XCTAssertEqual(empty.authorDate, "")
    }
    func testPresentationReopensSeparatelyFromAnnotationDefaults() throws {
        let name = "GitBlamePresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(GitBlamePresentation.load(from: defaults), GitBlamePresentation())
        var value = GitBlamePresentation(); value.fontName = "Courier"; value.fontSize = 14; value.tabSize = 8
        value.recentColor = 0x40ff80; value.oldColor = 0xf0f0ff; value.darkRecentColor = 0x204030; value.darkOldColor = 0x101020
        value.save(to: defaults)
        GitBlamePreferences.update(in: defaults) { $0.onlyFirstParent = true }
        XCTAssertEqual(GitBlamePresentation.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), value)
        XCTAssertTrue(GitBlamePreferences.load(from: defaults).onlyFirstParent)
        defaults.set(-1, forKey: "TurtleGitBlame.FontSize"); defaults.set(1001, forKey: "TurtleGitBlame.TabSize")
        defaults.set("4294967296", forKey: "TurtleGitBlame.RecentColor")
        let loaded = GitBlamePresentation.load(from: defaults)
        XCTAssertEqual(loaded.fontSize, 1); XCTAssertEqual(loaded.tabSize, 1000); XCTAssertEqual(loaded.recentColor, 0xffff50)
    }
    func testAgeInterpolationRetainsUpstreamIntegerPaletteAndCustomEndpoints() {
        var value = GitBlamePresentation()
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: true), 0xffffa7)
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: true, enabled: true), 0x383810)
        XCTAssertEqual(value.ageColor(rank: nil, historyCount: 10, dark: false, enabled: true), 0xffffff)
        value.recentColor = 0x00ff80; value.oldColor = 0x808080
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: true), 0x40bf80)
        XCTAssertEqual(value.ageColor(rank: 0, historyCount: 1, dark: false, enabled: false), 0x808080)
        XCTAssertEqual(value.ageColor(rank: 9, historyCount: 1, dark: false, enabled: true), 0x808080)
    }
}
