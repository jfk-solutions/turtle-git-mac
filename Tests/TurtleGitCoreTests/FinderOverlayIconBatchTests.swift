// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import XCTest
@testable import TurtleGitCore

final class FinderOverlayIconBatchTests: XCTestCase {
    func testIndexFlagsReadRealGitWithoutChangingIndexAndHandleBothBits() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path).path
        _ = try await repo.run(["update-index", "--assume-unchanged", "--", path])
        var flags = try await repo.finderIndexFlags()
        XCTAssertEqual(flags[file], FinderIndexFlags(assumeUnchanged: true))
        _ = try await repo.run(["update-index", "--skip-worktree", "--", path])
        let indexURL = root.appendingPathComponent(".git/index"), before = try Data(contentsOf: indexURL)
        flags = try await repo.finderIndexFlags()
        XCTAssertEqual(flags[file], FinderIndexFlags(skipWorktree: true, assumeUnchanged: true))
        XCTAssertEqual(try Data(contentsOf: indexURL), before)
        _ = try await repo.run(["update-index", "--no-assume-unchanged", "--", path])
        flags = try await repo.finderIndexFlags()
        XCTAssertEqual(flags[file], FinderIndexFlags(skipWorktree: true))
        _ = try await repo.run(["update-index", "--no-skip-worktree", "--", path])
        flags = try await repo.finderIndexFlags(); XCTAssertTrue(flags.isEmpty)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.finderIndexFlags(cancellation: token); XCTFail("Canceled scan executed") } catch {}
    }

    func testIndexBadgePriorityDisabledHandlersExclusionsAndNoneMode() {
        let both = FinderIndexFlags(skipWorktree: true, assumeUnchanged: true)
        let snapshot = FinderSnapshot(roots: ["/repo"], states: [:], overlayEntries: ["/repo/clean": .normal, "/repo/changed": .modified, "/repo/conflict": .conflicted, "/repo/folder": .normal], indexFlags: ["/repo/clean": both, "/repo/changed": both, "/repo/conflict": both, "/repo/folder": both])
        var settings = FinderOverlaySettings(); settings.volumes = [.network]
        func badges() -> [String: FinderOverlayBadge] {
            settings.overlayBadges(snapshot: snapshot, volume: { $0 == "/repo" ? .network : .unknown }, isDirectory: { $0 == "/repo/folder" })
        }
        XCTAssertEqual(badges()["/repo/clean"], .skipWorktree)
        XCTAssertEqual(badges()["/repo/changed"], .modified); XCTAssertEqual(badges()["/repo/conflict"], .conflicted)
        settings.showSkipWorktree = false; XCTAssertEqual(badges()["/repo/clean"], .assumeUnchanged)
        settings.showAssumeUnchanged = false; XCTAssertEqual(badges()["/repo/clean"], .normal)
        settings.showSkipWorktree = true; settings.excludePaths = "/repo*"
        XCTAssertNil(badges()["/repo/clean"]); XCTAssertEqual(badges()["/repo/folder"], .normal)
        settings.excludePaths = ""; settings.cacheMode = .none
        XCTAssertNil(badges()["/repo/clean"]); XCTAssertEqual(badges()["/repo/folder"], .normal)
    }

    func testOldPreferencesAndSnapshotsKeepExistingChoices() throws {
        let old = Data(#"{"cacheMode":0,"unversionedAsModified":true,"recurseSubmodules":true,"showExcludedAsNormal":false,"volumes":["network"],"excludePaths":"/repo*","includePaths":"/repo/allowed*","hiddenStates":["added"]}"#.utf8)
        var settings = try JSONDecoder().decode(FinderOverlaySettings.self, from: old)
        XCTAssertEqual(settings.cacheMode, .none); XCTAssertTrue(settings.unversionedAsModified); XCTAssertTrue(settings.recurseSubmodules)
        XCTAssertFalse(settings.showExcludedAsNormal); XCTAssertEqual(settings.volumes, [.network]); XCTAssertEqual(settings.hiddenStates, [.added])
        XCTAssertEqual(settings.excludePaths, "/repo*"); XCTAssertEqual(settings.includePaths, "/repo/allowed*")
        XCTAssertTrue(settings.showSkipWorktree); XCTAssertTrue(settings.showAssumeUnchanged); XCTAssertEqual(settings.iconSet, .xpStyle)
        settings.iconSet = .win10; settings.showSkipWorktree = false
        XCTAssertEqual(try JSONDecoder().decode(FinderOverlaySettings.self, from: JSONEncoder().encode(settings)), settings)
        let legacy = Data(#"{"roots":["/repo"],"states":{"/repo":"normal"},"updated":0}"#.utf8)
        var snapshot = try JSONDecoder().decode(FinderSnapshot.self, from: legacy); XCTAssertNil(snapshot.indexFlags)
        snapshot.indexFlags = ["/repo/file": FinderIndexFlags(assumeUnchanged: true)]
        XCTAssertEqual(try JSONDecoder().decode(FinderSnapshot.self, from: JSONEncoder().encode(snapshot)).indexFlags, snapshot.indexFlags)
    }

    func testRefreshRemovesStaleChildFlagsAndPreservesIndependentRepositories() {
        var snapshot = FinderSnapshot(roots: ["/repo", "/repo/removed", "/repo/independent", "/other"], states: [:], repositories: ["/repo/removed": FinderRepositoryMetadata(submoduleParentRoot: "/repo"), "/repo/independent": FinderRepositoryMetadata()], indexFlags: ["/repo/removed/a": .init(skipWorktree: true), "/repo/old": .init(skipWorktree: true), "/repo/independent/a": .init(assumeUnchanged: true), "/other/a": .init(skipWorktree: true)])
        let refreshed = FinderSnapshot(roots: ["/repo"], states: [:], indexFlags: ["/repo/new": .init(assumeUnchanged: true)])
        snapshot.replaceSubtree(root: URL(fileURLWithPath: "/repo"), snapshots: [refreshed])
        XCTAssertNil(snapshot.indexFlags?["/repo/removed/a"]); XCTAssertNil(snapshot.indexFlags?["/repo/old"])
        XCTAssertEqual(snapshot.indexFlags?["/repo/new"], .init(assumeUnchanged: true))
        XCTAssertEqual(snapshot.indexFlags?["/repo/independent/a"], .init(assumeUnchanged: true))
        XCTAssertEqual(snapshot.indexFlags?["/other/a"], .init(skipWorktree: true))
    }

    func testKnownUnbornRootRetainsRepositoryMenusWithoutVersioningUntrackedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untracked"); try Data().write(to: file)
        for state: FileState? in [.untracked, .ignored, nil] {
            let snapshot = FinderSnapshot(roots: [root.path], states: state.map { [root.path: $0, file.path: .untracked] } ?? [file.path: .untracked], repositories: [root.path: FinderRepositoryMetadata()])
            let flags = FinderShellRules.flags(paths: [root], snapshot: snapshot)
            XCTAssertTrue(flags.contains([.inGit, .workingTreeRoot, .folderInGit])); XCTAssertFalse(flags.contains(.ignored))
            XCTAssertTrue(FinderShellRules.allows(.log, flags: flags)); XCTAssertFalse(FinderShellRules.allows(.initialize, flags: flags))
            let creation = FinderCreationMenuContext.read(directory: root, snapshot: snapshot, extended: true)
            XCTAssertTrue(creation.versioned); XCTAssertFalse(creation.actions.contains(.initialize))
            let fileFlags = FinderShellRules.flags(paths: [file], snapshot: snapshot)
            XCTAssertFalse(fileFlags.contains(.inGit)); XCTAssertTrue(FinderShellRules.allows(.add, flags: fileFlags))
        }
    }

    func testAllOriginalOverlaySetsDecodeAtBothPreviewSizes() throws {
        XCTAssertEqual(FinderOverlayIconSet.allCases.count, 16)
        for set in FinderOverlayIconSet.allCases {
            for badge in FinderOverlayBadge.allCases {
                for size: CGFloat in [16, 32] {
                    let image = try XCTUnwrap(badge.image(set: set, size: size), "\(set.rawValue) / \(badge)")
                    XCTAssertTrue(image.isValid, "\(set.rawValue) / \(badge)")
                    XCTAssertEqual(image.size, NSSize(width: size, height: size))
                    var rectangle = NSRect(origin: .zero, size: image.size)
                    XCTAssertNotNil(image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil), "\(set.rawValue) / \(badge) pixels")
                }
            }
        }
    }
}
