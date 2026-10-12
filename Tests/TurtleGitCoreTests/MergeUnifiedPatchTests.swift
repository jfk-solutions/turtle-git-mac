import XCTest
@testable import TurtleGitCore

final class MergeUnifiedPatchTests: XCTestCase {
    private let git = URL(fileURLWithPath: "/usr/bin/git")
    private func content(_ bytes: Data, mode: String = "100644", deleted: Bool = false) -> ComparisonFileContent {
        ComparisonFileContent(path: "sample", revision: .workingTree, bytes: bytes, mode: mode, isDeleted: deleted)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPatchTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testQuotedPathsCRLFAndNonUTF8HunksApplyWithoutChangingInputs() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let label = "folder/雪 \"name\"\t.txt", file = root.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data([0xe9]) + Data(" line\r\n-- a/before\r\nlast".utf8)
        let new = Data([0xe9]) + Data(" changed\r\n-- a/before\r\nlast".utf8)
        let patch = try await MergeUnifiedPatch.create(base: content(old), destination: content(new), baseLabel: label, destinationLabel: label, executable: git)
        XCTAssertFalse(patch.containsSubsequence(Data("TurtleGitMergePatch-".utf8)))
        XCTAssertTrue(patch.containsSubsequence(Data([0xe9])))
        try old.write(to: file); let patchFile = root.appendingPathComponent("result.diff"); try patch.write(to: patchFile)
        _ = try await GitRepository(root: root).run(["apply", "--", patchFile.path])
        XCTAssertEqual(try Data(contentsOf: file), new)
    }
    func testContextsIdenticalAndRangeValidation() async throws {
        let old = "a\nb\nc\nd\ne\nf\ng\n", new = "a\nb\nc\nchanged\ne\nf\ng\n"
        let zero = try await MergeUnifiedPatch.create(base: content(Data(old.utf8)), destination: content(Data(new.utf8)), baseLabel: "one", destinationLabel: "one", contextLines: 0, executable: git)
        XCTAssertTrue(String(decoding: zero, as: UTF8.self).contains("@@ -4 +4 @@"))
        let standard = try await MergeUnifiedPatch.create(base: content(Data(old.utf8)), destination: content(Data(new.utf8)), baseLabel: "one", destinationLabel: "one", executable: git)
        XCTAssertTrue(standard.count > zero.count)
        let empty = try await MergeUnifiedPatch.create(base: content(Data(old.utf8)), destination: content(Data(old.utf8)), baseLabel: "one", destinationLabel: "one", executable: git)
        XCTAssertEqual(empty, Data())
        XCTAssertEqual(MergeUnifiedPatch.validatedContext(" -1 "), -1); XCTAssertEqual(MergeUnifiedPatch.validatedContext("1000"), 1000)
        XCTAssertNil(MergeUnifiedPatch.validatedContext("1001")); XCTAssertNil(MergeUnifiedPatch.validatedContext("-2")); XCTAssertNil(MergeUnifiedPatch.validatedContext("NaN"))
    }
    func testModeOnlyAndBinaryDiagnosticsRetainGitSemantics() async throws {
        let patch = try await MergeUnifiedPatch.create(base: content(Data("same\n".utf8), mode: "100644"), destination: content(Data("same\n".utf8), mode: "100755"), baseLabel: "run", destinationLabel: "run", executable: git)
        let text = String(decoding: patch, as: UTF8.self)
        XCTAssertTrue(text.contains("old mode 100644") && text.contains("new mode 100755"))
        let binary = try await MergeUnifiedPatch.create(base: content(Data([0,1])), destination: content(Data([0,2])), baseLabel: "image", destinationLabel: "image", executable: git)
        XCTAssertTrue(String(decoding: binary, as: UTF8.self).contains("Binary files a/image and b/image differ"))
    }
    func testAddDeleteAndSymlinkTargets() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root), output = root.appendingPathComponent("out.diff")
        let added = try await MergeUnifiedPatch.create(base: content(Data(), deleted: true), destination: content(Data("created\n".utf8)), baseLabel: "missing", destinationLabel: "new.txt", executable: git)
        try added.write(to: output); _ = try await repository.run(["apply", "--", output.path])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "created\n")
        let removed = try await MergeUnifiedPatch.create(base: content(Data("created\n".utf8)), destination: content(Data(), deleted: true), baseLabel: "new.txt", destinationLabel: "missing", executable: git)
        try removed.write(to: output); _ = try await repository.run(["apply", "--", output.path]); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        let link = try await MergeUnifiedPatch.create(base: content(Data("old-target".utf8), mode: "120000"), destination: content(Data("new-target".utf8), mode: "120000"), baseLabel: "link", destinationLabel: "link", executable: git)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "old-target")
        try link.write(to: output); _ = try await repository.run(["apply", "--", output.path])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "new-target")
    }
    func testCancelledRequestDoesNotStartGit() async throws {
        let token = OperationCancellation(); token.cancel()
        do {
            _ = try await MergeUnifiedPatch.create(base: content(Data()), destination: content(Data()), baseLabel: "one", destinationLabel: "one", executable: URL(fileURLWithPath: "/missing/git"), cancellation: token)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is OperationCancellationFailure) }
    }
}
private extension Data {
    func containsSubsequence(_ other: Data) -> Bool { range(of: other) != nil }
}
