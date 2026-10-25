import XCTest
@testable import TurtleGitCore

final class IssueMessageStyleTests: XCTestCase {
    func testCancelledStyleRequestsDoNotInvokeRegexOrFallback() async throws {
        let cancellation = OperationCancellation(); cancellation.cancel()
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "#([0-9]+)", "bugtraq.url": "https://example.invalid/%BUGID%"])
        XCTAssertThrowsError(try properties.messageStyles(in: "#42 *bold* https://example.invalid", executable: parser, cancellation: cancellation)) { XCTAssertTrue($0 is OperationCancellationFailure) }
        XCTAssertThrowsError(try IssueTrackerProperties().messageStyles(in: "*bold*", cancellation: cancellation)) { XCTAssertTrue($0 is OperationCancellationFailure) }
        do {
            _ = try await IssueMessageStyler().styles(properties: properties, message: "#42", cancellation: cancellation)
            XCTFail("Cancelled source style query was accepted")
        } catch { XCTAssertTrue(error is OperationCancellationFailure) }
    }
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    func testRepositoryHistoryIssueExtractionCancellation() async throws {
        let repo = GitRepository(root: URL(fileURLWithPath: "/"))
        let properties = IssueTrackerProperties(values: ["bugtraq.message": "Refs: %BUGID%"])
        let value = try await repo.issueFieldValue(properties: properties, message: "Body\nRefs: 73,42,73")
        XCTAssertEqual(value, "42 73")
        let stopped = OperationCancellation(); stopped.cancel()
        do {
            _ = try await repo.issueFieldValue(properties: properties, message: "Body\nRefs: 42", cancellation: stopped)
            XCTFail("A cancelled extraction must not return an issue ID")
        } catch { XCTAssertTrue(error is OperationCancellationFailure) }
    }
    func testUTF8StylingMapsEmojiOffsetsAndStylesOnlyCaptureOne() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "issue #(\\d+)", "bugtraq.url": "https://example.invalid/tickets/%BUGID%"])
        let message = "🦎 issue #42 after"
        let styles = try properties.messageStyles(in: message, executable: parser)
        XCTAssertEqual(styles.map(\.kind), [.context, .identifier])
        XCTAssertEqual(styles.map(\.range), [NSRange(location: 3, length: 7), NSRange(location: 10, length: 2)])
        XCTAssertNil(styles[0].url); XCTAssertEqual(styles[1].url, "https://example.invalid/tickets/42")
        let captureless = IssueTrackerProperties(values: ["bugtraq.logregex": "issue #\\d+"])
        XCTAssertTrue(try captureless.messageStyles(in: message, executable: parser).isEmpty)
    }
    func testTwoExpressionStylesContextAndCompleteInnerMatch() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.logregex": "issues.*\n#(\\d+)", "bugtraq.url": "https://example.invalid/%BUGID%"])
        let message = "雪🦎 issues #42 and #73 done"
        let styles = try properties.messageStyles(in: message, executable: parser)
        XCTAssertEqual(styles.map(\.kind), [.context, .identifier, .context, .identifier, .context])
        XCTAssertEqual(styles.map { (message as NSString).substring(with: $0.range) }, ["issues ", "#42", " and ", "#73", " done"])
        XCTAssertEqual(styles[1].url, "https://example.invalid/%2342")
        XCTAssertEqual(styles[3].url, "https://example.invalid/%2373")
    }
    func testByteRegexDiffersFromValidationAndAdjacentHotspotsMerge() throws {
        let splitScalar = IssueTrackerProperties(values: ["bugtraq.logregex": "(.{2})"])
        XCTAssertEqual(try splitScalar.identifiers(in: "🦎", executable: parser), ["🦎"])
        XCTAssertTrue(try splitScalar.messageStyles(in: "🦎", executable: parser).isEmpty)
        let literal = IssueTrackerProperties(values: ["bugtraq.logregex": "(雪)"])
        XCTAssertEqual(try literal.messageStyles(in: "🦎雪", executable: parser).map(\.range), [NSRange(location: 2, length: 1)])
        let adjacent = IssueTrackerProperties(values: ["bugtraq.logregex": "(\\d)", "bugtraq.url": "https://example.invalid/%BUGID%"])
        let styles = try adjacent.messageStyles(in: "42", executable: parser)
        XCTAssertEqual(styles.count, 1); XCTAssertEqual(styles[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(styles[0].url, "https://example.invalid/42")
    }
    func testHistoryFieldUsesWideMatchingNaturalOrderAndTemplateFallback() throws {
        let properties = IssueTrackerProperties(values: ["bugtraq.message": "Refs: %BUGID%", "bugtraq.logregex": "Refs: (\\d+)"])
        XCTAssertEqual(try properties.issueFieldValue(in: "Refs: 73\nRefs: 42\nRefs: 73", executable: parser), "42 73")
        XCTAssertEqual(try properties.issueFieldValue(in: "No issue", executable: parser), "")
        let simple = IssueTrackerProperties(values: ["bugtraq.message": "Refs: %BUGID%"])
        XCTAssertEqual(try simple.issueFieldValue(in: "Body\nRefs: 73,42", executable: parser), "42 73")
    }
}

extension IssueMessageStyleTests {
    func testConfiguredInvalidIssuePatternsKeepOnlyIndependentFormattingAndURLPasses()throws {
        let message="🦎 issue #42\n*bold* https://example.invalid/42"
        for pattern in ["(","issue.*\n("] {
            let properties=IssueTrackerProperties(values:["bugtraq.logregex":pattern,"bugtraq.url":"https://bugs.invalid/%BUGID%"])
            let styles=try properties.messageStyles(in:message,executable:parser)
            XCTAssertEqual(styles.map(\.kind),[.bold,.url])
            XCTAssertEqual(styles.map(\.range),[(message as NSString).range(of:"bold"),(message as NSString).range(of:"https://example.invalid/42")])
            guard styles.count == 2 else { continue }
            XCTAssertNil(styles[0].url);XCTAssertEqual(styles[1].url,"https://example.invalid/42")
            let plain=try properties.messageStyles(in:message,executable:parser,formattingEnabled:false)
            XCTAssertEqual(plain.map(\.kind),[.url])
            guard plain.count == 1 else { continue }
            XCTAssertEqual(plain[0].range,(message as NSString).range(of:"https://example.invalid/42"))
            // Source formatting retains its scalar/UTF16 boundary quirk within one line.
            let sameLine="🦎 issue #42 *bold* https://example.invalid/42"
            let sameLineStyles=try properties.messageStyles(in:sameLine,executable:parser)
            XCTAssertEqual(sameLineStyles.map(\.kind),[.url])
            XCTAssertEqual(sameLineStyles.map(\.range),[(sameLine as NSString).range(of:"https://example.invalid/42")])
        }
    }
    func testSourceStylingProtocolAndRuntimeErrorsAreNotURLFallbacks()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("IssueStyleSource-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("helper"),message="🦎 issue #42 https://example.invalid"
        let properties=IssueTrackerProperties(values:["bugtraq.logregex":"issue.*\n("])
        for output in ["styles\tutf8\n","styles\tutf8-source\nsyntax\tunknown\n","styles\tutf8-source\nsyntax\tinvalid-extraction\nidentifier\t0\t1\n","styles\tutf8-source\nsyntax\tvalid\nidentifier\t999\t1\n"] {
            let escaped=output.replacingOccurrences(of:"'",with:"'\"'\"'")
            try Data(("#!/bin/sh\nprintf '%s' '"+escaped+"'\n").utf8).write(to:helper)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            XCTAssertThrowsError(try properties.messageStyles(in:message,executable:helper)) {error in
                guard case IssueRegexFailure.failed=error else{return XCTFail("Bad styling reply became syntax/fallback: \(error)")}
            }
        }
        XCTAssertThrowsError(try properties.messageStyles(in:message,executable:root.appendingPathComponent("missing"))) {error in
            guard case IssueRegexFailure.runtimeMissing=error else{return XCTFail("Missing style runtime became URL fallback: \(error)")}
        }
        try Data("#!/bin/sh\necho 'source-style-runtime-sentinel' >&2\nexit 7\n".utf8).write(to:helper)
        XCTAssertThrowsError(try properties.messageStyles(in:message,executable:helper)) {error in
            guard case IssueRegexFailure.failed(let detail)=error else{return XCTFail("Runtime error changed type: \(error)")}
            XCTAssertTrue(detail.contains("source-style-runtime-sentinel"))
        }
    }
}
