// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class AutomaticStatusReadTests:XCTestCase {
    private struct Witness:Equatable {
        let bytes:Data,inode:UInt64,modifiedSeconds:Int,modifiedNanoseconds:Int,changedSeconds:Int,changedNanoseconds:Int
        init(_ url:URL)throws {
            var info=stat();guard lstat(url.path,&info)==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            bytes=try Data(contentsOf:url);inode=UInt64(info.st_ino)
            modifiedSeconds=info.st_mtimespec.tv_sec;modifiedNanoseconds=info.st_mtimespec.tv_nsec
            changedSeconds=info.st_ctimespec.tv_sec;changedNanoseconds=info.st_ctimespec.tv_nsec
        }
    }
    private final class Events:@unchecked Sendable {
        private let lock=NSLock();private var values:[RepositoryFileEvent]=[]
        func append(_ incoming:[RepositoryFileEvent]) {lock.lock();values += incoming;lock.unlock()}
        func contains(_ name:String)->Bool {lock.lock();defer{lock.unlock()};return values.contains{URL(fileURLWithPath:$0.path).lastPathComponent==name}}
        func take()->[RepositoryFileEvent] {lock.lock();defer{lock.unlock()};let result=values;values=[];return result}
    }
    private func wait(_ condition:()->Bool)async throws {
        for _ in 0..<500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Actual private FSEvents stream did not deliver its boundary");throw NSError(domain:"AutomaticStatusReadTests",code:1)
    }
    private func fixture()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-automatic-status-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable,askpass:nil,diffDetection:.init(percentage:50),libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Automatic status QA"),("user.email","status@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.fsmonitor","false"),("core.untrackedCache","false")] {_=try await repo.run(["config",key,value])}
        for path in ["tracked.txt","removed.txt"] {try Data("before\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(["."]);_=try await repo.commit(message:"private status base")
        // Force Git to inspect matching contents instead of trusting cached stat.
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_000_000_000)],ofItemAtPath:root.appendingPathComponent("tracked.txt").path)
        return(root,repo)
    }
    func testAutomaticStatusAndWorkingTreeReadsPreserveIndexAndSeeExternalEdits()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let index=root.appendingPathComponent(".git/index"),before=try Witness(index)
        for _ in 0..<3 {
            let changes=try await repo.status(readPolicy:.automatic)
            XCTAssertTrue(changes.isEmpty)
            XCTAssertEqual(try Witness(index),before,"status(readPolicy:automatic) rewrote the index")
            let workingFiles=try await repo.workingTreeFiles()
            XCTAssertEqual(try Witness(index),before,"workingTreeFiles display diff rewrote the index")
            let stagedFiles=try await repo.stagingFiles(staged:true)
            XCTAssertEqual(try Witness(index),before,"stagingFiles(staged:true) display diff rewrote the index")
            let unstagedFiles=try await repo.stagingFiles(staged:false)
            XCTAssertEqual(try Witness(index),before,"stagingFiles(staged:false) display diff rewrote the index")
            XCTAssertTrue(workingFiles.isEmpty && stagedFiles.isEmpty && unstagedFiles.isEmpty)
            let history=try await repo.workingTreeHistory()
            XCTAssertTrue(history?.files.isEmpty == true && history?.unversioned.isEmpty == true)
            XCTAssertEqual(try Witness(index),before,"workingTreeHistory Log observation rewrote the index")
            let selectedFile=CommitFile(path:"tracked.txt",oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
            let selectedDiff=try await repo.workingTreeFileDiffData(files:[selectedFile])
            XCTAssertTrue(selectedDiff.isEmpty)
            XCTAssertEqual(try Witness(index),before,"workingTreeFileDiffData Log observation rewrote the index")
            let rows=try await repo.workingTreeStatus(readPolicy:.automatic)
            XCTAssertEqual(GitPathSet(rows.map(\.id)),GitPathSet(["tracked.txt","removed.txt"]))
            XCTAssertEqual(try Witness(index),before)
        }
        try Data("after!\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("removed.txt"))
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("new.txt"))
        let actual=try await repo.status(readPolicy:.automatic)
        XCTAssertEqual(actual.first{$0.path=="tracked.txt"}?.state,.modified)
        XCTAssertEqual(actual.first{$0.path=="removed.txt"}?.state,.deleted)
        XCTAssertEqual(actual.first{$0.path=="new.txt"}?.state,.untracked)
        let freshWorking=try await repo.workingTreeFiles(),freshStaged=try await repo.stagingFiles(staged:true),freshUnstaged=try await repo.stagingFiles(staged:false)
        XCTAssertEqual(freshWorking.first{$0.path=="tracked.txt"}?.action,"M")
        XCTAssertEqual(freshWorking.first{$0.path=="removed.txt"}?.action,"D")
        XCTAssertEqual(freshUnstaged.first{$0.path=="tracked.txt"}?.action,"M")
        XCTAssertTrue(freshStaged.isEmpty)
        let changedHistory=try await repo.workingTreeHistory()
        XCTAssertEqual(changedHistory?.files.first{$0.path=="tracked.txt"}?.action,"M")
        let changedPatch=try await repo.workingTreeFileDiffData(files:freshWorking)
        XCTAssertTrue(String(decoding:changedPatch,as:UTF8.self).contains("+after!"))
        XCTAssertTrue(String(decoding:changedPatch,as:UTF8.self).contains("-before"))
        XCTAssertEqual(try Witness(index),before)
        try await realChangeVariants(root,repo)
    }
    private func realChangeVariants(_ root:URL,_ repo:GitRepository)async throws {
        for name in ["chmod.txt","type.txt","rename-old.txt"] {try Data("variant base\n".utf8).write(to:root.appendingPathComponent(name))}
        try Data([0,65,66,67]).write(to:root.appendingPathComponent("binary.dat"))
        let module=root.appendingPathComponent("module")
        try FileManager.default.createDirectory(at:module,withIntermediateDirectories:true)
        let child=GitRepository(root:module,executable:repo.executable,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await child.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Status child QA"),("user.email","child@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await child.run(["config",key,value])}
        try Data("child base\n".utf8).write(to:module.appendingPathComponent("file"));try await child.stage(["."]);_=try await child.commit(message:"child")
        try await repo.stage(["."]);_=try await repo.commit(message:"real diff variants")
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.appendingPathComponent("chmod.txt").path)
        try FileManager.default.removeItem(at:root.appendingPathComponent("type.txt"))
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("type.txt").path,withDestinationPath:"chmod.txt")
        try Data([0,88,89,90]).write(to:root.appendingPathComponent("binary.dat"))
        try FileManager.default.moveItem(at:root.appendingPathComponent("rename-old.txt"),to:root.appendingPathComponent("rename-new.txt"))
        _=try await repo.run(["add","-A","--","rename-old.txt","rename-new.txt"])
        try Data("child dirty\n".utf8).write(to:module.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_000_000_001)],ofItemAtPath:root.appendingPathComponent("tracked.txt").path)
        let index=root.appendingPathComponent(".git/index"),before=try Witness(index)
        let actual=try await repo.workingTreeFiles(),staged=try await repo.stagingFiles(staged:true),unstaged=try await repo.stagingFiles(staged:false)
        XCTAssertFalse(actual.contains{$0.path=="tracked.txt"},"Clean stat-only M survived display filtering")
        XCTAssertEqual(actual.first{$0.path=="binary.dat"}?.action,"M")
        XCTAssertTrue(actual.first{$0.path=="binary.dat"}?.hasStatistics==true && actual.first{$0.path=="binary.dat"}?.added==nil,"Binary -/- record was dropped")
        XCTAssertEqual(actual.first{$0.path=="chmod.txt"}?.action,"M");XCTAssertEqual(actual.first{$0.path=="chmod.txt"}?.added,0)
        XCTAssertEqual(actual.first{$0.path=="type.txt"}?.action,"T")
        XCTAssertTrue(actual.first{$0.path=="module"}?.isSubmodule==true);XCTAssertEqual(actual.first{$0.path=="module"}?.added,0)
        XCTAssertEqual(actual.first{$0.path=="rename-new.txt"}?.oldPath,"rename-old.txt")
        XCTAssertEqual(staged.first{$0.path=="rename-new.txt"}?.oldPath,"rename-old.txt")
        XCTAssertTrue(unstaged.contains{$0.path=="binary.dat"} && unstaged.contains{$0.path=="chmod.txt"} && unstaged.contains{$0.path=="module"})
        XCTAssertEqual(try Witness(index),before)
    }
    func testAutomaticReadsEmitNoIndexEventsAndExplicitRefreshStillPublishesIndex()async throws {
        if ProcessInfo.processInfo.environment["GIT_OPTIONAL_LOCKS"]=="0" {throw XCTSkip("Caller explicitly disables the existing optional index refresh positive control")}
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent(".git"),index=directory.appendingPathComponent("index"),before=try Witness(index),events=Events()
        let monitor=try RepositoryFileEventMonitor(roots:[directory],latency:0.02){events.append($0)};defer{monitor.stop()}
        try Data("start".utf8).write(to:directory.appendingPathComponent("qa-start"))
        try await wait{events.contains("qa-start")};_=events.take()
        for _ in 0..<3 {
            _=try await repo.status(readPolicy:.automatic)
            XCTAssertEqual(try Witness(index),before,"FSEvents range status rewrote index")
            _=try await repo.workingTreeStatus(readPolicy:.automatic)
            XCTAssertEqual(try Witness(index),before,"FSEvents range workingTreeStatus rewrote index")
            _=try await repo.workingTreeFiles()
            XCTAssertEqual(try Witness(index),before,"FSEvents range workingTreeFiles rewrote index")
            _=try await repo.stagingFiles(staged:true)
            XCTAssertEqual(try Witness(index),before,"FSEvents range staged display rewrote index")
            _=try await repo.stagingFiles(staged:false)
            XCTAssertEqual(try Witness(index),before,"FSEvents range unstaged display rewrote index")
            _=try await repo.workingTreeHistory()
            XCTAssertEqual(try Witness(index),before,"FSEvents range Log history rewrote index")
            let selectedFile=CommitFile(path:"tracked.txt",oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
            _=try await repo.workingTreeFileDiffData(files:[selectedFile])
            XCTAssertEqual(try Witness(index),before,"FSEvents range Log file diff rewrote index")
        }
        try Data("end".utf8).write(to:directory.appendingPathComponent("qa-end"))
        try await wait{events.contains("qa-end")}
        let automaticEvents=events.take().map{URL(fileURLWithPath:$0.path).lastPathComponent}
        XCTAssertFalse(automaticEvents.contains("index"),"Automatic observation emitted an index event: \(automaticEvents)")
        XCTAssertFalse(automaticEvents.contains("index.lock"),"Automatic observation acquired an index lock: \(automaticEvents)")
        XCTAssertEqual(try Witness(index),before)
        let explicit=try await repo.status(readPolicy:.refreshIndex)
        XCTAssertTrue(explicit.isEmpty)
        XCTAssertNotEqual(try Witness(index),before,"Explicit refresh positive control did not refresh stale index stats")
        try await wait{events.contains("index") || events.contains("index.lock")}
        let refreshed=try Witness(index)
        try Data("after!\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        let changed=try await repo.workingTreeHistory()
        let patch=try await repo.workingTreeFileDiffData(files:changed?.files ?? [])
        XCTAssertTrue(String(decoding:patch,as:UTF8.self).contains("+after!") && String(decoding:patch,as:UTF8.self).contains("-before"))
        XCTAssertEqual(try Witness(index),refreshed,"Fresh external Log diff refreshed index stats")
        XCTAssertFalse(FileManager.default.fileExists(atPath:index.path+".lock"))
    }
    func testFinderCollectorsRemainReadOnlyAndSeeLaterExternalChanges()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let index=root.appendingPathComponent(".git/index"),before=try Witness(index)
        let full=try await repo.collectFinderRepository(authorizedRoot:root)
        XCTAssertTrue(full.entries.isEmpty);XCTAssertEqual(try Witness(index),before)
        for mode in [FinderOverlayCacheMode.standard,.shell,.shellExtended] {
            let policy=FinderStatusPolicy(cacheMode:mode)
            let collected=try await repo.collectFinderOverlayRepository(authorizedRoot:root,policy:policy)
            XCTAssertEqual(collected.snapshots.first?.states[root.path+"/tracked.txt"],.normal)
            XCTAssertEqual(try Witness(index),before)
        }
        try Data("after!\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        let changed=try await repo.collectFinderRepository(authorizedRoot:root,policy:.init())
        XCTAssertEqual(changed.entries.first{$0.path=="tracked.txt"}?.state,.modified)
        XCTAssertEqual(changed.snapshots.first?.overlayEntries?[root.path+"/tracked.txt"],.modified)
        XCTAssertEqual(try Witness(index),before)
    }
    func testCancelledAutomaticCollectionLeavesOriginalIndexAndNoLock()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let index=root.appendingPathComponent(".git/index"),before=try Witness(index),token=OperationCancellation();token.cancel()
        do {_=try await repo.workingTreeStatus(readPolicy:.automatic,cancellation:token);XCTFail("Cancelled automatic status succeeded")}catch OperationCancellationFailure.cancelled {} catch {XCTFail("Unexpected cancellation result: \(error)")}
        do {_=try await repo.collectFinderRepository(authorizedRoot:root,cancellation:token);XCTFail("Cancelled Finder collection succeeded")}catch OperationCancellationFailure.cancelled {} catch {XCTFail("Unexpected cancellation result: \(error)")}
        XCTAssertEqual(try Witness(index),before);XCTAssertFalse(FileManager.default.fileExists(atPath:index.path+".lock"))
    }
}
