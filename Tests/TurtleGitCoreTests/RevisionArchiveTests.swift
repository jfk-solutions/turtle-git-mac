import XCTest
@testable import TurtleGitCore

final class RevisionArchiveTests: XCTestCase {
    private func unzip(_ archive: URL, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments + [archive.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0); return bytes
    }
    func testZipUsesCommittedBytesArchiveAttributesAndDirectoryScope() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "nested 雪"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        try Data([0, 255, 10]).write(to: root.appendingPathComponent(folder + "/binary"))
        try Data("excluded".utf8).write(to: root.appendingPathComponent(folder + "/private"))
        try Data("$Format:%H$\n".utf8).write(to: root.appendingPathComponent(folder + "/version"))
        try Data("private export-ignore\nversion export-subst\n".utf8).write(to: root.appendingPathComponent(folder + "/.gitattributes"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appendingPathComponent(folder + "/run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(folder + "/run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(folder + "/link").path, withDestinationPath: "binary")
        try await repo.stage([folder]); _ = try await repo.commit(message: "archive fixture")
        _ = try await repo.run(["tag", "-a", "archive-tag", "-m", "tag"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("dirty".utf8).write(to: root.appendingPathComponent(folder + "/binary"))
        let scoped = root.appendingPathComponent("scoped.zip")
        _ = try await repo.archiveRevision("archive-tag", directory: folder, to: scoped)
        let names = String(decoding: try unzip(scoped, ["-Z1"]), as: UTF8.self)
        XCTAssertTrue(names.contains("binary\n")); XCTAssertFalse(names.contains(folder)); XCTAssertFalse(names.contains("private"))
        let extract = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: false)
        // unzip's archive precedes extraction switches; use a direct process.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", scoped.path, "-d", extract.path]; try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: extract.appendingPathComponent("binary")), Data([0, 255, 10]))
        XCTAssertEqual(try String(contentsOf: extract.appendingPathComponent("version"), encoding: .utf8), head + "\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extract.appendingPathComponent("link").path), "binary")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: extract.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let whole = root.appendingPathComponent("whole.zip")
        _ = try await repo.archiveRevision(to: whole)
        let listing = String(decoding: try unzip(whole, ["-Z1"]), as: UTF8.self)
        XCTAssertTrue(listing.contains("nested ")); XCTAssertTrue(listing.contains("/binary"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(folder + "/binary"), encoding: .utf8), "dirty")
    }
    func testFailuresCancellationAndBareArchivePreserveDestination() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.zip"), original = Data("keep me".utf8)
        try original.write(to: output)
        for revision in ["--help", "missing", ""] {
            do { _ = try await repo.archiveRevision(revision, to: output); XCTFail("Invalid revision accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
        for directory in ["../", "/", "missing", ".git"] {
            do { _ = try await repo.archiveRevision(directory: directory, to: output); XCTFail("Invalid scope accepted") } catch {}
        }
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.archiveRevision(to: output, cancellation: cancellation); XCTFail("Cancelled export ran") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: output), original)
        for destination in [root.appendingPathComponent(".git/output.zip"), root] {
            do { _ = try await repo.archiveRevision(to: destination); XCTFail("Metadata or directory destination accepted") } catch {}
        }
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot)
        do { _ = try await bare.archiveRevision(to: bareRoot.appendingPathComponent("output.zip")); XCTFail("Bare metadata accepted") } catch {}
        _ = try await bare.archiveRevision(to: output)
        XCTAssertNotEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(try unzip(output, ["-Z1"]).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".TurtleGitArchive-") })
    }
}
