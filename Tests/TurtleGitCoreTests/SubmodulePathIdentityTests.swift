// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SubmodulePathIdentityTests: XCTestCase {
    private let composed = "café/module"
    private let decomposed = "cafe\u{301}/module"
    private func fixture(paths: [String]) async throws -> (URL, GitRepository, URL) {
        let (root, original, _) = try await GitPatchTests().fixture()
        let oid = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for path in paths { _ = try await original.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "160000," + oid + "," + path]) }
        let wrapper = root.appendingPathComponent("literal-submodule-git")
        let quotedEngine = "'" + original.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        task_previous=
        task_action=
        for task_argument do
          if [ "$task_previous" = submodule ]; then task_action="$task_argument"; fi
          task_previous="$task_argument"
        done
        case "$task_action" in
          add|update|sync) printf '%s\\0' "$@" > "$0.argv"; exit 0 ;;
        esac
        exec \(quotedEngine) "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return (root, GitRepository(root: root, executable: wrapper), wrapper.appendingPathExtension("argv"))
    }
    private func arguments(_ file: URL) throws -> [Data] { try Data(contentsOf: file).split(separator: 0).map { Data($0) } }
    func testCatalogAndScopedDiscoveryRetainEquivalentIndexNames() async throws {
        let (root, repo, _) = try await fixture(paths: [composed, decomposed]); defer { try? FileManager.default.removeItem(at: root) }
        let names = try await repo.submodulePathNames(), all = try await repo.submoduleUpdatePaths()
        XCTAssertEqual(names.count, 2); XCTAssertEqual(Set(all.map { GitReferenceName($0) }), [GitReferenceName(composed), GitReferenceName(decomposed)])
        let first = try await repo.submoduleUpdatePaths(scope: ["café"]), second = try await repo.submoduleUpdatePaths(scope: ["cafe\u{301}"])
        XCTAssertEqual(first.map { Data($0.utf8) }, [Data(composed.utf8)])
        XCTAssertEqual(second.map { Data($0.utf8) }, [Data(decomposed.utf8)])
    }
    func testUpdateValidatesExactIdentityAndSendsBothLiteralPaths() async throws {
        let (root, repo, capture) = try await fixture(paths: [composed, decomposed]); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.updateSubmodules(paths: [composed, decomposed], options: .init())
        let argv = try arguments(capture)
        XCTAssertEqual(Array(argv.suffix(2)), [Data(composed.utf8), Data(decomposed.utf8)])
        XCTAssertTrue(argv.contains(Data("core.precomposeunicode=false".utf8)))
        do { _ = try await repo.updateSubmodules(paths: [composed, composed], options: .init()); XCTFail("Exact duplicate accepted") } catch SubmoduleUpdateFailure.selection {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
    }
    func testEquivalentUnlistedNameCannotReplaceReviewedGitlink() async throws {
        let (root, repo, capture) = try await fixture(paths: [composed]); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.updateSubmodules(paths: [decomposed], options: .init()); XCTFail("Unlisted equivalent spelling accepted") } catch SubmoduleUpdateFailure.selection {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
    }
    func testAddAndSyncPassLiteralDestinationAndScope() async throws {
        let (root, repo, capture) = try await fixture(paths: []); defer { try? FileManager.default.removeItem(at: root) }
        var options = SubmoduleAddOptions(); options.source = "https://example.invalid/source.git"; options.path = decomposed
        _ = try await repo.addSubmodule(options)
        XCTAssertEqual(try arguments(capture).last, Data(decomposed.utf8))
        XCTAssertTrue(try arguments(capture).contains(Data("core.precomposeunicode=false".utf8)))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(decomposed), withIntermediateDirectories: true)
        _ = try await repo.syncSubmodules(scope: [decomposed])
        XCTAssertEqual(try arguments(capture).last, Data(decomposed.utf8))
        XCTAssertTrue(try arguments(capture).contains(Data("core.precomposeunicode=false".utf8)))
    }
}
