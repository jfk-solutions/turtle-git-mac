// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func diagnosticOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));diagnosticOrder(mode,relativeTo:number)}
    @objc func diagnosticFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
}
@MainActor @main enum CommandDiagnosticsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ condition:()->Bool)async throws{for _ in 0..<2000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:message)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.CommandDiagnostics."+UUID().uuidString,prefs:UserDefaults
        var models=[RepositoryModel](),delegates=[TurtleGitApplicationDelegate](),previews=[CommandDiagnosticPreviewController]()
        init(){prefs=UserDefaults(suiteName:suite)!}
        func owner(_ args:[String])->(TurtleGitApplicationDelegate,RepositoryModel){
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in throw Failure(description:"Diagnostic initialized repository")});model.enableActionRoutingAccess();model.fileComparisonPreferences=prefs;models.append(model)
            let owner=TurtleGitApplicationDelegate();owner.startupArguments=args;owner.startupDirectory=root.path;owner.diagnosticPreferences=prefs
            owner.makeStandaloneWorkspace={model};owner.configureStandaloneServices={_,_ in};owner.configureGeneralApplication={_ in};owner.activateStandaloneApplication={};owner.startupMergeToolExit={_ in}
            owner.presentCommandDiagnostic={[weak self] preview in self?.previews.append(preview);preview.window?.alphaValue=0;preview.showWindow(nil)}
            delegates.append(owner);return(owner,model)
        }
        func clean()async{for owner in delegates{owner.retireCommandDiagnostics();owner.retireFinderServices();owner.retireInboundURLBridge();owner.workspaceOpenHandoff.retire();owner.actionErrorController?.close()};for model in models{model.stopMonitoringForTermination()};for preview in previews{preview.retire()};for window in NSApp.windows{window.orderOut(nil);window.close()};for _ in 0..<2000{if FileListComparisonSession.activeOperations==0{break};try? await Task.sleep(nanoseconds:10_000_000)};GitCommandDiagnostics.installSink(nil);prefs.removePersistentDomain(forName:suite)}
    }
    static func verify(_ c:Context)async throws {
        let(off,_)=c.owner(["/command:about"]);var offCalls=0
        off.startupCommandHandler={_,_,_ in offCalls += 1};off.startupDidFinishLaunching()
        try require(offCalls==1 && c.previews.isEmpty,"Default-off Debug changed utility admission")
        c.prefs.set(true,forKey:"Debug")
        let(owner,model)=c.owner(["/command:about"]);var calls=0,reads=0,urls=[URL]()
        owner.startupCommandHandler={_,_,_ in calls += 1};owner.prepareGitConfigurationReads={reads += 1};owner.workspaceOpenHandler={_,url in urls.append(url)}
        owner.startupDidFinishLaunching()
        try require(c.previews.count==1 && calls==0 && !owner.startupDelivered && reads==0 && model.finderWatches==nil,"Preview did not own utility startup before unrelated Git state")
        let first=c.previews.last!;try require(first.commandText.contains("/command:about"),"Selectable preview lost captured command")
        let url=FinderRequest(action:.help,paths:[]).url!
        owner.application(NSApp,open:[url,url]);try require(urls.isEmpty && c.previews.count==1,"Queued URL escaped startup acknowledgment")
        first.acknowledge();try await wait("startup acknowledgment/FIFO"){calls==1 && c.previews.count==2}
        let second=c.previews.last!;try require(second.commandText.contains("/command:help"),"Typed URL preview omitted action")
        second.window?.performClose(nil);try await wait("native Close acknowledgment"){urls==[url] && c.previews.count==3}
        c.prefs.set(false,forKey:"Debug")
        // A live setting edit affects the next request, never bypasses an
        // informational window already owned by this captured invocation.
        owner.application(NSApp,open:[url]);try require(urls.count==1,"Disabling Debug bypassed captured preview")
        c.previews.last!.acknowledge();try await wait("duplicate and disabled-next admission"){urls==[url,url,url]}
        try require(reads==0 && model.finderWatches==nil && model.workspaceWindow==nil,"Utility diagnostic started Git/workspace authority")
        c.prefs.set(true,forKey:"Debug")
        let(gated,_)=c.owner(["/command:commit","/path:"+c.root.path]);var release:CheckedContinuation<Void,Never>?,entered=0,prepared=0
        defer{let pending=release;release=nil;pending?.resume()}
        gated.prepareGitConfigurationReads={prepared += 1;await withCheckedContinuation{release=$0}};gated.startupCommandHandler={_,_,_ in entered += 1}
        gated.startupDidFinishLaunching();try require(prepared==0 && entered==0,"Git preparation outran informational preview")
        let before=c.previews.count;c.previews.last!.acknowledge();try await wait("held Git configuration"){release != nil}
        try require(entered==0 && prepared==1 && c.previews.count==before,"Acknowledgment repeated during held configuration")
        let reply=release;release=nil;reply?.resume();try await wait("captured command delivery"){entered==1}
        let(service,_)=c.owner(["--turtlegit-action-only"]);var serviceCalls=0,serviceReads=0
        service.prepareGitConfigurationReads={serviceReads += 1};service.workspaceServiceHandler={_,_ in serviceCalls += 1;return true};service.startupDidFinishLaunching()
        try service.submitServiceRequest(FinderRequest(action:.status,paths:[c.root]))
        try require(service.commandDiagnosticController != nil && serviceCalls==0 && serviceReads==0,"Service bypassed captured preview")
        service.commandDiagnosticController?.window?.performClose(nil)
        try await wait("Service informational acknowledgment"){serviceCalls==1}
        try require(serviceReads==1 && service.pendingFinderServiceRequest==nil,"Service preview duplicated admission or skipped Git readiness")
        // Two accepted Service slots keep independent informational owners.
        c.prefs.set(false,forKey:"Debug")
        let(slots,_)=c.owner([]);slots.startupCommandHandler={_,_,_ in};slots.prepareGitConfigurationReads={};slots.startupDidFinishLaunching()
        c.prefs.set(true,forKey:"Debug");var order=[String]()
        slots.workspaceOpenSelectionHandler={_,_ in order.append("open");return true};slots.workspaceServiceHandler={_,_ in order.append("status");return true}
        try slots.submitOpenServiceSelection([c.root]);let openPreview=slots.commandDiagnosticController!
        try slots.submitServiceRequest(FinderRequest(action:.status,paths:[c.root]))
        try require(slots.commandDiagnosticController === openPreview && order.isEmpty,"Second Service replaced pending Open preview")
        openPreview.acknowledge();try await wait("distinct command Service preview"){order==["open"] && slots.commandDiagnosticController != nil}
        try require(slots.commandDiagnosticController !== openPreview && slots.commandDiagnosticController!.commandText.contains("status"),"Open acknowledgment admitted command Service without its own preview")
        slots.commandDiagnosticController?.acknowledge();try await wait("distinct Service FIFO"){order==["open","status"]}
        // Disabling Debug cannot bypass a different already-owned URL head.
        let(cross,_)=c.owner(["--turtlegit-action-only"]);cross.startupDidFinishLaunching();var crossURLs=0,crossServices=0
        cross.prepareGitConfigurationReads={};cross.workspaceOpenHandler={_,_ in crossURLs += 1};cross.workspaceServiceHandler={_,_ in crossServices += 1;return true}
        cross.application(NSApp,open:[url]);let head=cross.commandDiagnosticController!
        c.prefs.set(false,forKey:"Debug");try cross.submitServiceRequest(FinderRequest(action:.status,paths:[c.root]))
        try require(cross.commandDiagnosticController === head && crossURLs==0 && crossServices==0,"Disabled different-key Service bypassed owned URL")
        head.acknowledge();try await wait("different-key admitted only after head"){crossURLs==1 && crossServices==1}
        c.prefs.set(true,forKey:"Debug")
        // Retiring a Service provider also retires only its pending preview.
        let(retiringService,_)=c.owner(["--turtlegit-action-only"]);retiringService.startupDidFinishLaunching();retiringService.prepareGitConfigurationReads={}
        try retiringService.submitServiceRequest(FinderRequest(action:.status,paths:[c.root]));let retiredServicePreview=retiringService.commandDiagnosticController!
        retiringService.retireFinderServices();retiredServicePreview.acknowledge()
        retiringService.workspaceOpenHandler={_,_ in};retiringService.application(NSApp,open:[url])
        try require(retiringService.commandDiagnosticController != nil && retiringService.commandDiagnosticController !== retiredServicePreview,"Retired Service preview stranded unrelated URL")
        retiringService.commandDiagnosticController?.acknowledge()
        // A refused Quit leaves the paused command and native preview alive;
        // an accepted Quit retires the callback without dispatching it.
        let(quitting,_)=c.owner(["/command:about"]);var quitCalls=0
        quitting.startupCommandHandler={_,_,_ in quitCalls += 1};quitting.startupDidFinishLaunching()
        let paused=quitting.commandDiagnosticController!,blocker=FileListComparisonSession(window:nil,preferences:c.prefs)
        var drain:CheckedContinuation<Void,Never>?
        defer{let pending=drain;drain=nil;pending?.resume()}
        let work=Task{try await blocker.run(selectedCount:0){_ in await withCheckedContinuation{drain=$0}}}
        try await wait("owned Quit blocker"){drain != nil}
        try require(quitting.applicationShouldTerminate(NSApp) == .terminateCancel && quitting.commandDiagnosticController === paused && quitCalls==0,"Refused Quit dropped captured diagnostic owner")
        let finish=drain;drain=nil;finish?.resume();try await work.value
        try require(quitting.applicationShouldTerminate(NSApp) == .terminateNow && quitting.commandDiagnosticController==nil,"Accepted Quit retained informational callback")
        paused.acknowledge();try await Task.sleep(nanoseconds:20_000_000);try require(quitCalls==0,"Accepted Quit dispatched paused command")
        // Existing injected document decision exercises accepted async Quit:
        // its true reply must retire the paused preview before AppKit exits.
        let document=PatchWindowController(documentDirectory:c.root,preferences:c.prefs)
        document.window?.alphaValue=0;document.showWindow(nil);document.presentDocument(Data(),title:"private Quit owner",comparison:"",information:"")
        try await wait("private document admission"){PatchDocumentSession.activeOperations==0}
        document.model.editDocument("private unsaved diagnostic draft\n")
        var documentReply:((PatchDocumentSession.Decision)->Void)?
        defer{documentReply?(.discard);document.close()}
        document.documentSession.askChanges={_,reply in documentReply=reply}
        let(asyncQuit,_)=c.owner(["/command:about"]);var asyncCalls=0,quitReplies=[Bool]()
        asyncQuit.startupCommandHandler={_,_,_ in asyncCalls += 1};asyncQuit.replyToTermination={_,value in quitReplies.append(value)};asyncQuit.startupDidFinishLaunching()
        let asyncPreview=asyncQuit.commandDiagnosticController!
        try require(asyncQuit.applicationShouldTerminate(NSApp) == .terminateLater,"Dirty document omitted async Quit decision")
        try await wait("private Quit question"){documentReply != nil}
        let approve=documentReply;documentReply=nil;approve?(.discard)
        try await wait("accepted async Quit reply"){quitReplies==[true]}
        try require(asyncQuit.commandDiagnosticController==nil && asyncCalls==0,"Accepted async Quit retained preview callback")
        asyncPreview.acknowledge();try await Task.sleep(nanoseconds:20_000_000);try require(asyncCalls==0,"Accepted async Quit dispatched paused command")
        document.close()
        // Process-specific source namespace: primary Debug does not decorate
        // standalone image/UDiff/Merge entries. Merge has its own Debug key.
        for args in [["--image-tool"],["--unified-diff-tool"],["--merge-tool"]] {
            let(tool,_)=c.owner(args);var ran=0;tool.startupCommandHandler={_,_,_ in ran += 1};let count=c.previews.count
            tool.startupDidFinishLaunching();try require(ran==1 && c.previews.count==count,"Primary Debug leaked into standalone tool namespace")
        }
        c.prefs.set(true,forKey:"TurtleGitMerge.Debug")
        let(merge,_)=c.owner(["--merge-tool"]);var mergeCalls=0;merge.startupCommandHandler={_,_,_ in mergeCalls += 1};merge.startupDidFinishLaunching()
        try require(mergeCalls==0 && merge.commandDiagnosticController != nil,"Separate Merge Debug omitted preview")
        merge.commandDiagnosticController?.acknowledge();try await wait("Merge Debug admission"){mergeCalls==1}
        // A force-retired preview never invokes a late command callback.
        let(retired,_)=c.owner(["/command:about"]);var late=0;retired.startupCommandHandler={_,_,_ in late += 1};retired.startupDidFinishLaunching()
        let stale=retired.commandDiagnosticController!;retired.retireCommandDiagnostics();stale.acknowledge();try await Task.sleep(nanoseconds:20_000_000)
        try require(late==0,"Retired informational owner dispatched late command")
        // Actual advanced Apply and blank reset remove an installed trace sink;
        // private defaults keep this test away from the user's Console setting.
        c.prefs.set(true,forKey:"DebugOutputString")
        let settings=AdvancedSettingsModel(defaults:c.prefs,publishFinderMenu:{_ in},publishCachePersistence:{_ in},publishCacheTray:{_ in})
        try require(settings.edit("DebugOutputString",text:"false"),"Trace preference edit rejected");settings.apply()
        try require(settings.error==nil && c.prefs.bool(forKey:"DebugOutputString")==false,"Trace disable Apply failed")
        try require(settings.edit("DebugOutputString",text:""),"Trace reset rejected");settings.apply()
        try require(c.prefs.object(forKey:"DebugOutputString")==nil,"Trace blank reset retained override")
        let secret=CommandDiagnosticPreviewController(arguments:["/command:commit","/logmsg:private-message","https://user:password@example.invalid/repo?token=private-token"]){_ in}
        defer{secret.retire()}
        try require(!secret.commandText.contains("private-message") && !secret.commandText.contains("password") && !secret.commandText.contains("private-token"),"Preview leaked sensitive argv")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let swaps=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.diagnosticOrder(_:relativeTo:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.diagnosticFrame(_:to:))))]
        for(a,b)in swaps{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in swaps.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();do{try await verify(c);await c.clean();try require(FileListComparisonSession.activeOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Diagnostic window survived cleanup");print("PASS: native command diagnostics")}catch{await c.clean();fputs("Native diagnostics failed: \(error)\n",stderr);exit(1)}
    }
}
