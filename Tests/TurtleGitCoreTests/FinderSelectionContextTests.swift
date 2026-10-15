import XCTest
@testable import TurtleGitCore

final class FinderSelectionContextTests: XCTestCase {
    func testNearestOwnerDoesNotFallThroughToContainingParentForMixedSelection() {
        let parent = URL(fileURLWithPath:"/repo/file"), child = URL(fileURLWithPath:"/repo/nested/file")
        let snapshot = FinderSnapshot(roots:["/repo","/repo/nested"],states:[:],repositories:["/repo":.init(hasLFS:true),"/repo/nested":.init(hasStash:true)])
        XCTAssertEqual(snapshot.repositoryRoot(for:child),"/repo/nested")
        XCTAssertNil(snapshot.commonRepositoryRoot(for:[parent,child])); XCTAssertNil(snapshot.repositoryMetadata(for:[parent,child]))
        XCTAssertEqual(snapshot.repositoryMetadata(for:[child])?.hasStash,true)
        XCTAssertNil(snapshot.repositoryRoot(for:URL(fileURLWithPath:"/repo-sibling/file")))
        XCTAssertNil(snapshot.repositoryRoot(for:URL(string:"https://example.invalid/repo/file")!))
        XCTAssertNil(snapshot.commonRepositoryRoot(for:[]))
    }
    func testExplicitIgnoreAncestryTrackedExceptionAndNestedBoundary() {
        let root="/repo", ignored="/repo/ignored", nested="/repo/ignored/nested", tracked="/repo/ignored/tracked"
        let snapshot = FinderSnapshot(roots:[root,nested],states:[ignored:.ignored,ignored+"/sub":.modified,tracked:.normal,nested:.normal,nested+"/file":.normal],
            overlayEntries:[ignored:.ignored,tracked:.normal,nested+"/file":.normal])
        XCTAssertEqual(snapshot.cachedState(for:URL(fileURLWithPath:ignored+"/new")),.ignored)
        XCTAssertEqual(snapshot.cachedState(for:URL(fileURLWithPath:ignored+"/sub")),.ignored)
        XCTAssertEqual(snapshot.cachedState(for:URL(fileURLWithPath:tracked)),.normal)
        XCTAssertNil(snapshot.cachedState(for:URL(fileURLWithPath:nested+"/unknown")))
        XCTAssertEqual(snapshot.cachedState(for:URL(fileURLWithPath:nested+"/file")),.normal)
        XCTAssertFalse(snapshot.canIgnore([URL(fileURLWithPath:ignored+"/new")],deleting:false))
    }
    func testAggregatedIgnoredBadgeIsNotAnIgnoreRule() {
        let folder=URL(fileURLWithPath:"/repo/folder")
        let snapshot=FinderSnapshot(roots:["/repo"],states:[folder.path:.ignored,folder.path+"/ignored-file":.ignored],overlayEntries:[folder.path+"/ignored-file":.ignored])
        XCTAssertNil(snapshot.cachedState(for:folder)); XCTAssertNil(snapshot.cachedState(for:folder.appendingPathComponent("new")))
        let legacy=FinderSnapshot(roots:["/repo"],states:[folder.path:.ignored])
        XCTAssertEqual(legacy.cachedState(for:folder.appendingPathComponent("new")),.ignored)
    }
    func testNestedCheckoutChangesDoNotMakeParentOnlyDirectoryActionable() {
        let directory=URL(fileURLWithPath:"/repo/container"), child="/repo/container/nested"
        let snapshot=FinderSnapshot(roots:["/repo",child],states:[directory.path:.conflicted,child+"/file":.conflicted],overlayEntries:[child+"/file":.conflicted])
        XCTAssertFalse(snapshot.canRename([directory])); XCTAssertFalse(snapshot.canRemove([directory])); XCTAssertFalse(snapshot.canRevert([directory])); XCTAssertFalse(snapshot.canResolve([directory]))
        XCTAssertTrue(snapshot.canResolve([URL(fileURLWithPath:child)]))
    }
    func testRegisteredSubmoduleRootKeepsParentRenameRemoveButNotMixedContents() {
        let parent="/repo", child="/repo/module", file=URL(fileURLWithPath:"/repo/file"), module=URL(fileURLWithPath:child)
        let snapshot=FinderSnapshot(roots:[parent,child],states:[file.path:.modified,child:.normal,child+"/inside":.modified],repositories:[parent:.init(),child:.init(submoduleParentRoot:parent)],overlayEntries:[file.path:.modified,child:.normal,child+"/inside":.modified])
        XCTAssertEqual(snapshot.commonFileOperationOwner(for:[file,module]),parent)
        XCTAssertTrue(snapshot.canRename([module])); XCTAssertTrue(snapshot.canRemove([file,module]))
        XCTAssertNil(snapshot.commonRepositoryRoot(for:[file,module]))
        XCTAssertFalse(snapshot.canRemove([file,module.appendingPathComponent("inside")]))
        XCTAssertFalse(snapshot.canRevert([file,module.appendingPathComponent("inside")]))
        XCTAssertFalse(snapshot.canIgnore([file,module.appendingPathComponent("inside")],deleting:true))
    }
    func testRepresentativeFlagsDoNotCombineLaterStatusOrRepositoryFacts() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let normal=folder.appendingPathComponent("normal"), added=folder.appendingPathComponent("added.patch"), conflict=folder.appendingPathComponent("conflict")
        for path in [normal,added,conflict] { try Data().write(to:path) }
        let snapshot=FinderSnapshot(roots:[folder.path],states:[normal.path:.normal,added.path:.added,conflict.path:.conflicted],repositories:[folder.path:.init()])
        let firstNormal=FinderShellRules.flags(paths:[normal,added,conflict],snapshot:snapshot)
        XCTAssertTrue(firstNormal.contains(.normal)); XCTAssertTrue(firstNormal.contains(.patchFile))
        XCTAssertFalse(firstNormal.contains(.added)); XCTAssertFalse(firstNormal.contains(.conflicted))
        let firstConflict=FinderShellRules.flags(paths:[conflict,normal],snapshot:snapshot)
        XCTAssertTrue(firstConflict.isSuperset(of:[.inGit,.conflicted,.two])); XCTAssertFalse(firstConflict.contains(.normal))
        let firstAdded=FinderShellRules.flags(paths:[added,normal],snapshot:snapshot)
        XCTAssertTrue(firstAdded.contains(.added)); XCTAssertFalse(firstAdded.contains(.normal))
        XCTAssertTrue(FinderShellRules.allows(.add,flags:FinderShellRules.flags(paths:[normal,added],snapshot:snapshot)) == false)
    }
    func testRootAndIgnoredCreationUseSameCachedContext() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true), ignored=root.appendingPathComponent("ignored",isDirectory:true)
        try FileManager.default.createDirectory(at:ignored.appendingPathComponent("child",isDirectory:true),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let snapshot=FinderSnapshot(roots:[root.path],states:[root.path:.ignored,ignored.path:.ignored],repositories:[root.path:.init()],overlayEntries:[ignored.path:.ignored])
        let child=ignored.appendingPathComponent("child",isDirectory:true)
        XCTAssertTrue(FinderCreationMenuContext.read(directory:child,snapshot:snapshot,extended:false).ignored)
        XCTAssertEqual(Set(FinderCreationMenuContext.read(directory:child,snapshot:snapshot,extended:false).actions),Set([.clone,.initialize]))
        XCTAssertTrue(FinderShellRules.flags(paths:[child],snapshot:snapshot).contains(.ignored))
        let flags=FinderShellRules.flags(paths:[root],snapshot:snapshot)
        XCTAssertTrue(flags.contains(.inGit)); XCTAssertFalse(flags.contains(.ignored))
    }
}
