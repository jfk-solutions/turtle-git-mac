import XCTest
@testable import TurtleGitCore

final class UnifiedDiffAppearanceTests: XCTestCase {
    func testSourceLineRulesDistinguishMetadataHeadersAndCombinedPatches() {
        let samples: [(UnifiedDiffLineStyle, [String])] = [
            (.command, ["diff --git a/a b/a", "Index: file"]),
            (.header, ["--- a/a", "+++ b/a", "==== path", "*** file", "? hint"]),
            (.position, ["@@ -1 +1 @@", "@@@ -1 -1 +1 @@@", "12c12", "--- 12,14 ----", "+++ 3", "***************", "*** 5 ****", "---\n", "---\r\n"]),
            (.added, ["+line", "++combined", "+-combined", "> normal"]),
            (.removed, ["-line", "--combined", "-+combined", "< normal", "---"]),
            (.comment, ["index abc..def 100644", "new file mode 100644", "\\ No newline at end of file", ""]),
            (.context, [" context", "! context changed"])
        ]
        for (style, lines) in samples { for line in lines { XCTAssertEqual(UnifiedDiffLineStyle.classify(line), style, line) } }
        XCTAssertEqual(UnifiedDiffLineStyle.classify("--- 0"), .header)
        XCTAssertEqual(UnifiedDiffLineStyle.classify("--- 12/path"), .header)
    }
    func testDefaultsMatchSourceLightDarkAndRestoreColorsKeepsFont() {
        var value = UnifiedDiffAppearance()
        XCTAssertEqual(value.colors(.header, dark: false), .init(0x800000, 0xffff80))
        XCTAssertEqual(value.colors(.added, dark: false), .init(0, 0xccffcc))
        XCTAssertEqual(value.colors(.removed, dark: true), .init(0xdddddd, 0x402020))
        XCTAssertEqual(value.colors(.command, dark: true), .init(0xc9e2f5, 0x202020))
        value.fontName = "Courier"; value.fontSize = 18; value.tabSize = 8
        value.light[.header] = .init(1, 2); value.dark[.header] = .init(3, 4)
        value.restoreColors(dark: false)
        XCTAssertEqual(value.colors(.header, dark: false), .init(0x800000, 0xffff80))
        XCTAssertEqual(value.colors(.header, dark: true), .init(3, 4))
        XCTAssertEqual(value.fontName, "Courier"); XCTAssertEqual(value.fontSize, 18); XCTAssertEqual(value.tabSize, 8)
    }
    func testSettingsRoundTripAllColorsIndependentlyAndSanitizeCorruptData() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var value = UnifiedDiffAppearance(); value.fontName = "Courier"; value.fontSize = 14; value.tabSize = 6
        for (index, style) in UnifiedDiffLineStyle.configurable.enumerated() { value.light[style] = .init(UInt32(index), UInt32(index + 10)); value.dark[style] = .init(UInt32(index + 20), UInt32(index + 30)) }
        value.save(to: defaults); XCTAssertEqual(UnifiedDiffAppearance.load(from: defaults), value)
        value.fontName = "\0"; value.fontSize = -1; value.tabSize = 1001; value.light[.added] = .init(0x1000000, 0)
        value.save(to: defaults); let clean = UnifiedDiffAppearance.load(from: defaults)
        XCTAssertEqual(clean.fontName, "Menlo"); XCTAssertEqual(clean.fontSize, 1); XCTAssertEqual(clean.tabSize, 1000)
        XCTAssertEqual(clean.colors(.added, dark: false), UnifiedDiffAppearance().colors(.added, dark: false))
        defaults.set(Data("malformed".utf8), forKey: "TurtleGit.UnifiedDiffAppearance")
        XCTAssertEqual(UnifiedDiffAppearance.load(from: defaults), UnifiedDiffAppearance())
    }
}
