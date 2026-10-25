// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func settingsContextFrame(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
    @objc func settingsContextOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));settingsContextOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum SettingsContextVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Settings context \(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Settings context timeout \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{views($0)}}
    static func click(_ title:String,_ controller:NSWindowController)async throws {
        guard let view=controller.window?.contentView,
              let button=views(view).compactMap({$0 as? NSButton}).last(where:{$0.title==title}),
              let action=button.action else {throw Failure(description:"Actual Settings footer unavailable: "+title)}
        try await wait{button.isEnabled}
        try require(NSApp.sendAction(action,to:button.target,from:button),"Native footer did not dispatch")
    }
    static func flushMainQueue()async {
        for _ in 0..<2 {await withCheckedContinuation{(reply:CheckedContinuation<Void,Never>) in DispatchQueue.main.async{reply.resume()}}}
    }
    static func drained()->Bool {
        RemoteSettingsWindowModel.activeOperations==0 && RemoteSettingsWindowModel.activeRetirements==0 && SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0 && GitConfigurationSettingsModel.activeReads==0 && GitConfigurationSettingsModel.activeSaves==0 && GitConfigurationSettingsModel.activeSheetReleases==0 && GeneralGitSettingsModel.activeOperations==0
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.SettingsContext."+UUID().uuidString
        let prefs:UserDefaults,service=SettingsPresentationService()
        var workspace:RepositoryModel!,appearance:AppAppearance!,owners:[NSWindowController]=[],workspaces:[RepositoryModel]=[],releases:[()->Void]=[]
        var a:URL {base.appendingPathComponent("a",isDirectory:true)}
        var b:URL {base.appendingPathComponent("b",isDirectory:true)}
        var originalHead=Data(),originalIndex=Data()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"HintHierarchicalConfig")}
        func repository(_ root:URL)->GitRepository {GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        func makeWorkspace(_ root:URL)->RepositoryModel {
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false)
            model.root=root;model.settingsContextOverride=(repository(root),RepositoryAccessLease(url:root),true)
            model.fileComparisonPreferences=prefs;model.notifyFinder={};workspaces.append(model);return model
        }
        func prepare()async throws {
            for root in [a,b] {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let repo=repository(root)
                _=try await repo.run(["init","--template=","-b","main"])
                for(key,value)in[("user.name","Settings QA"),("user.email","settings@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
                try Data("untouched\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"private base")
                _=try await repo.run(["remote","add","origin",base.appendingPathComponent("origin.git").path])
            }
            originalHead=try await repository(a).run(["rev-parse","HEAD"]).stdout;originalIndex=try Data(contentsOf:a.appendingPathComponent(".git/index"))
            workspace=makeWorkspace(a);appearance=AppAppearance(preferences:prefs)
            service.present={ [weak self] owner in
                guard let self else{return}
                if !self.owners.contains(where:{$0 === owner}) {self.owners.append(owner)}
                owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.showWindow(nil);owner.window?.orderFront(nil)
            }
            service.install(workspace:workspace,appearance:appearance)
        }
        func ready(_ page:SettingsPageID,global:Bool=false)async throws->SettingsNavigationController {
            try await SettingsContextVerification.wait {
                guard let nav=self.service.navigation,let controller=self.service.controller,nav.globalOnly==global,nav.selected==page,nav.canDismiss,!nav.completionPending,
                      let view=controller.window?.contentView else{return false}
                let cancel=SettingsContextVerification.views(view).compactMap{$0 as? NSButton}.last{$0.title=="Cancel"}
                return cancel?.isEnabled==true && (page != .remote || nav.remote != nil)
            }
            return service.navigation!
        }
        func openRemote()async throws->RemoteSettingsWindowModel {
            service.show(initialPage:.remote)
            let nav=try await ready(.remote)
            guard let remote=nav.remote else{throw Failure(description:"Native Remote page absent")}
            try await SettingsContextVerification.wait{!remote.busy && !remote.hasPendingWork}
            return remote
        }
        func dismissNotice()async throws {
            if let owner=service.controller?.window,let sheet=owner.attachedSheet {
                owner.endSheet(sheet,returnCode:.abort);sheet.close();try await SettingsContextVerification.wait{sheet.sheetParent==nil}
            }
        }
        func unchanged()async throws {
            let head=try await repository(a).run(["rev-parse","HEAD"]).stdout
            try SettingsContextVerification.require(head==originalHead && (try Data(contentsOf:a.appendingPathComponent(".git/index")))==originalIndex,"Settings handoff changed HEAD/index")
            try SettingsContextVerification.require(try Data(contentsOf:a.appendingPathComponent("file.txt"))==Data("untouched\n".utf8),"Settings handoff changed working file")
        }
        func cleanup()async {
            workspaces.forEach{$0.stopMonitoringForTermination()}
            releases.forEach{$0()};releases=[]
            try? await dismissNotice()
            for owner in owners.reversed(){owner.close()}
            for _ in 0..<3000 {if SettingsContextVerification.drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func scope(_ c:Context)async throws {
        let remote=try await c.openRemote(),original=c.service.controller!,nav=c.service.navigation!
        c.service.show(initialPage:.git);_=try await c.ready(.git)
        try require(c.service.controller === original,"Same-context activation replaced its owner")
        c.service.show(initialPage:.remote);_=try await c.ready(.remote)
        try require(c.service.navigation?.remote === remote,"Same-context navigation lost cached draft model")
        c.service.show(globalOnly:true,initialPage:.advanced)
        try require(nav.completionPending,"Scope change did not retain asynchronous close")
        c.service.install(workspace:c.workspace,appearance:c.appearance)
        c.service.show(globalOnly:true,initialPage:.unifiedDiff)
        c.workspace.onSettingsPage(true,"blame")
        let global=try await c.ready(.blame,global:true)
        try require(global !== nav && nav.closedByCompletion && c.service.controller !== original,"Newest global page did not replace captured Settings")
        c.workspace.onSettingsPage(false,"gitremote")
        let local=try await c.ready(.remote)
        try require(local !== global && local.remote?.noFetch==true,"Repository page/noFetch request lost across scope close")
        try await c.unchanged()
    }
    static func refusal(_ c:Context)async throws {
        let remote=try await c.openRemote(),controller=c.service.controller!,nav=c.service.navigation!
        remote.select(GitReferenceName("origin"));try await wait{!remote.busy && !remote.hasPendingWork}
        let config=try Data(contentsOf:c.a.appendingPathComponent(".git/config")),draft=c.base.appendingPathComponent("unsaved.git").path
        remote.edit(.url){$0.url=draft};try await wait{!remote.hasPendingWork}
        c.service.show(globalOnly:true,initialPage:.blame)
        try require(c.service.controller === controller && nav.transaction.modified && remote.draft.url==draft && !nav.completionPending,"Dirty context was discarded or queued")
        try await c.dismissNotice()
        try await click("Cancel",controller);try await wait{c.service.controller==nil}
        try require(try Data(contentsOf:c.a.appendingPathComponent(".git/config"))==config,"Refused scope wrote draft")
        c.service.show(initialPage:.blame);let busyNav=try await c.ready(.blame),busyOwner=c.service.controller!
        var changed=true,reply:CheckedContinuation<Bool,Never>?
        busyNav.transaction.register("held-context",participant:.init(page:.blame,modified:{changed},validate:{nil},apply:{let result=await withCheckedContinuation{reply=$0};if result{changed=false};return result},cancel:{changed=false}))
        c.releases.append{reply?.resume(returning:false);reply=nil}
        busyNav.transaction.apply(closeAfter:false);try await wait{reply != nil}
        c.service.show(globalOnly:true,initialPage:.advanced)
        try require(c.service.controller === busyOwner && busyNav.transaction.busy && !busyNav.completionPending,"Busy apply was replaced/queued")
        try await c.dismissNotice();reply?.resume(returning:true);reply=nil
        try await wait{!busyNav.transaction.busy && busyNav.canDismiss}
        try require(c.service.navigation === busyNav && !busyNav.globalOnly,"Rejected request replayed after busy operation")
        try await c.unchanged()
    }
    static func terminal(_ c:Context)async throws {
        _=try await c.openRemote();let original=c.service.controller!,nav=c.service.navigation!
        try await click("Cancel",original)
        try require(nav.completionPending && !c.service.prepareContextChange(),"Terminal close allowed context adoption")
        c.service.show(globalOnly:true,initialPage:.advanced)
        c.service.show(initialPage:.remote,remoteNoFetch:true)
        let replacement=try await c.ready(.remote)
        try require(replacement !== nav && replacement.remote?.noFetch==true,"Newest terminal-race request lost")
        let remote=replacement.remote!,url=c.base.appendingPathComponent("saved-origin.git").path
        remote.select(GitReferenceName("origin"));try await wait{!remote.busy && !remote.hasPendingWork}
        remote.edit(.url){$0.url=url};try await wait{!remote.hasPendingWork && replacement.canDismiss}
        let completed=replacement.transaction.completed
        replacement.transaction.completed={close in completed(close);if close{c.service.show(globalOnly:true,initialPage:.blame)}}
        try await click("OK",c.service.controller!)
        let global=try await c.ready(.blame,global:true)
        try require(global !== replacement && replacement.closedByCompletion,"Successful OK dropped accepted next-page request")
        let saved=try await c.repository(c.a).run(["config","--get","remote.origin.url"]).text
        try require(saved==url+"\n","Successful OK did not persist actual Remote edit")
        try await c.unchanged()
    }
    static func ownership(_ c:Context)async throws {
        _=try await c.openRemote();let forced=c.service.controller!
        c.service.show(globalOnly:true,initialPage:.blame);forced.close()
        try await wait{c.service.controller==nil && drained()};await flushMainQueue()
        try require(c.service.controller==nil,"Forced old-window retirement replayed queued Settings")
        c.service.show(globalOnly:true,initialPage:.blame);_=try await c.ready(.blame,global:true)
        c.service.show(initialPage:.remote)
        c.workspace.root=c.b
        try await wait{c.service.controller==nil && drained()};await flushMainQueue()
        try require(c.service.controller==nil,"Queued repository request adopted a changed root")
        c.workspace.root=c.a
        _=try await c.openRemote()
        let oldWindow=c.service.controller!.window!,staleOpen=c.workspace.onSettings,stalePage=c.workspace.onSettingsPage,staleContext=c.workspace.canChangeSettingsContext
        c.service.show(globalOnly:true,initialPage:.blame)
        let newer=c.makeWorkspace(c.b);c.service.install(workspace:newer,appearance:c.appearance)
        c.service.show(initialPage:.remote);let replacement=try await c.ready(.remote),replacementOwner=c.service.controller!
        c.service.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:oldWindow))
        staleOpen(true);stalePage(true,"blame")
        try require(staleContext() && c.service.controller === replacementOwner && c.service.navigation === replacement,"Stale window/workspace callback affected replacement Settings")
        c.service.show(globalOnly:true,initialPage:.blame)
        newer.stopMonitoringForTermination()
        try await wait{c.service.controller==nil && drained()}
        c.service.show(globalOnly:true,initialPage:.advanced);await flushMainQueue()
        try require(c.service.controller==nil && newer.isRetired,"Retired workspace reopened Settings")
        try await c.unchanged()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let selectors=[(#selector(NSWindow.constrainFrameRect(_:to:)),#selector(NSWindow.settingsContextFrame(_:to:))),(#selector(NSWindow.order(_:relativeTo:)),#selector(NSWindow.settingsContextOrder(_:relativeTo:)))]
        for(a,b)in selectors {if let a=class_getInstanceMethod(NSWindow.self,a),let b=class_getInstanceMethod(NSWindow.self,b){method_exchangeImplementations(a,b)}}
        defer{for(a,b)in selectors.reversed(){if let a=class_getInstanceMethod(NSWindow.self,a),let b=class_getInstanceMethod(NSWindow.self,b){method_exchangeImplementations(a,b)}}}
        let c=Context(),name=CommandLine.arguments[3]
        do {
            try await c.prepare()
            switch name {case "scope":try await scope(c);case "refusal":try await refusal(c);case "terminal":try await terminal(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")}
            await c.cleanup();try require(drained(),"Owned Settings work did not drain");print("PASS: settings context "+name)
        } catch {await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}
