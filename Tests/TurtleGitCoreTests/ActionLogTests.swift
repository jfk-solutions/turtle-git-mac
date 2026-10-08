import XCTest
@testable import TurtleGitCore

final class ActionLogTests: XCTestCase {
    func fixture(_ body: (ActionLogStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit.ActionLog.Tests." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(ActionLogStore(storageURL: folder.appendingPathComponent("logfile.txt")))
    }
    func testSourceLineSplitting() {
        XCTAssertEqual(ActionLogStore.lines("a\r\nb\rc\n\n雪🐢\0ignored\n"), ["a", "b", "c", "", "雪🐢"])
        XCTAssertEqual(ActionLogStore.lines("\r\n"), [""])
        XCTAssertEqual(ActionLogStore.lines(""), [])
    }
    func testHeaderCancellationAndPrivateStorage() throws {
        try fixture { store in
            try store.append(repository: URL(fileURLWithPath: "/repos/雪"), output: "first\r\nsecond\rthird\n", cancelled: true,
                             date: Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
            let lines = ActionLogStore.lines(try store.read())
            XCTAssertEqual(lines.first, ""); XCTAssertTrue(lines[1].hasPrefix("1/1/70 - ")); XCTAssertTrue(lines[1].hasSuffix(" - /repos/雪"))
            XCTAssertEqual(Array(lines.dropFirst(2)), ["first", "second", "third", "User cancelled"])
            for (url, mode) in [(store.storageURL, 0o600), (store.storageURL.deletingLastPathComponent(), 0o700)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
            }
        }
    }
    func testRetentionPreservesEntireNewestOperation() throws {
        try fixture { store in
            let repo = URL(fileURLWithPath: "/repo")
            try store.append(repository: repo, output: "a\nb\nc\nd", cancelled: false)
            try store.append(repository: repo, output: "new", cancelled: false, maximumLines: 5)
            let lines = ActionLogStore.lines(try store.read()); XCTAssertEqual(lines.count, 5)
            XCTAssertEqual(Array(lines.prefix(2)), ["c", "d"]); XCTAssertEqual(lines.last, "new")
            try store.append(repository: repo, output: "1\n2\n3\n4", cancelled: false, maximumLines: 2)
            let big = ActionLogStore.lines(try store.read()); XCTAssertEqual(big.count, 6); XCTAssertEqual(Array(big.dropFirst(2)), ["1", "2", "3", "4"])
        }
    }
    func testZeroDisablesWithoutClearingExistingAndClearDeletesOnlyLog() throws {
        try fixture { store in
            let repo = URL(fileURLWithPath: "/repo")
            try store.append(repository: repo, output: "disabled", cancelled: false, maximumLines: 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.deletingLastPathComponent().path))
            try store.append(repository: repo, output: "saved", cancelled: false)
            let old = try store.read()
            try store.append(repository: repo, output: "disabled", cancelled: true, maximumLines: 0); XCTAssertEqual(try store.read(), old)
            let sentinel = store.storageURL.deletingLastPathComponent().appendingPathComponent("repositories.json")
            try Data("bookmarks".utf8).write(to: sentinel)
            try store.clear(); XCTAssertFalse(store.exists); XCTAssertEqual(try String(contentsOf: sentinel), "bookmarks"); try store.clear()
        }
    }
    func testConcurrentWritersDoNotLoseOperations() throws {
        try fixture { store in
            let results = NSLock(); var failures: [Error] = []
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                do { try store.append(repository: URL(fileURLWithPath: "/repo"), output: "operation-\(index)", cancelled: false) }
                catch { results.lock(); failures.append(error); results.unlock() }
            }
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            let lines = ActionLogStore.lines(try store.read()); XCTAssertEqual(lines.count, 24)
            for index in 0..<8 { XCTAssertEqual(lines.filter { $0 == "operation-\(index)" }.count, 1) }
        }
    }
}
