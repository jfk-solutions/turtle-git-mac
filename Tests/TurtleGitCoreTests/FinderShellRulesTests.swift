import XCTest
@testable import TurtleGitCore

final class FinderShellRulesTests: XCTestCase {
    func testPinnedSourceConditions() throws {
        struct Clause: Decodable { let yes: [String]; let no: [String] }
        struct Rule: Decodable { let command: String; let clauses: [Clause] }
        struct Fixture: Decodable { let upstreamCommit: String; let rules: [String: Rule] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("docs/upstream-shell-menu-conditions.json")))
        XCTAssertEqual(fixture.upstreamCommit, "7338078f8ddd924b8cddee35f512f2286072136d")
        let tokens: [String: FinderShellFlags] = [
            "ITEMIS_FOLDER": .folder, "ITEMIS_INGIT": .inGit, "ITEMIS_FOLDERINGIT": .folderInGit,
            "ITEMIS_BAREREPO": .bare, "ITEMIS_INACCESSIBLE": .inaccessible, "ITEMIS_IGNORED": .ignored,
            "ITEMIS_EXTENDED": .extended, "ITEMIS_ONLYONE": .onlyOne, "ITEMIS_TWO": .two,
            "ITEMIS_WCROOT": .workingTreeRoot, "ITEMIS_BISECT": .bisect, "ITEMIS_MERGEACTIVE": .merge,
            "ITEMIS_ADDED": .added, "ITEMIS_NORMAL": .normal, "ITEMIS_CONFLICTED": .conflicted,
            "ITEMIS_INVERSIONEDFOLDER": .inVersionedFolder, "ITEMIS_SUBMODULE": .submodule,
            "ITEMIS_PATCHFILE": .patchFile, "ITEMIS_DELETED": .deleted, "ITEMIS_STASH": .stash, "ITEMIS_SUBMODULECONTAINER": .submoduleContainer
        ]
        XCTAssertEqual(fixture.rules.count, 45)
        XCTAssertEqual(Set(fixture.rules.keys), Set(FinderShellRules.conditions.keys.map(\.rawValue)))
        func mask(_ names: [String]) throws -> FinderShellFlags {
            try names.reduce(into: FinderShellFlags()) { $0.formUnion(try XCTUnwrap(tokens[$1], $1)) }
        }
        for (name, rule) in fixture.rules {
            let action = try XCTUnwrap(RepositoryAction(rawValue: name))
            let actual = try XCTUnwrap(FinderShellRules.conditions[action])
            XCTAssertEqual(actual.count, 4, rule.command)
            for (native, source) in zip(actual, rule.clauses) {
                XCTAssertEqual(native.required, try mask(source.yes), rule.command)
                XCTAssertEqual(native.excluded, try mask(source.no), rule.command)
            }
        }
        XCTAssertFalse(FinderShellCondition([], []).matches([]))
        XCTAssertTrue(FinderShellCondition([], [.folder]).matches([.onlyOne]))
        XCTAssertFalse(FinderShellCondition([], [.folder]).matches([.folder]))
    }

    func testSelectionAndStatusClauses() {
        let file: FinderShellFlags = [.inGit, .inVersionedFolder, .onlyOne, .normal]
        XCTAssertTrue(FinderShellRules.allows(.log, flags: file))
        XCTAssertFalse(FinderShellRules.allows(.log, flags: file.union(.added)))
        for action in [RepositoryAction.pull, .fetch, .reflog, .referenceBrowser, .repositoryBrowser, .branch, .tag, .switchBranch, .formatPatch, .importPatch] {
            XCTAssertFalse(FinderShellRules.allows(action, flags: file), action.rawValue)
        }
        XCTAssertTrue(FinderShellRules.allows(.importPatch, flags: file.union(.patchFile)))
        XCTAssertTrue(FinderShellRules.allows(.importPatch, flags: [.folderInGit, .onlyOne]))
        XCTAssertFalse(FinderShellRules.allows(.importPatch, flags: [.folderInGit, .two]))
        XCTAssertFalse(FinderShellRules.allows(.clean, flags: file))
        XCTAssertTrue(FinderShellRules.allows(.clean, flags: [.folderInGit, .folder]))
        XCTAssertFalse(FinderShellRules.allows(.clean, flags: [.folderInGit]))
        XCTAssertFalse(FinderShellRules.allows(.clean, flags: [.bare, .folder]))
        XCTAssertFalse(FinderShellRules.allows(.revert, flags: file))
        XCTAssertTrue(FinderShellRules.allows(.revert, flags: file.subtracting(.normal)))
        XCTAssertTrue(FinderShellRules.allows(.rename, flags: file))
        XCTAssertFalse(FinderShellRules.allows(.rename, flags: file.union(.workingTreeRoot)))
        XCTAssertFalse(FinderShellRules.allows(.remove, flags: file.union(.added)))
        XCTAssertTrue(FinderShellRules.allows(.diff, flags: [.two]))
        XCTAssertFalse(FinderShellRules.allows(.diff, flags: [.two, .folder]))
        XCTAssertTrue(FinderShellRules.allows(.ignore, flags: [.inVersionedFolder, .onlyOne]))
        XCTAssertFalse(FinderShellRules.allows(.ignore, flags: file))
        XCTAssertTrue(FinderShellRules.allows(.ignoreDelete, flags: file))
        XCTAssertFalse(FinderShellRules.allows(.ignoreDelete, flags: file.union(.workingTreeRoot)))
        let folder = file.union([.folder, .folderInGit, .workingTreeRoot])
        XCTAssertTrue(FinderShellRules.allows(.branch, flags: folder))
        XCTAssertFalse(FinderShellRules.allows(.branch, flags: folder.subtracting(.onlyOne)))
        XCTAssertTrue(FinderShellRules.allows(.pull, flags: folder.subtracting(.onlyOne)))
        XCTAssertFalse(FinderShellRules.allows(.pull, flags: folder.union(.merge)))
        XCTAssertFalse(FinderShellRules.allows(.clone, flags: folder))
        XCTAssertTrue(FinderShellRules.allows(.clone, flags: folder.union(.extended)))
    }

    func testMergeAbortRequiresActiveMergeButNotConflictsOrOneSelection() throws {
        for flags in [[.inGit, .merge], [.folderInGit, .merge], [.inGit, .merge, .two], [.inGit, .merge, .normal]] as [FinderShellFlags] {
            XCTAssertTrue(FinderShellRules.allows(.mergeAbort, flags: flags))
        }
        for flags in [[], [.inGit], [.folderInGit], [.merge], [.bare, .merge], [.inGit, .conflicted]] as [FinderShellFlags] {
            XCTAssertFalse(FinderShellRules.allows(.mergeAbort, flags: flags))
        }
        XCTAssertFalse(FinderRepositoryMetadata().allows(.mergeAbort))
        XCTAssertTrue(FinderRepositoryMetadata(mergeActive: true).allows(.mergeAbort))
        XCTAssertFalse(FinderRepositoryMetadata(bare: true, mergeActive: true).allows(.mergeAbort))
        let request = FinderRequest(action: .mergeAbort, paths: [URL(fileURLWithPath: "/tmp/repo 雪/file\n")])
        let decoded = try XCTUnwrap(request.url.flatMap(FinderRequest.init(url:)))
        XCTAssertEqual(decoded.action, .mergeAbort); XCTAssertEqual(decoded.paths, request.paths)
        XCTAssertTrue(decoded.action.requiresWorkingTree); XCTAssertFalse(decoded.action.requiresValue)
        XCTAssertNil(decoded.action.arguments(value: "")); XCTAssertEqual(decoded.action.icon, .mergeAbort)
    }

    func testCachedPathClassification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tracked = folder.appendingPathComponent("tracked 雪.txt"), added = folder.appendingPathComponent("added.txt")
        let untracked = folder.appendingPathComponent("new.txt"), ignored = folder.appendingPathComponent("ignored.txt")
        for file in [tracked, added, untracked, ignored] { try Data().write(to: file) }
        let snapshot = FinderSnapshot(roots: [folder.path], states: [folder.path: .modified, tracked.path: .normal,
            added.path: .added, untracked.path: .untracked, ignored.path: .ignored],
            repositories: [folder.path: FinderRepositoryMetadata(mergeActive: true, hasStash: true)])
        let rootFlags = FinderShellRules.flags(paths: [folder], snapshot: snapshot)
        XCTAssertTrue(rootFlags.isSuperset(of: [.folder, .folderInGit, .workingTreeRoot, .onlyOne, .merge, .stash]))
        XCTAssertFalse(rootFlags.contains(.submoduleContainer))
        let trackedFlags = FinderShellRules.flags(paths: [tracked], snapshot: snapshot)
        XCTAssertTrue(trackedFlags.isSuperset(of: [.inGit, .normal, .inVersionedFolder, .onlyOne]))
        XCTAssertFalse(trackedFlags.contains(.folder))
        XCTAssertTrue(FinderShellRules.flags(paths: [added], snapshot: snapshot).contains(.added))
        XCTAssertFalse(FinderShellRules.flags(paths: [untracked], snapshot: snapshot).contains(.inGit))
        let ignoredFlags = FinderShellRules.flags(paths: [ignored], snapshot: snapshot)
        XCTAssertTrue(ignoredFlags.contains(.ignored)); XCTAssertFalse(ignoredFlags.contains(.inGit))
        XCTAssertTrue(FinderShellRules.flags(paths: [tracked, added], snapshot: snapshot).contains(.two))
        XCTAssertFalse(FinderShellRules.flags(paths: [tracked, added], snapshot: snapshot).contains(.onlyOne))
        let sibling = URL(fileURLWithPath: folder.path + "-other/file")
        XCTAssertFalse(FinderShellRules.flags(paths: [sibling], snapshot: snapshot).contains(.inVersionedFolder))
    }
}
