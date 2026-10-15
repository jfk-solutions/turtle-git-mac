import XCTest
@testable import TurtleGitCore

final class GitPatchTests: XCTestCase {
    func testLegacyLineStageAndUnstageKeepRawContextEndingsAndOtherIndexEntries() async throws {
        let (root,repo,path)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.quotepath","false"])
        let context=Data([99,97,102,0xe9,13,10]),first=Data([0x80,32,110,101,119,13,10]),second=Data([0xf1,32,109,111,114,101,13,10]),tail=Data("last".utf8)
        let base=context+tail,working=context+first+second+tail
        try base.write(to:root.appendingPathComponent(path));try Data("unrelated base".utf8).write(to:root.appendingPathComponent("other"));try await repo.stage([path,"other"]);_ = try await repo.commit(message:"legacy base")
        try working.write(to:root.appendingPathComponent(path));try Data([0xff,10]).write(to:root.appendingPathComponent("other"));try await repo.stage(["other"])
        let other=try await repo.run(["show",":other"]).stdout,head=try await repo.run(["rev-parse","HEAD"]).stdout
        let patch=try await repo.patch(paths:[path],staged:false)
        let rawPatch=try await repo.patchData(paths:[path],staged:false);XCTAssertEqual(patch.bytes,rawPatch);XCTAssertTrue(patch.text.contains("café"));XCTAssertTrue(patch.text.contains("€ new"));XCTAssertTrue(patch.files[0].header.joined().contains("雪"))
        let line=try XCTUnwrap(patch.lines.firstIndex {$0.hasPrefix("+€ new")})
        let selected=try patch.selectedPatchData(lines:[line],entireHunks:false,reverse:false)
        XCTAssertTrue(selected.contains(0x80));XCTAssertTrue(selected.contains(0xe9));XCTAssertNotEqual(selected,Data(try patch.selectedPatch(lines:[line],entireHunks:false,reverse:false).utf8))
        try await repo.applyPatchSelection(patch,paths:[path],staged:false,lines:[line],entireHunks:false)
        let stagedBytes=try await repo.run(["show",":"+path]).stdout;XCTAssertEqual(stagedBytes,context+first+tail)
        let staged=try await repo.patch(paths:[path],staged:true),remove=try XCTUnwrap(staged.lines.firstIndex {$0.hasPrefix("+€ new")})
        try await repo.applyPatchSelection(staged,paths:[path],staged:true,lines:[remove],entireHunks:false)
        let restored=try await repo.run(["show",":"+path]).stdout,finalOther=try await repo.run(["show",":other"]).stdout,finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(restored,base);XCTAssertEqual(finalOther,other);XCTAssertEqual(finalHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),working)
    }
    func testLegacyAdditionAndDeletionSelectionsPreserveExecutableModeAndBytes() async throws {
        let (root,repo,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let path="legacy-added.txt",file=root.appendingPathComponent(path),raw=Data([0xe9,10,0x80,10])
        try raw.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        let addition=try await repo.patch(paths:[path],staged:false,includeUntracked:true)
        try await repo.applyPatchSelection(addition,paths:[path],staged:false,lines:[addition.files[0].hunks[0].header],entireHunks:true)
        let staged=try await repo.patch(paths:[path],staged:true),selected=try XCTUnwrap(staged.lines.firstIndex {$0.hasPrefix("+é")})
        try await repo.applyPatchSelection(staged,paths:[path],staged:true,lines:[selected],entireHunks:false)
        let remainder=try await repo.run(["show",":"+path]).stdout;XCTAssertEqual(remainder,Data([0x80,10]));XCTAssertEqual(try Data(contentsOf:file),raw)
        try await repo.stage([path]);try FileManager.default.removeItem(at:file)
        let deletion=try await repo.patch(paths:[path],staged:false),removed=try XCTUnwrap(deletion.lines.firstIndex {$0.hasPrefix("-é")})
        try await repo.applyPatchSelection(deletion,paths:[path],staged:false,lines:[removed],entireHunks:false)
        let remaining=try await repo.run(["show",":"+path]).stdout,mode=try await repo.run(["ls-files","--stage","--",path]).text
        XCTAssertEqual(remaining,Data([0x80,10]));XCTAssertTrue(mode.hasPrefix("100755 "));XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testByteCarrierPreservesUndefinedLegacyBytesAndOriginalHunkSuffix() throws {
        let payload=Data([0x81,0x8d,0x8f,0x90,0x9d,0xe9])
        let raw=Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,1 @@ ".utf8)+Data([0xe9,0x85,10,43])+payload+Data([10])
        let patch=GitPatch(bytes:raw)
        XCTAssertEqual(patch.bytes,raw);XCTAssertEqual(try patch.selectedPatchData(lines:[patch.files[0].hunks[0].header],entireHunks:true,reverse:false),raw)
    }
    func fixture() async throws -> (URL, GitRepository, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root), path = "file 雪\n.txt"
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Patch Tests"])
        _ = try await repo.run(["config", "user.email", "patch@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data((1...30).map { "line \($0)\n" }.joined().utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "base")
        return (root, repo, path)
    }
    func change(_ root: URL, _ path: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).replacingOccurrences(of: "line 2\n", with: "first change\nextra first\n").replacingOccurrences(of: "line 26\n", with: "second change\n")
        try Data(text.utf8).write(to: root.appendingPathComponent(path)); return text
    }
    func testStageSecondHunkWithoutFirstAndUnstageIt() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = try change(root, path), document = try await repo.patch(paths: [path], staged: false)
        XCTAssertEqual(document.files[0].hunks.count, 2)
        let hunk = document.files[0].hunks[1]
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [hunk.header], entireHunks: true)
        var index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("second change")); XCTAssertFalse(index.contains("first change"))
        let staged = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(staged, paths: [path], staged: true, lines: [staged.files[0].hunks[0].header], entireHunks: true)
        index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 26")); XCTAssertFalse(index.contains("second change"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), working)
    }
    func testStageOneAddedLineAndUnstageOneLineFromPartiallyStagedFile() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try change(root, path)
        var document = try await repo.patch(paths: [path], staged: false)
        let line = try XCTUnwrap(document.lines.firstIndex(of: "+extra first"))
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [line], entireHunks: false)
        let index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 2\nextra first\n")); XCTAssertFalse(index.contains("first change")); XCTAssertFalse(index.contains("second change"))
        document = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [try XCTUnwrap(document.lines.firstIndex(of: "+extra first"))], entireHunks: false)
        let after = try await repo.diff(staged: true); XCTAssertTrue(after.isEmpty)
    }
    func testStageBothHunksAdjustsOffsetsAndRejectsStalePatch() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = try change(root, path), document = try await repo.patch(paths: [path], staged: false)
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: Set(document.files[0].hunks.map(\.header)), entireHunks: true)
        let index = try await repo.run(["show", ":" + path]).text; XCTAssertEqual(index, working)
        do { try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [document.files[0].hunks[0].header], entireHunks: true); XCTFail("Stale patch must fail") } catch PatchFailure.changed {}
    }
    func testNoNewlineMarkerSurvivesAndUnsupportedMetadataFails() throws {
        let document = GitPatch(text: "diff --git a/a b/a\nindex aaa..bbb 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n")
        let result = try document.selectedPatch(lines: [4], entireHunks: true, reverse: false)
        XCTAssertEqual(result.components(separatedBy: "\\ No newline").count, 3)
        let newFile = GitPatch(text: "diff --git a/a b/a\nnew file mode 100644\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n")
        XCTAssertTrue(try newFile.selectedPatch(lines: [4], entireHunks: true, reverse: false).contains("new file mode 100644"))
    }
    func testReverseSecondHunkWithEarlierIndexInsertionAndRestoreOneRemovedLine() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try change(root, path); try await repo.stage([path])
        var document = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [document.files[0].hunks[1].header], entireHunks: true)
        var index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("first change")); XCTAssertTrue(index.contains("line 26")); XCTAssertFalse(index.contains("second change"))
        document = try await repo.patch(paths: [path], staged: true)
        let removed = try XCTUnwrap(document.lines.firstIndex(of: "-line 2"))
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [removed], entireHunks: false)
        index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 2")); XCTAssertTrue(index.contains("first change")); XCTAssertTrue(index.contains("extra first"))
    }

}
