import XCTest
@testable import TurtleGitCore

final class IssueRegexTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func match(_ message: String, _ check: String, _ extract: String = "") throws -> IssueRegexMatch {
        try IssueRegexRuntime.match(message: message, check: check, extract: extract, executable: parser)
    }
    func testPinnedUpstreamCaptureAndTwoExpressionExamples() throws {
        let captureless = try match("This is a test for PAF-88", "PAF-[0-9]+")
        XCTAssertTrue(captureless.hasMatch); XCTAssertTrue(captureless.ranges.isEmpty)
        let single = try match("Testing issue #99", "[Ii]ssue #?(\\d+)")
        XCTAssertEqual(single.identifiers(in: "Testing issue #99"), ["99"])
        let multi = "This is a test for Issue #7463,#666"
        let check = "[Ii]ssues?:?(\\s*(,|and)?\\s*#\\d+)+"
        let values = try match(multi, check, "(\\d+)")
        XCTAssertTrue(values.hasMatch); XCTAssertEqual(values.identifiers(in: multi), ["7463", "666"])
        XCTAssertFalse(try match("This is a test for Issue 7463,666", check, "(\\d+)").hasMatch)
        let padded = "[000815] some error fixed"
        XCTAssertEqual(try match(padded, "^\\[(\\d+)\\].*").identifiers(in: padded), ["000815"])
        let brackets = "test test [[000815]]] some error fixed"
        XCTAssertEqual(try match(brackets, "\\[\\[(\\d+)\\]\\]\\]").identifiers(in: brackets), ["000815"])
    }
    func testUTF16OffsetsAndWholeSecondExpressionMatches() throws {
        let text = "雪🦎 issues #42 and #73"
        let result = try match(text, "issues.*", "#(\\d+)")
        XCTAssertEqual(result.identifiers(in: text), ["#42", "#73"])
        XCTAssertEqual(result.ranges, [(text as NSString).range(of: "#42"), (text as NSString).range(of: "#73")])
        let surrogate = "🦎 issue #42"
        XCTAssertEqual(try match(surrogate, "[Ii]ssue #?(\\d+)").ranges, [NSRange(location: 10, length: 2)])
        XCTAssertFalse(try match("prefix\0issue #42", "[Ii]ssue #?(\\d+)").hasMatch)
    }
    func testLogBatchECMAScriptCaseInversionInvalidAndUTF16Records() throws {
        let texts = ["red fox\n", "RED FOX\n", "blue fox\n", "", "雪🦎\0after"]
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "red.*fox", caseSensitive: true, executable: parser), [true, false, false, false, false])
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "red.*fox", caseSensitive: false, executable: parser), [true, true, false, false, false])
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "!red.*fox", caseSensitive: false, executable: parser), [false, false, true, true, true])
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "(?<=red)fox", caseSensitive: false, executable: parser), Array(repeating: true, count: texts.count))
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "!(", caseSensitive: false, executable: parser), Array(repeating: false, count: texts.count))
        XCTAssertEqual(try IssueRegexRuntime.logMatches(texts, pattern: "after", caseSensitive: true, executable: parser), [false, false, false, false, true])
        XCTAssertEqual(try IssueRegexRuntime.logMatches(["🦎"], pattern: "\\uD83E\\uDD8E", caseSensitive: true, executable: parser), [true])
        let stopped = OperationCancellation(); stopped.cancel()
        XCTAssertThrowsError(try IssueRegexRuntime.logMatches(texts, pattern: "fox", caseSensitive: true, executable: parser, cancellation: stopped)) { XCTAssertTrue($0 is OperationCancellationFailure) }
    }
    func testLogHelperCancellationStopsOnlyOwnedProcessAndChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("slow-regex")
        let script = """
        #!/bin/sh
        /bin/sleep 30 &
        task_regex_child=$!
        trap 'kill "$task_regex_child" 2>/dev/null; wait "$task_regex_child" 2>/dev/null; exit 143' TERM INT
        echo "$$ $task_regex_child" > "$0.started"
        wait "$task_regex_child"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let token = OperationCancellation()
        let read = Task.detached { try IssueRegexRuntime.logMatches(["fox"], pattern: "fox", caseSensitive: false, executable: helper, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: helper.path + ".started"), deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await read.result; XCTFail("Regex helper did not start"); return }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        XCTAssertEqual(try IssueRegexRuntime.logMatches(["fox"], pattern: "fox", caseSensitive: false, executable: parser), [true])
        token.cancel()
        do { _ = try await read.value; XCTFail("Cancelled regex returned results") } catch is OperationCancellationFailure {}
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        // A helper timeout owns a separate token and must not cancel the Log window.
        try FileManager.default.removeItem(at: marker)
        let ongoing = OperationCancellation()
        let timed = Task.detached { try IssueRegexRuntime.logMatches(["fox"], pattern: "fox", caseSensitive: false, executable: helper, cancellation: ongoing) }
        do { _ = try await timed.value; XCTFail("Stalled regex did not time out") } catch HistoryRegexFailure.timedOut {}
        XCTAssertFalse(ongoing.isCancelled)
        let timeoutPids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(timeoutPids.count, 2)
        XCTAssertTrue(timeoutPids.allSatisfy { kill($0, 0) != 0 })
    }
    func testECMAScriptSyntaxFailuresAndMissingRuntime() throws {
        do { _ = try match("issue #42", "(?<=#)(\\d+)"); XCTFail("ECMAScript lookbehind unexpectedly accepted") }
        catch IssueRegexFailure.failed(let detail) { XCTAssertFalse(detail.isEmpty) }
        do { _ = try IssueRegexRuntime.match(message: "42", check: "(\\d+)", executable: URL(fileURLWithPath: "/no-such-turtlegit-issue-helper")); XCTFail("Missing runtime accepted") }
        catch IssueRegexFailure.runtimeMissing {}
        XCTAssertEqual(try match("42", ""), IssueRegexMatch(hasMatch: false, ranges: []))
    }
}
