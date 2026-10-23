import XCTest
@testable import TurtleGitCore

final class SourceTextPatchWorkflowTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDecodedPatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }
    func files(_ names: [String], in directory: URL) throws {
        for name in names {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
    }
    func testDecodedUnicodeHeadersDiscoverLiteralPreimagesWithoutTargetWrites() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        // Decoded header discovery preserves source preimages without initializing
        // the chosen target folder as a repository.
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        let old = "--old cafe\u{301} (scope)\\literal\t\n[*].txt", new = "--new caf\u{e9} (scope)\\literal\t\n[*].txt"
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let patch = "diff --git \(quoted("a/" + old)) \(quoted("b/" + new))\n--- \(quoted("a/" + old))\n+++ \(quoted("b/" + new))\n@@ -1 +1 @@\n-before 🐢\n+after 🐢\n"
        for encoding in [ComparisonTextEncoding.utf8BOM, .utf16LE, .utf16BE, .utf16LEBOM, .utf16BEBOM, .utf32LE, .utf32BE] {
            let bytes = try encoding.encode(patch), original = bytes
            XCTAssertEqual(PatchTargetMatching.initialStripCount(bytes), 1, encoding.rawValue)
            let paths = try await repository.patchTargetPaths(bytes, stripCount: 1)
            XCTAssertEqual(paths, [Data(old.utf8)], encoding.rawValue)
            XCTAssertFalse(paths.contains(Data(new.utf8)), "Renames must discover the preimage")
            XCTAssertEqual(bytes, original)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testDecodedSVNHeadersAndLegacyPolicyKeepStripSemanticsAndFileOrder() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        let first = "src/caf\u{e9} [*].txt", second = "src/new file.txt", third = "src/deleted.txt"
        let patch = "Index: \(first)\n===================================================================\n--- \(first)\t(revision 7)\n+++ \(first)\t(working copy)\n@@ -1 +1 @@\n-before\n+after\n" +
            "Index: \(second)\n===================================================================\n--- /dev/null\t(revision 0)\n+++ \(second)\t(working copy)\n@@ -0,0 +1 @@\n+new\n" +
            "Index: \(third)\n===================================================================\n--- \(third)\t(revision 7)\n+++ /dev/null\t(working copy)\n@@ -1 +0,0 @@\n-deleted\n"
        let policy = MergeTextEncodingPolicy(preferUTF8: false, legacyEncoding: .windows1252)
        for encoding in [ComparisonTextEncoding.windows1252, .utf16LEBOM, .utf16BEBOM, .utf32LE, .utf32BE] {
            let bytes = try encoding.encode(patch)
            XCTAssertEqual(PatchTargetMatching.initialStripCount(bytes, textEncodingPolicy: policy), 0, encoding.rawValue)
            let paths = try await repository.patchTargetPaths(bytes, stripCount: 0, textEncodingPolicy: policy)
            XCTAssertEqual(paths, [first, second, third].map { Data($0.utf8) }, encoding.rawValue)
            let stripped = try await repository.patchTargetPaths(bytes, stripCount: 1, textEncodingPolicy: policy)
            XCTAssertEqual(stripped, ["caf\u{e9} [*].txt", "new file.txt", "deleted.txt"].map { Data($0.utf8) })
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testDecodedTargetDiscoveryRetainsBoundaryAndCancellation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let literal = "src/--file 雪[*].txt"
        try files([literal], in: root)
        let repository = GitRepository(root: selected, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- \(literal)\n+++ \(literal)\n@@ -1 +1 @@\n-before\n+after\n")
        let paths = try await repository.patchTargetPaths(bytes, stripCount: 0)
        XCTAssertEqual(paths, [Data(literal.utf8)])
        XCTAssertEqual(PatchTargetMatching.suggestion(start: selected, paths: paths, boundary: root), root)
        XCTAssertNil(PatchTargetMatching.suggestion(start: selected, paths: paths, boundary: selected))
        let token = OperationCancellation(); token.cancel()
        XCTAssertEqual(PatchTargetMatching.initialStripCount(bytes, cancellation: token), 0)
        do { _ = try await repository.patchTargetPaths(bytes, stripCount: 0, cancellation: token); XCTFail("Cancelled decoded target query ran") }
        catch is OperationCancellationFailure { }
        do { _ = try await repository.patchTargetPaths(bytes, stripCount: -1); XCTFail("Negative strip accepted") }
        catch WorkingTreePatchFailure.stripCount { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data())
    }

    func repository(_ root: URL) async throws -> GitRepository {
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "Decoded patch"])
        _ = try await repository.run(["config", "user.email", "decoded@example.invalid"])
        _ = try await repository.run(["config", "commit.gpgsign", "false"])
        _ = try await repository.run(["config", "core.hooksPath", "/dev/null"])
        return repository
    }
    func testUnicodeReviewSelectedComparisonApplyAndReversePreserveRawContainerAndIndex() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root), policy = MergeTextEncodingPolicy(preferUTF8: true)
        let first = "first 雪[*].txt", second = "second.txt"
        let firstBefore = try ComparisonTextEncoding.utf16LEBOM.encode("before 🐢\n"), firstAfter = try ComparisonTextEncoding.utf16LEBOM.encode("after 🐢\n")
        let secondBefore = try ComparisonTextEncoding.utf16BEBOM.encode("before two\n"), secondAfter = try ComparisonTextEncoding.utf16BEBOM.encode("after two\n")
        try firstBefore.write(to: root.appendingPathComponent(first)); try secondBefore.write(to: root.appendingPathComponent(second))
        try await repository.stage([first, second]); _ = try await repository.commit(message: "Before")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let text = "--- \(first)\t(revision 7)\n+++ \(first)\t(working copy)\n@@ -1,1 +1,1 @@\n-before 🐢\n+after 🐢\n--- \(second)\t(revision 7)\n+++ \(second)\t(working copy)\n@@ -1,1 +1,1 @@\n-before two\n+after two\n"
        let bytes = try ComparisonTextEncoding.utf32BE.encode(text)
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0, textEncodingPolicy: policy)
        XCTAssertTrue(review.canApply, review.validationError ?? "")
        XCTAssertEqual(review.document.bytes, bytes); XCTAssertEqual(review.document.sourceEncoding, .utf32BE)
        XCTAssertEqual(review.textEncodingPolicy, policy); XCTAssertEqual(review.files.map(\.pathBytes), [first, second].map { Data($0.utf8) })
        let firstComparison = try await repository.compareWorkingTreePatchFile(review, fileID: review.files[0].id)
        XCTAssertEqual(firstComparison.document.base.bytes, firstBefore); XCTAssertEqual(firstComparison.document.destination.bytes, firstAfter)
        XCTAssertFalse(firstComparison.requiresMerge)
        let firstOnly = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: [review.files[0].id])
        XCTAssertTrue(firstOnly.canApply); XCTAssertEqual(firstOnly.document.bytes, bytes)
        _ = try await repository.applyWorkingTreePatch(firstOnly)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first)), firstAfter)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second)), secondBefore)
        let secondOnly = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: [review.files[1].id])
        XCTAssertTrue(secondOnly.canApply)
        _ = try await repository.applyWorkingTreePatch(secondOnly)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second)), secondAfter)
        let reverse = try await repository.reviewWorkingTreePatch(bytes, reversed: true, stripCount: 0, textEncodingPolicy: policy)
        XCTAssertTrue(reverse.canApply, reverse.validationError ?? "")
        _ = try await repository.applyWorkingTreePatch(reverse)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first)), firstBefore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second)), secondBefore)
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }
    func testDecodedExplicitSaveBackupAndStaleComparisonRefusal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root), file = root.appendingPathComponent("file.txt")
        let original = try ComparisonTextEncoding.utf16LEBOM.encode("before\n")
        try original.write(to: file); try await repository.stage(["file.txt"]); _ = try await repository.commit(message: "Before")
        let bytes = try ComparisonTextEncoding.utf16BEBOM.encode("--- file.txt\n+++ file.txt\n@@ -1,1 +1,1 @@\n-before\n+after\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        let comparison = try await repository.compareWorkingTreePatchFile(review, fileID: review.files[0].id)
        let saved = try await repository.saveWorkingTreePatchFile(comparison, text: "edited 🐢\n", encoding: .utf16LEBOM, autoAddNewFiles: false, options: .init(backupOriginal: true))
        XCTAssertEqual(saved.document.destination.text, "edited 🐢\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file.txt.bak")), original)
        XCTAssertEqual(try Data(contentsOf: file), try ComparisonTextEncoding.utf16LEBOM.encode("edited 🐢\n"))
        do { _ = try await repository.saveWorkingTreePatchFile(comparison, text: "stale\n"); XCTFail("Stale decoded comparison saved") }
        catch FileComparisonEditFailure.changed { }
        XCTAssertEqual(try Data(contentsOf: file), try ComparisonTextEncoding.utf16LEBOM.encode("edited 🐢\n"))
    }
    func testSVNRevisionAnnotationsDoNotInventRecordedBaseAndValidSubsetRemainsApplicable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("good")); try Data("local\n".utf8).write(to: root.appendingPathComponent("conflict"))
        try await repository.stage(["good", "conflict"]); _ = try await repository.commit(message: "Before")
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- good\t(revision 12345678)\n+++ good\t(working copy)\n@@ -1,1 +1,1 @@\n-before\n+after\n--- conflict\t(revision 12345678)\n+++ conflict\t(working copy)\n@@ -1,1 +1,1 @@\n-before\n+after\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        XCTAssertFalse(review.canApply)
        let conflict = try XCTUnwrap(review.files.first { $0.path == "conflict" })
        do { _ = try await repository.compareWorkingTreePatchFile(review, fileID: conflict.id); XCTFail("SVN numeric annotation invented a Git base") }
        catch is SourceTextPatchApplication.Failure { }
        let good = try XCTUnwrap(review.files.first { $0.path == "good" })
        let selected = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: [good.id])
        XCTAssertTrue(selected.canApply, selected.validationError ?? "")
        _ = try await repository.applyWorkingTreePatch(selected)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("good")), Data("after\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("conflict")), Data("local\n".utf8))
    }
    func testDecodedModeRenameBatchAdvancesOnlyOwnedWritesAndRefusesExternalChanges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root)
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), c = root.appendingPathComponent("C")
        try Data("before\n".utf8).write(to: a); try await repository.stage(["A"]); _ = try await repository.commit(message: "Before")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let text = "diff --git a/A b/B\nold mode 100644\nnew mode 100755\n--- a/A\n+++ b/B\n@@ -1,1 +1,1 @@\n-before\n+middle\ndiff --git a/B b/C\n--- a/B\n+++ b/C\n@@ -1,1 +1,1 @@\n-middle\n+after\n"
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode(text)
        let review = try await repository.reviewWorkingTreePatch(bytes)
        XCTAssertTrue(review.canApply, review.validationError ?? "")
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)))
        XCTAssertEqual(result.files.count, 2); XCTAssertTrue(result.files.allSatisfy(\.success)); XCTAssertFalse(result.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(try Data(contentsOf: c), Data("after\n".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: c.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o111, 0o111)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try FileManager.default.removeItem(at: c); try Data("before\n".utf8).write(to: a)
        let fresh = try await repository.reviewWorkingTreePatch(bytes)
        let interrupted = try await repository.applyWorkingTreePatchBatch(fresh, fileIDs: Set(fresh.files.map(\.id)), onResult: { item in
            if item.success && item.pathBytes == Data("B".utf8) { try? Data("external\n".utf8).write(to: b) }
        })
        XCTAssertTrue(interrupted.files[0].success); XCTAssertFalse(interrupted.files[1].success)
        XCTAssertEqual(try Data(contentsOf: b), Data("external\n".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
    }
    func testGitAcceptedBinaryAndCapturedLegacyDocumentsRetainTheirBoundaries() async throws {
        let (root, repository, binary) = try await WorkingTreePatchReviewTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repository.reviewWorkingTreePatch(binary)
        XCTAssertTrue(review.canApply); XCTAssertNil(review.textEncodingPolicy); XCTAssertEqual(review.document.bytes, binary)
        let file = root.appendingPathComponent("legacy.txt"), policy = MergeTextEncodingPolicy(preferUTF8: false, legacyEncoding: .windows1251)
        try ComparisonTextEncoding.windows1251.encode("Привет\n").write(to: file)
        let patch = try ComparisonTextEncoding.windows1251.encode("--- a/legacy.txt\n+++ b/legacy.txt\n@@ -1,1 +1,1 @@\n-Привет\n+Мир\n")
        let captured = try await repository.reviewWorkingTreePatch(patch, textEncodingPolicy: policy)
        XCTAssertTrue(captured.canApply, captured.validationError ?? "")
        XCTAssertEqual(captured.document.sourceEncoding, .windows1251); XCTAssertEqual(captured.document.displayText, "--- a/legacy.txt\n+++ b/legacy.txt\n@@ -1,1 +1,1 @@\n-Привет\n+Мир\n")
    }
    func testGitShorthandMismatchKeepsValidatedMetadataAndRecordedBaseRecovery() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root), file = root.appendingPathComponent("long.txt")
        let original = (1...32).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(original.utf8).write(to: file); try await repository.stage(["long.txt"]); _ = try await repository.commit(message: "Before")
        let old = try await repository.run(["rev-parse", "HEAD:long.txt"]).text.trimmingCharacters(in: .newlines)
        let patch = Data("diff --git a/long.txt b/long.txt\nindex \(old)..\(String(repeating: "f", count: old.count)) 100644\n--- a/long.txt\n+++ b/long.txt\n@@ -32 +32 @@\n-line 32\n+patched 32\n".utf8)
        try Data(original.replacingOccurrences(of: "line 32\n", with: "local 32\n").utf8).write(to: file)
        let review = try await repository.reviewWorkingTreePatch(patch)
        XCTAssertFalse(review.canApply); XCTAssertEqual(review.files.count, 1); XCTAssertEqual(review.document.bytes, patch)
        let comparison = try await repository.compareWorkingTreePatchFile(review, fileID: review.files[0].id)
        XCTAssertTrue(comparison.requiresMerge); XCTAssertEqual(comparison.recoveryBase?.bytes, Data(original.utf8))
        XCTAssertTrue(comparison.document.destination.text?.contains("patched 32") == true)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("local 32"))
    }

    func testDecodedBatchRetainsExisting0750PermissionsWithoutPostApplyWarning() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root), file = root.appendingPathComponent("script")
        try Data("before\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: file.path)
        try await repository.stage(["script"]); _ = try await repository.commit(message: "Before")
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- script\n+++ script\n@@ -1,1 +1,1 @@\n-before\n+after\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        XCTAssertTrue(review.canApply, review.validationError ?? "")
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)))
        XCTAssertEqual(result.files.count, 1); XCTAssertTrue(result.files[0].success); XCTAssertNil(result.files[0].postApplyError)
        XCTAssertEqual(try Data(contentsOf: file), Data("after\n".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o750)
    }
    func testDecodedPublishedPermissionWarningRetainsSuccessfulBatchReceipt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let setup = try await repository(root), file = root.appendingPathComponent("first")
        try Data("before\n".utf8).write(to: file)
        try await setup.stage(["first"]); _ = try await setup.commit(message: "Before")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let realGit = ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        // Inject a changed permission witness after successful publication. The
        // adapter must report the write and refuse to chmod an unowned state.
        let wrapper = root.appendingPathComponent("git-wrapper")
        let script = """
        #!/bin/sh
        publish=no
        check=no
        for arg in "$@"; do
            [ "$arg" = "--whitespace=nowarn" ] && publish=yes
            [ "$arg" = "--check" ] && check=yes
        done
        \(quoted(realGit)) "$@"
        status=$?
        if [ "$status" = 0 ] && [ "$publish" = yes ] && [ "$check" = no ]; then
            /bin/chmod 777 \(quoted(file.path))
        fi
        exit "$status"
        """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let repository = GitRepository(root: root, executable: wrapper)
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- first\n+++ first\n@@ -1,1 +1,1 @@\n-before\n+after\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        XCTAssertTrue(review.canApply, review.validationError ?? "")
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)))
        let item = try XCTUnwrap(result.files.first)
        XCTAssertTrue(item.success); XCTAssertNotNil(item.postApplyError)
        XCTAssertTrue(item.output.contains("permission verification did not finish"))
        XCTAssertEqual(try Data(contentsOf: file), Data("after\n".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue, 0o777, "Unowned permission witness must not be overwritten")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testDecodedBatchNewFileAutoAddAndAutomaticEmptyResultCleanup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root)
        try Data("old\n".utf8).write(to: root.appendingPathComponent("zero")); try await repository.stage(["zero"]); _ = try await repository.commit(message: "Before")
        let text = "--- /dev/null\n+++ added\n@@ -0,0 +1,1 @@\n+new\n--- zero\n+++ zero\n@@ -1,1 +0,0 @@\n-old\n"
        let review = try await repository.reviewWorkingTreePatch(try ComparisonTextEncoding.utf16BEBOM.encode(text), stripCount: 0)
        XCTAssertTrue(review.canApply, review.validationError ?? "")
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)), autoAddNewFiles: true)
        XCTAssertTrue(result.files.allSatisfy(\.success)); XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.files.allSatisfy { $0.addError == nil && $0.postApplyError == nil })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("added")), Data("new\r\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("zero").path))
        let staged = try await repository.run(["diff", "--cached", "--name-status"]).text
        XCTAssertEqual(staged, "A\tadded\n")
    }
    func testDecodedExistingAdditionHasOnlyTheAuthoritativeEmptyRecoveryBase() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root), file = root.appendingPathComponent("added")
        try Data("local\n".utf8).write(to: file); try await repository.stage(["added"]); _ = try await repository.commit(message: "Before")
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- /dev/null\n+++ added\n@@ -0,0 +1,1 @@\n+patch\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        XCTAssertFalse(review.canApply)
        let comparison = try await repository.compareWorkingTreePatchFile(review, fileID: review.files[0].id)
        XCTAssertTrue(comparison.requiresMerge); XCTAssertEqual(comparison.recoveryBase?.bytes, Data())
        XCTAssertEqual(comparison.document.base.bytes, Data("local\n".utf8))
        XCTAssertTrue(comparison.document.destination.text?.hasPrefix("patch") == true)
        XCTAssertEqual(try Data(contentsOf: file), Data("local\n".utf8))
    }
    func testDecodedQuotedSVNAnnotationsPreserveLiteralParenthesesAndBackslash() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        let name = "name(1)\\part.txt"
        let patch = "--- \"name(1)\\\\part.txt\"\t(revision 4)\n+++ \"name(1)\\\\part.txt\"\t（working copy）\n@@ -1,1 +1,1 @@\n-before\n+after\n"
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode(patch)
        let paths = try await repository.patchTargetPaths(bytes, stripCount: 0)
        XCTAssertEqual(paths, [Data(name.utf8)])
        XCTAssertEqual(PatchTargetMatching.initialStripCount(bytes), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPlainFolderDecodedUnicodeCopyModesAddDeleteWholeAndBatchWithoutGitAdministration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git")
        let source = "source 雪", copied = "copied 雪"
        let before = try ComparisonTextEncoding.utf16BEBOM.encode("old 雪\n"), after = try ComparisonTextEncoding.utf16BEBOM.encode("copy 雪\n")
        let text = "diff --git \"a/\(source)\" \"b/\(copied)\"\nold mode 100644\nnew mode 100755\ncopy from \"\(source)\"\ncopy to \"\(copied)\"\n--- \"a/\(source)\"\n+++ \"b/\(copied)\"\n@@ -1,1 +1,1 @@\n-old 雪\n+copy 雪\n" +
            "diff --git a/added b/added\nnew file mode 100644\n--- /dev/null\n+++ b/added\n@@ -0,0 +1,1 @@\n+new\n" +
            "diff --git a/gone b/gone\ndeleted file mode 100644\n--- a/gone\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-gone\n"
        let bytes = try ComparisonTextEncoding.utf32LE.encode(text)
        for batch in [false, true] {
            let folder = root.appendingPathComponent(batch ? "batch" : "whole")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try before.write(to: folder.appendingPathComponent(source))
            try ComparisonTextEncoding.utf16LEBOM.encode("gone\n").write(to: folder.appendingPathComponent("gone"))
            let sentinel = Data("independent sentinel\n".utf8); try sentinel.write(to: folder.appendingPathComponent("index-sentinel"))
            let repository = GitRepository(root: folder, executable: git)
            let review = try await repository.reviewWorkingTreePatch(bytes, directoryMode: true, isGitWorkingTree: false)
            XCTAssertTrue(review.canApply, review.validationError ?? ""); XCTAssertFalse(review.isGitWorkingTree)
            XCTAssertEqual(review.document.bytes, bytes); XCTAssertEqual(review.document.sourceEncoding, .utf32LE)
            let copy = try XCTUnwrap(review.files.first { $0.path == copied })
            let comparison = try await repository.compareWorkingTreePatchFile(review, fileID: copy.id)
            XCTAssertEqual(comparison.document.base.bytes, before); XCTAssertEqual(comparison.document.destination.bytes, after)
            if batch {
                let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)), autoAddNewFiles: true)
                XCTAssertEqual(result.files.count, 3); XCTAssertTrue(result.files.allSatisfy { $0.success && $0.addError == nil && $0.postApplyError == nil })
            } else { _ = try await repository.applyWorkingTreePatch(review) }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(source)), before, "Copy retains its Unicode source")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(copied)), after)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("added")), Data("new\r\n".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("gone").path))
            let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(copied).path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue & 0o111, 0o111)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("index-sentinel")), sentinel)
        }
    }
    func testDecodedOrderedBatchCancellationStopsBeforeNextFileAndPreservesAcceptedResult() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await repository(root)
        try Data("first\n".utf8).write(to: root.appendingPathComponent("first"))
        try Data("second\n".utf8).write(to: root.appendingPathComponent("second"))
        try await repository.stage(["first", "second"]); _ = try await repository.commit(message: "Before")
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("--- first\n+++ first\n@@ -1,1 +1,1 @@\n-first\n+patched first\n--- second\n+++ second\n@@ -1,1 +1,1 @@\n-second\n+patched second\n")
        let review = try await repository.reviewWorkingTreePatch(bytes, stripCount: 0)
        let token = OperationCancellation()
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)), cancellation: token, onProgress: { item in
            if item.completedIndex == 1 { token.cancel() }
        })
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.files.count, 1); XCTAssertTrue(result.files[0].success)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("first")), Data("patched first\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("second")), Data("second\n".utf8))
    }

}
