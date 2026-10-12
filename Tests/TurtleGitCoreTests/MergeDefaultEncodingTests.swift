import XCTest
@testable import TurtleGitCore

final class MergeDefaultEncodingTests: XCTestCase {
    func testSourceASCIIDefaultAndShortFileClassification() {
        let data = Data("plain ASCII\r\n".utf8)
        XCTAssertEqual(ComparisonTextEncoding.detectMerge(data, preferUTF8: false), .windows1252)
        XCTAssertEqual(ComparisonTextEncoding.detectMerge(data, preferUTF8: true), .utf8)
        XCTAssertEqual(ComparisonTextEncoding.detect(data), .utf8) // generic consumers retain their API
        for value in ["", "a", "ab"] { XCTAssertEqual(ComparisonTextEncoding.detectMerge(Data(value.utf8), preferUTF8: true), .windows1252) }
    }
    func testBOMUnicodeLegacyAndInvalidInputs() throws {
        for encoding in [ComparisonTextEncoding.utf8BOM, .utf16LEBOM, .utf16BEBOM, .utf32LE, .utf32BE] {
            let bytes = try encoding.encode("snow 雪🦎\r\n")
            for flag in [false, true] { XCTAssertEqual(ComparisonTextEncoding.detectMerge(bytes, preferUTF8: flag), encoding) }
        }
        for flag in [false, true] {
            XCTAssertEqual(ComparisonTextEncoding.detectMerge(Data("café 雪".utf8), preferUTF8: flag), .utf8)
            let legacy = Data([0x63,0x61,0x66,0xe9,13,10])
            XCTAssertEqual(ComparisonTextEncoding.detectMerge(legacy, preferUTF8: flag), .windows1252)
            XCTAssertEqual(ComparisonTextEncoding.windows1252.decode(legacy), "café\r\n")
            XCTAssertNil(ComparisonTextEncoding.detectMerge(Data([0,0,0,0]), preferUTF8: flag))
            XCTAssertNil(ComparisonTextEncoding.detectMerge(Data([0xef,0xbb,0xbf,0xff]), preferUTF8: flag))
            XCTAssertNil(ComparisonTextEncoding.detectMerge(Data([0xff,0xfe,0,0xd8]), preferUTF8: flag))
        }
    }
    func testDocumentAdaptationAndSavePreserveCapturedBytesModeAndSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDefaultEncoding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        let bytes = Data([0x63,0x61,0x66,0xe9,13,10]); try bytes.write(to: base); try bytes.write(to: mine)
        let comparison = try WorkingFileComparison(base: base, destination: mine), raw = try comparison.read()
        XCTAssertNil(raw.destination.text)
        let document = raw.usingMergeEncoding(preferUTF8: false)
        XCTAssertEqual(document.destination.text, "café\r\n"); XCTAssertEqual(document.destination.bytes, bytes)
        XCTAssertEqual(document.destination.mode, raw.destination.mode); XCTAssertEqual(document.destination.permissions, raw.destination.permissions)
        let saved = try comparison.save(document, base: false, text: "café edit\r\n", encoding: .windows1252)
        XCTAssertEqual(saved.destination.encoding, .windows1252)
        XCTAssertEqual(try Data(contentsOf: mine), Data([0x63,0x61,0x66,0xe9]) + Data(" edit\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: base), bytes)
    }
    func testPreferenceAliasAndCanonicalPrecedence() {
        let suite = "TurtleGit.DefaultEncoding." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ComparisonTextEncoding.preferUTF8(from: prefs))
        prefs.set(true, forKey: "Merge.UseUTF8"); XCTAssertTrue(ComparisonTextEncoding.preferUTF8(from: prefs))
        prefs.set(false, forKey: "TurtleGitMerge.UseUTF8"); XCTAssertFalse(ComparisonTextEncoding.preferUTF8(from: prefs))
    }
}
