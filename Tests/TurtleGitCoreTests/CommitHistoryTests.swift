import XCTest
@testable import TurtleGitCore

final class CommitHistoryTests: XCTestCase {
    func testUnifiedDiffBytesRemainApplicableForNonUTF8Text() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "raw.txt", before = Data([0xff, 0x0a]), after = Data([0xfe, 0x0a])
        try before.write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "non-UTF8 base")
        try after.write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "non-UTF8 change")
        let history = try await repo.history(), entry = try XCTUnwrap(history.first)
        let files = try await repo.files(in: entry)
        let bytes = try await repo.revisionDiffData(entry)
        let selected = try await repo.revisionFileDiffData(entry, files: files + files)
        XCTAssertEqual(bytes, selected)
        XCTAssertNotNil(bytes.range(of: Data([0x2d, 0xff, 0x0a])))
        XCTAssertNotNil(bytes.range(of: Data([0x2b, 0xfe, 0x0a])))
        let preview = try UnifiedDiffPreview.create(selected)
        defer { preview.discard() }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.run(["apply", "--reverse", "--check", "--", preview.file.path])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try before.write(to: root.appendingPathComponent(path))
        let working = try await repo.revisionDiffData(entry, path: path, workingTree: true)
        XCTAssertNotNil(working.range(of: Data([0x2b, 0xff, 0x0a])))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testSelectedUnifiedDiffKeepsOrderRootRenameAndLiteralScopeWithoutMutations() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialHistory = try await repo.history()
        let initial = try XCTUnwrap(initialHistory.first)
        let initialFiles = try await repo.files(in: initial)
        let rootPatch = try await repo.revisionFileDiff(initial, files: initialFiles)
        XCTAssertTrue(rootPatch.contains("new file mode"))
        let literal = ":(glob)* 雪\n.txt", other = "other.txt", renamed = "renamed.txt"
        try Data("literal initial\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data("other initial\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([literal, other]); _ = try await repo.commit(message: "more paths")
        _ = try await repo.run(["mv", "--", path, renamed])
        try Data("literal selected\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data("UNSELECTED CHANGE\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([literal, other]); _ = try await repo.commit(message: "rename and modifications")
        let history = try await repo.history(), selected = try XCTUnwrap(history.first)
        let files = try await repo.files(in: selected)
        let rename = try XCTUnwrap(files.first { $0.path == renamed })
        let unusual = try XCTUnwrap(files.first { $0.path == literal })
        try Data("later staged\n".utf8).write(to: root.appendingPathComponent(literal)); try await repo.stage([literal])
        try Data("later working\n".utf8).write(to: root.appendingPathComponent(literal))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let patch = try await repo.revisionFileDiff(selected, files: [unusual, rename, unusual])
        XCTAssertTrue(patch.contains("+literal selected")); XCTAssertFalse(patch.contains("UNSELECTED CHANGE"))
        XCTAssertFalse(patch.contains("later staged")); XCTAssertFalse(patch.contains("later working"))
        XCTAssertEqual(rename.oldPath, path)
        XCTAssertTrue(patch.contains("rename from ")); XCTAssertTrue(patch.contains("rename to " + renamed))
        let first = try XCTUnwrap(patch.range(of: "+literal selected")), second = try XCTUnwrap(patch.range(of: "rename to " + renamed))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertEqual(patch.components(separatedBy: "+literal selected").count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data("later working\n".utf8))
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, finalHead)
        do { _ = try await repo.revisionFileDiff(selected, files: []); XCTFail("Empty selection accepted") } catch RevisionComparisonFailure.selection {}
    }
    private func entry(_ hash: String, _ parents: [String]) -> LogEntry {
        LogEntry(hash: hash, author: "A", date: "", subject: hash, parents: parents)
    }
    func testMergeAndBranchPointEdgesStayContinuous() {
        // Merge M has parents A and B, which share base R.
        let rows = CommitGraph.layout([entry("M", ["A", "B"]), entry("A", ["R"]), entry("B", ["R"]), entry("R", [])])
        XCTAssertTrue(rows[0].junction)
        XCTAssertTrue(rows[3].junction)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 2)
        XCTAssertFalse(rows[0].edges.contains(where: \.endsAtNode)) // no invented ancestor above a tip
        for index in 0..<rows.count - 1 {
            let outgoing = rows[index].edges.filter { !$0.endsAtNode }.map { "\($0.to):\($0.color)" }.sorted()
            let incoming = rows[index + 1].edges.filter { !$0.startsAtNode }.map { "\($0.from):\($0.color)" }.sorted()
            // Multiple edges may join the same ancestor at a row boundary.
            XCTAssertEqual(Set(outgoing), Set(incoming))
        }
        XCTAssertTrue(rows[3].edges.allSatisfy(\.endsAtNode))
    }
    func testOctopusAndDisconnectedHistory() {
        let rows = CommitGraph.layout([entry("M", ["A", "B", "C"]), entry("A", []), entry("B", []), entry("C", []), entry("unrelated", [])])
        XCTAssertEqual(rows[0].width, 3)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 3)
        XCTAssertEqual(rows[4].column, 0)
        XCTAssertTrue(rows[4].edges.isEmpty)
    }
    func testChangedPathParsingWithBinaryRenameTabsAndNewlines() {
        let files = CommitFile.parse(names: Data("R100\0old\nname\0new\tname\0M\0binary\0A\0雪\0".utf8),
            statistics: Data("0\t0\t\0old\nname\0new\tname\0-\t-\tbinary\03\t0\t雪\0".utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].oldPath, "old\nname")
        XCTAssertEqual(files[0].path, "new\tname")
        XCTAssertEqual(files[0].added, 0)
        XCTAssertNil(files[1].added)
        XCTAssertEqual(files[2].added, 3)
    }
    func testHistorySearchFieldsMatchAuthorAndCommitterBeforeLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Integrator [雪]"])
        _ = try await repo.run(["config", "user.email", "integrator@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.run(["commit", "--author=Contributor <contributor@example.invalid>", "-m", "Literal [needle]\n\nBody only token"])
        let oldHistory = try await repo.history(), older = try XCTUnwrap(oldHistory.first)
        XCTAssertEqual(older.committer, "Integrator [雪]")
        XCTAssertEqual(older.committerEmail, "integrator@example.invalid")
        _ = try await repo.run(["config", "user.name", "Recent"])
        _ = try await repo.run(["config", "user.email", "recent@example.invalid"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "contributor@example.invalid is mentioned")
        var options = HistoryOptions(); options.limit = 1; options.search = "CONTRIBUTOR"; options.searchFields = .authors
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "[雪]"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "INTEGRATOR@"; options.searchFields = .emails
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.search = "contributor@example.invalid"; options.searchFields = [.messages, .emails]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, older.hash)
        options.searchFields = .emails; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .revisions; options.search = String(older.hash.prefix(12)).uppercased()
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .messages; options.search = "[needle]"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = []; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = ""; options.limit = 1; found = try await repo.history(options: options); XCTAssertEqual(found.count, 1)
        options.search = "Contributor"; options.searchFields = .authors; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.searchFields = .authors; options.search = "CONTRIBUTOR"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "Contributor"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .emails; options.search = "INTEGRATOR@"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "integrator@"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .messages; options.search = "body only token"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "Body only token"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .subject; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "literal [needle]"; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchCaseSensitive = false; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = [.subject, .messages]; options.search = "BODY ONLY TOKEN"
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
        options.searchFields = .authors; options.search = "Contributor"
        options.paths = []; options.limit = 0; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.limit = 1; options.endRevision = older.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [older.hash])
    }
    func testReferenceSearchFindsBranchesRemoteAndPeeledTagsBeforeLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Ref Tests"])
        _ = try await repo.run(["config", "user.email", "refs@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["branch", "release-needle", old.hash])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/Review", old.hash])
        _ = try await repo.run(["tag", "light-needle", old.hash])
        _ = try await repo.run(["tag", "-a", "annotated-needle", "-m", "annotation text", old.hash])
        _ = try await repo.run(["tag", "-a", "nested-tag", "-m", "nested annotation", "annotated-needle"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "needle only-in-message")
        var options = HistoryOptions(); options.searchFields = .referenceNames; options.limit = 1
        for name in ["release-needle", "refs/remotes/origin/Review", "light-needle", "annotated-needle", "nested-tag"] {
            options.search = name; let found = try await repo.history(options: options)
            XCTAssertEqual(found.map(\.hash), [old.hash], name)
            XCTAssertTrue(found.first?.references.contains { $0.name.hasSuffix(name) } == true)
        }
        options.search = "annotated-needle^{}"
        let peeled = try await repo.history(options: options); XCTAssertEqual(peeled.map(\.hash), [old.hash])
        options.search = "light-needle^{}"; let notPeeled = try await repo.history(options: options); XCTAssertTrue(notPeeled.isEmpty)
        options.search = "only-in-message"; var found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "review"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchCaseSensitive = false; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.search = "needle"; options.searchFields = [.messages, .referenceNames]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
        options.searchFields = .referenceNames; options.search = "release-needle"; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash; options.search = "main"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
    }
    func testNotesSearchUsesDisplayedNotesWithoutCorruptingHistoryRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Note Tests"])
        _ = try await repo.run(["config", "user.email", "notes@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["notes", "add", "-m", "NoteToken 雪\nMultiline note", old.hash])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "NoteToken only-message")
        var options = HistoryOptions(); options.searchFields = .notes; options.search = "notetoken"; options.limit = 1
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        XCTAssertTrue(found.first?.notes.contains("Multiline note") == true)
        options.searchCaseSensitive = true; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "NoteToken"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.searchFields = [.notes, .messages]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2)
        options.searchFields = .messages; options.search = "Multiline note"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.searchFields = .notes; options.search = "only-message"
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "NoteToken"; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        _ = try await repo.run(["notes", "--ref=review", "add", "-m", "ReviewOnly", old.hash])
        _ = try await repo.run(["config", "notes.displayRef", "refs/notes/review"])
        options.search = "ReviewOnly"; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        _ = try await repo.run(["config", "--unset", "notes.displayRef"])
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/review"])
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        let binaryNote = root.appendingPathComponent("note.bin"); try Data("Before\0AfterMarker\n".utf8).write(to: binaryNote)
        let blob = try await repo.run(["hash-object", "-w", "--", binaryNote.path]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["notes", "add", "-f", "-C", blob, old.hash])
        let displayed = try await repo.run(["show", "-s", "--notes", "--format=%N", old.hash, "--"]).text.trimmingCharacters(in: .newlines)
        options.search = "Before"; found = try await repo.history(options: options)
        XCTAssertEqual(found.map(\.hash), [old.hash]); XCTAssertEqual(found.first?.notes, displayed)
        options.search = ""; options.endRevision = nil
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
    }
    func testAnnotatedTagInfoSearchUsesTagObjectsAndExcludesLightweightRefs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Tagger Person"])
        _ = try await repo.run(["config", "user.email", "tagger@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("old\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "old")
        let initial = try await repo.history(), old = try XCTUnwrap(initial.first)
        _ = try await repo.run(["tag", "-a", "release-tag", "-m", "AnnotationMarker 雪\nSecond line", old.hash])
        let object = try await repo.run(["rev-parse", "refs/tags/release-tag"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/tags/alias-only-name", object])
        _ = try await repo.run(["tag", "light-only-name", old.hash])
        _ = try await repo.run(["tag", "-a", "nested", "-m", "NestedAnnotation", "release-tag"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "AnnotationMarker only-message")
        var options = HistoryOptions(); options.searchFields = .tagInfo; options.search = "annotationmarker"; options.limit = 1
        var found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        XCTAssertTrue(found.first?.tagInfo.contains("tag release-tag") == true)
        XCTAssertTrue(found.first?.tagInfo.contains("Tagger Person <tagger@example.invalid>") == true)
        XCTAssertTrue(found.first?.tagInfo.contains("Second line") == true)
        XCTAssertFalse(found.first!.tagInfo.contains("object " + old.hash))
        for query in ["NestedAnnotation", "release-tag", "tagger@example.invalid", "Tagger Person"] {
            options.search = query; found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        }
        for query in ["light-only-name", "alias-only-name", "only-message", old.hash] {
            options.search = query; found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty, query)
        }
        options.search = "annotationmarker"; options.searchCaseSensitive = true
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.search = "AnnotationMarker"; options.searchFields = [.messages, .tagInfo]; options.limit = 2
        found = try await repo.history(options: options); XCTAssertEqual(found.count, 2); XCTAssertEqual(found.last?.hash, old.hash)
        options.searchFields = .tagInfo; options.paths = ["absent.txt"]
        found = try await repo.history(options: options); XCTAssertTrue(found.isEmpty)
        options.paths = []; options.endRevision = old.hash
        found = try await repo.history(options: options); XCTAssertEqual(found.map(\.hash), [old.hash])
        options.search = ""; found = try await repo.history(options: options)
        XCTAssertEqual(found.map(\.hash), [old.hash]); XCTAssertTrue(found.first?.tagInfo.contains("NestedAnnotation") == true)
    }
    func testRealHistoryDetailsRefsFilteringAndMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History Tests"])
        _ = try await repo.run(["config", "user.email", "history@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let weird = "initial\t雪\n.txt"
        try Data("line one\nline two\n".utf8).write(to: root.appendingPathComponent(weird))
        try await repo.stage([weird]); _ = try await repo.commit(message: "Initial\n\nMultiline body\nAnother line")
        let initialHistory = try await repo.history()
        let initial = try XCTUnwrap(initialHistory.first)
        XCTAssertEqual(initial.email, "history@example.invalid")
        XCTAssertTrue(initial.message.contains("Multiline body\nAnother line"))
        XCTAssertTrue(initial.isHead)
        XCTAssertEqual(initial.references.filter(\.isCurrent).map(\.name), ["refs/heads/main"])
        let initialFiles = try await repo.files(in: initial)
        XCTAssertEqual(initialFiles.first?.path, weird)
        XCTAssertEqual(initialFiles.first?.added, 2)
        _ = try await repo.run(["switch", "-c", "feature"])
        _ = try await repo.run(["mv", "--", weird, "renamed.txt"])
        _ = try await repo.commit(message: "Rename on feature")
        let renamedHistory = try await repo.history()
        let renamed = try XCTUnwrap(renamedHistory.first)
        let renamedFiles = try await repo.files(in: renamed)
        XCTAssertEqual(renamedFiles.first?.oldPath, weird)
        XCTAssertEqual(renamedFiles.first?.status, "Renamed")
        XCTAssertEqual(renamedFiles.first?.removed, 0)
        _ = try await repo.run(["tag", "-a", "v1", "-m", "Annotated tag"])
        _ = try await repo.run(["switch", "main"])
        try Data("main change\n".utf8).write(to: root.appendingPathComponent("main.txt"))
        try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "Main work")
        _ = try await repo.run(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let history = try await repo.history()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[0].parents.count, 2)
        XCTAssertTrue(history.first { $0.hash == renamed.hash }!.references.contains { $0.name == "refs/tags/v1" })
        let mergeFiles = try await repo.files(in: history[0])
        XCTAssertEqual(mergeFiles.first?.status, "Renamed")
        var options = HistoryOptions(); options.search = "Multiline body"
        let filtered = try await repo.history(options: options)
        XCTAssertEqual(filtered.map(\.hash), [initial.hash])
        options.search = ""; options.limit = 2
        let limited = try await repo.history(options: options)
        XCTAssertEqual(limited.count, 2)
        let diff = try await repo.revisionDiff(history[0])
        XCTAssertTrue(diff.contains("rename to renamed.txt"))
    }
}
