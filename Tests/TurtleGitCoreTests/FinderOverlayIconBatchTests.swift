// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import XCTest
@testable import TurtleGitCore

final class FinderOverlayIconBatchTests: XCTestCase {
    func testOverlayDraftEqualityPreservesLiteralRuleSpelling() throws {
        var composed = FinderOverlaySettings(), decomposed = composed
        composed.includePaths = "/repo/café?"; decomposed.includePaths = "/repo/cafe\u{301}?"
        XCTAssertEqual(composed.includePaths, decomposed.includePaths) // Swift canonical equality.
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertTrue(composed.pathPolicy.allows("/repo/café", fallback: false, caseSensitive: true))
        XCTAssertFalse(composed.pathPolicy.allows("/repo/cafe\u{301}", fallback: false, caseSensitive: true))
        XCTAssertTrue(decomposed.pathPolicy.allows("/repo/cafe\u{301}", fallback: false, caseSensitive: true))
        XCTAssertTrue(composed.pathPolicy.allows("/repo/cafe\u{301}", fallback: false, caseSensitive: false))
        let decoded = try JSONDecoder().decode(FinderOverlaySettings.self, from: JSONEncoder().encode(decomposed))
        XCTAssertEqual(decoded, decomposed); XCTAssertNotEqual(decoded, composed)
        composed.includePaths = ""; decomposed.includePaths = ""
        composed.excludePaths = "/repo/café*"; decomposed.excludePaths = "/repo/cafe\u{301}*"
        XCTAssertNotEqual(composed, decomposed)
        decomposed.excludePaths = composed.excludePaths; XCTAssertEqual(composed, decomposed)
    }
    func testCompiledOverlayRulesRespectVolumeCaseAndExactRecursivePrecedence() {
        let policy = FinderOverlayPathPolicy(exclude: "/Repo*\n/Repo/Exact?\n/Repo/Keep*\n/Repo/Tie?\n", include: "/Repo/Allowed*\n/Repo/Exact*\n/Repo/Keep?\n/Repo/Tie?\n")
        XCTAssertNil(policy.issue)
        XCTAssertFalse(policy.allows("/repo/file", fallback: true, caseSensitive: false))
        XCTAssertTrue(policy.allows("/repo/ALLOWED/file", fallback: false, caseSensitive: false))
        XCTAssertFalse(policy.allows("/Repo/Exact", fallback: true, caseSensitive: true))
        XCTAssertTrue(policy.allows("/Repo/Exact/child", fallback: false, caseSensitive: true))
        XCTAssertTrue(policy.allows("/Repo/Keep", fallback: false, caseSensitive: true))
        XCTAssertFalse(policy.allows("/Repo/Keep/child", fallback: true, caseSensitive: true))
        XCTAssertTrue(policy.allows("/Repo/Tie", fallback: false, caseSensitive: true))
        XCTAssertFalse(policy.allows("/Repo/Tie/child", fallback: true, caseSensitive: true))
        XCTAssertTrue(policy.allows("/repository/file", fallback: true, caseSensitive: false))
        XCTAssertTrue(policy.allows("/repo/file", fallback: true, caseSensitive: true))
        let unicode = FinderOverlayPathPolicy(exclude: "/repo/Café*", include: "")
        XCTAssertFalse(unicode.allows("/REPO/Cafe\u{301}/file", fallback: true, caseSensitive: false))
        XCTAssertTrue(unicode.allows("/repo/Cafe\u{301}/file", fallback: true, caseSensitive: true))
        let root = FinderOverlayPathPolicy(exclude: "/", include: "/allowed?")
        XCTAssertTrue(root.allows("/allowed", fallback: false, caseSensitive: true))
        XCTAssertFalse(root.allows("/allowed/child", fallback: true, caseSensitive: true))
    }
    func testOverlayRuleDiagnosticsAndHomeExpansionDoNotPublishInvalidIncludes() {
        let policy = FinderOverlayPathPolicy(exclude: "\n/valid*\r\nrelative\n", include: "/allowed*", home: URL(fileURLWithPath: "/private/House"))
        XCTAssertEqual(policy.issue?.line, 3); XCTAssertEqual(policy.issue?.include, false)
        XCTAssertTrue(policy.issue?.message.contains("Exclude paths, line 3") == true)
        XCTAssertFalse(policy.allows("/allowed/file", fallback: true, caseSensitive: true))
        let zero = FinderOverlayPathPolicy(exclude: "", include: "/valid\n/bad\0path")
        XCTAssertEqual(zero.issue?.line, 2); XCTAssertEqual(zero.issue?.include, true)
        let home = FinderOverlayPathPolicy(exclude: "~*", include: "$HOME/exact?", home: URL(fileURLWithPath: "/private/House"))
        XCTAssertEqual(home.includeCount, 1); XCTAssertEqual(home.excludeCount, 1)
        XCTAssertFalse(home.allows("/private/House/file", fallback: true, caseSensitive: true))
        XCTAssertTrue(home.allows("/private/House/exact", fallback: false, caseSensitive: true))
        XCTAssertFalse(home.allows("relative", fallback: true, caseSensitive: true))
    }
    func testOverlayProjectionUsesEachMountAndPolicyForIndexHandlers() {
        let snapshot = FinderSnapshot(roots: ["/repo"], states: ["/repo/mount/file": .normal], overlayEntries: ["/repo/local": .normal, "/repo/mount/file": .normal, "/repo/mount/folder": .normal], indexFlags: ["/repo/mount/file": .init(skipWorktree: true), "/repo/local": .init(assumeUnchanged: true)])
        var settings = FinderOverlaySettings()
        func badges() -> GitPathMap<FinderOverlayBadge> {
            settings.overlayBadges(snapshot: snapshot, volume: { $0.hasPrefix("/repo/mount") ? .network : .fixed }, isDirectory: { $0 == "/repo/mount/folder" }, caseSensitive: { $0.hasPrefix("/repo/mount") })
        }
        XCTAssertEqual(badges()["/repo/local"], .assumeUnchanged)
        XCTAssertNil(badges()["/repo/mount/file"]); XCTAssertEqual(badges()["/repo/mount/folder"], .normal)
        settings.includePaths = "/REPO/MOUNT*"
        XCTAssertNil(badges()["/repo/mount/file"], "A sensitive child volume must not inherit the root's insensitive rule matching")
        settings.includePaths = "/repo/mount*"; XCTAssertEqual(badges()["/repo/mount/file"], .skipWorktree)
        XCTAssertEqual(snapshot.states["/repo/mount/file"], .normal)
    }
    func testOverlayFileSystemCachesDirectoriesAndHonorsMountsLinksAndMissingPaths() {
        var reads: [String] = []
        let fs = FinderOverlayFileSystem(readVolume: { url in
            reads.append(url.path)
            if url.path == "/repo/mount/missing" { return nil }
            return FinderOverlayVolume(kind: url.path.hasPrefix("/repo/mount") ? .network : .fixed, caseSensitive: url.path.hasPrefix("/repo/mount"))
        }, readDirectory: { ["/repo", "/repo/mount"].contains($0.path) })
        XCTAssertEqual(fs.volume("/repo/one").kind, .fixed); XCTAssertFalse(fs.volume("/repo/two").caseSensitive)
        XCTAssertEqual(reads, ["/repo"])
        XCTAssertEqual(fs.volume("/repo/mount/one").kind, .network); XCTAssertTrue(fs.volume("/repo/mount/two").caseSensitive)
        XCTAssertEqual(reads, ["/repo", "/repo/mount"])
        XCTAssertEqual(fs.volume("/repo/link-to-mount").kind, .fixed)
        XCTAssertEqual(fs.volume("/repo/mount/missing/deleted").kind, .network)
        XCTAssertEqual(reads.filter { $0 == "/repo/mount/missing" }.count, 1)
        XCTAssertEqual(fs.volume("/repo/mount/missing/other").kind, .network)
        XCTAssertEqual(reads.filter { $0 == "/repo/mount/missing" }.count, 1)
    }
    func testFinderBadgeLookupHandlesAliasesWithoutCollapsingSensitiveNames() {
        let lookup = FinderOverlayBadgeLookup(badges: ["/Repo/Café": .modified, "/Repo/café": .conflicted, "/sensitive/File": .added], caseSensitive: { $0.hasPrefix("/sensitive") })
        XCTAssertEqual(lookup.badge(for: "/REPO/Cafe\u{301}", caseSensitive: false), .conflicted)
        XCTAssertEqual(lookup.badge(for: "/sensitive/File", caseSensitive: true), .added)
        XCTAssertNil(lookup.badge(for: "/sensitive/file", caseSensitive: true))
        XCTAssertNil(lookup.badge(for: "/sensitive/file", caseSensitive: false))
        var metadataReads = 0
        func sensitivity() -> Bool { metadataReads += 1; return true }
        XCTAssertNil(lookup.badge(for: "/unbadged/path", caseSensitive: sensitivity()))
        XCTAssertEqual(lookup.badge(for: "/sensitive/File", caseSensitive: sensitivity()), .added)
        XCTAssertEqual(metadataReads, 0, "Ordinary unbadged requests must not query filesystem metadata")
        let sensitiveUnicode = FinderOverlayBadgeLookup(badges: ["/sensitive/Café": .normal], caseSensitive: { _ in true })
        XCTAssertNil(sensitiveUnicode.badge(for: "/sensitive/Cafe\u{301}", caseSensitive: true))
    }
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
        func badges() -> GitPathMap<FinderOverlayBadge> {
            settings.overlayBadges(snapshot: snapshot, volume: { _ in .network }, isDirectory: { $0 == "/repo/folder" })
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
