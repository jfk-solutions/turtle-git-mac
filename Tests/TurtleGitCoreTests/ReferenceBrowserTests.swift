import XCTest
@testable import TurtleGitCore

final class ReferenceBrowserTests: XCTestCase {
    func testRemoteResolutionUsesConfiguredOrderAndExactNamespaces() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["team", "team/nested", "origin"] { _ = try await repo.run(["remote", "add", name, root.path]) }
        let snapshot = try await repo.referenceBrowser()
        XCTAssertEqual(snapshot.remote(for: GitReferenceName("refs/remotes/team/nested/topic")), "team")
        XCTAssertEqual(snapshot.remote(for: GitReferenceName("refs/remotes/origin/HEAD")), "origin")
        XCTAssertNil(snapshot.remote(for: GitReferenceName("refs/remotes/origin-other/topic")))
        XCTAssertNil(snapshot.remote(for: GitReferenceName("refs/heads/origin/topic")))
    }
    func testCurrentBranchReadsLiveHeadUnbornDetachedBareWorktreeAndCancellation() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let initial = try await repo.referenceBrowser()
        _ = try await repo.run(["branch", "late/topic"])
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/late/topic"])
        XCTAssertEqual(initial.currentBranch, "refs/heads/main")
        let live = try await repo.referenceBrowserCurrentBranch(); XCTAssertEqual(live, "refs/heads/late/topic")
        _ = try await repo.run(["checkout", "--detach", head])
        let detached = try await repo.referenceBrowserCurrentBranch(); XCTAssertEqual(detached, head)
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        _ = try await bare.run(["update-ref", "--no-deref", "HEAD", head])
        let bareDetached = try await bare.referenceBrowserCurrentBranch(); XCTAssertEqual(bareDetached, head)
        _ = try await bare.run(["symbolic-ref", "HEAD", "refs/heads/main"])
        let bareBranch = try await bare.referenceBrowserCurrentBranch(); XCTAssertEqual(bareBranch, "refs/heads/main")
        let unbornRoot = root.appendingPathComponent("unborn.git"); _ = try await repo.run(["init", "--bare", "-b", "unborn/topic", unbornRoot.path])
        let unborn = try await GitRepository(root: unbornRoot, executable: repo.executable).referenceBrowserCurrentBranch(); XCTAssertEqual(unborn, "refs/heads/unborn/topic")
        let worktreeRoot = root.appendingPathComponent("linked"); _ = try await repo.run(["worktree", "add", worktreeRoot.path, "late/topic"])
        let linked = try await GitRepository(root: worktreeRoot, executable: repo.executable).referenceBrowserCurrentBranch(); XCTAssertEqual(linked, "refs/heads/late/topic")
        // Preserve the actual symbolic HEAD spelling even with precomposition enabled.
        _ = try await repo.run(["config", "core.precomposeunicode", "true"])
        try Data("ref: refs/heads/Cafe\u{301}/unborn\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), headBytes = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        let unicode = try await repo.referenceBrowserCurrentBranch(); XCTAssertTrue(unicode.utf8.elementsEqual("refs/heads/Cafe\u{301}/unborn".utf8))
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.referenceBrowserCurrentBranch(cancellation: cancelled); XCTFail("Cancelled current-branch query ran") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        XCTAssertEqual(headBytes, try Data(contentsOf: root.appendingPathComponent(".git/HEAD")))
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("base\n".utf8))
    }
    func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-reference-browser-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Raw Author"), ("user.email", "raw@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("Canonical Author <canonical@example.invalid> Raw Author <raw@example.invalid>\n".utf8).write(to: root.appendingPathComponent(".mailmap"))
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["."])
        _ = try await repo.run(["commit", "-m", "base red fox"], environmentOverrides: ["GIT_AUTHOR_DATE": "2001-01-02T03:04:05+02:00", "GIT_COMMITTER_DATE": "2001-01-03T04:05:06+01:00"])
        return (root, repo)
    }
    func testAllNamespacesMetadataTagMailmapGoneAndNoMutation() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await repo.run(["branch", "gone"])
        for (branch, merge) in [("main", "main"), ("gone", "missing")] { _ = try await repo.run(["config", "branch." + branch + ".remote", "origin"]); _ = try await repo.run(["config", "branch." + branch + ".merge", "refs/heads/" + merge]) }
        _ = try await repo.run(["config", "branch.main.description", "first line\nsecond line"])
        _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "tag blue fox"], environmentOverrides: ["GIT_COMMITTER_DATE": "2002-02-03T04:05:06+03:00"])
        _ = try await repo.run(["update-ref", "refs/notes/custom", "HEAD"])
        let blob = try await repo.run(["hash-object", "-w", "file"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/custom/blob", blob])
        let treeHash = try await repo.run(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["update-ref", "refs/custom/tree", treeHash])
        let head = try await repo.run(["rev-parse", "HEAD"]).text, indexTree = try await repo.run(["write-tree"]).text
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let snapshot = try await repo.referenceBrowser()
        XCTAssertEqual(snapshot.currentBranch, "refs/heads/main")
        let main = try XCTUnwrap(snapshot.references.first { $0.name == "refs/heads/main" })
        XCTAssertEqual(main.author, "Canonical Author"); XCTAssertEqual(main.committer, "Canonical Author"); XCTAssertEqual(main.upstream, "origin/main"); XCTAssertEqual(main.description, "first line\nsecond line")
        XCTAssertEqual(main.authorDate, ISO8601DateFormatter().date(from: "2001-01-02T01:04:05Z")!.timeIntervalSince1970)
        XCTAssertEqual(main.committerDate, ISO8601DateFormatter().date(from: "2001-01-03T03:05:06Z")!.timeIntervalSince1970)
        XCTAssertEqual(snapshot.references.first { $0.name == "refs/heads/gone" }?.upstream, "(gone: origin/missing)")
        let tag = try XCTUnwrap(snapshot.references.first { $0.name == "refs/tags/release" })
        let tagHash = try await repo.run(["rev-parse", "refs/tags/release"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(tag.objectType, "tag"); XCTAssertEqual(tag.hash, tagHash); XCTAssertEqual(tag.subject, "tag blue fox"); XCTAssertEqual(tag.author, "Canonical Author"); XCTAssertEqual(tag.authorDate, tag.committerDate)
        XCTAssertEqual(snapshot.references.first { $0.name == "refs/custom/blob" }?.objectType, "blob")
        XCTAssertEqual(snapshot.references.first { $0.name == "refs/custom/tree" }?.hash, treeHash)
        XCTAssertTrue(snapshot.folders.contains("refs/notes")); XCTAssertTrue(snapshot.folders.contains("refs/custom")); XCTAssertTrue(snapshot.folders.contains("refs/remotes/origin"))
        let alias = snapshot.references.first { $0.name == "refs/remotes/origin/HEAD" }; XCTAssertEqual(alias?.symbolicTarget, "refs/remotes/origin/main")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text, afterTree = try await repo.run(["write-tree"]).text
        XCTAssertEqual(head, afterHead); XCTAssertEqual(indexTree, afterTree); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
    }
    func testNestedScopeTextFiltersExactUnicodeAndCheckoutClassification() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let nfc = "refs/heads/Café/leaf", nfd = "refs/heads/Cafe\u{301}/leaf", mark = "refs/tags/\u{301}tag"
        for name in [nfc, nfd, mark, "refs/heads/nested/topic2", "refs/heads/nested/topic10"] { _ = try await repo.run(["update-ref", name, "HEAD"]) }
        // APFS canonical-equivalent loose paths alias; packed refs preserve both spellings.
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let oid = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let names = ["refs/heads/main", nfc, nfd, mark, "refs/heads/nested/topic2", "refs/heads/nested/topic10"].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        try Data(("# pack-refs with: sorted\n" + names.map { oid + " " + $0 + "\n" }.joined()).utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let snapshot = try await repo.referenceBrowser()
        XCTAssertTrue(snapshot.folders.contains("refs/heads/Café")); XCTAssertTrue(snapshot.folders.contains("refs/heads/Cafe\u{301}"))
        XCTAssertEqual(snapshot.initialSelection(nfd).reference, GitReferenceName(nfd)); XCTAssertEqual(snapshot.initialSelection(nfd).folder, "refs/heads/Cafe\u{301}")
        let direct = snapshot.rows(folder: "refs/heads", nested: false); XCTAssertEqual(direct.map(\.name), ["main"])
        XCTAssertEqual(snapshot.rows(folder: "refs/heads/nested", nested: true).map(\.name), ["topic10", "topic2"])
        XCTAssertTrue(snapshot.rows(folder: "refs/heads", nested: true, query: "heads/", fields: .referenceNames).isEmpty)
        XCTAssertFalse(snapshot.rows(folder: "refs", nested: true, query: "heads/", fields: .referenceNames).isEmpty)
        XCTAssertEqual(snapshot.rows(folder: "refs/heads", nested: true, query: "red fox -blue", fields: .subject).count, 5)
        XCTAssertTrue(snapshot.rows(folder: "refs/heads", nested: true, query: "\"red fox\" -blue", fields: .subject).isEmpty) // source's post-quote prefix behavior
        XCTAssertTrue(snapshot.rows(folder: "refs/heads", nested: true, query: "Raw Author", fields: .authors).isEmpty)
        XCTAssertEqual(snapshot.rows(folder: "refs/heads", nested: true, query: "Canonical", fields: .authors).count, 5)
        let references = try await repo.checkoutReferences()
        let tag = try XCTUnwrap(references.first { GitReferenceName.equal($0.name, mark) }); XCTAssertEqual(tag.target, .tag); XCTAssertEqual(tag.label, "\u{301}tag")
        var options = CheckoutOptions(); options.target = .tag; options.revision = mark; try await repo.validateCheckout(options)
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.referenceBrowser(cancellation: cancelled); XCTFail("Cancelled metadata query ran") } catch OperationCancellationFailure.cancelled {}
    }
    func testMergedUnmergedBareAndEmptyCatalogs() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["checkout", "-b", "unmerged"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "new blue fox"]); _ = try await repo.run(["checkout", "main"])
        let merged = try await repo.referenceBrowser(filter: .merged), unmerged = try await repo.referenceBrowser(filter: .unmerged)
        XCTAssertEqual(merged.references.map(\.name), ["refs/heads/main"]); XCTAssertEqual(unmerged.references.map(\.name), ["refs/heads/unmerged"])
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = try await GitRepository(root: bareRoot, executable: repo.executable).referenceBrowser(); XCTAssertEqual(bare.initialSelection("HEAD").reference, "refs/heads/main")
        let emptyRoot = root.appendingPathComponent("empty.git"); _ = try await repo.run(["init", "--bare", "-b", "main", emptyRoot.path])
        let empty = try await GitRepository(root: emptyRoot, executable: repo.executable).referenceBrowser(); XCTAssertTrue(empty.references.isEmpty); XCTAssertEqual(empty.folders, ["refs"])
    }
    func testDescriptionWriteClearCancellationAndExactUnicodeKeys() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        _ = try await repo.run(["config", "core.precomposeunicode", "true"])
        let nfc = "Café", nfd = "Cafe\u{301}"
        let configURL = root.appendingPathComponent(".git/config")
        var raw = try Data(contentsOf: configURL)
        raw.append(Data(("\n[branch \"" + nfc + "\"]\n\tdescription = NFC\n[branch \"" + nfd + "\"]\n\tdescription = NFD\n").utf8))
        try raw.write(to: configURL)
        try await repo.updateBranchDescription(nfd, message: "  first\r\nsecond  ")
        // Enumerate raw keys: individual config lookup argument normalization is
        // separate from verifying the exact bytes persisted by this writer.
        let values = try await repo.run(["config", "--local", "--null", "--list"]).stdout
        XCTAssertNotNil(values.range(of: Data(("branch." + nfc + ".description\nNFC\0").utf8)))
        XCTAssertNotNil(values.range(of: Data(("branch." + nfd + ".description\nfirst\nsecond\0").utf8)))
        try await repo.updateBranchDescription(nfd, message: "cancellable", cancellation: OperationCancellation())
        let cancellable = try await repo.run(["config", "--local", "--null", "--list"]).stdout
        XCTAssertNotNil(cancellable.range(of: Data(("branch." + nfd + ".description\ncancellable\0").utf8)))
        XCTAssertNotNil(cancellable.range(of: Data(("branch." + nfc + ".description\nNFC\0").utf8)))
        try await repo.updateBranchDescription(nfd, message: " \r\n ")
        let cleared = try await repo.run(["config", "--local", "--null", "--list"]).stdout
        XCTAssertNil(cleared.range(of: Data(("branch." + nfd + ".description\n").utf8)))
        XCTAssertNotNil(cleared.range(of: Data(("branch." + nfc + ".description\nNFC\0").utf8)))
        try await repo.updateBranchDescription(nfd, message: "") // already absent
        let config = try Data(contentsOf: configURL), cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repo.updateBranchDescription(nfc, message: "bad", cancellation: cancelled); XCTFail("Cancelled write ran") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(config, try Data(contentsOf: configURL))
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(head, afterHead)
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        try await bare.updateBranchDescription("main", message: "bare description")
        let snapshot = try await bare.referenceBrowser(); XCTAssertEqual(snapshot.references.first { $0.name == "refs/heads/main" }?.description, "bare description")
    }

    func testBrowserBranchRenameMovesConfigReflogAndCurrentBranchWithoutCheckout() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "nested/topic"])
        _ = try await repo.run(["branch", "nested/neighbor"])
        _ = try await repo.run(["branch", "else/refs/heads/nested/topic"])
        _ = try await repo.run(["config", "branch.nested/topic.description", "description\nsecond"])
        _ = try await repo.run(["config", "branch.nested/topic.remote", "origin"])
        _ = try await repo.run(["config", "branch.nested/topic.merge", "refs/heads/main"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        try await repo.renameBrowserBranch("refs/heads/nested/topic", folder: "refs/heads", label: "other/renamed", cancellation: OperationCancellation())
        let snapshot = try await repo.referenceBrowser()
        XCTAssertFalse(snapshot.references.contains { $0.name == "refs/heads/nested/topic" })
        XCTAssertEqual(snapshot.initialSelection("refs/heads/nested/topic").folder, "refs/heads/nested")
        XCTAssertNil(snapshot.initialSelection("refs/heads/nested/topic").reference)
        let moved = try XCTUnwrap(snapshot.references.first { $0.name == "refs/heads/other/renamed" }); XCTAssertEqual(moved.description, "description\nsecond")
        let remote = try await repo.run(["config", "--get", "branch.other/renamed.remote"]).text; XCTAssertEqual(remote, "origin\n")
        let log = try await repo.run(["reflog", "show", "refs/heads/other/renamed"]).text; XCTAssertTrue(log.contains("renamed refs/heads/nested/topic to refs/heads/other/renamed"))
        try await repo.renameBrowserBranch("refs/heads/main", folder: "refs", label: "heads/current")
        let branch = try await repo.run(["symbolic-ref", "HEAD"]).text; XCTAssertEqual(branch, "refs/heads/current\n")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, after)
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(file, try Data(contentsOf: root.appendingPathComponent("file")))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        for (ref, folder, label) in [("refs/tags/release", "refs/tags", "other"), ("refs/heads/current", "refs", "tags/current"), ("refs/heads/current", "refs/heads", "other/renamed"), ("refs/heads/current", "refs/heads", "bad name"), ("refs/heads/current", "refs/heads", "-dash")] {
            do { try await repo.renameBrowserBranch(GitReferenceName(ref), folder: GitReferenceName(folder), label: label); XCTFail("Invalid/conflicting rename ran") } catch {}
        }
        XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repo.renameBrowserBranch("refs/heads/current", folder: "refs/heads", label: "cancelled", cancellation: cancelled); XCTFail("Cancelled rename ran") } catch OperationCancellationFailure.cancelled {}
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        try await bare.renameBrowserBranch("refs/heads/current", folder: "refs/heads", label: "bare-renamed")
        let bareHead = try await bare.run(["symbolic-ref", "HEAD"]).text; XCTAssertEqual(bareHead, "refs/heads/bare-renamed\n")
    }

    func testRenameDistinguishesPackedCanonicalEquivalentBranches() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let nfc = "Café", nfd = "Cafe\u{301}"
        try Data(("# pack-refs with: sorted\n" + ["refs/heads/main", "refs/heads/" + nfc, "refs/heads/" + nfd].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { hash + " " + $0 + "\n" }.joined()).utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let configURL = root.appendingPathComponent(".git/config"); var config = try Data(contentsOf: configURL)
        config.append(Data(("\n[branch \"" + nfc + "\"]\n description = NFC\n[branch \"" + nfd + "\"]\n description = NFD\n").utf8)); try config.write(to: configURL)
        try await repo.renameBrowserBranch(GitReferenceName("refs/heads/" + nfd), folder: "refs/heads", label: "unicode-renamed", cancellation: OperationCancellation())
        let snapshot = try await repo.referenceBrowser()
        XCTAssertTrue(snapshot.references.contains { $0.name == GitReferenceName("refs/heads/" + nfc) })
        XCTAssertFalse(snapshot.references.contains { $0.name == GitReferenceName("refs/heads/" + nfd) })
        XCTAssertEqual(snapshot.references.first { $0.name == "refs/heads/unicode-renamed" }?.description, "NFD")
        XCTAssertEqual(snapshot.references.first { $0.name == GitReferenceName("refs/heads/" + nfc) }?.description, "NFC")
    }

    func testRemoteOnlyPickerAndTrackingFetchMappingUnsetPreservation() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["update-ref", "refs/notes/custom", "HEAD"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        for (key, value) in [("description", "keep me"), ("pushRemote", "other"), ("rebase", "true")] { _ = try await repo.run(["config", "branch.main." + key, value]) }
        let remote = try await repo.referenceBrowser(scope: .remotes)
        XCTAssertEqual(remote.references.map(\.name), ["refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        XCTAssertFalse(remote.folders.contains("refs/heads")); XCTAssertFalse(remote.folders.contains("refs/tags"))
        try await repo.updateBrowserTracking("refs/heads/main", upstream: "refs/remotes/origin/main", cancellation: OperationCancellation())
        let snapshot = try await repo.referenceBrowser(); XCTAssertEqual(snapshot.references.first { $0.name == "refs/heads/main" }?.upstream, "origin/main")
        let merge = try await repo.run(["config", "--get", "branch.main.merge"]).text; XCTAssertEqual(merge, "refs/heads/main\n")
        try await repo.updateBrowserTracking("refs/heads/main", upstream: nil)
        try await repo.updateBrowserTracking("refs/heads/main", upstream: nil) // absent keys accepted
        let config = try await repo.run(["config", "--local", "--null", "--list"]).stdout
        for (key, value) in [("description", "keep me"), ("pushremote", "other"), ("rebase", "true")] { XCTAssertNotNil(config.range(of: Data(("branch.main." + key + "\n" + value + "\0").utf8))) }
        XCTAssertNil(config.range(of: Data("branch.main.remote\n".utf8))); XCTAssertNil(config.range(of: Data("branch.main.merge\n".utf8)))
        _ = try await repo.run(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other"])
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        do { try await repo.updateBrowserTracking("refs/heads/main", upstream: "refs/remotes/origin/main"); XCTFail("Missing fetch mapping accepted") } catch ReferenceBrowserTrackingFailure.fetchMapping(let message) { XCTAssertFalse(message.isEmpty) }
        for upstream in ["refs/heads/main", "refs/remotes/unconfigured/main"] {
            do { try await repo.updateBrowserTracking("refs/heads/main", upstream: GitReferenceName(upstream)); XCTFail("Invalid remote accepted") } catch ReferenceBrowserTrackingFailure.remoteBranchRequired {}
        }
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repo.updateBrowserTracking("refs/heads/main", upstream: nil, cancellation: cancelled); XCTFail("Cancelled unset ran") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, after); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(file, try Data(contentsOf: root.appendingPathComponent("file")))
    }
    func testUnsetTrackingPreservesUnicodeSiblingAndForeignConfigLock() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let nfc = "Café", nfd = "Cafe\u{301}", configURL = root.appendingPathComponent(".git/config")
        var config = try Data(contentsOf: configURL)
        config.append(Data(([nfc, nfd].map { "\n[branch \"" + $0 + "\"]\n remote = origin\n merge = refs/heads/main\n description = keep\n" }.joined()).utf8)); try config.write(to: configURL)
        let lock = root.appendingPathComponent(".git/config.lock"); try Data("foreign".utf8).write(to: lock)
        do { try await repo.updateBrowserTracking(GitReferenceName("refs/heads/" + nfd), upstream: nil); XCTFail("Foreign lock ignored") } catch is GitFailure {}
        XCTAssertEqual(config, try Data(contentsOf: configURL)); XCTAssertEqual(try Data(contentsOf: lock), Data("foreign".utf8)); try FileManager.default.removeItem(at: lock)
        try await repo.updateBrowserTracking(GitReferenceName("refs/heads/" + nfd), upstream: nil, cancellation: OperationCancellation())
        let result = try await repo.run(["config", "--local", "--null", "--list"]).stdout
        XCTAssertNotNil(result.range(of: Data(("branch." + nfc + ".remote\norigin\0").utf8))); XCTAssertNotNil(result.range(of: Data(("branch." + nfd + ".description\nkeep\0").utf8)))
        XCTAssertNil(result.range(of: Data(("branch." + nfd + ".remote\n").utf8))); XCTAssertNil(result.range(of: Data(("branch." + nfd + ".merge\n").utf8)))
    }

}

extension ReferenceBrowserTests {
    func testBrowserDeletionWarningsForceDeleteAndCheckedOutFailure() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).stdout
        _ = try await repo.run(["branch", "merged"])
        _ = try await repo.run(["switch", "-c", "unmerged"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "branch only"])
        _ = try await repo.run(["switch", "main"])
        let merged = try await repo.browserDeletionConfirmation("refs/heads/merged")
        let unmerged = try await repo.browserDeletionConfirmation("refs/heads/unmerged")
        XCTAssertFalse(merged.warning); XCTAssertTrue(unmerged.unmerged)
        XCTAssertEqual(unmerged.message, "Do you really want to delete \"unmerged\"?\n\nThis branch is not fully merged into HEAD.")
        try await repo.deleteBrowserReference("refs/heads/unmerged")
        do { try await repo.deleteBrowserReference("refs/heads/main"); XCTFail("Checked-out branch deleted") } catch is GitFailure {}
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(base, after)
        let refs = try await repo.referenceBrowser(); XCTAssertFalse(refs.references.contains { $0.name == "refs/heads/unmerged" }); XCTAssertTrue(refs.references.contains { $0.name == "refs/heads/main" })
    }
    func testBrowserDeletionTagsBareAndExactUnicodePackedNames() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let decomposed = "Cafe\u{301}", composed = "Caf\u{e9}"
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let names = ["refs/heads/main", "refs/heads/" + decomposed, "refs/heads/" + composed].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        try Data(("# pack-refs with: sorted\n" + names.map { hash + " " + $0 + "\n" }.joined()).utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        _ = try await repo.run(["tag", "-a", "release", "-m", "release"])
        _ = try await repo.run(["pack-refs", "--all"])
        _ = try await repo.run(["config", "core.precomposeunicode", "true"])
        let tag = try await repo.browserDeletionConfirmation("refs/tags/release"); XCTAssertFalse(tag.warning)
        try await repo.deleteBrowserReference(GitReferenceName("refs/heads/" + decomposed))
        try await repo.deleteBrowserReference("refs/tags/release")
        let refs = try await repo.referenceBrowser(); XCTAssertFalse(refs.references.contains { $0.name == GitReferenceName("refs/heads/" + decomposed) }); XCTAssertTrue(refs.references.contains { $0.name == GitReferenceName("refs/heads/" + composed) }); XCTAssertFalse(refs.references.contains { $0.name == "refs/tags/release" })
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: repo.executable)
        try await bare.deleteBrowserReference(GitReferenceName("refs/heads/" + composed))
        let bareRefs = try await bare.referenceBrowser(); XCTAssertFalse(bareRefs.references.contains { $0.name == GitReferenceName("refs/heads/" + composed) })
    }
    func testBrowserRemoteDeletionUsesPushAndPreservesLocalBranchAndTag() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "topic/nested"]); _ = try await repo.run(["tag", "topic/nested"])
        let bareRoot = root.appendingPathComponent("remote.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        _ = try await repo.run(["remote", "add", "origin", bareRoot.path]); _ = try await repo.run(["fetch", "origin"])
        let confirmation = try await repo.browserDeletionConfirmation("refs/remotes/origin/topic/nested")
        XCTAssertTrue(confirmation.warning); XCTAssertFalse(confirmation.unmerged); XCTAssertTrue(confirmation.message.hasSuffix("This action will remove the branches on the remote."))
        try await repo.deleteBrowserReference("refs/remotes/origin/topic/nested")
        let remote = try await GitRepository(root: bareRoot, executable: repo.executable).referenceBrowser()
        XCTAssertFalse(remote.references.contains { $0.name == "refs/heads/topic/nested" }); XCTAssertTrue(remote.references.contains { $0.name == "refs/tags/topic/nested" })
        let local = try await repo.referenceBrowser(); XCTAssertTrue(local.references.contains { $0.name == "refs/heads/topic/nested" }); XCTAssertTrue(local.references.contains { $0.name == "refs/tags/topic/nested" })
    }
    func testBrowserDeletionRejectsNamespaceAndCancelledRequestsWithoutMutation() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "keep"])
        _ = try await repo.run(["update-ref", "refs/remotes/unconfigured/topic", "HEAD"])
        try await repo.deleteBrowserReference("refs/remotes/unconfigured/topic")
        let unknown = try await repo.referenceBrowser(); XCTAssertTrue(unknown.references.contains { $0.name == "refs/remotes/unconfigured/topic" })
        let before = try await repo.run(["show-ref"]).stdout
        for name in ["refs/notes/custom", "HEAD", "refs/heads/", "--all"] {
            do { try await repo.deleteBrowserReference(GitReferenceName(name)); XCTFail("Unsupported namespace accepted") } catch ReferenceBrowserDeletionFailure.namespace {}
        }
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.browserDeletionConfirmation("refs/tags/keep", cancellation: token); XCTFail("Cancelled preflight ran") } catch OperationCancellationFailure.cancelled {}
        do { try await repo.deleteBrowserReference("refs/tags/keep", cancellation: token); XCTFail("Cancelled deletion ran") } catch OperationCancellationFailure.cancelled {}
        let after = try await repo.run(["show-ref"]).stdout; XCTAssertEqual(before, after)
    }
}


extension ReferenceBrowserTests {
    func testTwoReferenceRangesRetainLastSelectedDirectionAndByteNames() async throws {
        let first: GitReferenceName = "refs/heads/left", second: GitReferenceName = "refs/tags/right"
        let forward = try XCTUnwrap(ReferenceBrowserRange(references: [first, second], lastSelected: second))
        XCTAssertEqual(forward.revision(), "refs/heads/left..refs/tags/right"); XCTAssertEqual(forward.label(symmetric: true), "left...tags/right")
        let reverse = try XCTUnwrap(ReferenceBrowserRange(references: [first, second], lastSelected: first))
        XCTAssertEqual(reverse.revision(symmetric: true), "refs/tags/right...refs/heads/left")
        XCTAssertNil(ReferenceBrowserRange(references: [first, first], lastSelected: first))
        let composed = GitReferenceName("refs/heads/Caf\u{e9}"), decomposed = GitReferenceName("refs/heads/Cafe\u{301}")
        XCTAssertNotNil(ReferenceBrowserRange(references: [composed, decomposed], lastSelected: decomposed))
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "left"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "right"]); _ = try await repo.run(["tag", "right"])
        let range = try await repo.run(["log", "--format=%s", forward.revision()]).text
        let empty = try await repo.run(["log", "--format=%s", reverse.revision()]).text
        XCTAssertEqual(range, "right\n"); XCTAssertEqual(empty, "")
        var options = HistoryOptions(); options.revisionRange = forward.history()
        let parsed = try await repo.history(options: options); XCTAssertEqual(parsed.map(\.subject), ["right"])
        options.revisionRange = reverse.history(); let reversed = try await repo.history(options: options); XCTAssertTrue(reversed.isEmpty)
    }
}

extension ReferenceBrowserTests {
    func testBatchDeletionWarningsNamespacesAndStopOnFailure() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "later"] { _ = try await repo.run(["branch", name]) }
        _ = try await repo.run(["tag", "one"]); _ = try await repo.run(["tag", "two"])
        let branches: [GitReferenceName] = ["refs/heads/first", "refs/heads/main", "refs/heads/later"]
        let confirmation = try await repo.browserDeletionConfirmation(branches)
        XCTAssertTrue(confirmation.uncheckedMerge); XCTAssertFalse(confirmation.unmerged); XCTAssertTrue(confirmation.warning)
        XCTAssertEqual(confirmation.message, "Do you really want to permanently delete the 3 selected refs? It can NOT be recovered!\n\nIt has not been checked if these branches have been fully merged into HEAD.")
        let tags: [GitReferenceName] = ["refs/tags/one", "refs/tags/two"]
        let tagConfirmation = try await repo.browserDeletionConfirmation(tags); XCTAssertFalse(tagConfirmation.warning)
        let invalidBatches: [[GitReferenceName]] = [[], ["refs/heads/first", "refs/tags/one"], ["refs/tags/one", "refs/tags/one"]]
        for invalid in invalidBatches {
            do { try await repo.deleteBrowserReferences(invalid); XCTFail("Invalid batch accepted") } catch ReferenceBrowserDeletionFailure.namespace {}
        }
        do { try await repo.deleteBrowserReferences(branches); XCTFail("Checked out deletion must fail") } catch is GitFailure {}
        let refs = try await repo.referenceBrowser(); XCTAssertFalse(refs.references.contains { $0.name == branches[0] }); XCTAssertTrue(refs.references.contains { $0.name == branches[1] }); XCTAssertTrue(refs.references.contains { $0.name == branches[2] })
        try await repo.deleteBrowserReferences(tags)
        let after = try await repo.referenceBrowser(); XCTAssertFalse(after.references.contains { tags.contains($0.name) })
        let token = OperationCancellation(); token.cancel()
        do { try await repo.deleteBrowserReferences(["refs/heads/later"], cancellation: token); XCTFail("Cancelled batch ran") } catch OperationCancellationFailure.cancelled {}
    }
    func testBatchRemoteDeletionGroupsOnePushPerConfiguredRemote() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two"] { _ = try await repo.run(["branch", name]) }
        for name in ["alpha", "zeta"] {
            let bare = root.appendingPathComponent(name + ".git")
            _ = try await repo.run(["clone", "--bare", root.path, bare.path]); _ = try await repo.run(["remote", "add", name, bare.path]); _ = try await repo.run(["fetch", name])
        }
        let selected: [GitReferenceName] = ["refs/remotes/zeta/one", "refs/remotes/alpha/one", "refs/remotes/alpha/two"]
        let confirmation = try await repo.browserDeletionConfirmation(selected); XCTAssertTrue(confirmation.uncheckedMerge); XCTAssertTrue(confirmation.message.hasSuffix("This action will remove the branches on the remote."))
        let helper = root.appendingPathComponent("record-git")
        let quoted = "'" + repo.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nif [ \"${6-}\" = push ]; then printf '%s\\n' \"$*\" >> \"$0.pushes\"; fi\nexec " + quoted + " \"$@\"\n"
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let wrapped = GitRepository(root: root, executable: helper)
        try await wrapped.deleteBrowserReferences(selected)
        let commands = try String(contentsOf: URL(fileURLWithPath: helper.path + ".pushes")).split(separator: "\n")
        XCTAssertEqual(commands.count, 2); XCTAssertTrue(commands[0].contains("push -- alpha :refs/heads/one :refs/heads/two")); XCTAssertTrue(commands[1].contains("push -- zeta :refs/heads/one"))
        let alpha = try await GitRepository(root: root.appendingPathComponent("alpha.git"), executable: repo.executable).referenceBrowser()
        let zeta = try await GitRepository(root: root.appendingPathComponent("zeta.git"), executable: repo.executable).referenceBrowser()
        XCTAssertFalse(alpha.references.contains { [GitReferenceName("refs/heads/one"), "refs/heads/two"].contains($0.name) }); XCTAssertFalse(zeta.references.contains { $0.name == "refs/heads/one" }); XCTAssertTrue(zeta.references.contains { $0.name == "refs/heads/two" })
        let local = try await repo.referenceBrowser(); XCTAssertTrue(local.references.contains { $0.name == "refs/heads/one" }); XCTAssertTrue(local.references.contains { $0.name == "refs/heads/two" })
    }
    func testComparisonCapturesHashesButResolvesNamesAndKeepsDisplayedDirection() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "old"])
        try Data("second\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "second")
        _ = try await repo.run(["branch", "new"])
        let snapshot = try await repo.referenceBrowser()
        let old = try XCTUnwrap(snapshot.references.first { $0.name == "refs/heads/old" }), new = try XCTUnwrap(snapshot.references.first { $0.name == "refs/heads/new" })
        let pair = try XCTUnwrap(ReferenceBrowserComparison(references: [old, new]))
        XCTAssertEqual(pair.from, old.name); XCTAssertEqual(pair.to, new.name)
        let expected = try await repo.run(["diff-tree", "-r", "-p", "--stat", "--no-ext-diff", "--no-textconv", "--no-color", "--end-of-options", old.hash, new.hash, "--"]).stdout
        _ = try await repo.run(["update-ref", "refs/heads/new", old.hash])
        let captured = try await repo.referenceBrowserUnifiedDiff(pair); XCTAssertEqual(captured, expected); XCTAssertTrue(String(decoding: captured, as: UTF8.self).contains("+second"))
        let byName = try await repo.revisionComparison(from: .revision(pair.from.rawValue), to: .revision(pair.to.rawValue)); XCTAssertTrue(byName.files.isEmpty)
        let reverse = try XCTUnwrap(ReferenceBrowserComparison(references: [new, old])); let reversed = try await repo.referenceBrowserUnifiedDiff(reverse); XCTAssertTrue(String(decoding: reversed, as: UTF8.self).contains("-second"))
        XCTAssertNil(ReferenceBrowserComparison(references: [])); XCTAssertNil(ReferenceBrowserComparison(references: [old])); XCTAssertNil(ReferenceBrowserComparison(references: [old, old])); XCTAssertNil(ReferenceBrowserComparison(references: [old, new, old]))
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path]); let bare = GitRepository(root: bareRoot, executable: repo.executable)
        let barePatch = try await bare.referenceBrowserUnifiedDiff(pair); XCTAssertEqual(barePatch, expected)
        let treeOld = try await repo.run(["rev-parse", old.hash + "^{tree}"]).text.trimmingCharacters(in: .newlines), treeNew = try await repo.run(["rev-parse", new.hash + "^{tree}"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/custom/tree-old", treeOld]); _ = try await repo.run(["update-ref", "refs/custom/tree-new", treeNew])
        let trees = try await repo.referenceBrowser(); let treePair = try XCTUnwrap(ReferenceBrowserComparison(references: [try XCTUnwrap(trees.references.first { $0.name == "refs/custom/tree-old" }), try XCTUnwrap(trees.references.first { $0.name == "refs/custom/tree-new" })]))
        let treePatch = try await repo.referenceBrowserUnifiedDiff(treePair); XCTAssertEqual(treePatch, expected)
    }
    func testComparisonAndUnifiedDiffCancellationPreserveRepository() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "other"])
        let snapshot = try await repo.referenceBrowser(), pair = try XCTUnwrap(ReferenceBrowserComparison(references: snapshot.references.filter { $0.name == "refs/heads/main" || $0.name == "refs/heads/other" }))
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.referenceBrowserUnifiedDiff(pair, cancellation: token); XCTFail("Cancelled unified diff ran") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.revisionComparison(from: .revision(pair.from.rawValue), to: .revision(pair.to.rawValue), cancellation: token); XCTFail("Cancelled comparison ran") } catch OperationCancellationFailure.cancelled {}
        let comparison = try await repo.revisionComparison(from: .revision(pair.from.rawValue), to: .revision(pair.to.rawValue))
        do { _ = try await repo.revisionComparisonPatchData(comparison, cancellation: token); XCTFail("Cancelled comparison patch ran") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(head, try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(file, try Data(contentsOf: root.appendingPathComponent("file")))
    }

    func testSourceBrowserNamespaceAndShortNamesPreserveBytes() {
        let cases = [("refs/heads/topic", "topic"), ("refs/tags/v1", "tags/v1"), ("refs/remotes/origin/topic", "remotes/origin/topic"), ("refs/custom/x", "custom/x"), ("HEAD", "HEAD"), ("refs/heads/Cafe\u{301}", "Cafe\u{301}")]
        for (raw, short) in cases { XCTAssertTrue(GitReferenceName(raw).browserShortName.utf8.elementsEqual(short.utf8)) }
        for raw in ["refs/heads", "refs/heads/topic", "refs/heads/Cafe\u{301}"] { XCTAssertTrue(GitReferenceName(raw).browserIsFrom("refs/heads")) }
        for raw in ["refs/headsh", "refs/heads-other/topic", "refs/tags/heads"] { XCTAssertFalse(GitReferenceName(raw).browserIsFrom("refs/heads")) }
    }

}
