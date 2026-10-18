import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyUtilityCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let outside=container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let suite="TurtleGit.UtilityCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        var factoryCalls=0,about=0,help=0,pages:[(Bool,String?)]=[],wizardPages:[Int]=[]
        let noGit=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in factoryCalls += 1;throw Failure(description:"No Git should be required")},snapshotWriter:{_ in true})
        noGit.requiresRepositoryScope=false;noGit.fileComparisonPreferences=prefs
        noGit.onAbout={about += 1};noGit.onCommandHelp={help += 1};noGit.onSettingsPage={pages.append(($0,$1))};noGit.onFirstStart={wizardPages.append($0)}
        defer {noGit.stopMonitoringForTermination()}
        for args in [["--command=about"],["--command=help"],["--command=firststartwizard","--page=3"],["--command=settings","--page=main"]] {
            noGit.handleCommandLine(arguments:args,currentDirectory:outside.path)
            try await wait {!noGit.busy && !noGit.hasPendingRepositoryWork}
        }
        try require(about==1 && help==1 && wizardPages==[3] && pages.count==1 && pages[0].0 && pages[0].1=="main" && factoryCalls==0 && noGit.root==nil,"Application utilities or global Settings required Git/adopted a repository")
        for (name,page) in [("look",SettingsPageID.contextMenu),("extmenu",.contextMenu2),("dialog3",.dialogs3),("overlays",.overlayIcons),("overlay",.overlays),("overlayshandlers",.overlayHandlers),("smtp",.email),("gitcredential",.credential),("bugtraq",.issueProviders),("bugtraqconfig",.issueTracker),("merge",.mergeTool),("save",.savedData)] {
            try require(SettingsPageID.commandPage(name,repository:true)==page,"Wrong source Settings page: "+name)
        }
        try require(SettingsPageID.commandPage(nil,repository:true) == .git && SettingsPageID.commandPage("unknown",repository:false) == .general && SettingsPageID.commandPage("GITCONFIG",repository:true) == .git && SettingsPageID.commandPage("gitremote",repository:false) == .general && SettingsPageID.commandPage("win11menu",repository:true) == .git,"Settings default/case/unavailable-page fallback differs from source")
        let root=container.appendingPathComponent("repository"),other=container.appendingPathComponent("other")
        for folder in [root,other] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repository=GitRepository(root:folder,executable:git)
            _ = try await repository.run(["init","-b","main"])
            _ = try await repository.run(["config","user.name","Utility QA"]);_ = try await repository.run(["config","user.email","qa@example.invalid"])
            _ = try await repository.run(["config","commit.gpgsign","false"]);_ = try await repository.run(["config","core.hooksPath","/dev/null"])
            try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"base")
        }
        let repo=GitRepository(root:root,executable:git),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.rebaseCommit("HEAD")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container)}
        let appearance=AppAppearance(preferences:prefs),settings=SettingsPresentationService()
        settings.present={_ in};settings.install(workspace:workspace,appearance:appearance)
        defer {settings.controller?.close();workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        @MainActor func invoke(_ args:[String],cwd:URL?=nil){workspace.handleCommandLine(arguments:args,currentDirectory:(cwd ?? root).path)}
        invoke(["--command=settings"])
        try await wait {!workspace.busy && settings.navigation?.selected == .git && settings.navigation?.canDismiss == true}
        try require(workspace.root?.path==root.path && settings.navigation?.globalOnly==false,"Repository Settings did not adopt its authorized context or default to Git")
        let first=settings.controller
        invoke(["--command=settings","--page=gitremote"])
        try await wait {!workspace.busy && settings.navigation?.selected == .remote && settings.navigation?.remote?.busy==false}
        try require(settings.controller === first && settings.navigation?.remote?.noFetch==true && settings.navigation?.remote?.preferences === prefs,"Remote command lost No Fetch, window reuse or owning preferences")
        let navigation=settings.navigation!
        var draft=true,applied=false
        navigation.transaction.register("command-owned-draft",participant:.init(page:.remote,modified:{draft},validate:{nil},apply:{applied=true;return true},cancel:{draft=false}))
        invoke(["--command=settings","--page=color2"])
        try await wait {!workspace.busy && navigation.selected == .colors2}
        try require(navigation.transaction.modified && draft && !applied,"Command page navigation applied or discarded current draft")
        workspace.canChangeSettingsContext={false}
        invoke(["--command=settings","--path",other.path])
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
        try require(workspace.root?.path==root.path && settings.controller === first && navigation.transaction.modified,"Denied Settings context change replaced workspace/draft")
        navigation.transaction.unregister("command-owned-draft")
        settings.controller?.close()
        workspace.canChangeSettingsContext={settings.prepareContextChange()}
        invoke(["--command=settings","--path",outside.path,"--page=unknown"])
        try await wait {!workspace.busy && settings.navigation?.globalOnly==true && settings.navigation?.selected == .general}
        try require(workspace.root?.path==root.path,"Global Settings outside a repository changed current checkout")
        settings.controller?.close()
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:300,height:200),styleMask:[.titled],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false
        workspace.workspaceWindow=owner
        invoke(["--command=settings","--path",other.path]);owner.close()
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
        try require(workspace.root?.path==root.path && settings.controller==nil,"Closed owner authorized a late Settings adoption")
        workspace.workspaceWindow=nil
        // Initial user/authentication pages read a private global configuration.
        let global=container.appendingPathComponent("private.gitconfig")
        let originalGlobal=ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        setenv("GIT_CONFIG_GLOBAL",global.path,1)
        defer {if let originalGlobal {setenv("GIT_CONFIG_GLOBAL",originalGlobal,1)}else{unsetenv("GIT_CONFIG_GLOBAL")}}
        _ = try await repo.run(["config","--global","user.name","Private setup"])
        _ = try await repo.run(["config","--global","user.email","private@example.invalid"])
        _ = try await repo.run(["config","--global","credential.helper","store"])
        let globalBytes=try Data(contentsOf:global)
        let wizard=FirstStartWizardService();wizard.present={_ in}
        wizard.create={preferences,page in FirstStartWizardController(preferences:preferences,initialPage:page,makeRepository:{_,token in try token.check();return GitRepository(root:outside,executable:git)})}
        noGit.onFirstStart={wizard.show(initialPage:$0,preferences:prefs)}
        noGit.handleCommandLine(arguments:["--command=firststartwizard","--page=3"],currentDirectory:outside.path)
        try await wait {wizard.controller?.model.busy==false && wizard.controller?.model.git.busy==false}
        let setup=wizard.controller!
        try require(setup.model.page == .user && setup.model.name=="Private setup" && setup.model.email=="private@example.invalid" && (try Data(contentsOf:global))==globalBytes,"Initial User page did not load configuration without writing")
        setup.model.name="edited draft"
        noGit.handleCommandLine(arguments:["--command=firststartwizard","--page=0"],currentDirectory:outside.path)
        try require(wizard.controller === setup && setup.model.page == .user && setup.model.name=="edited draft","Repeated wizard command reset existing page/draft")
        setup.close();try await wait {FirstStartWizardModel.activeWrites==0 && GeneralGitSettingsModel.activeOperations==0}
        noGit.handleCommandLine(arguments:["--command=firststartwizard","--page=4"],currentDirectory:outside.path)
        try await wait {wizard.controller?.model.busy==false && wizard.controller?.model.git.busy==false}
        let auth=wizard.controller!
        try require(auth.model.page == .authentication && auth.model.name=="Private setup","Initial Authentication page failed configuration bootstrap")
        auth.model.skipHelper=true;auth.model.next()
        try await wait {wizard.controller==nil && FirstStartWizardModel.activeWrites==0}
        try require(prefs.bool(forKey:"TurtleGit.FirstStartComplete") && (try Data(contentsOf:global))==globalBytes,"Skipped helper finish wrote global config or lost private completion flag")
        var late:CheckedContinuation<GitRepository,Never>?,token:OperationCancellation?
        wizard.create={preferences,page in FirstStartWizardController(preferences:preferences,initialPage:page,makeRepository:{_,request in token=request;return await withCheckedContinuation {late=$0}})}
        wizard.show(initialPage:3,preferences:prefs)
        try await wait {late != nil}
        let closing=wizard.controller!;closing.close()
        try require(token?.isCancelled==true && FirstStartWizardModel.activeWrites>0,"Wizard close dropped bootstrap before actual drain")
        late?.resume(returning:repo);late=nil
        try await wait {FirstStartWizardModel.activeWrites==0 && GeneralGitSettingsModel.activeOperations==0}
        try require(closing.model.name.isEmpty && wizard.controller==nil,"Retired wizard accepted late configuration")
        let finalHead=try await repo.rebaseCommit("HEAD")
        try require(finalHead.hash==head.hash && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:global))==globalBytes,"Utility entry changed Git state without acceptance")
        print("PASS: Utility command family: no-Git About/Help/global Settings; source page/default mapping and Remote No Fetch; native reused Settings/draft/context refusal; owner cancellation; wizard page 3/4 configuration bootstrap, repeated draft retention, private finish, forced close/late drain; unchanged source Git/global config; owned windows closed. External Help/About services and real scoped pickers not activated.")
    }
}
