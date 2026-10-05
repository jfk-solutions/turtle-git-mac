import XCTest
import Darwin
@testable import TurtleGitCore

final class MessageCodeScannerTests: XCTestCase {
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    private func fixture(_ body: (URL, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let definitions = folder.appendingPathComponent("autolist.txt")
        try await body(folder, definitions)
    }
    func testTraversalOrderAndSnippetCollisionKinds() async throws {
        try await fixture { root, definitions in
            try ".test=(Collision)|(first\\.test)\n".write(to: definitions, atomically: true, encoding: .utf8)
            try "Collision first.test".write(to: root.appendingPathComponent("first.test"), atomically: true, encoding: .utf8)
            try "later".write(to: root.appendingPathComponent("Collision"), atomically: true, encoding: .utf8)
            let rows = [MessageCodeScanner.Source(path: "first.test", state: .modified), .init(path: "Collision", state: .modified)]
            let result = try await MessageCodeScanner().scan(root: root, sources: rows, userDefinitions: definitions, executable: helper)
            XCTAssertEqual(result.catalog.kind(for: "first.test"), .file)
            XCTAssertEqual(result.catalog.kind(for: "Collision"), .code) // Earlier code wins over a later filename.
            var snippets = MessageSnippets(); snippets.overlay("Collision=Expanded")
            let withSnippet = try await MessageCodeScanner().scan(root: root, sources: rows, snippets: snippets, userDefinitions: definitions, executable: helper)
            XCTAssertEqual(withSnippet.catalog.kind(for: "Collision"), .snippet)
        }
    }
    func testUnversionedIgnoredAndSizeGatesKeepFilenames() async throws {
        try await fixture { root, definitions in
            try ".test=(\\w+)".write(to: definitions, atomically: true, encoding: .utf8)
            for (name, value) in [("tracked.test", "Old"), ("new.test", "New"), ("ignored.test", "Ignored"), ("large.test", "Large")] {
                try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try Data().write(to: root.appendingPathComponent("empty.test"))
            try Data([0, 0, 0, 0]).write(to: root.appendingPathComponent("binary.test"))
            let rows: [MessageCodeScanner.Source] = [.init(path: "tracked.test", state: .modified), .init(path: "new.test", state: .untracked),
                .init(path: "ignored.test", state: .ignored), .init(path: "large.test", state: .modified),
                .init(path: "empty.test", state: .modified), .init(path: "binary.test", state: .modified)]
            var options = MessageCodeScanner.Options(); options.maximumBytes = 4
            let result = try await MessageCodeScanner().scan(root: root, sources: rows, userDefinitions: definitions, options: options, executable: helper)
            XCTAssertEqual(result.catalog.kind(for: "Old"), .code)
            for value in ["New", "Ignored", "Large"] { XCTAssertNil(result.catalog.kind(for: value)) }
            for row in rows { XCTAssertEqual(result.catalog.kind(for: row.path), .file) }
            options.parseUnversioned = true
            let parsed = try await MessageCodeScanner().scan(root: root, sources: rows, userDefinitions: definitions, options: options, executable: helper)
            XCTAssertEqual(parsed.catalog.kind(for: "New"), .code)
            XCTAssertNil(parsed.catalog.kind(for: "Ignored"))
        }
    }
    func testCacheFirstValidPatternAndEmptyDefinitionGate() async throws {
        try await fixture { root, definitions in
            let scanner = MessageCodeScanner(), rows = [MessageCodeScanner.Source(path: "source.test", state: .modified)]
            try "Alpha Other".write(to: root.appendingPathComponent("source.test"), atomically: true, encoding: .utf8)
            try ".test=(".write(to: definitions, atomically: true, encoding: .utf8)
            let invalid = try await scanner.scan(root: root, sources: rows, userDefinitions: definitions, executable: helper)
            XCTAssertNil(invalid.catalog.kind(for: "Alpha"))
            try ".test=(Alpha)".write(to: definitions, atomically: true, encoding: .utf8)
            _ = try await scanner.scan(root: root, sources: rows, userDefinitions: definitions, executable: helper)
            try ".test=(Other)".write(to: definitions, atomically: true, encoding: .utf8)
            let cached = try await scanner.scan(root: root, sources: rows, userDefinitions: definitions, executable: helper)
            XCTAssertEqual(cached.catalog.kind(for: "Alpha"), .code)
            XCTAssertNil(cached.catalog.kind(for: "Other"))
            try ".test=".write(to: definitions, atomically: true, encoding: .utf8)
            let disabled = try await scanner.scan(root: root, sources: rows, userDefinitions: definitions, executable: helper)
            XCTAssertNil(disabled.catalog.kind(for: "Alpha"))
        }
    }
    func testRawUTF16AndNonregularInputs() async throws {
        try await fixture { root, definitions in
            try ".test=(\\uD800)".write(to: definitions, atomically: true, encoding: .utf8)
            try Data([0xff, 0xfe, 0, 0xd8]).write(to: root.appendingPathComponent("raw.test"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.test").path, withDestinationPath: "raw.test")
            let fifo = root.appendingPathComponent("pipe.test")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            let rows: [MessageCodeScanner.Source] = [.init(path: "link.test", state: .modified), .init(path: "pipe.test", state: .modified), .init(path: "missing.test", state: .modified)]
            var options = MessageCodeScanner.Options(); options.maximumBytes = 4
            let result = try await MessageCodeScanner().scan(root: root, sources: rows, userDefinitions: definitions, options: options, executable: helper)
            XCTAssertEqual(result.catalog.kind(forUnits: [0xd800]), .code)
            for row in rows { XCTAssertEqual(result.catalog.kind(for: row.path), .file) }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("raw.test")), Data([0xff, 0xfe, 0, 0xd8]))
        }
    }
    func testTimeoutBetweenRowsPreservesAlreadyAddedCandidates() async throws {
        try await fixture { root, definitions in
            let clock = Clock()
            let scanner = MessageCodeScanner(nowMilliseconds: { clock.next() })
            let rows: [MessageCodeScanner.Source] = [.init(path: "one.test", state: .untracked), .init(path: "two.test", state: .untracked)]
            var options = MessageCodeScanner.Options(); options.timeoutSeconds = 0
            let result = try await scanner.scan(root: root, sources: rows, userDefinitions: definitions, options: options, executable: helper)
            XCTAssertTrue(result.timedOut); XCTAssertEqual(result.visitedRows, 1)
            XCTAssertEqual(result.catalog.kind(for: "one.test"), .file); XCTAssertNil(result.catalog.kind(for: "two.test"))
        }
    }
    func testCancelledScanThrowsInsteadOfPublishingAResult() async throws {
        try await fixture { root, definitions in
            let scanner = MessageCodeScanner()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await scanner.scan(root: root, sources: [], userDefinitions: definitions, executable: helper)
            }
            do { _ = try await task.value; XCTFail("Cancelled scanner published a result") }
            catch is CancellationError {}
        }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var index = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; index += 1; return index < 3 ? 0 : 1 }
    }
}
