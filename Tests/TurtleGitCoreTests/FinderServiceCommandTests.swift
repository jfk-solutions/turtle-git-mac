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
            ("pull",.pull),("fetch",.fetch),("push",.push),("synchronize",.synchronize),("rebase",.rebase),("stash",.stash),("stashApply",.stashApply),("stashPop",.stashPop),("stashList",.stashList),("switchBranch",.switchBranch),("merge",.merge),("branch",.branch),("tag",.tag)]
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
        for invalid in ["", "LOG", "revert", "remove", "commit&path=/other", " log"] {
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
        for text in ["https://service?command=log&path=/repo", "turtlegit://action?command=log&path=/repo", "turtlegit://service/extra?command=log&path=/repo", "turtlegit://user@service?command=log&path=/repo", "turtlegit://service:1234?command=log&path=/repo", "turtlegit://service?command=log&path=/repo#fragment", "turtlegit://service?path=/repo", "turtlegit://service?command=remove&path=/repo", "turtlegit://service?command=LOG&path=/repo", "turtlegit://service?command=log"] {
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

    func testOnlyDiffCapturesExplicitAlternateToolWithoutChangingSelectedPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = [literal("/repo/first 雪 &?.txt"), literal("/repo/second.txt")]
        for alternate in [false, true] {
            let request = try FinderServiceCommand.diff.request(paths: paths, alternateTool: alternate)
            XCTAssertEqual(request.alternateTool, alternate)
            let wire = try FinderServiceCommand.diff.serviceURL(paths: paths, alternateTool: alternate)
            let decoded = try FinderServiceCommand.request(serviceURL: wire)
            XCTAssertEqual(decoded.action, .diff); XCTAssertEqual(decoded.alternateTool, alternate)
            XCTAssertEqual(decoded.paths.map { Data($0.path.utf8) }, paths.map { Data($0.path.utf8) })
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: wire.absoluteString + "&alternate=1"))))
        }
        for suffix in ["&alternate=", "&alternate=true", "&alternate=2", "&alternate=-1", "&alternate"] {
            let wire = try FinderServiceCommand.diff.serviceURL(paths: paths)
            XCTAssertThrowsError(try FinderServiceCommand.request(serviceURL: XCTUnwrap(URL(string: wire.absoluteString + suffix))))
        }
        for command in FinderServiceCommand.allCases where command != .diff {
            _ = try command.request(paths: [directory])
            for alternate in [false, true] {
                XCTAssertThrowsError(try command.request(paths: [directory], alternateTool: alternate))
                XCTAssertThrowsError(try command.serviceURL(paths: [directory], alternateTool: alternate))
            }
        }
    }
}
