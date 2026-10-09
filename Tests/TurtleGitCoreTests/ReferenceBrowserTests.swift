import XCTest
@testable import TurtleGitCore

final class ReferenceBrowserTests: XCTestCase {
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

}
