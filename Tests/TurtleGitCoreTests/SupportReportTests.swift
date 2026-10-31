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
    func testIPSTerminationFallbackKeepsOriginalBodyAndExplicitPrivacyChoices() throws {
        let body = #"{"procName":"TurtleGitMac","termination":{"namespace":"SIGNAL","code":0,"indicator":"Termination\nreason\rtext"},"procPath":"/Users/test/private","private":"token-fixture"}"#
        for text in [body, #"{"bug_type":"309","bundleID":"org.test.turtle"}"# + "\n" + body] {
            let report = try SupportCrashReport.parse(Data(text.utf8), fileName: "termination.ips")
            XCTAssertEqual(report.exception, "SIGNAL / 0 / Termination reason text")
            XCTAssertEqual(Data(report.text.utf8), Data(text.utf8))
            var draft = SupportReportDraft()
            XCTAssertFalse(try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test").contains("token-fixture"))
            draft.includeCrashReport = true; draft.replaceHomePath = false
            let exact = try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test")
            XCTAssertTrue(exact.contains("Exception: SIGNAL / 0 / Termination reason text\n\n"))
            XCTAssertTrue(exact.hasSuffix(text)); XCTAssertTrue(exact.contains("/Users/test/private"))
            draft.replaceHomePath = true
            let replaced = try draft.render(systemInformation: "Version 1", report: report, home: "/Users/test")
            XCTAssertFalse(replaced.contains("/Users/test")); XCTAssertTrue(replaced.contains("<HOME>/private"))
            XCTAssertTrue(replaced.contains("token-fixture"))
            XCTAssertEqual(Data(report.text.utf8), Data(text.utf8))
        }
    }
    func testIPSExceptionPrecedenceAndEmptyExceptionTerminationFallback() throws {
        func summary(_ fields: String) throws -> String {
            try SupportCrashReport.parse(Data((#"{"procName":"TurtleGitMac","# + fields + "}").utf8), fileName: "summary.ips").exception
        }
        let termination = #""termination":{"namespace":"SIGNAL","code":9,"indicator":"Killed"}"#
        XCTAssertEqual(try summary(termination), "SIGNAL / 9 / Killed")
        XCTAssertEqual(try summary(#""exception":{},"# + termination), "SIGNAL / 9 / Killed")
        XCTAssertEqual(try summary(#""exception":{"type":" \n","signal":"\r "},"# + termination), "SIGNAL / 9 / Killed")
        XCTAssertEqual(try summary(#""exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"# + termination), "EXC_CRASH / SIGABRT")
        XCTAssertEqual(try summary(#""exception":{"signal":"SIGABRT"},"# + termination), "SIGABRT")
    }
    func testIPSTerminationSummaryIsBoundedAndDoesNotExplainMalformedValues() throws {
        let malformed = [#"{}"#, #"{"namespace":false,"code":false,"indicator":[]}"#,
                         #"{"namespace":7,"code":true,"indicator":{}}"#,
                         #"{"namespace":" \n","code":"0","indicator":"\r "}"#]
        for termination in malformed {
            let text = #"{"procName":"TurtleGitMac","termination":"# + termination + "}"
            let report = try SupportCrashReport.parse(Data(text.utf8), fileName: "malformed-metadata.ips")
            XCTAssertEqual(report.exception, ""); XCTAssertEqual(report.text, text)
        }
        let object: [String: Any] = ["procName": "TurtleGitMac", "termination": ["namespace": String(repeating: "n", count: 300), "code": 0, "indicator": "tail\ntext"]]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let report = try SupportCrashReport.parse(bytes, fileName: "bounded.ips")
        XCTAssertEqual(report.exception, String(repeating: "n", count: 256))
        XCTAssertEqual(Data(report.text.utf8), bytes)
        let separated = try JSONSerialization.data(withJSONObject: ["procName": "TurtleGitMac", "termination": ["indicator": "reason\u{2028}continued\u{0085}end"]])
        XCTAssertEqual(try SupportCrashReport.parse(separated, fileName: "separators.ips").exception, "reason continued end")
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
    func testDiscoveryMatchesExactAppAndSkipsHandledMalformedForeignAndSymlinkReports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let now = Date()
        func write(_ name:String,_ text:String,_ age:TimeInterval) throws -> URL {
            let file = root.appendingPathComponent(name); try Data(text.utf8).write(to:file)
            try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-age)],ofItemAtPath:file.path); return file
        }
        let matching = #"{"procName":"TurtleGitMac","bundleInfo":{"CFBundleIdentifier":"org.test.turtle"},"exception":{"type":"EXC_CRASH"}}"#
        let older = try write("TurtleGitMac-old.ips",matching,100)
        let newest = try write("TurtleGitMac-new.ips",matching.replacingOccurrences(of:"EXC_CRASH",with:"EXC_BAD_ACCESS"),10)
        _ = try write("TurtleGitMac-other.ips",matching.replacingOccurrences(of:"org.test.turtle",with:"org.test.other"),1)
        _ = try write("TurtleGitMac-wrong-process.ips",matching.replacingOccurrences(of:"TurtleGitMac",with:"TurtleGitMacOther"),1)
        _ = try write("TurtleGitMac-malformed.ips","not JSON",1)
        _ = try write("OtherApp-reporter.ips",matching,1)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("TurtleGitMac-linked.ips"),withDestinationURL:newest)
        let first = try XCTUnwrap(SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],now:now))
        XCTAssertEqual(first.report.fileName,newest.lastPathComponent)
        let second = try XCTUnwrap(SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[first.id],now:now))
        XCTAssertEqual(second.report.fileName,older.lastPathComponent)
        XCTAssertNil(try SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[first.id,second.id],now:now))
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],cancellation:token))
    }
    func testMetadataIdentityAndLegacyIdentityAndContentFingerprint() throws {
        let text = #"{"bundleID":"org.test.turtle","bug_type":"309"}"# + "\n" + ips.components(separatedBy:"\n")[1]
        let report = try SupportCrashReport.parse(Data(text.utf8),fileName:"TurtleGitMac-header.ips")
        XCTAssertEqual(report.bundleIdentifier,"org.test.turtle")
        let legacy = try SupportCrashReport.parse(Data("Process: TurtleGitMac [4]\nIdentifier: org.test.turtle\nException Type: EXC_CRASH\n".utf8),fileName:"TurtleGitMac-legacy.crash")
        XCTAssertEqual(legacy.bundleIdentifier,"org.test.turtle")
        let copy = try SupportCrashReport.parse(Data(text.utf8),fileName:"renamed.ips")
        XCTAssertEqual(SupportCrashIncident(report:report,date:Date()).id,SupportCrashIncident(report:copy,date:.distantPast).id)
    }
    func testDiscoveryDateBoundsAndCandidateLimitAndDirectorySymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let now = Date(), valid = #"{"procName":"TurtleGitMac","bundleInfo":{"CFBundleIdentifier":"org.test.turtle"},"exception":{"type":"EXC_CRASH"}}"#
        let good = root.appendingPathComponent("TurtleGitMac-good.ips"); try Data(valid.utf8).write(to:good)
        try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-31*24*3600)],ofItemAtPath:good.path)
        XCTAssertNil(try SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],now:now))
        try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(3600)],ofItemAtPath:good.path)
        XCTAssertNil(try SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],now:now))
        try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-100)],ofItemAtPath:good.path)
        for index in 0..<SupportCrashDiscovery.maximumCandidates {
            let file = root.appendingPathComponent("TurtleGitMac-invalid-\(index).ips"); try Data("invalid".utf8).write(to:file)
            try FileManager.default.setAttributes([.modificationDate:now],ofItemAtPath:file.path)
        }
        XCTAssertNil(try SupportCrashDiscovery.latest(in:root,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],now:now))
        let link = root.appendingPathComponent("linked"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertNil(try SupportCrashDiscovery.latest(in:link,process:"TurtleGitMac",bundleIdentifier:"org.test.turtle",excluding:[],now:now))
    }
    func testRecoveryPreferencesAreBoundedPrivateAndStoreNoReportText() throws {
        let suite = "TurtleGit.CrashRecovery."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertTrue(SupportCrashRecoveryPreferences.enabled(in:defaults))
        defaults.set(false,forKey:SupportCrashRecoveryPreferences.enabledKey); XCTAssertFalse(SupportCrashRecoveryPreferences.enabled(in:defaults))
        var last:SupportCrashIncident?
        for index in 0..<70 {
            let text = "Process: TurtleGitMac [\(index)]\nIdentifier: org.test.turtle\nException Type: EXC_CRASH\nPRIVATE_BODY\n"
            let incident = SupportCrashIncident(report:try SupportCrashReport.parse(Data(text.utf8),fileName:"TurtleGitMac-fixture.crash"),date:Date())
            SupportCrashRecoveryPreferences.acknowledge(incident,in:defaults); last = incident
        }
        SupportCrashRecoveryPreferences.acknowledge(last!,in:defaults)
        XCTAssertEqual(SupportCrashRecoveryPreferences.handled(in:defaults).count,64)
        XCTAssertFalse(String(describing:defaults.persistentDomain(forName:suite)!).contains("PRIVATE_BODY"))
    }

}
