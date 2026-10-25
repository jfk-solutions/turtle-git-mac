// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class InaccessibleEntryTests: XCTestCase {
    private enum FixtureFailure:Error {case missingInvocation}
    private func parse(_ arguments:[String],cwd:String="/repo")throws->PrimaryCommandInvocation {
        guard let value=try PrimaryCommandInvocation.parse(arguments:arguments,currentDirectory:cwd) else {throw FixtureFailure.missingInvocation}
        return value
    }
    private func directory()throws->URL {
        let value=FileManager.default.temporaryDirectory.appendingPathComponent("inaccessible-entry-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:false)
        return value
    }
    func testSourceDiagnosticIdentityAndForcedPlacementAreNotConfigurableRows() {
        XCTAssertEqual(FinderMenuEntry.inaccessible.mask,0x0010000000000000)
        XCTAssertEqual(FinderMenuEntry.inaccessible.title,"Inaccessible...")
        XCTAssertEqual(FinderMenuEntry.inaccessible.iconResource,"menucleanup")
        XCTAssertEqual(FinderMenuEntry.entry(for:.inaccessible),.inaccessible)
        XCTAssertEqual(RepositoryAction.inaccessible.icon,.clean)
        XCTAssertFalse(FinderMenuEntry.configurableCases.contains(.inaccessible))
        XCTAssertEqual(FinderMenuEntry.configurableCases.count,55)
        XCTAssertEqual(FinderMenuEntry.configurableMask & FinderMenuEntry.inaccessible.mask,0)
        XCTAssertNotEqual(FinderMenuEntry.allMask & FinderMenuEntry.inaccessible.mask,0)
        var settings=FinderMenuSettings();settings.topLevelMask=0;settings.extendedOnlyMask=FinderMenuEntry.allMask
        XCTAssertTrue(settings.firstLevel(.inaccessible));XCTAssertTrue(settings.visible(.inaccessible,extended:false))
        XCTAssertFalse(settings.firstLevel(.log));XCTAssertFalse(settings.visible(.log,extended:false))
    }
    func testSourceInaccessibleConditionsExcludeKnownRepositoryKinds() {
        let flags:FinderShellFlags=[.folder,.onlyOne,.inaccessible]
        XCTAssertTrue(FinderShellRules.allows(.inaccessible,flags:flags))
        for excluded in [FinderShellFlags.inGit,.folderInGit,.bare] {XCTAssertFalse(FinderShellRules.allows(.inaccessible,flags:flags.union(excluded)))}
        XCTAssertFalse(FinderShellRules.allows(.inaccessible,flags:[.folder,.onlyOne]))
        var settings=FinderMenuSettings();settings.hideForUnversioned=true
        XCTAssertTrue(settings.allowsMenu(flags:flags,extended:false))
        settings.excludedPaths="/repo/";XCTAssertFalse(settings.allowsPath("/repo/failure"))
    }
    func testUnknownGitMarkerProducesDiagnosticFlagsWithoutRunningGit()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("broken",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        XCTAssertFalse(FinderShellRules.flags(paths:[folder],snapshot:nil).contains(.inaccessible))
        try Data("gitdir: absent\n".utf8).write(to:folder.appendingPathComponent(".git"))
        let flags=FinderShellRules.flags(paths:[folder],snapshot:nil)
        XCTAssertTrue(flags.contains(.inaccessible));XCTAssertTrue(FinderShellRules.allows(.inaccessible,flags:flags))
        XCTAssertFalse(FinderShellRules.allows(.commit,flags:flags))
        XCTAssertFalse(FinderShellRules.allows(.initialize,flags:flags))
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(".git")),Data("gitdir: absent\n".utf8))
    }
    func testUnwatchedBareLayoutAndInvalidRefsDirectoryFollowSourceDetection()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        try Data("ref: refs/heads/main\n".utf8).write(to:root.appendingPathComponent("HEAD"))
        try Data("[core]\n bare = true\n".utf8).write(to:root.appendingPathComponent("config"))
        for path in ["objects","refs"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(path),withIntermediateDirectories:false)}
        try Data("reftable metadata".utf8).write(to:root.appendingPathComponent("refs/heads"))
        var flags=FinderShellRules.flags(paths:[root],snapshot:nil)
        XCTAssertTrue(flags.contains(.inaccessible));XCTAssertTrue(FinderShellRules.allows(.inaccessible,flags:flags))
        try FileManager.default.removeItem(at:root.appendingPathComponent("refs/heads"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("refs/heads"),withIntermediateDirectories:false)
        flags=FinderShellRules.flags(paths:[root],snapshot:nil)
        XCTAssertFalse(flags.contains(.inaccessible));XCTAssertFalse(FinderShellRules.allows(.inaccessible,flags:flags))
        XCTAssertTrue(FinderCreationMenuContext.read(directory:root,snapshot:nil,extended:false).bare)
    }
    func testKnownCachedRootSuppressesDiagnosticEvenWithGitMarker()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git"),withIntermediateDirectories:false)
        let snapshot=FinderSnapshot(roots:[root.path],states:[root.path:.normal])
        let flags=FinderShellRules.flags(paths:[root],snapshot:snapshot)
        XCTAssertTrue(flags.contains(.folderInGit));XCTAssertFalse(flags.contains(.inaccessible))
        XCTAssertFalse(FinderShellRules.allows(.inaccessible,flags:flags))
    }
    func testCommandCapturesOneLiteralFolderWithoutTrustOrMutationArguments()throws {
        for args in [["/command:inaccessible","/path:folder"],["--command=inaccessible","--path=folder"]] {
            let invocation=try parse(args)
            XCTAssertEqual(invocation.request.action,.inaccessible);XCTAssertEqual(invocation.request.paths.map(\.path),["/repo/folder"])
            XCTAssertFalse(invocation.request.action.isApplicationUtility);XCTAssertFalse(invocation.request.action.requiresWorkingTree)
            XCTAssertFalse(invocation.request.action.allowsEmptySelection);XCTAssertNil(invocation.request.action.arguments(value:"*"))
        }
        XCTAssertEqual(try parse(["/command:inaccessible"]).request.paths.map(\.path),["/repo"])
        for name in ["Café", "Cafe\u{301}"] {
            let invocation=try parse(["--command=inaccessible","--path="+name])
            XCTAssertEqual(Data(invocation.request.paths[0].lastPathComponent.utf8),Data(name.utf8))
        }
        for args in [["--command=inaccessible","--path=a","--path=b"],["--command=inaccessible","--force"],["--command=inaccessible","--remote=origin"],["--command=inaccessible","--trust"],["--command=inaccessible","--path=bad\0name"]] {XCTAssertThrowsError(try parse(args))}
    }
    func testPathFileCardinalityAndCancellationDoNotDeleteRejectedSelection()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("paths")
        try Data("one\0two\0".utf8).write(to:file)
        let value=try parse(["--command=inaccessible","--pathfile",file.path,"--pathfile0","--deletepathfile"])
        XCTAssertThrowsError(try value.resolvingPathFile(cancellation:OperationCancellation()))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        try Data("one\0".utf8).write(to:file)
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try value.resolvingPathFile(cancellation:token)) {XCTAssertTrue($0 is OperationCancellationFailure)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        let resolved=try value.resolvingPathFile(cancellation:OperationCancellation())
        XCTAssertEqual(resolved.request.action,.inaccessible);XCTAssertEqual(resolved.request.paths.map(\.path),["/repo/one"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testFinderEnvelopeRetainsUnknownSelectionAndConveysNoAutomaticTrust()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let path=FileTransferPaths.fileURL(root.path+"/Café")
        let request=FinderRequest(action:.inaccessible,paths:[path])
        let url=try XCTUnwrap(request.url),decoded=try XCTUnwrap(FinderRequest(url:url))
        XCTAssertEqual(decoded.action,.inaccessible)
        XCTAssertEqual(Data(decoded.paths[0].path.utf8),Data(request.paths[0].path.utf8))
        XCTAssertNil(decoded.clipboardPatch);XCTAssertTrue(decoded.sources.isEmpty)
        XCTAssertNil(FinderRequest(action:.inaccessible,paths:[]).url)
    }
}
