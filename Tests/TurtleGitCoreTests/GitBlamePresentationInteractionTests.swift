// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class GitBlamePresentationInteractionTests: XCTestCase {
    private let revisionHash = String(repeating: "abcdef12", count: 5)
    private let date = Date(timeIntervalSince1970: 1_000_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let locale = Locale(identifier: "en_US_POSIX")

    private func line(hash: String? = nil, author: String = "Captured author", email: String = "captured@example.test",
                      summary: String = "Captured subject", filename: String = "old/雪.swift", date: Date? = nil) -> GitBlameLine {
        GitBlameLine(hash: hash ?? self.revisionHash, originalLine: 7, number: 12, author: author, email: email,
                     date: date ?? self.date, timezone: "+0000", summary: summary, filename: filename,
                     boundary: false, source: "source", sourceBytes: Data("source".utf8))
    }
    private func entry(body: String, subject: String = "Rich subject") -> LogEntry {
        LogEntry(hash: revisionHash, author: "History author", date: "2001-09-09T03:46:40+02:00", subject: "Folded summary",
                 email: "history@example.test", message: subject + "\n" + body)
    }
    private func tooltip(_ line: GitBlameLine? = nil, entry: LogEntry? = nil, filename: Bool = true,
                         relative: Bool = false) -> String {
        GitBlameTooltip.text(line: line ?? self.line(), entry: entry, showFilename: filename,
            dateSettings: HistoryDateSettings(relative: relative, useSystemLocale: false),
            now: date.addingTimeInterval(3 * 86400), locale: locale, timeZone: utc)
    }

    func testZoomPreservesScintillaOffsetAndConfiguredFontBoundsWithoutOverflow() {
        XCTAssertEqual(GitBlameZoom(offset: Int.min).offset, -10)
        XCTAssertEqual(GitBlameZoom(offset: Int.max).offset, 60)
        XCTAssertEqual(GitBlameZoom().stepping(Int.min).offset, -10)
        XCTAssertEqual(GitBlameZoom(offset: -10).stepping(Int.max).offset, 60)
        XCTAssertEqual(GitBlameZoom(offset: 60).stepping(Int.min).offset, -10)
        XCTAssertFalse(GitBlameZoom(offset: 60).canIncrease)
        XCTAssertFalse(GitBlameZoom(offset: -10).canDecrease)
        XCTAssertEqual(GitBlameZoom(offset: 60).effectiveFontSize(base: Int.max), 1060)
        XCTAssertEqual(GitBlameZoom(offset: -10).effectiveFontSize(base: Int.min), 1)
        XCTAssertEqual(GitBlameZoom(offset: 4).effectiveFontSize(base: 12), 16)
        XCTAssertEqual(GitBlameZoom(offset: -9).stepping(-1).offset, -10)
        XCTAssertFalse(GitBlameZoom(offset: -9).changesFont(by: -1, base: 1))
        XCTAssertTrue(GitBlameZoom(offset: 0).changesFont(by: 1, base: 12))
        XCTAssertEqual(GitBlameZoom(offset: 7).stepping(-7), GitBlameZoom())
    }

    func testTooltipUsesCapturedRevisionFilenameAndMatchingRichMetadata() {
        let result = tooltip(entry: entry(body: "Body 🐢\n\nSigned-off-by: Author"))
        XCTAssertTrue(result.contains("Revision: " + revisionHash))
        XCTAssertTrue(result.contains("Filename: old/雪.swift"))
        XCTAssertTrue(result.contains("Author: History author <history@example.test>"))
        XCTAssertTrue(result.contains("Date: 2001-09-09 01:46:40"))
        XCTAssertTrue(result.contains("Message:\nRich subject\nBody 🐢\n\nSigned-off-by: Author"))
        XCTAssertFalse(result.contains("Folded summary"))
        XCTAssertFalse(tooltip(entry: entry(body: "Body"), filename: false).contains("Filename:"))
    }

    func testUnrelatedLateMetadataCannotReplaceCapturedLineAndMalformedDateFallsBack() {
        let unrelated = LogEntry(hash: "different", author: "Wrong author", date: "wrong", subject: "Wrong subject", email: "wrong")
        let result = tooltip(entry: unrelated)
        XCTAssertTrue(result.contains("Author: Captured author <captured@example.test>"))
        XCTAssertTrue(result.contains("Message:\nCaptured subject"))
        XCTAssertFalse(result.contains("Wrong"))
        let invalidDate = LogEntry(hash: revisionHash, author: "", date: "not a date", subject: "Fallback date")
        XCTAssertTrue(tooltip(entry: invalidDate).contains("Date: 2001-09-09 01:46:40"))
        XCTAssertTrue(tooltip(entry: invalidDate).contains("Author: Captured author <captured@example.test>"))
        XCTAssertTrue(tooltip(relative: true).contains("Date: 3 Days ago"))
    }

    func testWorkingTreeFallbackAvoidsFakeEpochAndForeignCommitMetadata() {
        let zero = String(repeating: "0", count: 40)
        let working = line(hash: zero, author: "", email: "", summary: "Uncommitted change", date: Date(timeIntervalSince1970: 0))
        let foreign = LogEntry(hash: zero, author: "Foreign", date: "2001-09-09T01:46:40Z", subject: "Foreign")
        let result = tooltip(working, entry: foreign)
        XCTAssertTrue(result.contains("Revision: Working tree"))
        XCTAssertTrue(result.contains("Author: Not committed yet"))
        XCTAssertTrue(result.contains("Uncommitted change"))
        XCTAssertFalse(result.contains("Date:"))
        XCTAssertFalse(result.contains("Foreign"))
        XCTAssertFalse(result.contains("<>"))
        XCTAssertTrue(tooltip(line(hash: "", author: "Editor", email: "", date: date)).contains("Author: Editor\n"))
    }

    func testBodyBudgetRetainsFifteenNominalLinesAndSourceWrappedLineHeuristic() {
        let body = (1...20).map { "row-\($0)\n" }.joined()
        let result = tooltip(entry: entry(body: body))
        XCTAssertTrue(result.contains("row-15\n\n..."))
        XCTAssertFalse(result.contains("row-16"))
        let wrapped = (1...6).map { String(repeating: "x", count: 139) + "\($0)\n" }.joined()
        // Each 140-unit body line consumes 1 + (140 - 1) / 70 = 2 rows.
        // Use 141 units to consume three rows and reach fifteen after five lines.
        let threeRows = (1...6).map { String(repeating: "x", count: 140) + "\($0)\n" }.joined()
        let bounded = tooltip(entry: entry(body: threeRows))
        XCTAssertTrue(bounded.contains(String(repeating: "x", count: 140) + "5\n\n..."))
        XCTAssertFalse(bounded.contains(String(repeating: "x", count: 140) + "6"))
        XCTAssertTrue(tooltip(entry: entry(body: wrapped)).contains(String(repeating: "x", count: 139) + "6"))
    }

    func testTerminalUnwrappedBodyUsesSourceBehaviorWithinHardLimit() {
        let body = String(repeating: "z", count: 2000)
        let result = tooltip(entry: entry(body: body))
        XCTAssertTrue(result.hasSuffix(body))
        XCTAssertFalse(result.hasSuffix("..."))
    }

    func testHardLimitIncludesEllipsisAndPreservesWholeUnicodeGraphemes() {
        let grapheme = "👩🏽‍💻e\u{301}"
        let result = tooltip(entry: entry(body: String(repeating: grapheme, count: 2000)))
        XCTAssertLessThanOrEqual(result.utf16.count, GitBlameTooltip.maximumUTF16Length)
        XCTAssertTrue(result.hasSuffix("..."))
        XCTAssertFalse(result.contains("\u{FFFD}"))
        let prefix = String(result.dropLast(3))
        XCTAssertTrue(prefix.last == Character("👩🏽‍💻") || prefix.last == Character("e\u{301}"))
        let hugeHeader = tooltip(line(author: String(repeating: grapheme, count: 2000)))
        XCTAssertLessThanOrEqual(hugeHeader.utf16.count, 8000)
        XCTAssertFalse(hugeHeader.contains("\u{FFFD}"))
        // An indivisible grapheme larger than the budget must be omitted intact.
        let giantGrapheme = "a" + String(repeating: "\u{301}", count: 9000)
        let giant = tooltip(entry: entry(body: giantGrapheme))
        XCTAssertLessThanOrEqual(giant.utf16.count, 8000)
        XCTAssertTrue(giant.hasSuffix("..."))
        XCTAssertFalse(giant.contains("\u{301}"))
    }

    private func originFixture() async throws -> (URL, GitRepository, GitBlameSnapshot, String) {
        let (root, repo, path) = try await GitPatchTests().fixture()
        do {
            let other = "copied origin.txt"
            try Data("Origin line 🐢\n".utf8).write(to: root.appendingPathComponent(other))
            try await repo.stage([other]); _ = try await repo.commit(message: "Origin subject\n\nFull origin body 雪\nsecond body line")
            let origin = try await repo.blame(path: other)
            try Data("Displayed file changed\n".utf8).write(to: root.appendingPathComponent(path))
            try await repo.stage([path]); _ = try await repo.commit(message: "Displayed change")
            let displayed = try await repo.blame(path: path)
            // A trusted attributed snapshot can contain an origin absent from
            // its path log, as with complete/follow history and copied lines.
            let combined = GitBlameSnapshot(revision: displayed.revision, path: path, contents: displayed.contents,
                encoding: displayed.encoding, lines: displayed.lines + origin.lines)
            return (root, repo, combined, origin.revision)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func testMissingAttributedOriginHasFullTooltipWithoutAddingVisibleHistoryRows() async throws {
        let (root, repo, snapshot, origin) = try await originFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = GitBlameOptions(); options.followRenames = true
        let visible = try await repo.blameHistory(snapshot, options: options)
        XCTAssertFalse(visible.contains { $0.hash == origin })
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let details = try await repo.blameHistoryDetails(snapshot, options: options)
        XCTAssertEqual(details.entries.map(\.hash), visible.map(\.hash))
        XCTAssertEqual(details.tooltipEntries.map(\.hash), [origin])
        let metadata = try XCTUnwrap(details.tooltipEntries.first)
        let captured = try XCTUnwrap(snapshot.lines.first { $0.hash == origin })
        let text = tooltip(captured, entry: metadata)
        XCTAssertTrue(text.contains("Origin subject\n\nFull origin body 雪\nsecond body line"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(snapshot.path)), snapshot.contents)
        // Attributed-only reads already contain the origin; avoid redundant
        // fallback metadata while preserving the existing row projection.
        options.showCompleteLog = false
        let attributed = try await repo.blameHistoryDetails(snapshot, options: options)
        XCTAssertTrue(attributed.tooltipEntries.isEmpty)
        XCTAssertTrue(attributed.entries.contains { $0.hash == origin })
    }

    func testMissingOriginLookupCancellationDrainsOwnedGitProcess() async throws {
        let (root, _, snapshot, _) = try await originFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("held-origin-log")
        let marker = URL(fileURLWithPath: helper.path + ".ready")
        let script = """
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = '--no-walk=unsorted' ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let token = OperationCancellation(), held = GitRepository(root: root, executable: helper)
        defer { token.cancel() }
        let work = Task { try await held.blameHistoryDetails(snapshot, options: GitBlameOptions(), cancellation: token) }
        var pids: [Int32] = []
        for _ in 0..<1000 {
            if let raw = try? String(contentsOf: marker) {
                pids = raw.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                if pids.count == 2 { break }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        token.cancel()
        do { _ = try await work.value; XCTFail("Cancelled origin lookup completed") }
        catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        XCTAssertEqual(pids.count, 2, "Missing-origin hash lookup was not reached")
        for _ in 0..<500 {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH) }
    }
}
