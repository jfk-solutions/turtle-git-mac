import AppKit
import TurtleGitCore

@main struct ReferenceChildDeliveryVerification {
    struct Failure:Error {let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws{
        for _ in 0..<3000 {NSApp.windows.forEach{$0.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Reference child delivery did not drain at line \(line)")
    }
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Child QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("reference delivery\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let name="refs/heads/Cafe\u{301}/leaf";_=try await repo.run(["update-ref",name,"HEAD"])
        // APFS may expose a loose reference through a different canonical
        // directory-entry spelling. Author the exact packed control, as the
        // complete Browser fixture does; no normalization is accepted below.
        _=try await repo.run(["pack-refs","--all","--prune"])
        let packed=root.appendingPathComponent(".git/packed-refs")
        var packedText=try String(contentsOf:packed,encoding:.utf8)
        let record=String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines)+" "+name
        if !packedText.components(separatedBy:"\n").contains(where:{$0.utf8.elementsEqual(record.utf8)}) {
            packedText=packedText.replacingOccurrences(of:" sorted",with:"")+record+"\n"
            try Data(packedText.utf8).write(to:packed)
        }
        let suite="TurtleGit.ChildDelivery."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")
        defer{prefs.removePersistentDomain(forName:suite)}
        let parent=NSWindow(contentRect:.init(x:-12000,y:-12000,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;parent.alphaValue=0;defer{parent.close()}
        for operation in ["accept","cancel","forced"] {
            print("PHASE: Browser sheet "+operation);fflush(stdout)
            var events:[String]=[],chosen:String?,detached=true
            var native:NSWindow?
            let child=ReferenceBrowserWindowController(repository:repo,access:nil,initial:name,preferences:prefs){value in
                detached = detached && native?.sheetParent==nil && parent.attachedSheet !== native
                chosen=value;events.append("choice")
            }
            native=child.window;child.onClosed={detached = detached && native?.sheetParent==nil && parent.attachedSheet !== native;events.append("closed")}
            child.model.load();try await wait{!child.model.busy && child.model.snapshot != nil}
            try require(child.model.error==nil,"Browser load failed: \(child.model.error ?? "unknown")")
            child.model.select([GitReferenceName(name)],last:GitReferenceName(name))
            try require(child.model.rows.contains{$0.reference.name.rawValue.utf8.elementsEqual(name.utf8)},"Browser exact packed row absent: folder=\(child.model.folder.rawValue), selected=\(String(describing:child.model.selected)), rows=\(child.model.rows.map{$0.reference.name.rawValue})")
            try await wait{child.model.chosen?.name.rawValue.utf8.elementsEqual(name.utf8)==true}
            child.window?.alphaValue=0;child.window?.setFrameOrigin(.init(x:-12000,y:-12000))
            parent.beginSheet(child.window!,completionHandler:{_ in})
            try require(child.window?.sheetParent===parent,"Browser did not create real native attachment")
            if operation=="accept" {child.model.accept()}else if operation=="cancel" {child.model.cancel()}else{child.close()}
            try await wait{events.count==2 && !child.hasPendingWork}
            try require(detached && events==["choice","closed"] && (operation=="accept" ? chosen?.utf8.elementsEqual(name.utf8)==true : chosen==nil),"Browser delivered before detachment, out of order, or lost exact reference")
            child.model.accept();child.model.cancel();child.close();await Task.yield()
            try require(events.count==2,"Browser delivered twice")
        }
        for operation in ["accept","cancel","forced"] {
            print("PHASE: Reflog sheet "+operation);fflush(stdout)
            var events:[String]=[],chosen:ReferenceLogEntry?,detached=true
            var native:NSWindow?
            let child=ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",onChoose:{value in
                detached = detached && native?.sheetParent==nil && parent.attachedSheet !== native
                chosen=value;events.append("choice")
            },preferences:prefs)
            native=child.window;child.onClosed={detached = detached && native?.sheetParent==nil && parent.attachedSheet !== native;events.append("closed")}
            try await wait{!child.model.busy && !child.model.entries.isEmpty}
            let selected=child.model.entries[0];child.model.selection=[selected.id]
            child.window?.alphaValue=0;child.window?.setFrameOrigin(.init(x:-12000,y:-12000));parent.beginSheet(child.window!,completionHandler:{_ in})
            try require(child.window?.sheetParent===parent,"Reflog did not create real native attachment")
            if operation=="accept" {child.model.accept()}else if operation=="cancel" {child.model.close()}else{child.close()}
            try await wait{events.count==2 && !child.hasPendingWork}
            try require(detached && events==["choice","closed"] && (operation=="accept" ? chosen?.id==selected.id : chosen==nil),"Reflog delivered before detachment, out of order, or lost exact entry")
            child.model.accept();child.model.close();child.close();await Task.yield()
            try require(events.count==2,"Reflog delivered twice")
        }
        try await wait{FinderFilesystemWorkflowRelease.activeRetirements==0}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Reference delivery changed HEAD/index")
        print("PASS: actual hidden native Browser/Reflog sheet acceptance, Cancel and forced-close detach before exactly-once ordered delivery; exact reference/entry and unchanged HEAD/index")
    }
    @MainActor static func main()async throws{try await verify()}
}
