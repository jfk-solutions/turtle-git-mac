// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SourceTextPatchApplicationTests: XCTestCase {
    private let utf8 = MergeTextEncodingPolicy(preferUTF8: true)
    private func patch(_ body: String, old: String = "a/file", new: String = "b/file") throws -> SourceTextPatchFile {
        try XCTUnwrap(SourceTextPatch.parse(bytes: Data(("--- " + old + "\n+++ " + new + "\n" + body).utf8)).files.first)
    }
    private func apply(_ body: String, _ input: String, old: String = "a/file", new: String = "b/file") throws -> SourceTextPatchApplication {
        try .simulate(file: patch(body, old: old, new: new), input: Data(input.utf8), textEncodingPolicy: utf8)
    }
    func testExactSimulationRetainsUntouchedBytesAndUsesTargetEndingForInsertions() throws {
        let result = try apply("@@ -1,3 +1,3 @@\n one\n-old\n+new\n last\n", "one\r\nold\r\nlast\r\n")
        XCTAssertEqual(result.outputData, Data("one\r\nnew\r\nlast\r\n".utf8))
        XCTAssertEqual(result.originalInput, Data("one\r\nold\r\nlast\r\n".utf8))
        XCTAssertEqual(result.recordCount, 4); XCTAssertFalse(result.removesFile)
        XCTAssertEqual(try result.validatedOutput(for: result.originalInput), result.outputData)
        XCTAssertThrowsError(try result.validatedOutput(for: Data("changed\r\n".utf8))) { XCTAssertEqual($0 as? SourceTextPatchApplication.Failure, .stale) }
    }
    func testAllSourceKeywordPrefixesBypassPayloadMismatchButRemainCaseSensitive() throws {
        let keywords = ["LastChangedDate", "Date", "LastChangedRevision", "Rev", "LastChangedBy", "Author", "HeadURL", "URL", "Id"]
        for keyword in keywords {
            let body = "@@ -1,2 +1,2 @@\n $\(keyword): patch payload$\n-$\(keyword): old patch payload$\n+replacement\n"
            XCTAssertEqual(try apply(body, "unrelated target context\nunrelated target removal\n").text, "unrelated target context\nreplacement\n", keyword)
            XCTAssertThrowsError(try apply("@@ -1,1 +1,1 @@\n-$\(keyword.lowercased()): payload$\n+replacement\n", "other\n"), keyword)
        }
        // This is a prefix test, not a keyword grammar or balanced '$' parser.
        XCTAssertEqual(try apply("@@ -1,1 +1,1 @@\n-$Revision without closing delimiter\n+replacement\n", "other\n").text, "replacement\n")
    }
    func testContextAllowsOnlySourceForwardLookaheadAndRejectsDistantOrBackwardSearch() throws {
        let body = "@@ -1,2 +1,2 @@\n context\n-old\n+new\n"
        for noise in ["noise\n", "noise one\nnoise two\n"] {
            XCTAssertEqual(try apply(body, noise + "context\nold\n").text, noise + "context\nnew\n")
        }
        XCTAssertThrowsError(try apply(body, "one\ntwo\nthree\ncontext\nold\n"))
        XCTAssertThrowsError(try apply("@@ -3,2 +3,2 @@\n context\n-old\n+new\n", "context\nold\nother\nother\n"))
    }
    func testOldPositionAcceptanceAndOldLookaheadDoNotInventNewCursorRelocation() throws {
        // PatchFile compares old coordinates when the new cursor differs, but
        // advances that cursor only one row; it does not relocate to oldStart.
        XCTAssertEqual(try apply("@@ -4,3 +1,3 @@\n context\n-b\n+new\n c\n", "a\nb\nc\ncontext\n").text, "a\nnew\nc\ncontext\n")
        XCTAssertEqual(try apply("@@ -3,3 +1,3 @@\n context\n-b\n+new\n c\n", "a\nb\nc\ncontext\n").text, "a\nnew\nc\ncontext\n")
    }
    func testInsertionGuardPreventsDuplicateInsertionAndKeepsSuccessfulSourceLookahead() throws {
        let body = "@@ -2,2 +2,3 @@\n+new\n old\n last\n"
        let once = try apply(body, "a\nold\nlast\n")
        XCTAssertEqual(once.text, "a\nnew\nold\nlast\n")
        XCTAssertThrowsError(try apply(body, once.text))
        XCTAssertThrowsError(try apply("@@ -1,1 +1,2 @@\n+new\n old\n", "other\nold\nlast\n"))
        // A pure insertion at the end has no later context requirement.
        XCTAssertEqual(try apply("@@ -1,0 +2,1 @@\n+end\n", "a\n").text, "a\nend\n")
    }
    func testMultipleHunksUseAbsoluteNewCoordinatesWithoutGlobalOffsetScoring() throws {
        let body = "@@ -1,2 +1,3 @@\n a\n+insert\n b\n@@ -3,1 +4,1 @@\n-c\n+C\n"
        XCTAssertEqual(try apply(body, "a\nb\nc\n").text, "a\ninsert\nb\nC\n")
        XCTAssertThrowsError(try apply("@@ -1,1 +99999,1 @@\n-a\n+A\n", "a\n"))
    }
    func testTrailingEmptyRecordAndNoNewlineWarningRetainSourceDistinction() throws {
        let body = "@@ -1,1 +0,0 @@\n-old\n\\ No newline at end of file\n"
        let unended = try apply(body, "old"), ended = try apply(body, "old\n")
        XCTAssertEqual(unended.outputData, Data()); XCTAssertTrue(unended.hasZeroRecords)
        XCTAssertEqual(ended.outputData, Data()); XCTAssertEqual(ended.recordCount, 1); XCTAssertFalse(ended.hasZeroRecords)
        let warning = try apply("@@ -1,1 +1,1 @@\n-old\n+new\n\\ No newline at end of file\n", "old")
        XCTAssertEqual(warning.text, "new\r\n", "Source ignores warning and uses AutoLine with CRLF fallback")
        let noPatchTerminator = try apply("@@ -1,1 +1,1 @@\n-old\n+new", "old")
        XCTAssertEqual(noPatchTerminator.text, "new")
    }
    func testTargetAllSupportedEndingsAndMixedUntouchedRecordsRemainExact() throws {
        for ending in MergeLineEnding.allCases {
            let result = try apply("@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n", "first" + ending.rawValue + "old" + ending.rawValue + "last" + ending.rawValue)
            XCTAssertEqual(result.text, "first" + ending.rawValue + "new" + ending.rawValue + "last" + ending.rawValue, ending.rawValue)
        }
        let mixed = try apply("@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n", "first\r\nold\nlast\r")
        XCTAssertEqual(mixed.text, "first\r\nnew\r\nlast\r")
    }
    func testUnicodeAndLegacyTargetCodecsAreRetainedLosslessly() throws {
        let file = try patch("@@ -1,1 +1,1 @@\n-café\n+thé\n")
        for encoding in [ComparisonTextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE, .utf16LEBOM, .utf16BEBOM, .utf32LE, .utf32BE, .windows1252] {
            let input = try encoding.encode("café\r\n")
            let policy = MergeTextEncodingPolicy(preferUTF8: true, legacyEncoding: .windows1252)
            let result = try SourceTextPatchApplication.simulate(file: file, input: input, textEncodingPolicy: policy)
            XCTAssertEqual(result.outputEncoding, encoding)
            XCTAssertEqual(result.outputData, try encoding.encode("thé\r\n"))
        }
    }
    func testSourceBOMTransitionsAndMissingPreimageUseCapturedLegacyNotContainer() throws {
        let addBOM = try patch("@@ -1,1 +1,1 @@\n-old\n+\u{feff}new\n")
        let promoted = try SourceTextPatchApplication.simulate(file: addBOM, input: Data("old\n".utf8), textEncodingPolicy: utf8)
        XCTAssertEqual(promoted.outputEncoding, .utf8BOM); XCTAssertEqual(promoted.outputData, try ComparisonTextEncoding.utf8BOM.encode("new\n"))
        let removeBOM = try patch("@@ -1,1 +1,1 @@\n-\u{feff}old\n+new\n")
        XCTAssertEqual(try SourceTextPatchApplication.simulate(file: removeBOM, input: ComparisonTextEncoding.utf8BOM.encode("old\n"), textEncodingPolicy: utf8).outputEncoding, .utf8)
        let added = try patch("@@ -0,0 +1,1 @@\n+café\n", old: "/dev/null")
        let legacy = try SourceTextPatchApplication.simulate(file: added, input: nil, textEncodingPolicy: utf8)
        XCTAssertEqual(legacy.outputEncoding, .windows1252); XCTAssertEqual(legacy.outputData, try ComparisonTextEncoding.windows1252.encode("café\r\n"))
        XCTAssertThrowsError(try SourceTextPatchApplication.simulate(file: patch("@@ -0,0 +1,1 @@\n+雪\n", old: "/dev/null"), input: nil, textEncodingPolicy: utf8))
        let unicodeAddition = try SourceTextPatchApplication.simulate(file: patch("@@ -0,0 +1,1 @@\n+\u{feff}雪\n", old: "/dev/null"), input: nil, textEncodingPolicy: utf8)
        XCTAssertEqual(unicodeAddition.outputEncoding, .utf8BOM)
    }
    func testAddedDeletedForcedBaseAndAbsentVersusEmptyWitnesses() throws {
        let added = try patch("@@ -0,0 +1,1 @@\n+new\n", old: "/dev/null")
        XCTAssertThrowsError(try SourceTextPatchApplication.simulate(file: added, input: Data(), textEncodingPolicy: utf8))
        let forced = try SourceTextPatchApplication.simulate(file: added, input: Data("existing\n".utf8), textEncodingPolicy: utf8, force: true)
        XCTAssertEqual(forced.text, "new\r\n"); XCTAssertEqual(forced.originalInput, Data("existing\n".utf8))
        XCTAssertThrowsError(try forced.validatedOutput(for: nil))
        let deleted = try patch("@@ -1,1 +0,0 @@\n-old\n", new: "/dev/null")
        let absent = try SourceTextPatchApplication.simulate(file: deleted, input: nil)
        XCTAssertEqual(absent.disposition, .alreadyDeleted); XCTAssertTrue(absent.removesFile); XCTAssertTrue(absent.hasZeroRecords)
        XCTAssertThrowsError(try absent.validatedOutput(for: Data()))
        let copiedBase = try SourceTextPatchApplication.simulate(file: patch("@@ -1,1 +1,1 @@\n-old\n+new\n"), input: Data("current target\n".utf8), baseInput: Data("old\r\n".utf8), textEncodingPolicy: utf8)
        XCTAssertEqual(copiedBase.text, "new\r\n"); XCTAssertEqual(copiedBase.originalInput, Data("current target\n".utf8))
    }
    func testExactUnicodeAndCancellationDoNotNormalizeOrPublishPartialResults() throws {
        let file = try patch("@@ -1,1 +1,1 @@\n-café\n+changed\n")
        XCTAssertThrowsError(try SourceTextPatchApplication.simulate(file: file, input: Data("cafe\u{301}\n".utf8), textEncodingPolicy: utf8))
        let cancellation = OperationCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try SourceTextPatchApplication.simulate(file: file, input: Data("café\n".utf8), cancellation: cancellation))
        let result = try SourceTextPatchApplication.simulate(file: file, input: Data("café\n".utf8), textEncodingPolicy: utf8)
        XCTAssertThrowsError(try result.validatedOutput(for: result.originalInput, cancellation: cancellation))
    }
    func testReceiptRetainsModeAndRenameRolesForCheckedMultiPathWriter() throws {
        let source="diff --git a/old b/new\nold mode 100644\nnew mode 100755\nrename from old\nrename to new\n--- a/old\n+++ b/new\n@@ -1,1 +1,1 @@\n-old\n+new\n"
        let file=try XCTUnwrap(SourceTextPatch.parse(bytes:Data(source.utf8)).files.first)
        let result=try SourceTextPatchApplication.simulate(file:file,input:Data("old\n".utf8),textEncodingPolicy:utf8)
        XCTAssertEqual(result.file,file)
        XCTAssertEqual(result.beforePathBytes,Data("old".utf8));XCTAssertEqual(result.afterPathBytes,Data("new".utf8))
        XCTAssertEqual(result.oldMode,"100644");XCTAssertEqual(result.newMode,"100755")
        XCTAssertEqual(result.file.renameFromPathBytes,Data("old".utf8));XCTAssertEqual(result.file.renameToPathBytes,Data("new".utf8))
    }

    func testZeroByteTargetAndBOMOnlyTargetRetainDifferentSourceRecordStates() throws {
        let file=try patch("@@ -0,0 +1,1 @@\n+new\n")
        let empty=try SourceTextPatchApplication.simulate(file:file,input:Data(),textEncodingPolicy:utf8)
        XCTAssertEqual(empty.outputEncoding,.windows1252);XCTAssertEqual(empty.recordCount,1)
        XCTAssertEqual(empty.outputData,try ComparisonTextEncoding.windows1252.encode("new\r\n"))
        let bomOnly=try SourceTextPatchApplication.simulate(file:file,input:Data([0xef,0xbb,0xbf]),textEncodingPolicy:utf8)
        XCTAssertEqual(bomOnly.outputEncoding,.utf8BOM);XCTAssertEqual(bomOnly.recordCount,2)
        XCTAssertEqual(bomOnly.outputData,try ComparisonTextEncoding.utf8BOM.encode("new\r\n"))
    }

}
