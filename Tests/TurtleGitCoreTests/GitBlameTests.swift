import XCTest
@testable import TurtleGitCore

final class GitBlameTests: XCTestCase {
    private let expectedHash = String(repeating: "a", count: 40)
    private func record(hash: String? = nil, header: String = "1 1 1", filename: String = "file.txt", source: String = "source") -> String {
        "\(hash ?? self.expectedHash) \(header)\nauthor Alice\nauthor-mail <alice@example.invalid>\nauthor-time 1000000000\nauthor-tz +0230\nsummary Subject\nboundary\nfilename \(filename)\n\t\(source)\n"
    }
    func testPorcelainMetadataAndQuotedOriginPaths() throws {
        let raw = record(hash: String(repeating: "b", count: 64), filename: "\"old \\351\\233\\252\\n\\t\\\"\\\\.txt\"", source: "\ttext\r")
        let line = try XCTUnwrap(GitBlameParser.parse(Data(raw.utf8)).first)
        XCTAssertEqual(line.hash.count, 64); XCTAssertEqual(line.originalLine, 1); XCTAssertEqual(line.number, 1)
        XCTAssertEqual(line.author, "Alice"); XCTAssertEqual(line.email, "alice@example.invalid")
        XCTAssertEqual(line.date.timeIntervalSince1970, 1000000000); XCTAssertEqual(line.timezone, "+0230")
        XCTAssertEqual(line.summary, "Subject"); XCTAssertTrue(line.boundary)
        XCTAssertEqual(line.filename, "old 雪\n\t\"\\.txt"); XCTAssertEqual(line.source, "\ttext\r")
        XCTAssertTrue(try GitBlameParser.parse(Data()).isEmpty)
        let empty = record(source: "").replacingOccurrences(of: "summary Subject", with: "summary ")
        XCTAssertEqual(try GitBlameParser.parse(Data(empty.utf8)).first?.summary, "")
    }
    func testMalformedAndTruncatedPorcelainIsRejected() throws {
        let valid = record()
        let bad = [
            String(valid.dropLast()), valid.replacingOccurrences(of: "\tsource\n", with: ""),
            record(header: "1 2 1"), record(header: "1 1 0"), record(header: "0 1 1"),
            record(hash: "invalid"), record(filename: "\"bad\\q\""), record(filename: "\"bad\\000\""),
            record(filename: "\"bad\\777\""), record(filename: "\"bad\\3\""), record(filename: ""),
            valid.replacingOccurrences(of: "author-time 1000000000", with: "author-time nan"),
            valid.replacingOccurrences(of: "author-tz +0230", with: "author-tz +2460"),
            valid.replacingOccurrences(of: "author Alice", with: "author Alice\nauthor Duplicate"),
            valid.replacingOccurrences(of: "source", with: "bad\0source")
        ]
        for text in bad { XCTAssertThrowsError(try GitBlameParser.parse(Data(text.utf8)), text.debugDescription) }
        XCTAssertThrowsError(try GitBlameParser.parse(Data([255, 10])))
    }
    func testRenamesAuthorsAndExactSourcePreserveRepositoryState() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "old 雪\n.txt", renamed = ":(glob)* new 雪\n.txt"
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("first\r\n\n\tthird".utf8)
        try bytes.write(to: root.appendingPathComponent(original)); try await repo.stage([original])
        _ = try await repo.run(["commit", "-m", "original"], environmentOverrides: ["GIT_AUTHOR_NAME": "Alice", "GIT_AUTHOR_EMAIL": "alice@example.invalid", "GIT_AUTHOR_DATE": "@1000000000 +0230"])
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["mv", "--", original, renamed])
        let changed = Data([0xef, 0xbb, 0xbf]) + Data("first\r\nchanged\n\tthird".utf8)
        try changed.write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed])
        _ = try await repo.run(["commit", "-m", "rename and edit"], environmentOverrides: ["GIT_AUTHOR_NAME": "Bob", "GIT_AUTHOR_EMAIL": "bob@example.invalid", "GIT_AUTHOR_DATE": "@1000100000 -0500"])
        let second = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("uncommitted replacement\n".utf8).write(to: root.appendingPathComponent(renamed))
        let result = try await repo.blame(path: renamed)
        XCTAssertEqual(result.revision, second); XCTAssertEqual(result.path, renamed); XCTAssertEqual(result.contents, changed)
        XCTAssertEqual(result.lines.map(\.hash), [first, second, first])
        XCTAssertEqual(result.lines.map(\.author), ["Alice", "Bob", "Alice"])
        XCTAssertEqual(result.lines.map(\.filename), [original, renamed, original])
        XCTAssertEqual(result.lines.map(\.originalLine), [1, 2, 3]); XCTAssertEqual(result.lines.map(\.number), [1, 2, 3])
        XCTAssertEqual(result.lines.map(\.source), ["\u{feff}first\r", "changed", "\tthird"])
        XCTAssertEqual(result.lines[0].timezone, "+0230"); XCTAssertEqual(result.lines[1].timezone, "-0500")
        let pinned = try await repo.blame(path: original, revision: first)
        XCTAssertEqual(pinned.contents, bytes); XCTAssertEqual(pinned.lines[1].source, "")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)), Data("uncommitted replacement\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(after, second)
    }
    func testWhitespaceOptionAndEmptyFile() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).replacingOccurrences(of: "line 2\n", with: "line   2  \n")
        try Data(text.utf8).write(to: root.appendingPathComponent(path)); try Data().write(to: root.appendingPathComponent("empty"))
        try await repo.stage([path, "empty"]); _ = try await repo.commit(message: "whitespace")
        let ordinary = try await repo.blame(path: path)
        XCTAssertNotEqual(ordinary.lines[1].hash, first)
        var options = GitBlameOptions(); options.ignoreWhitespace = true
        let ignored = try await repo.blame(path: path, options: options)
        XCTAssertEqual(ignored.lines[1].hash, first); XCTAssertEqual(ignored.lines[1].source, "line   2  ")
        let empty = try await repo.blame(path: "empty"); XCTAssertTrue(empty.lines.isEmpty); XCTAssertTrue(empty.contents.isEmpty)
    }
    func testMovedAndCopiedLineOptionsKeepOriginRevisionAndPath() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "alpha original long source statement with enough characters for move detection"
        let b = "bravo original long source statement with enough characters for copy detection"
        let c = "charlie original long source statement with enough characters for move detection"
        try Data("\(a)\n\(b)\n\(c)\n".utf8).write(to: root.appendingPathComponent("source"))
        try await repo.stage(["source"]); _ = try await repo.commit(message: "origin")
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("\(a)\n\(c)\n\(b)\nnew marker\n".utf8).write(to: root.appendingPathComponent("source"))
        try Data("\(b)\nnew destination\n".utf8).write(to: root.appendingPathComponent("copy"))
        try await repo.stage(["source", "copy"]); _ = try await repo.commit(message: "move and copy")
        var options = GitBlameOptions(); options.detectMoved = true
        let moved = try await repo.blame(path: "source", options: options)
        XCTAssertEqual(moved.lines.prefix(3).map(\.hash), [first, first, first])
        XCTAssertEqual(moved.lines.prefix(3).map(\.originalLine), [1, 3, 2])
        options.detectCopied = true
        let copied = try await repo.blame(path: "copy", options: options)
        XCTAssertEqual(copied.lines.first?.hash, first); XCTAssertEqual(copied.lines.first?.filename, "source")
        XCTAssertEqual(copied.lines.first?.originalLine, 2)
        let ordinary = try await repo.blame(path: "copy")
        XCTAssertNotEqual(ordinary.lines.first?.hash, first); XCTAssertEqual(ordinary.lines.first?.filename, "copy")
    }
    func testParentComparisonKeepsRenamePathsPinnedAndSkipsFileBirth() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let born = try await repo.blameParentComparisons(revision: first, path: original)
        XCTAssertTrue(born.isEmpty)
        let old = try Data(contentsOf: root.appendingPathComponent(original)), renamed = ":(glob)* renamed 雪\n.txt"
        _ = try await repo.run(["mv", "--", original, renamed])
        let new = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "line 2\n", with: "changed\n").utf8)
        try new.write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed]); _ = try await repo.commit(message: "rename and change")
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("later working\n".utf8).write(to: root.appendingPathComponent(renamed))
        let parents = try await repo.blameParentComparisons(revision: hash, path: renamed)
        let parent = try XCTUnwrap(parents.first); XCTAssertEqual(parents.count, 1)
        XCTAssertEqual(parent.parentNumber, 1); XCTAssertEqual(parent.revision, first); XCTAssertEqual(parent.path, original)
        XCTAssertEqual(parent.comparison.files.map(\.path), [renamed]); XCTAssertEqual(parent.comparison.files.first?.oldPath, original)
        let document = try await repo.comparisonFile(parent.comparison, path: renamed)
        XCTAssertEqual(document.base.bytes, old); XCTAssertEqual(document.destination.bytes, new)
        XCTAssertEqual(document.base.path, original); XCTAssertEqual(document.destination.path, renamed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)), Data("later working\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, hash)
        do { _ = try await repo.blameParentComparisons(revision: hash, path: "../outside"); XCTFail() } catch {}
    }
    func testMergeOriginOffersEachRelevantParent() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        _ = try await repo.run(["checkout", "-b", "side"])
        try Data(original.replacingOccurrences(of: "line 2\n", with: "side change\n").utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "side")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "main"])
        try Data(original.replacingOccurrences(of: "line 2\n", with: "main change\n").utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "main")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        do { _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge"]); XCTFail("Must conflict") } catch {}
        try Data(original.replacingOccurrences(of: "line 2\n", with: "resolved\n").utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "resolve both parents")
        let annotations = try await repo.blame(path: path), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        XCTAssertEqual(annotations.lines[1].hash, annotations.revision)
        let parents = try await repo.blameParentComparisons(revision: annotations.lines[1].hash, path: annotations.lines[1].filename)
        XCTAssertEqual(parents.map(\.revision), [main, side]); XCTAssertEqual(parents.map(\.parentNumber), [1, 2])
        let logText = try await repo.commitLogText(revision: annotations.revision)
        XCTAssertEqual(logText.components(separatedBy: "Modified: \(path)\n").count - 1, 2)
        for (choice, expected) in zip(parents, ["main change", "side change"]) {
            let document = try await repo.comparisonFile(choice.comparison, path: path)
            XCTAssertTrue(document.base.text?.contains(expected) == true); XCTAssertTrue(document.destination.text?.contains("resolved") == true)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testAddedFileWithExistingCommitParentHasNoPreviousFile() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first version\n".utf8).write(to: root.appendingPathComponent("new")); try await repo.stage(["new"]); _ = try await repo.commit(message: "birth")
        let parents = try await repo.blameParentComparisons(revision: "HEAD", path: "new"); XCTAssertTrue(parents.isEmpty)
    }
    func testFullLogCopyIncludesBodyNotesAnnotatedTagAndRenamedPath() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = "renamed 雪.txt"
        _ = try await repo.run(["mv", "--", path, renamed])
        _ = try await repo.commit(message: "Rename subject\n\nDetailed body\n\nSigned-off-by: Test <test@example.invalid>")
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["notes", "add", "-m", "Review note", hash])
        _ = try await repo.run(["tag", "-a", "release-copy", "-m", "Annotated release body", hash])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("later replacement\n".utf8).write(to: root.appendingPathComponent(renamed))
        let text = try await repo.commitLogText(revision: hash)
        XCTAssertTrue(text.contains("Revision: \(hash)\nAuthor:"))
        XCTAssertTrue(text.contains("Message:\nRename subject\n\nDetailed body\n\nSigned-off-by:"))
        XCTAssertTrue(text.contains("Notes:\nReview note"))
        XCTAssertTrue(text.contains("Tag info: refs/tags/release-copy")); XCTAssertTrue(text.contains("Annotated release body"))
        XCTAssertTrue(text.contains("Renamed: \(renamed) (from \(path))"))
        let withoutPaths = try await repo.commitLogText(revision: hash, includePaths: false)
        XCTAssertFalse(withoutPaths.contains("Renamed: "))
        XCTAssertTrue(withoutPaths.contains("Detailed body")); XCTAssertTrue(withoutPaths.contains("Review note"))
        XCTAssertTrue(withoutPaths.contains("Annotated release body"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)), Data("later replacement\n".utf8))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, hash)
        do { _ = try await repo.commitLogText(revision: "--all"); XCTFail() } catch {}
    }
    func testUnsupportedAndUnsafeFilesFail() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try Data([255, 10]).write(to: root.appendingPathComponent("encoding"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "binary")
        try await repo.stage(["binary", "encoding", "link"]); _ = try await repo.commit(message: "unsupported")
        for path in ["binary", "encoding", "link", "missing", "../outside"] {
            do { _ = try await repo.blame(path: path); XCTFail("Must reject \(path)") } catch {}
        }
    }
}
