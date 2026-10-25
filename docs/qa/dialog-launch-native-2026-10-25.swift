// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Carbon
import TurtleGitCore

@MainActor enum DialogLaunchVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:"Dialog launch: "+message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Dialog launch timeout: "+message)}
    static func children(since baseline:Set<ObjectIdentifier>)->[NSWindowController] {
        NSApp.windows.filter{!baseline.contains(ObjectIdentifier($0))}.compactMap(\.windowController)
    }
    static func closeChildren(since baseline:Set<ObjectIdentifier>)async throws {
        let controllers=children(since:baseline)
        for controller in controllers {controller.close()}
        try await wait("owned dialog children drain") {TurtleGitAboutController.activeReads==0 && LogWindowModel.activeHistoryLoads==0 && controllers.allSatisfy{$0.window?.attachedSheet==nil && $0.window?.sheetParent==nil && $0.window?.isVisible != true}}
    }
    /// Exercise the public event manager dispatch path, not the delegate method.
    static func dispatchURL(_ text:String)throws {
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kInternetEventClass),eventID:AEEventID(kAEGetURL),targetDescriptor:NSAppleEventDescriptor(processIdentifier:ProcessInfo.processInfo.processIdentifier),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string:text),forKeyword:AEKeyword(keyDirectObject))
        let reply=NSAppleEventDescriptor.null()
        guard let rawEvent=event.aeDesc,let rawReply=reply.aeDesc else {
            throw Failure(description:"Apple-event descriptor allocation failed")
        }
        var ownedRefCon:UInt8=0
        _ = withUnsafeMutablePointer(to:&ownedRefCon) { pointer in
            NSAppleEventManager.shared().dispatchRawAppleEvent(rawEvent,withRawReply:UnsafeMutablePointer(mutating:rawReply),handlerRefCon:UnsafeMutableRawPointer(pointer))
        }
    }
    static func verify(repository:GitRepository,existing:RepositoryModel,preferences:UserDefaults)async throws {
        let git=repository.executable,folder=repository.root
        var models=[RepositoryModel](),delegates=[TurtleGitApplicationDelegate](),settings=[SettingsPresentationService](),appearances=[AppAppearance]()
        defer {
            for delegate in delegates {delegate.retireInboundURLBridge();delegate.retireFinderServices();delegate.workspaceOpenHandoff.retire();delegate.actionErrorController?.close()}
            for model in models {model.stopMonitoringForTermination()}
            for service in settings {service.controller?.close()}
        }
        func configure(_ delegate:TurtleGitApplicationDelegate)throws->RepositoryModel {
            // A real persisted private bookmark grants the selected repository
            // to both CLI and later Finder requests. No interactive system panel
            // or user bookmark archive belongs to this offscreen receiver.
            let provider=RegistrationBookmarks()
            let store=try RepositoryAccessStore(storageURL:folder.deletingLastPathComponent().appendingPathComponent("dialog-access-"+UUID().uuidString+".json"),provider:provider)
            let saved=try store.remember(folder),grant=try store.acquire(saved.id,requireSecurityScope:true)
            try require(grant.hasSecurityScope && grant.contains(folder),"Private dialog repository grant was not acquired")
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in true},savedAccessStore:store)
            model.requiresRepositoryScope=true;model.repositoryBookmarkProvider=provider
            model.commandLineRepositoryPermission={paths in
                try require(paths.allSatisfy{grant.contains($0)},"CLI requested a repository outside its owned grant")
                return grant
            }
            model.fileComparisonPreferences=preferences;models.append(model)
            let appearance=AppAppearance(preferences:preferences),service=SettingsPresentationService();appearances.append(appearance);settings.append(service)
            delegate.makeStandaloneWorkspace={model}
            delegate.configureStandaloneServices={workspace,_ in service.install(workspace:workspace,appearance:appearance)}
            delegate.startupDirectory=folder.path;delegates.append(delegate);return model
        }
        // A URL launch may arrive without OpenConfiguration.arguments. Capture
        // real Apple-event delivery before startup and refuse a default workspace.
        let eventDelegate=TurtleGitApplicationDelegate(),eventModel=try configure(eventDelegate)
        eventDelegate.startupArguments=[];eventDelegate.configureGeneralApplication={_ in}
        var eventPresentations=0,eventURLs=[URL]()
        eventDelegate.presentWorkspace={eventPresentations += 1}
        eventDelegate.activateStandaloneApplication={}
        eventDelegate.workspaceOpenHandler={target,url in
            if target === eventModel {eventURLs.append(url)}
        }
        eventDelegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        let eventActions:[RepositoryAction]=[.registerRepository,.clone,.settings,.about,.help]
        let eventURLsExpected=try eventActions.map {action -> URL in
            guard let url=FinderRequest(action:action,paths:[folder]).url else {throw Failure(description:"Event action URL unavailable")}
            return url
        }
        for url in eventURLsExpected {try dispatchURL(url.absoluteString)}
        try require(eventURLs.isEmpty,"Cold GetURL bypassed startup ownership")
        eventDelegate.startupDidFinishLaunching(defaultLaunch:true)
        try require(eventURLs==eventURLsExpected && eventPresentations==0 && eventModel.workspaceWindow==nil,"Cold GetURL queue lost routing/order or created default workspace")
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try require(eventURLs.count==eventURLsExpected.count+2,"Repeated warm GetURL was dropped or delivered twice")
        for invalid in ["https://example.invalid/", "turtlegit://unknown", "turtlegit://workspace?unexpected=1", "turtlegit://workspace\0"] {try dispatchURL(invalid)}
        try require(eventURLs.count==eventURLsExpected.count+2 && eventPresentations==0,"Malformed GetURL entered routing")
        // Replacement owns the global event slot; retiring its predecessor must
        // neither remove that slot nor steal it back at a deferred boundary.
        eventDelegate.finishInstallingInboundURLBridge() // queues the actual launch reassertion
        let successor=TurtleGitApplicationDelegate(),successorModel=try configure(successor)
        successor.startupArguments=["--turtlegit-action-only"];successor.activateStandaloneApplication={}
        var successorURLs=[URL]()
        successor.workspaceOpenHandler={target,url in if target === successorModel {successorURLs.append(url)}}
        successor.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        successor.startupDidFinishLaunching()
        eventDelegate.retireInboundURLBridge()
        eventDelegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        await Task.yield()
        // Drain the queued launch reassertion before testing the successor.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try require(successorURLs==[eventURLsExpected[0]] && eventURLs.count==eventURLsExpected.count+2,"Old handler retirement removed successor or redelivered URL")
        successor.retireInboundURLBridge()
        successor.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try require(successorURLs.count==1,"Retired handler accepted late GetURL")
        eventModel.stopMonitoringForTermination();successorModel.stopMonitoringForTermination()
        // Tool processes hand every accepted external URL to their existing
        // separate-host handoff, never to the waiting Git tool's own workspace.
        for marker in ["--merge-tool","--unified-diff"] {
            let tool=TurtleGitApplicationDelegate(),toolModel=try configure(tool)
            tool.startupArguments=[marker];tool.activateStandaloneApplication={}
            tool.startupCommandHandler={_,_,_ in}
            var forwarded=[[URL]](),toolPresentations=0
            tool.presentWorkspace={toolPresentations += 1}
            tool.workspaceOpenHandoff.launch={urls,_,_,reply in forwarded.append(urls);reply(nil)}
            tool.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
            tool.startupDidFinishLaunching()
            try dispatchURL(eventURLsExpected[0].absoluteString)
            let patch=folder.appendingPathComponent("literal Café.patch")
            try dispatchURL(patch.absoluteString)
            try require(forwarded==[[eventURLsExpected[0]],[patch]] && toolPresentations==0 && toolModel.workspaceWindow==nil && !tool.workspaceOpenHandoff.hasPendingWork,"Tool GetURL escaped existing separate-host handoff: "+marker)
            tool.retireInboundURLBridge();tool.workspaceOpenHandoff.retire();toolModel.stopMonitoringForTermination()
        }

        let internalDelegate=TurtleGitApplicationDelegate(),internalModel=try configure(internalDelegate)
        var internalPresentations=0,internalActivations=0
        internalDelegate.startupArguments=["--turtlegit-action-only"]
        internalDelegate.presentWorkspace={internalPresentations += 1};internalDelegate.activateStandaloneApplication={internalActivations += 1}
        internalDelegate.startupDidFinishLaunching()
        try require(internalDelegate.startupLaunchMode == .actionOnly && internalPresentations==0 && internalActivations==0 && internalModel.workspaceWindow==nil,"Bare action-only bootstrap presented/activated workspace")
        internalDelegate.retireFinderServices();internalModel.stopMonitoringForTermination()
        for command in ["about","settings","log"] {
            let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),delegate=TurtleGitApplicationDelegate(),model=try configure(delegate)
            var workspacePresentations=0,forcedActivations=0
            delegate.presentWorkspace={workspacePresentations += 1};delegate.activateStandaloneApplication={forcedActivations += 1}
            delegate.startupArguments=["/command:"+command,"/path:"+folder.path]
            try require(delegate.startupLaunchMode == .actionOnly,"Cold command did not select action-only scene: "+command)
            delegate.startupDidFinishLaunching()
            try await wait("cold actual "+command) {
                switch command {
                case "about":return children(since:baseline).contains{$0 is TurtleGitAboutController}
                case "settings":return settings.last?.controller != nil
                default:return children(since:baseline).compactMap{$0 as? LogWindowController}.contains{$0.model.repository.root.path==folder.path && !$0.model.busy}
                }
            }
            try require(delegate.actionRepositoryModel === model && model.workspaceWindow==nil && workspacePresentations==0 && forcedActivations==1 && !delegate.applicationShouldOpenUntitledFile(NSApp),"Cold CLI action lost dialog activation or presented a workspace: "+command)
            try require(delegate.actionErrorController==nil,"Cold valid action produced error: "+command)
            try await closeChildren(since:baseline)
            // Explicit Open is deliberately a new workspace intent, whereas the
            // action above must never have launched it implicitly.
            var forwarded=[[URL]](),configurations=[[String]]()
            delegate.workspaceOpenHandoff.launch={urls,_,configuration,reply in forwarded.append(urls);configurations.append(configuration.arguments);reply(nil)}
            guard let registration=FinderRequest(action:.registerRepository,paths:[folder]).url,let log=FinderRequest(action:.log,paths:[folder]).url else{throw Failure(description:"Action handoff URL unavailable")}
            var actionConfigurations=[([String],Bool)]()
            let handoff=WorkspaceOpenHandoff()
            handoff.launch={_,_,configuration,reply in actionConfigurations.append((configuration.arguments,configuration.activates));reply(nil)}
            handoff.submit([registration]);handoff.submit([log])
            try require(actionConfigurations.count==2 && actionConfigurations[0].0==["--turtlegit-action-only"] && !actionConfigurations[0].1 && actionConfigurations[1].0==["--turtlegit-action-only"] && actionConfigurations[1].1 && !handoff.hasPendingWork,"Action handoff lost dialog-only launch or registration activation policy")
            handoff.retire()
            let explicitHost=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            explicitHost.isReleasedWhenClosed=false;explicitHost.alphaValue=0;model.workspaceWindow=explicitHost
            defer {explicitHost.close();if model.workspaceWindow === explicitHost {model.workspaceWindow=nil}}
            delegate.requestWorkspace()
            try require(workspacePresentations==1 && forwarded.isEmpty && configurations.isEmpty && delegate.repositoryModel === model,"Explicit workspace request did not retain in-process presentation")
            var opened=[[URL]]()
            delegate.workspaceOpenSelectionHandler={target,paths in
                guard target === model else {return false};opened.append(paths);return true
            }
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.writeObjects([folder as NSURL])
            var error:NSString?;delegate.finderServicesProvider.openInTurtleGit(board,userData:"open",error:&error)
            try require(error==nil && opened.count==1 && opened[0].map(\.path)==[folder.path] && forwarded.isEmpty,"Generic public Service did not explicitly route workspace Open")
            delegate.retireFinderServices();model.stopMonitoringForTermination()
        }
        let originalRoot=existing.root,originalWindow=existing.workspaceWindow
        let delegate=TurtleGitApplicationDelegate(),privateModel=try configure(delegate)
        var requested=0;delegate.startupArguments=[];delegate.repositoryModel=existing;delegate.presentWorkspace={requested += 1};delegate.startupDidFinishLaunching()
        delegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        for action in [RepositoryAction.about,.settings,.log] {
            let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),before=requested
            guard let url=FinderRequest(action:action,paths:[folder]).url else{throw Failure(description:"Action URL unavailable")}
            try dispatchURL(url.absoluteString)
            try await wait("warm actual "+action.rawValue) {
                switch action {
                case .about:return children(since:baseline).contains{$0 is TurtleGitAboutController}
                case .settings:return children(since:baseline).contains{$0.window?.title.contains("Settings")==true}
                default:return children(since:baseline).compactMap{$0 as? LogWindowController}.contains{$0.model.repository.root.path==folder.path && !$0.model.busy}
                }
            }
            try require(existing.root==originalRoot && existing.workspaceWindow===originalWindow && requested==before && delegate.actionRepositoryModel === privateModel && privateModel.workspaceWindow==nil,"Warm dialog retargeted/presented existing workspace: "+action.rawValue)
            if action == .settings {
                guard let owner=children(since:baseline).first(where:{$0.window?.contentViewController is SettingsNavigationController}),let navigation=owner.window?.contentViewController as? SettingsNavigationController else {throw Failure(description:"Actual private Settings navigation missing")}
                var dirty=true
                navigation.transaction.register("launch-dirty",participant:.init(page:.git,modified:{dirty},validate:{nil},apply:{dirty=false;return true},cancel:{dirty=false}))
                try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && dirty && navigation.transaction.modified && !navigation.completionPending,"Quit discarded/retired dirty private Settings")
                if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet);sheet.close()}
                navigation.transaction.unregister("launch-dirty")
            }
            try await closeChildren(since:baseline)
        }
        delegate.requestWorkspace();try require(requested==1 && existing.workspaceWindow===originalWindow,"Explicit warm workspace request lost existing route")
        delegate.retireFinderServices();privateModel.stopMonitoringForTermination()
    }
}
