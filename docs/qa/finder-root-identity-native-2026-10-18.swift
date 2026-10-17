import AppKit
import FinderSync
import TurtleGitCore

@MainActor final class RootIdentityTarget:NSObject {
    @objc func invoke(_ sender:NSMenuItem) {}
}
@main struct FinderRootIdentityVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ text:String) throws {if !condition {throw Failure(description:text)}}
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Root identity native timeout")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.last == "finder-publication-worker" {await FinderPublicationWorker.main();return}
        if CommandLine.arguments.last == "root-worker" {try await worker();return}
        try await verify()
        try await FinderPublicationVerification.verify()
        print("PASS: Finder root identity family; owned workers and models closed")
    }
    @MainActor static func worker() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        let input=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("input.json")))
        let root=input["root"]!,store=FinderSnapshotStore(url:URL(fileURLWithPath:input["store"]!))
        let ticket=try store.begin(root:FileTransferPaths.fileURL(root))
        try Data().write(to:directory.appendingPathComponent("ready"))
        try await wait {FileManager.default.fileExists(atPath:directory.appendingPathComponent("go").path)}
        let merge=input["merge"] == "1"
        let snapshot=FinderSnapshot(roots:[root],states:[root:.normal,root+"/file":merge ? .modified:.conflicted],repositories:[root:.init(bisectActive:!merge,mergeActive:merge)],overlayEntries:[root+"/file":merge ? .modified:.conflicted])
        try require(try store.publish(ticket,snapshots:[snapshot]).published,"Independent exact-root worker lost its ticket")
    }
    @MainActor static func verify() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]),cache=FinderSnapshotStore(url:directory.appendingPathComponent("root-cache/status.json"))
        let a=directory.path+"/\u{00c5}",b=directory.path+"/A\u{030a}"
        // The host volume may alias these spellings. The cache/wire fixture
        // intentionally preserves both; it does not claim two physical folders.
        let aURL=FileTransferPaths.fileURL(a),bURL=FileTransferPaths.fileURL(b)
        try FileManager.default.createDirectory(at:aURL,withIntermediateDirectories:true)
        try Data("original\n".utf8).write(to:FileTransferPaths.fileURL(a+"/file"))
        var workers:[Process]=[]
        defer {for worker in workers {if worker.isRunning {worker.terminate()};worker.waitUntilExit()}}
        for (index,root) in [a,b].enumerated() {
            let folder=directory.appendingPathComponent("exact-worker-\(index)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try JSONEncoder().encode(["root":root,"store":cache.url.path,"merge":index==0 ? "1":"0"]).write(to:folder.appendingPathComponent("input.json"))
            let worker=Process();worker.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);worker.arguments=[folder.path,CommandLine.arguments[2],"root-worker"]
            try worker.run();workers.append(worker)
        }
        try await wait {(0..<2).allSatisfy {FileManager.default.fileExists(atPath:directory.appendingPathComponent("exact-worker-\($0)/ready").path)}}
        for index in 0..<2 {try Data().write(to:directory.appendingPathComponent("exact-worker-\(index)/go"))}
        try await wait {workers.allSatisfy {!$0.isRunning}}
        for worker in workers {worker.waitUntilExit();try require(worker.terminationStatus==0,"Exact root worker failed");print("Exact-root worker reaped: \(worker.processIdentifier)")}
        let snapshot=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:cache.url))
        try require(snapshot.repositories.count==2 && snapshot.repositories[a]?.mergeActive == true && snapshot.repositories[b]?.bisectActive == true,"Cross-process metadata identity collapsed")
        let target=RootIdentityTarget(),selector=#selector(RootIdentityTarget.invoke(_:))
        var settings=FinderMenuSettings();settings.extendedOnlyMask=0;settings.topLevelMask=0
        func items(_ menu:NSMenu)->[NSMenuItem] {menu.items + menu.items.flatMap {$0.submenu.map(items) ?? []}}
        func menu(_ paths:[URL])->NSMenu {FinderMenuBuilder.make(paths:paths,snapshot:snapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:selector)}
        func item(_ action:RepositoryAction,_ menu:NSMenu)->NSMenuItem? {items(menu).first {($0.representedObject as? FinderMenuCommand)?.request.action==action}}
        let first=menu([aURL]),second=menu([bURL])
        try require(item(.mergeAbort,first)?.isEnabled == true && item(.bisectGood,first)==nil,"First root borrowed second menu state")
        try require(item(.bisectGood,second)?.isEnabled == true && item(.mergeAbort,second)==nil,"Second root borrowed first menu state")
        let mixed=menu([FileTransferPaths.fileURL(a+"/file"),FileTransferPaths.fileURL(b+"/file")])
        try require(item(.commit,mixed)?.isEnabled == false && item(.commit,mixed)?.toolTip?.contains("one repository") == true,"Mixed canonical roots enabled repository mutation")
        for (root,current) in [(a,first),(b,second)] {
            guard let selected=item(.log,current),let command=selected.representedObject as? FinderMenuCommand,
                  let raw=command.url(),let request=FinderRequest(url:raw) else {throw Failure(description:"Missing source Log command")}
            try require(selected.image != nil && request.paths.count==1 && GitReferenceName.equal(request.paths[0].path,root),"Source icon or captured root URI lost raw spelling")
            let dispatch=FinderMenuDispatch();dispatch.install(current)
            let clone=NSMenuItem(title:selected.title,action:selected.action,keyEquivalent:"");clone.tag=selected.tag
            try require(dispatch.claim(clone) != nil && dispatch.claim(clone)==nil,"Primitive dispatch was not once-only")
        }
        let badges=FinderOverlaySettings().overlayBadges(snapshot:snapshot,volume:{_ in .fixed},isDirectory:{GitPathSet([a,b]).contains($0)})
        let lookup=FinderOverlayBadgeLookup(badges:badges,caseSensitive:{_ in true})
        try require(lookup.badge(for:a+"/file",caseSensitive:true) == .modified && lookup.badge(for:b+"/file",caseSensitive:true) == .conflicted,"Finder badge lookup borrowed sibling state")
        try require(FinderTransferContext.requests(destination:aURL,sources:[FileTransferPaths.fileURL(b+"/file")],snapshot:snapshot,settings:settings).map(\.action) == [.pasteCopy],"Canonical peer permitted Paste Move across owners")
        let aliasChild=FinderSnapshot(roots:[directory.path,a],states:[a:.normal],repositories:[directory.path:.init(),a:.init(submoduleParentRoot:directory.path)],overlayEntries:[a:.normal])
        try require(FinderTransferContext.requests(destination:directory,sources:[bURL],snapshot:aliasChild,settings:settings).map(\.action) == [.pasteCopy,.pasteMove],"Unique submodule alias lost its parent transfer owner")
        let pending=try cache.begin(root:bURL),removed=try cache.remove(root:bURL)
        try require(removed.repositories[a]?.mergeActive == true && removed.repositories[b]==nil,"Removal erased peer metadata")
        let stale=FinderSnapshot(roots:[b],states:[b:.normal],repositories:[b:.init()])
        try require(try !cache.publish(pending,snapshots:[stale]).published,"Removed root revived through old ticket")
        try require(try Data(contentsOf:FileTransferPaths.fileURL(a+"/file"))==Data("original\n".utf8),"Finder family changed file bytes")
        print("Finder exact roots: lossless concurrent wire/cache, native menu eligibility/icons and captured URI, mixed-owner refusal, primitive once-only dispatch, badge state and exact removal passed")
    }
}
