// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func categoryFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func categoryOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));categoryOrder(mode,relativeTo:number)}
}
@MainActor
@main enum CommitCheckCategoriesVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Commit categories \(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Commit categories timeout \(line)")}
    @MainActor final class Context {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.CommitCategories."+UUID().uuidString,prefs:UserDefaults
        var owners:[CommitWindowController]=[]
        var head=Data(),originalIndex=Data(),config=Data(),work=Data()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"Commit.DoNotAutoselectSubmodules");prefs.set(false,forKey:"EnableGravatar")}
        func repository(_ root:URL?=nil)->GitRepository{GitRepository(root:root ?? folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        func initialize(_ repo:GitRepository)async throws{_=try await repo.run(["init","--template=","-b","main"]);for(k,v)in[("user.name","Categories QA"),("user.email","categories@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await repo.run(["config",k,v])}}
        func prepare()async throws{
            let repo=repository();try await initialize(repo)
            let childFolder=folder.deletingLastPathComponent().appendingPathComponent("origin",isDirectory:true);try FileManager.default.createDirectory(at:childFolder,withIntermediateDirectories:true)
            let child=repository(childFolder);try await initialize(child);try Data("before\n".utf8).write(to:childFolder.appendingPathComponent("child"));try await child.stage(["child"]);_=try await child.commit(message:"child base")
            try Data("before\n".utf8).write(to:folder.appendingPathComponent("file"));try Data("base delete\n".utf8).write(to:folder.appendingPathComponent("deleted"))
            _=try await repo.run(["-c","protocol.file.allow=always","submodule","add",childFolder.path,"module"])
            try await repo.stage([".gitmodules","module","file","deleted"]);_=try await repo.commit(message:"base")
            let module=repository(folder.appendingPathComponent("module",isDirectory:true));for(k,v)in[("user.name","Categories QA"),("user.email","categories@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await module.run(["config",k,v])}
            try Data("after child\n".utf8).write(to:module.root.appendingPathComponent("child"));try await module.stage(["child"]);_=try await module.commit(message:"child next")
            work=Data("after\n".utf8);try work.write(to:folder.appendingPathComponent("file"));try Data("new\n".utf8).write(to:folder.appendingPathComponent("new"));try FileManager.default.removeItem(at:folder.appendingPathComponent("deleted"))
            head=try await repo.run(["rev-parse","HEAD"]).stdout;originalIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"));config=try Data(contentsOf:folder.appendingPathComponent(".git/config"))
        }
        func owner()async throws->CommitWindowController{
            let owner=CommitWindowController(repository:repository(),access:nil,defaults:prefs);owners.append(owner)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.isReleasedWhenClosed=false
            owner.model.reload(paths:["."]);try await settled(owner.model)
            try CommitCheckCategoriesVerification.require(owner.model.error==nil,owner.model.error ?? "Load error")
            return owner
        }
        func settled(_ m:CommitWindowModel)async throws{
            try await CommitCheckCategoriesVerification.wait{
                guard !m.busy,!m.savingPreferences,m.canReceiveFileDrop,m.changelistsLoaded,!m.stagingStateNeedsRefresh,CommitWindowModel.activeFileOperations==0,
                      let owner=owners.first(where:{$0.model === m}),let view=owner.window?.contentView else{return false}
                if owner.fileTable()==nil{view.layoutSubtreeIfNeeded()}
                guard let table=owner.fileTable(),table.numberOfRows==m.visibleFileRowIDs.count else{return false}
                func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
                let expected=m.visibleFileRowIDs.map{Data($0.utf8)}
                return descendants(view).compactMap{$0 as? CommitFileInteraction.Probe}.contains{probe in
                    probe.nativeTable === table && probe.rows.map{Data($0.id.utf8)}==expected
                }
            }
        }
        func unchanged(index:Bool=true)async throws{
            try CommitCheckCategoriesVerification.require(try await repository().run(["rev-parse","HEAD"]).stdout==head,"HEAD changed")
            if index{try CommitCheckCategoriesVerification.require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==originalIndex,"Checkbox command changed index")}
            try CommitCheckCategoriesVerification.require(try Data(contentsOf:folder.appendingPathComponent(".git/config"))==config,"Config changed")
            try CommitCheckCategoriesVerification.require(try Data(contentsOf:folder.appendingPathComponent("file"))==work,"Working content changed")
        }
        func cleanup()async{for owner in owners{owner.model.message="";owner.close()};for _ in 0..<3000{if CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0{break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    @MainActor final class Commands {
        let owner:CommitWindowController,main=NSMenu(title:"Private Application")
        var flags=NSEvent.ModifierFlags(),sequence=[String]()
        init(_ owner:CommitWindowController){self.owner=owner;owner.commandMenu?.applicationMenu={ [weak self] in self?.main };owner.commandMenu?.keyWindow={ [weak owner] in owner?.window };owner.commandMenu?.modifierFlags={ [weak self] in self?.flags ?? []}}
        func find(_ id:String,in menu:NSMenu)->NSMenuItem?{for item in menu.items{if item.identifier?.rawValue=="TurtleGit.Commit.Form."+id{return item};if let child=item.submenu,let result=find(id,in:child){return result}};return nil}
        func item(_ category:CommitCheckCategory)throws->NSMenuItem{owner.commandMenu?.install();guard let item=find(category.rawValue,in:main)else{throw Failure(description:"Actual command missing "+category.rawValue)};return item}
        func send(_ category:CommitCheckCategory,shift:Bool=false)throws{flags=shift ? .shift:[];defer{flags=[]};let item=try item(category);sequence.append(category.rawValue+(shift ? "+Shift":""));try require(owner.commandMenu?.validateMenuItem(item)==true,"Category disabled "+category.rawValue+"; sequence=\(sequence); modelAvailable=\(owner.model.canCheckCategory(category)); busy=\(owner.model.busy); blocked=\(owner.model.inputsBlocked); list=\(owner.model.fileListAvailable); ownerCommands=\(owner.commandsAvailable); sheet=\(owner.window?.attachedSheet != nil); checked=\(owner.model.checked.sorted())");guard let action=item.action else{throw Failure(description:"No actual menu action")};try require(NSApp.sendAction(action,to:item.target,from:item),"Native action failed")}
    }
    static func categories(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,commands=Commands(owner)
        let rows=StatusEntry.parse(Data("C  copy\0source\0R  rename\0old\0UU conflict\0A  added\0 M modified\0?? unversioned\0D  removed\0".utf8))
        try require(rows.count==7,"Public status parser lost a source category fixture")
        m.queryCommitStatus={_,_ in rows};m.reload();try await c.settled(m);m.checked=[]
        try commands.send(.added);try require(m.checked==["copy","added"],"Added did not include Copy or included wrong status")
        try commands.send(.modified);try require(m.checked==["copy","added","modified"],"Modified included pure Rename/conflict")
        try commands.send(.modified,shift:true);try require(m.checked==["copy","added"],"Shift Modified touched unrelated checks")
        try commands.send(.none);try require(m.checked.isEmpty,"None did not clear")
        try commands.send(.all);try require(m.checked==GitPathSet(rows.map(\.id)),"All omitted rows")
        try commands.send(.none);try commands.send(.none,shift:true);try require(m.checked==GitPathSet(rows.map(\.id)),"Shift None did not use everything mask")
        try commands.send(.none);try commands.send(.unversioned);try require(m.checked==["unversioned"],"Unversioned category changed")
        try commands.send(.versioned);try require(m.checked==GitPathSet(rows.map(\.id)),"Versioned omitted rename/conflict")
        try await c.unchanged()
    }
    static func submodules(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,commands=Commands(owner)
        try require(m.submodules.contains("module") && m.doNotAutoselectSubmodules,"Real gitlink/policy missing")
        m.checked=[];try commands.send(.modified);try require(m.checked==["file"],"Modified automatically checked suppressed gitlink")
        try commands.send(.submodules);try require(m.checked==["file","module"],"Explicit Submodules failed override")
        try commands.send(.modified,shift:true);try require(m.checked.isEmpty,"Shift category failed to uncheck suppressed gitlink")
        try commands.send(.all);try require(m.checked.contains("module"),"All lost explicit everything submodule bit")
        try commands.send(.none);try commands.send(.none,shift:true);try require(m.checked.contains("module"),"Shift None lost explicit everything submodule bit")
        m.checked=[];try commands.send(.files);try require(!m.checked.contains("module") && m.checked.contains("file"),"Files included gitlink")
        try await c.unchanged()
    }
    static func staging(_ c:Context)async throws{
        _=try await c.repository().run(["config","--local","tgit.commitstagingsupport","true"])
        c.config=try Data(contentsOf:c.folder.appendingPathComponent(".git/config"))
        let owner=try await c.owner(),m=owner.model,commands=Commands(owner)
        m.setStagingEnabled(true);try await c.settled(m)
        try require(m.stagingEnabled && m.doNotAutoselectSubmodules,"Staging/policy not accepted")
        try commands.send(.modified);try await c.settled(m)
        var staged=try await c.repository().run(["diff","--cached","--name-only","-z"]).stdout
        try require(staged.split(separator:0).map{String(decoding:$0,as:UTF8.self)}==["file"],"Category staged excluded gitlink")
        try commands.send(.submodules);try await c.settled(m)
        staged=try await c.repository().run(["diff","--cached","--name-only","-z"]).stdout
        try require(staged.split(separator:0).map{String(decoding:$0,as:UTF8.self)}.contains("module"),"Explicit Submodules did not stage real new commit")
        try commands.send(.modified,shift:true);try await c.settled(m)
        try require(try await c.repository().run(["diff","--cached","--name-only"]).stdout.isEmpty,"Shift Modified did not unstage gitlink")
        try commands.send(.all);try await c.settled(m)
        try require(try await c.repository().run(["diff","--cached","--name-only"]).text.contains("module"),"All failed staging override")
        try commands.send(.none);try await c.settled(m)
        try require(try await c.repository().run(["diff","--cached","--name-only"]).stdout.isEmpty,"None failed to unstage")
        try await c.unchanged(index:false)
    }
    static func ownership(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,commands=Commands(owner)
        m.checked=[];let stale=m.fileCheckReceipt;m.setDoNotAutoselectSubmodules(false);m.checked=[]
        m.checkCategory(.all,checking:true,receipt:stale);try require(m.checked.isEmpty,"Stale policy receipt dispatched")
        m.busy=true;m.checkCategory(.all,checking:true);try require(m.checked.isEmpty,"Busy bulk action dispatched");m.busy=false
        m.confirmingQuit=true;m.checkCategory(.all,checking:true);try require(m.checked.isEmpty,"Quit bulk action dispatched");m.confirmingQuit=false
        let child=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false);child.isReleasedWhenClosed=false;child.alphaValue=0
        owner.window?.beginSheet(child,completionHandler:nil);let item=try commands.item(.all)
        try require(owner.commandMenu?.validateMenuItem(item)==false,"Owned sheet did not disable category")
        owner.window?.endSheet(child);child.orderOut(nil);try await wait{child.sheetParent==nil};child.close()
        let oldItem=try commands.item(.all);m.showUnversioned.toggle();if let action=oldItem.action{_=NSApp.sendAction(action,to:oldItem.target,from:oldItem)}
        try require(m.checked.isEmpty,"Stale native menu action checked rows")
        m.showUnversioned=true;owner.close();m.checkCategory(.all,checking:true);try require(m.checked.isEmpty,"Retired category action dispatched")
        try await c.unchanged()
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.categoryFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.categoryOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context(),name=CommandLine.arguments[3]
        do{try await c.prepare();switch name{case "categories":try await categories(c);case "submodules":try await submodules(c);case "staging":try await staging(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")};await c.cleanup();print("PASS: Commit check categories "+name)}catch{await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}
