import XCTest
@testable import TurtleGitCore

final class MergeToolInvocationTests:XCTestCase {
    private func fixture()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeEntry-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    private var engine:SubversionMergeConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
    }
    private func inputs(_ root:URL)throws {
        for (name,text) in [("base","a\nb\nc\n"),("theirs","a\nb\nC\n"),("mine","a\nB\nc\n")] {try Data(text.utf8).write(to:root.appendingPathComponent(name))}
    }
    func testAllSourceFilesNamesAndReflectedNamesRemainSeparate()throws {
        let arguments=["/base:base","/theirs:theirs","/mine:mine","/merged:out","/basename:BASE : label","/theirsname:THEIRS","/minename:MINE","/mergedname:RESULT","/basereflectedname:source/base","/theirsreflectedname:remote/theirs","/minereflectedname:local/mine","/mergedreflectedname:display/result","/line:12","/saverequired","/saverequiredonconflicts","/deletebasetheirsmineonclose"]
        let value=try XCTUnwrap(MergeToolInvocation.parse(arguments:arguments,currentDirectory:"/fixture"))
        XCTAssertEqual(value.base?.path,"/fixture/base");XCTAssertEqual(value.theirs?.path,"/fixture/theirs");XCTAssertEqual(value.mine?.path,"/fixture/mine");XCTAssertEqual(value.merged?.path,"/fixture/out")
        XCTAssertEqual(value.baseName,"BASE : label");XCTAssertEqual(value.theirsName,"THEIRS");XCTAssertEqual(value.mineName,"MINE");XCTAssertEqual(value.mergedName,"RESULT")
        XCTAssertEqual(value.baseReflectedName,"source/base");XCTAssertEqual(value.theirsReflectedName,"remote/theirs");XCTAssertEqual(value.mineReflectedName,"local/mine");XCTAssertEqual(value.mergedReflectedName,"display/result")
        XCTAssertEqual(value.line,12);XCTAssertTrue(value.saveRequired);XCTAssertTrue(value.saveRequiredOnConflicts);XCTAssertTrue(value.deleteInputsOnClose)
        XCTAssertFalse(value.readOnly);XCTAssertFalse(value.blame);XCTAssertFalse(value.help)
    }
    func testNativeAliasesCaseFlagsAndPatchDefaults()throws {
        let value=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","--BASE=base","--mine","/absolute/mine","--base-name","a b","--mine-reflected-name=visible","--blame","--one-way","--diff=patch.diff","--working-copy","--reversed-patch","--patch-original=: OLD","--patch-patched",": NEW"],currentDirectory:"/fixture"))
        XCTAssertEqual(value.base?.path,"/fixture/base");XCTAssertEqual(value.mine?.path,"/absolute/mine");XCTAssertEqual(value.baseName,"a b");XCTAssertEqual(value.mineReflectedName,"visible")
        XCTAssertTrue(value.readOnly);XCTAssertTrue(value.blame);XCTAssertFalse(value.oneWay);XCTAssertTrue(value.workingCopy);XCTAssertTrue(value.reversedPatch)
        XCTAssertEqual(value.diff?.path,"/fixture/patch.diff");XCTAssertEqual(value.patchPath?.path,"/fixture");XCTAssertEqual(value.patchOriginal,": OLD");XCTAssertEqual(value.patchPatched,": NEW")
        let explicit=try XCTUnwrap(MergeToolInvocation.parse(arguments:["/diff:file.patch","/wc","/patchpath:target","/readonly","/oneway"],currentDirectory:"/fixture"))
        XCTAssertEqual(explicit.patchPath?.path,"/fixture/target");XCTAssertTrue(explicit.readOnly);XCTAssertFalse(explicit.oneWay)
        let oneWay=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","--oneway"],currentDirectory:"/fixture"));XCTAssertTrue(oneWay.oneWay)
    }
    func testSourceTheirsTransferRetiresPaneButDoesNotTransferReflectedName()throws {
        let value=try XCTUnwrap(MergeToolInvocation.parse(arguments:["/base:b","/theirs:t","/theirsname:description","/theirsreflectedname:theirs display","/minereflectedname:mine display"],currentDirectory:"/fixture"))
        XCTAssertEqual(value.mine?.path,"/fixture/t");XCTAssertEqual(value.mineName,"description");XCTAssertNil(value.theirs);XCTAssertNil(value.theirsName)
        XCTAssertEqual(value.mineReflectedName,"mine display");XCTAssertEqual(value.theirsReflectedName,"theirs display")
    }
    func testRepositoryCommandsAndDocumentLaunchAreNotIntercepted()throws {
        for arguments in [["/command:diff","/path:repository"],["--command","commit","--merge-tool","--base=ignored"],["--command=log"],[],["/some/file"],["-psn_1_2"]] {
            XCTAssertNil(try MergeToolInvocation.parse(arguments:arguments,currentDirectory:"/fixture"))
        }
        XCTAssertTrue(try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool"],currentDirectory:"/fixture")).base==nil)
    }
    func testUnifiedOutputAndLiteralByteSpellingsAndMarkedPositionals()throws {
        let a="café*\n.txt",b="cafe\u{301}.txt"
        let value=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","--create-unified-diff","--original-file",a,"--modified-file",b,"--output-file=diff.patch"],currentDirectory:"/fixture"))
        XCTAssertTrue(value.createUnifiedDiff,"Unified-diff flag was not parsed")
        XCTAssertTrue(value.originalFile!.lastPathComponent.utf8.elementsEqual(a.utf8),"Original NFC filename bytes changed")
        XCTAssertTrue(value.modifiedFile!.lastPathComponent.utf8.elementsEqual(b.utf8),"Modified NFD filename bytes changed")
        XCTAssertEqual(value.outputFile?.path,"/fixture/diff.patch")
        let home=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","--mine","~/"+a],currentDirectory:"/fixture"))
        XCTAssertTrue(home.mine!.path.utf8.elementsEqual((UserAccountPaths.homeDirectory.path+"/"+a).utf8),"Tilde expansion changed the original filename tail")
        let pair=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","--","/base","/mine","/theirs"],currentDirectory:"/fixture"))
        XCTAssertEqual(pair.base?.path,"/base");XCTAssertEqual(pair.mine?.path,"/mine");XCTAssertEqual(pair.theirs?.path,"/theirs")
        let single=try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool","one"],currentDirectory:"/fixture"));XCTAssertEqual(single.mine?.path,"/fixture/one")
    }
    func testBareAccountTildeAndNamedUserLocationsRemainDistinctFromWorkingDirectory()throws {
        let account = UserAccountPaths.homeDirectory.path
        let invocation = try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool", "--base=~", "--mine=~/input", "--merged=~/output", "--diff=~/patch.diff", "--patch-path=~/target"], currentDirectory:"/private/tmp/unrelated"))
        XCTAssertEqual(invocation.base?.path,account)
        XCTAssertEqual(invocation.mine?.path,account+"/input")
        XCTAssertEqual(invocation.merged?.path,account+"/output")
        XCTAssertEqual(invocation.diff?.path,account+"/patch.diff")
        XCTAssertEqual(invocation.patchPath?.path,account+"/target")
        let user = NSUserName()
        let namedHome = try XCTUnwrap(NSHomeDirectoryForUser(user))
        let named = try XCTUnwrap(MergeToolInvocation.parse(arguments:["--merge-tool", "--mine=~"+user+"/named-input"], currentDirectory:"/fixture"))
        XCTAssertEqual(named.mine?.path,namedHome+"/named-input")
    }
    func testMalformedUnsupportedAndWindowsProtocolsAreExplicitFailures()throws {
        for arguments in [["--merge-tool","--unknown"],["--merge-tool=value"],["--base"],["/base"],["--base="],["--base=a","--base=b"],["--merge-tool","--merge-tool"],["--readonly=false"],["/mine:bad\0path"],["/line:0"],["/line:-1"],["/line:999999999999999999999999999999999"],["--base","--readonly"],["--merge-tool","a","b","c","d"],["--merge-tool","/base:a","positional"],["--merge-tool","/resolvemsghwnd:123"],["--merge-tool","/resolvemsgwparam:1"],["--merge-tool","/resolvemsglparam:2"]] {
            XCTAssertThrowsError(try MergeToolInvocation.parse(arguments:arguments,currentDirectory:"/fixture"),"Unexpected acceptance: \(arguments)")
        }
        XCTAssertThrowsError(try MergeToolInvocation.parse(arguments:["--merge-tool"],currentDirectory:"relative"))
        let help=try XCTUnwrap(MergeToolInvocation.parse(arguments:["/?"],currentDirectory:"/fixture"));XCTAssertTrue(help.help)
    }
    func testAbsentOutputFirstSaveAndExistingPermissionBackupAndExactBytes()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let output=root.appendingPathComponent("result"),initial=try MergeToolOutputTarget(capturing:output,absentPermissions:0o750)
        XCTAssertTrue(initial.content.isDeleted);XCTAssertEqual(initial.content.permissions,0o750)
        let raw=Data([0xff,0x00,0x80,0x0a]),saved=try initial.save(bytes:raw)
        XCTAssertEqual(try Data(contentsOf:output),raw);XCTAssertEqual(saved.content.bytes,raw);XCTAssertFalse(saved.content.isDeleted)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:output.path)[.posixPermissions] as? NSNumber)?.intValue,0o750)
        let next=try saved.save(text:"text\n",encoding:.utf16LEBOM,options:.init(backupOriginal:true))
        XCTAssertEqual(try Data(contentsOf:output.appendingPathExtension("bak")),raw);XCTAssertEqual(try Data(contentsOf:output),try ComparisonTextEncoding.utf16LEBOM.encode("text\n"))
        let deleted=try next.save(bytes:Data(),options:.init(emptyResult:.delete));XCTAssertTrue(deleted.content.isDeleted)
        _ = try deleted.save(bytes:raw);XCTAssertEqual(try Data(contentsOf:output),raw)
    }
    func testOutputFirstSaveRejectsExternalCreationReplacementModeAndSymlink()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let output=root.appendingPathComponent("result"),absent=try MergeToolOutputTarget(capturing:output)
        try Data("external\n".utf8).write(to:output)
        XCTAssertThrowsError(try absent.save(text:"wrong\n"));XCTAssertEqual(try Data(contentsOf:output),Data("external\n".utf8))
        let captured=try MergeToolOutputTarget(capturing:output)
        let replacement=root.appendingPathComponent("replacement");try Data("external\n".utf8).write(to:replacement)
        try FileManager.default.removeItem(at:output);try FileManager.default.moveItem(at:replacement,to:output)
        XCTAssertThrowsError(try captured.save(text:"wrong\n"),"Same bytes but replaced identity accepted")
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:output.path)
        let permissions=try MergeToolOutputTarget(capturing:output);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        XCTAssertThrowsError(try permissions.validate())
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:output)
        XCTAssertThrowsError(try MergeToolOutputTarget(capturing:link));XCTAssertThrowsError(try MergeToolOutputTarget(capturing:root))
    }
    func testOutputReadOnlyAndCleanDraftRetainOriginalMineLocation()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)};try inputs(root)
        let mine=try WorkingFileComparison.workingContent(at:root.appendingPathComponent("mine")),output=root.appendingPathComponent("result")
        let saved=try MergeToolOutputTarget(capturing:output).save(text:"merged\n",encoding:.utf8)
        let baseline=saved.savedPaneContent(like:mine)
        XCTAssertEqual(baseline.path,mine.path);XCTAssertEqual(baseline.revision,mine.revision);XCTAssertEqual(baseline.mode,mine.mode);XCTAssertEqual(baseline.permissions,mine.permissions);XCTAssertEqual(baseline.bytes,Data("merged\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("mine")),mine.bytes)
        let absent=try MergeToolFileInput.read(at:root.appendingPathComponent("absent mine")),absentBaseline=saved.savedPaneContent(like:absent)
        XCTAssertEqual(absentBaseline.path,absent.path);XCTAssertFalse(absentBaseline.isDeleted);XCTAssertEqual(absentBaseline.text,"merged\n")
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:output.path)
        let readOnly=try MergeToolOutputTarget(capturing:output);XCTAssertThrowsError(try readOnly.save(text:"wrong\n"))
    }
    func testThreeFileConfiguredExistingOutputIsCapturedBeforeFirstSave()async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)};try inputs(root)
        let output=root.appendingPathComponent("result");try Data("old output\n".utf8).write(to:output);try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:output.path)
        let merge=try WorkingTextMerge(base:root.appendingPathComponent("base"),theirs:root.appendingPathComponent("theirs"),mine:root.appendingPathComponent("mine"),merged:output)
        XCTAssertEqual(merge.outputURL,output)
        let document=try await merge.read(engine:engine)
        XCTAssertEqual(document.initialResult,"a\nB\nC\n");XCTAssertEqual(document.workingContents,Data("old output\n".utf8));XCTAssertEqual(document.permissions,0o750)
        try Data("external output\n".utf8).write(to:output)
        do {_ = try await merge.save(document,result:"wrong\n");XCTFail("First Save overwrote changed configured target")} catch TextConflictFailure.changedWorkingFile {}
        let reviewed=try await merge.read(engine:engine);_ = try await merge.save(reviewed,result:reviewed.initialResult,options:.init(backupOriginal:true))
        XCTAssertEqual(try Data(contentsOf:output),Data("a\nB\nC\n".utf8));XCTAssertEqual(try Data(contentsOf:output.appendingPathExtension("bak")),Data("external output\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("mine")),Data("a\nB\nc\n".utf8))
    }
    func testThreeFileAbsentOutputAndReplacementIdentityAreGuarded()async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)};try inputs(root)
        let output=root.appendingPathComponent("result"),merge=try WorkingTextMerge(base:root.appendingPathComponent("base"),theirs:root.appendingPathComponent("theirs"),mine:root.appendingPathComponent("mine"),merged:output)
        let document=try await merge.read(engine:engine);XCTAssertNil(document.workingContents)
        try Data("created externally\n".utf8).write(to:output)
        do {_ = try await merge.save(document,result:"wrong\n");XCTFail("External creation overwritten")} catch TextConflictFailure.changedWorkingFile {}
        let reviewed=try await merge.read(engine:engine),replacement=root.appendingPathComponent("replacement")
        try Data("created externally\n".utf8).write(to:replacement);try FileManager.default.removeItem(at:output);try FileManager.default.moveItem(at:replacement,to:output)
        do {_ = try await merge.save(reviewed,result:"wrong\n");XCTFail("Replacement with equal bytes overwritten")} catch TextConflictFailure.changedWorkingFile {}
        try FileManager.default.removeItem(at:output)
        let absentAgain=try await merge.read(engine:engine);_ = try await merge.save(absentAgain,result:absentAgain.initialResult)
        XCTAssertEqual(try Data(contentsOf:output),Data("a\nB\nC\n".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
    }
    func testMissingFileInputIsOptInAndAbsentMineSaveRejectsAppearance()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)};try inputs(root)
        let absent=root.appendingPathComponent("absent"),comparison=try WorkingFileComparison(base:root.appendingPathComponent("base"),destination:absent)
        XCTAssertThrowsError(try comparison.read())
        let document=try comparison.readForMergeTool()
        XCTAssertTrue(document.destination.isDeleted);XCTAssertEqual(document.destination.text,"");XCTAssertEqual(document.destination.permissions,0o644)
        let input=try MergeToolFileInput.read(at:absent);XCTAssertTrue(input.isDeleted);XCTAssertEqual(input.bytes,Data())
        try Data("external creation\n".utf8).write(to:absent)
        XCTAssertThrowsError(try comparison.save(document,base:false,text:"wrong\n"));XCTAssertEqual(try Data(contentsOf:absent),Data("external creation\n".utf8))
        try FileManager.default.removeItem(at:absent)
        let reviewed=try comparison.readForMergeTool();_ = try comparison.save(reviewed,base:false,text:"created explicitly\n")
        XCTAssertEqual(try Data(contentsOf:absent),Data("created explicitly\n".utf8))
    }
    func testThreeFileMissingInputIsEmptyAndLateAppearanceCannotBeSaved()async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)};try inputs(root)
        let base=root.appendingPathComponent("base"),theirs=root.appendingPathComponent("theirs"),mine=root.appendingPathComponent("mine"),output=root.appendingPathComponent("result")
        try FileManager.default.removeItem(at:theirs)
        let strict=try WorkingTextMerge(base:base,theirs:theirs,mine:mine)
        do {_ = try await strict.read(engine:engine);XCTFail("Normal Merge Open accepted missing input")} catch {}
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output,allowMissingInputs:true)
        let document=try await merge.read(engine:engine)
        XCTAssertEqual(document.theirs,"");XCTAssertNil(document.workingContents)
        try Data("late theirs\n".utf8).write(to:theirs)
        do {_ = try await merge.save(document,result:"wrong\n");XCTFail("Missing-input appearance accepted")} catch TextConflictFailure.changedWorkingFile {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        try FileManager.default.removeItem(at:theirs)
        let reviewed=try await merge.read(engine:engine);_ = try await merge.save(reviewed,result:"chosen result\n")
        XCTAssertEqual(try Data(contentsOf:output),Data("chosen result\n".utf8));XCTAssertEqual(try Data(contentsOf:mine),Data("a\nB\nc\n".utf8))
    }

}
