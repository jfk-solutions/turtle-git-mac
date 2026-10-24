import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserTests: XCTestCase {
    func testRevisionLabelUsesSourceReferenceOrderWithoutChangingSnapshot() async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","aaa-label",hash]);_ = try await repo.run(["tag","-a","release-label","-m","annotated",hash])
        let snapshot=try await repo.browseRepository(revision:hash)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout,bytes=try Data(contentsOf:root.appendingPathComponent(path))
        let label=try await repo.repositoryBrowserRevisionLabel(snapshot);XCTAssertEqual(label,"refs/heads/aaa-label")
        let symbolic=try await repo.browseRepository(revision:"HEAD"),symbolicLabel=try await repo.repositoryBrowserRevisionLabel(symbolic)
        XCTAssertEqual(symbolicLabel,"HEAD")
        _ = try await repo.run(["branch","-D","aaa-label"])
        let nextLabel=try await repo.repositoryBrowserRevisionLabel(snapshot);XCTAssertEqual(nextLabel,"refs/heads/main")
        XCTAssertEqual(snapshot.objectID,hash);XCTAssertEqual(snapshot.revision,hash)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout
        XCTAssertEqual(afterHead,head);XCTAssertEqual(afterIndex,index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
    }
    func testRevisionLabelAnnotatedTreeFallbackCancellationAndForeignScope() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["tag","-a","tree-label","-m","annotated tree",tree])
        let snapshot=try await repo.browseRepository(revision:tree)
        let label=try await repo.repositoryBrowserRevisionLabel(snapshot);XCTAssertEqual(label,"refs/tags/tree-label^{}")
        _ = try await repo.run(["tag","-d","tree-label"])
        let fallback=try await repo.repositoryBrowserRevisionLabel(snapshot);XCTAssertEqual(fallback,tree)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.repositoryBrowserRevisionLabel(snapshot,cancellation:token);XCTFail("Cancelled label read accepted")} catch is OperationCancellationFailure {}
        let foreign=GitRepository(root:root.appendingPathComponent("foreign"))
        do {_ = try await foreign.repositoryBrowserRevisionLabel(snapshot);XCTFail("Foreign snapshot accepted")} catch RepositoryBrowserFailure.selection {}
    }
    func testBytePathCollectionsAndEntryIdentity() throws {
        let a="caf\u{e9}",b="cafe\u{301}"
        XCTAssertEqual(a,b) // Swift canonical equality is the regression trigger.
        XCTAssertFalse(RepositoryBrowserPathIdentity.equal(a,b))
        XCTAssertNotEqual(RepositoryBrowserPathIdentity.id(a),RepositoryBrowserPathIdentity.id(b))
        var map:RepositoryBrowserPathMap<Int>=[:];map[a]=1;map[b]=2
        XCTAssertEqual(map.count,2);XCTAssertEqual(map[a],1);XCTAssertEqual(map[b],2)
        XCTAssertEqual(map.mapValues{$0 * 2}[b],4)
        let paths=RepositoryBrowserPathSet([a,b]);XCTAssertTrue(paths.isSuperset(of:[a,b]))
        XCTAssertTrue(paths.intersection([a]).contains(a));XCTAssertFalse(paths.intersection([a]).contains(b))
        let left=RepositoryBrowserEntry(path:a,name:a,mode:"100644",objectID:String(repeating:"a",count:40),size:1)
        let right=RepositoryBrowserEntry(path:b,name:b,mode:"100644",objectID:left.objectID,size:1)
        XCTAssertNotEqual(left,right)
    }
    func testUnicodeAliasTreesKeepHistoricalBytesAndRefuseWorkingAliasMutation() async throws {
        let (root,repo,_) = try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let a="caf\u{e9}.txt",b="cafe\u{301}.txt",da="d\u{e9}",db="de\u{301}"
        let working=Data("working identity\n".utf8);try working.write(to:root.appendingPathComponent(a));try await repo.stage([a]);_ = try await repo.commit(message:"working NFC")
        let first=Data([0,1,0xff,10]),second=Data([9,2,0xfe,13,10])
        let ah=try await repo.run(["hash-object","-w","--stdin"],input:first).text.trimmingCharacters(in:.newlines)
        let bh=try await repo.run(["hash-object","-w","--stdin"],input:second).text.trimmingCharacters(in:.newlines)
        func record(_ mode:String,_ type:String,_ hash:String,_ name:String)->String {"\(mode) \(type) \(hash)\t\(name)\0"}
        let at=try await repo.run(["mktree","-z"],input:Data(record("100644","blob",ah,"first.txt").utf8)).text.trimmingCharacters(in:.newlines)
        let bt=try await repo.run(["mktree","-z"],input:Data(record("100644","blob",bh,"second.txt").utf8)).text.trimmingCharacters(in:.newlines)
        let directories=record("040000","tree",at,da)+record("040000","tree",bt,db)
        let tree=try await repo.run(["mktree","-z"],input:Data((record("100644","blob",ah,a)+record("100644","blob",bh,b)+directories).utf8)).text.trimmingCharacters(in:.newlines)
        let snapshot=try await repo.browseRepository(revision:tree)
        XCTAssertEqual(snapshot.entries.count,4);XCTAssertEqual(Set(snapshot.entries.map(\.id)).count,4)
        let ae=try XCTUnwrap(snapshot.entries.first{RepositoryBrowserPathIdentity.equal($0.path,a)}),be=try XCTUnwrap(snapshot.entries.first{RepositoryBrowserPathIdentity.equal($0.path,b)})
        let av=try await repo.repositoryBrowserFile(snapshot,entry:ae),bv=try await repo.repositoryBrowserFile(snapshot,entry:be)
        XCTAssertEqual(av.bytes,first);XCTAssertEqual(bv.bytes,second)
        let ad=try await repo.browseRepositoryDirectory(snapshot,directory:da),bd=try await repo.browseRepositoryDirectory(snapshot,directory:db)
        XCTAssertEqual(ad.entries.first?.name,"first.txt");XCTAssertEqual(bd.entries.first?.name,"second.txt")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do {try await repo.revertRepositoryBrowserFile(snapshot,entry:be);XCTFail("Canonical alias checkout was allowed")}
        catch RepositoryBrowserFailure.normalizationCollision(let path) {XCTAssertTrue(RepositoryBrowserPathIdentity.equal(path,b))}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(a)),working)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let unchanged=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(unchanged,head)
        let single=try await repo.exportRepositoryBrowser(snapshot,entry:be, backend: GitLibGit2Configuration());defer{single.discard()};XCTAssertEqual(try Data(contentsOf:single.item),second)
        let dirs=try await repo.run(["mktree","-z"],input:Data(directories.utf8)).text.trimmingCharacters(in:.newlines)
        let listing=try await repo.browseRepository(revision:dirs)
        // Ask this actual volume whether aliases share a directory. On such a
        // volume a recursive export must fail rather than merge disjoint children.
        let probe=root.appendingPathComponent("volume-probe");try FileManager.default.createDirectory(at:probe,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:probe.appendingPathComponent(da),withIntermediateDirectories:false)
        let aliases=FileManager.default.fileExists(atPath:probe.appendingPathComponent(db).path)
        if aliases {
            do {let export=try await repo.exportRepositoryBrowser(listing, backend: GitLibGit2Configuration());export.discard();XCTFail("Alias directories were merged")}
            catch {XCTAssertTrue((error as NSError).domain == NSCocoaErrorDomain)}
        } else {let export=try await repo.exportRepositoryBrowser(listing, backend: GitLibGit2Configuration());XCTAssertEqual(export.fileCount,2);export.discard()}
        try await repo.revertRepositoryBrowserFile(snapshot,entry:ae)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(a)),first)
    }
    func testStandaloneTreesSupportComparisonMarksPatchesAndHistoricalReadsWithoutInventingHistory() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let first = try await repo.browseRepository(), tree = try XCTUnwrap(first.treeID)
        _ = try await repo.run(["tag", "-a", "snapshot-tree", tree, "-m", "Tree snapshot"])
        let changed = Data("tree comparison changed\n".utf8), literal = ":(glob)* 雪\n.bin"
        try changed.write(to: root.appendingPathComponent(path))
        try Data([0xff, 0x85, 0, 10]).write(to: root.appendingPathComponent(literal))
        try await repo.stage([path, literal]); _ = try await repo.commit(message: "second snapshot")
        let second = try await repo.browseRepository(), newer = try XCTUnwrap(second.treeID)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        // The selected source GetCommit fallback requires an explicit tree
        // expression when an annotated tag itself is not a tree object.
        let snapshotTree = "snapshot-tree^{tree}"
        let comparison = try await repo.revisionComparison(from: .revision(snapshotTree), to: .revision(newer))
        XCTAssertEqual(comparison.from, .revision(tree)); XCTAssertEqual(comparison.to, .revision(newer))
        XCTAssertEqual(comparison.fromDetails?.isTree, true); XCTAssertEqual(comparison.toDetails?.isTree, true)
        XCTAssertEqual(comparison.fromDetails?.author, ""); XCTAssertNil(comparison.fromDetails?.authorDate)
        XCTAssertTrue(comparison.files.contains { $0.path == path })
        let document = try await repo.comparisonFile(comparison, path: path)
        XCTAssertEqual(document.base.bytes, original); XCTAssertEqual(document.destination.bytes, changed)
        let patch = try await repo.revisionComparisonPatchData(comparison, paths: [path])
        XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+tree comparison changed"))
        let reverse = try await repo.revisionComparison(from: .revision(newer), to: .revision(tree))
        let reversed = try await repo.comparisonFile(reverse, path: path)
        XCTAssertEqual(reversed.base.bytes, changed); XCTAssertEqual(reversed.destination.bytes, original)
        var options = RevisionDiffOptions(); options.commonAncestor = true
        let direct = try await repo.revisionComparison(from: .revision(tree), to: .revision(newer), options: options)
        XCTAssertEqual(direct.from, comparison.from); XCTAssertEqual(direct.files, comparison.files)
        let working = try await repo.revisionFileComparison(from: .revision(tree), to: .workingTree, paths: [path])
        let workingDocument = try await repo.comparisonFile(working, path: path)
        XCTAssertEqual(workingDocument.base.bytes, original); XCTAssertEqual(workingDocument.destination.bytes, changed)
        let marked = try await repo.preparedPathComparison(from: .revision(tree), fromPath: path, to: .revision(snapshotTree), toPath: path)
        let markedDocument = try await repo.comparisonFile(marked, path: path)
        XCTAssertEqual(markedDocument.base.bytes, original); XCTAssertEqual(markedDocument.destination.bytes, original)
        let external = try await repo.historicalWorkingFileComparison(revision: tree, path: path, workingFile: root.appendingPathComponent(literal))
        let externalDocument = try await repo.comparisonFile(external)
        XCTAssertEqual(externalDocument.base.bytes, Data([0xff, 0x85, 0, 10])); XCTAssertEqual(externalDocument.destination.bytes, original)
        let saved = try await repo.historicalFile(revision: newer, path: literal)
        XCTAssertEqual(saved.bytes, Data([0xff, 0x85, 0, 10])); XCTAssertEqual(saved.revision, .revision(newer))
        let commit = try await repo.revisionComparison(from: .revision(first.objectID!), to: .revision(second.objectID!))
        XCTAssertEqual(commit.fromDetails?.isTree, false); XCTAssertFalse(commit.fromDetails?.author.isEmpty ?? true)
        let blob = try XCTUnwrap(first.entries.first { $0.path == path }?.objectID)
        for invalid in [blob, "--help", "missing-snapshot"] {
            do { _ = try await repo.revisionComparison(from: .revision(invalid), to: .workingTree); XCTFail("Non-tree object accepted") } catch {}
            do { _ = try await repo.preparedPathComparison(from: .revision(invalid), fromPath: path, to: .workingTree, toPath: path); XCTFail("Non-tree mark accepted") } catch {}
        }
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.revisionComparison(from: .revision(tree), to: .workingTree, cancellation: token); XCTFail("Cancelled tree read accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, second.objectID)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), changed)
    }
    func testLiteralTreeEntriesModesAndExactBlobContents() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "folder: 雪", filename = "tab\tand\nnewline.bin"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        let binary = Data([0, 255, 13, 10])
        try binary.write(to: root.appendingPathComponent(folder + "/" + filename))
        try Data("echo QA\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/missing/target")
        try Data("literal".utf8).write(to: root.appendingPathComponent(":(glob)*.txt"))
        try await repo.stage([folder, "run.sh", "link", ":(glob)*.txt"])
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + ",module"])
        _ = try await repo.commit(message: "browser entries")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.browseRepository()
        XCTAssertEqual(snapshot.entries.first { $0.name == folder }?.kind, .directory)
        let module = try XCTUnwrap(snapshot.entries.first { $0.name == "module" })
        XCTAssertEqual(module.kind, .submodule)
        let description = try await repo.repositoryBrowserFile(snapshot, entry: module)
        XCTAssertEqual(description.path, "module.txt")
        XCTAssertEqual(description.bytes, Data(("Subproject commit " + previous).utf8))
        XCTAssertEqual(snapshot.entries.first { $0.name == "run.sh" }?.kind, .executable)
        let link = try XCTUnwrap(snapshot.entries.first { $0.name == "link" })
        XCTAssertEqual(link.kind, .symlink)
        let target = try await repo.repositoryBrowserFile(snapshot, entry: link)
        XCTAssertEqual(target.bytes, Data("/missing/target".utf8))
        let children = try await repo.browseRepositoryDirectory(snapshot, directory: folder)
        let file = try XCTUnwrap(children.entries.first)
        XCTAssertEqual(file.name, filename); XCTAssertEqual(file.size, 4); XCTAssertEqual(file.fileExtension, ".bin")
        let content = try await repo.repositoryBrowserFile(children, entry: file)
        XCTAssertEqual(content.bytes, binary)
        do { _ = try await repo.repositoryBrowserFile(snapshot, entry: file); XCTFail("Foreign directory entry accepted") } catch is RepositoryBrowserFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testPinnedDirectoryDoesNotFollowMovedReference() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("old".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"]); _ = try await repo.commit(message: "old tree")
        let first = try await repo.browseRepository()
        try Data("new".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"]); _ = try await repo.commit(message: "new tree")
        let pinned = try await repo.browseRepositoryDirectory(first, directory: "nested")
        let old = try await repo.repositoryBrowserFile(pinned, entry: XCTUnwrap(pinned.entries.first))
        XCTAssertEqual(old.bytes, Data("old".utf8))
        let latest = try await repo.browseRepository(directory: "nested")
        let new = try await repo.repositoryBrowserFile(latest, entry: XCTUnwrap(latest.entries.first))
        XCTAssertEqual(new.bytes, Data("new".utf8)); XCTAssertNotEqual(first.objectID, latest.objectID)
        for path in ["../nested", "/nested", "nested//child", "nested/file.txt", "missing"] {
            do { _ = try await repo.browseRepositoryDirectory(first, directory: path); XCTFail("Invalid directory accepted: " + path) } catch {}
        }
    }
    func testBareTagsTreesAndUnbornHead() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "-a", "browser-tag", "-m", "annotated"])
        let tagged = try await repo.browseRepository(revision: "browser-tag")
        let tree = try XCTUnwrap(tagged.treeID)
        let treeSnapshot = try await repo.browseRepository(revision: tree)
        XCTAssertEqual(treeSnapshot.entries, tagged.entries)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = try await GitRepository(root: bareRoot).browseRepository()
        XCTAssertTrue(bare.bare); XCTAssertEqual(bare.entries, tagged.entries)
        let emptyRoot = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: false)
        let emptyRepo = GitRepository(root: emptyRoot); _ = try await emptyRepo.run(["init"])
        let empty = try await emptyRepo.browseRepository()
        XCTAssertTrue(empty.entries.isEmpty); XCTAssertNil(empty.objectID)
        for invalid in ["missing-revision", "--help", tagged.entries.first { $0.kind == .file }!.objectID] {
            do { _ = try await repo.browseRepository(revision: invalid); XCTFail("Non-tree revision accepted") } catch {}
        }
    }
    func testRevertSupportsSHA256PinnedCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBrowserSHA256-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "--object-format=sha256", "--initial-branch=main"])
        _ = try await repo.run(["config", "user.name", "Browser QA"]); _ = try await repo.run(["config", "user.email", "browser@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgSign", "false"])
        let path = ":(glob)* 雪.bin", bytes = Data([0, 255, 10])
        try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "first")
        let snapshot = try await repo.browseRepository(), entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(snapshot.objectID?.count, 64); XCTAssertEqual(entry.objectID.count, 64)
        XCTAssertEqual(snapshot.acceptedBackend?.enabled,false,"SHA-256 Browser must explicitly retain its CLI engine extension")
        let directory=try await repo.browseRepositoryDirectory(snapshot,directory:"")
        XCTAssertEqual(directory.acceptedBackend?.enabled,false);XCTAssertEqual(directory.objectID,snapshot.objectID)
        let pinned=try await repo.repositoryBrowserFile(directory,entry:entry)
        XCTAssertEqual(pinned.bytes,bytes);XCTAssertEqual(pinned.revision,.revision(snapshot.objectID!))
        try Data("second".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "second")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try Data("local edits".utf8).write(to: root.appendingPathComponent(path))
        try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let indexed = try await repo.run(["show", ":" + path]).stdout, finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(indexed, bytes); XCTAssertEqual(finalHead, head)
    }
    func testRevertRestoresPinnedBytesModesAndIndexWithoutMovingHead() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = ":(glob)*.bin", binary = Data([0, 255, 10, 13])
        try binary.write(to: root.appendingPathComponent(name))
        try Data("old executable\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "old-target")
        try await repo.stage([name, "run.sh", "link"]); _ = try await repo.commit(message: "original browser files")
        _ = try await repo.run(["tag", "-a", "restore-tag", "-m", "original"])
        let snapshot = try await repo.browseRepository(revision: "restore-tag")
        try Data("new bytes".utf8).write(to: root.appendingPathComponent(name))
        try Data("new executable\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "new-target")
        try await repo.stage([name, "run.sh", "link"]); _ = try await repo.commit(message: "new browser files")
        // The named tag moves, but the displayed selection must still restore the old blob.
        _ = try await repo.run(["tag", "-f", "restore-tag", "HEAD"])
        try Data("uncommitted".utf8).write(to: root.appendingPathComponent(name))
        try Data("unrelated staged".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        try await repo.stage(["unrelated.txt"])
        let unrelated = try await repo.run(["ls-files", "--stage", "--", "unrelated.txt"]).stdout
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for path in [name, "run.sh", "link"] {
            let entry = try XCTUnwrap(snapshot.entries.first { $0.path == path })
            try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
            let indexed = try await repo.run(["ls-files", "--stage", "--", path]).text
            XCTAssertTrue(indexed.hasPrefix(entry.mode + " " + entry.objectID + " 0\t"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), binary)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "old-target")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o111, 0o111)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalUnrelated = try await repo.run(["ls-files", "--stage", "--", "unrelated.txt"]).stdout
        XCTAssertEqual(finalHead, head); XCTAssertEqual(finalUnrelated, unrelated)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unrelated.txt")), Data("unrelated staged".utf8))
    }
    func testRevertRejectsForeignFoldersSubmodulesBareAndEscapedAncestors() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("historical".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + head + ",module"])
        _ = try await repo.commit(message: "browser rejection fixture")
        let snapshot = try await repo.browseRepository()
        let nested = try await repo.browseRepositoryDirectory(snapshot, directory: "nested")
        let file = try XCTUnwrap(nested.entries.first)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let ordinary = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        for invalid in ["--force", "HEAD", "", "1234"] {
            let forged = RepositoryBrowserSnapshot(root: snapshot.root, revision: snapshot.revision, objectID: invalid, treeID: snapshot.treeID, directory: snapshot.directory, bare: false, entries: snapshot.entries)
            do { try await repo.revertRepositoryBrowserFile(forged, entry: ordinary); XCTFail("Unpinned object accepted") } catch RepositoryBrowserFailure.selection {}
        }
        for entry in snapshot.entries.filter({ [.directory, .submodule].contains($0.kind) }) {
            do { try await repo.revertRepositoryBrowserFile(snapshot, entry: entry); XCTFail("Unsupported kind restored") } catch is RepositoryBrowserFailure {}
        }
        do { try await repo.revertRepositoryBrowserFile(snapshot, entry: file); XCTFail("Foreign entry restored") } catch is RepositoryBrowserFailure {}
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bareRepo = GitRepository(root: bareRoot, executable: repo.executable), bare = try await bareRepo.browseRepository(directory: "nested")
        do { try await bareRepo.revertRepositoryBrowserFile(bare, entry: XCTUnwrap(bare.entries.first)); XCTFail("Bare restored") } catch is RepositoryBrowserFailure {}
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBrowserOutside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside must remain".utf8).write(to: outside.appendingPathComponent("file.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("nested").path, withDestinationPath: outside.path)
        do { try await repo.revertRepositoryBrowserFile(nested, entry: file); XCTFail("Escaped ancestor restored") } catch is WorkingFileRestoreFailure {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file.txt")), Data("outside must remain".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testRevertLockFailureLeavesFileAndIndexUnchangedThenCanResume() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await repo.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        let location = root.appendingPathComponent(entry.path), lock = root.appendingPathComponent(".git/index.lock")
        try Data("working stays on failure".utf8).write(to: location)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data().write(to: lock)
        do { try await repo.revertRepositoryBrowserFile(snapshot, entry: entry); XCTFail("Index lock ignored") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: location), Data("working stays on failure".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try FileManager.default.removeItem(at: lock)
        try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
        let original = try await repo.repositoryBrowserFile(snapshot, entry: entry)
        XCTAssertEqual(try Data(contentsOf: location), original.bytes)
    }
    func testExportPreservesPinnedRecursiveNamesBytesAndSkipsGitlinks() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "folder 雪", nested = folder + "/nested", name = ":(glob)*\tline\n.bin"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(nested), withIntermediateDirectories: true)
        let binary = Data([0, 255, 13, 10])
        try binary.write(to: root.appendingPathComponent(nested + "/" + name))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(folder + "/link").path, withDestinationPath: "/outside/must-not-follow")
        try await repo.stage([folder])
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + "," + folder + "/module"])
        _ = try await repo.commit(message: "export old folder")
        let snapshot = try await repo.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path == folder })
        try Data("current must not export".utf8).write(to: root.appendingPathComponent(nested + "/" + name))
        try await repo.stage([folder]); _ = try await repo.commit(message: "advance export source")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let export = try await repo.exportRepositoryBrowser(snapshot, entry: entry, backend: GitLibGit2Configuration())
        defer { export.discard() }
        XCTAssertEqual(export.item.lastPathComponent, folder); XCTAssertEqual(export.fileCount, 2)
        XCTAssertEqual(try Data(contentsOf: export.item.appendingPathComponent("nested/" + name)), binary)
        let link = export.item.appendingPathComponent("link")
        XCTAssertEqual(try Data(contentsOf: link), Data("/outside/must-not-follow".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.item.appendingPathComponent("module").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(nested + "/" + name)), Data("current must not export".utf8))
        let listing = try await repo.browseRepositoryDirectory(snapshot, directory: nested)
        let file = try XCTUnwrap(listing.entries.first)
        let single = try await repo.exportRepositoryBrowser(listing, entry: file, backend: GitLibGit2Configuration())
        XCTAssertEqual(single.item.lastPathComponent, name); XCTAssertEqual(try Data(contentsOf: single.item), binary)
        single.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: single.directory.path))
        let directory = try await repo.exportRepositoryBrowser(listing, backend: GitLibGit2Configuration())
        defer { directory.discard() }
        XCTAssertEqual(directory.item.lastPathComponent, "nested")
        XCTAssertEqual(try Data(contentsOf: directory.item.appendingPathComponent(name)), binary)
    }
    func testExportRejectsForeignGitlinkAndCancelledSelection() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + ",module"])
        _ = try await repo.commit(message: "export gitlink rejection")
        let snapshot = try await repo.browseRepository(), module = try XCTUnwrap(snapshot.entries.first { $0.kind == .submodule })
        do { _ = try await repo.exportRepositoryBrowser(snapshot, entry: module, backend: GitLibGit2Configuration()); XCTFail("Gitlink exported as ordinary file") } catch is RepositoryBrowserFailure {}
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.exportRepositoryBrowser(snapshot, cancellation: cancellation, backend: GitLibGit2Configuration()); XCTFail("Cancelled export continued") } catch is OperationCancellationFailure {}
        let file = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        let foreign = RepositoryBrowserEntry(path: file.path, name: file.name, mode: file.mode, objectID: String(repeating: "f", count: 40), size: file.size)
        do { _ = try await repo.exportRepositoryBrowser(snapshot, entry: foreign, backend: GitLibGit2Configuration()); XCTFail("Foreign blob exported") } catch is RepositoryBrowserFailure {}
    }
    func testCancellationReachesEveryBrowserOperationWithoutMutatingRepository() async throws {
        let (root,repo,_) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
        try Data("nested bytes\n".utf8).write(to:root.appendingPathComponent("nested/file"))
        try await repo.stage(["nested/file"]); _ = try await repo.commit(message:"Nested")
        let snapshot=try await repo.browseRepository(), nested=try await repo.browseRepositoryDirectory(snapshot,directory:"nested")
        let entry=try XCTUnwrap(nested.entries.first), token=OperationCancellation();token.cancel()
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent("nested/file"))
        do { _ = try await repo.browseRepository(cancellation:token);XCTFail("Root cancellation lost") } catch is OperationCancellationFailure {}
        do { _ = try await repo.browseRepositoryDirectory(snapshot,directory:"nested",cancellation:token);XCTFail("Directory cancellation lost") } catch is OperationCancellationFailure {}
        do { _ = try await repo.repositoryBrowserFile(nested,entry:entry,cancellation:token);XCTFail("Blob cancellation lost") } catch is OperationCancellationFailure {}
        do { try await repo.revertRepositoryBrowserFile(nested,entry:entry,cancellation:token);XCTFail("Restore cancellation lost") } catch is OperationCancellationFailure {}
        do { _ = try await repo.exportRepositoryBrowser(nested,cancellation:token, backend: GitLibGit2Configuration());XCTFail("Export cancellation lost") } catch is OperationCancellationFailure {}
        do { _ = try await repo.repositoryBrowserSubmodule(nested,entry:entry,cancellation:token);XCTFail("Submodule cancellation lost") } catch is OperationCancellationFailure {}
        do { _ = try await repo.submoduleComparison(path:entry.path,cancellation:token);XCTFail("Child cancellation lost") } catch is OperationCancellationFailure {}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(head,afterHead);XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")));XCTAssertEqual(file,try Data(contentsOf:root.appendingPathComponent("nested/file")))
    }

    func testNativeColumnsNormalizeAndPersistIndependentLayout() throws {
        let suite="TurtleGit.Browser.Columns.QA."+UUID().uuidString,preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { preferences.removePersistentDomain(forName:suite) }
        XCTAssertEqual(RepositoryBrowserColumns.load(preferences),RepositoryBrowserColumns())
        let value=RepositoryBrowserColumns(visible:["size","foreign"],order:["size","size","foreign","extension"],widths:["name":350,"extension":Double.infinity,"size":20000,"foreign":50])
        XCTAssertEqual(value.visible,["name","size"]);XCTAssertEqual(value.order,["size","extension","name"]);XCTAssertEqual(value.widths,["name":350,"size":10000])
        value.save(preferences);XCTAssertEqual(RepositoryBrowserColumns.load(preferences),value)
        XCTAssertNil(preferences.object(forKey:"Commit.FileColumns"))
        preferences.set(5,forKey:"RepositoryBrowser.Columns.Version");XCTAssertEqual(RepositoryBrowserColumns.load(preferences),RepositoryBrowserColumns())
    }

    func testSortingAndMalformedTreeRecords() throws {
        let oid = String(repeating: "a", count: 40)
        let bytes = Data(("100644 blob " + oid + " 20\tfile2.txt\0" + "040000 tree " + oid + " -\tfolder\0" + "100644 blob " + oid + " 1\tfile10.txt\0").utf8)
        let entries = try RepositoryBrowserListing.parse(bytes, directory: "")
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries).map(\.name), ["folder", "file2.txt", "file10.txt"])
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries, descending: true).map(\.name), ["folder", "file10.txt", "file2.txt"])
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries, by: .fileExtension).map(\.name), ["folder", "file10.txt", "file2.txt"])
        for malformed in ["100644 blob " + oid + " 3\tx", "100644 blob " + oid + " -\tx\0", "040000 blob " + oid + " -\tx\0", "100644 blob " + oid + " 3\t../x\0"] {
            XCTAssertThrowsError(try RepositoryBrowserListing.parse(Data(malformed.utf8), directory: ""))
        }
    }
}
