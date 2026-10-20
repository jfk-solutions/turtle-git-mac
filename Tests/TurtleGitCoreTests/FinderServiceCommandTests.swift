import XCTest
@testable import TurtleGitCore

/// Services selections use the normal request router, without requiring cached Finder roots.
final class FinderServiceCommandTests: XCTestCase {
    private func literal(_ path: String) -> URL { FileTransferPaths.fileURL(path) }

    func testCommandsMapToExistingDialogsWithoutAddingAuthorityOrPresets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected: [(String, RepositoryAction)] = [("log", .log), ("commit", .commit), ("status", .status), ("diff", .diff), ("clone", .clone), ("initialize", .initialize),
            ("pull",.pull),("fetch",.fetch),("push",.push),("synchronize",.synchronize),("rebase",.rebase),("stash",.stash),("stashApply",.stashApply),("stashPop",.stashPop),("stashList",.stashList),("switchBranch",.switchBranch),("merge",.merge),("branch",.branch),("tag",.tag),
            ("add",.add),("revert",.revert),("resolve",.resolve),("resolveCurrent",.resolveCurrent),("resolveMine",.resolveMine),("resolveTheirs",.resolveTheirs),("blame",.blame),("previousDiff",.previousDiff),("editConflict",.editConflict),("ignore",.ignore),("ignoreMask",.ignoreMask),("ignoreDelete",.ignoreDelete),("ignoreDeleteMask",.ignoreDeleteMask),("rename",.rename),("remove",.remove),("removeKeep",.removeKeep),("clean",.clean),("worktreeList",.worktreeList),("worktreeCreate",.worktreeCreate),("submoduleAdd",.submoduleAdd),("submoduleUpdate",.submoduleUpdate),("submoduleSync",.submoduleSync),("logSubmodule",.logSubmodule)]
        XCTAssertEqual(Set(FinderServiceCommand.allCases.map(\.rawValue)), Set(expected.map(\.0)))
        for (name, action) in expected {
            let command = try XCTUnwrap(FinderServiceCommand(rawValue: name))
            let request = try command.request(paths: [directory])
            XCTAssertEqual(request.action, action)
            XCTAssertEqual(request.paths.map(\.path), [directory.standardizedFileURL.path])
            XCTAssertTrue(request.sources.isEmpty)
            XCTAssertNil(request.alternateTool)
            XCTAssertNil(request.requestPullEnd); XCTAssertNil(request.requestPullURL); XCTAssertNil(request.clipboardPatch)
            let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.action, action); XCTAssertEqual(decoded.paths.map(\.path), request.paths.map(\.path))
            let service = try command.serviceURL(paths: [directory])
            XCTAssertEqual(service.scheme, "turtlegit"); XCTAssertEqual(service.host, "service")
            XCTAssertNil(FinderRequest(url: service), "Services envelopes must use their reviewed route")
            let serviceRequest = try FinderServiceCommand.request(serviceURL: service)
            XCTAssertEqual(serviceRequest.action, action)
            XCTAssertEqual(serviceRequest.paths.map(\.path), request.paths.map(\.path))
            XCTAssertNil(serviceRequest.alternateTool)
        }
        for invalid in ["", "LOG", "unignore", "remove-force", "commit&path=/other", " log"] {
            XCTAssertNil(FinderServiceCommand(rawValue: invalid))
        }
    }

    func testExpandedServicesPreserveSelectionsAndApplySourceCardinality() throws {
        let commands:[FinderServiceCommand]=[.pull,.fetch,.push,.synchronize,.rebase,.stash,.stashApply,.stashPop,.stashList,.switchBranch,.merge,.branch,.tag]
        let first=literal("/unwatched service 雪/folder &?\n"),second=literal("/unwatched service 雪/other")
        let multiple:Set<FinderServiceCommand>=[.pull,.fetch,.push]
        for command in commands {
            XCTAssertTrue(command.requiresSourceEligibility,command.rawValue)
            XCTAssertEqual(command.requiresSingleSelection,!multiple.contains(command))
            XCTAssertEqual(command.action.rawValue,command.rawValue)
            let request=try command.request(paths:[first,first])
            XCTAssertEqual(request.paths.map{Data($0.path.utf8)},[Data(first.path.utf8)])
            let envelope=try command.serviceURL(paths:[first,first]),decoded=try FinderServiceCommand.request(serviceURL:envelope)
            XCTAssertEqual(decoded.action,command.action);XCTAssertEqual(decoded.paths.map{Data($0.path.utf8)},[Data(first.path.utf8)])
            XCTAssertTrue(decoded.sources.isEmpty);XCTAssertNil(decoded.alternateTool)
            if multiple.contains(command) {
                let pair=try FinderServiceCommand.request(serviceURL:command.serviceURL(paths:[first,second]))
                XCTAssertEqual(pair.paths.map{Data($0.path.utf8)},[first,second].map{Data($0.path.utf8)})
            }else{
                XCTAssertThrowsError(try command.request(paths:[first,second]))
                var forged=URLComponents();forged.scheme="turtlegit";forged.host="service"
                forged.queryItems=[URLQueryItem(name:"command",value:command.rawValue),URLQueryItem(name:"path",value:first.path),URLQueryItem(name:"path",value:second.path)]
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(forged.url)))
            }
            for control in ["&source=/other","&branch=main","&ref=refs/stash","&force=1","&url=ssh://example.invalid/repo","&alternate=0","&alternate=1"] {
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(URL(string:envelope.absoluteString+control))),command.rawValue+control)
            }
        }
        for legacy in [FinderServiceCommand.log,.commit,.status,.diff,.clone,.initialize]{XCTAssertFalse(legacy.requiresSourceEligibility)}
        for alias in ["sync","stashSave","createBranch","createTag","switch","stashdrop","stashClear"] {XCTAssertNil(FinderServiceCommand(rawValue:alias))}
    }

    func testExpandedServicesFollowIndependentPinnedMenuConditions() throws {
        let commands:[FinderServiceCommand]=[.pull,.fetch,.push,.synchronize,.rebase,.stash,.stashApply,.stashPop,.stashList,.switchBranch,.merge,.branch,.tag]
        let ordinary:Set<FinderServiceCommand>=[.pull,.fetch,.push,.synchronize,.rebase,.stash,.switchBranch,.merge,.branch,.tag]
        // Independent expected commands, taken from MenuInfo.cpp:35–46,
        // 102–113 and 167–176, rather than querying the shared predicate itself.
        let cases:[(FinderShellFlags,Set<FinderServiceCommand>)]=[
            ([.folder,.folderInGit,.inGit,.onlyOne],ordinary),
            ([.folder,.folderInGit,.inGit,.onlyOne,.stash],Set(commands)),
            ([.inGit,.inVersionedFolder,.onlyOne],[.stash]),
            ([.inVersionedFolder,.onlyOne],[]),
            ([.folder,.bare,.onlyOne],[.fetch,.push]),
            ([.folder,.folderInGit,.inGit,.onlyOne,.merge],[.fetch,.push,.switchBranch,.branch,.tag]),
            ([.folder,.folderInGit,.inGit,.onlyOne,.bisect],[.fetch,.push,.stash,.switchBranch,.branch,.tag]),
            ([.folder,.folderInGit,.inGit,.onlyOne,.merge,.stash],[.fetch,.push,.stashApply,.stashPop,.stashList,.switchBranch,.branch,.tag]),
            ([.folder,.folderInGit,.inGit,.workingTreeRoot,.two],[.pull,.fetch,.push]),
            ([.folder,.folderInGit,.inGit,.two],[]),
            ([.folder,.bare,.two],[.fetch,.push]),
            ([],[])
        ]
        for(flags,expected)in cases {
            let actual=Set(commands.filter{$0.isEligible(flags:flags)})
            XCTAssertEqual(actual,expected,"Source Services clauses differ for flags \(flags)")
        }
    }

    func testFirstUseScopesRetainOrderedLiteralPathsAndExactDeduplication() throws {
        // Nothing is created or added to Finder's monitored roots. Missing leaves remain editable input.
        let base = "/TurtleGit-services-unmonitored-" + UUID().uuidString
        let names = ["space &?#%\n雪.txt", "case.txt", "CASE.txt", "café.txt", "cafe\u{301}.txt", "-leading.txt", "literal*asterisk.txt"]
        let selected = names.map { literal(base + "/" + $0) }
        for command in [FinderServiceCommand.log, .commit, .status, .diff] {
            let request = try command.request(paths: [selected[0]] + selected + [selected[2]])
            XCTAssertEqual(request.paths.map { Data($0.path.utf8) }, selected.map { Data($0.path.utf8) })
            let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.paths.map { Data($0.path.utf8) }, selected.map { Data($0.path.utf8) })
            XCTAssertEqual(request.relativePaths(root: literal(base)).map { Data($0.utf8) }, names.map { Data($0.utf8) })
        }
    }

    func testRejectsMalformedURLsAndAdministrativeSelectionsBeforeRouting() throws {
        let malformed = [
            try XCTUnwrap(URL(string: "https://example.invalid/repo")),
            try XCTUnwrap(URL(string: "file://remote.invalid/repo")),
            try XCTUnwrap(URL(string: "file://user@localhost/repo")),
            try XCTUnwrap(URL(string: "file://user:secret@localhost/repo")),
            try XCTUnwrap(URL(string: "file://localhost:1234/repo")),
            try XCTUnwrap(URL(string: "file:///repo?selection=other")),
            try XCTUnwrap(URL(string: "file:///repo#other")),
            try XCTUnwrap(URL(string: "file:///repo/bad%00name")),
            literal("/repo/.git"), literal("/repo/.git/config"), literal("/repo/.GIT/objects"),
            literal("/repo/.git/../selected")
        ]
        for command in FinderServiceCommand.allCases {
            XCTAssertThrowsError(try command.request(paths: []), command.rawValue)
            for path in malformed {
                XCTAssertThrowsError(try command.request(paths: [path]), command.rawValue + " " + path.absoluteString)
            }
        }
        let valid = [literal("/repo/.gitignore"), literal("/repo/git"), literal("/repo/.git-worktrees/file")]
        XCTAssertEqual(try FinderServiceCommand.status.request(paths: valid).paths.count, valid.count)
        let localHost = try XCTUnwrap(URL(string: "file://localhost/repo/file"))
        XCTAssertEqual(try FinderServiceCommand.log.request(paths: [localHost]).paths.first?.path, "/repo/file")
    }

    func testCreationRequiresOneExistingDirectoryWhileNormalScopesAllowMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.txt"), missing = directory.appendingPathComponent("missing")
        let link = directory.appendingPathComponent("directory-link")
        try Data("unchanged selection".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        for command in [FinderServiceCommand.clone, .initialize] {
            XCTAssertEqual(try command.request(paths: [directory]).paths.count, 1)
            XCTAssertThrowsError(try command.request(paths: [file]))
            XCTAssertThrowsError(try command.request(paths: [missing]))
            XCTAssertThrowsError(try command.request(paths: [directory, file]))
            XCTAssertThrowsError(try command.request(paths: [link]))
            XCTAssertThrowsError(try command.request(paths: [literal("/")]))
        }
        for command in [FinderServiceCommand.log, .commit, .status, .diff] {
            XCTAssertEqual(try command.request(paths: [file, missing]).paths.count, 2)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("unchanged selection".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
    }

    func testRawSelectionLimitAppliesBeforeDeduplication() throws {
        let base = "/TurtleGit-services-count-" + UUID().uuidString
        let paths = (0..<10_000).map { literal(base + "/file-" + String($0)) }
        let request = try FinderServiceCommand.status.request(paths: paths)
        XCTAssertEqual(request.paths.count, 10_000)
        XCTAssertEqual(request.paths.first?.path, paths.first?.path)
        XCTAssertEqual(request.paths.last?.path, paths.last?.path)
        XCTAssertThrowsError(try FinderServiceCommand.status.request(paths: paths + [literal(base + "/extra")]))
        XCTAssertThrowsError(try FinderServiceCommand.status.request(paths: Array(repeating: paths[0], count: 10_001)))
    }

    func testEncodedRequestBudgetIncludesEscapingAndEnvelopeAtExactBoundary() throws {
        // An independent URLComponents envelope computes wire bytes, rather than calling the policy under test.
        func wireBytes(_ path: String) throws -> Int {
            var components = URLComponents()
            components.scheme = "turtlegit"; components.host = "service"
            components.queryItems = [URLQueryItem(name: "command", value: "log"), URLQueryItem(name: "path", value: path)]
            return try XCTUnwrap(components.url).absoluteString.utf8.count
        }
        let limit = 1_048_576, overhead = try wireBytes("/")
        let exact = "/" + String(repeating: "a", count: limit - overhead)
        XCTAssertEqual(try wireBytes(exact), limit)
        let accepted = try FinderServiceCommand.log.request(paths: [literal(exact)])
        XCTAssertEqual(try XCTUnwrap(accepted.url).absoluteString.utf8.count, limit - 1)
        let wire = try FinderServiceCommand.log.serviceURL(paths: [literal(exact)])
        XCTAssertEqual(wire.absoluteString.utf8.count, limit)
        XCTAssertEqual(try FinderServiceCommand.request(serviceURL: wire).paths.first?.path.utf8.count, exact.utf8.count)
        XCTAssertThrowsError(try FinderServiceCommand.log.request(paths: [literal(exact + "a")]))
        XCTAssertThrowsError(try FinderServiceCommand.log.serviceURL(paths: [literal(exact + "a")]))
        XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: wire.absoluteString + "a"))))
        let escaped = "/" + String(repeating: "雪", count: 120_000)
        XCTAssertLessThan(escaped.utf8.count, limit)
        XCTAssertGreaterThan(try wireBytes(escaped), limit)
        XCTAssertThrowsError(try FinderServiceCommand.log.request(paths: [literal(escaped)]))
    }

    func testServicesEnvelopeRejectsUnrecognizedCommandsFieldsAndAuthority() throws {
        let good = try FinderServiceCommand.log.serviceURL(paths: [literal("/repo/selected")])
        for suffix in ["&command=log", "&command=commit", "&path", "&path=", "&path=relative", "&path=%00", "&source=/other", "&url=ssh://host/repo", "&endrev=HEAD", "&clipboardpatch=unavailable", "&unknown=value", "&alternate", "&alternate=1", "&alternate=0"] {
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: good.absoluteString + suffix))), suffix)
        }
        for text in ["https://service?command=log&path=/repo", "turtlegit://action?command=log&path=/repo", "turtlegit://service/extra?command=log&path=/repo", "turtlegit://user@service?command=log&path=/repo", "turtlegit://service:1234?command=log&path=/repo", "turtlegit://service?command=log&path=/repo#fragment", "turtlegit://service?path=/repo", "turtlegit://service?command=remove-force&path=/repo", "turtlegit://service?command=LOG&path=/repo", "turtlegit://service?command=log"] {
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: text))), text)
        }
        // Parser cardinality is raw-input bounded even if every path later deduplicates.
        let flooded = good.absoluteString + String(repeating: "&path=/repo/selected", count: 10_000)
        XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: flooded))))
        for path in ["/repo/.git/../selected", "/repo/.GIT/../selected", "/repo/nested/../.git/config"] {
            var envelope = URLComponents()
            envelope.scheme = "turtlegit"; envelope.host = "service"
            envelope.queryItems = [URLQueryItem(name: "command", value: "log"), URLQueryItem(name: "path", value: path)]
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(envelope.url)), "Raw administrative traversal must be checked before normalizing: " + path)
        }
    }

    func testComparisonServicesCaptureExplicitAlternateToolWithoutChangingSelectedPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = [literal("/repo/first 雪 &?.txt"), literal("/repo/second.txt")]
        for command in [FinderServiceCommand.diff,.previousDiff,.editConflict] {
          let paths=command == .previousDiff ? Array(paths.prefix(1)):paths
          XCTAssertTrue(command.capturesAlternateTool)
          for alternate in [false, true] {
            let request = try command.request(paths: paths, alternateTool: alternate)
            XCTAssertEqual(request.alternateTool, alternate)
            let wire = try command.serviceURL(paths: paths, alternateTool: alternate)
            let decoded = try FinderServiceCommand.request(serviceURL: wire)
            XCTAssertEqual(decoded.action, command.action); XCTAssertEqual(decoded.alternateTool, alternate)
            XCTAssertEqual(decoded.paths.map { Data($0.path.utf8) }, paths.map { Data($0.path.utf8) })
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: wire.absoluteString + "&alternate=1"))))
        }
        }
        for suffix in ["&alternate=", "&alternate=true", "&alternate=2", "&alternate=-1", "&alternate"] {
            let wire = try FinderServiceCommand.diff.serviceURL(paths: paths)
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: wire.absoluteString + suffix))))
        }
        for command in FinderServiceCommand.allCases where !command.capturesAlternateTool {
            _ = try command.request(paths: [directory])
            for alternate in [false, true] {
                XCTAssertThrowsError(try command.request(paths: [directory], alternateTool: alternate))
                XCTAssertThrowsError(try command.serviceURL(paths: [directory], alternateTool: alternate))
            }
        }
    }
    func testSelectedFileServiceCardinalityAliasesAndStrictEnvelopes() throws {
        let commands:[FinderServiceCommand]=[.add,.revert,.resolve,.resolveCurrent,.resolveMine,.resolveTheirs,.blame,.previousDiff,.editConflict,.ignore,.ignoreMask,.ignoreDelete,.ignoreDeleteMask]
        let first=literal("/unmonitored/first 雪 &?\n.txt"),second=literal("/unmonitored/second.txt")
        for command in commands {
            XCTAssertTrue(command.requiresSourceEligibility)
            XCTAssertEqual(command.requiresSingleSelection,command == .blame || command == .previousDiff)
            let singleton=try command.request(paths:[first,first])
            XCTAssertEqual(singleton.paths.map{Data($0.path.utf8)},[Data(first.path.utf8)])
            let paths=command.requiresSingleSelection ? [first]:[first,second]
            let decoded=try FinderServiceCommand.request(serviceURL:command.serviceURL(paths:paths))
            XCTAssertEqual(decoded.action,command.action)
            XCTAssertEqual(decoded.paths.map{Data($0.path.utf8)},paths.map{Data($0.path.utf8)})
            if command.requiresSingleSelection {XCTAssertThrowsError(try command.request(paths:[first,second]))}
            for suffix in ["&source=/other","&force=1","&ref=HEAD","&command=resolve","&mask=1"] {
                let wire=try command.serviceURL(paths:paths)
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(URL(string:wire.absoluteString+suffix))))
            }
        }
        for command in [FinderServiceCommand.resolveCurrent,.resolveMine,.resolveTheirs] {
            XCTAssertEqual(command.sourceAction,.resolve)
            XCTAssertTrue(command.isEligible(flags:[.inGit,.conflicted]))
            XCTAssertTrue(command.isEligible(flags:[.inGit,.folder]))
            XCTAssertFalse(command.isEligible(flags:[.bare]))
        }
        XCTAssertEqual(FinderServiceCommand.ignoreMask.sourceAction,.ignore)
        XCTAssertEqual(FinderServiceCommand.ignoreDeleteMask.sourceAction,.ignoreDelete)
        XCTAssertTrue(FinderServiceCommand.ignoreMask.isEligible(flags:[.inVersionedFolder]))
        XCTAssertTrue(FinderServiceCommand.ignoreDeleteMask.isEligible(flags:[.inVersionedFolder,.inGit]))
        XCTAssertFalse(FinderServiceCommand.ignoreMask.isEligible(flags:[.inVersionedFolder,.ignored]))
    }

    func testSelectedFileLiveEligibilityKeepsSourceStatusAndDynamicChildrenDistinct() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let folder=root.appendingPathComponent("folder.ext",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let normal=root.appendingPathComponent("normal.txt"),added=root.appendingPathComponent("added.txt")
        let conflict=folder.appendingPathComponent("conflict.txt"),untracked=root.appendingPathComponent("new.txt")
        let extensionless=root.appendingPathComponent("plain"),extensionlessSecond=root.appendingPathComponent("other-plain"),ignored=root.appendingPathComponent("ignored.txt")
        let deleted=root.appendingPathComponent("deleted.txt"),other=literal("/other-repository/file.txt")
        for path in [normal,added,conflict,untracked,extensionless,extensionlessSecond,ignored] {try Data().write(to:path)}
        let snapshot=FinderSnapshot(roots:[root.path,"/other-repository"],states:[root.path:.modified,folder.path:.conflicted,normal.path:.normal,added.path:.added,conflict.path:.conflicted,untracked.path:.untracked,extensionless.path:.untracked,extensionlessSecond.path:.untracked,ignored.path:.ignored,deleted.path:.deleted,other.path:.conflicted])
        for command in [FinderServiceCommand.blame,.previousDiff] {
            XCTAssertTrue(command.isEligible(paths:[normal],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[added],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[normal,conflict],snapshot:snapshot))
        }
        XCTAssertFalse(FinderServiceCommand.blame.isEligible(paths:[folder],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.editConflict.isEligible(paths:[conflict,normal],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.editConflict.isEligible(paths:[normal,conflict],snapshot:snapshot),"Source conflict editor consumes representative first path")
        XCTAssertTrue(FinderServiceCommand.resolve.isEligible(paths:[root],snapshot:snapshot))
        for command in [FinderServiceCommand.resolveCurrent,.resolveMine,.resolveTheirs] {
            XCTAssertTrue(command.isEligible(paths:[folder],snapshot:snapshot))
            XCTAssertTrue(command.isEligible(paths:[conflict,normal],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[normal],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[conflict,other],snapshot:snapshot))
        }
        XCTAssertTrue(FinderServiceCommand.add.isEligible(paths:[untracked],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.add.isEligible(paths:[ignored],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.add.isEligible(paths:[normal],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.revert.isEligible(paths:[normal],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.revert.isEligible(paths:[deleted],snapshot:snapshot))
        for command in [FinderServiceCommand.ignore,.ignoreMask] {
            XCTAssertTrue(command.isEligible(paths:[untracked],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[ignored],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[normal],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[untracked,normal],snapshot:snapshot))
        }
        let dotfile=root.appendingPathComponent(".profile"),trailingDot=root.appendingPathComponent("trailing.")
        try Data().write(to:dotfile);try Data().write(to:trailingDot)
        let suffixSnapshot=FinderSnapshot(roots:[root.path],states:[dotfile.path:.untracked,trailingDot.path:.untracked])
        XCTAssertTrue(FinderServiceCommand.ignoreMask.isEligible(paths:[dotfile],snapshot:suffixSnapshot))
        XCTAssertTrue(FinderServiceCommand.ignoreMask.isEligible(paths:[trailingDot],snapshot:suffixSnapshot))
        XCTAssertTrue(FinderServiceCommand.ignore.isEligible(paths:[extensionless],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.ignoreMask.isEligible(paths:[extensionless],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.ignoreMask.isEligible(paths:[extensionless,untracked],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.ignoreMask.isEligible(paths:[extensionless,extensionlessSecond],snapshot:snapshot),"Source offers multi-selection masks even when rule generation skips all extensionless names")
        let mask=try IgnoreOptions(paths:["plain","other-plain"],mask:true)
        XCTAssertNil(mask.pattern(for:"plain"));XCTAssertNil(mask.pattern(for:"other-plain"))
        let trackedPlain=FinderSnapshot(roots:[root.path],states:[extensionless.path:.normal,extensionlessSecond.path:.modified])
        XCTAssertTrue(FinderServiceCommand.ignoreDeleteMask.isEligible(paths:[extensionless,extensionlessSecond],snapshot:trackedPlain))
        let deleteSelection=try FinderServiceCommand.ignoreDeleteMask.request(paths:[extensionless,extensionlessSecond])
        XCTAssertEqual(deleteSelection.paths.map{Data($0.path.utf8)},[extensionless,extensionlessSecond].map{Data($0.path.utf8)})
        XCTAssertTrue(FinderServiceCommand.ignoreDelete.isEligible(paths:[folder],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.ignoreDeleteMask.isEligible(paths:[folder],snapshot:snapshot))
        let literalLink=root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at:literalLink,withDestinationURL:folder)
        let linkSnapshot=FinderSnapshot(roots:[root.path],states:[literalLink.path:.normal])
        XCTAssertTrue(FinderServiceCommand.ignoreDeleteMask.isEligible(paths:[literalLink],snapshot:linkSnapshot),"A tracked symlink is the selected Git leaf, not its directory target")
        XCTAssertTrue(FinderServiceCommand.ignoreDeleteMask.isEligible(paths:[normal,added],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.ignoreDelete.isEligible(paths:[deleted],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.ignoreDelete.isEligible(paths:[root],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.ignoreDelete.isEligible(paths:[conflict,other],snapshot:snapshot))
    }

    func testFilesystemServicesPreserveLiteralSelectionAndRejectExecutionPresets() throws {
        let first=literal("/unwatched/first &?#%\n雪*[-.txt"),second=literal("/unwatched/cafe\u{301}.txt")
        let commands:[FinderServiceCommand]=[.rename,.remove,.removeKeep,.clean]
        for command in commands {
            XCTAssertTrue(command.requiresSourceEligibility)
            XCTAssertEqual(command.requiresSingleSelection,command == .rename)
            XCTAssertEqual(command.sourceAction,command.action)
            let paths=command == .rename ? [first]:[first,second]
            let wire=try command.serviceURL(paths:paths+[paths[0]])
            let decoded=try FinderServiceCommand.request(serviceURL:wire)
            XCTAssertEqual(decoded.action,command.action)
            XCTAssertEqual(decoded.paths.map{Data($0.path.utf8)},paths.map{Data($0.path.utf8)})
            XCTAssertTrue(decoded.sources.isEmpty);XCTAssertNil(decoded.alternateTool)
            for suffix in ["&force=1","&keep=1","&target=/elsewhere","&source=/elsewhere","&submodule=1","&recursive=1","&alternate=0"] {
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(URL(string:wire.absoluteString+suffix))),command.rawValue+suffix)
            }
        }
        XCTAssertThrowsError(try FinderServiceCommand.rename.request(paths:[first,second]))
        var forged=URLComponents();forged.scheme="turtlegit";forged.host="service"
        forged.queryItems=[URLQueryItem(name:"command",value:"rename"),URLQueryItem(name:"path",value:first.path),URLQueryItem(name:"path",value:second.path)]
        XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(forged.url)))
        for alias in ["delete","deleteKeep","cleanup","rm","mv","Rename"] {XCTAssertNil(FinderServiceCommand(rawValue:alias))}
    }

    func testFilesystemServicesMatchIndependentPinnedConditionsIncludingSubmoduleExceptions() {
        // Pinned MenuInfo.cpp:142–156. Ordinary roots cannot be renamed/deleted;
        // submodule-root Rename/Remove exceptions are deliberately distinct from
        // RemoveKeep. Added leaves remain Rename-eligible, but not Remove.
        let commands:[FinderServiceCommand]=[.rename,.remove,.removeKeep,.clean]
        let cases:[(FinderShellFlags,Set<FinderServiceCommand>)]=[
            ([.inGit,.inVersionedFolder,.onlyOne],[.rename,.remove,.removeKeep]),
            ([.inGit,.inVersionedFolder,.two],[.remove,.removeKeep]),
            ([.inGit,.inVersionedFolder,.onlyOne,.added],[.rename]),
            ([.inVersionedFolder,.onlyOne],[]),
            ([.folder,.folderInGit,.inGit,.inVersionedFolder,.onlyOne],[.rename,.remove,.removeKeep,.clean]),
            ([.folder,.folderInGit,.inGit,.inVersionedFolder,.workingTreeRoot,.onlyOne],[.clean]),
            ([.folder,.folderInGit,.inGit,.inVersionedFolder,.workingTreeRoot,.submodule,.onlyOne],[.rename,.remove,.clean]),
            ([.folder,.folderInGit,.workingTreeRoot,.submodule],[.rename,.remove,.clean]),
            ([.folder,.folderInGit,.two],[.clean]),
            ([.folder,.bare,.onlyOne],[]),
            ([.folder,.onlyOne],[]),
            ([],[])
        ]
        for(flags,expected)in cases {XCTAssertEqual(Set(commands.filter{$0.isEligible(flags:flags)}),expected,"Filesystem service source clauses changed for \(flags)")}
    }

    func testFilesystemServicesUseLiveStatusAndLiteralSymlinkLeaf() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let directory=root.appendingPathComponent("nested",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let normal=root.appendingPathComponent("normal.txt"),added=root.appendingPathComponent("added.txt"),untracked=root.appendingPathComponent("new.txt"),link=root.appendingPathComponent("literal-link")
        for file in [normal,added,untracked] {try Data().write(to:file)}
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        let snapshot=FinderSnapshot(roots:[root.path],states:[root.path:.modified,directory.path:.normal,normal.path:.normal,added.path:.added,untracked.path:.untracked,link.path:.normal])
        for command in [FinderServiceCommand.rename,.remove,.removeKeep] {
            XCTAssertTrue(command.isEligible(paths:[normal],snapshot:snapshot))
            XCTAssertTrue(command.isEligible(paths:[link],snapshot:snapshot),"Git operates on the selected symlink, not its directory target")
            XCTAssertFalse(command.isEligible(paths:[untracked],snapshot:snapshot))
            XCTAssertFalse(command.isEligible(paths:[root],snapshot:snapshot))
        }
        XCTAssertTrue(FinderServiceCommand.rename.isEligible(paths:[added],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.remove.isEligible(paths:[added],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.removeKeep.isEligible(paths:[added],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.remove.isEligible(paths:[normal,link],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.rename.isEligible(paths:[normal,link],snapshot:snapshot))
        XCTAssertTrue(FinderServiceCommand.clean.isEligible(paths:[root,directory],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.clean.isEligible(paths:[normal],snapshot:snapshot))
        XCTAssertFalse(FinderServiceCommand.clean.isEligible(paths:[link],snapshot:snapshot))
        let submodule=FinderSnapshot(roots:[root.path],states:[root.path:.normal],repositories:[root.path:FinderRepositoryMetadata(submoduleParentRoot:root.deletingLastPathComponent().path)])
        XCTAssertTrue(FinderServiceCommand.rename.isEligible(paths:[root],snapshot:submodule))
        XCTAssertTrue(FinderServiceCommand.remove.isEligible(paths:[root],snapshot:submodule))
        XCTAssertFalse(FinderServiceCommand.removeKeep.isEligible(paths:[root],snapshot:submodule))
        let bare=FinderSnapshot(roots:[root.path],states:[:],repositories:[root.path:FinderRepositoryMetadata(bare:true)])
        for command in [FinderServiceCommand.rename,.remove,.removeKeep,.clean] {XCTAssertFalse(command.isEligible(paths:[root],snapshot:bare))}
    }

    func testFilesystemServiceRegistrationPreservesExistingOrderAndSelectorContract() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data=try Data(contentsOf:root.appendingPathComponent("Configuration/App-Info.plist"))
        let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any])
        let services=try XCTUnwrap(plist["NSServices"] as? [[String:Any]])
        XCTAssertEqual(services.count,42)
        let names=services.compactMap{$0["NSUserData"] as? String}
        XCTAssertEqual(Array(names[32..<36]),["rename","remove","removeKeep","clean"])
        XCTAssertEqual(Set(names),Set(FinderServiceCommand.allCases.map(\.rawValue)))
        let originalOrder=["pull","fetch","push","synchronize","commit","diff","log","status","rebase","stash","stashApply","stashPop","stashList","switchBranch","merge","branch","tag","clone","initialize","add","revert","resolve","resolveCurrent","resolveMine","resolveTheirs","blame","previousDiff","editConflict","ignore","ignoreMask","ignoreDelete","ignoreDeleteMask"]
        XCTAssertEqual(Array(names.prefix(32)),originalOrder)
        for entry in services[32..<36] {
            let command=try XCTUnwrap(entry["NSUserData"] as? String)
            XCTAssertEqual(entry["NSMessage"] as? String,"performFinderAction")
            XCTAssertEqual(entry["NSPortName"] as? String,"TurtleGit")
            XCTAssertEqual(entry["NSSendFileTypes"] as? [String],command == "clean" ? ["public.folder"]:["public.item"])
            XCTAssertEqual(entry["NSRestricted"] as? Bool,true)
            XCTAssertEqual((entry["NSRequiredContext"] as? [String:Any])?.count,0)
            XCTAssertTrue(((entry["NSMenuItem"] as? [String:String])?["default"] ?? "").hasPrefix("TurtleGit: "))
        }
    }

    func testLinkedRepositoryServicesPreserveLiteralScopesAndExplicitContextCardinality() throws {
        let commands:[FinderServiceCommand]=[.worktreeList,.worktreeCreate,.submoduleAdd,.submoduleUpdate,.submoduleSync,.logSubmodule]
        let first=literal("/unmonitored/super &?#%\n雪/sub*module"),second=literal("/unmonitored/super &?#%\n雪/other")
        let multiple:Set<FinderServiceCommand>=[.submoduleUpdate,.submoduleSync]
        for command in commands {
            XCTAssertTrue(command.requiresSourceEligibility)
            XCTAssertEqual(command.requiresSingleSelection,!multiple.contains(command))
            XCTAssertEqual(command.sourceAction,command.action)
            let paths=multiple.contains(command) ? [first,second]:[first]
            let wire=try command.serviceURL(paths:paths+[first]),decoded=try FinderServiceCommand.request(serviceURL:wire)
            XCTAssertEqual(decoded.action,command.action)
            XCTAssertEqual(decoded.paths.map{Data($0.path.utf8)},paths.map{Data($0.path.utf8)})
            XCTAssertTrue(decoded.sources.isEmpty);XCTAssertNil(decoded.alternateTool)
            if !multiple.contains(command) {XCTAssertThrowsError(try command.request(paths:[first,second]))}
            for suffix in ["&source=/other","&destination=/new","&ref=main","&force=1","&bkpath=/parent","&submodule=1","&alternate=0"] {
                XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL:XCTUnwrap(URL(string:wire.absoluteString+suffix))),command.rawValue+suffix)
            }
        }
        for alias in ["parentLog","worktree","newWorktree","subadd","subsync","subupdate","logsubmodule"] {XCTAssertNil(FinderServiceCommand(rawValue:alias))}
    }

    func testLinkedRepositoryServicesMatchPinnedConditionsAndDocumentedCreateAdaptation() {
        let commands:[FinderServiceCommand]=[.worktreeList,.worktreeCreate,.submoduleAdd,.submoduleUpdate,.submoduleSync,.logSubmodule]
        // MenuInfo.cpp:81–82,207–220 and the existing macOS DropNewWorktree
        // source-root adaptation. This deliberately tests the bare List clause
        // independently of the explicit singleton Services request boundary.
        let cases:[(FinderShellFlags,Set<FinderServiceCommand>)]=[
            ([.folder,.folderInGit,.onlyOne],[.worktreeList,.submoduleAdd]),
            ([.folder,.folderInGit,.onlyOne,.workingTreeRoot],[.worktreeList,.worktreeCreate,.submoduleAdd]),
            ([.folder,.folderInGit,.onlyOne,.workingTreeRoot,.submodule],[.worktreeList,.worktreeCreate,.submoduleAdd,.logSubmodule]),
            ([.folder,.folderInGit,.onlyOne,.submoduleContainer],[.worktreeList,.submoduleAdd,.submoduleUpdate,.submoduleSync]),
            ([.folder,.folderInGit,.two,.submoduleContainer],[.submoduleUpdate,.submoduleSync]),
            ([.folder,.bare,.onlyOne],[.worktreeList,.worktreeCreate]),
            ([.folder,.bare,.two],[.worktreeList]),
            ([.folder,.folderInGit,.two],[]),
            ([.inGit,.inVersionedFolder,.onlyOne],[]),
            ([.folder,.onlyOne],[]),
            ([],[])
        ]
        for(flags,expected)in cases {XCTAssertEqual(Set(commands.filter{$0.isEligible(flags:flags)}),expected,"Linked Services source clauses changed for \(flags)")}
    }

    func testLinkedRepositoryLiveEligibilitySeparatesChildRootAndParentScopes() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let child=parent.appendingPathComponent("registered",isDirectory:true),nested=parent.appendingPathComponent("nested",isDirectory:true),unregistered=parent.appendingPathComponent("unregistered",isDirectory:true)
        for folder in [child,nested,unregistered] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        defer {try? FileManager.default.removeItem(at:parent)}
        let file=parent.appendingPathComponent("file.txt"),link=parent.appendingPathComponent("link")
        try Data().write(to:file);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:child)
        let superproject=FinderSnapshot(roots:[parent.path],states:[parent.path:.normal,child.path:.normal,nested.path:.normal,file.path:.normal,link.path:.normal],repositories:[parent.path:FinderRepositoryMetadata(hasSubmoduleConfig:true)])
        for command in [FinderServiceCommand.submoduleUpdate,.submoduleSync] {
            XCTAssertTrue(command.isEligible(paths:[parent],snapshot:superproject))
            XCTAssertTrue(command.isEligible(paths:[child,nested],snapshot:superproject),"Parent-scoped pathfile selections must retain multiple folders")
            XCTAssertFalse(command.isEligible(paths:[file],snapshot:superproject))
            XCTAssertFalse(command.isEligible(paths:[link],snapshot:superproject),"A literal Git symlink is not a selected submodule directory")
        }
        XCTAssertTrue(FinderServiceCommand.worktreeCreate.isEligible(paths:[parent],snapshot:superproject))
        XCTAssertFalse(FinderServiceCommand.worktreeCreate.isEligible(paths:[nested],snapshot:superproject))
        XCTAssertTrue(FinderServiceCommand.worktreeList.isEligible(paths:[nested],snapshot:superproject))
        XCTAssertTrue(FinderServiceCommand.submoduleAdd.isEligible(paths:[nested],snapshot:superproject))
        XCTAssertFalse(FinderServiceCommand.logSubmodule.isEligible(paths:[child],snapshot:superproject),"Parent-only cache cannot prove selected child registration")
        let registered=FinderSnapshot(roots:[parent.path,child.path,unregistered.path],states:[parent.path:.normal,child.path:.normal,unregistered.path:.normal],repositories:[parent.path:FinderRepositoryMetadata(hasSubmoduleConfig:true),child.path:FinderRepositoryMetadata(submoduleParentRoot:parent.path),unregistered.path:FinderRepositoryMetadata()])
        XCTAssertTrue(FinderServiceCommand.logSubmodule.isEligible(paths:[child],snapshot:registered))
        XCTAssertFalse(FinderServiceCommand.logSubmodule.isEligible(paths:[parent],snapshot:registered))
        XCTAssertFalse(FinderServiceCommand.logSubmodule.isEligible(paths:[unregistered],snapshot:registered))
        XCTAssertFalse(FinderServiceCommand.logSubmodule.isEligible(paths:[child,parent],snapshot:registered))
        let bare=FinderSnapshot(roots:[parent.path,child.path],states:[:],repositories:[parent.path:FinderRepositoryMetadata(bare:true),child.path:FinderRepositoryMetadata(bare:true)])
        XCTAssertTrue(FinderServiceCommand.worktreeList.isEligible(flags:[.bare,.folder,.two]))
        XCTAssertFalse(FinderServiceCommand.worktreeList.isEligible(paths:[parent,child],snapshot:bare),"Services has no independent Explorer context folder and must not silently narrow ambiguous roots")
        XCTAssertTrue(FinderServiceCommand.worktreeList.isEligible(paths:[parent],snapshot:bare))
        XCTAssertTrue(FinderServiceCommand.worktreeCreate.isEligible(paths:[parent],snapshot:bare))
        for command in [FinderServiceCommand.submoduleAdd,.submoduleUpdate,.submoduleSync,.logSubmodule] {XCTAssertFalse(command.isEligible(paths:[parent],snapshot:bare))}
    }

    func testLinkedServiceRegistrationAppendsSixFolderActionsWithoutChangingPriorDeclarations() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data=try Data(contentsOf:root.appendingPathComponent("Configuration/App-Info.plist"))
        let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any])
        let services=try XCTUnwrap(plist["NSServices"] as? [[String:Any]])
        let names=services.compactMap{$0["NSUserData"] as? String}
        XCTAssertEqual(services.count,42);XCTAssertEqual(Set(names).count,42)
        XCTAssertEqual(Array(names.suffix(6)),["worktreeList","worktreeCreate","submoduleAdd","submoduleUpdate","submoduleSync","logSubmodule"])
        XCTAssertEqual(Array(names[32..<36]),["rename","remove","removeKeep","clean"])
        for entry in services.suffix(6) {
            XCTAssertEqual(entry["NSMessage"] as? String,"performFinderAction")
            XCTAssertEqual(entry["NSPortName"] as? String,"TurtleGit")
            XCTAssertEqual(entry["NSSendFileTypes"] as? [String],["public.folder"])
            XCTAssertEqual(entry["NSRestricted"] as? Bool,true)
            XCTAssertEqual((entry["NSRequiredContext"] as? [String:Any])?.count,0)
            XCTAssertTrue(((entry["NSMenuItem"] as? [String:String])?["default"] ?? "").hasPrefix("TurtleGit: "))
        }
    }

}
