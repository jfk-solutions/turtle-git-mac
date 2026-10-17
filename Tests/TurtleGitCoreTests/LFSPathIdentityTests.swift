// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class LFSPathIdentityTests: XCTestCase {
    let a = "caf\u{00e9}.bin", b = "cafe\u{0301}.bin"
    func testParsedLockAndResultIdentityAndOwnerClipboardAreExact() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["id":"1","path":a,"owner":["name":"Alice"]],
            ["id":"2","path":b,"owner":["name":"Bob"]]])
        let locks = try LFSLock.parse(data)
        XCTAssertEqual(locks.map { Data($0.path.utf8) }, [Data(a.utf8),Data(b.utf8)])
        XCTAssertNotEqual(LFSLock(id:"1",path:a,owner:"Alice"),LFSLock(id:"1",path:b,owner:"Alice"))
        let first = LFSFileResult(path:a,success:true,output:"ok"), second = LFSFileResult(path:b,success:true,output:"ok")
        XCTAssertNotEqual(first,second); XCTAssertNotEqual(first.id,second.id)
        let owners = GitPathMap(locks.map { ($0.path,$0.owner) },uniquingKeysWith:{ old,_ in old })
        let rows = StatusEntry.parse(Data((" M " + a + "\0 M " + b + "\0").utf8))
        XCTAssertEqual(owners.count,2)
        XCTAssertEqual(StatusListClipboard.text(rows,root:URL(fileURLWithPath:"/fixture"),statistics:[:],copy:.column(.lfsOwner),lfsOwners:owners),"Alice\nBob\n")
        XCTAssertEqual(LFSLockMenu.actions(paths:[b],ownersVisible:true,lockedPaths:[a],ownershipKnown:true),[.lock])
        XCTAssertEqual(LFSLockMenu.actions(paths:[a,b],ownersVisible:true,lockedPaths:[a],ownershipKnown:true),[])
    }
    func testRemoteCommandsAndCancellationRetainBothSpellings() async throws {
        let (root,repo,log) = try await LFSLocksTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let before = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let batch = try await repo.setLFSLocked(paths:[a,b,a],locked:false,force:true)
        XCTAssertEqual(batch.files.map { Data($0.path.utf8) },[Data(a.utf8),Data(b.utf8)])
        let commands = try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode([String].self,from:Data($0.utf8)) }
        XCTAssertEqual(commands.count,2)
        XCTAssertEqual(commands.map { Data($0.last!.utf8) },[Data(a.utf8),Data(b.utf8)])
        XCTAssertTrue(commands.allSatisfy { $0.dropLast() == ["lfs","unlock","--force","--"] })
        let token = OperationCancellation()
        let partial = try await repo.setLFSLocked(paths:[b,a],locked:true,cancellation:token,onResult:{ _ in token.cancel() })
        XCTAssertTrue(partial.cancelled); XCTAssertEqual(partial.files.map { Data($0.path.utf8) },[Data(b.utf8)])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
    }
    func testFinderEligibilityUsesExactIndexAndHeadMembership() async throws {
        let (root,repo,_) = try await LFSLocksTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let hash = try await repo.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        func entry(_ path:String)->Data { Data(("100644 " + hash + "\t" + path + "\0").utf8) }
        _ = try await repo.run(["update-index","-z","--index-info"],input:entry(a)+entry(b))
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let accepted = try await repo.finderLFSPaths([b,a,b])
        XCTAssertEqual(accepted.map { Data($0.utf8) },[Data(b.utf8),Data(a.utf8)])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        _ = try await repo.run(["commit","-m","both index spellings"])
        // Deleting one spelling only from the index must retain HEAD eligibility.
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(("0 " + String(repeating:"0",count:40) + "\t" + b + "\0").utf8))
        let deleted = try await repo.finderLFSPaths([b]); XCTAssertEqual(deleted.map { Data($0.utf8) },[Data(b.utf8)])
        // A different canonical spelling never inherits another index path's eligibility.
        let c = "only-" + a, d = "only-" + b
        _ = try await repo.run(["update-index","-z","--index-info"],input:entry(c))
        do { _ = try await repo.finderLFSPaths([d]); XCTFail("Canonical neighbor was accepted as versioned") } catch LFSLocksFailure.selection {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
