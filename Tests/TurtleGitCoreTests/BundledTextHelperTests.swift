import XCTest
@testable import TurtleGitCore

final class BundledTextHelperTests: XCTestCase {
    private func helper(_ code: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTextHelperTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("helper")
        try ("#!/usr/bin/python3\n" + code).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }
    func testLargeErrorOutputDoesNotBlockAndDiagnosticsAreBounded() throws {
        let (directory, executable) = try helper("import sys\nsys.stdout.write('output' * 200000)\nsys.stderr.write('diagnostic' * 200000)\nsys.exit(1)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try BundledTextHelper.capture(executable: executable, arguments: [])
            XCTFail("Failed helper was accepted")
        } catch BundledTextHelperFailure.failed(let detail) {
            XCTAssertEqual(detail.utf8.count, 1024)
            XCTAssertTrue(detail.hasPrefix("diagnostic"))
        }
    }
    func testTimeoutKillsOnlyItsOwnUnresponsiveProcess() throws {
        let (directory, executable) = try helper("import signal,time,os\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nopen(__file__ + '.pid', 'w').write(str(os.getpid()))\ntime.sleep(60)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        do {
            _ = try BundledTextHelper.capture(executable: executable, arguments: [])
            XCTFail("Unresponsive helper was accepted")
        } catch BundledTextHelperFailure.timedOut {
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 5)
            XCTAssertLessThan(Date().timeIntervalSince(start), 12)
            let pid = try XCTUnwrap(Int32(String(contentsOf: executable.appendingPathExtension("pid"), encoding: .utf8)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
