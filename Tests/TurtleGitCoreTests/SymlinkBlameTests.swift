// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SymlinkBlameTests: XCTestCase {
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-link-blame-" + UUID().uuidString)
        let folder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"), wrapper = root.appendingPathComponent("git")
        let runtime = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let script = "#!/bin/sh\nunset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=" + quote(root.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n" + runtime + "\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let repo = GitRepository(root: folder, executable: wrapper, askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Link blame fixture"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.symlinks", "true")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: folder.appendingPathComponent("readme")); try await repo.stage(["readme"]); _ = try await repo.commit(message: "base")
        return (root, repo)
    }
    private func link(_ path: URL, target: String) throws {
        if FileManager.default.fileExists(atPath: path.path) || (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil { try FileManager.default.removeItem(at: path) }
        let result = target.withCString { destination in path.path.withCString { symlink(destination, $0) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func linkBytes(_ path: URL) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = path.path.withCString { source in buffer.withUnsafeMutableBytes { readlink(source, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) } }
        guard count >= 0, count < buffer.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Data(buffer.prefix(count))
    }
    private func hash(_ repo: GitRepository) async throws -> String { try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines) }

    func testPinnedTargetsIncludeDanglingExternalDirectoryAndMultilineWithoutFollowingLeaf() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("binary"), bytes = Data([0, 255, 1, 2, 0])
        try bytes.write(to: target)
        let targets = ["../missing-file", target.path, outside.path + "/", "../missing-cafe\u{0301}\n:(glob)*"]
        let paths = targets.indices.map { ":(glob)* link \($0) 雪" }
        for (path, target) in zip(paths, targets) { try link(repo.root.appendingPathComponent(path), target: target) }
        try await repo.stage(paths); _ = try await repo.commit(message: "link text only")
        let revision = try await hash(repo), index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index"))
        for path in paths { try link(repo.root.appendingPathComponent(path), target: "different working link") }
        for (path, target) in zip(paths, targets) {
            let snapshot = try await repo.blame(path: path)
            XCTAssertEqual(snapshot.revision, revision); XCTAssertEqual(Data(snapshot.path.utf8), Data(path.utf8))
            XCTAssertEqual(snapshot.contents, Data(target.utf8)); XCTAssertTrue(snapshot.lines.allSatisfy { $0.hash == revision })
            XCTAssertEqual(snapshot.lines.map(\.sourceBytes), Data(target.utf8).split(separator: 10, omittingEmptySubsequences: false).map { Data($0) })
            let direct = try await repo.run(["-c", "core.precomposeunicode=false", "blame", "--line-porcelain", "--no-textconv", revision, "--", path]).stdout
            let oracle = direct.split(separator: 10).filter { $0.first == 9 }.map { Data($0.dropFirst()) }
            XCTAssertEqual(snapshot.lines.map(\.sourceBytes), oracle)
            XCTAssertEqual(try linkBytes(repo.root.appendingPathComponent(path)), Data("different working link".utf8))
            let history = try await repo.blameHistory(snapshot, options: GitBlameOptions())
            XCTAssertTrue(history.contains { $0.hash == revision })
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), index)
        let after = try await hash(repo); XCTAssertEqual(after, revision)
    }

    func testRenameTypeTransitionHistoryAndPreviousReblameStayOnLinkBlob() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = "link", renamed = "renamed link", location = repo.root.appendingPathComponent(path)
        try Data("regular source\n".utf8).write(to: location); try await repo.stage([path]); _ = try await repo.commit(message: "regular origin")
        let regular = try await hash(repo)
        try link(location, target: "first-target"); try await repo.stage([path]); _ = try await repo.commit(message: "change to symlink")
        let first = try await hash(repo)
        try link(location, target: "second-target"); try await repo.stage([path]); _ = try await repo.commit(message: "new link target")
        let second = try await hash(repo)
        _ = try await repo.run(["mv", "--", path, renamed]); _ = try await repo.commit(message: "rename link")
        let head = try await hash(repo), index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.blame(path: renamed)
        XCTAssertEqual(snapshot.contents, Data("second-target".utf8)); XCTAssertEqual(snapshot.lines.map(\.hash), [second]); XCTAssertEqual(snapshot.lines.map(\.filename), [path])
        var options = GitBlameOptions(); options.followRenames = true
        let history = try await repo.blameHistory(snapshot, options: options)
        XCTAssertTrue(history.contains { $0.hash == first }); XCTAssertTrue(history.contains { $0.hash == second })
        let previous = try await repo.blameHistoryParentComparisons(snapshot, revision: second)
        XCTAssertEqual(previous.count, 1); XCTAssertEqual(previous.first?.revision, first); XCTAssertEqual(previous.first?.path, path)
        let prior = try await repo.blame(path: try XCTUnwrap(previous.first?.path), revision: try XCTUnwrap(previous.first?.revision))
        XCTAssertEqual(prior.contents, Data("first-target".utf8)); XCTAssertEqual(prior.lines.map(\.hash), [first])
        let transition = try await repo.blameParentComparisons(revision: first, path: path)
        XCTAssertEqual(transition.first?.revision, regular)
        let oldRegular = try await repo.blame(path: path, revision: regular)
        XCTAssertEqual(oldRegular.contents, Data("regular source\n".utf8))
        let renameChoices = try await repo.blameParentComparisons(revision: head, path: renamed)
        XCTAssertEqual(renameChoices.count, 1); XCTAssertEqual(renameChoices.first?.path, path); XCTAssertEqual(renameChoices.first?.revision, second)
        // A historical blob remains available after its current link is gone,
        // and a Windows/core.symlinks=false text surrogate doesn't retarget it.
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(renamed))
        _ = try await repo.run(["config", "core.symlinks", "false"])
        try Data("uncommitted surrogate".utf8).write(to: repo.root.appendingPathComponent(renamed))
        let reblamed = try await repo.blame(path: renamed, revision: head)
        XCTAssertEqual(reblamed.contents, snapshot.contents); XCTAssertEqual(reblamed.lines.map(\.hash), snapshot.lines.map(\.hash))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(renamed)), Data("uncommitted surrogate".utf8))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), index)
        let after = try await hash(repo); XCTAssertEqual(after, head)
    }

    func testExactUnicodeHistoricalLinkPathsAndAttributedParentChoicesRemainDistinct() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["caf\u{e9}-link", "cafe\u{301}-link"]
        XCTAssertEqual(paths[0], paths[1]); XCTAssertNotEqual(Data(paths[0].utf8), Data(paths[1].utf8))
        for (index, path) in paths.enumerated() {
            let object = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("initial-\(index)".utf8)).text.trimmingCharacters(in: .newlines)
            _ = try await repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "120000," + object + "," + path])
        }
        _ = try await repo.commit(message: "two exact link names"); let first = try await hash(repo)
        for (index, path) in paths.enumerated() {
            let object = try await repo.run(["hash-object", "-w", "--stdin"], input: Data("changed-\(index)".utf8)).text.trimmingCharacters(in: .newlines)
            _ = try await repo.run(["-c", "core.precomposeunicode=false", "update-index", "--cacheinfo", "120000," + object + "," + path])
        }
        _ = try await repo.commit(message: "change both target texts")
        let index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), head = try await hash(repo)
        let a = try await repo.blame(path: paths[0]), b = try await repo.blame(path: paths[1])
        XCTAssertEqual(a.contents, Data("changed-0".utf8)); XCTAssertEqual(b.contents, Data("changed-1".utf8))
        XCTAssertEqual(Data(a.lines[0].filename.utf8), Data(paths[0].utf8)); XCTAssertEqual(Data(b.lines[0].filename.utf8), Data(paths[1].utf8))
        let combined = GitBlameSnapshot(revision: a.revision, path: a.path, contents: a.contents, encoding: a.encoding, lines: a.lines + b.lines)
        let choices = try await repo.blameHistoryParentComparisons(combined, revision: head)
        XCTAssertEqual(choices.count, 2); XCTAssertEqual(Set(choices.map { Data($0.path.utf8) }), Set(paths.map { Data($0.utf8) }))
        for choice in choices {
            XCTAssertEqual(choice.revision, first)
            let prior = try await repo.blame(path: choice.path, revision: choice.revision)
            let expected = Data(choice.path.utf8) == Data(paths[0].utf8) ? "initial-0" : "initial-1"
            XCTAssertEqual(prior.contents, Data(expected.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), index)
    }

    func testFinderOffersBlameForCommittedLinksWithoutFollowingTheirTargets() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = repo.root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("directory content\n".utf8).write(to: directory.appendingPathComponent("file"))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let external = outside.appendingPathComponent("target"), bytes = Data([0, 255, 2, 0])
        try bytes.write(to: external)
        let names = ["directory link", "dangling #?% link", "outside 雪 link", "outside directory link"]
        let targets = ["directory", "missing target", external.path, outside.path]
        let urls = names.map { repo.root.appendingPathComponent($0, isDirectory: false) }
        for (url, target) in zip(urls, targets) { try link(url, target: target) }
        try await repo.stage(names + ["directory/file"]); _ = try await repo.commit(message: "Finder link selections")
        let index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), head = try await hash(repo)
        let snapshot = FinderSnapshot(roots: [repo.root.path], states: GitPathMap<FileState>(uniqueKeysWithValues: urls.map { ($0.path, .normal) }), repositories: [repo.root.path: .init()])
        for (url, target) in zip(urls, targets) {
            let flags = FinderShellRules.flags(paths: [url], snapshot: snapshot)
            XCTAssertTrue(flags.contains(.inGit)); XCTAssertFalse(flags.contains(.folder))
            XCTAssertTrue(FinderShellRules.allows(.blame, flags: flags))
            let encoded = try XCTUnwrap(FinderRequest(action: .blame, paths: [url]).url)
            let decoded = try XCTUnwrap(FinderRequest(url: encoded))
            XCTAssertEqual(decoded.action, .blame); XCTAssertEqual(decoded.paths.count, 1)
            XCTAssertEqual(Data(try XCTUnwrap(decoded.paths.first).path.utf8), Data(url.path.utf8))
            XCTAssertEqual(try linkBytes(url), Data(target.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), index)
        let after = try await hash(repo); XCTAssertEqual(after, head)
    }

    func testParentEscapeAdminGitlinkAndCancellationRefuseWithoutReadingOutside() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = repo.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try link(parent.appendingPathComponent("link"), target: "../readme"); try await repo.stage(["nested/link"]); _ = try await repo.commit(message: "nested link")
        let revision = try await hash(repo)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + revision + ",module"]); _ = try await repo.commit(message: "gitlink")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bytes = Data([0, 255, 0]); try bytes.write(to: outside.appendingPathComponent("link"))
        try FileManager.default.moveItem(at: parent, to: repo.root.appendingPathComponent("retained")); try link(parent, target: outside.path)
        let before = try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), head = try await hash(repo)
        for path in ["nested/link", ".git/config", "../outside/link", outside.path] {
            do { _ = try await repo.blame(path: path, revision: revision); XCTFail("Unsafe lexical parent/path accepted: \(path)") }
            catch is WorkingFileRestoreFailure {}
        }
        do { _ = try await repo.blame(path: "module"); XCTFail("Gitlink accepted as text blob") }
        catch GitBlameFailure.unsupported {}
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.blame(path: "readme", cancellation: token); XCTFail("Canceled blame succeeded") }
        catch is OperationCancellationFailure {}
        do { _ = try await repo.blameParentComparisons(revision: revision, path: "nested/link", cancellation: token); XCTFail("Canceled parent read succeeded") }
        catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("link")), bytes)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")), before)
        let after = try await hash(repo); XCTAssertEqual(after, head)
    }
}
