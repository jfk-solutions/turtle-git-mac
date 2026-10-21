// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class MergeInputEncodingTests:XCTestCase {
    private var engine:SubversionMergeConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
    }
    private func directory()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("InputEncoding-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    private func legacy(_ suffix:String)->Data {Data([0xe9])+Data(suffix.utf8)}

    func testExplicitDecoderRetainsBytesAndNormalizesMatchingBOMWithoutOutputConversion() throws {
        let raw=legacy("\r\n"),content=ComparisonFileContent(path:"literal 雪\n[*]",revision:.revision(String(repeating:"a",count:40)),bytes:raw,mode:"100755",permissions:0o444)
        let latin=try content.reinterpreting(encoding:.windows1252),cyrillic=try content.reinterpreting(encoding:.windows1251)
        XCTAssertEqual(latin.text,"é\r\n");XCTAssertEqual(cyrillic.text,"й\r\n")
        XCTAssertEqual(latin.bytes,raw);XCTAssertEqual(cyrillic.bytes,raw);XCTAssertEqual(cyrillic.path,content.path)
        XCTAssertEqual(cyrillic.mode,"100755");XCTAssertEqual(cyrillic.permissions,0o444)
        XCTAssertThrowsError(try content.reinterpreting(encoding:.utf8));XCTAssertNil(content.text)
        let loadChoices:[(ComparisonTextEncoding,ComparisonTextEncoding)]=[(.utf8BOM,.utf8),(.utf16LEBOM,.utf16LE),(.utf16BEBOM,.utf16BE),(.utf32LE,.utf32LE),(.utf32BE,.utf32BE)]
        for (selected,normalized) in loadChoices {
            let bytes=try selected.encode("A雪\r\n"),source=ComparisonFileContent(path:"file",revision:.workingTree,bytes:bytes,mode:"100644")
            let reloaded=try source.reinterpreting(encoding:selected)
            XCTAssertEqual(reloaded.encoding,normalized);XCTAssertEqual(reloaded.text,"A雪\r\n");XCTAssertEqual(reloaded.bytes,bytes)
            XCTAssertEqual(try source.reinterpreting(encoding:normalized).text,"A雪\r\n")
        }
        let binary=ComparisonFileContent(path:"binary",revision:.workingTree,bytes:Data([0,0]),mode:"100644")
        XCTAssertThrowsError(try binary.reinterpreting(encoding:.windows1252))
    }

    func testReadOnlyTwoPaneInputRedecodeChangesActualAlignmentWithoutWriting() throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),bytes=legacy("\n")
        try bytes.write(to:base);try Data("й\n".utf8).write(to:mine)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:base.path)
        let comparison=try WorkingFileComparison(base:base,destination:mine),document=try comparison.read().usingMergeEncoding(preferUTF8:false)
        let initial=try document.reinterpreting(destination:.utf8)
        XCTAssertFalse(FileComparisonAlignment(base:initial.base.text!,destination:initial.destination.text!).differences.isEmpty)
        let accepted=try initial.reinterpreting(base:.windows1251)
        XCTAssertTrue(FileComparisonAlignment(base:accepted.base.text!,destination:accepted.destination.text!).differences.isEmpty)
        XCTAssertEqual(accepted.base.bytes,bytes);XCTAssertEqual(accepted.destination.bytes,Data("й\n".utf8))
        XCTAssertEqual(try Data(contentsOf:base),bytes);XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:base.path)[.posixPermissions] as? NSNumber)?.intValue,0o444)
        XCTAssertThrowsError(try accepted.reinterpreting(base:.utf8));XCTAssertEqual(accepted.base.text,"й\n")
        XCTAssertEqual(try accepted.reinterpreting(base:.windows1252).base.text,"é\n","Switching back must decode original bytes")
    }

    func testGitConflictRolesRetainRealStageBytesAndIndexSafetyAcrossDecodeReload() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false)),path="conflict 雪\n[*]"
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Encoding"),("user.email","encoding@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try legacy(" base\n").write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["checkout","-b","side"]);try legacy(" theirs\n").write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"theirs")
        _ = try await repo.run(["checkout","main"]);try legacy(" mine\n").write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"mine")
        do{_ = try await repo.run(["merge","--no-edit","side"]);XCTFail("Expected conflict")}catch is GitFailure{}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:root.appendingPathComponent(path)),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let original=try await repo.textConflictDocument(path:path,mergePreferUTF8:false)
        let document=try await repo.textConflictDocument(path:path,mergePreferUTF8:false,inputEncodings:.init(mine:.windows1251))
        XCTAssertEqual(original.mine,"é mine\n");XCTAssertEqual(document.mine,"й mine\n");XCTAssertEqual(document.base,"é base\n");XCTAssertEqual(document.theirs,"é theirs\n")
        XCTAssertEqual(document.rawInputs?.mine,legacy(" mine\n"));XCTAssertEqual(document.rawInputs?.base,legacy(" base\n"));XCTAssertEqual(document.rawInputs?.theirs,legacy(" theirs\n"))
        XCTAssertEqual(document.encoding,original.encoding);XCTAssertTrue(document.generatedResult.contains("й mine\n"));XCTAssertFalse(document.generatedResult.contains("Ð"))
        do{_ = try await repo.textConflictDocument(path:path,mergePreferUTF8:false,inputEncodings:.init(mine:.utf8));XCTFail("Invalid UTF-8 accepted")}catch{}
        let token=OperationCancellation();token.cancel()
        do{_ = try await repo.textConflictDocument(path:path,inputEncodings:.init(mine:.windows1251),cancellation:token);XCTFail("Cancelled reload accepted")}catch is OperationCancellationFailure{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),working)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
        // Reinterpreting doesn't authorize a later save against replaced stages.
        _ = try await repo.run(["add","--",path])
        do{_ = try await repo.saveTextConflict(document,result:"accepted text\n",markResolved:false);XCTFail("Old conflict receipt accepted")}catch{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),working)
        // A real replay reverses Git's stage roles. Override the logical Mine
        // pane, not a hard-coded stage 2 from the ordinary merge above.
        _ = try await repo.run(["merge","--abort"])
        do{_ = try await repo.run(["rebase","side"]);XCTFail("Expected actual replay conflict")}catch is GitFailure{}
        let replayIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),replayWorking=try Data(contentsOf:root.appendingPathComponent(path))
        let stage3=try await repo.run(["show",":3:"+path]).stdout,stage2=try await repo.run(["show",":2:"+path]).stdout
        let replay=try await repo.textConflictDocument(path:path,mergePreferUTF8:false,inputEncodings:.init(mine:.windows1251))
        XCTAssertEqual(replay.mineStage,3);XCTAssertEqual(replay.theirsStage,2)
        XCTAssertEqual(replay.rawInputs?.mine,stage3);XCTAssertEqual(replay.rawInputs?.theirs,stage2)
        XCTAssertEqual(stage3,legacy(" mine\n"));XCTAssertEqual(stage2,legacy(" theirs\n"))
        XCTAssertEqual(replay.mine,"й mine\n");XCTAssertEqual(replay.theirs,"é theirs\n")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),replayIndex)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),replayWorking)
    }

    func testExternalPerRoleReloadAndRetainedRawRemergeKeepOutputReceiptAndEncoding() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs"),output=root.appendingPathComponent("output")
        for (url,bytes) in [(base,legacy(" base\n")),(mine,legacy(" mine\n")),(theirs,Data("й theirs\n".utf8)),(output,Data("accepted output\n".utf8))] {try bytes.write(to:url)}
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:base.path)
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output)
        let original=try await merge.read(engine:engine,mergePreferUTF8:false,inputEncodings:.init(theirs:.utf8))
        let accepted=try original.reinterpretingInputs(.init(mine:.windows1251,theirs:.utf8),engine:engine)
        XCTAssertEqual(accepted.mine,"й mine\n");XCTAssertEqual(accepted.theirs,"й theirs\n");XCTAssertEqual(accepted.base,"é base\n")
        XCTAssertEqual(accepted.rawInputs?.mine,legacy(" mine\n"));XCTAssertEqual(accepted.workingContents,Data("accepted output\n".utf8));XCTAssertEqual(accepted.encoding,original.encoding)
        XCTAssertTrue(accepted.initialResult.contains("й mine\n"));XCTAssertEqual(accepted.initialResult,accepted.generatedResult)
        XCTAssertEqual(accepted.externalSources.map(\.expectedBytes),original.externalSources.map(\.expectedBytes))
        XCTAssertThrowsError(try accepted.reinterpretingInputs(.init(mine:.utf8),engine:engine));XCTAssertEqual(accepted.mine,"й mine\n")
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try accepted.reinterpretingInputs(.init(mine:.windows1252),engine:engine,cancellation:token))
        let actual=try await merge.read(engine:engine,mergePreferUTF8:false,inputEncodings:.init(mine:.windows1251,theirs:.utf8))
        XCTAssertEqual(actual.mine,accepted.mine);XCTAssertEqual(actual.initialResult,accepted.initialResult)
        try Data("outside edit\n".utf8).write(to:mine)
        do{_ = try await merge.save(accepted,result:"do not overwrite\n");XCTFail("Redecode bypassed original input snapshot")}catch TextConflictFailure.changedWorkingFile{}
        XCTAssertEqual(try Data(contentsOf:output),Data("accepted output\n".utf8));XCTAssertEqual(try Data(contentsOf:base),legacy(" base\n"))
    }

    func testSavedSourceReplacementUpdatesRawRoleAndResultSavesRetainOriginalInputs() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs"),output=root.appendingPathComponent("output"),replacement=root.appendingPathComponent("saved source")
        for (url,text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n"),(output,"old result\n")] {try Data(text.utf8).write(to:url)}
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output),document=try await merge.read(engine:engine)
        try legacy(" replacement\n").write(to:replacement)
        let replacementContent=try WorkingFileComparison.workingContent(at:replacement)
        let replaced=try document.replacingSources(mine:replacementContent,theirs:nil,engine:engine)
        XCTAssertEqual(replaced.rawInputs?.mine,legacy(" replacement\n"))
        let reviewed=try replaced.reinterpretingInputs(.init(mine:.windows1251),engine:engine)
        XCTAssertEqual(reviewed.mine,"й replacement\n");XCTAssertTrue(reviewed.generatedResult.contains("й replacement\n"))
        let saved=try await merge.save(document,result:"saved result\n",encoding:.utf16LEBOM)
        XCTAssertEqual(saved.rawInputs?.mine,Data("mine\n".utf8));XCTAssertEqual(saved.rawInputs?.base,Data("base\n".utf8));XCTAssertEqual(saved.encoding,.utf16LEBOM)
        XCTAssertEqual(try Data(contentsOf:output),try ComparisonTextEncoding.utf16LEBOM.encode("saved result\n"))
    }

    func testPatchRecoveryUsesOriginalRoleBytesAndKeepsItsSaveGuards() async throws {
        let base=legacy(" base\nkeep\n"),patched=legacy(" patched\nkeep\n"),current=legacy(" local\nkeep\n")
        let (root,repo,review)=try await WorkingPatchEncodingTests().fixture(base:base,patched:patched,current:current)
        defer{try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id,textEncodingPolicy:.init(preferUTF8:false))
        let document=try comparison.patchMergeDocument(engine:engine,inputEncodings:.init(mine:.windows1251))
        XCTAssertEqual(document.mine,"й local\nkeep\n");XCTAssertEqual(document.base,"é base\nkeep\n");XCTAssertEqual(document.theirs,"é patched\nkeep\n")
        XCTAssertEqual(document.rawInputs?.base,base);XCTAssertEqual(document.rawInputs?.mine,current);XCTAssertEqual(document.rawInputs?.theirs,patched)
        XCTAssertEqual(document.encoding,.windows1252);XCTAssertTrue(document.generatedResult.contains("й local\n"))
        let again=try document.reinterpretingInputs(.init(mine:.windows1252),engine:engine)
        XCTAssertEqual(again.mine,"é local\nkeep\n");XCTAssertEqual(again.rawInputs?.mine,current)
        try Data("outside edit\n".utf8).write(to:root.appendingPathComponent("file.txt"))
        do{_ = try await repo.saveWorkingTreePatchFile(comparison,text:document.generatedResult,encoding:.utf8);XCTFail("Reinterpreted patch bypassed stale working snapshot")}catch{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),Data("outside edit\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
}
