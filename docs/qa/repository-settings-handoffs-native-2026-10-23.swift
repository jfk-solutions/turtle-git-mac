// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func contextHandoffFrame(_ requested:NSRect,to screen:NSScreen?)->NSRect {requested}
    @objc func contextHandoffOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));contextHandoffOrder(mode,relativeTo:number)}
}
@MainActor @main enum RepositorySettingsHandoffsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Owner handoff \(line): "+message)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Owner handoff timeout \(line)")}
    static func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    static func own(_ owner:NSWindowController){owner.window?.alphaValue=0;owner.window?.orderFront(nil)}
    static func drained()->Bool{CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeCommitPreflights==0 && BlameWindowModel.activeHistoryOperations==0 && RemoteSettingsWindowModel.activeOperations==0 && RemoteSettingsWindowModel.activeRetirements==0 && SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ContextHandoffs."+UUID().uuidString,prefs:UserDefaults
        let service=SettingsPresentationService.shared
        var workspace:RepositoryModel!,host:NSWindow!,appearance:AppAppearance!,store:RepositoryAccessStore!
        var settingsOpenCount=0
        var owners:[NSWindowController]=[],commits:[CommitWindowController]=[],release:[()->Void]=[]
        var a:URL{root.appendingPathComponent("a")};var b:URL{root.appendingPathComponent("b")}
        var revisionHold:URL{root.appendingPathComponent("revision-hold")};var revisionStarted:URL{root.appendingPathComponent("revision-started")}
        var hold:URL{root.appendingPathComponent("hold")};var started:URL{root.appendingPathComponent("discovery-started")};var wrapper:URL{root.appendingPathComponent("held-helper")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(1,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint")}
        func seed()async throws {
            for folder in [a,b] {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let repo=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
                _=try await repo.run(["init","--template=","-b","main"])
                for(key,value)in[("user.name","Context QA"),("user.email","context@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
                try Data("base\n".utf8).write(to:folder.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"private base")
                _=try await repo.run(["remote","add","origin",root.appendingPathComponent("private-origin.git").path])
            }
            let script="#!/bin/sh\nfor argument in \"$@\"; do\n if test \"$argument\" = --show-toplevel && test -f "+quote(hold.path)+"; then\n  : > "+quote(started.path)+"\n  while test -f "+quote(hold.path)+"; do /bin/sleep 0.05; done\n fi\n if test \"$argument\" = \"HEAD^{commit}\" && test -f "+quote(revisionHold.path)+"; then\n  : > "+quote(revisionStarted.path)+"\n  while test -f "+quote(revisionHold.path)+"; do /bin/sleep 0.05; done\n fi\ndone\nexec "+quote(git.path)+" \"$@\"\n"
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            store=try RepositoryAccessStore(storageURL:root.appendingPathComponent("access.json"))
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git,wrapper,b] url in GitRepository(root:url,executable:url.standardizedFileURL.resolvingSymlinksInPath().path==b.standardizedFileURL.resolvingSymlinksInPath().path ? wrapper:git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
            workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
            host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
            appearance=AppAppearance(preferences:prefs)
            service.present={ [weak self] owner in self?.owners.append(owner);own(owner)};service.install(workspace:workspace,appearance:appearance)
            workspace.commitWindowFactory={ [weak self] repo,access in
                guard let self else{return CommitWindowController(repository:repo,access:access)}
                let owner=CommitWindowController(repository:repo,access:access,defaults:self.prefs);owner.model.confirmCancel={$0(true)};self.commits.append(owner);self.owners.append(owner);return owner
            }
            workspace.open(a);try await wait(host){self.workspace.root==self.a && !self.workspace.busy}
        }
        func remoteSettings()async throws->RemoteSettingsWindowModel {
            // Reopen immediately after the prior controller closes. Production
            // must defer page construction while its retired native page drains.
            settingsOpenCount += 1;print("Opening actual Remote Settings phase \(settingsOpenCount)");fflush(stdout)
            service.show(globalOnly:false,initialPage:.remote)
            do {try await wait(service.controller?.window){self.service.navigation?.remote != nil && self.service.navigation?.remote?.busy==false}}
            catch {print("Remote readiness phase=\(settingsOpenCount) selected=\(String(describing:service.navigation?.selected)) loaded=\(service.navigation?.isViewLoaded == true) remote=\(service.navigation?.remote != nil) busy=\(String(describing:service.navigation?.remote?.busy)) operations=\(RemoteSettingsWindowModel.activeOperations) retirements=\(RemoteSettingsWindowModel.activeRetirements) settingsRetirements=\(SettingsTransaction.activeRetirements) workspaceRoot=\(workspace.root?.path ?? "nil")");fflush(stdout);throw error}
            guard let remote=service.navigation?.remote else{throw Failure(description:"Actual Remote settings page missing")}
            try await wait(service.controller?.window){!remote.busy && !remote.hasPendingWork && remote.names.contains(GitReferenceName("origin"))}
            remote.select(GitReferenceName("origin"));try await wait(service.controller?.window){remote.selected==GitReferenceName("origin") && !remote.busy && !remote.hasPendingWork}
            return remote
        }
        func dismissNotice()async throws {
            if let parent=service.controller?.window,let sheet=parent.attachedSheet {parent.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}}
        }
        func closeSettings()async throws {try await dismissNotice();service.controller?.close();try await wait{self.service.controller==nil && self.service.navigation==nil}}
        func clean()async {
            try? FileManager.default.removeItem(at:hold);try? FileManager.default.removeItem(at:revisionHold);release.forEach{$0()};release=[]
            try? await closeSettings();owners.forEach{$0.close()};workspace?.stopMonitoringForTermination();host?.close()
            for _ in 0..<3000{if drained() && workspace?.busy != true{break};try? await Task.sleep(nanoseconds:10_000_000)}
            service.present={ $0.showWindow(nil);$0.window?.makeKeyAndOrderFront(nil) };prefs.removePersistentDomain(forName:suite)
        }
    }
    static func repository(_ c:Context)async throws {
        let remote=try await c.remoteSettings(),draft=c.root.appendingPathComponent("unsaved-origin.git").path
        remote.edit(.url){$0.url=draft}
        try require(c.service.navigation?.transaction.modified==true,"Actual Remote draft did not become modified")
        var opened=0;c.workspace.open(c.b){opened+=1};try await wait(c.host){!c.workspace.busy}
        try require(c.workspace.root==c.a && opened==0 && remote.draft.url==draft && !remote.changed.isEmpty,"Open rebound/discarded dirty Settings context")
        try await c.dismissNotice()
        let saved=try c.store.remember(c.b);c.workspace.openRecent(saved);try await wait(c.host){!c.workspace.busy}
        try require(c.workspace.root==c.a && remote.draft.url==draft,"Recent rebound dirty Settings context");try await c.dismissNotice()
        c.workspace.closeRepository();try require(c.workspace.root==c.a && remote.draft.url==draft,"Close Repository cleared dirty Settings owner");try await c.dismissNotice()
        c.workspace.open(c.a){opened+=1};try await wait(c.host){!c.workspace.busy && opened==1}
        try require(c.workspace.root==c.a && remote.draft.url==draft && c.service.navigation?.transaction.modified==true,"Same-root reload was blocked or discarded Settings draft")
        try await c.closeSettings()
        let late=try await c.remoteSettings();try require(c.service.navigation?.transaction.modified==false,"Fresh Settings did not start clean")
        // Remote name publication schedules a real workspace refresh. Wait for
        // that accepted read before issuing Open, whose busy guard must remain.
        try await wait(c.host){!c.workspace.busy && late.hasPendingWork==false && c.service.navigation?.canDismiss==true}
        try? FileManager.default.removeItem(at:c.started);try Data().write(to:c.hold)
        c.workspace.open(c.b){opened+=1}
        do {try await wait{FileManager.default.fileExists(atPath:c.started.path) && c.workspace.busy}}
        catch {print("Discovery hold missing: busy=\(c.workspace.busy) root=\(c.workspace.root?.path ?? "nil") error=\(c.workspace.error ?? "nil") remoteBusy=\(late.busy) settingsCanDismiss=\(c.service.navigation?.canDismiss == true) expectedB=\(c.b.standardizedFileURL.resolvingSymlinksInPath().path) marker=\(FileManager.default.fileExists(atPath:c.started.path))");fflush(stdout);throw error}
        late.edit(.url){$0.url=draft};try require(c.service.navigation?.transaction.modified==true,"Late actual Settings draft was not captured")
        try FileManager.default.removeItem(at:c.hold);try await wait(c.host){!c.workspace.busy}
        try require(c.workspace.root==c.a && opened==1 && late.draft.url==draft && c.workspace.error==nil,"Late async discovery adopted stale context or emitted false Git failure")
        try await c.dismissNotice();try await c.closeSettings()
        let selected=try await c.remoteSettings()
        try await wait(c.host){!c.workspace.busy && !selected.hasPendingWork && c.service.navigation?.canDismiss==true}
        try Data().write(to:c.revisionHold)
        c.workspace.handleCommandLine(arguments:["--command=log","--path",c.b.path,"--rev","HEAD"],currentDirectory:c.a.path)
        do {try await wait{FileManager.default.fileExists(atPath:c.revisionStarted.path) && c.workspace.busy}}
        catch {print("Selected revision hold missing: busy=\(c.workspace.busy) root=\(c.workspace.root?.path ?? "nil") error=\(c.workspace.error ?? "nil") settingsCanDismiss=\(c.service.navigation?.canDismiss == true) marker=\(FileManager.default.fileExists(atPath:c.revisionStarted.path))");fflush(stdout);throw error}
        try require(c.workspace.root==c.a,"Selected Log revision preflight published another root before completing")
        selected.edit(.url){$0.url=draft}
        try FileManager.default.removeItem(at:c.revisionHold);try await wait(c.host){!c.workspace.busy}
        try require(c.workspace.root==c.a && selected.draft.url==draft && c.workspace.error==nil,"Selected Log revision late adoption crossed dirty Settings context")
        try await c.dismissNotice();try await c.closeSettings()
        // Keep close/reopen/supersede in one actor turn: the old native Remote
        // retirement is real, and no fabricated counters or readiness wait can
        // conceal a dropped initial-page request.
        _ = try await c.remoteSettings()
        let previous=c.service.navigation!;c.service.controller!.close()
        c.service.show(globalOnly:false,initialPage:.remote)
        let replacement=c.service.navigation!
        c.service.show(globalOnly:false,initialPage:.blame)
        func headings(_ view:NSView)->[String] {var result:[String]=[];if let field=view as? NSTextField,field.identifier?.rawValue=="Settings.PageHeading" {result.append(field.stringValue)};return result+view.subviews.flatMap{headings($0)}}
        try await wait(c.service.controller?.window){replacement.selected == .blame && headings(replacement.view).contains("TurtleGitBlame")}
        try require(replacement !== previous && replacement.remote==nil,"Retired initial Remote request superseded the accepted Blame page")
        c.service.controller!.close();c.service.show(globalOnly:false,initialPage:.remote)
        let cancelled=c.service.navigation!;c.service.controller!.close()
        try await wait{RemoteSettingsWindowModel.activeRetirements==0 && SettingsTransaction.activeRetirements==0}
        try require(c.service.controller==nil && cancelled.remote==nil,"Closed initial-page retry recreated a native Remote page")
        // Root adoption has its own legitimate busy-page fence. First settle
        // this clean Remote page; immediate-reopen/supersession/cancellation
        // above remain synchronous and do not wait for retired page readiness.
        c.service.show(globalOnly:false,initialPage:.remote)
        let changing=c.service.navigation!
        try await wait(c.service.controller?.window){changing.remote != nil && changing.remote?.busy==false && changing.remote?.hasPendingWork==false && changing.canDismiss && !c.workspace.busy}
        c.workspace.open(c.b);try await wait(c.host){!c.workspace.busy && c.workspace.root==c.b}
        try await wait(c.service.controller?.window){changing.selected == .git && headings(changing.view).contains("Git")}
        try require(changing.remote==nil,"Deferred initial Remote page retained the previous repository context")
        try await c.closeSettings();c.workspace.closeRepository();try require(c.workspace.root==nil,"Clean Settings context still blocked Close Repository")
    }
    static func commit(_ c:Context)async throws {
        try Data("base\nchanged\n".utf8).write(to:c.a.appendingPathComponent("file.txt"));await c.workspace.refresh()
        try await wait(c.host){!c.workspace.busy}
        c.workspace.activate(.commit);try await wait{c.commits.count==1 && !c.commits[0].model.busy && c.commits[0].commandsAvailable}
        let owner=c.commits[0],model=owner.model
        var held:CheckedContinuation<URL?,Never>?,entered=false
        model.chooseExportFolder={_ in entered=true;return await withCheckedContinuation{held=$0}}
        c.release.append{let current=held;held=nil;current?.resume(returning:nil)}
        model.fileAction(.export,snapshot:model.fileMenu(["file.txt"]))
        try await wait{entered && model.fileWorkPending}
        var closed=0;let original=owner.onClosed;owner.onClosed={closed+=1;original()}
        owner.close();try require(!owner.canReuse && !model.messageFocusAvailable && closed==0 && model.fileWorkPending,"Closing Commit released/reused before held chooser drained")
        let windows=Set(NSApp.windows.map(ObjectIdentifier.init))
        owner.showWindow(nil);c.workspace.activate(.commit);model.showViewPatch();model.showPartial(false)
        try await Task.sleep(nanoseconds:100_000_000)
        try require(c.commits.count==1 && !owner.canReuse && owner.window?.isVisible != true && closed==0 && Set(NSApp.windows.map(ObjectIdentifier.init)).isSubset(of:windows),"Retired cached Commit reopened/replaced/presented stale companions")
        let current=held;held=nil;current?.resume(returning:nil)
        try await wait{closed==1 && !model.fileWorkPending}
        c.workspace.activate(.commit);try await wait{c.commits.count==2 && !c.commits[1].model.busy && c.commits[1].canReuse}
        try require(c.commits[1] !== owner && closed==1,"Drained Commit cache did not hand off to a fresh owner")
    }
    static func blame(_ c:Context)async throws {
        let owner=BlameWindowController(repository:GitRepository(root:c.a,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false)),access:nil,path:"file.txt",revision:"HEAD",preferences:c.prefs);c.owners.append(owner);own(owner)
        try await wait(owner.window){!owner.model.busy && owner.model.canFind}
        owner.model.showSettings();try await wait(c.service.controller?.window){c.service.navigation?.selected == .blame}
        try require(c.service.navigation?.globalOnly==true,"Blame Settings opened General/repository context")
        try await c.closeSettings();owner.model.confirmingQuit=true;owner.model.showSettings();try require(c.service.controller==nil,"Blame Settings crossed Quit fence")
        owner.model.confirmingQuit=false;owner.close();owner.model.showSettings();try require(c.service.controller==nil,"Retired Blame revived Settings")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.contextHandoffFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.contextHandoffOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.seed();let kind=CommandLine.arguments[3];switch kind{case "repository":try await repository(c);case "commit":try await commit(c);case "blame":try await blame(c);default:throw Failure(description:"Unknown handoff case")};await c.clean();try require(drained() && c.workspace.busy==false && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned handoff work/windows did not drain");print("PASS: repository Settings handoffs "+kind);fflush(stdout)}catch{await c.clean();fputs("Repository Settings handoffs failed: \(error)\n",stderr);exit(1)}
    }
}
