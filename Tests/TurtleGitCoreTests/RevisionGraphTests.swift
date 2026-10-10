import XCTest
@testable import TurtleGitCore

final class RevisionGraphTests: XCTestCase {
    func repositoryFixture() async throws -> (URL, GitRepository) {
        let (root, original) = try await CommitSelectionTests().fixture()
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? original.executable
        return (root, GitRepository(root: root, executable: executable))
    }
    func testOrderedRewriteKeepsRootsBranchPointsMergeParentsAndNonTagLabels() throws {
        // Newest-first order is material: removing B then A must reconnect Tip
        // all the way to Root. Tags on a retained branch still remain labels.
        let tag = RevisionReference(name: "refs/tags/release", kind: .annotatedTag)
        let branch = RevisionReference(name: "refs/heads/main")
        let input = [RevisionGraphNode(hash: "tip", parents: ["b"], references: [branch]),
                     RevisionGraphNode(hash: "b", parents: ["a"], references: [tag]),
                     RevisionGraphNode(hash: "a", parents: ["root"]), RevisionGraphNode(hash: "root")]
        let compact = try RevisionGraphData.simplify(input, showAllTags: false, showBranchingsAndMerges: true)
        XCTAssertEqual(compact.map(\.hash), ["tip", "root"])
        XCTAssertEqual(compact[0].parents, ["root"])
        let tagged = try RevisionGraphData.simplify(input, showAllTags: true, showBranchingsAndMerges: true)
        XCTAssertEqual(tagged.map(\.hash), ["tip", "b", "root"])
        XCTAssertEqual(tagged[1].parents, ["root"])
        let protected = try RevisionGraphData.simplify(input, showAllTags: false, showBranchingsAndMerges: true, protectedHashes: ["a"])
        XCTAssertEqual(protected.map(\.hash), ["tip", "a", "root"])
        let merge = [RevisionGraphNode(hash: "merge", parents: ["left", "right"]),
                     RevisionGraphNode(hash: "left", parents: ["base"]), RevisionGraphNode(hash: "right", parents: ["base"]),
                     RevisionGraphNode(hash: "base", parents: ["root"]), RevisionGraphNode(hash: "root")]
        XCTAssertEqual(try RevisionGraphData.simplify(merge, showAllTags: false, showBranchingsAndMerges: true).map(\.hash), merge.map(\.hash))
        let labelled = [RevisionGraphNode(hash: "tip", parents: ["other"], references: [branch, tag]),
                        RevisionGraphNode(hash: "other", parents: ["root"], references: [RevisionReference(name: "refs/custom/keep")]),
                        RevisionGraphNode(hash: "root")]
        XCTAssertEqual(try RevisionGraphData.simplify(labelled, showAllTags: false, showBranchingsAndMerges: false).map(\.hash), labelled.map(\.hash))
    }

    func fixture() async throws -> (URL, GitRepository, [String: String]) {
        let (root, repo) = try await repositoryFixture()
        try Data("graph fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        let tree = try await repo.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
        var hashes: [String: String] = [:]
        for (name, parents) in [("root", []), ("a", ["root"]), ("b", ["a"]), ("left", ["b"]), ("right", ["b"]), ("merge", ["left", "right"]), ("remote", ["root"]), ("tagOnly", ["root"])] {
            var arguments = ["commit-tree", tree, "-m", name]
            for parent in parents { arguments += ["-p", hashes[parent]!] }
            hashes[name] = try await repo.run(arguments).text.trimmingCharacters(in: .newlines)
        }
        for (reference, name) in [("refs/heads/main", "merge"), ("refs/heads/left", "left"), ("refs/remotes/origin/topic", "remote"), ("refs/tags/only", "tagOnly")] {
            _ = try await repo.run(["update-ref", reference, hashes[name]!])
        }
        _ = try await repo.run(["tag", "-a", "release", hashes["a"]!, "-m", "Annotated release"])
        _ = try await repo.run(["tag", "linear", hashes["b"]!])
        return (root, repo, hashes)
    }

    func testRepositoryScopesTagHidingAndBoundaryEdgesPreserveRepository() async throws {
        let (root, repo, h) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("staged".utf8).write(to: root.appendingPathComponent("dirty.txt"))
        try await repo.stage(["dirty.txt"])
        try Data("working".utf8).write(to: root.appendingPathComponent("dirty.txt"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let refs = try await repo.run(["show-ref"]).stdout
        let all = try await repo.revisionGraph()
        XCTAssertTrue(all.nodes.allSatisfy { !$0.author.isEmpty && !$0.authorDate.isEmpty && !$0.message.isEmpty })
        XCTAssertEqual(all.head, h["merge"])
        XCTAssertTrue(all.nodes.contains { $0.hash == h["remote"] })
        XCTAssertTrue(all.nodes.contains { $0.hash == h["tagOnly"] })
        XCTAssertTrue(all.nodes.first { $0.hash == h["a"] }!.references.contains { $0.kind == .annotatedTag })
        XCTAssertTrue(all.nodes.first { $0.hash == h["merge"] }!.references.contains { $0.isCurrent })
        var options = RevisionGraphOptions(); options.onlyLocalBranches = true
        let local = try await repo.revisionGraph(options: options)
        XCTAssertFalse(local.nodes.contains { $0.hash == h["remote"] || $0.hash == h["tagOnly"] })
        options.onlyCurrentBranch = true; options.to = "missing-and-ignored"
        let precedence = try await repo.revisionGraph(options: options)
        XCTAssertEqual(precedence.nodes.map(\.hash), local.nodes.map(\.hash))
        options.onlyLocalBranches = false; options.showAllTags = false; options.showBranchingsAndMerges = true
        let current = try await repo.revisionGraph(options: options)
        XCTAssertFalse(current.nodes.contains { $0.hash == h["a"] })
        XCTAssertTrue(current.nodes.contains { $0.hash == h["b"] }, "Branch point survives tag hiding")
        XCTAssertEqual(current.nodes.first { $0.hash == h["b"] }?.parents, [h["root"]!])
        XCTAssertEqual(Set(current.nodes.first { $0.hash == h["merge"] }!.parents), Set([h["left"]!, h["right"]!]))
        options = RevisionGraphOptions(); options.to = "left\norigin/topic"; options.from = "release"
        let range = try await repo.revisionGraph(options: options)
        XCTAssertFalse(range.nodes.contains { $0.hash == h["merge"] })
        XCTAssertTrue(range.nodes.contains { $0.hash == h["remote"] })
        XCTAssertTrue(range.nodes.contains { $0.hash == h["a"] && $0.isBoundary && $0.parents.isEmpty })
        XCTAssertTrue(range.nodes.contains { $0.hash == h["root"] && $0.isBoundary })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        let refsAfter = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(refsAfter, refs)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("dirty.txt"), encoding: .utf8), "working")
        options.to = "--all"
        do { _ = try await repo.revisionGraph(options: options); XCTFail("Revision text must not become a Git option") } catch {}
    }

    func testUnbornDetachedAndCancellation() async throws {
        let (root, repo) = try await repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try await repo.revisionGraph()
        XCTAssertTrue(empty.nodes.isEmpty)
        var options = RevisionGraphOptions(); options.onlyCurrentBranch = true
        let emptyCurrent = try await repo.revisionGraph(options: options)
        XCTAssertTrue(emptyCurrent.nodes.isEmpty)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.revisionGraph(cancellation: token); XCTFail("Cancelled graph read") } catch {}
        try Data("detached fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        let tree = try await repo.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
        let hash = try await repo.run(["commit-tree", tree, "-m", "detached"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "--no-deref", "HEAD", hash])
        let unreferenced = try await repo.revisionGraph(options: options)
        let oracle = try await repo.run(["log", "--format=%H", "--topo-order", "--parents", "--simplify-by-decoration", "HEAD", "--"]).text
        XCTAssertEqual(unreferenced.nodes.map(\.hash), oracle.split(separator: "\n").map { String($0.split(separator: " ")[0]) })
        XCTAssertEqual(unreferenced.head, hash)
        _ = try await repo.run(["tag", "detached-tip", hash])
        let detached = try await repo.revisionGraph(options: options)
        XCTAssertEqual(detached.nodes.map(\.hash), [hash])
        XCTAssertTrue(detached.nodes.first?.isHead == true)
        XCTAssertTrue(detached.nodes.first?.references.contains { $0.isCurrent } == false)
    }

    func testSuperprojectIndexPointersSurviveTagHidingIncludingConflicts() async throws {
        let (source, _, h) = try await fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let (parent, superproject) = try await repositoryFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        _ = try await superproject.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", source.path, "child"])
        let child = GitRepository(root: parent.appendingPathComponent("child"), executable: superproject.executable)
        var options = RevisionGraphOptions(); options.showAllTags = false; options.showBranchingsAndMerges = true
        _ = try await superproject.run(["update-index", "--cacheinfo", "160000," + h["a"]! + ",child"])
        let index = try Data(contentsOf: parent.appendingPathComponent(".git/index"))
        let graph = try await child.revisionGraph(options: options)
        XCTAssertEqual(graph.superprojectHashes, [h["a"]!])
        XCTAssertEqual(graph.superprojectLabels, [h["a"]!: ["super-project-pointer"]])
        XCTAssertTrue(graph.nodes.contains { $0.hash == h["a"] })
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(".git/index")), index)
        options.showSuperprojectPointers = false
        let hidden = try await child.revisionGraph(options: options)
        XCTAssertFalse(hidden.nodes.contains { $0.hash == h["a"] })
        options.showSuperprojectPointers = true
        var trees: [String] = []
        for name in ["root", "a", "b"] {
            _ = try await superproject.run(["update-index", "--cacheinfo", "160000," + h[name]! + ",child"])
            trees.append(try await superproject.run(["write-tree"]).text.trimmingCharacters(in: .newlines))
        }
        _ = try await superproject.run(["read-tree", trees[1]])
        _ = try await superproject.run(["read-tree", "-m"] + trees)
        let conflictIndex = try Data(contentsOf: parent.appendingPathComponent(".git/index"))
        let conflict = try await child.revisionGraph(options: options)
        XCTAssertEqual(conflict.superprojectHashes, Set([h["a"]!, h["b"]!]))
        XCTAssertEqual(conflict.superprojectLabels, [h["a"]!: ["super-project-head"], h["b"]!: ["super-project-merge-head"]])
        XCTAssertTrue(conflict.nodes.contains { $0.hash == h["a"] })
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(".git/index")), conflictIndex)
        for name in ["rebase-apply", "rebase-merge", "tgitrebase.active"] {
            let path = try await superproject.run(["rev-parse", "--git-path", name]).text.trimmingCharacters(in: .newlines)
            let directory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : parent.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rebasing = try await child.revisionGraph(options: options)
            XCTAssertEqual(rebasing.superprojectLabels, [h["a"]!: ["super-project-rebase-head"], h["b"]!: ["super-project-head"]])
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(".git/index")), conflictIndex)
            try FileManager.default.removeItem(at: directory)
        }

    }

    func testShortReferenceWarningsDoNotContaminateMultiReferenceRange() async throws {
        let (root, repo, hashes) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "main", hashes["merge"]!])
        let resolved = try await repo.run(["rev-parse", "--verify", "--end-of-options", "main^{commit}"])
        XCTAssertTrue(String(decoding: resolved.stderr, as: UTF8.self).contains("ambiguous"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let refs = try await repo.run(["show-ref"]).stdout
        var short = RevisionGraphOptions(); short.to = "main tags/release"
        var canonical = short; canonical.to = "refs/tags/main refs/tags/release"
        let actual = try await repo.revisionGraph(options: short), expected = try await repo.revisionGraph(options: canonical)
        XCTAssertEqual(actual.nodes.map(\.hash), expected.nodes.map(\.hash))
        XCTAssertEqual(actual.nodes.map(\.parents), expected.nodes.map(\.parents))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        let refsAfter = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(refsAfter, refs)
    }

    func testBareGraphHasNoSuperprojectAndMatchesWorkingRepository() async throws {
        let (root, repo, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--mirror", "--", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        let graph = try await bare.revisionGraph()
        let working = try await repo.revisionGraph()
        XCTAssertEqual(graph.nodes.map(\.hash), working.nodes.map(\.hash))
        XCTAssertEqual(graph.nodes.map(\.parents), working.nodes.map(\.parents))
        XCTAssertTrue(graph.superprojectHashes.isEmpty)
    }
}
