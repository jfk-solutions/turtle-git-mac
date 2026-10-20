import XCTest
import Foundation
@testable import TurtleGitCore

final class FinderStatusOperationLeaseTests:XCTestCase {
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-finder-activity-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false);return url
    }
    func testIndependentOwnersHoldGlobalFenceUntilLastActualOwnerEnds() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        XCTAssertFalse(FinderStatusOperationLease.isBlocked(directory:dir))
        let one=try XCTUnwrap(FinderStatusOperationLease.begin(root:dir.appendingPathComponent("one"),directory:dir,notify:{}))
        let two=try XCTUnwrap(FinderStatusOperationLease.begin(root:dir.appendingPathComponent("two"),directory:dir,notify:{}))
        defer{one.end();two.end()}
        XCTAssertTrue(FinderStatusOperationLease.isBlocked(root:dir.appendingPathComponent("other"),directory:dir))
        one.end();one.end();XCTAssertTrue(FinderStatusOperationLease.isBlocked(directory:dir))
        two.end();XCTAssertFalse(FinderStatusOperationLease.isBlocked(directory:dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("commands.lock").path),"A persistent inode must not split live process locks")
    }
    func testCancellationAndDeinitializationCannotLeaveLiveOwnership() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try FinderStatusOperationLease.begin(directory:dir,cancellation:token,notify:{}))
        XCTAssertFalse(FinderStatusOperationLease.isBlocked(directory:dir))
        var lease=try FinderStatusOperationLease.begin(directory:dir,notify:{})
        withExtendedLifetime(lease) {XCTAssertNotNil(lease);XCTAssertTrue(FinderStatusOperationLease.isBlocked(directory:dir))}
        lease=nil;XCTAssertFalse(FinderStatusOperationLease.isBlocked(directory:dir))
    }
    func testInvalidFenceDoesNotFollowLinksOrClaimUnblockedStatus() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let target=dir.appendingPathComponent("other"),fence=dir.appendingPathComponent("commands.lock")
        try Data("untouched".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:fence,withDestinationURL:target)
        XCTAssertTrue(FinderStatusOperationLease.isBlocked(directory:dir))
        XCTAssertThrowsError(try FinderStatusOperationLease.begin(directory:dir,notify:{}))
        XCTAssertEqual(try Data(contentsOf:target),Data("untouched".utf8))
        try FileManager.default.removeItem(at:fence)
        try FileManager.default.linkItem(at:target,to:fence)
        XCTAssertTrue(FinderStatusOperationLease.isBlocked(directory:dir))
        XCTAssertThrowsError(try FinderStatusOperationLease.begin(directory:dir,notify:{}))
    }
    func testChildProcessDeathReleasesKernelFenceWithoutPIDOrAgeRecovery() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let lease=try XCTUnwrap(FinderStatusOperationLease.begin(directory:dir,notify:{}));lease.end()
        let child=Process(),output=Pipe(),errors=Pipe();var launched=false
        child.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        child.arguments=["-c","import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_SH); print('ready',flush=True); time.sleep(30)",dir.appendingPathComponent("commands.lock").path]
        child.standardOutput=output;child.standardError=errors
        let timeout=DispatchWorkItem {if child.isRunning{child.terminate()}}
        defer{timeout.cancel();if launched {if child.isRunning{child.terminate()};child.waitUntilExit()};try? output.fileHandleForReading.close();try? errors.fileHandleForReading.close()}
        try child.run();launched=true;DispatchQueue.global().asyncAfter(deadline:.now()+5,execute:timeout)
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount:6),Data("ready\n".utf8))
        XCTAssertTrue(FinderStatusOperationLease.isBlocked(directory:dir))
        child.terminate();child.waitUntilExit();XCTAssertFalse(FinderStatusOperationLease.isBlocked(directory:dir))
    }
    func testInspectionCommandsNeverBlockTheirOwnCollectorsButMutationsDo() {
        for arguments in [["status","--porcelain=v2"],["turtlegit-finder-status"],["turtlegit-local-refs"],["turtlegit-single-commit"],["-c","core.precomposeunicode=false","ls-files","-z"],["config","--get","core.ignorecase"],["branch","--show-current"],["submodule","status"],["worktree","list"]] {
            XCTAssertFalse(FinderStatusOperationLease.isCommandActivity(arguments),arguments.joined(separator:" "))
        }
        for arguments in [["commit","-m","test"],["add","--","path"],["turtlegit-prepare-index"],["config","--local","core.ignorecase","true"],["branch","-D","branch"],["custom-alias"],["-c","alias.status=reset","custom-alias"]] {
            XCTAssertTrue(FinderStatusOperationLease.isCommandActivity(arguments),arguments.joined(separator:" "))
        }
    }
}
