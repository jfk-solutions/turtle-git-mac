// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class FileListDragTests: XCTestCase {
    private let raw = GitLibGit2Configuration(enabled: false)

    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileListDrag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo = GitRepository(root: root, executable: executable, askpass: nil, libgit2Configuration: raw)
        _ = try await repo.run(["init", "-b", "main"])
        for pair in [("user.name", "Drag Tests"), ("user.email", "drag@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] {
            _ = try await repo.run(["config", pair.0, pair.1])
        }
        return (root, repo)
    }
    private func row(_ path: String, action: String = "M", old: String? = nil, mode: UInt32? = nil, submodule: Bool = false) -> CommitFile {
        CommitFile(path: path, oldPath: old, action: action, added: 0, removed: 0, hasStatistics: false, isSubmodule: submodule, newMode: mode)
    }
    private func write(_ root: URL, _ path: String, _ bytes: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    private func hash(_ repo: GitRepository, _ revision: String = "HEAD") async throws -> String {
        try await repo.run(["rev-parse", "--verify", revision]).text.trimmingCharacters(in: .newlines)
    }
    private func exported(_ repo: GitRepository, _ plan: FileListDragPlan, _ index: Int) async throws -> RepositoryBrowserExport {
        guard case .historical(let result) = try await repo.materializeFileListDrag(plan, itemAt: index) else {
            throw RevisionComparisonFailure.selection
        }
        return result
    }

    func testCapturedHistoricalRevisionLiteralLeavesModesAndSymlinkTextDoNotMutateRepository() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let literal = "dir 雪/name\n[*].txt", executable = "tool", link = "link"
        try write(root, literal, Data([0, 255, 13, 10])); try write(root, executable, Data("#!/bin/sh\necho old\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(executable).path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "../outside target")
        try await repo.stage([literal, executable, link]); _ = try await repo.commit(message: "captured")
        let revision = try await hash(repo)
        let plan = try FileListDragPlan(root: root, revision: .revision(revision), files: [row(literal), row(executable), row(link)], backend: raw)
        try write(root, literal, Data("new committed".utf8)); try await repo.stage([literal]); _ = try await repo.commit(message: "new HEAD")
        try write(root, literal, Data("working remains".utf8)); try write(root, "unrelated", Data("staged remains".utf8)); try await repo.stage(["unrelated"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await hash(repo)
        let expected = [Data([0, 255, 13, 10]), Data("#!/bin/sh\necho old\n".utf8), Data("../outside target".utf8)]
        for position in plan.items.indices {
            let result = try await exported(repo, plan, position)
            XCTAssertEqual(result.item.lastPathComponent, plan.items[position].name)
            XCTAssertEqual(try Data(contentsOf: result.item), expected[position])
            let attributes = try FileManager.default.attributesOfItem(atPath: result.item.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, position == 1 ? 0o755 : 0o644)
            result.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: result.directory.path))
        }
        let after = try await hash(repo)
        XCTAssertEqual(after, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data("working remains".utf8))
    }

    func testExactUnicodeAndDuplicateLeafOccurrencesRemainSeparate() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let nfc = "caf\u{e9}.txt", nfd = "cafe\u{301}.txt"
        let a = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("first".utf8)).text.trimmingCharacters(in: .newlines)
        let b = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("second".utf8)).text.trimmingCharacters(in: .newlines)
        func record(_ object: String, _ name: String) -> String { "100644 blob \(object)\t\(name)\0" }
        let subtree = try await repo.run(["mktree", "-z"], input: Data(record(a, "same.txt").utf8)).text.trimmingCharacters(in: .newlines)
        let tree = try await repo.run(["mktree", "-z"], input: Data((record(a, nfc) + record(b, nfd) + "040000 tree \(subtree)\tone\0" + "040000 tree \(subtree)\ttwo\0").utf8)).text.trimmingCharacters(in: .newlines)
        let revision = try await repo.run(["commit-tree", tree, "-m", "exact names"]).text.trimmingCharacters(in: .newlines)
        let plan = try FileListDragPlan(root: root, revision: .revision(revision), files: [row(nfc), row(nfd), row("one/same.txt"), row("two/same.txt"), row("one/same.txt")], backend: raw)
        XCTAssertEqual(plan.items.count, 5); XCTAssertEqual(Set(plan.items.map(\.id)).count, 5)
        XCTAssertNotEqual(Data(plan.items[0].path.utf8), Data(plan.items[1].path.utf8))
        XCTAssertEqual(plan.items.suffix(3).map(\.name), ["same.txt", "same.txt", "same.txt"])
        var results: [RepositoryBrowserExport] = []; defer { results.forEach { $0.discard() } }
        for position in plan.items.indices { results.append(try await exported(repo, plan, position)) }
        XCTAssertEqual(Set(results.map { $0.directory.path }).count, 5)
        for index in results.indices { XCTAssertEqual(try Data(contentsOf: results[index].item), Data((index == 1 ? "second" : "first").utf8)) }
    }

    func testSourceExclusionsAndRenameCurrentSideNeverFallBackToOldPath() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "old", Data("old-only".utf8)); try await repo.stage(["old"]); _ = try await repo.commit(message: "base")
        let revision = try await hash(repo)
        let plan = try FileListDragPlan(root: root, revision: .revision(revision), files: [row("deleted", action: "D"), row("missing", action: "!"), row("module", mode: 0o160000, submodule: true), row("folder", mode: 0o040000), row("new", action: "R", old: "old")], backend: raw)
        XCTAssertEqual(plan.items.map(\.path), ["new"]); XCTAssertEqual(plan.items.map(\.id), [4])
        do { _ = try await repo.materializeFileListDrag(plan, itemAt: 0); XCTFail("Absent rename destination must not export old bytes") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("old")), Data("old-only".utf8))
    }

    func testWorkingURLsValidateParentBoundaryAndLeafWithoutFollowingSymlink() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: outside) }
        try write(root, "current", Data("working".utf8)); try write(outside, "external", Data("outside".utf8))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: outside.appendingPathComponent("external").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        let plan = try FileListDragPlan(root: root, revision: .workingTree, files: [row("current"), row("link"), row("missing"), row("directory"), row("escape/external")], backend: raw)
        for index in 0..<2 {
            let url = try plan.validatedWorkingURL(itemAt: index)
            guard case .workingURL(let materialized) = try await repo.materializeFileListDrag(plan, itemAt: index) else { return XCTFail("Expected live URL") }
            XCTAssertEqual(url.path, root.appendingPathComponent(plan.items[index].path).path); XCTAssertEqual(materialized, url)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: plan.validatedWorkingURL(itemAt: 1).path), outside.appendingPathComponent("external").path)
        for index in 2..<5 { XCTAssertThrowsError(try plan.validatedWorkingURL(itemAt: index)) }
        let foreign = GitRepository(root: outside)
        do { _ = try await foreign.materializeFileListDrag(plan, itemAt: 0); XCTFail("Foreign root accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("external")), Data("outside".utf8))
    }

    func testInvalidPlansAndCancelledLoadRejectWithoutChangingIndex() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file", Data("base".utf8)); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let revision = try await hash(repo), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for bad in ["HEAD", "HEAD~1..HEAD", String(repeating: "g", count: 40), ""] { XCTAssertThrowsError(try FileListDragPlan(root: root, revision: .revision(bad), files: [row("file")], backend: raw)) }
        XCTAssertThrowsError(try FileListDragPlan(root: root, revision: .emptyTree, files: [row("file")], backend: raw))
        for bad in ["", "../file", "/file", "a//file", "a/./file", ".GIT/config", "a\0b"] { XCTAssertThrowsError(try FileListDragPlan(root: root, revision: .revision(revision), files: [row(bad)], backend: raw)) }
        for source in [ComparisonRevision.revision(revision), .workingTree] {
            let plan = try FileListDragPlan(root: root, revision: source, files: [row("file")], backend: raw), token = OperationCancellation(); token.cancel()
            do { _ = try await repo.materializeFileListDrag(plan, itemAt: 0, cancellation: token); XCTFail("Cancelled transfer accepted") } catch is OperationCancellationFailure {}
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("base".utf8))
    }

    func testCapturedGetOneFileBackendAppliesFiltersAndPropagatesRequiredFilterFailure() async throws {
        let backend = GitLibGit2Configuration(mask: 0x200)
        do { _ = try backend.executor(for: .getOneFile) } catch { throw XCTSkip("Historical filter helper unavailable: \(error)") }
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitattributes", Data("*.filtered filter=drag\n".utf8)); try write(root, "value.filtered", Data("STORED\n".utf8))
        _ = try await repo.run(["config", "filter.drag.clean", "cat"]); _ = try await repo.run(["config", "filter.drag.smudge", "sed 's/STORED/SMUDGED/g'"]); _ = try await repo.run(["config", "filter.drag.required", "true"])
        try await repo.stage([".gitattributes", "value.filtered"]); _ = try await repo.commit(message: "filtered")
        let revision = try await hash(repo), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let rawPlan = try FileListDragPlan(root: root, revision: .revision(revision), files: [row("value.filtered")], backend: raw)
        let filteredPlan = try FileListDragPlan(root: root, revision: .revision(revision), files: [row("value.filtered")], backend: backend)
        let a = try await exported(repo, rawPlan, 0), b = try await exported(repo, filteredPlan, 0); defer { a.discard(); b.discard() }
        XCTAssertEqual(try Data(contentsOf: a.item), Data("STORED\n".utf8)); XCTAssertEqual(try Data(contentsOf: b.item), Data("SMUDGED\n".utf8))
        _ = try await repo.run(["config", "filter.drag.smudge", "exit 1"])
        do { _ = try await repo.materializeFileListDrag(filteredPlan, itemAt: 0); XCTFail("Required filter failure must refuse the file") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("value.filtered")), Data("STORED\n".utf8))
    }
}
