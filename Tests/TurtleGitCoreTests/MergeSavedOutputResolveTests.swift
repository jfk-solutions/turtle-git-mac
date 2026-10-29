import XCTest
@testable import TurtleGitCore

final class MergeSavedOutputResolveTests: XCTestCase {
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func saved(_ url: URL, text: String, encoding: ComparisonTextEncoding = .utf8) throws -> MergeToolOutputTarget {
        try MergeToolOutputTarget(capturing: url).save(text: text, encoding: encoding)
    }
    func testSavedStandaloneUnmergedResultResolvesExactLiteralBytesAndPreservesPeers() async throws {
        let (root, repository, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path)
        let peer = try await repository.run(["ls-files", "--stage", "-z", "--", "other.txt"]).stdout
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let merge = try await repository.run(["rev-parse", "MERGE_HEAD"]).stdout
        let output = try saved(file, text: "standalone reviewed 雪🦎\r\nlast", encoding: .utf16LEBOM)
        let receipt = try MergeSavedOutputReceipt.capture(after: output.content, at: file)
        for side in ["BASE", "LOCAL", "REMOTE"] { try Data("temporary".utf8).write(to: URL(fileURLWithPath: file.path + "." + side + ".txt")) }
        let backup = URL(fileURLWithPath: file.path + ".BACKUP.txt"); try Data("keep".utf8).write(to: backup)
        try await repository.resolveSavedMergeOutput(receipt)
        try receipt.validate()
        let indexed = try await repository.run(["show", ":" + path]).stdout
        let peerAfter = try await repository.run(["ls-files", "--stage", "-z", "--", "other.txt"]).stdout
        let headAfter = try await repository.run(["rev-parse", "HEAD"]).stdout
        let mergeAfter = try await repository.run(["rev-parse", "MERGE_HEAD"]).stdout
        XCTAssertEqual(indexed, output.content.bytes); XCTAssertEqual(peerAfter, peer)
        XCTAssertEqual(headAfter, head); XCTAssertEqual(mergeAfter, merge)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        for side in ["BASE", "LOCAL", "REMOTE"] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "." + side + ".txt")) }
        XCTAssertEqual(try Data(contentsOf: backup), Data("keep".utf8))
        let exactIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try await repository.resolveSavedMergeOutput(receipt)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), exactIndex)
    }
    func testExplicitResolveHandlesExistingTrackedNewIgnoredAndDeletedResultsWithoutWeakeningAutoAdd() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackedURL = root.appendingPathComponent(tracked), existing = try saved(trackedURL, text: "existing changed\n")
        try await repository.resolveSavedMergeOutput(MergeSavedOutputReceipt.capture(after: existing.content, at: trackedURL))
        let indexedTracked = try await repository.run(["show", ":" + tracked]).stdout
        XCTAssertEqual(indexedTracked, existing.content.bytes)
        try Data("*.out\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let newURL = root.appendingPathComponent("new 雪\t[one].out")
        let before = try MergeToolOutputTarget(capturing: newURL), new = try before.save(text: "ignored new result\n")
        let automatic = try XCTUnwrap(MergeNewOutputReceipt.capture(before: before.content, after: new.content, at: newURL))
        do { try await repository.addNewMergeOutput(automatic); XCTFail("AutoAdd unexpectedly force-added ignored data") } catch is GitFailure {}
        let explicit = try MergeSavedOutputReceipt.capture(after: new.content, at: newURL)
        try await repository.resolveSavedMergeOutput(explicit)
        let indexedNew = try await repository.run(["show", ":" + newURL.lastPathComponent]).stdout
        XCTAssertEqual(indexedNew, new.content.bytes)
        let deleted = try new.save(text: "", options: .init(emptyResult: .delete))
        let deletion = try explicit.refreshingSavedOutput(deleted.content)
        try await repository.resolveSavedMergeOutput(deletion)
        try deletion.validate()
        let removed = try await repository.run(["ls-files", "--stage", "-z", "--", newURL.lastPathComponent]).stdout
        XCTAssertTrue(removed.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
    }
    func testDefaultUnresolvedRefusalRequiresFreshPerAttemptConsentForMarkersAndIgnoredState() async throws {
        for markers in [false, true] {
            let (root, repository, path) = try await ConflictResolutionTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent(path)
            let text = markers ? "<<<<<<< Mine\nleft\n=======\nright\n>>>>>>> Theirs\n" : "ignored comparison conflict\n"
            let output = try saved(file, text: text)
            let receipt = try MergeSavedOutputReceipt.capture(after: output.content, at: file, unresolvedConflicts: !markers)
            XCTAssertTrue(receipt.unresolvedConflicts)
            let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            do { try await repository.resolveSavedMergeOutput(receipt); XCTFail("Unresolved saved output staged without consent") }
            catch TextConflictFailure.markers {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            try await repository.resolveSavedMergeOutput(receipt, allowUnresolvedConflicts: true)
            do { try await repository.resolveSavedMergeOutput(receipt); XCTFail("Prior Resolve consent persisted") }
            catch TextConflictFailure.markers {}
            let indexed = try await repository.run(["show", ":" + path]).stdout
            XCTAssertEqual(indexed, output.content.bytes)
        }
    }
    func testStaleReplacedDeletedAndForeignSavedTargetsCannotMutateTheIndex() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path), output = try saved(root.appendingPathComponent(path), text: "reviewed\n")
        let receipt = try MergeSavedOutputReceipt.capture(after: output.content, at: file)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("retired-result"))
        try output.content.bytes.write(to: file)
        do { try await repository.resolveSavedMergeOutput(receipt); XCTFail("Identical replacement borrowed a saved receipt") } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let current = try MergeToolOutputTarget(capturing: file)
        let deleted = try current.save(text: "", options: .init(emptyResult: .delete))
        let absence = try receipt.refreshingSavedOutput(deleted.content)
        try Data("appeared later".utf8).write(to: file)
        do { try await repository.resolveSavedMergeOutput(absence); XCTFail("Late appearance borrowed a deletion receipt") } catch FileComparisonEditFailure.changed {}
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitForeignResult-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        let other = try saved(outside, text: "outside\n"), foreign = try MergeSavedOutputReceipt.capture(after: other.content, at: outside)
        do { try await repository.resolveSavedMergeOutput(foreign); XCTFail("Foreign output staged") } catch FileComparisonEditFailure.unsupported {}
        let binary = root.appendingPathComponent("opaque-result")
        let opaque = Data([0, 255, 1]); try opaque.write(to: binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        let content = ComparisonFileContent(path: binary.path, revision: .workingTree, bytes: opaque, mode: "100644", permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
        let unreadable = try MergeSavedOutputReceipt.capture(after: content, at: binary)
        do { try await repository.resolveSavedMergeOutput(unreadable, allowUnresolvedConflicts: true); XCTFail("Warning consent bypassed unsupported binary text") } catch FileComparisonEditFailure.encoding {}
        let child = root.appendingPathComponent("nested-repository")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        _ = try await repository.run(["init", child.path])
        let nested = child.appendingPathComponent("result"), nestedOutput = try saved(child.appendingPathComponent("result"), text: "nested\n")
        let nestedReceipt = try MergeSavedOutputReceipt.capture(after: nestedOutput.content, at: nested)
        do { try await repository.resolveSavedMergeOutput(nestedReceipt); XCTFail("Outer repository borrowed a nested repository output") } catch ResolveFailure.outsideWorkingTree {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testFailedAndActuallyCancelledResolveKeepsSavedTargetForExplicitRetryWithoutRewrite() async throws {
        let (root, repository, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path), output = try saved(root.appendingPathComponent(path), text: "durable reviewed\n")
        let receipt = try MergeSavedOutputReceipt.capture(after: output.content, at: file)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        do { try await repository.resolveSavedMergeOutput(receipt); XCTFail("Externally locked index changed") } catch is GitFailure {}
        try receipt.validate(); try FileManager.default.removeItem(at: lock)
        let wrapper = root.appendingPathComponent("saved-output-git"), marker = root.appendingPathComponent("saved-output-stage-ready")
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = add ]; then
            /usr/bin/touch \(quote(marker.path))
            /bin/sleep 30
            exit 1
          fi
        done
        exec /usr/bin/git "$@"

        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let wrapped = GitRepository(root: root, executable: wrapper, askpass: nil), cancellation = OperationCancellation()
        let task = Task { try await wrapped.resolveSavedMergeOutput(receipt, cancellation: cancellation) }
        var reached = false
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: marker.path) { reached = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        cancellation.cancel()
        do { try await task.value; XCTFail("Cancelled private index stage published") } catch {}
        XCTAssertTrue(reached)
        try receipt.validate(); try output.validate()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        try await repository.resolveSavedMergeOutput(receipt)
        try output.validate()
        let indexed = try await repository.run(["show", ":" + path]).stdout
        XCTAssertEqual(indexed, output.content.bytes)
    }
    func testConcurrentRealIndexReplacementRefusesPrivatePublicationAndPreservesPeerChange() async throws {
        let (root, repository, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path), output = try saved(root.appendingPathComponent(path), text: "target reviewed\n")
        let receipt = try MergeSavedOutputReceipt.capture(after: output.content, at: file)
        let alternate = root.appendingPathComponent("peer-index"), actual = root.appendingPathComponent(".git/index")
        try Data(contentsOf: actual).write(to: alternate)
        try Data("peer concurrently staged\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        let wrapper = root.appendingPathComponent("race-output-git")
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = add ]; then
            /usr/bin/git "$@" || exit $?
            GIT_INDEX_FILE=\(quote(alternate.path)) /usr/bin/git -C \(quote(root.path)) add -- other.txt || exit $?
            /bin/mv \(quote(alternate.path)) \(quote(actual.path)) || exit $?
            exit 0
          fi
        done
        exec /usr/bin/git "$@"

        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let wrapped = GitRepository(root: root, executable: wrapper, askpass: nil)
        do { try await wrapped.resolveSavedMergeOutput(receipt); XCTFail("Replaced real index was overwritten") } catch MergeNewOutputFailure.indexChanged {}
        try receipt.validate()
        let remaining = try await repository.conflicts(paths: [path]); XCTAssertEqual(remaining.count, 1)
        let peer = try await repository.run(["show", ":other.txt"]).stdout
        XCTAssertEqual(peer, Data("peer concurrently staged\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.path + ".lock"))
    }
    func testCapturedKnownOutputEncodingControlsResolveRefreshAndMarkerGuard() async throws {
        let formats: [(ComparisonTextEncoding, String)] = [(.windows1252, "café"), (.utf16LE, "雪龍"), (.utf16BE, "雪龍")]
        for (encoding, text) in formats {
            let (root, repository, path) = try await GitPatchTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent(path)
            let output = try saved(file, text: text, encoding: encoding)
            // Actual post-save IO may not detect legacy bytes or a BOMless
            // UTF-16 Unicode-only file. The editor already owns its format.
            let observed = try MergeToolFileInput.read(at: file)
            let receipt = try MergeSavedOutputReceipt.capture(after: observed, at: file, encoding: encoding)
            try await repository.resolveSavedMergeOutput(receipt)
            let indexed = try await repository.run(["show", ":" + path]).stdout
            XCTAssertEqual(indexed, try encoding.encode(text))
            let markers = "<<<<<<< Mine\n" + text + "\n=======\nother\n>>>>>>> Theirs\n"
            _ = try output.save(text: markers, encoding: encoding)
            let marked = try MergeToolFileInput.read(at: file)
            let refreshed = try receipt.refreshingSavedOutput(marked, encoding: encoding)
            XCTAssertTrue(refreshed.unresolvedConflicts)
            // Known encoding remains state on a same-format refresh; it is not
            // remembered permission to stage unresolved marker text.
            let retained = try refreshed.refreshingSavedOutput(marked)
            XCTAssertTrue(retained.unresolvedConflicts)
            let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            do { try await repository.resolveSavedMergeOutput(retained); XCTFail("Known encoding lost unresolved marker classification") }
            catch TextConflictFailure.markers {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
            try await repository.resolveSavedMergeOutput(refreshed, allowUnresolvedConflicts: true)
            let resolved = try await repository.run(["show", ":" + path]).stdout
            XCTAssertEqual(resolved, try encoding.encode(markers))
        }
    }

}
