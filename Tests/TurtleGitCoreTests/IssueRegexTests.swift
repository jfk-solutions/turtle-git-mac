import XCTest
@testable import TurtleGitCore

final class IssueRegexTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func match(_ message: String, _ check: String, _ extract: String = "") throws -> IssueRegexMatch {
        try IssueRegexRuntime.match(message: message, check: check, extract: extract, executable: parser)
    }
    func testBatchedIssueIDsMatchSingleSourceExtractionIncludingUTF16AndInvalidPatterns() throws {
        let messages = ["🦎 Issue #10 and #2", "Issue #7", "none", "Issue #1\0Issue #99"]
        let pattern = "#([0-9]+)"
        let batch = try IssueRegexRuntime.batchIssueIDs(messages,check:pattern,executable:parser)
        let single = try messages.map { try IssueRegexRuntime.match(message:$0,check:pattern,executable:parser,ignoreInvalidPattern:true).identifiers(in:$0) }
        XCTAssertEqual(batch,single)
        let two = try IssueRegexRuntime.batchIssueIDs(messages,check:"Issue.*",extract:"#[0-9]+",executable:parser)
        let twoSingle = try messages.map { try IssueRegexRuntime.match(message:$0,check:"Issue.*",extract:"#[0-9]+",executable:parser,ignoreInvalidPattern:true).identifiers(in:$0) }
        XCTAssertEqual(two,twoSingle)
        XCTAssertEqual(try IssueRegexRuntime.batchIssueIDs(messages,check:"(",executable:parser),Array(repeating:[],count:4))
        XCTAssertEqual(try IssueRegexRuntime.batchIssueIDs(["b"],check:"(a)?b",executable:parser),[[""]])
    }
    func testLogValidationUsesECMAScriptIncludingInversionAndCancellation() throws {
        for expression in ["", "!", "blue|snow", "!blue", "\\uD83E\\uDD8E", "^a.*$"] {
            XCTAssertTrue(try IssueRegexRuntime.validateLogPattern(expression, caseSensitive: true, executable: parser), expression)
        }
        for expression in ["(", "![", "(?<=#)42"] {
            XCTAssertFalse(try IssueRegexRuntime.validateLogPattern(expression, caseSensitive: false, executable: parser), expression)
        }
        let stopped = OperationCancellation(); stopped.cancel()
        XCTAssertThrowsError(try IssueRegexRuntime.validateLogPattern("blue", caseSensitive: false, executable: parser, cancellation: stopped)) { XCTAssertTrue($0 is OperationCancellationFailure) }
    }
    func testSourceSVNRevisionBatchPatternsAndWholeMessageAnchors() throws {
        let messages = ["git-svn-id: https://example.invalid/a@b@00123 abcd-123", "\n\tgit-svn-id: 0007@ab-c9", "subject\n\ngit-svn-id: https://example.invalid/a@42 abcd", "git-svn-id: https://example.invalid/a@42 abcd\n", "git-svn-id: 42@ABCD", "git-svn-id: 42@abcd\0ignored", "ordinary"]
        XCTAssertEqual(try IssueRegexRuntime.svnRevisions(messages, executable: parser), ["00123", "0007", "", "", "", "42", ""])
        XCTAssertEqual(try IssueRegexRuntime.svnRevisions([], executable: parser), [])
        let stopped = OperationCancellation(); stopped.cancel()
        XCTAssertThrowsError(try IssueRegexRuntime.svnRevisions(messages, executable: parser, cancellation: stopped)) { XCTAssertTrue($0 is OperationCancellationFailure) }
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

extension IssueRegexTests {
    func testConfiguredSourceSyntaxRetainsSuccessfulFirstExpressionWithoutRanges()throws {
        let message="雪🦎 issues #42 and #73"
        let valid=try IssueRegexRuntime.sourceMatch(message:message,check:"issues.*",extract:"#[0-9]+",executable:parser)
        XCTAssertEqual(valid.syntax,.valid);XCTAssertTrue(valid.hasMatch)
        XCTAssertEqual(valid.identifiers(in:message),["#42","#73"])
        XCTAssertEqual(valid.ranges,[(message as NSString).range(of:"#42"),(message as NSString).range(of:"#73")])
        let partial=try IssueRegexRuntime.sourceMatch(message:message,check:"issues.*",extract:"(",executable:parser)
        XCTAssertEqual(partial.syntax,.invalidExtraction);XCTAssertTrue(partial.hasMatch);XCTAssertEqual(partial.ranges,[])
        let miss=try IssueRegexRuntime.sourceMatch(message:"No issue here",check:"issues.*",extract:"(",executable:parser)
        XCTAssertEqual(miss.syntax,.invalidExtraction);XCTAssertFalse(miss.hasMatch);XCTAssertEqual(miss.ranges,[])
        let invalid=try IssueRegexRuntime.sourceMatch(message:message,check:"(",extract:"#[0-9]+",executable:parser)
        XCTAssertEqual(invalid.syntax,.invalidCheck);XCTAssertFalse(invalid.hasMatch);XCTAssertEqual(invalid.ranges,[])
        // The strict tester still rejects either malformed expression. Tolerant
        // source-property matching is an explicit separate operation.
        for(check,extract)in [("issues.*","("),("(","#[0-9]+")] {
            XCTAssertThrowsError(try IssueRegexRuntime.match(message:message,check:check,extract:extract,executable:parser)) {error in
                guard case IssueRegexFailure.failed=error else{return XCTFail("Not a strict syntax failure: \(error)")}
            }
        }
    }
    func testSourceCaptureOffsetsNULTerminationAndInactiveRuntimeBypass()throws {
        let message="雪🦎 issue #42\0issue #99"
        let result=try IssueRegexRuntime.sourceMatch(message:message,check:"issue #([0-9]+)",executable:parser)
        XCTAssertEqual(result.syntax,.valid);XCTAssertTrue(result.hasMatch)
        XCTAssertEqual(result.identifiers(in:message),["42"])
        XCTAssertEqual(result.ranges,[(message as NSString).range(of:"42")])
        let missing=URL(fileURLWithPath:"/no-such-turtlegit-source-regex")
        let inactive=try IssueRegexRuntime.sourceMatch(message:message,check:"",extract:"(",executable:missing)
        XCTAssertEqual(inactive.syntax,.inactive);XCTAssertFalse(inactive.hasMatch);XCTAssertEqual(inactive.ranges,[])
        let stopped=OperationCancellation();stopped.cancel()
        XCTAssertThrowsError(try IssueRegexRuntime.sourceMatch(message:message,check:"",executable:missing,cancellation:stopped)) {XCTAssertTrue($0 is OperationCancellationFailure)}
        XCTAssertThrowsError(try IssueRegexRuntime.sourceMatch(message:message,check:"issue",executable:missing)) {error in
            guard case IssueRegexFailure.runtimeMissing=error else{return XCTFail("Missing helper disguised as syntax: \(error)")}
        }
    }
    private func sourceFixtureHelper(_ script:String)throws->(URL,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("IssueSource-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let helper=root.appendingPathComponent("helper")
        try Data(("#!/bin/sh\n"+script+"\n").utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        return(root,helper)
    }
    func testSourceSyntaxProtocolAndExecutionFailuresRemainFailures()throws {
        let malformed=[
            "matched\t1\n",
            "source\t1\nsyntax\tunknown\nmatched\t0\n",
            "source\t1\nsyntax\tinvalid-check\nmatched\t1\n",
            "source\t1\nsyntax\tinvalid-extraction\nmatched\t1\n0\t1\n",
            "source\t1\nsyntax\tvalid\nmatched\t1\n999\t1\n"
        ]
        for output in malformed {
            let escaped=output.replacingOccurrences(of:"'",with:"'\"'\"'")
            let(root,helper)=try sourceFixtureHelper("printf '%s' '"+escaped+"'");defer{try? FileManager.default.removeItem(at:root)}
            XCTAssertThrowsError(try IssueRegexRuntime.sourceMatch(message:"🦎 issue #42",check:"issue.*",extract:"#[0-9]+",executable:helper)) {error in
                guard case IssueRegexFailure.failed(let detail)=error else{return XCTFail("Malformed wire accepted as syntax: \(error)")}
                XCTAssertFalse(detail.isEmpty)
            }
        }
        let(root,helper)=try sourceFixtureHelper("echo 'source-regex-runtime-sentinel' >&2\nexit 7");defer{try? FileManager.default.removeItem(at:root)}
        XCTAssertThrowsError(try IssueRegexRuntime.sourceMatch(message:"issue #42",check:"issue.*",extract:"(",executable:helper)) {error in
            guard case IssueRegexFailure.failed(let detail)=error else{return XCTFail("Execution failure became syntax: \(error)")}
            XCTAssertTrue(detail.contains("source-regex-runtime-sentinel"))
        }
    }
    func testConfiguredSourceCancellationReapsOnlyItsOwnedHelperAndChild()async throws {
        let(root,helper)=try sourceFixtureHelper("""
        /bin/sleep 30 &
        task_issue_child=$!
        trap 'kill "$task_issue_child" 2>/dev/null; wait "$task_issue_child" 2>/dev/null; exit 143' TERM INT
        echo "$$ $task_issue_child" > "$0.started"
        wait "$task_issue_child"
        """)
        defer{try? FileManager.default.removeItem(at:root)}
        let token=OperationCancellation(),marker=URL(fileURLWithPath:helper.path+".started")
        let request=Task.detached {try IssueRegexRuntime.sourceMatch(message:"issue #42",check:"issue.*",extract:"(",executable:helper,cancellation:token)}
        defer{token.cancel()}
        do {
            let deadline=Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath:marker.path),Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
            guard FileManager.default.fileExists(atPath:marker.path) else{token.cancel();_=await request.result;return XCTFail("Owned source helper did not start")}
            let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
            XCTAssertEqual(pids.count,2)
            let independent=try IssueRegexRuntime.sourceMatch(message:"issue #73",check:"issue #([0-9]+)",executable:parser)
            XCTAssertEqual(independent.identifiers(in:"issue #73"),["73"])
            token.cancel()
            do{_=try await request.value;XCTFail("Cancellation returned a syntax receipt")}catch is OperationCancellationFailure {}
            let drained=Date().addingTimeInterval(3)
            while Date()<drained,pids.contains(where:{kill($0,0)==0}){try await Task.sleep(nanoseconds:10_000_000)}
            XCTAssertTrue(pids.allSatisfy{kill($0,0) != 0})
        } catch {token.cancel();_=await request.result;throw error}
    }
}
