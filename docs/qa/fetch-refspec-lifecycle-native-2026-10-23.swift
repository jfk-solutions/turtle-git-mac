// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func sourceFetchHiddenOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));sourceFetchHiddenOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum FetchRefspecLifecycleVerification {
    typealias Base=SyncTransferNotificationsVerification
    typealias Context=Base.Context
    static let originalSpec="+refs/heads/main:refs/remotes/origin/main"
    static let selectedSpec="refs/heads/topic:refs/remotes/origin/topic"
    static func seed(_ c:Context)async throws {
        try await c.seed()
        let author=GitRepository(root:c.root.appendingPathComponent("author"),executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await author.run(["push",c.root.appendingPathComponent("origin.git").path,c.old+":refs/heads/topic"])
        _=try await c.repository.run(["config","--local","--replace-all","remote.origin.fetch",originalSpec])
    }
    static func specs(_ c:Context)async throws->[String] {
        let data=try await c.repository.run(["config","--local","--null","--get-all","remote.origin.fetch"]).stdout
        return data.split(separator:0).map{String(decoding:$0,as:UTF8.self)}
    }
    static func reference(_ c:Context,_ name:String)async throws->String? {
        let result=try await c.repository.run(["show-ref","--verify","--hash",name],successfulExitCodes:0...128)
        return result.exitCode==0 ? result.text.trimmingCharacters(in:.newlines):nil
    }
    static func settled(_ owner:SynchronizationWindowController)async throws {
        try await Base.wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && owner.model.commandCompleted}
    }
    static func exactSpecs(_ c:Context)async throws {
        let actual=try await specs(c)
        try Base.require(actual==[originalSpec]+c.expectedFetchSpecs,"Persisted source refspec order/duplicates differ: \(actual)")
        try await c.preserved()
    }
    static func sync(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model;model.remoteBranch="topic"
        c.expectedFetchSpecs.append(selectedSpec);model.fetch();try await settled(owner)
        try Base.require(model.commandSucceeded && model.showsNotifications,"First source Fetch failed: \(model.error ?? model.commandOutput)")
        let main=try await reference(c,"refs/remotes/origin/main"),topic=try await reference(c,"refs/remotes/origin/topic")
        try Base.require(main==c.new && topic==nil,"First invocation did not use the previously loaded main-only refspec")
        let (_,coordinator)=try await Base.table(owner)
        try Base.require(coordinator.rows.contains{$0.reference?.oldHash==c.old && $0.reference?.newHash==c.new},"Loaded old refspec lost its actual forward receipt")
        let caption=try Base.unwrap(model.notifications.rows.first?.path,"Source command caption missing")
        try Base.require(caption=="Fetch origin "+selectedSpec,"Sync did not retain full qualified requested refspec caption: \(caption)")
        model.remoteBranch="unaccepted-topic-edit"
        try Base.require(model.notifications.rows.first?.path==caption,"Current form edit changed accepted command context")
        model.remoteBranch="topic";try await exactSpecs(c)
        c.expectedFetchSpecs.append(selectedSpec);model.fetch();try await settled(owner)
        let laterTopic=try await reference(c,"refs/remotes/origin/topic")
        try Base.require(model.commandSucceeded && laterTopic==c.old,"Next invocation did not load the previously appended destination mapping")
        try Base.require(model.notifications.rows.contains{$0.kind == .reference && $0.reference?.newHash==c.old && $0.path.contains("refs/remotes/origin/topic")},"New topic ref lost its typed callback")
        try await exactSpecs(c)
        model.fetch(.fetchAllBranches);try await settled(owner)
        try Base.require(model.commandSucceeded,"Fetch All failed");try await exactSpecs(c)
        // The real Remote settings page has no invented refspec editor. Closing
        // its owned sheet must refresh Sync's actual names/selection/results.
        owner.showRemoteSettings()
        try await Base.wait(owner.window){owner.remoteSettingsController != nil && owner.remoteSettingsController?.model.busy==false}
        let settings=try Base.unwrap(owner.remoteSettingsController,"Owned Remote settings did not open")
        try await Base.wait(settings.window){settings.model.names.contains(GitReferenceName("origin")) && !settings.model.hasPendingWork}
        settings.model.select(GitReferenceName("origin"))
        try await Base.wait(settings.window){settings.model.selected==GitReferenceName("origin") && !settings.model.busy && !settings.model.hasPendingWork}
        settings.close()
        try await Base.wait(owner.window){owner.remoteSettingsController==nil && !model.managingRemotes && !model.busy && !model.hasPendingInlineWork}
        try await exactSpecs(c)
    }
    static func standalone(_ c:Context,_ progress:inout [FetchProgressWindowController])async throws {
        _=try await c.open()
        for invocation in 0..<2 {
            var options=FetchOptions();options.remote="origin";options.branch="topic";options.namedRemoteFetchAll=false
            let backend=GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.fetch.mask,helperURL:c.root.appendingPathComponent("held-helper"))
            let model=FetchProgressWindowModel(repository:c.repository,access:RepositoryAccessLease(url:c.repository.root),options:options,preferences:c.preferences,backend:backend)
            let owner=FetchProgressWindowController(model:model);progress.append(owner);owner.window?.orderFront(nil)
            c.expectedFetchSpecs.append("topic");await model.run()
            try await Base.wait(owner.window){!model.busy && model.pendingOperations==0}
            try Base.require(model.success && model.showsNotifications,"Standalone selected source Fetch failed: \(model.output)")
            let main=try await reference(c,"refs/remotes/origin/main"),topic=try await reference(c,"refs/remotes/origin/topic")
            try Base.require(main==c.new && topic==nil,"Standalone raw branch was incorrectly rewritten into a tracking destination")
            if invocation==1 {
                let fetched=try String(contentsOf:c.repository.root.appendingPathComponent(".git/FETCH_HEAD"),encoding:.utf8)
                try Base.require(fetched.contains(c.old) && fetched.contains("topic"),"Second standalone invocation did not load appended raw branch")
            }
            try await exactSpecs(c);owner.close()
        }
        var options=FetchOptions();options.remote="origin";options.branch="topic";options.namedRemoteFetchAll=false
        let model=FetchProgressWindowModel(repository:c.repository,access:RepositoryAccessLease(url:c.repository.root),options:options,preferences:c.preferences,backend:.init(enabled:false))
        let owner=FetchProgressWindowController(model:model);progress.append(owner);owner.window?.orderFront(nil);await model.run()
        try Base.require(model.success && !model.showsNotifications,"CLI standalone Fetch adopted selected-library presentation")
        try await exactSpecs(c);owner.close()
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model;model.remoteBranch="topic"
        let originalURL=c.root.appendingPathComponent("origin.git").path
        _=try await c.repository.run(["config","remote.origin.url",c.root.appendingPathComponent("unavailable-origin.git").path])
        c.expectedFetchSpecs.append(selectedSpec);model.fetch();try await settled(owner)
        try Base.require(!model.commandSucceeded && model.showsNotifications && model.notifications.rows.contains{$0.kind == .error} && model.notifications.rows.last?.kind == .finished,"Transport failure after source append lost actual Error/Finished outcome")
        let failedMain=try await reference(c,"refs/remotes/origin/main")
        try Base.require(failedMain==c.old && !model.notifications.rows.contains{$0.kind == .reference},"Failed unavailable origin fabricated an update")
        let afterFailure=try await specs(c)
        try Base.require(afterFailure==[originalSpec,selectedSpec],"Real transport failure rolled back or omitted the preceding source config append")
        _=try await c.repository.run(["config","remote.origin.url",originalURL]);try await exactSpecs(c)
        c.expectedFetchSpecs.append(selectedSpec);model.fetch();try await settled(owner)
        try Base.require(model.commandSucceeded,"Explicit retry after repairing origin failed");try await exactSpecs(c)
        try? FileManager.default.removeItem(at:c.started);try Data().write(to:c.hold)
        c.expectedFetchSpecs.append(selectedSpec);model.fetch()
        try await Base.wait(owner.window){FileManager.default.fileExists(atPath:c.started.path) && model.busy}
        model.cancelTransport();try await Base.wait(owner.window){!model.busy && !model.hasPendingInlineWork}
        try Base.require(model.commandCancelled,"Cancel failed to preserve actual cancellation outcome")
        try await exactSpecs(c)
        try? FileManager.default.removeItem(at:c.started);try Data().write(to:c.hold)
        c.expectedFetchSpecs.append(selectedSpec);model.fetch()
        try await Base.wait(owner.window){FileManager.default.fileExists(atPath:c.started.path) && model.busy}
        var closed=0;owner.onClosed={closed+=1};model.confirmingQuit=true;owner.close()
        let rows=model.notifications.rows.map(\.id),generation=model.notifications.generation
        try await Base.wait{closed==1 && !model.hasPendingInlineWork && Base.drained()}
        try Base.require(model.closed && model.notifications.rows.map(\.id)==rows && model.notifications.generation==generation && !model.notificationActionsAvailable && !model.notificationKeyboardAvailable,"Retired source Fetch published late actions or rows")
        try await exactSpecs(c)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.sourceFetchHiddenOrder(_:relativeTo:))){method_exchangeImplementations(original,hidden)}
        let c=Context(),kind=CommandLine.arguments[4];var progress:[FetchProgressWindowController]=[]
        func cleanup()async {try? FileManager.default.removeItem(at:c.hold);for owner in progress {owner.close()};await c.cleanup();for _ in 0..<3000 {if FetchProgressWindowModel.activeOperations==0 && FetchWindowController.activeProgressReleases==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}}
        do {
            try await seed(c)
            switch kind {case "sync":try await sync(c);case "standalone":try await standalone(c,&progress);case "ownership":try await ownership(c);default:throw Base.Failure(description:"Unknown source Fetch case")}
            await cleanup()
            try Base.require(Base.drained() && FetchProgressWindowModel.activeOperations==0 && FetchWindowController.activeProgressReleases==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Source Fetch owners/windows did not drain")
            print("PASS: Fetch refspec lifecycle "+kind);fflush(stdout)
        }catch {await cleanup();fputs("Fetch refspec lifecycle failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
