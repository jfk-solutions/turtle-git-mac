// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func utilityOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));utilityOrder(mode,relativeTo:number)}
    @objc func utilityFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
}
@MainActor @main enum UtilityStartupVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    struct Scope:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {true}
        func stopAccessing(_ url:URL) {}
    }
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Utility startup timeout: "+message)}
    static func turn()async{await withCheckedContinuation{reply in DispatchQueue.main.async{reply.resume()}}}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath(),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.UtilityStartup."+UUID().uuidString,prefs:UserDefaults
        var models=[RepositoryModel](),delegates=[TurtleGitApplicationDelegate](),windows=[NSWindowController](),sessions=[MergeToolLaunchSession]()
        var settings=[SettingsPresentationService](),abouts=[TurtleGitAboutService](),appearances=[AppAppearance]()
        var repositoryRequests=0
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func model()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[weak self] _ in self?.repositoryRequests += 1;throw Failure(description:"Utility requested repository")})
            value.enableActionRoutingAccess();value.fileComparisonPreferences=prefs;models.append(value);return value
        }
        func delegate(_ model:RepositoryModel,args:[String])->TurtleGitApplicationDelegate {
            let value=TurtleGitApplicationDelegate();value.startupArguments=args;value.startupDirectory=root.path
            value.makeStandaloneWorkspace={model};value.configureStandaloneServices={_,_ in};value.configureGeneralApplication={_ in};value.activateStandaloneApplication={};value.startupMergeToolExit={_ in}
            delegates.append(value);return value
        }
        func install(_ model:RepositoryModel)->(SettingsPresentationService,TurtleGitAboutService) {
            let appearance=AppAppearance(preferences:prefs),service=SettingsPresentationService(),about=TurtleGitAboutService()
            appearances.append(appearance);settings.append(service);abouts.append(about)
            service.install(workspace:model,appearance:appearance)
            about.information={ApplicationAboutInformation(application:SubversionMergeDiff.applicationBundle().bundleURL,version:"0.1.0",build:"utility-QA")}
            about.checkRuntime={[git] owner in owner.checkSelectedGit(git,environment:GitRuntime.environment(executable:git))}
            about.present={[weak self] owner in owner.window?.alphaValue=0;owner.showWindow(nil);self?.windows.append(owner)}
            model.onAbout={_ = about.show(.application)}
            return(service,about)
        }
        func clean()async {
            for model in models{model.stopMonitoringForTermination()}
            for delegate in delegates{delegate.retireFinderServices();delegate.retireInboundURLBridge();delegate.workspaceOpenHandoff.retire();delegate.actionErrorController?.close()}
            for session in sessions{session.cancel()}
            for service in settings{service.controller?.close()}
            for owner in windows{owner.close()}
            for window in NSApp.windows{if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.orderOut(nil);window.close()}
            for _ in 0..<2000{if TurtleGitAboutController.activeReads==0 && ReleaseUpdateModel.activeOperations==0 && MergeToolLaunchSession.activePreparations==0 && sessions.allSatisfy({!$0.hasPendingWork}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func utilities(_ c:Context)async throws {
        let archive=RepositoryAccessStore.defaultStorageURL
        try require(RepositoryAccessLease.pathIsContained(archive,by:c.root.deletingLastPathComponent()),"Utility archive escaped private HOME")
        let saved=try RepositoryAccessStore(storageURL:archive,provider:Scope()).remember(c.root)
        // Use real CLI parsing and utility dispatch. Only handlers which would
        // open external Help/update/setup services are captured by this receiver.
        for (name,action) in [("about",RepositoryAction.about),("help",.help),("rtfm",.introduction),("autotexttest",.autotextTest),("updatecheck",.updateCheck),("firststartwizard",.firstStartWizard)] {
            let model=c.model(),delegate=c.delegate(model,args:["/command:"+name,"/path:"+c.root.path])
            let(_,about)=c.install(model);var delivered=0,reads=0
            if action != .about {model.onCommandHelp={delivered += 1};model.onIntroduction={delivered += 1};model.onAutotextTest={delivered += 1};model.onUpdateCheck={_,_ in delivered += 1};model.onFirstStart={_ in delivered += 1}}
            else {model.onAbout={delivered += 1;_ = about.show(.application)}}
            delegate.prepareGitConfigurationReads={reads += 1}
            delegate.startupDidFinishLaunching()
            try require(delegate.startupDelivered && delivered==1,"Pure utility CLI did not admit immediately: "+name)
            await turn()
            try require(reads==0 && !delegate.gitConfigurationReadsReady && model.recentRepositories.isEmpty && model.finderWatches==nil && model.workspaceWindow==nil,"Pure utility CLI restored Git/saved authority or workspace: "+name)
            if action == .about {
                try await wait("actual About Git version"){TurtleGitAboutController.activeReads==0}
                try require(c.windows.compactMap{$0 as? TurtleGitAboutController}.last?.diagnosticText.contains("Selected Git: git version ")==true,"About version failed with unrelated invalid Git configuration")
            }
            for owner in c.windows{owner.close()}
            try await wait("utility runtime drain"){TurtleGitAboutController.activeReads==0}
        }
        // Utility heads can present real About/global Settings before a held
        // Git request, but a later utility cannot leapfrog that FIFO owner.
        let model=c.model(),delegate=c.delegate(model,args:["--turtlegit-action-only"])
        let(service,about)=c.install(model);var aboutCalls=0,helpCalls=0,requests=[URL](),reads=0
        var reply:CheckedContinuation<Void,Never>?
        defer{let pending=reply;reply=nil;pending?.resume()}
        model.onAbout={aboutCalls += 1;_ = about.show(.application)};model.onHelp={helpCalls += 1}
        delegate.prepareGitConfigurationReads={reads += 1;await withCheckedContinuation{reply=$0}}
        delegate.workspaceOpenHandler={target,url in
            requests.append(url)
            if let request=FinderRequest(url:url),request.action != .log{target.handle(url)}
        }
        let urls=try [FinderRequest(action:.about,paths:[c.root]),FinderRequest(action:.help,paths:[c.root]),FinderRequest(action:.settings,paths:[]),FinderRequest(action:.log,paths:[c.root]),FinderRequest(action:.about,paths:[c.root])].map{request->URL in guard let url=request.url else{throw Failure(description:"Utility URL unavailable")};return url}
        delegate.startupDidFinishLaunching();delegate.application(NSApp,open:Array(urls.prefix(3)))
        try require(aboutCalls==1 && helpCalls==1 && service.controller != nil && service.navigation?.globalOnly==true,"Utility URL cohort omitted actual About/global Settings")
        await turn()
        try require(reads==0 && model.recentRepositories.isEmpty && model.finderWatches==nil && model.workspaceWindow==nil,"Utility URL cohort initialized Git configuration/authority/workspace")
        delegate.application(NSApp,open:Array(urls.suffix(2)))
        try await wait("held Git readiness"){reply != nil}
        try require(reads==1 && requests==Array(urls.prefix(3)) && aboutCalls==1,"Later utility leapfrogged Git readiness")
        let resume=reply;reply=nil;resume?.resume()
        try await wait("utility/Git FIFO"){delegate.gitConfigurationReadsReady && requests==urls && aboutCalls==2}
        try require(model.recentRepositories.contains{$0.id==saved.id} && model.finderWatches != nil,"Git-backed request failed to restore authority after utility-only launch")
        service.controller?.close()
        // Captured-path Settings remains repository-sensitive in CLI and URL
        // entry; its handler is observed only after the real delegate gate.
        for cli in [false,true] {
            let target=c.model(),context=c.delegate(target,args:cli ? ["/command:settings","/path:"+c.root.path]:["--turtlegit-action-only"])
            var entered=0,preparations=0,release:CheckedContinuation<Void,Never>?
            defer{let pending=release;release=nil;pending?.resume()}
            context.prepareGitConfigurationReads={preparations += 1;await withCheckedContinuation{release=$0}}
            context.startupCommandHandler={_,_,_ in if cli{entered += 1}}
            context.workspaceOpenHandler={_,_ in entered += 1}
            context.startupDidFinishLaunching()
            if !cli{context.application(NSApp,open:[FinderRequest(action:.settings,paths:[c.root]).url!])}
            try await wait("context Settings readiness"){release != nil}
            try require(entered==0 && preparations==1,"Context Settings bypassed Git readiness")
            let completion=release;release=nil;completion?.resume();try await wait("context Settings delivery"){entered==1}
        }
        try require(c.repositoryRequests==0,"Nonrepository utilities invoked repository factory")
    }
    static func merge(_ c:Context)async throws {
        let base=c.root.appendingPathComponent("base.txt"),mine=c.root.appendingPathComponent("mine.txt"),theirs=c.root.appendingPathComponent("theirs.txt")
        let source:[(URL,String)]=[(base,"common\nold\n"),(mine,"common\nmine\n"),(theirs,"common\ntheirs\n")]
        for(file,text)in source{try Data(text.utf8).write(to:file)}
        for args in [["--merge-tool"],["--merge-tool","--base",base.path,"--mine",mine.path,"--readonly"],["--merge-tool","--base",base.path,"--mine",mine.path,"--theirs",theirs.path,"--readonly"]] {
            let model=c.model(),delegate=c.delegate(model,args:args);var reads=0,presented=[NSWindowController]()
            delegate.prepareGitConfigurationReads={reads += 1}
            model.configureMergeToolLaunch={session in
                c.sessions.append(session);session.requiresScopes=false;session.executable={c.git}
                session.presentation={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner);presented.append(owner)}
            }
            delegate.startupDidFinishLaunching()
            try require(delegate.startupDelivered,"Local Merge startup waited for Git configuration")
            try await wait("actual local Merge editor"){!presented.isEmpty || model.error != nil}
            try require(model.error==nil,"Local Merge presentation failed: \(model.error ?? "unknown")")
            if let pair=presented.first as? FileComparisonWindowController {try await wait("local pair bytes"){!pair.model.busy && pair.model.document != nil}}
            if let three=presented.first as? TextConflictWindowController {try await wait("local three-way bytes"){!three.model.busy && three.model.document != nil}}
            await turn()
            try require(reads==0 && !delegate.gitConfigurationReadsReady && model.root==nil && model.finderWatches==nil,"Local Merge initialized unrelated Git context")
            for owner in presented{owner.close()}
            try await wait("owned Merge child drain"){c.sessions.allSatisfy{!$0.hasPendingWork}}
        }
        // Generator/patch invocations actually use Git during preparation;
        // observe their admission only after the existing configuration gate.
        for args in [["--merge-tool","--diff",c.root.appendingPathComponent("input.patch").path],["--merge-tool","--createunifieddiff","--origfile",base.path,"--modifiedfile",mine.path,"--outfile",c.root.appendingPathComponent("out.patch").path]] {
            let model=c.model(),delegate=c.delegate(model,args:args);var entered=0,release:CheckedContinuation<Void,Never>?
            defer{let pending=release;release=nil;pending?.resume()}
            delegate.prepareGitConfigurationReads={await withCheckedContinuation{release=$0}};delegate.startupCommandHandler={_,_,_ in entered += 1}
            delegate.startupDidFinishLaunching();try await wait("Git-backed Merge readiness"){release != nil}
            try require(entered==0,"Git-backed Merge invocation bypassed configuration")
            let reply=release;release=nil;reply?.resume();try await wait("Git-backed Merge admission"){entered==1}
        }
        for(file,text)in source{try require((try Data(contentsOf:file))==Data(text.utf8),"Read-only Merge startup changed source bytes")}
    }
    static func reopen(_ c:Context)async throws {
        // Exercise actual WorkspaceSceneOwner and native utility controllers,
        // rather than injecting a utility-only dispatcher that cannot exercise
        // the controlled false-flag workspace regression. The installed probe
        // may instead have received its reopen after About had closed.
        for name in ["about","settings","rtfm","autotexttest","firststartwizard","updatecheck"] {
            print("Utility reopen phase: "+name);fflush(stdout)
            let arguments=name=="settings" ? ["--turtlegit-action-only"]:["/command:"+name]+(name=="updatecheck" ? ["/visible"]:[])
            let model=c.model(),delegate=c.delegate(model,args:arguments)
            let scene=WorkspaceSceneOwner(commandModel:model)
            scene.makeModel={c.model()};scene.installWorkspaceServices={_ in}
            scene.makeController={model,appearance,applicationDelegate in
                let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:applicationDelegate)
                owner.presentWindow={window in window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.orderFront(nil)}
                c.windows.append(owner);return owner
            }
            delegate.configureGeneralApplication={scene.configure(applicationDelegate:$0)}
            let(service,about)=c.install(model)
            let introduction=ApplicationIntroductionService(),wizard=FirstStartWizardService(),updates=ReleaseUpdateService()
            introduction.display={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner)}
            wizard.present={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner)}
            updates.createModel={ReleaseUpdateModel(preferences:$0,appStore:true)}
            updates.display={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner)}
            model.onIntroduction={introduction.show(preferences:c.prefs)}
            model.onFirstStart={wizard.show(initialPage:$0,preferences:c.prefs)}
            var updateWasVisible=false
            model.onUpdateCheck={visible,force in updateWasVisible=visible;updates.showCommand(visible:visible,force:force,preferences:c.prefs)}
            delegate.presentExistingApplicationUtility={
                if about.hasOwnedUtilityWindow {_ = about.presentExistingUtility();return true}
                if service.hasOwnedUtilityWindow {_ = service.presentExistingUtility();return true}
                if introduction.hasOwnedUtilityWindow {_ = introduction.presentExistingUtility();return true}
                if wizard.hasOwnedUtilityWindow {_ = wizard.presentExistingUtility();return true}
                if updates.hasOwnedUtilityWindow {_ = updates.presentExistingUtility();return true}
                return false
            }
            var admissionReopens=0,admissionOpenedWorkspace=false
            let makeAbout=about.create
            about.create={tool,information in
                admissionReopens += 1
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                admissionOpenedWorkspace = admissionOpenedWorkspace || scene.storedController != nil
                return makeAbout(tool,information)
            }
            if name == "settings" {
                let activate=delegate.activateStandaloneApplication
                var activationProbed=false
                delegate.activateStandaloneApplication={
                    // Inject exactly the Settings URL's admission activation,
                    // before its factory. Later post-Close workspace activation
                    // is a different user intent, not another injected reopen.
                    if delegate.startupDelivered,!activationProbed {
                        activationProbed=true
                        admissionReopens += 1;_ = delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                        admissionOpenedWorkspace = admissionOpenedWorkspace || scene.storedController != nil
                    }
                    activate()
                }
            }
            delegate.prepareGitConfigurationReads={}
            delegate.startupDidFinishLaunching(defaultLaunch:true)
            if name=="settings" {delegate.application(NSApp,open:[FinderRequest(action:.settings,paths:[]).url!])}
            await turn()
            @MainActor func utilityWindow()->NSWindow? {
                switch name {
                case "about":return c.windows.compactMap{$0 as? TurtleGitAboutController}.last?.window
                case "settings":return service.controller?.window
                case "rtfm":return introduction.controller?.window
                case "firststartwizard":return wizard.controller?.window
                case "updatecheck":return updates.controller?.window
                default:return model.autotextUtilityWindow
                }
            }
            guard let window=utilityWindow() else{throw Failure(description:"Actual utility window absent: "+name)}
            if name=="settings" {try require(admissionReopens==1,"Actual Settings URL activation gap was not exercised")}
            if name=="updatecheck" {try require(updateWasVisible,"Visible update utility cohort lost the actual CLI /visible request")}
            try require(scene.storedController==nil && !admissionOpenedWorkspace,"Utility admission/reentrant factory created workspace: "+name)
            window.alphaValue=0;window.orderOut(nil)
            let before=Set(NSApp.windows.map(ObjectIdentifier.init))
            let handled=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            try require(!handled && scene.storedController==nil && utilityWindow() === window,"False Cocoa flag promoted/replaced actual utility: "+name)
            try require(Set(NSApp.windows.map(ObjectIdentifier.init))==before,"Utility reopen constructed another native owner: "+name)
            if name=="about" {
                try require(admissionReopens==1,"About factory gap was not exercised")
                (c.windows.compactMap{$0 as? TurtleGitAboutController}.last)?.closeAbout(nil)
                try await wait("About actual close retirement"){!about.hasOwnedUtilityWindow}
                // A direct menu/service presentation has its own factory gap,
                // outside the delegate's scoped CLI admission depth.
                _=about.show(.application)
                try require(admissionReopens==2 && !admissionOpenedWorkspace && scene.storedController==nil,"Direct About factory gap lost utility ownership")
                about.presentExistingUtility()
                (c.windows.compactMap{$0 as? TurtleGitAboutController}.last)?.closeAbout(nil)
            } else {window.performClose(nil)}
            try await wait("utility actual Close drains "+name){
                switch name {
                case "about":return !about.hasOwnedUtilityWindow
                case "settings":return !service.hasOwnedUtilityWindow
                case "rtfm":return introduction.controller==nil
                case "firststartwizard":return wizard.controller==nil
                case "updatecheck":return !updates.hasOwnedUtilityWindow
                default:return model.autotextUtilityWindow==nil
                }
            }
            // Once the real owner closes, an actual Dock/reopen request must
            // remain available, and must create the real native workspace.
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            try require(scene.storedController != nil && scene.storedModel?.workspaceWindow === scene.storedController?.window,"Closed utility retained a sticky reopen fence: "+name)
            scene.storedController?.close()
            try await wait("utility metadata drain "+name){TurtleGitAboutController.activeReads==0}
        }
        // Explicit Open Repository/workspace is an independent user intent;
        // retained utility ownership must not block it.
        let model=c.model(),delegate=c.delegate(model,args:["/command:about"]),scene=WorkspaceSceneOwner(commandModel:model)
        let(_,about)=c.install(model)
        scene.makeModel={c.model()};scene.installWorkspaceServices={_ in}
        scene.makeController={model,appearance,applicationDelegate in let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:applicationDelegate);owner.presentWindow={$0.alphaValue=0;$0.orderFront(nil)};c.windows.append(owner);return owner}
        delegate.configureGeneralApplication={scene.configure(applicationDelegate:$0)}
        delegate.presentExistingApplicationUtility={if about.hasOwnedUtilityWindow {_ = about.presentExistingUtility();return true};return false}
        delegate.startupDidFinishLaunching();try require(about.hasOwnedUtilityWindow && scene.storedController==nil,"Explicit workspace cohort failed to open utility alone")
        delegate.requestWorkspace()
        try require(scene.storedController != nil && about.hasOwnedUtilityWindow,"Explicit workspace intent was blocked by utility ownership")
        for owner in c.windows {owner.close()}
        try await wait("final utility metadata drain"){TurtleGitAboutController.activeReads==0}
        // Warm command Debug and error acknowledgements are retained native
        // command owners too, even when Cocoa reports no visible windows.
        for diagnostic in [true,false] {
            print("Utility reopen phase: "+(diagnostic ? "warm-debug":"queued-command-errors"));fflush(stdout)
            let model=c.model(),delegate=c.delegate(model,args:["--turtlegit-action-only"]),scene=WorkspaceSceneOwner(commandModel:model)
            scene.makeModel={c.model()};scene.installWorkspaceServices={_ in}
            scene.makeController={model,appearance,applicationDelegate in let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:applicationDelegate);owner.presentWindow={$0.alphaValue=0;$0.orderFront(nil)};c.windows.append(owner);return owner}
            delegate.configureGeneralApplication={scene.configure(applicationDelegate:$0)}
            delegate.presentExistingApplicationUtility={false}
            delegate.startupDidFinishLaunching()
            if diagnostic {
                c.prefs.set(true,forKey:"Debug");delegate.diagnosticPreferences=c.prefs
                delegate.presentCommandDiagnostic={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner)}
                var helpCalls=0;model.onHelp={helpCalls += 1}
                delegate.application(NSApp,open:[FinderRequest(action:.help,paths:[]).url!])
                guard let owner=delegate.commandDiagnosticController else{throw Failure(description:"Warm native Debug preview absent")}
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try require(scene.storedController==nil && delegate.commandDiagnosticController === owner,"Warm Debug preview lost native ownership")
                owner.acknowledge()
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try require(scene.storedController==nil,"Accepted Debug callback gap created workspace")
                try await wait("warm Debug actual admission"){helpCalls==1 && delegate.commandDiagnosticController==nil}
                c.prefs.set(false,forKey:"Debug")
            } else {
                model.error="Private first command error";model.error="Private queued command error"
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try require(scene.storedController==nil,"Queued command error presentation gap created workspace")
                try await wait("first actual command error"){delegate.actionErrorController != nil}
                guard let first=delegate.actionErrorController else{throw Failure(description:"Actual command error absent")}
                c.windows.append(first)
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try require(scene.storedController==nil && delegate.actionErrorController === first,"Open command error lost native ownership")
                first.close()
                try await wait("queued command error"){delegate.actionErrorController != nil && delegate.actionErrorController !== first}
                guard let second=delegate.actionErrorController else{throw Failure(description:"Queued command error absent")};c.windows.append(second)
                _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try require(scene.storedController==nil,"Queued native error acknowledgement created workspace")
                second.close();try await wait("command error retirement"){delegate.actionErrorController==nil && model.error==nil}
            }
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            try require(scene.storedController != nil,"Retired command acknowledgement left sticky reopen ownership")
            scene.storedController?.close()
        }
        // A quiet automatic network check is not a utility presentation. A
        // real Dock/reopen must still open the workspace while that read waits;
        // promoting the same held check to an explicit forced presentation
        // must then retain its pending owner without creating an update window.
        do {
            print("Utility reopen phase: quiet-and-forced-update");fflush(stdout)
            let model=c.model(),delegate=c.delegate(model,args:["--turtlegit-action-only"]),scene=WorkspaceSceneOwner(commandModel:model),updates=ReleaseUpdateService()
            var release:CheckedContinuation<[PublishedRelease],Error>?,hostPresentations=0
            defer{release?.resume(returning:[]);updates.cancelBackground()}
            updates.createModel={preferences in let model=ReleaseUpdateModel(preferences:preferences,appStore:false);model.fetch={_,_ in try await withCheckedThrowingContinuation{release=$0}};return model}
            updates.display={owner in owner.window?.alphaValue=0;owner.showWindow(nil);c.windows.append(owner)}
            scene.makeModel={c.model()};scene.installWorkspaceServices={_ in}
            scene.makeController={model,appearance,applicationDelegate in let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:applicationDelegate);owner.presentWindow={hostPresentations += 1;$0.alphaValue=0;$0.orderFront(nil)};c.windows.append(owner);return owner}
            delegate.configureGeneralApplication={scene.configure(applicationDelegate:$0)}
            delegate.presentExistingApplicationUtility={if updates.hasOwnedUtilityWindow {_ = updates.presentExistingUtility();return true};return false}
            delegate.startupDidFinishLaunching();updates.showCommand(visible:false,force:false,preferences:c.prefs)
            try await wait("quiet update held read"){release != nil}
            try require(!updates.hasOwnedUtilityWindow && updates.background != nil,"Quiet update incorrectly retained presentation ownership")
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            try require(hostPresentations==1 && scene.storedController != nil,"Quiet update blocked actual workspace reopen")
            scene.storedController?.close()
            updates.showCommand(visible:false,force:true,preferences:c.prefs)
            try require(updates.hasOwnedUtilityWindow && updates.controller==nil,"Forced update lost held presentation intent")
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            try require(hostPresentations==1 && updates.controller==nil,"Forced held update constructed workspace or premature utility")
            updates.cancelBackground();let reply=release;release=nil;reply?.resume(returning:[])
            try await wait("held update actual cancellation drain"){ReleaseUpdateModel.activeOperations==0}
            try require(!updates.hasOwnedUtilityWindow,"Cancelled forced update left stale presentation ownership")
        }
        print("Native utility reopen: real About/global Settings/introduction/autotext/wizard/update windows, false Cocoa flag, reentrant startup/direct factory admission, native Close retirement, real AppKit workspace successor and explicit workspace intent passed; hidden/private owners only")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let swaps=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.utilityOrder(_:relativeTo:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.utilityFrame(_:to:))))]
        for(a,b)in swaps{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in swaps.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs)
        do{if CommandLine.arguments[3]=="merge"{try await merge(c)}else if CommandLine.arguments[3]=="reopen"{try await reopen(c)}else{try await utilities(c)};await c.clean();DialogGeometry.install(preferences:.standard);try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil} && TurtleGitAboutController.activeReads==0 && ReleaseUpdateModel.activeOperations==0 && MergeToolLaunchSession.activePreparations==0,"Utility-owned windows/workers survived cleanup");print("PASS: utility startup "+CommandLine.arguments[3])}
        catch{await c.clean();DialogGeometry.install(preferences:.standard);fputs("Utility startup failed: \(error)\n",stderr);exit(1)}
    }
}
