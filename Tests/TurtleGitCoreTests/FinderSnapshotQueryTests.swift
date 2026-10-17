import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderSnapshotQueryTests:XCTestCase {
    private func url(_ path:String)->URL {FileTransferPaths.fileURL(path)}
    func testWarmedCopiesDetachOnStatesAndModernEntriesChanges() {
        let original=FinderSnapshot(roots:["/repo"],states:["/repo/folder/file":.normal])
        XCTAssertFalse(original.canResolve([url("/repo/folder")]))
        var changed=original;changed.states["/repo/folder/file"] = .conflicted
        XCTAssertTrue(changed.canResolve([url("/repo/folder")]))
        XCTAssertFalse(original.canResolve([url("/repo/folder")]))
        var modern=changed;modern.overlayEntries=[:]
        XCTAssertFalse(modern.canResolve([url("/repo/folder")]))
        modern.overlayEntries?["/repo/folder/file"] = .conflicted
        XCTAssertTrue(modern.canResolve([url("/repo/folder")]))
        let retained=modern
        modern.overlayEntries?["/repo/folder/file"] = .normal
        XCTAssertFalse(modern.canResolve([url("/repo/folder")]))
        XCTAssertTrue(retained.canResolve([url("/repo/folder")]))
        modern.overlayEntries=nil
        XCTAssertTrue(modern.canResolve([url("/repo/folder")]))
    }
    func testWarmedCopiesRespectNewNestedRootAndSubmoduleParentOwner() {
        let path="/repo/container/module/file"
        let original=FinderSnapshot(roots:["/repo"],states:[path:.conflicted],overlayEntries:[path:.conflicted])
        XCTAssertTrue(original.canResolve([url("/repo/container")]))
        var nested=original;nested.roots.append("/repo/container/module")
        XCTAssertFalse(nested.canResolve([url("/repo/container")]))
        XCTAssertTrue(nested.canResolve([url("/repo/container/module")]))
        XCTAssertTrue(original.canResolve([url("/repo/container")]))
        let independent=nested
        nested.repositories["/repo/container/module"] = .init(submoduleParentRoot:"/repo")
        XCTAssertFalse(nested.canResolve([url("/repo/container/module")]))
        XCTAssertTrue(independent.canResolve([url("/repo/container/module")]))
        XCTAssertEqual(nested.commonFileOperationOwner(for:[url("/repo/container/module")]),"/repo")
        nested.roots.removeLast()
        XCTAssertTrue(nested.canResolve([url("/repo/container")]))
        XCTAssertEqual(independent.exactRepositoryRoot(for:"/repo/container/module/"),"/repo/container/module")
        XCTAssertNil(independent.exactRepositoryRoot(for:"relative/file"))
    }
    func testNewCanonicalPeerDoesNotReuseOldAliasIndex() {
        let a="/repo/\u{00c5}",b="/repo/A\u{030a}"
        let original=FinderSnapshot(roots:["/repo"],states:[a+"/file":.normal],overlayEntries:[a+"/file":.normal])
        XCTAssertEqual(original.cachedState(for:url(b+"/file")),.normal)
        var changed=original;changed.overlayEntries?[b+"/other"] = .conflicted
        XCTAssertNil(changed.cachedState(for:url(b+"/file")))
        XCTAssertEqual(changed.cachedState(for:url(b+"/other")),.conflicted)
        XCTAssertEqual(original.cachedState(for:url(b+"/file")),.normal)
        XCTAssertFalse(changed.canResolve([url(a)]));XCTAssertTrue(changed.canResolve([url(b)]))
    }
    func testDescendantIndexMatchesCapturedEntryOwnerRules() {
        let parent="/repo",child="/repo/child",nested="/repo/nested"
        let entries:GitPathMap<FileState>=["/repo/tracked":.normal,"/repo/group/a":.modified,"/repo/group/b":.deleted,"/repo/group/ignored":.ignored,"/repo/group/new":.untracked,child:.added,child+"/inner/file":.conflicted,nested+"/inside/file":.conflicted]
        let snapshot=FinderSnapshot(roots:[parent,child,nested],states:entries,repositories:[child:.init(submoduleParentRoot:parent)],overlayEntries:entries)
        // A simple entry scan is an independent reference for the former public
        // behavior, including direct entries and the parent's captured gitlink.
        func owner(_ path:String)->String {
            if GitReferenceName.equal(path,child) {return parent}
            if FileTransferPaths.contains(path,in:child) {return child}
            if FileTransferPaths.contains(path,in:nested) {return nested}
            return parent
        }
        let selections=[parent,"/repo/group","/repo/group/a",child,child+"/inner",nested,nested+"/inside","/repo/absent"]
        let states:[FileState]=[.normal,.modified,.deleted,.ignored,.untracked,.added,.conflicted]
        for _ in 0..<3 {
            for path in selections {
                for state in states {
                    let expected=entries.contains {entry in entry.value==state && FileTransferPaths.contains(entry.key,in:path) && GitReferenceName.equal(owner(entry.key),owner(path))}
                    XCTAssertEqual(snapshot.hasFileState([state],at:url(path),includingDescendants:true),expected,"\(path): \(state)")
                }
            }
        }
    }
    func testConcurrentReadersAndEncodingPreserveSnapshotValues() async throws {
        let snapshot=FinderSnapshot(roots:["/repo"],states:["/repo/group/file":.conflicted],repositories:["/repo":.init(mergeActive:true)],overlayEntries:["/repo/group/file":.conflicted])
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let before=try encoder.encode(snapshot)
        let results=await withTaskGroup(of:Bool.self,returning:[Bool].self) {group in
            for _ in 0..<128 {group.addTask {
                let file=FileTransferPaths.fileURL("/repo/group/file"),folder=FileTransferPaths.fileURL("/repo/group")
                return snapshot.cachedState(for:file) == .conflicted && snapshot.canResolve([folder]) && snapshot.repositoryRoot(for:file)=="/repo"
            }}
            var result:[Bool]=[];for await passed in group {result.append(passed)};return result
        }
        XCTAssertEqual(results.count,128);XCTAssertTrue(results.allSatisfy {$0})
        XCTAssertEqual(try encoder.encode(snapshot),before)
        let decoded=try JSONDecoder().decode(FinderSnapshot.self,from:before)
        XCTAssertTrue(decoded.canResolve([url("/repo/group")]))
        XCTAssertEqual(try encoder.encode(decoded),before)
    }
    func testLargeSnapshotRepeatedFolderAndRootQueries() {
        let count=5000,root="/repo"
        let entries=GitPathMap(uniqueKeysWithValues:(0..<count).map {(root+"/folder/sub-\($0)/file",$0==count-1 ? FileState.conflicted:.normal)})
        let snapshot=FinderSnapshot(roots:[root]+(0..<200).map {"/other-\($0)"},states:entries,overlayEntries:entries)
        let folder=url(root+"/folder"),file=url(root+"/folder/sub-4999/file")
        let cold=DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(snapshot.canResolve([folder]))
        let ready=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<500 {
            XCTAssertTrue(snapshot.canResolve([folder]));XCTAssertTrue(snapshot.canRemove([folder]))
            XCTAssertEqual(snapshot.repositoryRoot(for:file),root)
        }
        let end=DispatchTime.now().uptimeNanoseconds
        print("Finder query sample: \(count) entries /201 roots, cold \(Double(ready-cold)/1_000_000) ms; 1500 warm folder/root queries \(Double(end-ready)/1_000_000) ms. No timing threshold asserted.")
    }
}
