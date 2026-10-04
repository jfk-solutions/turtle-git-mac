import XCTest
@testable import TurtleGitCore

final class GitBlameTests: XCTestCase {
    func testFirstParentAttributesSideBranchLinesToIntegrationCommit() async throws {
        let (root, repo, fixturePath) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ":(glob)* first parent 雪\n.swift"
        let base = "main base\nunchanged spacer\nside base\n"
        try Data(base.utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "annotation base")
        let origin = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let branch = try await repo.run(["branch", "--show-current"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "annotation-side"])
        try Data(base.replacingOccurrences(of: "side base", with: "side change").utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "side annotation")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", branch])
        try Data(base.replacingOccurrences(of: "main base", with: "main change").utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "main annotation")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["merge", "--no-ff", "annotation-side", "-m", "integrate side annotation"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let contents = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("staged replacement\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("working replacement\n".utf8).write(to: root.appendingPathComponent(path))
        let normal = try await repo.blame(path: path)
        XCTAssertEqual(normal.lines.map(\.hash), [main, origin, side])
        var options = GitBlameOptions(); options.onlyFirstParent = true
        let rootHash = try await repo.run(["rev-list", "--max-parents=0", head]).text.trimmingCharacters(in: .newlines)
        let rootOnly = try await repo.blame(path: fixturePath, revision: rootHash, options: options)
        XCTAssertTrue(rootOnly.lines.allSatisfy { $0.hash == rootHash })
        let singleParent = try await repo.blame(path: path, revision: main, options: options)
        XCTAssertEqual(singleParent.lines.map(\.hash), [main, origin, origin])
        let first = try await repo.blame(path: path, options: options)
        XCTAssertEqual(first.lines.map(\.hash), [main, origin, head])
        XCTAssertEqual(first.contents, contents); XCTAssertEqual(first.lines.map(\.sourceBytes), normal.lines.map(\.sourceBytes))
        // Reproduce upstream's rev-list -> ancestry-file construction and compare
        // its annotations with Git's native first-parent traversal.
        let ancestors = try await repo.run(["rev-list", "--first-parent", "--end-of-options", head, "--"]).text.split(separator: "\n").map(String.init)
        let ancestry = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ancestry) }
        var previous = "", chain = ""
        for hash in ancestors { chain += previous + " " + hash + "\n"; previous = hash }
        try Data(chain.utf8).write(to: ancestry)
        let raw = try await repo.run(["-c", "blame.blankBoundary=false", "blame", "--line-porcelain", "--no-textconv", "-S", ancestry.path, head, "--", path]).stdout
        let upstream = try GitBlameParser.parse(raw)
        XCTAssertEqual(first.lines.map(\.hash), upstream.map(\.hash))
        XCTAssertEqual(first.lines.map(\.originalLine), upstream.map(\.originalLine))
        XCTAssertEqual(first.lines.map(\.filename), upstream.map(\.filename))
        options.detectionMode = .existingFiles; options.ignoreWhitespace = true
        let combined = try await repo.blame(path: path, options: options)
        XCTAssertEqual(combined.lines.map(\.hash), first.lines.map(\.hash))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("working replacement\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(after, head)
    }
    func testCopyDetectionScopesAndCharacterThresholds() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstLine = "alpha original statement with many alphanumeric characters for attribution"
        let laterLine = "bravo separate statement with many alphanumeric characters for attribution"
        let shortLine = "shortvalue"
        let source = "donor 雪\n.txt", target = ":(glob)* copy 雪\n.txt"
        try Data("\(firstLine)\n\(laterLine)\n\(shortLine)\n".utf8).write(to: root.appendingPathComponent(source))
        try await repo.stage([source]); _ = try await repo.commit(message: "donor origin")
        let origin = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("\(firstLine)\nnew destination marker\n".utf8).write(to: root.appendingPathComponent(target))
        try await repo.stage([target]); _ = try await repo.commit(message: "copy from unchanged donor at creation")
        let creation = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        var options = GitBlameOptions(); options.detectionMode = .modifiedFiles
        let modified = try await repo.blame(path: target, options: options)
        XCTAssertEqual(modified.lines[0].hash, creation)
        options.detectionMode = .fileCreation
        let atCreation = try await repo.blame(path: target, options: options)
        XCTAssertEqual(atCreation.lines[0].hash, origin)
        XCTAssertEqual(atCreation.lines[0].filename, source)
        let copiedHistory = try await repo.blameHistory(atCreation, options: options)
        XCTAssertEqual(Set(copiedHistory.map(\.hash)), [origin, creation])
        try Data("\(firstLine)\nnew destination marker\n\(laterLine)\n".utf8).write(to: root.appendingPathComponent(target))
        let shortTarget = "short-copy.txt"
        try Data("\(shortLine)\nunique destination marker\n".utf8).write(to: root.appendingPathComponent(shortTarget))
        try await repo.stage([target, shortTarget]); _ = try await repo.commit(message: "later copies from unchanged donor")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let bytes = try Data(contentsOf: root.appendingPathComponent(target))
        try Data("uncommitted replacement\n".utf8).write(to: root.appendingPathComponent(target))
        let creationOnly = try await repo.blame(path: target, options: options)
        XCTAssertEqual(creationOnly.lines[2].hash, head)
        options.detectionMode = .existingFiles
        let all = try await repo.blame(path: target, options: options)
        XCTAssertEqual(all.lines[2].hash, origin); XCTAssertEqual(all.lines[2].originalLine, 2)
        let existingHistory = try await repo.blameHistory(all, options: options)
        XCTAssertEqual(Set(existingHistory.map(\.hash)), Set(all.lines.map(\.hash)))
        XCTAssertTrue(existingHistory.contains { $0.hash == origin })
        let shortDefault = try await repo.blame(path: shortTarget, options: options)
        XCTAssertEqual(shortDefault.lines[0].hash, head)
        options.betweenFileCharacters = 1
        let low = try await repo.blame(path: shortTarget, options: options)
        XCTAssertEqual(low.lines[0].hash, origin); XCTAssertEqual(low.lines[0].originalLine, 3)
        options.betweenFileCharacters = 1000
        let high = try await repo.blame(path: target, options: options)
        XCTAssertEqual(high.lines[0].hash, creation); XCTAssertEqual(high.lines[2].hash, head)
        XCTAssertEqual(high.contents, bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(target)), Data("uncommitted replacement\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(after, head)
    }
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
        // Keep similarity well above the rename threshold on older Apple Git too.
        // A three-line, 17-byte file is an add/delete on Git 2.39.5 but a rename
        // on Git 2.50.1; this test exercises attribution after a detected rename.
        let firstLine = "first " + String(repeating: "unchanged source ", count: 12)
        let thirdLine = "\tthird " + String(repeating: "preserved final line ", count: 12)
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("\(firstLine)\r\n\n\(thirdLine)".utf8)
        try bytes.write(to: root.appendingPathComponent(original)); try await repo.stage([original])
        _ = try await repo.run(["commit", "-m", "original"], environmentOverrides: ["GIT_AUTHOR_NAME": "Alice", "GIT_AUTHOR_EMAIL": "alice@example.invalid", "GIT_AUTHOR_DATE": "@1000000000 +0230"])
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["mv", "--", original, renamed])
        let changed = Data([0xef, 0xbb, 0xbf]) + Data("\(firstLine)\r\nchanged\n\(thirdLine)".utf8)
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
        XCTAssertEqual(result.lines.map(\.source), ["\u{feff}" + firstLine + "\r", "changed", thirdLine])
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
        var options = GitBlameOptions(); options.detectionMode = .withinFile
        let moved = try await repo.blame(path: "source", options: options)
        XCTAssertEqual(moved.lines.prefix(3).map(\.hash), [first, first, first])
        XCTAssertEqual(moved.lines.prefix(3).map(\.originalLine), [1, 3, 2])
        options.withinFileCharacters = 1000
        let highThreshold = try await repo.blame(path: "source", options: options)
        XCTAssertNotEqual(highThreshold.lines[2].hash, first)
        options.withinFileCharacters = 1
        let lowThreshold = try await repo.blame(path: "source", options: options)
        XCTAssertEqual(lowThreshold.lines[2].hash, first)
        options.detectionMode = .modifiedFiles
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
    func testUTF16ByteFramingBOMBlankLinesAndExactPinnedContent() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (encoding, detected, bom) in [(String.Encoding.utf16LittleEndian, GitBlameEncoding.utf16LE, [UInt8(255), 254]), (.utf16BigEndian, .utf16BE, [254, 255])] {
            for hasBOM in [false, true] {
                for ending in ["", "\n", "\r\n", "\n\n"] {
                    let path = "source-\(detected)-\(hasBOM)-\(ending.utf8.count).txt"
                    let text = "first\nsecond 雪 🐢" + ending
                    let bytes = (hasBOM ? Data(bom) : Data()) + (try XCTUnwrap(text.data(using: encoding)))
                    try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "encoded origin")
                    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
                    try Data("later working content\n".utf8).write(to: root.appendingPathComponent(path))
                    let snapshot = try await repo.blame(path: path)
                    XCTAssertEqual(snapshot.encoding, detected); XCTAssertEqual(snapshot.contents, bytes)
                    let expected = ["first", "second 雪 🐢" + (ending == "\r\n" ? "\r" : "")] + (ending == "\n\n" ? [""] : []) + (detected == .utf16LE && !ending.isEmpty ? [""] : [])
                    XCTAssertEqual(snapshot.lines.map(\.source), expected, path)
                    var raw = bytes.split(separator: UInt8(10), omittingEmptySubsequences: false).map { Data($0) }
                    if bytes.last == 10 { raw.removeLast() }
                    XCTAssertEqual(snapshot.lines.map(\.sourceBytes), raw)
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("later working content\n".utf8))
                    let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, snapshot.revision)
                }
            }
            let path = "bom-only-\(detected)"
            try Data(bom).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "BOM only")
            let empty = try await repo.blame(path: path); XCTAssertEqual(empty.lines.map(\.source), [""])
        }
    }
    func testUTF16AttributionAndMalformedEncodingRejection() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "encoded.txt", bom = Data([0xff, 0xfe])
        try (bom + XCTUnwrap("first\nold\n".data(using: .utf16LittleEndian))).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "first encoded")
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try (bom + XCTUnwrap("first\nnew 雪\n".data(using: .utf16LittleEndian))).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "encoded change")
        let snapshot = try await repo.blame(path: path)
        XCTAssertEqual(snapshot.lines[0].hash, first); XCTAssertEqual(snapshot.lines[1].hash, snapshot.revision)
        XCTAssertEqual(snapshot.lines[1].source, "new 雪")
        for bytes in [Data([255,254,65]), Data([255,254,0,216]), Data([255,254,0,220]), Data([255,254,0,0]), Data([255,254,10,1]), Data([0,1,0,2])] {
            XCTAssertThrowsError(try GitBlameEncoding.detect(bytes))
        }
    }
    func testExplicitLegacyCodePagesPreserveBytesAndUTF8Metadata() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (page, text) in [(UInt32(1252), "Preis € – café\r\nzweite Zeile\r\n"), (850, "dsöd\n\n"), (932, "日本語\n東京\n")] {
            let encoding = try XCTUnwrap(GitBlameEncoding.available.first { $0.windowsCodePage == page })
            let bytes = try XCTUnwrap(text.data(using: String.Encoding(rawValue: encoding.id)))
            let path = "page-\(page).txt"
            try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path])
            _ = try await repo.run(["commit", "-m", "Legacy encoding"], environmentOverrides: ["GIT_AUTHOR_NAME": "Jörg 雪", "GIT_AUTHOR_EMAIL": "encoding@example.invalid"])
            let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            try Data("uncommitted UTF-8 replacement\n".utf8).write(to: root.appendingPathComponent(path))
            var options = GitBlameOptions(); options.encoding = encoding
            let snapshot = try await repo.blame(path: path, options: options)
            XCTAssertEqual(snapshot.contents, bytes); XCTAssertEqual(snapshot.encoding, encoding)
            XCTAssertEqual(snapshot.lines.map(\.source), Array(text.components(separatedBy: "\n").dropLast()))
            XCTAssertTrue(snapshot.lines.allSatisfy { $0.author == "Jörg 雪" && $0.email == "encoding@example.invalid" })
            XCTAssertEqual(snapshot.lines.map(\.sourceBytes), bytes.split(separator: UInt8(10), omittingEmptySubsequences: false).dropLast().map { Data($0) })
            options.encoding = .utf8
            do { _ = try await repo.blame(path: path, options: options); XCTFail("Wrong encoding accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("uncommitted UTF-8 replacement\n".utf8))
            let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, snapshot.revision)
        }
    }
    func testExplicitUTF16OverridesAmbiguousAutomaticDetection() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try XCTUnwrap("日本語\n".data(using: .utf16LittleEndian)), path = "ambiguous.txt"
        try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "ambiguous UTF-16")
        do { _ = try await repo.blame(path: path); XCTFail("Should require a choice") } catch {}
        var options = GitBlameOptions(); options.encoding = .utf16LE
        let snapshot = try await repo.blame(path: path, options: options)
        XCTAssertEqual(snapshot.lines.map(\.source), ["日本語", ""]); XCTAssertEqual(snapshot.contents, bytes)
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
    func testCompleteAndOriginHistoriesFollowLiteralRenamesWithoutMutations() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let initial = try Data(contentsOf: root.appendingPathComponent(original))
        let text = String(decoding: initial, as: UTF8.self).replacingOccurrences(of: "line 2\n", with: "temporary line 2\n")
        try Data(text.utf8).write(to: root.appendingPathComponent(original)); try await repo.stage([original]); _ = try await repo.commit(message: "temporary change")
        let temporary = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try initial.write(to: root.appendingPathComponent(original)); try await repo.stage([original]); _ = try await repo.commit(message: "restore line\n\nBody 雪 🐢")
        let restored = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let renamed = ":(glob)* renamed 雪\n.txt"
        _ = try await repo.run(["mv", "--", original, renamed]); _ = try await repo.commit(message: "rename")
        let rename = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let snapshot = try await repo.blame(path: renamed)
        try Data("staged replacement\n".utf8).write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed])
        try Data("working replacement\n".utf8).write(to: root.appendingPathComponent(renamed))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var options = GitBlameOptions()
        let currentName = try await repo.blameHistory(snapshot, options: options)
        XCTAssertEqual(currentName.map(\.hash), [rename])
        options.followRenames = true
        let full = try await repo.blameHistory(snapshot, options: options)
        XCTAssertEqual(full.map(\.hash), [rename, restored, temporary, base])
        XCTAssertTrue(full.first(where: { $0.hash == restored })?.message.contains("Body 雪 🐢") == true)
        options.showCompleteLog = false
        let origins = try await repo.blameHistory(snapshot, options: options)
        XCTAssertEqual(Set(origins.map(\.hash)), Set(snapshot.lines.map(\.hash)))
        XCTAssertEqual(Set(origins.map(\.hash)), [base, restored]); XCTAssertFalse(origins.contains { $0.hash == temporary || $0.hash == rename })
        for mode in GitBlameDetectionMode.allCases where mode.betweenFiles {
            options.showCompleteLog = true; options.detectionMode = mode
            let gated = try await repo.blameHistory(snapshot, options: options)
            XCTAssertEqual(Set(gated.map(\.hash)), Set(origins.map(\.hash)))
        }
        options.detectionMode = .disabled; options.onlyFirstParent = true
        let firstParentGated = try await repo.blameHistory(snapshot, options: options)
        XCTAssertEqual(Set(firstParentGated.map(\.hash)), Set(origins.map(\.hash)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)), Data("working replacement\n".utf8))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, rename)
        XCTAssertEqual(snapshot.contents, initial)
    }
    func testEmptyBlameOriginHistoryAndLogSettingsDependencies() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("empty")); try await repo.stage(["empty"]); _ = try await repo.commit(message: "empty")
        let snapshot = try await repo.blame(path: "empty")
        var options = GitBlameOptions()
        let complete = try await repo.blameHistory(snapshot, options: options); XCTAssertEqual(complete.count, 1)
        options.showCompleteLog = false
        let origins = try await repo.blameHistory(snapshot, options: options); XCTAssertTrue(origins.isEmpty)
        for mode in GitBlameDetectionMode.allCases {
            options = GitBlameOptions(); options.detectionMode = mode; options.followRenames = true
            XCTAssertEqual(options.canShowCompleteLog, !mode.betweenFiles)
            options.normalizeLogSettings()
            XCTAssertEqual(options.showCompleteLog, !mode.betweenFiles); XCTAssertEqual(options.followRenames, !mode.betweenFiles)
            options.onlyFirstParent = true; options.normalizeLogSettings()
            XCTAssertFalse(options.showCompleteLog); XCTAssertFalse(options.followRenames)
        }
        options = GitBlameOptions(); options.showCompleteLog = false; options.followRenames = true; options.normalizeLogSettings()
        XCTAssertFalse(options.followRenames)
    }

}
