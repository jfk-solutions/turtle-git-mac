import XCTest
import AppKit
@testable import TurtleGitCore

final class ImageConflictTests: XCTestCase {
    func png(_ red: UInt8) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<2 { let offset = y * bitmap.bytesPerRow + x * 4; bitmap.bitmapData![offset] = red; bitmap.bitmapData![offset + 3] = 255 } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    func fixture(rebase: Bool = false, mixed: Bool = false) async throws -> (URL, GitRepository, [Data]) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        let bytes = [png(40),png(100),mixed ? Data("not an image".utf8) : png(200)], file = root.appendingPathComponent("picture.dat")
        try bytes[0].write(to: file); try await repo.stage(["picture.dat"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "side"])
        try bytes[2].write(to: file); try await repo.stage(["picture.dat"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try bytes[1].write(to: file); try await repo.stage(["picture.dat"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(rebase ? ["rebase", "side"] : ["merge", "side"]); XCTFail("Expected image conflict") } catch is GitFailure {}
        return (root,repo,bytes)
    }
    func testSelectEachSideLeavesStagesUntilExplicitResolution() async throws {
        let (root,repo,bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.dat")
        try Data("unrelated staged".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"])
        try Data("unrelated working".utf8).write(to: root.appendingPathComponent("other.txt"))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let loaded = try await repo.imageConflictDocument(path: "picture.dat")
        var document = try XCTUnwrap(loaded)
        XCTAssertEqual(document.contents[.base],bytes[0]); XCTAssertEqual(document.contents[.mine],bytes[1]); XCTAssertEqual(document.contents[.theirs],bytes[2])
        for (side,contents) in [(ImageConflictSide.base,bytes[0]),(.mine,bytes[1]),(.theirs,bytes[2])] {
            document = try await repo.selectImageConflict(document,side: side)
            XCTAssertEqual(try Data(contentsOf: file),contents)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")),index)
        }
        _ = try await repo.markImageConflictResolved(document)
        let conflicts = try await repo.conflicts(); XCTAssertTrue(conflicts.isEmpty)
        let staged = try await repo.run(["show",":picture.dat"]).stdout; XCTAssertEqual(staged,bytes[2])
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout; XCTAssertEqual(afterHead,head)
        let other = try await repo.run(["show",":other.txt"]).text; XCTAssertEqual(other,"unrelated staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")),"unrelated working")
    }
    func testChangedWorkingBytesAndPermissionsRejectSelectionAndResolution() async throws {
        let (root,repo,bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.dat")
        let loaded = try await repo.imageConflictDocument(path: "picture.dat")!, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try bytes[0].write(to: file)
        do { _ = try await repo.selectImageConflict(loaded,side: .theirs); XCTFail("Overwrote changed image") } catch ImageConflictFailure.changedWorkingFile {}
        let next = try await repo.imageConflictDocument(path: "picture.dat")!
        let saved = try await repo.selectImageConflict(next,side: .mine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],ofItemAtPath: file.path)
        do { _ = try await repo.markImageConflictResolved(saved); XCTFail("Resolved changed permissions") } catch ImageConflictFailure.changedWorkingFile {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")),index)
    }
    func testStaleStagesAndSymlinkWorkingFileDoNotOverwrite() async throws {
        let (root,repo,bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.dat"), outside = root.appendingPathComponent("outside.dat")
        let document = try await repo.imageConflictDocument(path: "picture.dat")!
        try bytes[0].write(to: outside); try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file,withDestinationURL: outside)
        do { _ = try await repo.selectImageConflict(document,side: .theirs); XCTFail("Overwrote symlink") } catch ImageConflictFailure.changedWorkingFile {}
        XCTAssertEqual(try Data(contentsOf: outside),bytes[0])
        try FileManager.default.removeItem(at: file); try bytes[1].write(to: file)
        _ = try await repo.resolveConflicts([document.entry],using: .mine)
        do { _ = try await repo.selectImageConflict(document,side: .theirs); XCTFail("Accepted resolved stages") } catch ResolveFailure.stale {}
        XCTAssertEqual(try Data(contentsOf: file),bytes[1])
    }
    func testRebaseUsesMineStageThreeAndTheirsStageTwo() async throws {
        let (root,repo,bytes) = try await fixture(rebase: true); defer { try? FileManager.default.removeItem(at: root) }
        let document = try await repo.imageConflictDocument(path: "picture.dat")!
        XCTAssertEqual(document.mineStage,3); XCTAssertEqual(document.theirsStage,2)
        XCTAssertEqual(document.contents[.mine],bytes[1]); XCTAssertEqual(document.contents[.theirs],bytes[2])
    }
    func testAddAddHasNoSelectableBaseAndPrecancelledWritesPreserveBytes() async throws {
        let (root,repo) = try await CommitSelectionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["commit","--allow-empty","-m","empty"])
        let file = root.appendingPathComponent("picture.dat")
        _ = try await repo.run(["switch","-c","side"])
        try png(200).write(to: file); try await repo.stage(["picture.dat"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch","main"])
        try png(100).write(to: file); try await repo.stage(["picture.dat"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge","side"]); XCTFail("Expected add/add") } catch is GitFailure {}
        let document = try await repo.imageConflictDocument(path: "picture.dat")!
        XCTAssertNil(document.contents[.base]); XCTAssertNil(document.image(.base))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: file)
        do { _ = try await repo.selectImageConflict(document,side: .base); XCTFail("Selected absent base") } catch ImageConflictFailure.unavailable {}
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.selectImageConflict(document,side: .theirs,cancellation: token); XCTFail("Cancelled selection wrote bytes") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.markImageConflictResolved(document,cancellation: token); XCTFail("Cancelled resolution staged") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf: file),bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")),index)
    }
    func testMixedImageAndNonImageStagesRemainInOtherConflictWorkflows() async throws {
        let (root,repo,_) = try await fixture(mixed: true); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let document = try await repo.imageConflictDocument(path: "picture.dat")
        XCTAssertNil(document)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")),before)
    }

}
