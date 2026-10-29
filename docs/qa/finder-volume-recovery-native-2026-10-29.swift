// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import Darwin
import TurtleGitCore

@MainActor @main struct FinderVolumeRecoveryVerification {
    static var diagnostic:(()->Void)?
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws{if !value{throw Failure(description:"\(line): "+text)}}
    static func unwrap<T>(_ value:T?,_ text:String)throws->T{guard let value else{throw Failure(description:text)};return value}
    static func wait(_ text:String,line:Int = #line,_ ready:()->Bool)async throws{
        for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        diagnostic?();fflush(stdout)
        throw Failure(description:"\(line): "+text)
    }
    final class Bookmarks:RepositoryBookmarkProvider,@unchecked Sendable {
        private let lock=NSLock();private var denied=Set<String>(),entered:[String:Int]=[:],exited:[String:Int]=[:],moves:[String:URL]=[:]
        func create(for url:URL)throws->Data{Data(url.standardizedFileURL.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{
            let path=String(decoding:data,as:UTF8.self);lock.lock();let unavailable=denied.contains(path),moved=moves[path];lock.unlock()
            if unavailable{throw RepositoryAccessFailure.securityScopeUnavailable}
            return ResolvedBookmark(url:moved ?? URL(fileURLWithPath:path,isDirectory:true),stale:moved != nil)
        }
        func startAccessing(_ url:URL)->Bool{lock.lock();defer{lock.unlock()};let path=url.standardizedFileURL.path;if denied.contains(path){return false};entered[path,default:0]+=1;return true}
        func stopAccessing(_ url:URL){lock.lock();defer{lock.unlock()};exited[url.standardizedFileURL.path,default:0]+=1}
        func deny(_ url:URL,_ value:Bool){lock.lock();defer{lock.unlock()};if value{denied.insert(url.standardizedFileURL.path)}else{denied.remove(url.standardizedFileURL.path)}}
        func move(_ old:URL,to new:URL){lock.lock();defer{lock.unlock()};moves[old.standardizedFileURL.path]=new}
        func active(_ url:URL)->Int{lock.lock();defer{lock.unlock()};let path=url.standardizedFileURL.path;return entered[path,default:0]-exited[path,default:0]}
        var balanced:Bool{lock.lock();defer{lock.unlock()};return entered==exited}
    }
    @MainActor final class AuthorityGate {
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?,entered=0,holding=true
        weak var lease:RepositoryAccessLease?
        func resolve(_ request:RepositoryAuthorityRequest,_ scoped:Bool,_ cancellation:OperationCancellation)async throws->RepositoryAuthorityRequest.Authority{
            let authority=try await Task.detached{try request.resolve(requireSecurityScope:scoped,cancellation:cancellation)}.value
            if holding{entered+=1;token=cancellation;lease=authority.primary;await withCheckedContinuation{reply=$0}}
            // Deliberately return real late authority even after cancellation:
            // the manager must fence it, without trusting this injected reader.
            return authority
        }
        func release(){holding=false;reply?.resume();reply=nil}
    }
    @MainActor final class Clock {
        var pending:[CheckedContinuation<Void,Error>]=[],values:[TimeInterval]=[]
        func delay(_ value:TimeInterval)async throws{values.append(value);try await withCheckedThrowingContinuation{pending.append($0)}}
        func fire(){if !pending.isEmpty{pending.removeFirst().resume()}}
        func release(){for item in pending{item.resume()};pending=[]}
    }
    @MainActor final class Context {
        let folder:URL,git:URL,provider=Bookmarks(),permissions:RepositoryAccessStore,cache:FinderSnapshotStore,catalog:URL
        let volumes=NotificationCenter()
        var roots:[URL]=[],managers:[FinderWatchManager]=[],gates:[AuthorityGate]=[],recoveries:[FinderVolumeRecovery]=[],clocks:[Clock]=[]
        var heads:[Data]=[],indexes:[Data]=[]
        var wrapper:URL{folder.appendingPathComponent("held-helper")}
        var trace:URL{folder.appendingPathComponent("calls.log")}
        init(folder:URL,git:URL)throws{
            self.folder=folder;self.git=git
            permissions=try RepositoryAccessStore(storageURL:folder.appendingPathComponent("private/watches.json"),provider:provider)
            cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"));catalog=folder.appendingPathComponent("shared/registered-roots.json")
        }
        func setup()async throws{
            for name in ["Returning root","Healthy root","Renewed root","Archive renewed root"]{
                let root=folder.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false));_=try await repo.run(["init","--template=","-b","main"])
                for(key,value)in[("user.name","Recovery QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
                try Data("baseline\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"Private recovery baseline")
                roots.append(root);heads.append(try await repo.run(["rev-parse","HEAD"]).stdout);indexes.append(try Data(contentsOf:root.appendingPathComponent(".git/index")))
            }
            func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="""
            #!/bin/sh
            task_root="$PWD"
            task_next=false
            for task_arg in "$@"; do
              if [ "$task_next" = true ]; then task_root="$task_arg"; task_next=false; fi
              if [ "$task_arg" = -C ]; then task_next=true; fi
            done
            printf '%s\\n' "$task_root" >> \(quote(trace.path))
            exec \(quote(git.path)) "$@"
            """
            try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        }
        func manager(store:RepositoryAccessStore?=nil)->FinderWatchManager{
            let executable=wrapper
            let value=FinderWatchManager(permissions:store ?? permissions,cache:cache,requireScope:true,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:executable,libgit2Configuration:.init(enabled:false))},registeredRootsURL:catalog,volumeNotificationCenter:volumes,notify:{})
            managers.append(value);return value
        }
        func live()->FinderSnapshot?{FinderSnapshot.readLive(from:cache.url)}
        func calls(_ root:URL)throws->Int{
            let values=(try? String(contentsOf:trace)) ?? ""
            let expected=root.resolvingSymlinksInPath().standardizedFileURL.path
            return values.split(separator:"\n").filter{URL(fileURLWithPath:String($0)).resolvingSymlinksInPath().standardizedFileURL.path==expected}.count
        }
        func hold(_ manager:FinderWatchManager,id:UUID)->AuthorityGate{
            let gate=AuthorityGate();gates.append(gate)
            manager.resolveAuthority={request,scoped,token in
                if request.record.id==id{return try await gate.resolve(request,scoped,token)}
                return try await Task.detached{try request.resolve(requireSecurityScope:scoped,cancellation:token)}.value
            }
            return gate
        }
        func unavailable(store:RepositoryAccessStore?=nil)->FinderWatchManager{
            provider.deny(roots[0],true);let value=manager(store:store);value.restore();return value
        }
        func readyUnavailable(_ manager:FinderWatchManager)async throws{
            try await wait("Saved unavailable root did not isolate healthy watch"){manager.pendingOperations==0 && manager.rows.contains{$0.path==self.roots[0].path && $0.status.contains("unavailable")} && manager.rows.contains{$0.path==self.roots[1].path && $0.status=="Updated"} && self.live()?.roots.contains(self.roots[1].path)==true}
        }
        func clean()async{
            gates.forEach{$0.release()};clocks.forEach{$0.release()};recoveries.forEach{$0.retire()}
            for item in recoveries{await item.settle()}
            for item in managers{await item.shutdown()}
        }
        func preserved()async throws{
            for i in roots.indices{
                let repo=GitRepository(root:roots[i],executable:git,libgit2Configuration:.init(enabled:false))
                try require(try await repo.run(["rev-parse","HEAD"]).stdout==heads[i],"Volume recovery changed repository HEAD")
                try require(try Data(contentsOf:roots[i].appendingPathComponent(".git/index"))==indexes[i],"Volume recovery changed raw index")
                try require(try Data(contentsOf:roots[i].appendingPathComponent("file.txt"))==Data("baseline\n".utf8),"Volume recovery changed working bytes")
            }
        }
    }
    static func scheduler(_ c:Context)async throws{
        let center=NotificationCenter(),clock=Clock();c.clocks.append(clock)
        var calls=0
        let recovery=FinderVolumeRecovery(retry:{calls+=1;return false},notificationCenter:center,delays:[1,3],delay:{try await clock.delay($0)})
        c.recoveries.append(recovery)
        center.post(name:NSWorkspace.didMountNotification,object:nil)
        try await wait("Mount notification did not schedule private recovery"){clock.pending.count==1}
        recovery.volumeChanged();recovery.volumeChanged();recovery.volumeChanged()
        clock.fire();try await wait("Coalesced queued cycle did not start"){calls==1 && clock.pending.count==1}
        clock.fire();await recovery.settle()
        try require(calls==2 && clock.values==[1,1] && !recovery.isPending,"Volume event burst was lost or produced unbounded duplicate cycles")
        recovery.volumeChanged();try await wait("New volume generation did not schedule"){clock.pending.count==1}
        recovery.retire();clock.release();await recovery.settle()
        try require(calls==2 && !recovery.isPending,"Retired queued retry executed")
        center.post(name:NSWorkspace.didMountNotification,object:nil)
        try require(!recovery.isPending,"Retired notification subscription revived recovery")
        let retryClock=Clock();c.clocks.append(retryClock);var attempts=0
        let bounded=FinderVolumeRecovery(retry:{attempts+=1;return true},notificationCenter:center,delays:[1,3],delay:{try await retryClock.delay($0)})
        c.recoveries.append(bounded);bounded.volumeChanged()
        for count in 1...2{try await wait("Bounded backoff step absent"){retryClock.pending.count==1};retryClock.fire();try await wait("Bounded retry did not execute"){attempts==count}}
        await bounded.settle();try require(attempts==2 && retryClock.values==[1,3] && !bounded.isPending,"Recovery exceeded bounded retry sequence")
        bounded.retire()
    }
    static func verify(_ c:Context)async throws{
        let initial=c.manager();await initial.add(c.roots[0]);await initial.add(c.roots[1])
        try await wait("Initial explicit roots did not publish"){initial.pendingOperations==0 && initial.rows.count==2 && initial.rows.allSatisfy{$0.status=="Updated"}}
        await initial.shutdown();try await wait("Initial scopes did not drain"){c.provider.balanced}
        let deferred=c.manager(),beforeDeferred=try c.calls(c.roots[1])
        _=await deferred.recoverUnavailableRepositories()
        try require(deferred.pendingOperations==0 && c.calls(c.roots[1])==beforeDeferred && c.provider.balanced && c.live()?.roots.isEmpty==true,"Deferred action router crawled unrelated saved roots on recovery")
        await deferred.shutdown()
        let parked=c.folder.appendingPathComponent("temporarily-disconnected",isDirectory:true)
        try FileManager.default.moveItem(at:c.roots[0],to:parked)
        let manager=c.unavailable();try await c.readyUnavailable(manager)
        let healthyCalls=try c.calls(c.roots[1])
        try FileManager.default.moveItem(at:parked,to:c.roots[0]);c.provider.deny(c.roots[0],false)
        c.volumes.post(name:NSWorkspace.didMountNotification,object:nil)
        try await wait("Returning root did not recover without manual Refresh"){manager.pendingOperations==0 && manager.rows.allSatisfy{$0.status=="Updated"} && c.live()?.roots.contains(c.roots[0].path)==true && !manager.recoveryPending}
        try require(c.live()?.roots.contains(c.roots[1].path)==true && c.calls(c.roots[1])==healthyCalls,"Recovery rescanned or retired healthy root")
        // This root already owns a live session. Its monitor must notice a
        // disappearance; reconnect must then resolve a renewed bookmark rather
        // than continuing to reuse the failed session's old repository path.
        let oldLiveRoot=c.roots[0],liveID=try unwrap(c.permissions.repositories.first{$0.lastKnownPath==oldLiveRoot.path}?.id,"No live saved root")
        let absent=c.folder.appendingPathComponent("live-disconnected",isDirectory:true),moved=c.folder.appendingPathComponent("Moved returning root",isDirectory:true)
        c.provider.deny(oldLiveRoot,true);try FileManager.default.moveItem(at:oldLiveRoot,to:absent)
        c.volumes.post(name:NSWorkspace.didUnmountNotification,object:nil)
        try await wait("Published root disappearance did not mark its existing session unavailable"){manager.pendingOperations==0 && manager.rows.contains{$0.id==liveID && !$0.status.hasPrefix("Updated") && $0.status != "Waiting"}}
        try FileManager.default.moveItem(at:absent,to:moved);c.provider.move(oldLiveRoot,to:moved);c.provider.deny(oldLiveRoot,false);c.roots[0]=moved
        c.volumes.post(name:NSWorkspace.didRenameVolumeNotification,object:nil)
        try await wait("Previously published moved volume did not renew live root"){manager.pendingOperations==0 && !manager.recoveryPending && manager.rows.contains{$0.id==liveID && $0.path==moved.path && $0.status=="Updated"} && c.live()?.roots.contains(moved.path)==true}
        let movedCatalog=try FinderRegisteredRoots.read(from:c.catalog)
        try require(c.live()?.roots.contains(oldLiveRoot.path) != true && movedCatalog.root(for:oldLiveRoot)==nil && movedCatalog.root(for:moved)?.id==liveID && c.provider.active(oldLiveRoot)==0,"Moved recovery retained ghost root, catalog or old lease")
        try require(c.live()?.roots.contains(c.roots[1].path)==true && c.calls(c.roots[1])==healthyCalls,"Live moved-root recovery rescanned or retired healthy peer")
        await manager.shutdown()
        // Actual accepted leases remain owned while a late immutable result is
        // held; Remove/Renew must invalidate its captured saved-record witness.
        let removed=c.unavailable();try await c.readyUnavailable(removed)
        let id=try unwrap(c.permissions.repositories.first{$0.lastKnownPath==c.roots[0].path}?.id,"No saved returning watch")
        c.provider.deny(c.roots[0],false);let gate=c.hold(removed,id:id)
        let read=Task{await removed.recoverUnavailableRepositories()}
        try await wait("Remove race did not hold real resolved scope"){gate.reply != nil && gate.lease != nil && removed.pendingOperations>0}
        await removed.remove(id);gate.release();_=await read.value
        try await wait("Removed late authority did not drain"){removed.pendingOperations==0 && c.provider.active(c.roots[0])==0}
        try require(!removed.rows.contains{$0.id==id} && c.live()?.roots.contains(c.roots[0].path) != true && c.live()?.roots.contains(c.roots[1].path)==true,"Late recovery revived removed watch or lost peer")
        await removed.shutdown()
        let renewedID=try c.permissions.remember(c.roots[0]).id
        let renewed=c.unavailable();try await c.readyUnavailable(renewed)
        c.provider.deny(c.roots[0],false);let renewedGate=c.hold(renewed,id:renewedID)
        let renewalRead=Task{await renewed.recoverUnavailableRepositories()}
        try await wait("Renew race did not hold real authority"){renewedGate.reply != nil && renewedGate.lease != nil}
        await renewed.add(c.roots[2],replacing:renewedID);renewedGate.release();_=await renewalRead.value
        try await wait("Renewed watch did not settle at replacement root"){renewed.pendingOperations==0 && renewed.rows.contains{$0.id==renewedID && $0.path==c.roots[2].path && $0.status=="Updated"}}
        try require(c.live()?.roots.contains(c.roots[0].path) != true && c.live()?.roots.contains(c.roots[2].path)==true && c.provider.active(c.roots[0])==0,"Late old grant replaced renewed watch")
        await renewed.shutdown()
        _=try c.permissions.remember(c.roots[0]);let closing=c.unavailable();try await c.readyUnavailable(closing)
        let closingID=try unwrap(c.permissions.repositories.first{$0.lastKnownPath==c.roots[0].path}?.id,"No shutdown watch")
        c.provider.deny(c.roots[0],false);let closingGate=c.hold(closing,id:closingID)
        let closingRead=Task{await closing.recoverUnavailableRepositories()}
        try await wait("Shutdown race did not retain prepared grant"){closingGate.reply != nil && closingGate.lease != nil}
        let shutdown=Task{await closing.shutdown()}
        try await wait("Shutdown did not cancel owned recovery"){closingGate.token?.isCancelled==true}
        try require(closing.pendingOperations>0 && c.provider.active(c.roots[0])>0,"Shutdown released authority before actual worker drain")
        closingGate.release();_=await closingRead.value;await shutdown.value
        try await wait("Shutdown did not balance real scopes"){c.provider.balanced}
        try require(c.live()?.roots.isEmpty==true,"Retired manager published late recovered roots")
        // A distinct store owner changes the authoritative archive while this
        // manager still has an old in-memory record and a prepared real lease.
        let independent=c.unavailable();try await c.readyUnavailable(independent)
        let independentID=try unwrap(c.permissions.repositories.first{$0.lastKnownPath==c.roots[0].path}?.id,"No independent removal target")
        c.provider.deny(c.roots[0],false);let independentGate=c.hold(independent,id:independentID)
        let independentRead=Task{await independent.recoverUnavailableRepositories()}
        try await wait("Independent removal did not hold authority"){independentGate.reply != nil}
        let peer=try RepositoryAccessStore(storageURL:c.permissions.storageURL,provider:c.provider)
        try peer.forget(independentID);independentGate.release();_=await independentRead.value
        try await wait("Independent removed authority did not drain"){independent.pendingOperations==0 && c.provider.active(c.roots[0])==0}
        let afterRemove=try RepositoryAccessStore(storageURL:c.permissions.storageURL,provider:c.provider)
        try require(!afterRemove.repositories.contains{$0.id==independentID} && c.live()?.roots.contains(c.roots[0].path) != true,"Stale manager overwrote independent archive removal or attached old root")
        await independent.shutdown()
        let archiveID=try peer.remember(c.roots[0]).id
        let ownerStore=try RepositoryAccessStore(storageURL:c.permissions.storageURL,provider:c.provider)
        let archiveRenew=c.unavailable(store:ownerStore);try await c.readyUnavailable(archiveRenew)
        c.provider.deny(c.roots[0],false);let archiveGate=c.hold(archiveRenew,id:archiveID)
        let archiveRead=Task{await archiveRenew.recoverUnavailableRepositories()}
        try await wait("Independent renewal did not hold old authority"){archiveGate.reply != nil}
        let renewPeer=try RepositoryAccessStore(storageURL:c.permissions.storageURL,provider:c.provider)
        _=try renewPeer.replace(archiveID,with:c.roots[3]);archiveGate.release();_=await archiveRead.value
        try await wait("Independent renewed authority did not drain"){archiveRenew.pendingOperations==0 && c.provider.active(c.roots[0])==0}
        let afterRenew=try RepositoryAccessStore(storageURL:c.permissions.storageURL,provider:c.provider)
        try require(afterRenew.repositories.first{$0.id==archiveID}?.lastKnownPath==c.roots[3].path && c.live()?.roots.contains(c.roots[0].path) != true,"Stale manager overwrote independent archive renewal or attached old root")
        await archiveRenew.shutdown();try await wait("Independent owner race scopes did not balance"){c.provider.balanced}
        try await scheduler(c);try await c.preserved()
    }
    static func main()async throws{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let c=try Context(folder:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        diagnostic={ [weak c] in
            guard let c else{return}
            print("RECOVERY LIVE roots=\(c.live()?.roots ?? []) scopes=\(c.roots.map{c.provider.active($0)})")
            for (index,manager) in c.managers.enumerated(){print("RECOVERY OWNER \(index) pending=\(manager.pendingOperations) retryPending=\(manager.recoveryPending) error=\(manager.error ?? "none") rows=\(manager.rows.map{($0.id,$0.path,$0.status)})")}
        }
        defer{diagnostic=nil}
        do{try await c.setup();try await verify(c);await c.clean()}catch{await c.clean();throw error}
        try require(c.provider.balanced && c.managers.allSatisfy{$0.pendingOperations==0} && c.recoveries.allSatisfy{!$0.isPending} && NSApp.windows.allSatisfy{!$0.isVisible},"Recovery workers/scopes/windows survived cleanup")
        print("PASS: Finder volume recovery, durable roots, private event coalescing, stale authority fences and shutdown drain")
    }
}
