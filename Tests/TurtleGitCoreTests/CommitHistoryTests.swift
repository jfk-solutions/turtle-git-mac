import XCTest
@testable import TurtleGitCore

final class CommitHistoryTests: XCTestCase {
    func testHistoryWalkFirstParentNoMergesAndFullHistoryPreserveRepository() async throws {
        let (root, baseRepo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? baseRepo.executable)
        let initial = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "walk-side"])
        try Data("main changed\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "walk main")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "walk-side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("walk-side-file")); try await repo.stage(["walk-side-file"]); _ = try await repo.commit(message: "walk side")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "main"]); _ = try await repo.run(["merge", "--no-ff", "--no-commit", "walk-side"])
        _ = try await repo.run(["checkout", initial, "--", path]); _ = try await repo.commit(message: "walk merge keeps side path")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        var options = HistoryOptions(); options.walk.firstParent = true
        let first = try await repo.history(options: options)
        XCTAssertEqual(first.map(\.subject), ["walk merge keeps side path", "walk main", "base"])
        XCTAssertEqual(first[0].parents, [main, side], "Walk filtering must retain actual action parents")
        options.walk.noMerges = true
        let linear = try await repo.history(options: options); XCTAssertEqual(linear.map(\.hash), [main, initial])
        options.walk.firstParent = false
        let ordinary = try await repo.history(options: options); XCTAssertEqual(Set(ordinary.map(\.hash)), [main, side, initial])
        options.walk.noMerges = false; options.paths = [path]
        let simplified = try await repo.history(options: options); XCTAssertFalse(simplified.contains { $0.hash == main })
        options.walk.fullHistory = true
        let full = try await repo.history(options: options); XCTAssertTrue(full.contains { $0.hash == main })
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
    func testHistoryWalkRewrittenGraphPreservesActualFileActionParents() async throws {
        let (root, fixtureRepo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "graph-base", base])
        try Data("unrelated\n".utf8).write(to: root.appendingPathComponent("unrelated"))
        try await repo.stage(["unrelated"]); _ = try await repo.commit(message: "omitted intermediate")
        let intermediate = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("path changed\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "visible path change")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        var options = HistoryOptions(); options.paths = [path]
        let entries = try await repo.history(options: options)
        XCTAssertEqual(entries.map(\.subject), ["visible path change", "base"])
        let latest = try XCTUnwrap(entries.first)
        XCTAssertEqual(latest.parents, [intermediate])
        XCTAssertEqual(latest.graphParents, [base])
        XCTAssertEqual(entries.last?.graphParents, [])
        let graph = CommitGraph.project(entries, walk: options.walk)
        XCTAssertTrue(graph.graph[1].edges.contains { $0.endsAtNode }, "Path history must connect across an omitted intermediate commit")
        XCTAssertEqual(graph.entries[0].parents, [intermediate])
        XCTAssertTrue(CommitGraph.layout(entries)[1].edges.contains { $0.endsAtNode })
        let files = try await repo.files(in: latest)
        XCTAssertEqual(files.map(\.path), [path], "File details must compare the actual parent, not the graph ancestor")
        let targets = try await repo.prepareLogFileRevert(latest, files: files, parent: true)
        XCTAssertEqual(targets.map(\.revision), [intermediate])
        options.walk.graphMode = .labeled
        XCTAssertTrue(CommitGraph.project(entries, walk: options.walk).graph.last!.edges.contains { $0.endsAtNode })
        options.walk.fullHistory = true
        let full = try await repo.history(options: options)
        XCTAssertEqual(full.first?.parents, [intermediate]); XCTAssertNil(full.first?.graphParents)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
    func testHistoryWalkFollowsLiteralRenameAndRejectsFolderOrMultiplePaths() async throws {
        let (root, baseRepo, old) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? baseRepo.executable)
        let renamed = "new :(glob)* 雪\n.txt"
        _ = try await repo.run(["mv", "--", old, renamed]); _ = try await repo.commit(message: "walk rename")
        try Data("literal objects file\n".utf8).write(to: root.appendingPathComponent("objects")); try await repo.stage(["objects"]); _ = try await repo.commit(message: "unrelated")
        let moduleHash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + moduleHash + ",uninitialized-module"])
        _ = try await repo.commit(message: "gitlink fixture")
        var options = HistoryOptions(); options.paths = [renamed]
        let simple = try await repo.history(options: options); XCTAssertEqual(simple.map(\.subject), ["walk rename"])
        options.walk.followRenames = true
        let followed = try await repo.history(options: options); XCTAssertEqual(followed.map(\.subject), ["walk rename", "base"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for paths in [[], [renamed, "objects"], ["."]] {
            options.paths = paths
            do { _ = try await repo.history(options: options); XCTFail("Invalid follow scope accepted") } catch is HistoryWalkFailure {}
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        options.paths = ["folder"]
        do { _ = try await repo.history(options: options); XCTFail("Directory follow accepted") } catch is HistoryWalkFailure {}
        options.paths = [renamed]; options.allBranches = true
        do { _ = try await repo.history(options: options); XCTFail("All branches follow accepted") } catch is HistoryWalkFailure {}
        let bare = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bare.path])
        let bareRepo = GitRepository(root: bare, executable: repo.executable)
        let allowed = try await bareRepo.canFollowHistory(paths: ["objects"]); XCTAssertTrue(allowed, "Bare administration directories must not hide committed file history")
        let directorySyntax = try await bareRepo.canFollowHistory(paths: ["folder/"]); XCTAssertFalse(directorySyntax)
        let moduleAllowed = try await bareRepo.canFollowHistory(paths: ["uninitialized-module"]); XCTAssertFalse(moduleAllowed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testHistoryWalkCompressionKeepsHeadLabelsMergesForksAndActualParents() {
        func entry(_ hash: String, _ parents: [String]) -> LogEntry { LogEntry(hash: hash, author: "", date: "", subject: hash, parents: parents) }
        var head = entry("head", ["hidden"]); head.isHead = true
        var root = entry("root", []); root.references = [RevisionReference(name: "refs/tags/root")]
        let entries = [head, entry("hidden", ["merge"]), entry("merge", ["left", "right"]), entry("left", ["root"]), entry("right", ["root"]), root]
        var walk = HistoryWalkOptions(); walk.toggle(.compressed)
        let compact = CommitGraph.project(entries, walk: walk)
        XCTAssertEqual(compact.entries.map(\.hash), ["head", "merge", "root"])
        XCTAssertEqual(compact.entries[0].parents, ["hidden"]); XCTAssertEqual(compact.entries[1].parents, ["left", "right"])
        XCTAssertTrue(compact.graph[1].junction && compact.graph[2].junction)
        XCTAssertTrue(compact.graph[1].edges.contains { $0.endsAtNode }, "Hidden linear ancestors must connect retained nodes")
        walk.toggle(.labeled); XCTAssertFalse(walk.contains(.compressed)); XCTAssertTrue(walk.contains(.labeled))
        let labeled = CommitGraph.project(entries, walk: walk)
        XCTAssertEqual(labeled.entries.map(\.hash), ["head", "root"]); XCTAssertTrue(labeled.graph[1].edges.contains { $0.endsAtNode })
        walk.toggle(.labeled); XCTAssertFalse(walk.isActive)
        XCTAssertEqual(CommitGraph.project(entries, walk: walk).entries.map(\.hash), entries.map(\.hash))
        walk.firstParent = true
        XCTAssertEqual(CommitGraph.project(entries, walk: walk).entries[2].parents, ["left", "right"])
    }
    func testHistoricalLogFileRevertPinsTargetsPreservesAddedWorkAndUnrelatedIndex() async throws {
        let (root, fixtureRepo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        let before = try Data(contentsOf: root.appendingPathComponent(path))
        try Data([0xff, 10]).write(to: root.appendingPathComponent(path))
        let added = "added :(glob)* 雪\n.txt", addedBytes = Data([0xfe, 10])
        try addedBytes.write(to: root.appendingPathComponent(added))
        try await repo.stage([path, added]); _ = try await repo.commit(message: "changed and added")
        let history = try await repo.history(), changed = try XCTUnwrap(history.first)
        let files = try await repo.files(in: changed)
        try Data("unrelated index\n".utf8).write(to: root.appendingPathComponent("unrelated")); try await repo.stage(["unrelated"])
        try Data("new local work\n".utf8).write(to: root.appendingPathComponent(path))
        let target = try await repo.prepareLogFileRevert(changed, files: [try XCTUnwrap(files.first { $0.path == path })], parent: true)
        XCTAssertEqual(target[0].revision, changed.parents[0]); XCTAssertEqual(target[0].path, path)
        _ = try await repo.revertLogFile(target[0], recycle: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), before)
        let staged = try await repo.run(["show", ":" + path]).stdout; XCTAssertEqual(staged, before)
        let addedTarget = try await repo.prepareLogFileRevert(changed, files: [try XCTUnwrap(files.first { $0.path == added })], parent: true)
        XCTAssertTrue(addedTarget[0].unstageOnly)
        _ = try await repo.revertLogFile(addedTarget[0], recycle: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(added)), addedBytes)
        let unstaged = try await repo.run(["ls-files", "--error-unmatch", "--", added], successfulExitCodes: 0...1); XCTAssertEqual(unstaged.exitCode, 1)
        let untouched = try await repo.run(["show", ":unrelated"]).stdout; XCTAssertEqual(untouched, Data("unrelated index\n".utf8))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, changed.hash)
        // Current-revision restore puts the selected raw bytes back in worktree and index.
        let currentTarget = try await repo.prepareLogFileRevert(changed, files: [try XCTUnwrap(files.first { $0.path == path })], parent: false)
        _ = try await repo.revertLogFile(currentTarget[0], recycle: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data([0xff, 10]))
        try await repo.stage([added]); _ = try await repo.commit(message: "prepare rename")
        let new = "renamed.txt"; _ = try await repo.run(["mv", "--", path, new]); _ = try await repo.commit(message: "rename")
        let renamedHistory = try await repo.history(), renamed = try XCTUnwrap(renamedHistory.first)
        let renamedFiles = try await repo.files(in: renamed), file = try XCTUnwrap(renamedFiles.first { $0.path == new })
        XCTAssertEqual(file.oldPath, path)
        try Data("old name local data\n".utf8).write(to: root.appendingPathComponent(path))
        let renameIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { _ = try await repo.prepareLogFileRevert(renamed, files: [file], parent: false); XCTFail("Missing old path accepted") } catch RevisionComparisonFailure.selection {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("old name local data\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), renameIndex)
        let oldTarget = try await repo.prepareLogFileRevert(renamed, files: [file], parent: true)
        _ = try await repo.revertLogFile(oldTarget[0], recycle: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data([0xff, 10]))
        let renamedData = try Data(contentsOf: root.appendingPathComponent(new)); XCTAssertEqual(renamedData, Data([0xff, 10]))
        let forged = CommitFile(path: "../escape", oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        do { _ = try await repo.prepareLogFileRevert(renamed, files: [forged], parent: true); XCTFail("Forged target accepted") } catch RevisionComparisonFailure.selection {}
    }
    func testLogFileGroupsRetainEveryParentOccurrenceAndScopedPatch() async throws {
        let (root, fixtureRepo, old) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        var history = try await repo.history(); let initial = try XCTUnwrap(history.first)
        let roots = try await repo.logFileGroups(in: initial)
        XCTAssertEqual(roots.count, 1); XCTAssertNil(roots[0].parent)
        XCTAssertEqual(roots[0].files.map(\.path), [old]); XCTAssertEqual(roots[0].files[0].action, "A")
        try Data("base\n".utf8).write(to: root.appendingPathComponent("shared"))
        try await repo.stage(["shared"]); _ = try await repo.commit(message: "shared base")
        _ = try await repo.run(["branch", "side"])
        try Data("main\n".utf8).write(to: root.appendingPathComponent("shared"))
        try Data("main only\n".utf8).write(to: root.appendingPathComponent("main-only"))
        try await repo.stage(["shared", "main-only"]); _ = try await repo.commit(message: "main")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "side"])
        let renamed = "renamed :(glob)* 雪\n.txt"
        _ = try await repo.run(["mv", "--", old, renamed])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("shared"))
        try await repo.stage(["shared"]); _ = try await repo.commit(message: "side")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "main"])
        _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge"], successfulExitCodes: 0...1)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent("shared"))
        try await repo.stage(["shared"]); _ = try await repo.commit(message: "resolved merge")
        history = try await repo.history(); var merge = try XCTUnwrap(history.first)
        XCTAssertEqual(merge.parents, [main, side])
        // Cached row metadata is not authoritative for which parents belong to the commit.
        merge.parents = [side, main, initial.hash]
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("shared")); try await repo.stage(["shared"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("shared"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let groups = try await repo.logFileGroups(in: merge)
        XCTAssertEqual(groups.map(\.id), [0, 1]); XCTAssertEqual(groups.map(\.parent), [main, side])
        XCTAssertEqual(groups.map { $0.entry.parents }, [[main], [side]])
        let annotated = groups.flatMap { group in group.files.filter { $0.path == "shared" }.map { $0.inParentGroup(group.id) } }
        var actualMerge = merge; actualMerge.parents = [main, side]
        let combinedOccurrences = try await repo.revisionFileDiffData(actualMerge, files: annotated + annotated)
        let occurrenceText = String(decoding: combinedOccurrences, as: UTF8.self)
        XCTAssertEqual(Set(annotated.map(\.id)).count, 2)
        XCTAssertTrue(occurrenceText.contains("-main") && occurrenceText.contains("-side"))
        XCTAssertEqual(occurrenceText.components(separatedBy: "+resolved").count, 3)

        XCTAssertEqual(groups.filter { $0.files.contains { $0.path == "shared" } }.count, 2)
        XCTAssertEqual(groups[0].files.first { $0.path == renamed }?.oldPath, old)
        XCTAssertFalse(groups[1].files.contains { $0.path == renamed })
        XCTAssertFalse(groups[0].files.contains { $0.path == "main-only" })
        XCTAssertEqual(groups[1].files.first { $0.path == "main-only" }?.action, "A")
        for (index, group) in groups.enumerated() {
            let file = try XCTUnwrap(group.files.first { $0.path == "shared" })
            let bytes = try await repo.revisionFileDiffData(group.entry, files: [file])
            let patch = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(patch.contains(index == 0 ? "-main" : "-side")); XCTAssertTrue(patch.contains("+resolved"))
            XCTAssertFalse(patch.contains("staged")); XCTAssertFalse(patch.contains("working"))
            let snapshot = try await repo.revisionFileComparison(from: .revision(try XCTUnwrap(group.parent)), to: .revision(group.entry.hash), paths: [file.path])
            let document = try await repo.comparisonFile(snapshot, path: file.path)
            XCTAssertEqual(document.base.bytes, Data((index == 0 ? "main\n" : "side\n").utf8))
            XCTAssertEqual(document.destination.bytes, Data("resolved\n".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("shared")), Data("working\n".utf8))
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.logFileGroups(in: merge, cancellation: stopped); XCTFail("Cancelled groups succeeded") } catch is OperationCancellationFailure {}
        let invalid = LogEntry(hash: "HEAD", author: "", date: "", subject: "")
        do { _ = try await repo.logFileGroups(in: invalid); XCTFail("Unpinned groups succeeded") } catch RevisionComparisonFailure.range {}
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "shared"])
        _ = try await repo.run(["switch", "-c", "empty-side"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "empty side"])
        _ = try await repo.run(["switch", "main"]); _ = try await repo.run(["merge", "--no-ff", "empty-side", "-m", "empty merge"])
        let emptyHistory = try await repo.history(), emptyMerge = try XCTUnwrap(emptyHistory.first)
        let emptyGroups = try await repo.logFileGroups(in: emptyMerge)
        XCTAssertEqual(emptyGroups.count, 2); XCTAssertTrue(emptyGroups.allSatisfy { $0.files.isEmpty })
        let bareRoot = FileManager.default.temporaryDirectory.appendingPathComponent("groups-bare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bareRoot) }
        _ = try await repo.run(["clone", "--bare", "--local", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        let bareGroups = try await bare.logFileGroups(in: merge)
        XCTAssertEqual(bareGroups.map(\.parent), groups.map(\.parent))
        XCTAssertEqual(bareGroups.map(\.files), groups.map(\.files))
        _ = try await repo.run(["branch", "octopus-a"]); _ = try await repo.run(["branch", "octopus-b"])
        for branch in ["main", "octopus-a", "octopus-b"] {
            _ = try await repo.run(["switch", branch])
            try Data((branch + "\n").utf8).write(to: root.appendingPathComponent(branch))
            try await repo.stage([branch]); _ = try await repo.commit(message: branch)
        }
        _ = try await repo.run(["switch", "main"])
        _ = try await repo.run(["merge", "--no-ff", "octopus-a", "octopus-b", "-m", "three parents"])
        let octopusHistory = try await repo.history(), octopus = try XCTUnwrap(octopusHistory.first)
        let octopusGroups = try await repo.logFileGroups(in: octopus)
        XCTAssertEqual(octopusGroups.map(\.parent), octopus.parents); XCTAssertEqual(octopusGroups.count, 3)
        XCTAssertEqual(octopusGroups.map(\.id), [0, 1, 2])
        XCTAssertEqual(octopusGroups.map { Set($0.files.map(\.path)) }, [Set(["octopus-a", "octopus-b"]), Set(["main", "octopus-b"]), Set(["main", "octopus-a"])])
    }
    func testUnifiedDiffBytesRemainApplicableForNonUTF8Text() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "raw.txt", before = Data([0xff, 0x0a]), after = Data([0xfe, 0x0a])
        try before.write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "non-UTF8 base")
        try after.write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "non-UTF8 change")
        let history = try await repo.history(), entry = try XCTUnwrap(history.first)
        let files = try await repo.files(in: entry)
        let bytes = try await repo.revisionDiffData(entry)
        let selected = try await repo.revisionFileDiffData(entry, files: files + files)
        XCTAssertEqual(bytes, selected)
        XCTAssertNotNil(bytes.range(of: Data([0x2d, 0xff, 0x0a])))
        XCTAssertNotNil(bytes.range(of: Data([0x2b, 0xfe, 0x0a])))
        let preview = try UnifiedDiffPreview.create(selected)
        defer { preview.discard() }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.run(["apply", "--reverse", "--check", "--", preview.file.path])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try before.write(to: root.appendingPathComponent(path))
        let working = try await repo.revisionDiffData(entry, path: path, workingTree: true)
        XCTAssertNotNil(working.range(of: Data([0x2b, 0xff, 0x0a])))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testSelectedUnifiedDiffKeepsOrderRootRenameAndLiteralScopeWithoutMutations() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialHistory = try await repo.history()
        let initial = try XCTUnwrap(initialHistory.first)
        let initialFiles = try await repo.files(in: initial)
        let rootPatch = try await repo.revisionFileDiff(initial, files: initialFiles)
        XCTAssertTrue(rootPatch.contains("new file mode"))
        let literal = ":(glob)* 雪\n.txt", other = "other.txt", renamed = "renamed.txt"
        try Data("literal initial\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data("other initial\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([literal, other]); _ = try await repo.commit(message: "more paths")
        _ = try await repo.run(["mv", "--", path, renamed])
        try Data("literal selected\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data("UNSELECTED CHANGE\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([literal, other]); _ = try await repo.commit(message: "rename and modifications")
        let history = try await repo.history(), selected = try XCTUnwrap(history.first)
        let files = try await repo.files(in: selected)
        let rename = try XCTUnwrap(files.first { $0.path == renamed })
        let unusual = try XCTUnwrap(files.first { $0.path == literal })
        try Data("later staged\n".utf8).write(to: root.appendingPathComponent(literal)); try await repo.stage([literal])
        try Data("later working\n".utf8).write(to: root.appendingPathComponent(literal))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let patch = try await repo.revisionFileDiff(selected, files: [unusual, rename, unusual])
        XCTAssertTrue(patch.contains("+literal selected")); XCTAssertFalse(patch.contains("UNSELECTED CHANGE"))
        XCTAssertFalse(patch.contains("later staged")); XCTAssertFalse(patch.contains("later working"))
        XCTAssertEqual(rename.oldPath, path)
        XCTAssertTrue(patch.contains("rename from ")); XCTAssertTrue(patch.contains("rename to " + renamed))
        let first = try XCTUnwrap(patch.range(of: "+literal selected")), second = try XCTUnwrap(patch.range(of: "rename to " + renamed))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertEqual(patch.components(separatedBy: "+literal selected").count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data("later working\n".utf8))
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, finalHead)
        do { _ = try await repo.revisionFileDiff(selected, files: []); XCTFail("Empty selection accepted") } catch RevisionComparisonFailure.selection {}
    }
    private func entry(_ hash: String, _ parents: [String]) -> LogEntry {
        LogEntry(hash: hash, author: "A", date: "", subject: hash, parents: parents)
    }
    func testMergeAndBranchPointEdgesStayContinuous() {
        // Merge M has parents A and B, which share base R.
        let rows = CommitGraph.layout([entry("M", ["A", "B"]), entry("A", ["R"]), entry("B", ["R"]), entry("R", [])])
        XCTAssertTrue(rows[0].junction)
        XCTAssertTrue(rows[3].junction)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 2)
        XCTAssertFalse(rows[0].edges.contains(where: \.endsAtNode)) // no invented ancestor above a tip
        for index in 0..<rows.count - 1 {
            let outgoing = rows[index].edges.filter { !$0.endsAtNode }.map { "\($0.to):\($0.color)" }.sorted()
            let incoming = rows[index + 1].edges.filter { !$0.startsAtNode }.map { "\($0.from):\($0.color)" }.sorted()
            // Multiple edges may join the same ancestor at a row boundary.
            XCTAssertEqual(Set(outgoing), Set(incoming))
        }
        XCTAssertTrue(rows[3].edges.allSatisfy(\.endsAtNode))
    }
    func testOctopusAndDisconnectedHistory() {
        let rows = CommitGraph.layout([entry("M", ["A", "B", "C"]), entry("A", []), entry("B", []), entry("C", []), entry("unrelated", [])])
        XCTAssertEqual(rows[0].width, 3)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 3)
        XCTAssertEqual(rows[4].column, 0)
        XCTAssertTrue(rows[4].edges.isEmpty)
    }
    func testChangedPathParsingWithBinaryRenameTabsAndNewlines() {
        let files = CommitFile.parse(names: Data("R100\0old\nname\0new\tname\0M\0binary\0A\0雪\0".utf8),
            statistics: Data("0\t0\t\0old\nname\0new\tname\0-\t-\tbinary\03\t0\t雪\0".utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].oldPath, "old\nname")
        XCTAssertEqual(files[0].path, "new\tname")
        XCTAssertEqual(files[0].added, 0)
        XCTAssertNil(files[1].added)
        XCTAssertEqual(files[2].added, 3)
    }
    func testHistorySearchFieldsMatchAuthorAndCommitterBeforeLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Integrator [雪]"])
        _ = try await repo.run(["config", "user.email", "integrator@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.run(["commit", "--author=Contributor <contributor@example.invalid>", "-m", "Literal [needle]\n\nBody only token"])
        let oldHistory = try await repo.history(), older = try XCTUnwrap(oldHistory.first)
        XCTAssertEqual(older.committer, "Integrator [雪]")
        XCTAssertEqual(older.committerEmail, "integrator@example.invalid")
        _ = try await repo.run(["config", "user.name", "Recent"])
        _ = try await repo.run(["config", "user.email", "recent@example.invalid"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "contributor@example.invalid is mentioned")
        var options = HistoryOptions(); options.limit = 1; options.search = "CONTRIBUTOR"; options.searchFields = .authors
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "[雪]"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "INTEGRATOR@"; options.searchFields = .emails
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "contributor@example.invalid"; options.searchFields = [.messages, .emails]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, older.hash)
        options.searchFields = .emails; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .revisions; options.search = String(older.hash.prefix(12)).uppercased()
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .messages; options.search = "[needle]"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = []; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = ""; options.limit = 1; found = try await repo.history(options: options); XCTAssertEqual(found.count, 1)
        options.search = "Contributor"; options.searchFields = .authors; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.searchFields = .authors; options.search = "CONTRIBUTOR"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "Contributor"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .emails; options.search = "INTEGRATOR@"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "integrator@"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .messages; options.search = "body only token"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "Body only token"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .subject; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "literal [needle]"; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchCaseSensitive = false; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = [.subject, .messages]; options.search = "BODY ONLY TOKEN"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .authors; options.search = "Contributor"
        options.paths = []; options.limit = 0; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.limit = 1; options.endRevision = older.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
    }
    func testReferenceSearchFindsBranchesRemoteAndPeeledTagsBeforeLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Ref Tests"])
        _ = try await repo.run(["config", "user.email", "refs@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["branch", "release-needle", old.hash])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/Review", old.hash])
        _ = try await repo.run(["tag", "light-needle", old.hash])
        _ = try await repo.run(["tag", "-a", "annotated-needle", "-m", "annotation text", old.hash])
        _ = try await repo.run(["tag", "-a", "nested-tag", "-m", "nested annotation", "annotated-needle"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "needle only-in-message")
        var options = HistoryOptions(); options.searchFields = .referenceNames; options.limit = 1
        for name in ["release-needle", "refs/remotes/origin/Review", "light-needle", "annotated-needle", "nested-tag"] {
            options.search = name; let found = try await repo.history(options: options)
            XCTAssertEqual(found.map(\.hash), [old.hash], name)
            XCTAssertTrue(found.first?.references.contains { $0.name.hasSuffix(name) } == true)
        }
        options.search = "annotated-needle^{}"
        let peeled = try await repo.history(options: options); XCTAssertEqual(peeled.map(\.hash), [old.hash])
        options.search = "light-needle^{}"; let notPeeled = try await repo.history(options: options); XCTAssertTrue(notPeeled.isEmpty)
        options.search = "only-in-message"; var found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "review"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchCaseSensitive = false; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.search = "needle"; options.searchFields = [.messages, .referenceNames]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
        options.searchFields = .referenceNames; options.search = "release-needle"; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash; options.search = "main"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
    }
    func testNotesSearchUsesDisplayedNotesWithoutCorruptingHistoryRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Note Tests"])
        _ = try await repo.run(["config", "user.email", "notes@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["notes", "add", "-m", "NoteToken 雪\nMultiline note", old.hash])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "NoteToken only-message")
        var options = HistoryOptions(); options.searchFields = .notes; options.search = "notetoken"; options.limit = 1
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        XCTAssertTrue(found.first?.notes.contains("Multiline note") == true)
        options.searchCaseSensitive = true; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "NoteToken"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.searchFields = [.notes, .messages]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2)
        options.searchFields = .messages; options.search = "Multiline note"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = .notes; options.search = "only-message"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "NoteToken"; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        _ = try await repo.run(["notes", "--ref=review", "add", "-m", "ReviewOnly", old.hash])
        _ = try await repo.run(["config", "notes.displayRef", "refs/notes/review"])
        options.search = "ReviewOnly"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        _ = try await repo.run(["config", "--unset", "notes.displayRef"])
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/review"])
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        let binaryNote = root.appendingPathComponent("note.bin"); try Data("Before\0AfterMarker\n".utf8).write(to: binaryNote)
        let blob = try await repo.run(["hash-object", "-w", "--", binaryNote.path]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["notes", "add", "-f", "-C", blob, old.hash])
        let displayed = try await repo.run(["show", "-s", "--notes", "--format=%N", old.hash, "--"]).text.trimmingCharacters(in: .newlines)
        options.search = "Before"; found = try await repo.history(options: options)
        XCTAssertEqual(found.map(\.hash), [old.hash]); XCTAssertEqual(found.first?.notes, displayed)
        options.search = ""; options.endRevision = nil
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
    }
    func testAnnotatedTagInfoSearchUsesTagObjectsAndExcludesLightweightRefs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Tagger Person"])
        _ = try await repo.run(["config", "user.email", "tagger@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["tag", "-a", "release-tag", "-m", "AnnotationMarker 雪\nSecond line", old.hash])
        let object = try await repo.run(["rev-parse", "refs/tags/release-tag"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/tags/alias-only-name", object])
        _ = try await repo.run(["tag", "light-only-name", old.hash])
        _ = try await repo.run(["tag", "-a", "nested", "-m", "NestedAnnotation", "release-tag"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "AnnotationMarker only-message")
        let fixedDates = HistoryDateSettings(useSystemLocale: false)
        let rawTag = try await repo.run(["cat-file", "tag", object]).text
        let expectedTag = fixedDates.tagInfo(rawTag)
        let taggerLine = try XCTUnwrap(expectedTag.components(separatedBy: "\n").first { $0.hasPrefix("tagger ") })
        var dateQuery = HistoryOptions(); dateQuery.searchFields = .tagInfo; dateQuery.search = "\"" + taggerLine + "\""
        let dateMatches = try await repo.history(options: dateQuery, dateSettings: fixedDates)
        XCTAssertEqual(dateMatches.map(\.hash), [old.hash])
        let copied = try await repo.commitLogText(revision: old.hash, includePaths: false, dateSettings: fixedDates)
        XCTAssertTrue(copied.contains("Date: " + fixedDates.format(old.date) + "\n"))
        XCTAssertTrue(copied.contains(taggerLine))
        XCTAssertFalse(copied.contains("object " + old.hash))
        XCTAssertTrue(copied.contains("AnnotationMarker 雪\nSecond line"))
        var options = HistoryOptions(); options.searchFields = .tagInfo; options.search = "annotationmarker"; options.limit = 1
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        XCTAssertTrue(found.first?.tagInfo.contains("tag release-tag") == true)
        XCTAssertTrue(found.first?.tagInfo.contains("Tagger Person <tagger@example.invalid>") == true)
        XCTAssertTrue(found.first?.tagInfo.contains("Second line") == true)
        XCTAssertFalse(found.first!.tagInfo.contains("object " + old.hash))
        for query in ["NestedAnnotation", "release-tag", "tagger@example.invalid", "Tagger Person"] {
            options.search = query; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        }
        for query in ["light-only-name", "alias-only-name", "only-message", old.hash] {
            options.search = query; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty, query)
        }
        options.search = "annotationmarker"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "AnnotationMarker"; options.searchFields = [.messages, .tagInfo]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
        options.searchFields = .tagInfo; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.search = ""; found = try await repo.history(options: options)
        XCTAssertEqual(found.map(\.hash), [old.hash]); XCTAssertTrue(found.first?.tagInfo.contains("NestedAnnotation") == true)
    }
    func testPathSearchIncludesRootRenamesAndEveryMergeParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Paths Tests"])
        _ = try await repo.run(["config", "user.email", "paths@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let original = "Old 雪\n[1].txt", renamed = "Renamed\t[1].txt"
        try Data("root\n".utf8).write(to: root.appendingPathComponent(original)); try await repo.stage([original])
        _ = try await repo.commit(message: "root")
        let initial = try await repo.history(), first = try XCTUnwrap(initial.first)
        _ = try await repo.run(["mv", "--", original, renamed]); _ = try await repo.commit(message: "rename")
        let renamedHistory = try await repo.history(), rename = try XCTUnwrap(renamedHistory.first)
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature-only.txt")); try await repo.stage(["feature-only.txt"])
        _ = try await repo.commit(message: "feature")
        _ = try await repo.run(["switch", "main"])
        try Data("main\n".utf8).write(to: root.appendingPathComponent("MainOnly.txt")); try await repo.stage(["MainOnly.txt"])
        _ = try await repo.commit(message: "main")
        _ = try await repo.run(["merge", "--no-ff", "feature", "-m", "merge"])
        let mergedHistory = try await repo.history(), merge = try XCTUnwrap(mergedHistory.first)
        var options = HistoryOptions(); options.searchFields = .paths; options.limit = 1; options.search = original
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [rename.hash])
        options.limit = 10; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [rename.hash, first.hash])
        options.search = renamed; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [rename.hash])
        // MainOnly is unchanged from the first parent but changed from the second.
        options.limit = 1; options.search = "MainOnly.txt"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [merge.hash])
        options.search = "mainonly.txt"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchCaseSensitive = false; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [merge.hash])
        options.search = "message-only-token"; _ = try await repo.run(["commit", "--allow-empty", "-m", "message-only-token"])
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = [.paths, .messages]; found = try await repo.history(options: options); XCTAssertEqual(found.count, 1)
        options.searchFields = .paths; options.search = renamed; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.search = original; options.endRevision = first.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
    }
    func testPlainQueryRulesFromUpstreamFilterHelper() {
        let cases: [(String, String, Bool)] = [
            ("red fox", "fox and RED", true), ("red fox", "red only", false),
            ("red -blocked", "red open", true), ("red -blocked", "red blocked", false),
            ("red +blue", "blue", true), ("red +blue", "green", false),
            ("red +blue fox", "red fox", true), ("red +blue fox", "blue", false),
            ("red -blocked +blue fox", "blue fox", true),
            ("!red", "blue", true), ("!red", "red", false),
            ("!", "anything", false), ("   ", "", true),
            ("\"red fox\"", "red fox", true), ("\"red fox\"", "red slow fox", false),
            ("\"a\"\"b\"", "a\"b", true), ("\"unterminated", "unterminated", true),
            ("red\tfox", "red fox", false), ("red\tfox", "red\tfox", true),
            ("-blocked", "clear", true), ("-blocked", "", false),
            ("\"red fox\" -blocked", "red fox clear", false),
            ("\"red fox\" -blocked", "red fox -blocked", true)
        ]
        for (query, text, expected) in cases {
            XCTAssertEqual(HistoryTextQuery(query, caseSensitive: false).matches(text), expected, query)
        }
        XCTAssertFalse(HistoryTextQuery("Red", caseSensitive: true).matches("red"))
        XCTAssertTrue(HistoryTextQuery("雪", caseSensitive: true).matches("雪"))
        XCTAssertTrue(HistoryTextQuery("!red", caseSensitive: false).matches(""))
    }
    func testRealPlainQueryCombinesFieldsExclusionsAlternativesNegationAndLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Query Author"])
        _ = try await repo.run(["config", "user.email", "query@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "red fox"])
        let initial = try await repo.history(); let first = try XCTUnwrap(initial.first)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "red blocked"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "blue fox"])
        let all = try await repo.history()
        var options = HistoryOptions(); options.limit = 1; options.search = "red -blocked"
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        options.limit = 10; options.search = "red +blue fox"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash, first.hash])
        options.search = "!red"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash])
        options.search = "\"red fox\""
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        options.searchFields = [.messages, .authors]; options.search = "fox author"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash, first.hash])
        options.searchCaseSensitive = true; options.search = "fox AUTHOR"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = []; options.search = "!red"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), all.map(\.hash))
        options.search = "red"; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = .messages; options.search = "!"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
    }
    func testRealRegexQueryFieldsCaseInversionInvalidAndMatchingLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Regex Author"])
        _ = try await repo.run(["config", "user.email", "regex@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "red fox"])
        let initial = try await repo.history(); let first = try XCTUnwrap(initial.first)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "blue bird"])
        let all = try await repo.history()
        var options = HistoryOptions(); options.searchRegex = true; options.limit = 1
        options.regexExecutable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
        options.search = "RED.*FOX"
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "!red.*fox"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash])
        options.search = "(?<=blue)bird"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash])
        options.search = "!("; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = [.messages, .authors]; options.search = "red[\\s\\S]*Regex Author"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        options.searchFields = []; options.search = ".*"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "!.*"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [all[0].hash])
        options.paths = ["absent.txt"]; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
    }
    func testBugIDSearchUsesProjectConfigurationExtractionAndBareHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Issue Tests"])
        _ = try await repo.run(["config", "user.email", "issue@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("[bugtraq]\nmessage = Issue %BUGID%\nurl = https://example.invalid/%BUGID%\n".utf8).write(to: root.appendingPathComponent(".tgitconfig"))
        try await repo.stage([".tgitconfig"])
        _ = try await repo.commit(message: "Fix\n\nIssue 42,7,42\n")
        let initial = try await repo.history(); let first = try XCTUnwrap(initial.first)
        XCTAssertEqual(first.issueIDs, "7 42")
        _ = try await repo.run(["commit", "--allow-empty", "-m", "Mention 900 without issue line"])
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var options = HistoryOptions(); options.searchFields = .bugIDs; options.search = "7 42"; options.limit = 1
        options.regexExecutable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        options.search = "900"; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = [.messages, .bugIDs]; found = try await repo.history(options: options); XCTAssertEqual(found.count, 1)
        _ = try await repo.run(["config", "bugtraq.logregex", "issue #(\\d+)"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "issue #100 issue #2 issue #2"])
        options.searchFields = .bugIDs; options.search = "2 100"
        found = try await repo.history(options: options); XCTAssertEqual(found.first?.issueIDs, "2 100")
        XCTAssertEqual(found.count, 1)
        options.searchRegex = true; options.search = "^2 100"
        found = try await repo.history(options: options); XCTAssertEqual(found.first?.issueIDs, "2 100")
        _ = try await repo.run(["config", "bugtraq.logregex", "(?<=#)42"])
        options.search = ""; options.limit = 10
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 3); XCTAssertTrue(found.allSatisfy { $0.issueIDs.isEmpty })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot)
        options.searchRegex = false; options.search = "7 42"
        found = try await bare.history(options: options); XCTAssertEqual(found.map(\.hash), [first.hash])
        XCTAssertEqual(found.first?.issueIDs, "7 42")
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.issueTrackerProperties(cancellation: stopped); XCTFail("Cancelled properties succeeded") } catch is OperationCancellationFailure {}
    }
    func testHistoryPreservesIndependentAuthorAndCommitterDatesAcrossRecordsAndScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Date Tests"])
        _ = try await repo.run(["config", "user.email", "date@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let authorDate = "2001-02-03T04:05:06+02:00", commitDate = "2020-04-05T06:07:08-07:00"
        _ = try await repo.run(["commit", "--allow-empty", "-m", "older timestamp"], environmentOverrides: ["GIT_AUTHOR_DATE": authorDate, "GIT_COMMITTER_DATE": commitDate])
        let initial = try await repo.history(); let older = try XCTUnwrap(initial.first)
        XCTAssertEqual(older.date, authorDate); XCTAssertEqual(older.committerDate, commitDate)
        let secondDate = "2020-04-06T06:07:08-07:00"
        _ = try await repo.run(["commit", "--allow-empty", "-m", "newer timestamp"], environmentOverrides: ["GIT_AUTHOR_DATE": authorDate, "GIT_COMMITTER_DATE": secondDate])
        let all = try await repo.history()
        XCTAssertEqual(all.map(\.committerDate), [secondDate, commitDate])
        XCTAssertEqual(all.map(\.date), [authorDate, authorDate])
        var options = HistoryOptions(); options.limit = 1; options.search = "older timestamp"
        let filtered = try await repo.history(options: options); XCTAssertEqual(filtered.first?.hash, older.hash); XCTAssertEqual(filtered.first?.committerDate, commitDate)
        options.search = ""; options.endRevision = older.hash
        let pinned = try await repo.history(options: options); XCTAssertEqual(pinned.first?.committerDate, commitDate)
    }
    func testActionSlotsClassifyCopyTypeChangeRenameAndConflict() {
        let names = Data("M\0modified\0T\0type\0A\0added\0C100\0old\0copy\0D\0deleted\0R100\0before\0after\0U\0conflict\0".utf8)
        let actions = LogRevisionActions.classify(CommitFile.parse(names: names, statistics: Data()))
        XCTAssertEqual(actions, [.modified, .added, .deleted, .replaced, .conflicted])
        XCTAssertEqual(LogRevisionActions.classify([]), [])
    }
    func testDatePreferencesDefaultsPersistedChoicesAndNativeAbsoluteTimezones() throws {
        let name = "TurtleGitDates-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(HistoryDateSettings.load(defaults: defaults), HistoryDateSettings())
        defaults.set(false, forKey: "LogDateFormat"); defaults.set(true, forKey: "RelativeTimes"); defaults.set(false, forKey: "UseSystemLocaleForDates")
        let settings = HistoryDateSettings.load(defaults: defaults)
        XCTAssertEqual(settings, HistoryDateSettings(shortDate: false, relative: true, useSystemLocale: false))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0)), berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let timestamp = "2020-04-05T06:07:08-07:00"
        XCTAssertEqual(settings.format(timestamp, timeZone: utc, absolute: true), "2020-04-05 13:07:08")
        XCTAssertEqual(settings.format(timestamp, timeZone: berlin, absolute: true), "2020-04-05 15:07:08")
        XCTAssertEqual(settings.format("bad timestamp"), "bad timestamp")
        XCTAssertEqual(settings.format(""), "")
        let short = HistoryDateSettings(), long = HistoryDateSettings(shortDate: false)
        let en = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        XCTAssertNotEqual(short.format(timestamp, locale: en, timeZone: utc), long.format(timestamp, locale: en, timeZone: utc))
        XCTAssertNotEqual(short.format(timestamp, locale: en, timeZone: utc), short.format(timestamp, locale: de, timeZone: utc))
    }
    func testRelativeDateThresholdsAndSignedFutureCountsMatchPinnedSource() throws {
        let parser = ISO8601DateFormatter(), date = try XCTUnwrap(parser.date(from: "2020-01-01T00:00:00Z"))
        let settings = HistoryDateSettings(relative: true)
        let cases: [(Double, String)] = [(0, "0 Seconds ago"), (1, "1 Second ago"), (119, "119 Seconds ago"), (120, "2 minutes ago"), (7199, "119 minutes ago"), (7200, "2 Hours ago"), (172799, "47 Hours ago"), (172800, "2 Days ago"), (14 * 86400 - 1, "13 Days ago"), (14 * 86400, "2 Weeks ago"), (60 * 86400 - 1, "8 Weeks ago"), (60 * 86400, "2 Months ago"), (1095 * 86400 - 1, "36 Months ago"), (1095 * 86400, "3 Years ago"), (-120, "-2 minutes ago")]
        for (elapsed, expected) in cases { XCTAssertEqual(settings.format("2020-01-01T00:00:00Z", now: date.addingTimeInterval(elapsed)), expected) }
    }
    func testHistoryCancellationStopsOwnedPathReadAndLeavesOtherReaderAndIndexIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Cancel Tests"])
        _ = try await repo.run(["config", "user.email", "cancel@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "base")
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let stopped = OperationCancellation(); stopped.cancel()
        var zero = HistoryOptions(); zero.limit = 0
        do { _ = try await repo.history(options: zero, cancellation: stopped); XCTFail("Cancelled zero-limit read succeeded") } catch is OperationCancellationFailure {}
        let helper = root.appendingPathComponent("slow-history")
        let script = """
        #!/bin/sh
        case "$*" in
          *diff-tree*)
            /bin/sleep 30 &
            task_history_child=$!
            trap 'kill "$task_history_child" 2>/dev/null; wait "$task_history_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_history_child" > "$0.started"
            wait "$task_history_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
        var options = HistoryOptions(); options.searchFields = .paths; options.search = "file.txt"
        let read = Task { try await slow.history(options: options, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: helper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await read.result; XCTFail("Path read never started"); return }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        let independent = try await repo.history(); XCTAssertEqual(independent.count, 1)
        let began = Date(); token.cancel()
        do { _ = try await read.value; XCTFail("Cancelled path read succeeded") }
        catch is OperationCancellationFailure {}
        catch is GitCommandCancellationFailure {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let final = try await repo.history(); XCTAssertEqual(final.map(\.hash), independent.map(\.hash))
    }
    func testDetailCancellationStopsOwnedStatisticsReadAndLeavesOtherReaderAndIndexIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Cancel Tests"])
        _ = try await repo.run(["config", "user.email", "cancel@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "base")
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let history = try await repo.history()
        let entry = try XCTUnwrap(history.first)
        let expected = try await repo.files(in: entry)
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.files(in: entry, cancellation: stopped); XCTFail("Cancelled details read succeeded") } catch is OperationCancellationFailure {}
        let helper = root.appendingPathComponent("slow-details")
        let script = """
        #!/bin/sh
        case "$*" in
          *--numstat*)
            /bin/sleep 30 &
            task_details_child=$!
            trap 'kill "$task_details_child" 2>/dev/null; wait "$task_details_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_details_child" > "$0.started"
            wait "$task_details_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
        let read = Task { try await slow.files(in: entry, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: helper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await read.result; XCTFail("Statistics read never started"); return }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        let independent = try await repo.files(in: entry); XCTAssertEqual(independent.map(\.path), expected.map(\.path))
        let began = Date(); token.cancel()
        do { _ = try await read.value; XCTFail("Cancelled statistics read succeeded") }
        catch is OperationCancellationFailure {}
        catch is GitCommandCancellationFailure {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let final = try await repo.files(in: entry)
        XCTAssertEqual(final.map(\.path), expected.map(\.path))
        XCTAssertEqual(final.first?.added, 1)
        XCTAssertEqual(final.first?.removed, 0)
    }
    func testActionCancellationStopsOwnedNameReadAndLeavesOtherReaderAndIndexIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Cancel Tests"])
        _ = try await repo.run(["config", "user.email", "cancel@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "base")
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let history = try await repo.history()
        let entry = try XCTUnwrap(history.first)
        let expected = try await repo.revisionActions(in: entry)
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.revisionActions(in: entry, cancellation: stopped); XCTFail("Cancelled details read succeeded") } catch is OperationCancellationFailure {}
        let helper = root.appendingPathComponent("slow-actions")
        let script = """
        #!/bin/sh
        case "$*" in
          *diff-tree*)
            /bin/sleep 30 &
            task_actions_child=$!
            trap 'kill "$task_actions_child" 2>/dev/null; wait "$task_actions_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_actions_child" > "$0.started"
            wait "$task_actions_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
        let read = Task { try await slow.revisionActions(in: entry, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: helper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await read.result; XCTFail("Action read never started"); return }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        let independent = try await repo.revisionActions(in: entry); XCTAssertEqual(independent, expected)
        let began = Date(); token.cancel()
        do { _ = try await read.value; XCTFail("Cancelled action read succeeded") }
        catch is OperationCancellationFailure {}
        catch is GitCommandCancellationFailure {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let final = try await repo.revisionActions(in: entry)
        XCTAssertEqual(final, expected)
        XCTAssertEqual(final, .added)
    }
    func testClipboardCancellationStopsOwnedTagReadAndLeavesOtherReaderAndIndexIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Cancel Tests"])
        _ = try await repo.run(["config", "user.email", "cancel@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "base")
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let history = try await repo.history()
        let entry = try XCTUnwrap(history.first)
        _ = try await repo.run(["notes", "add", "-m", "clipboard note", entry.hash])
        _ = try await repo.run(["tag", "-a", "clipboard-tag", "-m", "clipboard tag", entry.hash])
        let expected = try await repo.commitLogText(revision: entry.hash, includePaths: false)
        XCTAssertTrue(expected.contains("clipboard note"))
        XCTAssertTrue(expected.contains("clipboard tag"))
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.commitLogText(revision: entry.hash, includePaths: false, cancellation: stopped); XCTFail("Cancelled clipboard read succeeded") } catch is OperationCancellationFailure {}
        let helper = root.appendingPathComponent("slow-clipboard")
        let script = """
        #!/bin/sh
        case "$*" in
          *cat-file*)
            /bin/sleep 30 &
            task_clipboard_child=$!
            trap 'kill "$task_clipboard_child" 2>/dev/null; wait "$task_clipboard_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_clipboard_child" > "$0.started"
            wait "$task_clipboard_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
        let read = Task { try await slow.commitLogText(revision: entry.hash, includePaths: false, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: helper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await read.result; XCTFail("Tag read never started"); return }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        let independent = try await repo.commitLogText(revision: entry.hash, includePaths: false); XCTAssertEqual(independent, expected)
        let began = Date(); token.cancel()
        do { _ = try await read.value; XCTFail("Cancelled clipboard read succeeded") }
        catch is OperationCancellationFailure {}
        catch is GitCommandCancellationFailure {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let final = try await repo.commitLogText(revision: entry.hash, includePaths: false)
        XCTAssertEqual(final, expected)
        let withPaths = try await repo.commitLogText(revision: entry.hash)
        XCTAssertTrue(withPaths.contains("Added: file.txt"))
    }
    func testTagDateHeaderFormattingPreservesAnnotationAndMalformedHeaders() {
        let settings = HistoryDateSettings(useSystemLocale: false)
        let object = "object abc\ntype commit\ntag release\ntagger Person <person@example.invalid> 1586092028 -0700\n\nMessage\ntagger Literal <text> 1586092028 +0000\n"
        let formatted = settings.tagInfo(object, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(formatted, "tag release\ntagger Person <person@example.invalid> 2020-04-05 13:07:08\n\nMessage\ntagger Literal <text> 1586092028 +0000")
        XCTAssertFalse(formatted.contains("object abc"))
        XCTAssertEqual(settings.tagInfo("tag x\ntagger A <a> invalid +0000\n\nbody"), "tag x\ntagger A <a> invalid +0000\n\nbody")
        XCTAssertTrue(settings.tagInfo(object.replacingOccurrences(of: "type commit", with: "type tag")).hasPrefix("type tag\n"))
        let relative = HistoryDateSettings(relative: true)
        XCTAssertTrue(relative.tagInfo(object, now: Date(timeIntervalSince1970: 1586092028 + 120)).contains("<person@example.invalid> 2 minutes ago"))
    }
    func testJumpCandidatesAndSelectionHistoryFollowSourceRules() {
        func entry(_ hash: String, _ parents: [String], _ email: String = "a", _ committer: String = "c") -> LogEntry {
            LogEntry(hash: hash, author: "Author", date: "", subject: hash, parents: parents, email: email, committerEmail: committer)
        }
        var rows = [entry("tip", ["merge"]), entry("merge", ["left", "right"]), entry("left", ["base"]), entry("right", ["base"], "b", "d"), entry("base", [])]
        rows[0].references = [.init(name: "refs/tags/release")]
        rows[3].references = [.init(name: "refs/remotes/origin/side")]
        XCTAssertEqual(HistoryJumpKind.allCases.map(\.rawValue), ["Author Email", "Committer Email", "Merge Point", "Parent 1", "Parent 2", "Tag", "Tag (FF)", "Branch", "Branch (FF)", "Selection History"])
        XCTAssertEqual(HistoryJumpKind.authorEmail.candidates(entries: rows, selected: ["left"], up: true), [1, 0])
        XCTAssertEqual(HistoryJumpKind.committerEmail.candidates(entries: rows, selected: ["left"], up: false), [4])
        XCTAssertEqual(HistoryJumpKind.mergePoint.candidates(entries: rows, selected: ["base"], up: true), [1])
        XCTAssertEqual(HistoryJumpKind.parent1.candidates(entries: rows, selected: ["left"], up: true), [1])
        XCTAssertEqual(HistoryJumpKind.parent2.candidates(entries: rows, selected: ["right"], up: true), [1])
        XCTAssertEqual(HistoryJumpKind.parent2.candidates(entries: rows, selected: ["merge"], up: false), [3])
        XCTAssertEqual(HistoryJumpKind.tag.candidates(entries: rows, selected: ["base"], up: true), [0])
        XCTAssertEqual(HistoryJumpKind.branch.candidates(entries: rows, selected: ["merge"], up: false), [3])
        XCTAssertEqual(HistoryJumpKind.authorEmail.candidates(entries: rows, selected: ["merge", "right"], up: true), [2, 1, 0])
        XCTAssertNil(HistoryJumpKind.authorEmail.candidates(entries: rows, selected: ["tip"], up: false)) // Pinned source guard in both directions.
        XCTAssertNil(HistoryJumpKind.parent1.candidates(entries: rows, selected: ["base"], up: false))
        XCTAssertNil(HistoryJumpKind.parent2.candidates(entries: rows, selected: ["left"], up: false))
        XCTAssertNil(HistoryJumpKind.tag.candidates(entries: rows, selected: [], up: true))
        var history = HistorySelectionNavigation()
        XCTAssertNil(history.move(up: true)); history.add("")
        for hash in ["a", "b", "c"] { history.add(hash) }
        XCTAssertEqual(history.move(up: true), "b"); history.add("b")
        XCTAssertEqual(history.move(up: false), "c")
        _ = history.move(up: true); history.add("x")
        XCTAssertEqual(history.hashes, ["a", "b", "x"]); XCTAssertNil(history.move(up: false))
        _ = history.move(up: true); history.add("x"); XCTAssertEqual(history.location, 2)
        for index in 0..<60 { history.add(String(index)) }
        XCTAssertEqual(history.hashes.count, 50); XCTAssertEqual(history.hashes.first, "10")
    }
    func testFastForwardJumpUsesRealAncestryAndOwnedCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Jump"])
        _ = try await repo.run(["config", "user.email", "jump@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        func commit(_ message: String) async throws -> String {
            _ = try await repo.run(["commit", "--allow-empty", "-m", message])
            return try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        }
        let a = try await commit("base"), b = try await commit("middle"), c = try await commit("tip")
        _ = try await repo.run(["checkout", "-b", "side", a]); let d = try await commit("side")
        _ = try await repo.run(["checkout", "main"])
        func row(_ hash: String) -> LogEntry { LogEntry(hash: hash, author: "Jump", date: "", subject: "") }
        var rows = [row("ignored"), row(c), row(d), row(b), row(a)]
        for index in [1, 2, 4] { rows[index].references = [.init(name: "refs/tags/release"), .init(name: "refs/heads/main")] }
        let before = try? Data(contentsOf: root.appendingPathComponent(".git/index"))
        let branch = try await repo.historyJump(entries: rows, selected: [b], kind: .branch, up: true); XCTAssertEqual(branch, 2)
        let ff = try await repo.historyJump(entries: rows, selected: [b], kind: .branchFF, up: true); XCTAssertEqual(ff, 1)
        let down = try await repo.historyJump(entries: rows, selected: [c], kind: .tagFF, up: false); XCTAssertEqual(down, 4)
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.historyJump(entries: rows, selected: [b], kind: .tagFF, up: true, cancellation: stopped); XCTFail() } catch is OperationCancellationFailure {}
        let wrapper = root.appendingPathComponent("slow-jump")
        let script = """
        #!/bin/sh
        case "$*" in
          *merge-base*)
            /bin/sleep 30 &
            task_jump_child=$!
            trap 'kill "$task_jump_child" 2>/dev/null; wait "$task_jump_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_jump_child" > "$0.started"
            wait "$task_jump_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = GitRepository(root: root, executable: wrapper), token = OperationCancellation()
        let snapshot = rows
        let task = Task { try await slow.historyJump(entries: snapshot, selected: [b], kind: .tagFF, up: true, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: wrapper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await task.result; XCTFail("Ancestry read never started"); return }
        let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        token.cancel()
        do { _ = try await task.value; XCTFail() } catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pids.count, 2); XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        let independent = try await repo.historyJump(entries: rows, selected: [b], kind: .tagFF, up: true); XCTAssertEqual(independent, 1)
        XCTAssertEqual(try? Data(contentsOf: root.appendingPathComponent(".git/index")), before)
    }
    func testEditableNotesPreserveExactBytesEmptyNotesRefAndWorkingState() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await repo.history()[0]
        let head = entry.hash, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("unstaged note test\n".utf8).write(to: root.appendingPathComponent(path))
        let initial = try await repo.editableCommitNote(revision: head)
        XCTAssertEqual(initial.text, ""); XCTAssertEqual(initial.notesRef, "refs/notes/commits")
        let exact = "  leading  \n# literal comment\n雪😀\r\n\ntrailing  "
        _ = try await repo.saveCommitNote(initial, text: exact)
        let loaded = try await repo.editableCommitNote(revision: head); XCTAssertEqual(loaded.text, exact)
        let blob = try await repo.run(["notes", "list", head]).text.trimmingCharacters(in: .newlines)
        let bytes = try await repo.run(["cat-file", "blob", blob]).stdout; XCTAssertEqual(bytes, Data(exact.utf8))
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/review"])
        let review = try await repo.editableCommitNote(revision: head); XCTAssertEqual(review.text, "")
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/other"])
        _ = try await repo.saveCommitNote(review, text: "review note")
        let written = try await repo.run(["notes", "--ref=refs/notes/review", "show", head]).text; XCTAssertTrue(written.contains("review note"))
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/commits"])
        _ = try await repo.saveCommitNote(loaded, text: "")
        let empty = try await repo.editableCommitNote(revision: head); XCTAssertEqual(empty.text, "")
        let emptyID = try await repo.run(["notes", "list", head]).text.trimmingCharacters(in: .newlines)
        let emptyBytes = try await repo.run(["cat-file", "blob", emptyID]).stdout; XCTAssertTrue(emptyBytes.isEmpty) // An empty note is stored, not removed.
        do { _ = try await repo.saveCommitNote(empty, text: "nul\0text"); XCTFail() } catch is CommitNoteFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("unstaged note test\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, head)
    }
    func testNoteMinimumLengthProjectIncludesLocalOverrideAndBareRepository() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        let bareRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: bareRoot) }
        try Data("[include]\n path = note-settings\n".utf8).write(to: root.appendingPathComponent(".tgitconfig"))
        try Data("[tgit]\n logminsize = 4\n".utf8).write(to: root.appendingPathComponent("note-settings"))
        let entry = try await repo.history()[0]
        let project = try await repo.editableCommitNote(revision: entry.hash)
        XCTAssertEqual(project.minimumLength, 4); XCTAssertFalse(project.accepts("abc")); XCTAssertTrue(project.accepts("😀😀"))
        do { _ = try await repo.saveCommitNote(project, text: "abc"); XCTFail() } catch is CommitNoteFailure {}
        _ = try await repo.run(["config", "tgit.logminsize", "2"])
        let local = try await repo.editableCommitNote(revision: entry.hash); XCTAssertEqual(local.minimumLength, 2)
        _ = try await repo.run(["config", "--unset", "tgit.logminsize"])
        try Data("[tgit]\n logminsize = 3\n".utf8).write(to: root.appendingPathComponent(".tgitconfig"))
        try await repo.stage([".tgitconfig"]); _ = try await repo.commit(message: "project notes settings")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot)
        _ = try await bare.run(["config", "user.name", "Note"]); _ = try await bare.run(["config", "user.email", "note@example.invalid"])
        let snapshot = try await bare.editableCommitNote(revision: "HEAD"); XCTAssertEqual(snapshot.minimumLength, 3)
        _ = try await bare.saveCommitNote(snapshot, text: "Bare note 雪")
        let reread = try await bare.editableCommitNote(revision: "HEAD"); XCTAssertEqual(reread.text, "Bare note 雪")
    }
    func testNoteSavedButDisplayRefreshFailureReportsCompletedWrite() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repo.editableCommitNote(revision: "HEAD")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let wrapper = root.appendingPathComponent("fail-note-display")
        let script = """
        #!/bin/sh
        case "$*" in
          *--format=%N*) echo 'display refresh failed' >&2; exit 91 ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let failing = GitRepository(root: root, executable: wrapper)
        do { _ = try await failing.saveCommitNote(note, text: "written before display failure"); XCTFail() }
        catch CommitNoteFailure.savedButRefreshFailed(let message) { XCTAssertTrue(message.contains("display refresh failed")) }
        let read = try await repo.editableCommitNote(revision: note.revision); XCTAssertEqual(read.text, "written before display failure")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, note.revision)
    }
    func testOwnedNoteReadCancellationAndIndependentRead() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await repo.history()[0], snapshot = try await repo.editableCommitNote(revision: "HEAD")
        _ = try await repo.saveCommitNote(snapshot, text: "cancel read note")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.editableCommitNote(revision: entry.hash, cancellation: stopped); XCTFail() } catch is OperationCancellationFailure {}
        let wrapper = root.appendingPathComponent("slow-note-read")
        let script = """
        #!/bin/sh
        case "$*" in
          *cat-file*)
            /bin/sleep 30 &
            task_note_child=$!
            trap 'kill "$task_note_child" 2>/dev/null; wait "$task_note_child" 2>/dev/null; exit 143' TERM INT
            echo "$$ $task_note_child" > "$0.started"
            wait "$task_note_child"
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = GitRepository(root: root, executable: wrapper), token = OperationCancellation()
        let task = Task { try await slow.editableCommitNote(revision: entry.hash, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: wrapper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await task.result; XCTFail("Note read never started"); return }
        let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        token.cancel()
        do { _ = try await task.value; XCTFail() } catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pids.count, 2); XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        let independent = try await repo.editableCommitNote(revision: entry.hash); XCTAssertEqual(independent.text, "cancel read note")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testMergeRevertEachMainlinePreservesUnrelatedChangesAndDoesNotCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Revert"]); _ = try await repo.run(["config", "user.email", "revert@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        for (name, text) in [("main.txt", "M0\n"), ("side.txt", "S0\n"), ("unrelated.txt", "U0\n")] { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(["main.txt", "side.txt", "unrelated.txt"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "side"])
        try Data("S1\n".utf8).write(to: root.appendingPathComponent("side.txt")); try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "Side change & title")
        _ = try await repo.run(["checkout", "main"])
        try Data("M1\n".utf8).write(to: root.appendingPathComponent("main.txt")); try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "Main change with a very long title")
        let normal = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge"])
        let merge = try await repo.history()[0], index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for parent in [nil, 0, 3] as [Int?] {
            do { _ = try await repo.revertLogRevision(revision: merge.hash, mainline: parent); XCTFail() } catch is LogRevertFailure {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        }
        do { _ = try await repo.revertLogRevision(revision: base); XCTFail() } catch LogRevertFailure.root {}
        try Data((normal + "\n").utf8).write(to: root.appendingPathComponent(".git/MERGE_HEAD"))
        let active = try await repo.logMergeActive(); XCTAssertTrue(active)
        do { _ = try await repo.revertLogRevision(revision: merge.hash, mainline: 1); XCTFail() } catch LogRevertFailure.mergeActive {}
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/MERGE_HEAD"))
        for parent in [1, 2] {
            _ = try await repo.run(["reset", "--hard", merge.hash])
            try Data("US\n".utf8).write(to: root.appendingPathComponent("unrelated.txt")); try await repo.stage(["unrelated.txt"])
            try Data("UW\n".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
            _ = try await repo.revertLogRevision(revision: merge.hash, mainline: parent)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.txt")), parent == 1 ? "M1\n" : "M0\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("side.txt")), parent == 1 ? "S0\n" : "S1\n")
            let staged = try await repo.run(["show", ":unrelated.txt"]).stdout; XCTAssertEqual(staged, Data("US\n".utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unrelated.txt")), Data("UW\n".utf8))
            let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, merge.hash)
        }
        _ = try await repo.run(["reset", "--hard", merge.hash]); _ = try await repo.revertLogRevision(revision: normal)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.txt")), "M0\n")
        _ = try await repo.run(["reset", "--hard", merge.hash])
        try Data("later incompatible\n".utf8).write(to: root.appendingPathComponent("side.txt")); try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "later")
        let later = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        do { _ = try await repo.revertLogRevision(revision: merge.hash, mainline: 1); XCTFail() } catch is GitFailure {}
        let unmerged = try await repo.run(["ls-files", "--unmerged"]).stdout; XCTAssertFalse(unmerged.isEmpty)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, later)
    }
    func testParentMetadataLabelsFallbackAndOwnedCancellation() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.history()[0], index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var entry = head; entry.parents = [head.hash, String(repeating: "a", count: 40)]
        let choices = try await repo.logParentChoices(entry)
        XCTAssertEqual(choices.map(\.number), [1, 2]); XCTAssertEqual(choices[0].subject, head.subject); XCTAssertNil(choices[1].subject)
        XCTAssertEqual(choices[1].title, "Parent 2 (aaaaaaaa)")
        XCTAssertEqual(LogParentChoice(number: 3, hash: head.hash, subject: "12345678901234567890 & after").title, "Parent 3: \"12345678901234567890...\" (" + head.hash.prefix(8) + ")")
        XCTAssertTrue(LogParentChoice(number: 1, hash: head.hash, subject: "A & B").title.contains("A & B"))
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try await repo.logParentChoices(entry, cancellation: stopped); XCTFail() } catch is OperationCancellationFailure {}
        let wrapper = root.appendingPathComponent("slow-parent-read")
        let script = """
        #!/bin/sh
        /bin/sleep 30 &
        task_parent_child=$!
        trap 'kill "$task_parent_child" 2>/dev/null; wait "$task_parent_child" 2>/dev/null; exit 143' TERM INT
        echo "$$ $task_parent_child" > "$0.started"
        wait "$task_parent_child"
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = GitRepository(root: root, executable: wrapper), token = OperationCancellation(), snapshot = entry
        let task = Task { try await slow.logParentChoices(snapshot, cancellation: token) }
        defer { token.cancel() }
        let marker = URL(fileURLWithPath: wrapper.path + ".started"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else { token.cancel(); _ = await task.result; XCTFail("Parent read never started"); return }
        let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }; token.cancel()
        do { _ = try await task.value; XCTFail() } catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        let reaped = Date().addingTimeInterval(3)
        while Date() < reaped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pids.count, 2); XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
        let independent = try await repo.logParentChoices(entry); XCTAssertEqual(independent, choices)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testRealHistoryDetailsRefsFilteringAndMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History Tests"])
        _ = try await repo.run(["config", "user.email", "history@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let weird = "initial\t雪\n.txt"
        try Data("line one\nline two\n".utf8).write(to: root.appendingPathComponent(weird))
        try await repo.stage([weird]); _ = try await repo.commit(message: "Initial\n\nMultiline body\nAnother line")
        let initialHistory = try await repo.history()
        let initial = try XCTUnwrap(initialHistory.first)
        XCTAssertEqual(initial.email, "history@example.invalid")
        XCTAssertTrue(initial.message.contains("Multiline body\nAnother line"))
        XCTAssertTrue(initial.isHead)
        XCTAssertEqual(initial.references.filter(\.isCurrent).map(\.name), ["refs/heads/main"])
        let initialFiles = try await repo.files(in: initial)
        XCTAssertEqual(initialFiles.first?.path, weird)
        XCTAssertEqual(initialFiles.first?.added, 2)
        let rootActions = try await repo.revisionActions(in: initial); XCTAssertEqual(rootActions, .added)
        _ = try await repo.run(["switch", "-c", "feature"])
        _ = try await repo.run(["mv", "--", weird, "renamed.txt"])
        _ = try await repo.commit(message: "Rename on feature")
        let renamedHistory = try await repo.history()
        let renamed = try XCTUnwrap(renamedHistory.first)
        let renamedFiles = try await repo.files(in: renamed)
        XCTAssertEqual(renamedFiles.first?.oldPath, weird)
        XCTAssertEqual(renamedFiles.first?.status, "Renamed")
        XCTAssertEqual(renamedFiles.first?.removed, 0)
        let renameActions = try await repo.revisionActions(in: renamed); XCTAssertEqual(renameActions, .replaced)
        _ = try await repo.run(["tag", "-a", "v1", "-m", "Annotated tag"])
        _ = try await repo.run(["switch", "main"])
        try Data("main change\n".utf8).write(to: root.appendingPathComponent("main.txt"))
        try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "Main work")
        _ = try await repo.run(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let history = try await repo.history()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[0].parents.count, 2)
        XCTAssertTrue(history.first { $0.hash == renamed.hash }!.references.contains { $0.name == "refs/tags/v1" })
        let mergeFiles = try await repo.files(in: history[0])
        XCTAssertEqual(mergeFiles.first?.status, "Renamed")
        let mergeActions = try await repo.revisionActions(in: history[0]); XCTAssertEqual(mergeActions, [.added, .replaced])
        var options = HistoryOptions(); options.search = "Multiline body"
        let filtered = try await repo.history(options: options)
        XCTAssertEqual(filtered.map(\.hash), [initial.hash])
        options.search = ""; options.limit = 2
        let limited = try await repo.history(options: options)
        XCTAssertEqual(limited.count, 2)
        let diff = try await repo.revisionDiff(history[0])
        XCTAssertTrue(diff.contains("rename to renamed.txt"))
    }
}
