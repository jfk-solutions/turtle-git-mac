import AppKit
import SwiftUI
import TurtleGitCore

@main struct FinderWatchVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    final class Bookmarks:RepositoryBookmarkProvider,RepositoryTransferBookmarkProvider {
        let marker="PRIVATE-WATCH-BOOKMARK:"
        var moves:[String:URL]=[:]
        var available=true,successfulStarts=0,stops=0
        func create(for url:URL) throws -> Data { Data((marker+url.path).utf8) }
        func resolve(_ data:Data) throws -> ResolvedBookmark {
            let text=String(decoding:data,as:UTF8.self);guard text.hasPrefix(marker) else { throw RepositoryAccessFailure.unknownRepository }
            let path=String(text.dropFirst(marker.count));return ResolvedBookmark(url:moves[path] ?? URL(fileURLWithPath:path,isDirectory:true),stale:moves[path] != nil)
        }
        func createTransfer(for url:URL) throws -> Data { Data(("TRANSFER:"+url.path).utf8) }
        func resolveTransfer(_ data:Data) throws -> ResolvedBookmark { ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self).replacingOccurrences(of:"TRANSFER:",with:""),isDirectory:true),stale:false) }
        func startAccessing(_ url:URL) -> Bool { if available { successfulStarts += 1 };return available }
        func stopAccessing(_ url:URL) { stops += 1 }
    }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Finder watch timeout at \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Finder watches failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),provider=Bookmarks()
        let registry=folder.appendingPathComponent("private/watch-repositories.json"),permissions=try RepositoryAccessStore(storageURL:registry,provider:provider)
        let cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        var repositories:[GitRepository]=[]
        for name in ["Project A","Project B"] {
            let root=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:engine);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Watch QA"),("user.email","watch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("baseline\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Watched baseline");repositories.append(repo)
        }
        func snapshot() -> FinderSnapshot? { guard let data=try? Data(contentsOf:cache.url) else { return nil };return try? JSONDecoder().decode(FinderSnapshot.self,from:data) }
        var notifications=0
        func manager(_ executable:URL = engine) -> FinderWatchManager {
            FinderWatchManager(permissions:permissions,cache:cache,requireScope:true,scopeProvider:provider,repositoryFactory:{ GitRepository(root:$0,executable:executable) },notify:{ notifications += 1 })
        }
        let first=manager()
        await first.add(repositories[0].root);await first.add(repositories[1].root)
        try await wait { first.pendingOperations==0 && first.rows.allSatisfy { $0.status=="Updated" } && snapshot()?.roots.count==2 }
        try require(first.rows.count==2 && notifications>=2,"Add/publication")
        do {
            let exported=try first.serviceAuthorization(provider:provider),received=try exported.acquire(provider:provider)
            try require(Set(received.map { $0.root.path })==Set(repositories.map { $0.root.path }),"Watcher export lost authorized roots")
            withExtendedLifetime(received) {}
        }
        let originalIDs=Set(first.rows.map(\.id))
        await first.add(repositories[0].root);try await wait { first.pendingOperations==0 && first.rows.allSatisfy { $0.status=="Updated" } }
        try require(Set(first.rows.map(\.id))==originalIDs,"Duplicate Add created another watcher")
        try Data("changed\n".utf8).write(to:repositories[0].root.appendingPathComponent("file"))
        try await wait { snapshot()?.states[repositories[0].root.appendingPathComponent("file").path] == .modified && first.pendingOperations==0 }
        try require(!(try String(contentsOf:cache.url)).contains(provider.marker),"Private bookmark entered shared cache")
        let aID=permissions.repositories.first { $0.lastKnownPath==repositories[0].root.path }!.id
        await first.add(repositories[1].root,replacing:aID)
        try require(first.error=="This repository is already watched." && permissions.repositories.count==2,"Duplicate Renew accepted")
        if CommandLine.arguments[3]=="finder-watches-captures" {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.title="Watched Repositories – TurtleGit"
            window.contentViewController=NSHostingController(rootView:FinderWatchedRepositoriesPage(manager:first));window.setContentSize(NSSize(width:900,height:500));window.contentView?.layoutSubtreeIfNeeded();try await capture(window);window.close()
        }
        await first.shutdown()
        let moved=folder.appendingPathComponent("Moved Project A");try FileManager.default.moveItem(at:repositories[0].root,to:moved);provider.moves[repositories[0].root.path]=moved
        let relaunched=manager();relaunched.restore()
        try await wait { relaunched.pendingOperations==0 && relaunched.rows.count==2 && relaunched.rows.allSatisfy { $0.status=="Updated" } && snapshot()?.roots.contains(moved.path)==true }
        try require(!snapshot()!.roots.contains(repositories[0].root.path) && permissions.repositories.first { $0.id==aID }?.lastKnownPath==moved.path,"Moved root retained ghost cache/lost identity")
        await relaunched.remove(aID);try await wait { relaunched.pendingOperations==0 }
        try require(relaunched.rows.count==1 && !snapshot()!.roots.contains(moved.path) && snapshot()!.roots.contains(repositories[1].root.path),"Remove dropped other roots")
        await relaunched.shutdown()
        provider.available=false;let denied=manager();denied.restore()
        try require(denied.rows.first?.status.contains("unavailable")==true && permissions.repositories.count==1,"Failed scope discarded row")
        await denied.shutdown();provider.available=true
        func quote(_ value:String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        for phase in ["remove","quit"] {
            if permissions.repositories.isEmpty { _ = try permissions.remember(repositories[1].root) }
            let helper=folder.appendingPathComponent("slow-watch-"+phase),marker=URL(fileURLWithPath:helper.path+".ready")
            let script="""
            #!/bin/sh
            task_hit=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '--is-bare-repository' ]; then task_hit=true; fi
            done
            if [ "$task_hit" = true ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
              /bin/mv "$0.ready.tmp" "$0.ready"
              wait "$task_child"
            fi
            exec \(quote(engine.path)) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let slow=manager(helper);slow.restore()
            do {
                try await wait { FileManager.default.fileExists(atPath:marker.path) }
                let pids=try String(contentsOf:marker).split(whereSeparator:{ $0.isWhitespace }).compactMap { Int32($0) }
                try require(pids.count==2 && pids.allSatisfy { kill($0,0)==0 },"Missing owned watcher read")
                if phase=="remove" {
                    await slow.remove(permissions.repositories[0].id)
                    try await wait { slow.pendingOperations==0 && pids.allSatisfy { kill($0,0) != 0 } }
                    try require(slow.rows.isEmpty && !snapshot()!.roots.contains(repositories[1].root.path),"Late removed watcher revived")
                    await slow.shutdown()
                } else {
                    let workspace=RepositoryModel(startMonitoring:false,finderWatches:slow),delegate=TurtleGitApplicationDelegate();delegate.repositoryModel=workspace
                    var replies=0,approved=false
                    delegate.replyToTermination={ _,value in replies += 1;approved=value }
                    try require(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater,"Quit did not await watcher")
                    _ = delegate.applicationShouldTerminate(NSApplication.shared)
                    try await wait { replies==1 && slow.pendingOperations==0 && pids.allSatisfy { kill($0,0) != 0 } }
                    try require(approved && !slow.active,"Quit reply/lifetime")
                }
            } catch { await slow.shutdown();throw error }
        }
        try await wait { provider.successfulStarts==provider.stops }
        let reopened=try RepositoryAccessStore(storageURL:registry,provider:provider)
        try require(reopened.repositories.count==1 && reopened.repositories[0].lastKnownPath==repositories[1].root.path && String(decoding:reopened.repositories[0].bookmark,as:UTF8.self).contains(provider.marker),"Private relaunch records missing")
        print("Finder watches: private persistent Add/dedup/Renew, real independent event refresh, moved bookmark/cache cleanup, retained failed grants, removal and late-read fencing, owned process reaping, once-only asynchronous Quit and balanced scope leases passed. No user preferences/App Group or Finder activation used.")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/finder-watch-captures-2026-10-13")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.appearance=window.appearance;window.center();window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
            try await Task.sleep(nanoseconds:400_000_000)
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent("finder-watches-"+suffix+".png").path]
            try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Owned watcher capture failed");window.orderOut(nil)
        }
    }
}
