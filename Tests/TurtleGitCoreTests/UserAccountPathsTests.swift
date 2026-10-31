// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class UserAccountPathsTests: XCTestCase {
    func testAccountHomeWinsOverContainerOrPrivateProcessHome() {
        for fallback in ["/Users/test/Library/Containers/org.example.TurtleGit/Data", "/private/tmp/isolated-test-home"] {
            let directory = UserAccountPaths.resolveHome(accountHome: "/Users/test", fallback: URL(fileURLWithPath: fallback))
            XCTAssertEqual(directory.path, "/Users/test")
            XCTAssertTrue(directory.hasDirectoryPath)
            XCTAssertEqual(directory.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true).path,
                           "/Users/test/Library/Logs/DiagnosticReports")
        }
    }
    func testUnavailableOrInvalidAccountLocationsRetainFoundationFallback() {
        let fallback = URL(fileURLWithPath: "/private/tmp/foundation-home")
        for invalid in [nil, "", "relative/home", "~", "/", "///", "/./", "/Users/..", "/Users/test\0suffix"] as [String?] {
            let directory = UserAccountPaths.resolveHome(accountHome: invalid, fallback: fallback)
            XCTAssertEqual(directory.path, fallback.path, String(describing: invalid))
            XCTAssertTrue(directory.isFileURL); XCTAssertTrue(directory.hasDirectoryPath)
        }
    }
    func testAccountLocationNeedsNoExistingDirectoryAndKeepsUnicode() {
        let account = "/Users/fixture café/nonexistent-account-directory"
        let result = UserAccountPaths.resolveHome(accountHome: account, fallback: URL(fileURLWithPath: "/fallback"))
        XCTAssertEqual(result.path, account)
        XCTAssertTrue(result.hasDirectoryPath)
    }
    func testTildeExpansionUsesInjectedAccountLocationAndPreservesLiteralTailBytes() {
        let account = UserAccountPaths.resolveHome(accountHome: "/Users/test", fallback: URL(fileURLWithPath: "/container/Data"))
        let tail = "/cafe\u{301}/a[*]\nfile.txt"
        XCTAssertEqual(UserAccountPaths.expandingTilde("~", home: account), "/Users/test")
        XCTAssertTrue(UserAccountPaths.expandingTilde("~" + tail, home: account).utf8.elementsEqual(("/Users/test" + tail).utf8))
        XCTAssertEqual(UserAccountPaths.expandingTilde("~/", home: account), "/Users/test/")
        for literal in ["", "/container/Data/file", "/explicit/~/file", "relative/file", "./~/file", "cafe\u{301}"] {
            XCTAssertTrue(UserAccountPaths.expandingTilde(literal, home: account).utf8.elementsEqual(literal.utf8))
        }
    }
}
