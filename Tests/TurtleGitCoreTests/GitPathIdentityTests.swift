// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GitPathIdentityTests: XCTestCase {
    private let composed = "café\n.txt", decomposed = "cafe\u{301}\n.txt"
    private func bytes(_ value:String)->Data { Data(value.utf8) }
    func testStatusPairingAndHashingKeepDistinctGitSpellings() throws {
        XCTAssertEqual(composed,decomposed); XCTAssertNotEqual(bytes(composed),bytes(decomposed))
        let rows = StatusEntry.parse(bytes("D  \(composed)\0?? \(decomposed)\0?? \(composed)\0"))
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(bytes(rows[0].path),bytes(composed)); XCTAssertTrue(rows[0].hasUnversionedCopy)
        XCTAssertEqual(bytes(rows[1].path),bytes(decomposed)); XCTAssertFalse(rows[1].hasUnversionedCopy)
        let modified = StatusEntry.parse(bytes(" M \(composed)\0 M \(decomposed)\0"))
        XCTAssertEqual(Set(modified).count,2); XCTAssertNotEqual(modified[0],modified[1])
        let renamed = StatusEntry.parse(bytes("R  \(composed)\0old é\0R  \(decomposed)\0old e\u{301}\0"))
        XCTAssertEqual(renamed.count,2); XCTAssertNotEqual(bytes(renamed[0].originalPath!),bytes(renamed[1].originalPath!))
    }
    func testStatisticsRenamesAndGitlinksAttachByExactDestination() throws {
        let files = CommitFile.parse(names:bytes("M\0\(composed)\0M\0\(decomposed)\0"),statistics:bytes("1\t2\t\(composed)\0" + "7\t8\t\(decomposed)\0"),raw:bytes(":100644 160000 a b M\0\(composed)\0"))
        XCTAssertEqual(files.count,2); XCTAssertEqual(files[0].added,1); XCTAssertEqual(files[1].added,7)
        XCTAssertTrue(files[0].isSubmodule); XCTAssertFalse(files[1].isSubmodule)
        let names = bytes("R100\0old\0\(composed)\0R100\0older\0\(decomposed)\0")
        let stats = bytes("3\t4\t\0old\0\(composed)\0" + "9\t10\t\0older\0\(decomposed)\0")
        let renamed = CommitFile.parse(names:names,statistics:stats)
        XCTAssertEqual(renamed.map(\.added),[3,9]); XCTAssertEqual(renamed.map(\.removed),[4,10])
        let a = CommitFile(path:composed,oldPath:nil,action:"M",added:1,removed:2,hasStatistics:true,isSubmodule:false)
        let b = CommitFile(path:decomposed,oldPath:nil,action:"M",added:1,removed:2,hasStatistics:true,isSubmodule:false)
        XCTAssertNotEqual(a,b); XCTAssertEqual(Set([a,b]).count,2)
    }
    func testMetadataMapLookupFilterMergeAndCodingKeepBothSpellings() throws {
        var map = GitPathMap<Int>(uniqueKeysWithValues:[(composed,1),(decomposed,2)])
        XCTAssertEqual(map.count,2); XCTAssertEqual(map[composed],1); XCTAssertEqual(map[decomposed],2)
        XCTAssertEqual(map.filter { $0.value == 2 }[decomposed],2)
        map.merge(GitPathMap(uniqueKeysWithValues:[(composed,4)]),uniquingKeysWith:+)
        XCTAssertEqual(map[composed],5); XCTAssertEqual(map.mapValues { String($0) }[decomposed],"2")
        let encoded = try JSONEncoder().encode(map), restored = try JSONDecoder().decode(GitPathMap<Int>.self,from:encoded)
        XCTAssertEqual(restored,map); XCTAssertEqual(restored.count,2)
        let duplicate = try JSONSerialization.data(withJSONObject:[["path":composed,"value":1],["path":composed,"value":2]])
        XCTAssertThrowsError(try JSONDecoder().decode(GitPathMap<Int>.self,from:duplicate))
        XCTAssertEqual(map.removeValue(forKey:decomposed),2); XCTAssertEqual(map.count,1)
    }
    func testFinderFlagsWireRecordsAndLegacyCompatibility() throws {
        let a = "/repo/"+composed, b = "/repo/"+decomposed
        let flags = GitPathMap(uniqueKeysWithValues:[(a,FinderIndexFlags(skipWorktree:true)),(b,FinderIndexFlags(assumeUnchanged:true))])
        let source = FinderSnapshot(roots:["/repo"],states:[:],indexFlags:flags)
        let encoded = try JSONEncoder().encode(source)
        let result = try JSONDecoder().decode(FinderSnapshot.self,from:encoded)
        XCTAssertEqual(result.indexFlags,flags); XCTAssertEqual(result.indexFlags?.count,2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertEqual((object["indexFlagsV2"] as? [[String:Any]])?.count,2)
        XCTAssertNotNil(object["indexFlags"] as? [String:Any],"Old extensions require their original object field")
        object.removeValue(forKey:"indexFlagsV2"); object["indexFlags"] = ["/repo/old":["skipWorktree":true,"assumeUnchanged":false]]
        let legacy = try JSONDecoder().decode(FinderSnapshot.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(legacy.indexFlags?["/repo/old"],FinderIndexFlags(skipWorktree:true))
    }
    func testPathScopeDoesNotIncludeCanonicalAliases() throws {
        let rows = StatusEntry.parse(bytes(" M \(composed)\0 M \(decomposed)\0"))
        var filter = WorkingTreeFilter(); filter.wholeProject = false; filter.showAllStaged = false; filter.paths = [composed]
        let files = rows.map { WorkingTreeFile(entry:$0,assumeUnchanged:false,skipWorktree:false,modificationDate:nil) }
        XCTAssertTrue(filter.includes(files[0])); XCTAssertFalse(filter.includes(files[1]))
        filter.paths = ["café"]
        let folders = StatusEntry.parse(bytes(" M café/one\0 M cafe\u{301}/two\0"))
        XCTAssertTrue(filter.includes(WorkingTreeFile(entry:folders[0],assumeUnchanged:false,skipWorktree:false,modificationDate:nil)))
        XCTAssertFalse(filter.includes(WorkingTreeFile(entry:folders[1],assumeUnchanged:false,skipWorktree:false,modificationDate:nil)))
    }
    func testRealIndexFlagsPreserveCanonicallyEquivalentPathsAndNULInput() async throws {
        let (root,repo,_) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        let hash = try await repo.run(["hash-object","-w","--stdin"],input:bytes("payload\n")).text.trimmingCharacters(in:.newlines)
        let paths = [composed,decomposed,"--option\tline"]
        let indexInput = bytes(paths.map { "100644 \(hash)\t\($0)\0" }.joined())
        _ = try await repo.run(["update-index","-z","--index-info"],input:indexInput)
        _ = try await repo.commit(message:"exact index paths")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let stage = try await repo.run(["ls-files","--stage","-z"]).stdout
        let before = try await repo.workingTreeStatus(refreshIndex:false)
        XCTAssertEqual(before.filter { paths.map { GitReferenceName($0) }.contains(GitReferenceName($0.id)) }.count,3)
        let history = try await repo.workingTreeHistory()
        let changed = try XCTUnwrap(history).files.filter { paths.map { GitReferenceName($0) }.contains(GitReferenceName($0.path)) }
        XCTAssertEqual(changed.count,3); XCTAssertTrue(changed.allSatisfy { $0.removed == 1 })
        let amendment = try await repo.commitDialogStatus(amendToParent:true)
        XCTAssertEqual(amendment.filter { paths.map { GitReferenceName($0) }.contains(GitReferenceName($0.path)) }.count,3)
        try await repo.setIndexFlags(.skipWorktree,paths:paths)
        var flags = try await repo.finderIndexFlags()
        for path in paths { XCTAssertEqual(flags[root.path + "/" + path],FinderIndexFlags(skipWorktree:true)) }
        XCTAssertEqual(flags.count,3)
        try await repo.setIndexFlags(.clear,paths:[decomposed])
        flags = try await repo.finderIndexFlags()
        XCTAssertNil(flags[root.path + "/" + decomposed]); XCTAssertEqual(flags.count,2)
        XCTAssertEqual(flags[root.path + "/" + composed],FinderIndexFlags(skipWorktree:true))
        let finalStage = try await repo.run(["ls-files","--stage","-z"]).stdout, finalHead = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(finalStage,stage); XCTAssertEqual(finalHead,head)
    }
    func testNativeRowBridgeKeepsPathsAndGroupNamespaceLossless() {
        let group = "\0group:modified", paths = GitPathSet([composed,decomposed,group])
        let encoded = Set(paths.map(GitPathRowIdentity.encode))
        XCTAssertEqual(encoded.count,3);XCTAssertTrue(encoded.allSatisfy {$0.utf8.allSatisfy {$0 < 128}})
        XCTAssertEqual(GitPathRowIdentity.paths(encoded),paths)
        XCTAssertNil(GitPathRowIdentity.decode("foreign"));XCTAssertNil(GitPathRowIdentity.decode("git-path:@@"))
        XCTAssertEqual(GitPathRowIdentity.paths(["foreign"]).count,0)
    }
    func testExactSelectionSetAndCheckboxMarksKeepAliasesIndependent() throws {
        var selected = GitPathSet([composed,decomposed])
        XCTAssertEqual(selected.count,2); XCTAssertEqual(selected.identities.count,2)
        XCTAssertEqual(try JSONDecoder().decode(GitPathSet.self,from:JSONEncoder().encode(selected)),selected)
        selected.remove(composed); XCTAssertFalse(selected.contains(composed)); XCTAssertTrue(selected.contains(decomposed))
        selected.formUnion([composed]); XCTAssertEqual(selected.intersection([composed]).count,1)
        let rows = StatusEntry.parse(bytes(" M \(composed)\0 M \(decomposed)\0"))
        let only = StatusListSelection.checkboxEntries(entry:rows[0],entries:rows,highlighted:GitPathSet([decomposed]))
        XCTAssertEqual(only.count,1); XCTAssertEqual(bytes(only[0].path),bytes(composed))
        let both = StatusListSelection.checkboxEntries(entry:rows[0],entries:rows,highlighted:selected)
        XCTAssertEqual(both.count,2)
        let marked = StatusListSelection.mark(entries:rows,requested:selected,highlighted:selected,focusedPath:decomposed)
        XCTAssertEqual(marked.map { bytes($0.path) },bytes(decomposed))
        let clicked = StatusListSelection.mark(entries:rows,requested:GitPathSet([composed]),highlighted:GitPathSet([decomposed]),focusedPath:decomposed)
        XCTAssertEqual(clicked.map { bytes($0.path) },bytes(composed))
        let grouped = StatusListGroups.rows(entries:rows,changelists:GitChangelists(),locallyIgnored:GitPathSet([decomposed]))
        XCTAssertEqual(StatusListGroups.files(in:.localChangesIgnored,rows:grouped).map { bytes($0.path) },[bytes(decomposed)])
    }
    func testLiteralSelectedCommitAndStagingStateDoNotIncludeCanonicalNeighbor() async throws {
        let (root,repo,normal) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        let original = try Data(contentsOf:root.appendingPathComponent(normal))
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:bytes("base\n")).text.trimmingCharacters(in:.newlines)
        func packet(_ hash:String,_ path:String)->Data { bytes("100644 \(hash)\t\(path)\0") }
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet(blob,composed)+packet(blob,decomposed))
        try await repo.unstage([decomposed])
        var indexed = try await repo.trackedPaths()
        XCTAssertTrue(indexed.contains { GitReferenceName.equal($0,composed) }); XCTAssertFalse(indexed.contains { GitReferenceName.equal($0,decomposed) })
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet(blob,decomposed))
        _ = try await repo.commit(message:"paired index paths")
        let newer = try await repo.run(["hash-object","-w","--stdin"],input:bytes("staged neighbor\n")).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet(newer,composed))
        let changes = try await repo.status()
        let states = try await repo.commitStagingStates(for:changes)
        XCTAssertEqual(states.count,2); XCTAssertEqual(states[composed],.partial); XCTAssertEqual(states[decomposed],.unstaged)
        _ = try await repo.commitSelected(message:"delete only decomposed",paths:GitPathSet([decomposed]))
        let tree = try await repo.run(["ls-tree","-r","-z","HEAD"]).stdout
        XCTAssertTrue(tree.split(separator:0).contains { $0.suffix(bytes(composed).count).elementsEqual(bytes(composed)) })
        XCTAssertFalse(tree.split(separator:0).contains { $0.suffix(bytes(decomposed).count).elementsEqual(bytes(decomposed)) })
        let staged = try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertTrue(staged.split(separator:0).contains { $0.elementsEqual(bytes("100644 \(newer) 0\t\(composed)")) })
        indexed = try await repo.trackedPaths(); XCTAssertTrue(indexed.contains { GitReferenceName.equal($0,composed) })
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(normal)),original)
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do { try await repo.stage(["bad\0path"]); XCTFail("NUL selection accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

    func testAddAndRevertScopesKeepCanonicalPathsAndDirectoryBoundaries() async throws {
        let a = "café.txt",b = "cafe\u{301}.txt"
        let (root,repo,_) = try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:bytes("base\n")).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:bytes([a,b].map {"100644 \(blob)\t\($0)\0"}.joined()))
        _ = try await repo.commit(message:"paired names")
        try bytes("changed\n").write(to:root.appendingPathComponent(a))
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let add = try await repo.addDialogSelection(paths:[a,b],includeIgnored:false)
        XCTAssertEqual(add.entries.count,2);XCTAssertEqual(add.initiallyChecked.count,2)
        let scoped = try await repo.addDialogSelection(paths:[a],includeIgnored:false)
        XCTAssertEqual(scoped.entries.map {bytes($0.path)},[bytes(a)])
        let rows = StatusEntry.parse(bytes(" M café/file\0 M cafe\u{301}/file\0 M cafés/file\0"))
        let revert = RevertDialogSelection(status:rows,paths:["café"],directFiles:GitPathSet(["cafe\u{301}/file"]))
        XCTAssertEqual(revert.entries.map {bytes($0.path)},[bytes("café/file")]);XCTAssertTrue(revert.initiallyChecked.isEmpty)
        let all = RevertDialogSelection(status:rows,paths:["."],directFiles:GitPathSet(["cafe\u{301}/file"]))
        XCTAssertEqual(all.initiallyChecked.count,1);XCTAssertTrue(all.initiallyChecked.contains("cafe\u{301}/file"));XCTAssertFalse(all.initiallyChecked.contains("café/file"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testReviewedAddAndModePostActionsKeepExactIndexNeighbor() async throws {
        let a = "café\n.txt",b = "cafe\u{301}\n.txt"
        let (root,repo,_) = try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:bytes("base\n")).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:bytes([a,b].map {"100644 \(blob)\t\($0)\0"}.joined()))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        try await repo.setAddedFileMode(paths:[b],mode:.executable)
        func has(_ records:Data,_ mode:String,_ hash:String,_ path:String)->Bool {records.split(separator:0).contains {$0.elementsEqual(bytes("\(mode) \(hash) 0\t\(path)"))}}
        var staged = try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertTrue(has(staged,"100644",blob,a));XCTAssertTrue(has(staged,"100755",blob,b))
        try await repo.setAddedFileMode(paths:[a,b],mode:.symlink)
        staged = try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertTrue(has(staged,"120000",blob,a));XCTAssertTrue(has(staged,"120000",blob,b))
        try bytes("new working bytes\n").write(to:root.appendingPathComponent(b))
        let working = try Data(contentsOf:root.appendingPathComponent(b))
        _ = try await repo.addReviewedPaths([b],mode:.executable)
        staged = try await repo.run(["ls-files","--stage","-z"]).stdout
        let newBlob = try await repo.run(["hash-object","--stdin"],input:working).text.trimmingCharacters(in:.newlines)
        XCTAssertTrue(has(staged,"120000",blob,a));XCTAssertTrue(has(staged,"100755",newBlob,b))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(b)),working)
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(finalHead,head)
    }
    func testRevertAndRetryRestoreOnlyExactSelectedIndexName() async throws {
        let a = "café.txt",b = "cafe\u{301}.txt"
        let (root,repo,_) = try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:bytes("base\n")).text.trimmingCharacters(in:.newlines)
        func packet(_ hash:String,_ path:String)->Data {bytes("100644 \(hash)\t\(path)\0")}
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet(blob,a)+packet(blob,b))
        _ = try await repo.commit(message:"paired names")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let neighbor = try await repo.run(["hash-object","-w","--stdin"],input:bytes("unrelated staged neighbor\n")).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet(neighbor,a))
        let selected = try await repo.status().filter {GitReferenceName.equal($0.path,b)}
        XCTAssertEqual(selected.count,1)
        let result = try await repo.revertWorkingFiles(selected)
        XCTAssertEqual(result.revertedPaths.map(bytes),[bytes(b)]);XCTAssertTrue(result.trashedFiles.isEmpty)
        let staged = try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertTrue(staged.split(separator:0).contains {$0.elementsEqual(bytes("100644 \(neighbor) 0\t\(a)"))})
        XCTAssertTrue(staged.split(separator:0).contains {$0.elementsEqual(bytes("100644 \(blob) 0\t\(b)"))})
        let retry = try await repo.workingFileRevertSelection(selected)
        XCTAssertEqual(retry.map {bytes($0.path)},[bytes(b)])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(b)),bytes("base\n"))
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(finalHead,head)
    }

    func testCheckedOperationOrderIsOrdinalAndPreservesDistinctGitNames() {
        let a = "café",b = "cafe\u{301}"
        let result = GitPathOperationOrder.sorted(["file2","B","a","file10","A",a,b,"B"])
        XCTAssertEqual(Array(result.prefix(3)),["A","a","B"])
        XCTAssertTrue(result.firstIndex(of:"file10")! < result.firstIndex(of:"file2")!)
        XCTAssertEqual(result.count,7)
        XCTAssertEqual(GitPathOperationOrder.sorted(["a/child","a1","a.txt"]),["a.txt","a1","a/child"])
        XCTAssertEqual(result.filter {GitReferenceName.equal($0,a)}.count,1)
        XCTAssertEqual(result.filter {GitReferenceName.equal($0,b)}.count,1)
        XCTAssertEqual(GitPathOperationOrder.sorted(result.reversed()).map {Data($0.utf8)},result.map {Data($0.utf8)})
    }

}
