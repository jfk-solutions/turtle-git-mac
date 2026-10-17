import XCTest
@testable import TurtleGitCore
final class WorkingPatchEncodingTests:XCTestCase {
    var engine:SubversionMergeConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"),regexExecutable:root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"))
    }
    func fixture(base:Data,patched:Data,current:Data) async throws -> (URL,GitRepository,WorkingTreePatchReview) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch codec QA"),("user.email","codec@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt");try base.write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        try patched.write(to:file);let patch=try await repo.run(["diff","--full-index","--binary","--","file.txt"]).stdout
        try current.write(to:file)
        return (root,repo,try await repo.reviewWorkingTreePatch(patch))
    }
    func testRegionalRecordedBasePreviewAndManualSaveAreLossless() async throws {
        for (codec,words) in [(ComparisonTextEncoding.windows1251,["начало","старое","новое","местное","хвост"]),(.shiftJIS,["開始","元の行","変更した行","自分の行","最後"])] {
            let base=words[0]+"\n"+words[1]+"\nkeep\n"+words[4]+"\n",patched=words[0]+"\n"+words[2]+"\nkeep\n"+words[4]+"\n",current=words[0]+"\n"+words[3]+"\nkeep\n"+words[4]+"\n"
            let currentBytes=try codec.encode(current)
            let (root,repo,review)=try await fixture(base:codec.encode(base),patched:codec.encode(patched),current:currentBytes)
            defer {try? FileManager.default.removeItem(at:root)}
            let policy=MergeTextEncodingPolicy(preferUTF8:false,legacyEncoding:codec)
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let inspection=try await repo.inspectWorkingTreePatchFiles(review,textEncodingPolicy:policy)
            XCTAssertEqual(inspection[Data("file.txt".utf8)]?.state,.conflict)
            let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id,textEncodingPolicy:policy)
            XCTAssertEqual(comparison.recoveryKind,.text);XCTAssertEqual(comparison.textEncodingPolicy,policy)
            XCTAssertEqual(comparison.recoveryBase?.text,base);XCTAssertEqual(comparison.document.base.text,current);XCTAssertEqual(comparison.document.destination.text,patched)
            let document=try comparison.patchMergeDocument(engine:engine)
            XCTAssertEqual(document.encoding,codec);XCTAssertEqual(MergeText.conflicts(in:document.initialResult,document:document).count,1)
            let resolved=try MergeText.applying(.theirs,block:0,to:document.initialResult,document:document)
            do {_=try await repo.saveWorkingTreePatchFile(comparison,text:resolved,encoding:.windows1252);XCTFail("Lossy conversion accepted")}catch FileComparisonEditFailure.encoding {}
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),currentBytes)
            _=try await repo.saveWorkingTreePatchFile(comparison,text:resolved,autoAddNewFiles:false)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),try codec.encode(patched))
            let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
            XCTAssertEqual(afterHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("file.txt").path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        }
    }
    func testAutomaticLegacyRecoveryPreservesLocalEditAndIndex() async throws {
        let codec=ComparisonTextEncoding.shiftJIS,base="開始\n元の行\nkeep\n最後\n",patched="開始\n変更した行\nkeep\n最後\n",current="開始\n元の行\nkeep\n別の最後\n"
        let (root,repo,review)=try await fixture(base:codec.encode(base),patched:codec.encode(patched),current:codec.encode(current));defer {try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),policy=MergeTextEncodingPolicy(preferUTF8:false,legacyEncoding:codec)
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),mergeConfiguration:engine,textEncodingPolicy:policy)
        XCTAssertEqual(result.files.count,1);XCTAssertTrue(result.files[0].success,result.files[0].output)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),try codec.encode("開始\n変更した行\nkeep\n別の最後\n"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testUnrepresentableAutoMergeRemainsAvailableForManualEncodingChoice() async throws {
        let codec=ComparisonTextEncoding.windows1251,current="head\nold\nkeep\nместный хвост\n",original=try codec.encode(current)
        let (root,repo,review)=try await fixture(base:Data("head\nold\nkeep\ntail\n".utf8),patched:Data("head\n日本語\nkeep\ntail\n".utf8),current:original);defer {try? FileManager.default.removeItem(at:root)}
        let policy=MergeTextEncodingPolicy(preferUTF8:false,legacyEncoding:codec),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),mergeConfiguration:engine,textEncodingPolicy:policy)
        XCTAssertFalse(result.files[0].success);XCTAssertTrue(result.files[0].requiresMerge)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),original)
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id,textEncodingPolicy:policy),document=try comparison.patchMergeDocument(engine:engine)
        XCTAssertEqual(document.initialResult,"head\n日本語\nkeep\nместный хвост\n")
        _=try await repo.saveWorkingTreePatchFile(comparison,text:document.initialResult,encoding:.utf8,autoAddNewFiles:false)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),Data(document.initialResult.utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testLegacyPolicyDoesNotRouteBinaryBytesIntoTextRecovery() async throws {
        let current=Data([0,9,8,7,6,5])
        let (root,repo,review)=try await fixture(base:Data([0,1,2,3,4,5]),patched:Data([0,1,2,3,8,9]),current:current);defer {try? FileManager.default.removeItem(at:root)}
        let policy=MergeTextEncodingPolicy(preferUTF8:false,legacyEncoding:.windows1251)
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id,textEncodingPolicy:policy)
        XCTAssertEqual(comparison.recoveryKind,.binary);XCTAssertThrowsError(try comparison.patchMergeDocument(engine:engine))
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),mergeConfiguration:engine,textEncodingPolicy:policy)
        XCTAssertTrue(result.files[0].requiresMerge);XCTAssertFalse(result.files[0].success)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file.txt")),current)
    }
}
