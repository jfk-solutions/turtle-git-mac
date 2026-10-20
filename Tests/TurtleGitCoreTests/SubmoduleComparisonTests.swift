import XCTest
@testable import TurtleGitCore

final class SubmoduleComparisonTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, GitRepository, String, String) {
        let (root, parent, _) = try await GitPatchTests().fixture()
        let path = ":(glob)* module, 雪\ncheckout"
        let location = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let child = GitRepository(root: location)
        _ = try await child.run(["init", "-b", "main"])
        _ = try await child.run(["config", "user.name", "QA"])
        _ = try await child.run(["config", "user.email", "qa@example.invalid"])
        try Data("base\n".utf8).write(to: location.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "child base 雪")
        let hash = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + path])
        _ = try await parent.commit(message: "attach child")
        return (root, parent, child, path, hash)
    }

    func testCapturedChildAncestryEngineAndPreparedRepositoryPreserveConfiguration() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("ancestry-helper"), reply = root.appendingPathComponent("ancestry-reply"), log = root.appendingPathComponent("ancestry-log")
        var wire = Data()
        let frames: [[String: Any]] = [["kind":"header", "operation":"mergeBase"], ["kind":"mergeBase", "base":base, "fastForward":true], ["kind":"end", "count":1]]
        for value in frames {
            wire.append(Data("TurtleGit Inspection v1:".utf8)); wire.append(try JSONSerialization.data(withJSONObject:value).base64EncodedData()); wire.append(10)
        }
        try wire.write(to:reply)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log.path)'\ncat '\(reply.path)'\n".utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let config = GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.mergeBase.mask,helperURL:helper)
        let captured = GitRepository(root:root,executable:parent.executable,askpass:parent.askpass,diffDetection:parent.diffDetection,libgit2Configuration:config)
        let working = try await captured.submoduleWorkingRepository(path:path)
        XCTAssertEqual(working.libgit2Configuration?.helperURL,helper); XCTAssertEqual(working.executable,parent.executable)
        // Identical objects do not require an ancestry helper at all.
        let identical = try await captured.submoduleComparison(path:path,from:"HEAD",to:"HEAD")
        XCTAssertEqual(identical.change,.identical); XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
        _ = try await child.run(["commit","--allow-empty","-m","next"])
        let comparison = try await captured.submoduleComparison(path:path)
        XCTAssertEqual(comparison.change,.fastForward)
        let arguments = try String(contentsOf:log,encoding:.utf8)
        XCTAssertTrue(arguments.contains(child.root.path)); XCTAssertTrue(arguments.contains("turtlegit-merge-base"))
        let prepared = try await captured.prepareSubmoduleComparison(comparison,action:.logTo)
        XCTAssertEqual(prepared.repository.libgit2Configuration?.helperURL,helper)
        XCTAssertEqual(prepared.repository.libgit2Configuration?.mask,config.mask)
        // A selected helper failure is not converted into a timestamp classification.
        try Data("#!/bin/sh\nexit 23\n".utf8).write(to:helper)
        do { _ = try await captured.submoduleComparison(path:path); XCTFail("Selected ancestry failure was hidden") } catch is GitFailure {}
        let token = OperationCancellation(); token.cancel()
        do { _ = try await captured.submoduleComparison(path:path,cancellation:token); XCTFail("Cancellation was hidden") } catch is OperationCancellationFailure {}
    }

    func testHistoricalGitlinksPreserveCanonicalByteIdentityUnderPrecomposition() async throws {
        let (root, parent, child, _, first) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("second\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"]); _ = try await child.commit(message: "second")
        let second = try await child.rebaseCommit("HEAD").hash
        let names = ["module-é", "module-e\u{301}"]
        for (name, hash) in zip(names, [first, second]) { _ = try await parent.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "160000," + hash + "," + name]) }
        _ = try await parent.commit(message: "canonical gitlinks"); _ = try await parent.run(["config", "core.precomposeunicode", "true"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for (name, hash) in zip(names, [first, second]) {
            let details = try await parent.submoduleComparison(path: name, from: "HEAD", to: "HEAD")
            XCTAssertEqual(details.from.revision, hash); XCTAssertEqual(details.to.revision, hash)
            XCTAssertEqual(Array(details.path.utf8), Array(name.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

    func testWorkingAndStagingStatisticsRetainAddedModifiedAndDeletedGitlinkModes() async throws {
        let (root,parent,child,path,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await parent.run(["reset","--soft","HEAD~1"])
        var index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let added=try await parent.workingTreeFiles(),stagedAddition=try await parent.stagingFiles(staged:true)
        XCTAssertTrue(added.first {$0.path==path}?.isSubmodule == true);XCTAssertEqual(stagedAddition.first {$0.path==path}?.action,"A");XCTAssertTrue(stagedAddition.first {$0.path==path}?.isSubmodule == true)
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        _ = try await parent.commit(message:"reattach child")
        try Data("new module bytes\n".utf8).write(to:child.root.appendingPathComponent("file.txt"));try await child.stage(["file.txt"]);_ = try await child.commit(message:"new child")
        index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let modified=try await parent.workingTreeFiles(),unstaged=try await parent.stagingFiles(staged:false)
        XCTAssertTrue(modified.first {$0.path==path}?.isSubmodule == true);XCTAssertTrue(unstaged.first {$0.path==path}?.isSubmodule == true)
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        try await parent.stage([path]);let staged=try await parent.stagingFiles(staged:true)
        XCTAssertTrue(staged.first {$0.path==path}?.isSubmodule == true)
        _ = try await parent.run(["rm","--cached","-f","--",path])
        index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let deleted=try await parent.workingTreeFiles(),stagedDeletion=try await parent.stagingFiles(staged:true)
        XCTAssertEqual(stagedDeletion.first {$0.path==path}?.action,"D");XCTAssertTrue(stagedDeletion.first {$0.path==path}?.isSubmodule == true);XCTAssertTrue(deleted.first {$0.path==path}?.isSubmodule == true)
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        XCTAssertEqual(try Data(contentsOf:child.root.appendingPathComponent("file.txt")),Data("new module bytes\n".utf8))
    }

    func testWorkingSubmoduleHistoryResolvesChildAndRefusesParentFallbackAndCancellation() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let resolved = try await parent.submoduleWorkingRepository(path: path)
        XCTAssertEqual(resolved.root, child.root); XCTAssertEqual(resolved.executable, parent.executable)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await parent.submoduleWorkingRepository(path: path, cancellation: token); XCTFail("Cancelled child lookup ran") } catch is OperationCancellationFailure {}
        try FileManager.default.removeItem(at: child.root.appendingPathComponent(".git"))
        do { _ = try await parent.submoduleWorkingRepository(path: path); XCTFail("Uninitialized checkout discovered parent repository") } catch is SubmoduleWorkingHistoryFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testCommitDirtySubmoduleWarningsFollowSourceAndPreserveRepositories() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings = try await parent.commitDirtySubmodules(paths: [path])
        XCTAssertTrue(warnings.isEmpty)
        // Untracked-only changes are ignored for an existing gitlink, like diff.
        try Data("untracked".utf8).write(to: child.root.appendingPathComponent("untracked"))
        warnings = try await parent.commitDirtySubmodules(paths: [path]); XCTAssertTrue(warnings.isEmpty)
        try Data("dirty".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        let parentIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let childIndex = try Data(contentsOf: child.root.appendingPathComponent(".git/index"))
        warnings = try await parent.commitDirtySubmodules(paths: [path, path, "file.txt"])
        XCTAssertEqual(warnings.map(\.path), [path]); XCTAssertEqual(warnings.first?.checkout, child.root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), parentIndex)
        XCTAssertEqual(try Data(contentsOf: child.root.appendingPathComponent(".git/index")), childIndex)
        try await child.stage(["file.txt"])
        warnings = try await parent.commitDirtySubmodules(paths: [path]); XCTAssertEqual(warnings.count, 1)
        _ = try await child.commit(message: "new child commit")
        warnings = try await parent.commitDirtySubmodules(paths: [path]); XCTAssertTrue(warnings.isEmpty, "New child commits are not dirty files")
        try FileManager.default.removeItem(at: child.root.appendingPathComponent("untracked"))
        // An unversioned nested repository does include untracked children.
        _ = try await parent.run(["update-index", "--force-remove", "--", path])
        try Data("untracked".utf8).write(to: child.root.appendingPathComponent("untracked"))
        warnings = try await parent.commitDirtySubmodules(paths: [path]); XCTAssertEqual(warnings.count, 1)
        _ = try await parent.run(["config", "diff.ignoreSubmodules", "all"])
        let hash = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + path])
        try Data("dirty again".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        warnings = try await parent.commitDirtySubmodules(paths: [path]); XCTAssertTrue(warnings.isEmpty, "Respect source diff configuration")
        do { _ = try await parent.commitDirtySubmodules(paths: ["../escape"]); XCTFail("Unsafe path accepted") } catch is WorkingFileRestoreFailure {}
    }

    func testBrowserSubmoduleResolutionPinsChildHistoryWithoutWrites() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await parent.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path == path })
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "new child must not be shown")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + next + "," + path])
        _ = try await parent.commit(message: "advance gitlink")
        try Data("child staged\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
        try Data("child working\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        let parentIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let childIndex = try Data(contentsOf: child.root.appendingPathComponent(".git/index"))
        let details = try await parent.repositoryBrowserSubmodule(snapshot, entry: entry)
        XCTAssertEqual(details.checkout, child.root); XCTAssertEqual(details.from.revision, base)
        XCTAssertTrue(details.from.canShowLog); XCTAssertEqual(details.from.subject, "child base 雪")
        var options = HistoryOptions(); options.endRevision = entry.objectID
        let history = try await child.history(options: options)
        XCTAssertEqual(history.first?.hash, base)
        XCTAssertFalse(history.contains { $0.hash == next })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), parentIndex)
        XCTAssertEqual(try Data(contentsOf: child.root.appendingPathComponent(".git/index")), childIndex)
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("file.txt")), "child working\n")
        let childHead = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(childHead, next)
        let ordinary = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        do { _ = try await parent.repositoryBrowserSubmodule(snapshot, entry: ordinary); XCTFail("Ordinary file treated as child repository") } catch is RepositoryBrowserFailure {}
    }
    func testBrowserSubmoduleUnavailableAndBareDoNotFetchOrInitialize() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await parent.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path == path })
        try FileManager.default.removeItem(at: child.root)
        try FileManager.default.createDirectory(at: child.root, withIntermediateDirectories: false)
        let missing = try await parent.repositoryBrowserSubmodule(snapshot, entry: entry)
        XCTAssertNil(missing.checkout); XCTAssertEqual(missing.from.revision, base); XCTAssertFalse(missing.from.canShowLog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.root.appendingPathComponent(".git").path))
        _ = try await child.run(["init", "-b", "main"])
        try Data("unrelated\n".utf8).write(to: child.root.appendingPathComponent("other.txt")); try await child.stage(["other.txt"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "unrelated child"])
        let unavailable = try await parent.repositoryBrowserSubmodule(snapshot, entry: entry)
        XCTAssertEqual(unavailable.checkout, child.root); XCTAssertFalse(unavailable.from.available)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await parent.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bareRepo = GitRepository(root: bareRoot), bare = try await bareRepo.browseRepository()
        let bareEntry = try XCTUnwrap(bare.entries.first { $0.kind == .submodule })
        do { _ = try await bareRepo.repositoryBrowserSubmodule(bare, entry: bareEntry); XCTFail("Bare child resolution attempted") } catch is RepositoryBrowserFailure {}
    }
    func testSubmoduleRootDiscoveryIgnoresPreexistingURLDirectoryBitWithoutChangingOwnership() async throws {
        let (root, parent, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = "module root"
        // Match CLI/Finder URLs constructed while the checkout does not exist.
        let selected = FileTransferPaths.fileURL(root.appendingPathComponent(path).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let child = GitRepository(root: selected)
        _ = try await child.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await child.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: selected.appendingPathComponent("file")); try await child.stage(["file"]); _ = try await child.commit(message: "child base")
        let hash = try await child.rebaseCommit("HEAD").hash
        try Data("[submodule \"child\"]\n\tpath = module root\n\turl = ./unused\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        try await parent.stage([".gitmodules"])
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + path]); _ = try await parent.commit(message: "attach child")
        let directoryURL = URL(fileURLWithPath: selected.path, isDirectory: true)
        XCTAssertNotEqual(selected, directoryURL, "Fixture must exercise differing URL directory bits")
        let parentIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), childIndex = try Data(contentsOf: selected.appendingPathComponent(".git/index"))
        for action in [RepositoryAction.diff, .revert, .submoduleUpdate, .submoduleSync, .rename, .move, .remove, .logSubmodule] {
            let owner = try await child.discoverSelectionRoot(for: action, selected: selected)
            XCTAssertTrue(GitReferenceName.equal(owner.path, parent.root.path), action.rawValue)
        }
        let statusOwner = try await child.discoverSelectionRoot(for: .status, selected: selected)
        let fileOwner = try await child.discoverSelectionRoot(for: .diff, selected: selected.appendingPathComponent("file"))
        XCTAssertTrue(GitReferenceName.equal(statusOwner.path, child.root.path)); XCTAssertTrue(GitReferenceName.equal(fileOwner.path, child.root.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), parentIndex)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git/index")), childIndex)
        // Parent discovery must still require an indexed gitlink, not merely a
        // nested initialized repository or a former URL's directory identity.
        _ = try await parent.run(["update-index", "--force-remove", "--", path])
        let unlinkedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let withoutGitlink = try await child.discoverSelectionRoot(for: .diff, selected: selected)
        XCTAssertTrue(GitReferenceName.equal(withoutGitlink.path, child.root.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), unlinkedIndex)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git/index")), childIndex)
    }

    func testWorkingComparisonUsesChildHeadAndDirtyStateWithoutWrites() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored.txt\n".utf8).write(to: child.root.appendingPathComponent(".git/info/exclude"))
        try Data("ignored local\n".utf8).write(to: child.root.appendingPathComponent("ignored.txt"))
        let owner = try await child.discoverSelectionRoot(for: .diff, selected: child.root)
        XCTAssertEqual(owner, parent.root)
        let childOwner = try await child.discoverSelectionRoot(for: .diff, selected: child.root.appendingPathComponent("file.txt"))
        XCTAssertEqual(childOwner, child.root)
        let history = try await parent.history(options: HistoryOptions())
        let entry = try XCTUnwrap(history.first)
        let files = try await parent.files(in: entry)
        XCTAssertTrue(files.first(where: { $0.path == path })?.isSubmodule == true)
        do { _ = try await parent.historicalFile(revision: entry.hash, path: path); XCTFail("Gitlinks are not file exports") } catch RevisionComparisonFailure.selection {}
        let clean = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(clean.change, .identical); XCTAssertFalse(clean.dirty)
        XCTAssertEqual(clean.from.subject, "child base 雪"); XCTAssertEqual(clean.to.revision, base)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "child next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("staged\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
        try Data("later local\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: child.root.appendingPathComponent("new.txt"))
        let parentIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let childIndex = try Data(contentsOf: child.root.appendingPathComponent(".git/index"))
        let parentHead = try await parent.run(["rev-parse", "HEAD"]).stdout
        let comparison = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(comparison.change, .fastForward); XCTAssertTrue(comparison.dirty)
        XCTAssertEqual(comparison.from.revision, base); XCTAssertEqual(comparison.to.revision, next)
        XCTAssertTrue(comparison.from.canShowLog); XCTAssertTrue(comparison.to.canShowLog)
        XCTAssertTrue(comparison.toWorkingTree); XCTAssertEqual(comparison.checkout, child.root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), parentIndex)
        XCTAssertEqual(try Data(contentsOf: child.root.appendingPathComponent(".git/index")), childIndex)
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("file.txt")), "later local\n")
        let after = try await parent.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, parentHead)
    }

    func testEmptyComparisonSidesAndReverseWorkingCheckout() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try await parent.submoduleComparison(path: path, from: "", to: "HEAD")
        XCTAssertNil(added.from.revision); XCTAssertEqual(added.to.revision, base); XCTAssertEqual(added.change, .newSubmodule)
        let deleted = try await parent.submoduleComparison(path: path, from: "HEAD", to: "")
        XCTAssertEqual(deleted.from.revision, base); XCTAssertNil(deleted.to.revision); XCTAssertEqual(deleted.change, .deleteSubmodule)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let reverse = try await parent.submoduleComparison(path: path, from: "Working tree", to: "HEAD")
        XCTAssertEqual(reverse.from.revision, next); XCTAssertEqual(reverse.to.revision, base); XCTAssertEqual(reverse.change, .rewind)
    }

    func testHistoricalGitlinksAreIndependentOfCheckoutAndCanRewind() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await parent.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + next + "," + path]); _ = try await parent.commit(message: "advance child")
        _ = try await child.run(["checkout", "--detach", base])
        let rewind = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(rewind.change, .rewind); XCTAssertEqual(rewind.from.revision, next); XCTAssertEqual(rewind.to.revision, base)
        try Data("untracked\n".utf8).write(to: child.root.appendingPathComponent("new.txt"))
        let historical = try await parent.submoduleComparison(path: path, from: before, to: "HEAD")
        XCTAssertEqual(historical.change, .fastForward); XCTAssertFalse(historical.dirty)
        XCTAssertFalse(historical.toWorkingTree); XCTAssertEqual(historical.from.revision, base); XCTAssertEqual(historical.to.revision, next)
        let unchanged = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(unchanged, base)
    }

    func testDivergentCommitTimesClassifyAllThreeCases() async throws {
        for (timestamp, expected) in [(1700000200, SubmoduleChangeType.newerTime), (1700000000, .olderTime), (1700000100, .sameTime)] {
            let (root, parent, child, path, base) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("left\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
            _ = try await child.run(["commit", "-m", "left"], environmentOverrides: ["GIT_AUTHOR_DATE":"1700000100 +0000", "GIT_COMMITTER_DATE":"1700000100 +0000"])
            let left = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            _ = try await parent.run(["update-index", "--cacheinfo", "160000," + left + "," + path]); _ = try await parent.commit(message: "left child")
            _ = try await child.run(["checkout", "--detach", base])
            try Data("right\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
            _ = try await child.run(["commit", "-m", "right"], environmentOverrides: ["GIT_AUTHOR_DATE":"\(timestamp) +0000", "GIT_COMMITTER_DATE":"\(timestamp) +0000"])
            let comparison = try await parent.submoduleComparison(path: path)
            XCTAssertEqual(comparison.change, expected); XCTAssertEqual(comparison.from.subject, "left"); XCTAssertEqual(comparison.to.subject, "right")
        }
    }

    func testUninitializedAndMissingObjectsDisableMetadataAndLog() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: child.root)
        try FileManager.default.createDirectory(at: child.root, withIntermediateDirectories: false)
        let uninitialized = try await parent.submoduleComparison(path: path)
        XCTAssertNil(uninitialized.checkout); XCTAssertFalse(uninitialized.dirty); XCTAssertEqual(uninitialized.change, .unknown)
        XCTAssertFalse(uninitialized.from.canShowLog); XCTAssertFalse(uninitialized.to.canShowLog)
        XCTAssertEqual(uninitialized.from.subject, "not initialized")
        _ = try await child.run(["init", "-b", "main"])
        try Data("other\n".utf8).write(to: child.root.appendingPathComponent("other.txt")); try await child.stage(["other.txt"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "unrelated child"])
        let missing = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(missing.change, .unknown); XCTAssertFalse(missing.from.available)
        XCTAssertTrue(missing.to.available); XCTAssertTrue(missing.to.canShowLog)
    }

    func testAdditionDeletionAndUnsupportedOrEscapingPaths() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyTree = try await parent.run(["mktree"]).text.trimmingCharacters(in: .newlines)
        let initial = try await parent.submoduleComparison(path: path, from: emptyTree)
        XCTAssertEqual(initial.change, .newSubmodule)
        let added = try await parent.submoduleComparison(path: path, from: "HEAD^")
        XCTAssertEqual(added.change, .newSubmodule); XCTAssertNil(added.from.revision); XCTAssertFalse(added.from.canShowLog)
        let attached = try await parent.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--force-remove", "--", path]); _ = try await parent.commit(message: "remove child")
        let deleted = try await parent.submoduleComparison(path: path, from: attached, to: "HEAD")
        XCTAssertEqual(deleted.change, .deleteSubmodule); XCTAssertNil(deleted.to.revision); XCTAssertFalse(deleted.to.canShowLog)
        do { _ = try await parent.submoduleComparison(path: "../escape"); XCTFail("Accepted outside path") } catch WorkingFileRestoreFailure.location {}
        do { _ = try await parent.submoduleComparison(path: "not a module"); XCTFail("Accepted unrelated path") } catch SubmoduleComparisonFailure.unsupported {}
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: child.root, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: child.root, withDestinationURL: outside)
        do { _ = try await parent.submoduleComparison(path: path, from: attached); XCTFail("Followed external checkout symlink") } catch SubmoduleComparisonFailure.unsafeCheckout {}
    }

    func testRevertResultPinsComparisonBeforeLaterSuperprojectCommit() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("advanced\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "advanced child")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let selected = try await parent.status().filter { $0.path == path }
        let result = try await parent.revertWorkingFiles(selected)
        XCTAssertEqual(result.submodulePaths, [path]); XCTAssertTrue(result.trashedFiles.isEmpty)
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + next + "," + path]); _ = try await parent.commit(message: "later superproject commit")
        let comparison = try await parent.submoduleComparison(path: path, from: result.comparisonRevision)
        XCTAssertEqual(comparison.from.revision, base); XCTAssertEqual(comparison.to.revision, next)
        XCTAssertEqual(comparison.change, .fastForward)
        let current = try await parent.submoduleComparison(path: path); XCTAssertEqual(current.change, .identical)
    }

    func testPreparedCommandsKeepDisplayedObjectsAfterRefsAdvanceAndDoNotWrite() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await parent.submoduleComparison(path: path, from: "", to: "HEAD")
        try Data("later\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "later")
        _ = try await parent.run(["update-index", "--force-remove", "--", path]); _ = try await parent.commit(message: "remove gitlink")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let childIndex = try Data(contentsOf: child.root.appendingPathComponent(".git/index"))
        let command = try await parent.prepareSubmoduleComparison(snapshot, action: .compareRevisions)
        if case .compare(.emptyTree, .revision(let hash)) = command.command { XCTAssertEqual(hash, base) } else { XCTFail("Retargeted displayed comparison") }
        let log = try await parent.prepareSubmoduleComparison(snapshot, action: .logTo)
        if case .log(let hash) = log.command { XCTAssertEqual(hash, base) } else { XCTFail("Lost pinned Log") }
        let working = try await parent.prepareSubmoduleComparison(snapshot, action: .compareWorkingTree)
        if case .compare(.emptyTree, .workingTree) = working.command {} else { XCTFail("Lost working comparison") }
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
        XCTAssertEqual(childIndex, try Data(contentsOf: child.root.appendingPathComponent(".git/index")))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await parent.prepareSubmoduleComparison(snapshot, action: .logTo, cancellation: token); XCTFail("Cancelled command ran") } catch is OperationCancellationFailure {}
        try FileManager.default.removeItem(at: child.root.appendingPathComponent(".git"))
        do { _ = try await parent.prepareSubmoduleComparison(snapshot, action: .logTo); XCTFail("Fell back to parent") } catch is SubmoduleWorkingHistoryFailure {}
    }

    func testConflictedIndexUsesConflictWorkflow() async throws {
        let (root, source, parent, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        do { _ = try await parent.submoduleComparison(path: path); XCTFail("Accepted unresolved index") } catch SubmoduleComparisonFailure.conflicted {}
    }
    func testPreparedWorkingGitlinksUseIndexInsteadOfSuperprojectHEAD() async throws {
        let (root,parent,child,path,base) = try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        try Data("first child advance\n".utf8).write(to:child.root.appendingPathComponent("file.txt"));try await child.stage(["file.txt"]);_ = try await child.commit(message:"indexed child")
        let indexed = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await parent.run(["update-index","--cacheinfo","160000," + indexed + "," + path])
        try Data("second child advance\n".utf8).write(to:child.root.appendingPathComponent("file.txt"));try await child.stage(["file.txt"]);_ = try await child.commit(message:"working child")
        let current = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("dirty working bytes\n".utf8).write(to:child.root.appendingPathComponent("file.txt"))
        let parentIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")),childIndex = try Data(contentsOf:child.root.appendingPathComponent(".git/index"))
        let head = try await parent.submoduleComparison(path:path),index = try await parent.submoduleComparison(path:path,fromIndex:true)
        XCTAssertEqual(head.from.revision,base);XCTAssertEqual(index.from.revision,indexed);XCTAssertEqual(index.to.revision,current)
        XCTAssertTrue(index.dirty);XCTAssertEqual(index.change,.fastForward)
        let prepared = try await parent.prepareSubmoduleComparison(index,action:.compareRevisions)
        guard case .compare(.revision(let from),.revision(let to)) = prepared.command else {return XCTFail("Index baseline lost")}
        XCTAssertEqual(from,indexed);XCTAssertEqual(to,current)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),parentIndex)
        XCTAssertEqual(try Data(contentsOf:child.root.appendingPathComponent(".git/index")),childIndex)
        XCTAssertEqual(try Data(contentsOf:child.root.appendingPathComponent("file.txt")),Data("dirty working bytes\n".utf8))
    }

    func testRenamedGitlinksRetainHistoricalOldPathAndReadOnlyDirectDiscovery() async throws {
        let (root,parent,child,old,base) = try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let before = try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),new = ":(literal) renamed 雪\nmodule"
        try FileManager.default.moveItem(at:child.root,to:root.appendingPathComponent(new))
        let moved = GitRepository(root:root.appendingPathComponent(new))
        _ = try await parent.run(["update-index","--force-remove","--",old]);_ = try await parent.run(["update-index","--add","--cacheinfo","160000," + base + "," + new])
        var index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let direct = try await parent.submoduleComparison(path:new)
        XCTAssertEqual(direct.from.revision,base,"Direct staged rename became an addition");XCTAssertEqual(direct.to.revision,base)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        try Data("new child\n".utf8).write(to:moved.root.appendingPathComponent("file.txt"));try await moved.stage(["file.txt"]);_ = try await moved.commit(message:"new child after move")
        let next = try await moved.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let working = try await parent.submoduleComparison(path:new,fromPath:old)
        XCTAssertEqual(working.from.revision,base);XCTAssertEqual(working.to.revision,next);XCTAssertEqual(working.change,.fastForward)
        _ = try await parent.run(["update-index","--cacheinfo","160000," + next + "," + new]);_ = try await parent.commit(message:"rename child")
        let after = try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let historical = try await parent.submoduleComparison(path:new,from:before,to:after,fromPath:old)
        XCTAssertEqual(historical.from.revision,base);XCTAssertEqual(historical.to.revision,next)
        XCTAssertEqual(historical.checkout,moved.root);XCTAssertFalse(historical.toWorkingTree)
        do {_ = try await parent.submoduleComparison(path:new,from:before,to:after,fromPath:"../escape");XCTFail("Unsafe historical path accepted")} catch is WorkingFileRestoreFailure {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

    func testIndexGitlinkBaselineDoesNotRequireHEADAndRetainsCancellation() async throws {
        let (root,parent,_,path,base) = try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await parent.run(["update-ref","-d","refs/heads/main"])
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let details = try await parent.submoduleComparison(path:path,fromIndex:true)
        XCTAssertEqual(details.from.revision,base);XCTAssertEqual(details.to.revision,base);XCTAssertEqual(details.change,.identical)
        let token = OperationCancellation();token.cancel()
        do {_ = try await parent.submoduleComparison(path:path,fromIndex:true,cancellation:token);XCTFail("Cancelled index comparison accepted")} catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

}
