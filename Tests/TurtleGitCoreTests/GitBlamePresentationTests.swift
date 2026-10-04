import XCTest
@testable import TurtleGitCore

final class GitBlamePresentationTests: XCTestCase {
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
