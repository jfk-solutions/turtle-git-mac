import XCTest
@testable import TurtleGitCore

private final class TestBookmarks: RepositoryBookmarkProvider {
    var creates = 0
    var starts = 0
    var stops = 0
    var stale = false
    var scopeAvailable = true
    var movedURL: URL?
    var failResolution = false
    var invalidBookmarks=Set<Data>()
    func create(for url: URL) throws -> Data { creates += 1; return Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if failResolution || invalidBookmarks.contains(data) { throw RepositoryAccessFailure.securityScopeUnavailable }
        return ResolvedBookmark(url: movedURL ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return scopeAvailable }
    func stopAccessing(_ url: URL) { stops += 1 }
}

final class RepositoryAccessTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appendingPathComponent("private/repositories.json"))
    }
    func testCompoundLeaseRetainsAllScopesWithoutWideningPrimaryContainment() throws {
        let provider=TestBookmarks(),base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var primary:RepositoryAccessLease?=RepositoryAccessLease(url:base.appendingPathComponent("worktree"),provider:provider)
        var metadata:RepositoryAccessLease?=RepositoryAccessLease(url:base.appendingPathComponent("metadata"),provider:provider)
        weak var original=primary,related=metadata
        var session:RepositoryAccessLease?=primary!.retainingRelatedScopes([metadata!])
        XCTAssertFalse(session!.contains(metadata!.url));XCTAssertTrue(session!.permits(metadata!.url));XCTAssertTrue(session!.contains(primary!.url))
        primary=nil;metadata=nil
        XCTAssertNotNil(original);XCTAssertNotNil(related);XCTAssertEqual(provider.stops,0)
        session=nil
        XCTAssertNil(original);XCTAssertNil(related);XCTAssertEqual(provider.starts,2);XCTAssertEqual(provider.stops,2)
    }
    func testAvailableAdditionalGrantsSkipOnlyFailuresAndRenewValidBookmarks() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let provider=TestBookmarks(),store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("saved.json"),provider:provider)
        let saved=try store.remember(base.appendingPathComponent("repo")),good=base.appendingPathComponent("good"),bad=base.appendingPathComponent("bad")
        try store.addPermission(saved.id,url:good);try store.addPermission(saved.id,url:bad)
        provider.invalidBookmarks=[Data(bad.path.utf8)]
        XCTAssertThrowsError(try store.acquireAdditionalPermissions(saved.id,requireSecurityScope:true))
        provider.stale=true;let before=provider.creates
        let available=try store.acquireAdditionalPermissions(saved.id,requireSecurityScope:true,skipUnavailable:true)
        XCTAssertEqual(available.map{ $0.url.path },[good.path]);XCTAssertEqual(provider.creates,before+1)
        XCTAssertEqual(store.repositories[0].additionalPermissions?.count,2,"Unavailable records remain available for explicit renewal/removal")
    }
    func testRenewalWithoutOpeningPreservesRecentOrderAndDates() throws {
        let (folder,file)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=TestBookmarks(),store=try RepositoryAccessStore(storageURL:file,provider:provider)
        let first=try store.remember(folder.appendingPathComponent("first")),second=try store.remember(folder.appendingPathComponent("second"))
        provider.stale=true;provider.movedURL=folder.appendingPathComponent("moved")
        do { let lease=try store.acquire(first.id,requireSecurityScope:true,recordingOpen:false);XCTAssertEqual(lease.url,provider.movedURL) }
        XCTAssertEqual(store.repositories.map(\.id),[second.id,first.id]);XCTAssertEqual(store.repositories.last?.lastOpened,first.lastOpened)
        XCTAssertEqual(store.repositories.last?.lastKnownPath,provider.movedURL?.path);XCTAssertEqual(provider.starts,provider.stops)
        let reopened=try RepositoryAccessStore(storageURL:file,provider:provider)
        XCTAssertEqual(reopened.repositories,store.repositories)
        do { _=try reopened.acquire(first.id) };XCTAssertEqual(reopened.repositories.first?.id,first.id)
    }
    func testTargetedGrantRenewalDoesNotResolveOrChangeUnavailableSibling() throws {
        let (folder,file)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=TestBookmarks(),store=try RepositoryAccessStore(storageURL:file,provider:provider),saved=try store.remember(folder.appendingPathComponent("repo"))
        try store.addPermission(saved.id,url:folder.appendingPathComponent("good"));try store.addPermission(saved.id,url:folder.appendingPathComponent("bad"))
        let grants=try XCTUnwrap(store.repositories.first?.additionalPermissions),good=grants[0],bad=grants[1]
        provider.invalidBookmarks=[bad.bookmark];provider.stale=true;provider.movedURL=folder.appendingPathComponent("moved-good")
        do { let lease=try store.acquirePermission(saved.id,permission:good.id,requireSecurityScope:true);XCTAssertEqual(lease.url,provider.movedURL) }
        XCTAssertEqual(store.repositories[0].additionalPermissions?[1],bad);XCTAssertEqual(store.repositories[0].additionalPermissions?[0].id,good.id)
        XCTAssertEqual(store.repositories[0].additionalPermissions?[0].path,provider.movedURL?.path);XCTAssertEqual(provider.starts,provider.stops)
        let bytes=try Data(contentsOf:file)
        XCTAssertThrowsError(try store.acquirePermission(saved.id,permission:bad.id));XCTAssertEqual(try Data(contentsOf:file),bytes)
        provider.scopeAvailable=false
        XCTAssertThrowsError(try store.acquirePermission(saved.id,permission:good.id,requireSecurityScope:true));XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertThrowsError(try store.acquirePermission(saved.id,permission:UUID()))
    }
    func testLinkedWorktreeMetadataPermissionsAreDiscoveredInLayersWithoutGitWrites() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture()
        let linked=root.deletingLastPathComponent().appendingPathComponent("linked 雪-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:linked);try? FileManager.default.removeItem(at:root) }
        _=try await repo.run(["worktree","add","-b","linked-access",linked.path])
        let git=try await GitRepository(root:linked).run(["rev-parse","--absolute-git-dir"]).text.trimmingCharacters(in:.newlines)
        let provider=TestBookmarks(),primary=RepositoryAccessLease(url:linked,provider:provider)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let first=try XCTUnwrap(RepositoryMetadataAccess.next(at:linked,permissions:[primary]))
        XCTAssertEqual(first.kind,.gitDirectory);XCTAssertEqual(first.folder.path,URL(fileURLWithPath:git).resolvingSymlinksInPath().path)
        let narrow=RepositoryAccessLease(url:first.folder,provider:provider)
        let common=try XCTUnwrap(RepositoryMetadataAccess.next(at:linked,permissions:[primary,narrow]))
        XCTAssertEqual(common.kind,.commonDirectory);XCTAssertEqual(common.folder.path,root.appendingPathComponent(".git").resolvingSymlinksInPath().path)
        let broad=RepositoryAccessLease(url:common.folder,provider:provider)
        XCTAssertNil(try RepositoryMetadataAccess.next(at:linked,permissions:[primary,broad]))
        let cancelled=OperationCancellation();cancelled.cancel()
        XCTAssertThrowsError(try RepositoryMetadataAccess.next(at:linked,permissions:[primary],cancellation:cancelled))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
    }
    func testRecursiveAlternatesAndQuotedUnicodePathsUseOnlyAuthorizedFolders() async throws {
        let (source,repo,path)=try await GitPatchTests().fixture()
        let base=source.deletingLastPathComponent().appendingPathComponent("alternates-"+UUID().uuidString),middle=base.appendingPathComponent("middle"),leaf=base.appendingPathComponent("leaf")
        defer { try? FileManager.default.removeItem(at:base);try? FileManager.default.removeItem(at:source) }
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        _=try await repo.run(["clone","--shared","--",source.path,middle.path]);_=try await repo.run(["clone","--shared","--",middle.path,leaf.path])
        let provider=TestBookmarks(),primary=RepositoryAccessLease(url:leaf,provider:provider)
        let first=try XCTUnwrap(RepositoryMetadataAccess.next(at:leaf,permissions:[primary]))
        XCTAssertEqual(first.kind,.objectDirectory);XCTAssertEqual(first.folder.path,middle.appendingPathComponent(".git/objects").resolvingSymlinksInPath().path)
        let middleGrant=RepositoryAccessLease(url:first.folder,provider:provider)
        let second=try XCTUnwrap(RepositoryMetadataAccess.next(at:leaf,permissions:[primary,middleGrant]))
        XCTAssertEqual(second.folder.path,source.appendingPathComponent(".git/objects").resolvingSymlinksInPath().path)
        let sourceGrant=RepositoryAccessLease(url:second.folder,provider:provider)
        XCTAssertNil(try RepositoryMetadataAccess.next(at:leaf,permissions:[primary,middleGrant,sourceGrant]))
        let alias=base.appendingPathComponent("objects\n雪")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:source.appendingPathComponent(".git/objects"))
        let quoted="\""+alias.path.replacingOccurrences(of:"\n",with:"\\n")+"\"\n"
        try Data(quoted.utf8).write(to:leaf.appendingPathComponent(".git/objects/info/alternates"))
        XCTAssertNil(try RepositoryMetadataAccess.next(at:leaf,permissions:[primary,sourceGrant]))
        let bytes=try await GitRepository(root:leaf).run(["cat-file","blob","HEAD:"+path]).stdout
        XCTAssertEqual(bytes,try Data(contentsOf:source.appendingPathComponent(path)))
    }
    func testGitfileCRLFRelativePathsMalformedMarkersAndUncoveredMetadata() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),work=base.appendingPathComponent("work"),git=base.appendingPathComponent("external/meta")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:git,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let provider=TestBookmarks(),primary=RepositoryAccessLease(url:work,provider:provider),marker=work.appendingPathComponent(".git")
        try Data("gitdir: ../external/meta\r\n".utf8).write(to:marker)
        try Data([0,1,2]).write(to:git.appendingPathComponent("commondir"))
        let requirement=try XCTUnwrap(RepositoryMetadataAccess.next(at:work,permissions:[primary]))
        XCTAssertEqual(requirement.folder.path,git.resolvingSymlinksInPath().path,"CRLF must not enter the folder path")
        let grant=RepositoryAccessLease(url:git,provider:provider)
        XCTAssertThrowsError(try RepositoryMetadataAccess.next(at:work,permissions:[primary,grant]),"Uncovered invalid commondir must not be read until granted")
        for invalid in [Data("not a gitfile\n".utf8),Data("gitdir: ".utf8),Data([0,1,2])] {
            try invalid.write(to:marker);XCTAssertThrowsError(try RepositoryMetadataAccess.next(at:work,permissions:[primary]))
        }
    }
    func testAdditionalPermissionsSurviveRenewalRelaunchAndExplicitRemoval() throws {
        let (folder,url)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=TestBookmarks(),store=try RepositoryAccessStore(storageURL:url,provider:provider)
        let saved=try store.remember(folder.appendingPathComponent("worktree")),admin=folder.appendingPathComponent("main/.git")
        try store.addPermission(saved.id,url:admin)
        let grant=try XCTUnwrap(store.repositories[0].additionalPermissions?.first)
        _ = try store.replace(saved.id,with:folder.appendingPathComponent("worktree"))
        let reopened=try RepositoryAccessStore(storageURL:url,provider:provider)
        do { let leases=try reopened.acquireAdditionalPermissions(saved.id,requireSecurityScope:true);XCTAssertEqual(leases.map(\.url),[admin]);XCTAssertTrue(leases[0].contains(admin.appendingPathComponent("index")));XCTAssertFalse(leases[0].contains(folder)) }
        XCTAssertEqual(provider.starts,provider.stops)
        try reopened.addPermission(saved.id,url:folder.appendingPathComponent("moved/.git"),replacing:grant.id)
        XCTAssertEqual(reopened.repositories[0].additionalPermissions?.map(\.id),[grant.id])
        try reopened.removePermission(saved.id,permission:grant.id)
        XCTAssertTrue(try reopened.acquireAdditionalPermissions(saved.id).isEmpty)
    }
    func testSavedPermissionSurvivesRelaunchAndForgetDoesNotDeleteRepository() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), repository = folder.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(repository)
        let relaunched = try RepositoryAccessStore(storageURL: storage, provider: provider)
        XCTAssertEqual(relaunched.repositories.map(\.id), [saved.id])
        XCTAssertEqual(relaunched.repositories[0].lastKnownPath, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber, 0o600)
        try relaunched.forget(saved.id)
        XCTAssertTrue(try RepositoryAccessStore(storageURL: storage, provider: provider).repositories.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }
    func testReplacementKeepsIdentityAndRejectsDuplicateWithoutChangingStore() throws {
        let (folder,url)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=TestBookmarks(),store=try RepositoryAccessStore(storageURL:url,provider:provider)
        let a=folder.appendingPathComponent("a"),b=folder.appendingPathComponent("b"),moved=folder.appendingPathComponent("moved")
        let first=try store.remember(a),second=try store.remember(b)
        let replaced=try store.replace(first.id,with:moved)
        XCTAssertEqual(replaced.id,first.id);XCTAssertEqual(replaced.lastKnownPath,moved.path)
        let before=try Data(contentsOf:url)
        XCTAssertThrowsError(try store.replace(first.id,with:b));XCTAssertEqual(before,try Data(contentsOf:url))
        let reopened=try RepositoryAccessStore(storageURL:url,provider:provider)
        XCTAssertEqual(Set(reopened.repositories.map(\.id)),[first.id,second.id])
        XCTAssertEqual(try reopened.acquire(first.id).url.path,moved.path)
    }

    func testScopeHeldThroughSessionAndBalancedOnRelease() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder)
        var lease: RepositoryAccessLease? = try store.acquire(saved.id, requireSecurityScope: true)
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 0)
        XCTAssertTrue(lease!.contains(folder.appendingPathComponent("file")))
        lease = nil
        XCTAssertEqual(provider.stops, 1)
    }
    func testUnavailableScopeRequiresReselectionWithoutUnbalancedStop() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder); provider.scopeAvailable = false
        XCTAssertThrowsError(try store.acquire(saved.id, requireSecurityScope: true))
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 0)
        XCTAssertEqual(store.repositories[0].id, saved.id)
    }
    func testStaleMovedBookmarkRenewsWithoutDuplicatingEntry() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder.appendingPathComponent("old"))
        let moved = folder.appendingPathComponent("new")
        provider.stale = true; provider.movedURL = moved
        let lease = try store.acquire(saved.id)
        XCTAssertEqual(provider.creates, 2)
        XCTAssertEqual(store.repositories.count, 1); XCTAssertEqual(store.repositories[0].id, saved.id)
        XCTAssertEqual(lease.url.path, moved.path)
        XCTAssertEqual(store.repositories[0].lastKnownPath, moved.resolvingSymlinksInPath().path)
    }
    func testPathBoundaryTraversalAndSymlinkCannotWidenGrant() throws {
        let (folder, _) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("repo", isDirectory: true)
        let outside = folder.appendingPathComponent("repo-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let lease = RepositoryAccessLease(url: root, provider: TestBookmarks())
        XCTAssertTrue(lease.contains(root.appendingPathComponent("nested/file.txt")))
        XCTAssertFalse(lease.contains(outside))
        XCTAssertFalse(lease.contains(root.appendingPathComponent("../repo-other/file.txt")))
        XCTAssertFalse(lease.contains(root.appendingPathComponent("escape/file.txt")))
        XCTAssertFalse(lease.contains(URL(string: "https://example.invalid" + root.path)!))
    }
    func testFailedResolutionKeepsSavedBookmarkAndNeverStartsAccess() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder); provider.failResolution = true
        XCTAssertThrowsError(try store.acquire(saved.id))
        XCTAssertEqual(provider.starts, 0); XCTAssertEqual(store.repositories, [saved])
    }
    func testCorruptStoreFailsVisiblyRatherThanOverwritingPermissions() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("broken".utf8); try corrupt.write(to: storage)
        XCTAssertThrowsError(try RepositoryAccessStore(storageURL: storage, provider: TestBookmarks()))
        XCTAssertEqual(try Data(contentsOf: storage), corrupt)
    }
    func testRecentRepositoriesDeduplicateAndKeepMostRecentlyOpenedFirst() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try RepositoryAccessStore(storageURL: storage, provider: TestBookmarks())
        let a = try store.remember(folder.appendingPathComponent("a"))
        let b = try store.remember(folder.appendingPathComponent("b"))
        let repeated = try store.remember(folder.appendingPathComponent("a"))
        XCTAssertEqual(repeated.id, a.id)
        XCTAssertEqual(store.repositories.map(\.id), [a.id, b.id])
    }
    func testAppStoreRuntimeCannotSilentlyUseSystemGit() throws {
        let (folder, _) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bundleURL = folder.appendingPathComponent("NoGit.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.turtlegit.test.no-runtime", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertThrowsError(try GitRuntime.executable(bundle: bundle, appStore: true))
        XCTAssertEqual(try GitRuntime.executable(bundle: bundle, appStore: false).path, "/usr/bin/git")
    }
}

final class WorkingComparisonMarkTests: XCTestCase {
    func testPrivateBookmarkSharedMetadataRelaunchAndConditionalConsumption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("marked 雪\n.txt"), bytes = Data([0, 255, 13, 10])
        try bytes.write(to: path)
        let storage = root.appendingPathComponent("private/mark.json"), shared = root.appendingPathComponent("shared/mark.json"), provider = TestBookmarks()
        let permission = RepositoryAccessLease(url: root, provider: provider)
        let store = WorkingComparisonMarkStore(storageURL: storage, provider: provider)
        let first = try store.remember(file: path, permission: permission, requireSecurityScope: true)
        XCTAssertTrue(try WorkingComparisonMarkSnapshot.publish(first, to: shared))
        XCTAssertEqual(try WorkingComparisonMarkSnapshot.read(from: shared), first)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: shared)) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["id", "path"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber, 0o600)
        let relaunched = WorkingComparisonMarkStore(storageURL: storage, provider: provider)
        var acquired: WorkingComparisonAccess? = try relaunched.acquire(requireSecurityScope: true)
        XCTAssertEqual(acquired?.file.path, path.path); XCTAssertEqual(acquired?.mark, first)
        XCTAssertEqual(provider.starts, 2); XCTAssertEqual(provider.stops, 0)
        acquired = nil; XCTAssertEqual(provider.stops, 1)
        let second = try relaunched.remember(file: path, permission: permission)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(try store.consume(first.id)); XCTAssertEqual(try store.snapshot(), second)
        XCTAssertTrue(try store.consume(second.id)); XCTAssertNil(try relaunched.snapshot())
        XCTAssertTrue(try WorkingComparisonMarkSnapshot.publish(nil, to: shared)); XCTAssertNil(try WorkingComparisonMarkSnapshot.read(from: shared))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testSingleFileGrantFollowsMovedFileWithoutGrantingItsSibling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file"), sibling = root.appendingPathComponent("sibling"), moved = root.appendingPathComponent("moved")
        try Data("file".utf8).write(to: file); try Data("sibling".utf8).write(to: sibling)
        let provider = TestBookmarks(), permission = RepositoryAccessLease(url: file, provider: provider)
        let store = WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("private/mark.json"), provider: provider)
        let mark = try store.remember(file: file, permission: permission, requireSecurityScope: true)
        XCTAssertThrowsError(try store.remember(file: sibling, permission: permission))
        try FileManager.default.moveItem(at: file, to: moved)
        provider.movedURL = moved; provider.stale = true
        let access = try store.acquire(requireSecurityScope: true)
        XCTAssertEqual(access.file.path, moved.path); XCTAssertEqual(access.mark.id, mark.id)
        XCTAssertFalse(access.permission.contains(sibling)); XCTAssertEqual(try Data(contentsOf: access.file), Data("file".utf8))
        let shared = root.appendingPathComponent("shared/mark.json")
        XCTAssertThrowsError(try WorkingComparisonMarkSnapshot.publish(.init(id: UUID(), path: "relative"), to: shared))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(WorkingComparisonMarkSnapshot(id: UUID(), path: "relative")).write(to: shared)
        XCTAssertThrowsError(try WorkingComparisonMarkSnapshot.read(from: shared))
    }
    func testMovedFolderRenewalAndFailedAccessKeepMarkAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), moved = root.appendingPathComponent("moved"), name = "nested/file.txt"
        try FileManager.default.createDirectory(at: old.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("contents\n".utf8).write(to: old.appendingPathComponent(name))
        let provider = TestBookmarks(), store = WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("private/mark.json"), provider: provider)
        let saved = try store.remember(file: old.appendingPathComponent(name), permission: RepositoryAccessLease(url: old, provider: provider))
        provider.failResolution = true
        XCTAssertThrowsError(try store.acquire()); XCTAssertEqual(try store.snapshot(), saved)
        provider.failResolution = false; provider.scopeAvailable = false
        XCTAssertThrowsError(try store.acquire(requireSecurityScope: true)); XCTAssertEqual(try store.snapshot(), saved)
        provider.scopeAvailable = true
        try FileManager.default.moveItem(at: old, to: moved)
        provider.stale = true; provider.movedURL = moved
        let access = try store.acquire(requireSecurityScope: true)
        XCTAssertEqual(access.mark.id, saved.id); XCTAssertEqual(access.file.path, moved.appendingPathComponent(name).path)
        XCTAssertEqual(provider.creates, 2); XCTAssertEqual(try store.snapshot()?.path, access.file.path)
        try FileManager.default.removeItem(at: access.file)
        XCTAssertThrowsError(try store.acquire()); XCTAssertEqual(try store.snapshot()?.id, saved.id)
    }
    func testMarkRejectsDirectoriesEscapingLinksAndUnavailableScopeWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("repo"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let file = folder.appendingPathComponent("file"); try Data("inside".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: outside)
        let provider = TestBookmarks(), store = WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("mark.json"), provider: provider)
        let permission = RepositoryAccessLease(url: folder, provider: provider)
        let saved = try store.remember(file: file, permission: permission)
        for invalid in [folder, outside, folder.appendingPathComponent("escape"), folder.appendingPathComponent("missing")] {
            XCTAssertThrowsError(try store.remember(file: invalid, permission: permission))
            XCTAssertEqual(try store.snapshot(), saved)
        }
        provider.scopeAvailable = false
        XCTAssertThrowsError(try store.remember(file: file, permission: RepositoryAccessLease(url: folder, provider: provider), requireSecurityScope: true))
        XCTAssertEqual(try store.snapshot(), saved)
        let corrupt = Data("invalid".utf8); try corrupt.write(to: store.storageURL)
        XCTAssertThrowsError(try store.snapshot()); XCTAssertThrowsError(try store.acquire())
        XCTAssertEqual(try Data(contentsOf: store.storageURL), corrupt)
    }
}
