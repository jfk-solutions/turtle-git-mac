// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SourceTextPatchParserTests: XCTestCase {
    private let ordinary = "--- a/one.txt\n+++ b/one.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    private func parse(_ text: String) throws -> SourceTextPatch { try SourceTextPatch.parse(bytes: Data(text.utf8)) }

    func testUnicodeContainersUseCapturedCodecsAndRetainExactBytes() throws {
        let text = "--- a/日本.txt\n+++ b/日本.txt\n@@ -1,1 +1,1 @@\n-古い\n+新しい\n"
        for codec in [ComparisonTextEncoding.utf8BOM, .utf16LEBOM, .utf16BEBOM, .utf32LE, .utf32BE] {
            let bytes = try codec.encode(text), patch = try SourceTextPatch.parse(bytes: bytes)
            XCTAssertEqual(patch.originalBytes, bytes)
            XCTAssertEqual(patch.document.bytes, bytes)
            XCTAssertEqual(patch.sourceEncoding, codec)
            XCTAssertEqual(patch.text, text)
            XCTAssertEqual(patch.files.first?.pathBytes, Data("日本.txt".utf8))
            XCTAssertEqual(patch.files.first?.hunks.first?.lines.last?.text, "新しい")
            XCTAssertTrue(SourceTextPatch.recognizedTextEligibility(bytes: bytes))
        }
    }

    func testBOMlessUTF16AndCapturedLegacyCodePage() throws {
        for codec in [ComparisonTextEncoding.utf16LE, .utf16BE] {
            let bytes = try codec.encode(ordinary)
            XCTAssertEqual(try SourceTextPatch.parse(bytes: bytes).files.count, 1)
        }
        let text = "--- a/тест\n+++ b/тест\n@@ -1,1 +1,1 @@\n-да\n+нет\n"
        let bytes = try ComparisonTextEncoding.windows1251.encode(text)
        let patch = try SourceTextPatch.parse(bytes: bytes, textEncodingPolicy: .init(preferUTF8: false, legacyEncoding: .windows1251))
        XCTAssertEqual(patch.sourceEncoding, .windows1251)
        XCTAssertEqual(patch.files[0].pathBytes, Data("тест".utf8))
        XCTAssertEqual(patch.files[0].hunks[0].lines.last?.text, "нет")
    }

    func testSVNAndGNUFilePairsDoNotRequireGitHeaders() throws {
        let text = "Index: first.txt\n===================================================================\n" +
            "--- first.txt (revision 52)\n+++ first.txt (working copy)\n@@ -1,1 +1,1 @@\n-old\n+new\n" +
            "--- nested/第二.txt （版本 12）\n+++ nested/第二.txt （工作副本）\n@@ -1,1 +1,1 @@\n-前\n+後\n"
        let patch = try parse(text)
        XCTAssertEqual(patch.files.map(\.id), [0, 1])
        XCTAssertEqual(patch.files.map(\.pathBytes), [Data("first.txt".utf8), Data("nested/第二.txt".utf8)])
        XCTAssertNil(patch.files[0].oldRevision)
        XCTAssertEqual(patch.files[1].hunks[0].lines.map(\.text), ["前", "後"])
    }

    func testQuotedPathsTabsOctalAndBackslashSeparators() throws {
        let text = "diff --git \"a/sp ace/\\303\\251.txt\" \"b/sp ace/\\303\\251.txt\"\nindex abc1234..def5678 100644\n" +
            "--- \"a/sp ace/\\303\\251.txt\"\t2020-01-01\n+++ \"b/sp ace/\\303\\251.txt\"\t2020-01-02\n@@ -1,1 +1,1 @@\n-a\n+b\n"
        let file = try XCTUnwrap(parse(text).files.first)
        XCTAssertEqual(file.oldPathBytes, Data("sp ace/é.txt".utf8))
        XCTAssertEqual(file.newPathBytes, Data("sp ace/é.txt".utf8))
        XCTAssertEqual(file.rawOldPathBytes, Data("a/sp ace/é.txt".utf8))
        XCTAssertEqual(file.oldRevision, "abc1234")
        XCTAssertEqual(file.newRevision, "def5678")
        XCTAssertEqual(try parse(ordinary.replacingOccurrences(of: "a/one.txt", with: "dir\\one.txt")).files[0].oldPathBytes, Data("dir/one.txt".utf8))
    }

    func testRevisionMetadataDoesNotLeakToFollowingFile() throws {
        let patch = try parse("diff --git a/one.txt b/one.txt\nindex abc..def 100644\n" + ordinary + ordinary.replacingOccurrences(of: "one.txt", with: "two.txt"))
        XCTAssertEqual(patch.files[0].oldRevision, "abc")
        XCTAssertNil(patch.files[1].oldRevision)
        XCTAssertNil(patch.files[1].newRevision)
    }

    func testAddDeleteAndReverseRetainOriginalDataAndStableFileIDs() throws {
        let text = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+created\n" +
            "--- a/gone.txt\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-deleted\n"
        let patch = try parse(text), reverse = patch.reversed
        XCTAssertNil(patch.files[0].oldPathBytes)
        XCTAssertNil(patch.files[1].newPathBytes)
        XCTAssertEqual(reverse.originalBytes, Data(text.utf8))
        XCTAssertEqual(reverse.files.map(\.id), [0, 1])
        XCTAssertEqual(reverse.files[0].oldPathBytes, Data("new.txt".utf8))
        XCTAssertNil(reverse.files[0].newPathBytes)
        XCTAssertEqual(reverse.files[0].hunks[0].oldStart, 1)
        XCTAssertEqual(reverse.files[0].hunks[0].newCount, 0)
        XCTAssertEqual(reverse.files[0].hunks[0].lines[0].kind, .removed)
        XCTAssertEqual(reverse.reversed.files, patch.files)
    }

    func testExplicitStripUsesRawPathsAndRejectsExhaustion() throws {
        let patch = try parse(ordinary.replacingOccurrences(of: "one.txt", with: "dir/one.txt"))
        XCTAssertEqual(patch.files[0].pathBytes, Data("dir/one.txt".utf8))
        XCTAssertEqual(try patch.strippingPaths(0).files[0].pathBytes, Data("b/dir/one.txt".utf8))
        XCTAssertEqual(try patch.strippingPaths(1).files[0].pathBytes, Data("dir/one.txt".utf8))
        XCTAssertEqual(try patch.strippingPaths(2).files[0].pathBytes, Data("one.txt".utf8))
        XCTAssertThrowsError(try patch.strippingPaths(3)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .stripCount) }
        XCTAssertThrowsError(try patch.strippingPaths(-1)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .stripCount) }
    }

    func testSourceShorthandCountsAreNotAssumedToBeGitOneLineRanges() throws {
        let patch = try parse("--- x\n+++ x\n@@ -2 +2 @@\n first\n second\n")
        let hunk = patch.files[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 0); XCTAssertEqual(hunk.oldCount, 2)
        XCTAssertEqual(hunk.newStart, 1); XCTAssertEqual(hunk.newCount, 2)
        XCTAssertThrowsError(try parse("--- x\n+++ x\n@@ -7 +7 @@\n only one\n"))
    }

    func testBOMFlagsAreLineLocalAndSwapOnReverse() throws {
        let patch = try parse("--- x\n+++ x\n@@ -1,2 +1,2 @@\n-\u{feff}old\n+new\n \u{feff}context\n")
        let file = patch.files[0]
        XCTAssertEqual(file.oldHasBOM, true); XCTAssertEqual(file.newHasBOM, false)
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["old", "new", "context"])
        XCTAssertEqual(file.hunks[0].lines.map(\.hadBOM), [true, false, true])
        XCTAssertEqual(file.reversed.oldHasBOM, false); XCTAssertEqual(file.reversed.newHasBOM, true)
        let later = try parse("--- x\n+++ x\n@@ -3,1 +3,1 @@\n-old\n+\u{feff}new\n").files[0]
        XCTAssertNil(later.oldHasBOM); XCTAssertNil(later.newHasBOM)
    }

    func testWarningsDoNotChangeThePrecedingRecordEnding() throws {
        let patch = try parse("--- x\r\n+++ x\r\n@@ -1,1 +1,1 @@\r\n-old\r\n\\ No newline at end of file\r\n+new\r\n\\ No newline at end of file\r\n")
        let hunk = patch.files[0].hunks[0]
        XCTAssertEqual(hunk.warnings.count, 2)
        XCTAssertEqual(hunk.lines.map(\.ending), [.automatic, .automatic])
        XCTAssertEqual(hunk.lines.map(\.originalEnding), [.crlf, .crlf])
        let final = try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@\n-old\n+new").files[0].hunks[0]
        XCTAssertEqual(try XCTUnwrap(final.lines.last).ending, .none)
        XCTAssertNil(final.lines.last?.originalEnding)
    }

    func testEmptyContextAndMultipleHunksPreserveOrderAndEndingKinds() throws {
        let patch = try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@\n\n@@ -8,1 +8,1 @@ section\n-before\n+after\n")
        XCTAssertEqual(patch.files[0].hunks.count, 2)
        XCTAssertEqual(patch.files[0].hunks[0].lines[0].text, "")
        XCTAssertEqual(patch.files[0].hunks[0].lines[0].kind, .context)
        XCTAssertEqual(patch.files[0].hunks[1].oldStart, 8)
        let virtual = try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@\n").files[0].hunks[0]
        XCTAssertEqual(virtual.lines.count, 1)
        XCTAssertEqual(virtual.lines[0].text, "")
        XCTAssertEqual(virtual.lines[0].kind, .context)
        XCTAssertEqual(virtual.lines[0].ending, .none)
        XCTAssertNil(virtual.lines[0].originalEnding)
        XCTAssertThrowsError(try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@"))
        for ending in MergeLineEnding.allCases {
            let text = ordinary.replacingOccurrences(of: "\n", with: ending.rawValue)
            XCTAssertTrue(SourceTextPatch.recognizedTextEligibility(bytes: Data(text.utf8)))
            XCTAssertEqual(try parse(text).files[0].hunks[0].lines[0].originalEnding, ending)
        }
    }

    func testExpandedKeywordRecognitionIsCaseSensitivePayloadPrefixSearch() throws {
        for token in ["LastChangedDate", "Date", "LastChangedRevision", "Rev", "LastChangedBy", "Author", "HeadURL", "URL", "Id"] {
            let hunk = try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@\n-prefix $\(token) suffix\n+replacement\n").files[0].hunks[0]
            XCTAssertTrue(hunk.lines[0].hasExpandedKeywords, token)
        }
        let hunk = try parse("--- x\n+++ x\n@@ -1,1 +1,1 @@\n-$rev: lower$\n+Date without dollar\n").files[0].hunks[0]
        XCTAssertFalse(hunk.lines[0].hasExpandedKeywords)
        XCTAssertFalse(hunk.lines[1].hasExpandedKeywords)
    }

    func testStrictHunkBoundariesDoNotPublishPartialFiles() throws {
        for malformed in [
            "--- x\nnot a new header\n",
            "--- x\n+++ x\n@@ -x,1 +1,1 @@\n-a\n+b\n",
            "--- x\n+++ x\n@@ -1,2 +1,1 @@\n-a\n+b\n",
            "--- x\n+++ x\n@@ -1,1 +1,1 @@\n-a\n+b\n+extra\n",
            "--- x\n+++ x\n@@ -1,1 +1,1 @@\n?unknown\n",
            "--- x\n+++ x\n@@ -99999999999999999999,1 +1,1 @@\n-a\n+b\n"
        ] { XCTAssertThrowsError(try parse(ordinary + malformed), malformed) }
        XCTAssertThrowsError(try parse("--- x\n+++ x\n"))
        XCTAssertThrowsError(try parse("arbitrary text\n")) { XCTAssertEqual($0 as? SourceTextPatchFailure, .unrecognized) }
    }

    func testOpaqueAndSpecialFileRecordsRefuseTheEntireMixedDocument() throws {
        for opaque in ["GIT binary patch\nliteral 4\nabc\n", "Binary files a/x and b/x differ\n",
            "diff --cc x\n", "diff --combined x\n", "new file mode 120000\n", "index abc..def 160000\n"] {
            let bytes = Data((ordinary + opaque).utf8)
            XCTAssertFalse(SourceTextPatch.recognizedTextEligibility(bytes: bytes))
            XCTAssertThrowsError(try SourceTextPatch.parse(bytes: bytes)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .opaque) }
        }
        for metadataOnly in ["diff --git a/mode b/mode\nold mode 100644\nnew mode 100755\n",
            "diff --git a/before b/after\nsimilarity index 100%\nrename from before\nrename to after\n"] {
            XCTAssertThrowsError(try parse(ordinary + metadataOnly)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .opaque) }
            XCTAssertThrowsError(try parse(metadataOnly + "diff --git a/one.txt b/one.txt\n" + ordinary)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .opaque) }
        }
        XCTAssertFalse(SourceTextPatch.recognizedTextEligibility(bytes: Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try SourceTextPatch.parse(bytes: Data([0xff, 0xfe, 45])))
        XCTAssertThrowsError(try parse("--- /dev/null\n+++ /dev/null\n@@ -0,0 +0,0 @@\n"))
        XCTAssertThrowsError(try parse("--- \"a/\\777\"\n+++ b/x\n@@ -1,1 +1,1 @@\n-a\n+b\n"))
    }

    func testDuplicatePathRuleMatchesPinnedSecondOccurrenceAllowance() throws {
        XCTAssertEqual(try parse(ordinary + ordinary).files.count, 2)
        XCTAssertThrowsError(try parse(ordinary + ordinary + ordinary)) { XCTAssertEqual($0 as? SourceTextPatchFailure, .duplicatePath) }
    }

    func testRegularModeRenameAndCopyMetadataAreRetainedRatherThanDropped() throws {
        let text = "diff --git a/old b/new\nold mode 100644\nnew mode 100755\nrename from old\nrename to new\nindex abc..def\n" +
            "--- a/old\n+++ b/new\n@@ -1,1 +1,1 @@\n-old\n+new\n"
        let file = try parse(text).files[0]
        XCTAssertEqual(file.oldMode, "100644"); XCTAssertEqual(file.newMode, "100755")
        XCTAssertEqual(file.renameFromPathBytes, Data("old".utf8))
        XCTAssertEqual(file.renameToPathBytes, Data("new".utf8))
        XCTAssertEqual(file.reversed.oldMode, "100755")
        XCTAssertEqual(file.reversed.renameFromPathBytes, Data("new".utf8))
        let copy = try parse(text.replacingOccurrences(of: "rename from", with: "copy from").replacingOccurrences(of: "rename to", with: "copy to")).files[0]
        XCTAssertEqual(copy.copyFromPathBytes, Data("old".utf8)); XCTAssertEqual(copy.copyToPathBytes, Data("new".utf8))
        XCTAssertNil(copy.renameFromPathBytes)
        let mode = try parse("diff --git a/one.txt b/one.txt\nindex abc..def 100755\n" + ordinary).files[0]
        XCTAssertEqual(mode.oldMode, "100755"); XCTAssertEqual(mode.newMode, "100755")
    }

    func testQuotedNativeGitNamesKeepParenthesesAndLiteralBackslashes() throws {
        let patch = try parse("--- \"a/folder/name(1)\\\\part.txt\"\n+++ \"b/folder/name(1)\\\\part.txt\"\n@@ -1,1 +1,1 @@\n-old\n+new\n")
        XCTAssertEqual(patch.files[0].pathBytes, Data("folder/name(1)\\part.txt".utf8))
        XCTAssertEqual(try patch.strippingPaths(1).files[0].pathBytes, Data("folder/name(1)\\part.txt".utf8))
        let svn = try parse("--- \"folder/name(1)\\\\part.txt\" (revision 4)\n+++ \"folder/name(1)\\\\part.txt\" （working copy）\n@@ -1,1 +1,1 @@\n-old\n+new\n")
        XCTAssertEqual(svn.files[0].oldPathBytes, Data("folder/name(1)\\part.txt".utf8))
        XCTAssertEqual(svn.files[0].newPathBytes, Data("folder/name(1)\\part.txt".utf8))
        XCTAssertNil(svn.files[0].oldRevision)
        XCTAssertThrowsError(try parse("--- \"name\" trailing garbage\n+++ name\n@@ -1,1 +1,1 @@\n-old\n+new\n"))
    }

    func testPrecancelledParseDoesNotReturnAnyReceipt() throws {
        let cancellation = OperationCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try SourceTextPatch.parse(bytes: Data(ordinary.utf8), cancellation: cancellation))
    }
}
