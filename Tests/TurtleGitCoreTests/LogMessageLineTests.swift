import XCTest
@testable import TurtleGitCore

final class LogMessageLineTests: XCTestCase {
    func testRawFirstLineAndSourceWhitespaceFolding() {
        for (message, short, full) in [
            ("", "fallback", "fallback"),
            ("Subject", "Subject", "Subject"),
            ("Subject\n", "Subject", "Subject"),
            ("Subject\n\nBody\n", "Subject", "Subject  Body "),
            ("Subject\r\n\r\n雪\t🦎\r\n", "Subject\r", "Subject    雪\t🦎  "),
            ("first paragraph\ncontinued subject\n\nbody", "first paragraph", "first paragraph continued subject  body"),
            ("  subject  \n \nbody  ", "  subject  ", "  subject     body  ")
        ] {
            let entry = LogEntry(hash: "commit", author: "", date: "", subject: "fallback", message: message)
            XCTAssertEqual(entry.logLine(), short)
            XCTAssertEqual(entry.logLine(fullMessage: true), full)
            XCTAssertEqual(entry.message, message); XCTAssertEqual(entry.subject, "fallback")
        }
        let working = LogEntry(hash: "", author: "", date: "", subject: "Working tree changes", message: "3 changed files")
        XCTAssertEqual(working.logLine(fullMessage: true), "Working tree changes")
    }
    func testGitFoldedSubjectIsNotRepeatedWithRawContinuation() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let message = "first line\ncontinued heading\n\nbody 雪\nsecond body line\n"
        _ = try await repo.run(["commit", "--allow-empty", "-m", message])
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let paths = [".git/HEAD", ".git/index", ".git/config", path], before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let entries = try await repo.history()
        let entry = try XCTUnwrap(entries.first { $0.hash == hash })
        XCTAssertEqual(entry.subject, "first line continued heading")
        XCTAssertEqual(entry.logLine(), "first line")
        XCTAssertEqual(entry.logLine(fullMessage: true), "first line continued heading  body 雪 second body line ")
        XCTAssertEqual(entry.message, message)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; XCTAssertEqual(before, after)
    }
}
