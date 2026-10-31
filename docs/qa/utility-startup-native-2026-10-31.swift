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
            for _ in 0..<2000{if TurtleGitAboutController.activeReads==0 && MergeToolLaunchSession.activePreparations==0 && sessions.allSatisfy({!$0.hasPendingWork}){break};try? await Task.sleep(nanoseconds:10_000_000)}
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
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let swaps=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.utilityOrder(_:relativeTo:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.utilityFrame(_:to:))))]
        for(a,b)in swaps{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in swaps.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs)
        do{if CommandLine.arguments[3]=="merge"{try await merge(c)}else{try await utilities(c)};await c.clean();DialogGeometry.install(preferences:.standard);try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil} && TurtleGitAboutController.activeReads==0 && MergeToolLaunchSession.activePreparations==0,"Utility-owned windows/workers survived cleanup");print("PASS: utility startup "+CommandLine.arguments[3])}
        catch{await c.clean();DialogGeometry.install(preferences:.standard);fputs("Utility startup failed: \(error)\n",stderr);exit(1)}
    }
}
