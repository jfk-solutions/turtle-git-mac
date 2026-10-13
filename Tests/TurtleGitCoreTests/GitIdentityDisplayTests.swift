import XCTest
@testable import TurtleGitCore

final class GitIdentityDisplayTests: XCTestCase {
    func testPrivatePreferenceDefaultsAndRawVersusMappedFormats() {
        let name = "TurtleGit.Identity.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(GitIdentityDisplay(defaults: defaults).useMailmap)
        defaults.set(false, forKey: "UseMailmap")
        let raw = GitIdentityDisplay(defaults: defaults)
        XCTAssertEqual([raw.authorName, raw.authorEmail, raw.committerName, raw.committerEmail], ["%an", "%ae", "%cn", "%ce"])
        defaults.set(true, forKey: "UseMailmap")
        let mapped = GitIdentityDisplay(defaults: defaults)
        XCTAssertEqual([mapped.authorName, mapped.authorEmail, mapped.committerName, mapped.committerEmail], ["%aN", "%aE", "%cN", "%cE"])
    }
    func testDisplayConsumersRespectBothPoliciesAndPreserveRawCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Raw Committer"), ("user.email", "raw-committer@example.invalid"), ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", key, value]) }
        let path = "identity.txt", file = root.appendingPathComponent(path)
        try Data("source\n".utf8).write(to: file); try await repo.stage([path])
        _ = try await repo.run(["commit", "-m", "Identity baseline"], environmentOverrides: ["GIT_AUTHOR_NAME": "Raw Author", "GIT_AUTHOR_EMAIL": "raw-author@example.invalid"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let rawCommit = try await repo.run(["cat-file", "commit", head]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let mapping = Data("Mapped Author <mapped-author@example.invalid> Raw Author <raw-author@example.invalid>\nMapped Committer <mapped-committer@example.invalid> Raw Committer <raw-committer@example.invalid>\n".utf8)
        try mapping.write(to: root.appendingPathComponent(".mailmap"))
        let blame = try await repo.blame(path: path)
        for enabled in [false, true] {
            let author = enabled ? "Mapped Author" : "Raw Author"
            let email = enabled ? "mapped-author@example.invalid" : "raw-author@example.invalid"
            let committer = enabled ? "Mapped Committer" : "Raw Committer"
            var graphOptions = RevisionGraphOptions(); graphOptions.useMailmap = enabled
            let graph = try await repo.revisionGraph(options: graphOptions)
            let node = try XCTUnwrap(graph.nodes.first { $0.hash == head })
            XCTAssertEqual(node.author, author); XCTAssertEqual(node.authorEmail, email); XCTAssertEqual(node.committer, committer)
            var blameOptions = GitBlameOptions(); blameOptions.useMailmap = enabled
            let entries = try await repo.blameHistory(blame, options: blameOptions)
            let entry = try XCTUnwrap(entries.first { $0.hash == head })
            let displayed = blame.applyingDisplayIdentities(entries)
            XCTAssertEqual(displayed.lines.first?.author, author); XCTAssertEqual(displayed.lines.first?.email, email)
            XCTAssertEqual(displayed.contents, blame.contents); XCTAssertEqual(displayed.lines.map(\.sourceBytes), blame.lines.map(\.sourceBytes)); XCTAssertEqual(displayed.lines.map(\.hash), blame.lines.map(\.hash))
            XCTAssertEqual(entry.author, author); XCTAssertEqual(entry.email, email); XCTAssertEqual(entry.committer, committer)
            let containing = try await repo.commitContainingReferences(head, useMailmap: enabled)
            XCTAssertEqual(containing.author, author)
            let comparison = try await repo.revisionComparison(from: .emptyTree, to: .revision(head), useMailmap: enabled)
            XCTAssertEqual(comparison.toDetails?.author, author)
            let utility = try await WorkingCopyRevisionReader.read(path: root, useMailmap: enabled)
            XCTAssertEqual(utility.author, author); XCTAssertEqual(utility.email, email)
            let clipboard = try await repo.commitLogText(revision: head, includePaths: false, useMailmap: enabled)
            XCTAssertTrue(clipboard.contains("Author: \(author) <\(email)>"))
            let references = try await repo.referenceBrowser(useMailmap: enabled)
            XCTAssertTrue(references.references.contains { $0.author == author && $0.committer == committer })
            var historyOptions = HistoryOptions(); historyOptions.useMailmap = enabled
            let history = try await repo.history(options: historyOptions)
            XCTAssertEqual(history.first?.author, author)
        }
        let after = try await repo.run(["cat-file", "commit", head]).stdout
        XCTAssertEqual(after, rawCommit)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: file), Data("source\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".mailmap")), mapping)
    }
}
