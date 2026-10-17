import XCTest
@testable import TurtleGitCore

final class ConflictPathIdentityTests: XCTestCase {
    private let a = "café\n.txt", b = "cafe\u{301}\n.txt"
    private func fixture(paths: [String]? = nil) async throws -> (URL, GitRepository, [String]) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        _ = try await repo.run(["config", "core.precomposeunicode", "false"])
        try Data("unrelated\n".utf8).write(to: root.appendingPathComponent("other")); try await repo.stage(["other"]); _ = try await repo.commit(message: "base")
        let selected = paths ?? [a, b]
        var records = Data()
        for (index, path) in selected.enumerated() {
            for stage in 1...3 {
                let object = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("path\(index) stage\(stage)\n".utf8)).text.trimmingCharacters(in: .newlines)
                records.append(Data("100644 \(object) \(stage)\t\(path)\0".utf8))
            }
        }
        _ = try await repo.run(["update-index", "-z", "--index-info"], input: records)
        return (root, repo, selected)
    }
    func testConflictStagesAndScopesPreserveExactPathAndDirectorySpellings() async throws {
        let paths = [a,b,"café/file","cafe\u{301}/file"]
        let (root,repo,_) = try await fixture(paths: paths); defer { try? FileManager.default.removeItem(at: root) }
        let all = try await repo.conflicts()
        XCTAssertEqual(all.count, 4); XCTAssertEqual(Set(all).count, 4)
        XCTAssertTrue(all.allSatisfy { $0.stages.map(\.number) == [1,2,3] })
        for path in paths {
            let selected = try await repo.conflicts(paths: [path])
            XCTAssertEqual(selected.map { Data($0.path.utf8) }, [Data(path.utf8)])
        }
        for folder in ["café", "cafe\u{301}"] {
            let selected = try await repo.conflicts(paths: [folder])
            XCTAssertEqual(selected.map { Data($0.path.utf8) }, [Data((folder + "/file").utf8)])
        }
        let direct = try await repo.conflictEditorEntry(path: b)
        XCTAssertEqual(Data(direct.path.utf8), Data(b.utf8))
    }
    func testCanonicalNeighborStagesCannotValidateAsCapturedEntry() async throws {
        let (root,repo,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try await repo.conflicts(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let first = try XCTUnwrap(entries.first { GitReferenceName.equal($0.path,a) })
        let forged = ConflictEntry(path: b, stages: first.stages)
        XCTAssertNotEqual(first, forged)
        do { _ = try await repo.resolveConflicts([forged], using: .mine); XCTFail("Neighbor stages accepted") } catch ResolveFailure.stale {}
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
    }
    func testSingleSideResolutionLeavesOtherSpellingUnmergedAndUnrelatedIndexUntouched() async throws {
        for selectedPath in [a,b] {
            let (root,repo,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let entries = try await repo.conflicts(), head = try await repo.run(["rev-parse","HEAD"]).stdout
            let selected = try XCTUnwrap(entries.first { GitReferenceName.equal($0.path,selectedPath) }), other = try XCTUnwrap(entries.first { !GitReferenceName.equal($0.path,selectedPath) })
            let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
            _ = try await repo.resolveConflicts([selected], using: .theirs)
            let remaining = try await repo.conflicts(), object = try await repo.run(["rev-parse", ":" + selectedPath]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(remaining, [other]); XCTAssertEqual(object, selected.stages.first { $0.number == 3 }?.object)
            let currentHead = try await repo.run(["rev-parse","HEAD"]).stdout, unrelated = try await repo.run(["show",":other"]).stdout
            XCTAssertEqual(head,currentHead); XCTAssertEqual(unrelated,Data("unrelated\n".utf8)); XCTAssertEqual(config,try Data(contentsOf:root.appendingPathComponent(".git/config")))
        }
    }
    func testBothDistinctPathsResolveButRepeatedExactTargetAndCancellationRefuseMutation() async throws {
        let (root,repo,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try await repo.conflicts(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { _ = try await repo.resolveConflicts([entries[0], entries[0]], using: .mine); XCTFail("Repeated exact target accepted") } catch ResolveFailure.selection {}
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.resolveConflicts(entries, using: .mine, cancellation: token); XCTFail("Cancelled resolution ran") } catch is OperationCancellationFailure {}
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
        _ = try await repo.resolveConflicts(entries, using: .mine)
        let remaining = try await repo.conflicts(); XCTAssertTrue(remaining.isEmpty)
        for entry in entries {
            let object = try await repo.run(["rev-parse", ":" + entry.path]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(object, entry.stages.first { $0.number == 2 }?.object)
        }
    }
    func testCheckedRebaseRecoveryCommitsBothIndexSpellingsAndPreservesExcludedResolution() async throws {
        let tests = RebaseTests(), (root, repo, ordinary) = try await tests.fixture(conflict: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "core.precomposeunicode", "false"])
        _ = try await repo.startRebase(try await repo.rebasePlan(tests.options()), editorExecutable: tests.editor)
        try Data("resolved excluded\n".utf8).write(to: root.appendingPathComponent(ordinary)); try await repo.stage([ordinary])
        let blob = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("same physical payload\n".utf8)).text.trimmingCharacters(in: .newlines)
        try Data("same physical payload\n".utf8).write(to: root.appendingPathComponent(a))
        _ = try await repo.run(["update-index", "-z", "--index-info"], input: Data("100644 \(blob)\t\(a)\0100644 \(blob)\t\(b)\0".utf8))
        let state = try await repo.rebaseState(), head = try await repo.rebaseCommit("HEAD"), paths = GitPathSet([a,b])
        let empty = try await repo.rebaseConflictSelectionIsEmpty(paths: paths, expected: state, expectedHead: head.hash)
        XCTAssertFalse(empty)
        _ = try await repo.commitRebaseConflictSelection(message: "both exact paths", paths: paths, expected: state, expectedHead: head.hash)
        for path in [a,b] {
            let object = try await repo.run(["rev-parse", "HEAD:" + path]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(object, blob)
        }
        let excluded = try await repo.run(["show", ":" + ordinary]).stdout
        XCTAssertEqual(excluded, Data("resolved excluded\n".utf8))
        let names = try await repo.run(["ls-tree", "-r", "--name-only", "-z", "HEAD"]).stdout.split(separator: 0).map {String(decoding:$0,as:UTF8.self)}
        XCTAssertTrue(GitPathSet(names).isSuperset(of:paths))
        _ = try await repo.abortRebase()
    }

}
