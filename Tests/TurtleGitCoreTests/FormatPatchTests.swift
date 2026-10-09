import XCTest
@testable import TurtleGitCore

private final class PatchOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; bytes.append(chunk.data) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

final class FormatPatchTests: XCTestCase {
    func testLogSelectionPresetsRespectRowOrderContinuityAndHiddenRows() throws {
        let rows = ["newest", "middle", "older", "oldest"]
        let single = try XCTUnwrap(FormatPatchPreset.logSelection(orderedHashes: rows, selected: ["middle"]))
        XCTAssertEqual(single.selection, .since("middle")); XCTAssertEqual(single.from, "middle~1"); XCTAssertEqual(single.to, "middle")
        XCTAssertEqual(FormatPatchPreset.logSelection(orderedHashes: rows, selected: ["newest", "oldest"])?.selection, .range(from: "oldest~1", to: "newest"))
        let three: Set<String> = ["newest", "middle", "older"]
        XCTAssertEqual(FormatPatchPreset.logSelection(orderedHashes: rows, selected: three)?.selection, .range(from: "older~1", to: "newest"))
        XCTAssertNil(FormatPatchPreset.logSelection(orderedHashes: rows, selected: ["newest", "middle", "oldest"]))
        XCTAssertNil(FormatPatchPreset.logSelection(orderedHashes: rows, selected: three, hasHiddenRows: true))
        XCTAssertNotNil(FormatPatchPreset.logSelection(orderedHashes: rows, selected: ["newest", "oldest"], hasHiddenRows: true))
        XCTAssertEqual(FormatPatchPreset.logSelection(orderedHashes: rows.reversed(), selected: three, oldestFirst: true)?.selection, .range(from: "older~1", to: "newest"))
        XCTAssertNil(FormatPatchPreset.logSelection(orderedHashes: rows, selected: []))
        XCTAssertNil(FormatPatchPreset.logSelection(orderedHashes: rows, selected: ["missing"]))
        XCTAssertNil(FormatPatchPreset(startRevision: nil, endRevision: "HEAD"))
    }

    func testLogPresetsExportSourceSingleAndInclusiveMultipleCommitRanges() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var hashes: [String] = []
        for number in 1...3 {
            try Data("change \(number)\n".utf8).write(to: root.appendingPathComponent(path))
            try await repo.stage([path]); _ = try await repo.commit(message: "Change \(number)")
            hashes.insert(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), at: 0)
        }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for (name, selected, subjects) in [
            ("single", Set([hashes[1]]), ["Change 3"]),
            ("two", Set([hashes[0], hashes[1]]), ["Change 2", "Change 3"]),
            ("continuous", Set(hashes), ["Change 1", "Change 2", "Change 3"])
        ] {
            let preset = try XCTUnwrap(FormatPatchPreset.logSelection(orderedHashes: hashes, selected: selected))
            let output = root.appendingPathComponent(name)
            _ = try await repo.formatPatch(selection: preset.selection, to: output)
            let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            XCTAssertEqual(files.count, subjects.count)
            for (file, subject) in zip(files, subjects) {
                let patch = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(patch.components(separatedBy: "\n").contains { $0.hasPrefix("Subject: [PATCH") && $0.hasSuffix(subject) })
            }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, hashes[0])
    }
    func testAllModesAndBinaryMailPatchRoundTripPreserveRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("first change\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "First patch")
        let binary = Data([0, 255, 13, 10, 1, 2, 3])
        try binary.write(to: root.appendingPathComponent("binary.dat"))
        try await repo.stage(["binary.dat"]); _ = try await repo.commit(message: "Binary patch")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("unstaged\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var since: URL?
        for (name, selection, count) in [("since 雪", FormatPatchSelection.since(base), 2), ("number", .number(1), 1), ("range", .range(from: base, to: "HEAD"), 2), ("empty", .range(from: "HEAD", to: "HEAD"), 0)] {
            let folder = root.appendingPathComponent(name)
            let capture = PatchOutputCapture()
            let result = try await repo.formatPatch(selection: selection, to: folder, onOutput: { capture.append($0) })
            XCTAssertEqual(capture.text, result.text, "Only patch filenames, not metadata probes, are streamed")
            XCTAssertFalse(capture.text.contains("diff --git"), "Patch payload stays in the generated files")
            XCTAssertEqual(result.exitCode, 0)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            XCTAssertEqual(files.count, count)
            if name.hasPrefix("since") { since = folder }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("unstaged\n".utf8))
        let receiver = root.appendingPathComponent("receiver")
        _ = try await repo.run(["clone", "--no-local", root.path, receiver.path])
        let target = GitRepository(root: receiver)
        _ = try await target.run(["config", "user.name", "Receiver"])
        _ = try await target.run(["config", "user.email", "receiver@example.invalid"])
        _ = try await target.run(["config", "commit.gpgsign", "false"])
        _ = try await target.run(["reset", "--hard", base])
        let patches = try FileManager.default.contentsOfDirectory(at: XCTUnwrap(since), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        let mail = try String(contentsOf: patches[1], encoding: .utf8)
        XCTAssertTrue(mail.contains("Subject: [PATCH 2/2] Binary patch"))
        XCTAssertTrue(mail.contains("GIT binary patch"))
        _ = try await target.run(["am"] + patches.map(\.path))
        XCTAssertEqual(try Data(contentsOf: receiver.appendingPathComponent("binary.dat")), binary)
        XCTAssertEqual(try Data(contentsOf: receiver.appendingPathComponent(path)), Data("first change\n".utf8))
        let tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text
        let restoredTree = try await target.run(["rev-parse", "HEAD^{tree}"]).text
        XCTAssertEqual(tree, restoredTree)
    }

    func testNoPrefixAndExistingPatchReplacement() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("change\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "Patch")
        let folder = root.appendingPathComponent("out")
        _ = try await repo.formatPatch(selection: .number(1), to: folder)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let normal = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(normal.contains("diff --git \"a/file"))
        try Data("old export".utf8).write(to: file)
        _ = try await repo.formatPatch(selection: .number(1), to: folder, noPrefix: true)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("diff --git \"file")); XCTAssertFalse(text.contains("diff --git \"a/file"))
        XCTAssertTrue(text.contains("Subject: [PATCH] Patch"))
    }

    func testInvalidSelectionsAndMetadataDestinationsFailBeforeExport() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out")
        for selection in [FormatPatchSelection.number(0), .number(-1), .number(Int(Int32.max) + 1), .since(""), .since("HEAD\0"), .range(from: "HEAD", to: "")] {
            do { _ = try await repo.formatPatch(selection: selection, to: output); XCTFail("Invalid selection accepted") } catch FormatPatchFailure.selection {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let alias = root.appendingPathComponent("admin-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent(".git"))
        for folder in [root.appendingPathComponent(".git/exports"), alias.appendingPathComponent("exports")] {
            do { _ = try await repo.formatPatch(selection: .number(1), to: folder); XCTFail("Metadata output accepted") } catch FormatPatchFailure.outputDirectory {}
        }
        do { _ = try await repo.formatPatch(selection: .since("--output=/tmp/unwanted"), to: output); XCTFail("Option was treated as revision") } catch is GitFailure {}
    }

    func testBareRepositoryExportAndAdminGuard() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bare.path])
        let repository = GitRepository(root: bare)
        let folder = root.appendingPathComponent("bare-output")
        _ = try await repository.formatPatch(selection: .number(1), to: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        do { _ = try await repository.formatPatch(selection: .number(1), to: bare.appendingPathComponent("exports")); XCTFail("Bare metadata output accepted") } catch FormatPatchFailure.outputDirectory {}
    }

    func testFetchHeadUsesOnlyMergeRecordAndRejectsAmbiguity() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("change\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "After fetch base")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let fetch = root.appendingPathComponent(".git/FETCH_HEAD")
        try Data((head + "\tnot-for-merge\tignored branch\n" + base + "\t\tselected branch\n").utf8).write(to: fetch)
        let folder = root.appendingPathComponent("fetch-export")
        _ = try await repo.formatPatch(selection: .since("FETCH_HEAD"), to: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        for content in [head + "\tnot-for-merge\tonly excluded\n", base + "\t\tfirst\n" + head + "\t\tsecond\n"] {
            try Data(content.utf8).write(to: fetch)
            do { _ = try await repo.formatPatch(selection: .since("FETCH_HEAD"), to: folder); XCTFail("Ambiguous FETCH_HEAD accepted") } catch FormatPatchFailure.selection {}
        }
    }
}
