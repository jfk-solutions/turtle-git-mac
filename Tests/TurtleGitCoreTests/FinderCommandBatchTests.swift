// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class FinderCommandBatchTests: XCTestCase {
    func testUtilitiesRoundTripWithoutRepositorySelectionAndCannotRunGit() throws {
        for action in [RepositoryAction.settings, .help, .about] {
            let request = FinderRequest(action: action, paths: [])
            let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.action, action); XCTAssertTrue(decoded.paths.isEmpty)
            XCTAssertTrue(action.isApplicationUtility); XCTAssertFalse(action.requiresWorkingTree); XCTAssertNil(action.arguments(value: ""))
            XCTAssertTrue(FinderRepositoryMetadata(bare: true).allows(action))
        }
        XCTAssertNil(FinderRequest(action: .blame, paths: []).url)
        XCTAssertNil(FinderRequest(url: URL(string: "turtlegit://action?command=previousDiff")!))
    }
    func testNewSourceCommandGatesAndGroupedPreferenceAvailability() {
        let file: FinderShellFlags = [.inGit, .inVersionedFolder, .onlyOne, .normal]
        XCTAssertTrue(FinderShellRules.allows(.blame, flags: file)); XCTAssertTrue(FinderShellRules.allows(.previousDiff, flags: file))
        XCTAssertFalse(FinderShellRules.allows(.blame, flags: file.union(.folder))); XCTAssertFalse(FinderShellRules.allows(.previousDiff, flags: file.union(.added)))
        XCTAssertTrue(FinderShellRules.allows(.editConflict, flags: file.union(.conflicted)))
        XCTAssertFalse(FinderShellRules.allows(.editConflict, flags: file.union([.folder, .conflicted])))
        XCTAssertTrue(FinderShellRules.allows(.synchronize, flags: [.folderInGit, .onlyOne]))
        XCTAssertFalse(FinderShellRules.allows(.synchronize, flags: [.folderInGit, .onlyOne, .merge]))
        XCTAssertFalse(FinderShellRules.allows(.synchronize, flags: [.folderInGit, .onlyOne, .bisect]))
        XCTAssertTrue(FinderShellRules.allows(.logSubmodule, flags: [.folderInGit, .onlyOne, .workingTreeRoot, .submodule]))
        XCTAssertFalse(FinderShellRules.allows(.logSubmodule, flags: [.folderInGit, .onlyOne, .workingTreeRoot]))
        XCTAssertEqual(FinderMenuEntry.configurableCases.filter(\.availableInFinder).count, 55)
        for action in [RepositoryAction.synchronize, .blame, .previousDiff, .logSubmodule, .editConflict, .settings, .help, .about] {
            XCTAssertTrue(FinderMenuEntry.entry(for: action)?.availableInFinder == true)
            XCTAssertNil(action.arguments(value: ""))
        }
    }
    func testPreviousFileDiffUsesSecondPathCommitAndCurrentWorkingContent() async throws {
        let (root, repo, file) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("second file version\n".utf8).write(to: root.appendingPathComponent(file)); try await repo.stage([file]); _ = try await repo.commit(message: "second path commit")
        let other = "other.txt"; try Data("other\n".utf8).write(to: root.appendingPathComponent(other)); try await repo.stage([other]); _ = try await repo.commit(message: "unrelated commit")
        let parent = try await repo.run(["rev-parse", "HEAD~1"]).text.trimmingCharacters(in: .newlines)
        try Data("staged file version\n".utf8).write(to: root.appendingPathComponent(file)); try await repo.stage([file])
        let working = Data("working file version\n".utf8); try working.write(to: root.appendingPathComponent(file))
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let base = try await repo.previousDiffBase(path: file)
        XCTAssertFalse(base.directory); XCTAssertEqual(base.revision, initial); XCTAssertNotEqual(base.revision, parent)
        let comparison = try await repo.revisionFileComparison(from: .revision(base.revision), to: .workingTree, paths: [file])
        XCTAssertEqual(comparison.files.map(\.path), [file])
        let patch = try await repo.revisionComparisonPatchData(comparison, paths: [file])
        XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+working file version"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file)), working)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(afterHead, head)
        do { _ = try await repo.previousDiffBase(path: other); XCTFail("One-entry history accepted") } catch FinderCommandFailure.previousRevisionUnavailable {}
    }
    func testDirectoryPreviousDiffAndPatchKeepLiteralScope() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ":(glob)folder 雪\n", file = scope + "/changed.txt", outside = scope + "-other/changed.txt"
        for path in [file, outside] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original\n".utf8).write(to: root.appendingPathComponent(path))
        }
        try await repo.stage([file, outside]); _ = try await repo.commit(message: "directory paths")
        for path in [file, outside] { try Data("working\n".utf8).write(to: root.appendingPathComponent(path)) }
        let base = try await repo.previousDiffBase(path: scope)
        XCTAssertTrue(base.directory)
        let expected = try await repo.run(["rev-parse", "HEAD~1"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(base.revision, expected)
        let rootBase = try await repo.previousDiffBase(path: ".")
        XCTAssertTrue(rootBase.directory); XCTAssertEqual(rootBase.revision, expected)
        let snapshot = try await repo.revisionComparison(from: .revision(base.revision), to: .workingTree, paths: [scope])
        XCTAssertEqual(snapshot.scopePaths, [scope]); XCTAssertEqual(snapshot.files.map(\.path), [file])
        let patch = try await repo.revisionComparisonPatchData(snapshot)
        XCTAssertFalse(String(decoding: patch, as: UTF8.self).contains("-other"))
        do { _ = try await repo.previousDiffBase(path: "../outside"); XCTFail("Outside path accepted") } catch {}
        let canceled = OperationCancellation(); canceled.cancel()
        do { _ = try await repo.previousDiffBase(path: scope, cancellation: canceled); XCTFail("Canceled command ran") } catch {}
    }
}
