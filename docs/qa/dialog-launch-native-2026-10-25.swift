// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
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
    static func verify(repository:GitRepository,existing:RepositoryModel,preferences:UserDefaults)async throws {
        let git=repository.executable,folder=repository.root
        var models=[RepositoryModel](),delegates=[TurtleGitApplicationDelegate](),settings=[SettingsPresentationService](),appearances=[AppAppearance]()
        defer {
            for delegate in delegates {delegate.retireFinderServices();delegate.workspaceOpenHandoff.retire();delegate.actionErrorController?.close()}
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
            delegate.requestWorkspace()
            try require(forwarded.count==1 && forwarded[0].map(\.absoluteString)==["turtlegit://workspace"] && configurations[0].isEmpty,"Explicit workspace request did not retain workspace launch semantics")
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.writeObjects([folder as NSURL])
            var error:NSString?;delegate.finderServicesProvider.openInTurtleGit(board,userData:"open",error:&error)
            try require(error==nil && forwarded.count==2 && (try? TurtleGitFinderServicesProvider.openSelection(from:forwarded[1][0]))?.map(\.path)==[folder.path] && configurations[1].isEmpty,"Generic public Service did not explicitly forward workspace Open")
            delegate.retireFinderServices();model.stopMonitoringForTermination()
        }
        let originalRoot=existing.root,originalWindow=existing.workspaceWindow
        let delegate=TurtleGitApplicationDelegate(),privateModel=try configure(delegate)
        var requested=0;delegate.startupArguments=[];delegate.repositoryModel=existing;delegate.presentWorkspace={requested += 1};delegate.startupDidFinishLaunching()
        for action in [RepositoryAction.about,.settings,.log] {
            let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),before=requested
            guard let url=FinderRequest(action:action,paths:[folder]).url else{throw Failure(description:"Action URL unavailable")}
            delegate.application(NSApp,open:[url])
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
