import AppKit
import FinderSync
import Carbon
import Darwin
import TurtleGitCore

@MainActor final class ColdMenuTarget:NSObject {@objc func invoke(_ sender:NSMenuItem){}}
@MainActor @main enum FinderColdMenuVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Cold menu timeout: "+message)}
    final class Bookmarks:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{true}
        func stopAccessing(_ url:URL){}
    }
    static func items(_ menu:NSMenu)->[NSMenuItem]{menu.items.flatMap{[$0]+($0.submenu.map(items) ?? [])}}
    static func command(_ action:RepositoryAction,_ menu:NSMenu)->NSMenuItem?{items(menu).first{($0.representedObject as? FinderMenuCommand)?.request.action==action}}
    static func actions(_ menu:NSMenu)->[RepositoryAction]{items(menu).compactMap{($0.representedObject as? FinderMenuCommand)?.request.action}}
    static func signatures(_ menu:NSMenu)->[String]{items(menu).map{"\($0.isSeparatorItem)|\($0.title)|\($0.isEnabled)|\($0.image != nil)|\(($0.representedObject as? FinderMenuCommand)?.url()?.absoluteString ?? "")"}}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func staleManagers(_ folder:URL,git:URL)async throws {
        let directory=folder.appendingPathComponent("multiple-writers")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let archive=directory.appendingPathComponent("private-watches.json"),catalogURL=directory.appendingPathComponent("registered-roots.json"),cache=FinderSnapshotStore(url:directory.appendingPathComponent("status.json"))
        var roots=[URL]()
        for name in ["A","B","RenewedBare"] {
            let root=directory.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            let repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            _=try await repository.run(name=="RenewedBare" ? ["init","--bare","--template="]:["init","--template=","-b","main"])
            roots.append(root)
        }
        func manager(_ store:RepositoryAccessStore)->FinderWatchManager{FinderWatchManager(permissions:store,cache:cache,requireScope:true,scopeProvider:Bookmarks(),repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},registeredRootsURL:catalogURL,notify:{})}
        let firstStore=try RepositoryAccessStore(storageURL:archive,provider:Bookmarks()),first=manager(firstStore)
        var managers=[first]
        let direct=try cache.startSession(),directRoot=directory.appendingPathComponent("independent-workspace",isDirectory:true)
        defer{_=try? cache.endSession(direct)}
        let directTicket=try cache.begin(root:directRoot,session:direct)
        try require(try cache.publish(directTicket,snapshots:[FinderSnapshot(roots:[directRoot.path],states:[directRoot.path:.modified],repositories:[directRoot.path:.init()])]).published,"Independent workspace fixture did not publish")
        do {
            await first.add(roots[0]);try await wait("initial stale-writer fixture"){first.pendingOperations==0}
            guard let firstID=try FinderRegisteredRoots.read(from:catalogURL).root(for:roots[0])?.id else{throw Failure(description:"Initial explicit root missing")}
            let peerStore=try RepositoryAccessStore(storageURL:archive,provider:Bookmarks()),peer=manager(peerStore);managers.append(peer)
            await peer.add(roots[1]);try await wait("peer Add"){peer.pendingOperations==0}
            guard let peerID=try FinderRegisteredRoots.read(from:catalogURL).root(for:roots[1])?.id else{throw Failure(description:"Peer explicit root missing")}
            first.restore();try await wait("late stale manager after peer Add"){first.pendingOperations==0}
            try require(Set(try FinderRegisteredRoots.read(from:catalogURL).entries.map(\.id))==Set([firstID,peerID]),"Stale manager erased a peer's newly registered root")
            await peer.remove(firstID);try await wait("peer Remove"){peer.pendingOperations==0}
            first.restore();try await wait("late stale manager after peer Remove"){first.pendingOperations==0}
            try require(try FinderRegisteredRoots.read(from:catalogURL).entries.map(\.id)==[peerID],"Stale manager revived a forgotten registration")
            try await wait("peer removal retires only old live contribution") {
                first.pendingOperations==0 && peer.pendingOperations==0 &&
                (try? cache.readLive().roots.contains(roots[0].path))==false &&
                (try? cache.readLive().roots.contains(roots[1].path))==true &&
                (try? cache.readLive().roots.contains(directRoot.path))==true
            }
            let oldRootStore=try RepositoryAccessStore(storageURL:archive,provider:Bookmarks()),oldRoot=manager(oldRootStore);managers.append(oldRoot)
            oldRoot.restore();try await wait("retain old working-tree kind"){oldRoot.pendingOperations==0}
            await peer.add(roots[2],replacing:peerID);try await wait("peer Renew to bare root"){peer.pendingOperations==0}
            let renewed=try FinderRegisteredRoots.read(from:catalogURL)
            try require(renewed.root(for:roots[2])?.id==peerID && renewed.root(for:roots[2])?.kind == .bare,"Renew did not publish actual bare identity")
            oldRoot.restore();try await wait("old-path kind publication"){oldRoot.pendingOperations==0}
            let settled=try FinderRegisteredRoots.read(from:catalogURL)
            try require(settled.entries.count==1 && settled.root(for:roots[2])?.id==peerID && settled.root(for:roots[2])?.kind == .bare && settled.root(for:roots[1])==nil,"Stale old-path kind reclassified a renewed root")
            try await wait("renew retires old live root while replacement remains") {
                managers.allSatisfy{$0.pendingOperations==0} &&
                (try? cache.readLive().roots.contains(roots[1].path))==false &&
                (try? cache.readLive().roots.contains(roots[2].path))==true &&
                (try? cache.readLive().roots.contains(directRoot.path))==true
            }
            for value in managers{await value.shutdown()}
        }catch{for value in managers{await value.shutdown()};throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let delivery=FinderActionDelivery(receipt:UUID().uuidString.lowercased(),action:.commit) else{throw Failure(description:"Private delivery construction failed")}
        let event=FinderSync.actionEvent(delivery)
        try require(event.eventClass==AEEventClass(kInternetEventClass) && event.eventID==AEEventID(kAEGetURL),"Finder cold launch must provide a real first GetURL event")
        try require(event.paramDescriptor(forKeyword:AEKeyword(keyDirectObject))?.stringValue==delivery.url.absoluteString,"First Apple event lost bounded receipt envelope")
        try require(delivery.arguments==[FinderActionDelivery.argumentFlag,delivery.url.absoluteString],"Unsandboxed argv fallback changed")
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=folder.appendingPathComponent("registered 雪",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Cold menu QA"),("user.email","cold-menu@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        try Data("before\n".utf8).write(to:root.appendingPathComponent("tracked.txt"));try await repository.stage(["tracked.txt"]);_=try await repository.commit(message:"initial")
        try Data("after\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        let permissions=try RepositoryAccessStore(storageURL:folder.appendingPathComponent("private/watches.json"),provider:Bookmarks())
        let cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json")),catalogURL=folder.appendingPathComponent("shared/registered-roots.json")
        let helper=folder.appendingPathComponent("held-status"),fifo=URL(fileURLWithPath:helper.path+".fifo"),marker=URL(fileURLWithPath:helper.path+".ready"),released=URL(fileURLWithPath:helper.path+".released")
        guard mkfifo(fifo.path,mode_t(0o600))==0 else{throw Failure(description:"Private status FIFO unavailable")}
        let script="""
        #!/bin/sh
        task_status=false
        for task_arg in "$@"; do
          if [ "$task_arg" = status ] || [ "$task_arg" = ls-files ]; then task_status=true; fi
        done
        if [ "$task_status" = true ] && [ ! -f "$0.released" ]; then
          printf '%s\\n' "$$" > "$0.ready"
          IFS= read -r task_release < "$0.fifo"
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        var notificationCount=0
        let manager=FinderWatchManager(permissions:permissions,cache:cache,requireScope:true,scopeProvider:Bookmarks(),repositoryFactory:{GitRepository(root:$0,executable:helper,libgit2Configuration:.init(enabled:false))},registeredRootsURL:catalogURL,notify:{notificationCount+=1})
        let target=ColdMenuTarget(),selector=#selector(ColdMenuTarget.invoke(_:))
        var settings=FinderMenuSettings(showIcons:true);settings.topLevelMask=0;settings.extendedOnlyMask=0
        func menu(_ paths:[URL],live:FinderSnapshot?=nil,catalog:FinderRegisteredRoots?,policy:FinderMenuSettings?=nil,extended:Bool=false,toolbar:Bool=false)->NSMenu {
            FinderMenuBuilder.make(paths:paths,snapshot:live,settings:policy ?? settings,comparisonMark:nil,target:target,actionSelector:selector,extended:extended,toolbar:toolbar,registeredRoots:catalog)
        }
        let registration=Task{await manager.add(root)}
        var helperPID:Int32?
        do {
            try await wait("heavy status blocked after confirmed registration"){FileManager.default.fileExists(atPath:marker.path)}
            helperPID=Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))
            let early=try FinderRegisteredRoots.read(from:catalogURL)
            try require(early.root(for:root)?.kind == .workingTree && early.entries.count==1,"Confirmed generic commands waited for full status publication")
            try require(command(.commit,menu([root],catalog:early))?.isEnabled==true,"Registered working tree lacks Commit before heavy status completes")
            try require(manager.pendingOperations>0,"Held status read lost real ownership")
            try Data().write(to:released)
            let handle=try FileHandle(forWritingTo:fifo);try handle.write(contentsOf:Data("continue\n".utf8));try handle.close()
            await registration.value
            try await wait("actual status publication"){manager.pendingOperations==0 && manager.rows.first?.status=="Updated"}
            let reader=FinderSnapshotLiveReader(url:cache.url),live=try reader.read(),registered=try FinderRegisteredRoots.read(from:catalogURL)
            try require(live.states[root.appendingPathComponent("tracked.txt").path] == .modified,"Actual publisher lost changed tracked-file status")
            try require(signatures(menu([root],live:live,catalog:registered))==signatures(menu([root],live:live,catalog:nil)),"Catalog altered current live source menus/order/icons/selection")
            await manager.shutdown()
            try require(try reader.read().roots.isEmpty,"Publisher shutdown retained live badge authority")
            let cold=try FinderRegisteredRoots.read(from:catalogURL),popup=menu([root],catalog:cold)
            try require(cold.entries.map(\.id)==permissions.repositories.map(\.id),"Shutdown lost explicit watch identity")
            for action in [RepositoryAction.commit,.log,.fetch,.push,.status] {try require(command(action,popup)?.isEnabled==true && command(action,popup)?.image != nil,"Cold registered root lost generic source command/icon: "+action.rawValue)}
            let forbidden:Set<RepositoryAction>=[.resolve,.resolveMine,.resolveTheirs,.revert,.remove,.ignore,.blame,.lfsLock,.lfsUnlock,.bisectGood,.bisectBad,.stashPop,.submoduleUpdate]
            try require(Set(actions(popup)).isDisjoint(with:forbidden),"Discovery hints fabricated file/conflict/LFS/bisect/stash/submodule state")
            let descendant=root.appendingPathComponent("folder",isDirectory:true)
            try require(command(.commit,menu([descendant],catalog:cold))?.isEnabled==true,"Known descendant folder lost generic repository invocation")
            try require(command(.worktreeCreate,popup) != nil && command(.worktreeCreate,menu([descendant],catalog:cold))==nil,"Worktree creation requires the exact registered root")
            let file=root.appendingPathComponent("tracked.txt"),outside=folder.appendingPathComponent("unknown",isDirectory:true)
            for selection in [[file],[outside],[root,outside],[root,descendant]] {try require(command(.commit,menu(selection,catalog:cold))==nil,"File/unknown/multiple selection acquired synthetic repository flags")}
            let unknown=FinderRegisteredRoots(entries:[.init(id:UUID(),root:root.path,kind:.unknown)])
            try require(command(.commit,menu([root],catalog:unknown))==nil && command(.log,menu([root],catalog:unknown)) != nil,"Unconfirmed kind fabricated working-tree capability")
            let bare=FinderRegisteredRoots(entries:[.init(id:UUID(),root:root.path,kind:.bare)]),bareMenu=menu([root],catalog:bare)
            try require(command(.fetch,bareMenu) != nil && command(.repositoryBrowser,bareMenu) != nil && command(.commit,bareMenu)==nil && command(.status,bareMenu)==nil,"Bare generic context fabricated a working tree")
            try require(command(.worktreeCreate,bareMenu) != nil && command(.worktreeCreate,menu([descendant],catalog:bare))==nil,"Bare descendant fabricated worktree root capability")
            var extendedOnly=settings;extendedOnly.extendedOnlyMask=FinderMenuEntry.commit.mask
            try require(command(.commit,menu([root],catalog:cold,policy:extendedOnly))==nil && command(.commit,menu([root],catalog:cold,policy:extendedOnly,extended:true)) != nil,"Cold generic command ignored extended-only preference")
            var firstLevel=settings;firstLevel.topLevelMask=FinderMenuEntry.commit.mask
            let promoted=menu([root],catalog:cold,policy:firstLevel)
            try require(promoted.items.contains{($0.representedObject as? FinderMenuCommand)?.request.action == .commit},"Cold command ignored first-level placement")
            var excluded=settings;excluded.excludedPaths=root.path
            try require(command(.commit,menu([root],catalog:cold,policy:excluded))==nil,"Durable registration bypassed path exclusions")
            var noIcons=settings;noIcons.showIcons=false
            try require(items(menu([root],catalog:cold,policy:noIcons)).allSatisfy{$0.image==nil},"Cold generic menu ignored icon preference")
            try require(FinderOverlaySettings().overlayBadges(snapshot:try reader.read(),volume:{_ in .fixed},isDirectory:{_ in true}).isEmpty,"Durable hints became stale status overlays")
            if let helperPID {try require(kill(helperPID,0) != 0,"Held status helper survived manager shutdown")}
            try require(notificationCount>0,"Durable hint/live publication omitted change notification")
        }catch{await manager.shutdown();await registration.value;throw error}
        try await staleManagers(folder,git:git)
        print("PASS: cold Finder command hints before status and after shutdown; conservative file/bare/unknown/mixed menus, live parity, icons and no stale badge authority")
    }
}
