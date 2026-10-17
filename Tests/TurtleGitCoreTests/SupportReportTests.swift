// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SupportReportTests: XCTestCase {
    private let ips = #"{"bug_type":"309","incident_id":"private-fixture"}"# + "\n" + #"{"procName":"TurtleGitMac","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"procPath":"/Users/test/TurtleGit.app","threads":[]}"#
    func testAppleTwoObjectAndStandaloneJSONKeepOriginalText() throws {
        let report = try SupportCrashReport.parse(Data(ips.utf8), fileName: "example.ips")
        XCTAssertEqual(report.process, "TurtleGitMac"); XCTAssertEqual(report.exception, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(Data(report.text.utf8), Data(ips.utf8))
        let body = ips.components(separatedBy: "\n")[1]
        XCTAssertEqual(try SupportCrashReport.parse(Data(body.utf8), fileName: "single.IPS").process, "TurtleGitMac")
    }
    func testLegacyTextKeepsUnicodeAndAcceptsTerminationReports() throws {
        let text = "Process: TurtleGitMac [123]\r\nException Type: EXC_CRASH (SIGABRT)\r\nPath: /Users/test/cafe\u{301}\r\n"
        let report = try SupportCrashReport.parse(Data(text.utf8), fileName: "legacy.crash")
        XCTAssertEqual(report.process, "TurtleGitMac [123]"); XCTAssertEqual(Data(report.text.utf8), Data(text.utf8))
        XCTAssertNoThrow(try SupportCrashReport.parse(Data("Process: git [3]\nTermination Reason: SIGNAL 6\n".utf8), fileName: "helper.crash"))
    }
    func testIncompleteMalformedBinaryAndOversizedReportsAreRejected() {
        for text in ["", "{}", #"{"procName":"Other"}"#, #"{"procName":"Other","threads":[]}"#, #"{"metadata":true}"# + "\nnot JSON", ips + "\0"] {
            XCTAssertThrowsError(try SupportCrashReport.parse(Data(text.utf8), fileName: "bad.ips"))
        }
        XCTAssertThrowsError(try SupportCrashReport.parse(Data([0xFF, 0xFE]), fileName: "bad.crash"))
        XCTAssertThrowsError(try SupportCrashReport.parse(Data(ips.utf8), fileName: "bad.txt"))
        XCTAssertThrowsError(try SupportCrashReport.parse(Data(repeating: 32, count: SupportCrashReport.maximumBytes + 1), fileName: "large.ips"))
    }
    func testCrashInclusionIsExplicitAndHomeReplacementDoesNotClaimGeneralRedaction() throws {
        let report = try SupportCrashReport.parse(Data(ips.utf8), fileName: "example.ips")
        var draft = SupportReportDraft(); draft.details = "Open /Users/test/repo with token=private-fixture"
        var text = try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test")
        XCTAssertFalse(text.contains("SIGSEGV")); XCTAssertFalse(text.contains("/Users/test")); XCTAssertTrue(text.contains("<HOME>/repo")); XCTAssertTrue(text.contains("token=private-fixture"))
        draft.includeCrashReport = true; text = try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test")
        XCTAssertTrue(text.contains("SIGSEGV")); XCTAssertFalse(text.contains("/Users/test"))
        draft.replaceHomePath = false; text = try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test")
        XCTAssertTrue(text.contains(ips)); XCTAssertTrue(text.contains("/Users/test/repo"))
        draft.details = #"\/Users\/test\/repo"#; draft.replaceHomePath = true
        XCTAssertFalse(try draft.render(systemInformation: "", report: nil, home: "/Users/test").contains("test"))
    }
    func testDescriptionBoundsNullsAndEmptyHomeAreHandled() throws {
        var draft = SupportReportDraft(); draft.details = String(repeating: "x", count: 64 * 1024 + 1)
        XCTAssertThrowsError(try draft.render(systemInformation: "", report: nil, home: "/"))
        draft.details = "bad\0text"; XCTAssertThrowsError(try draft.render(systemInformation: "", report: nil, home: ""))
        draft.details = "home /repo"; XCTAssertTrue(try draft.render(systemInformation: "", report: nil, home: "/").contains("/repo"))
    }
    func testRegularFileBoundsSymlinkAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.ips"), link = root.appendingPathComponent("linked.ips")
        try Data(ips.utf8).write(to: file); XCTAssertEqual(try SupportCrashReport.read(file).process, "TurtleGitMac")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file); XCTAssertThrowsError(try SupportCrashReport.read(link))
        let token = OperationCancellation(); token.cancel(); XCTAssertThrowsError(try SupportCrashReport.read(file, cancellation: token))
        XCTAssertThrowsError(try SupportCrashReport.read(root))
    }
}
