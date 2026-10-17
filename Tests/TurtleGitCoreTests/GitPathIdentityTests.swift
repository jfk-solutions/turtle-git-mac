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
}
