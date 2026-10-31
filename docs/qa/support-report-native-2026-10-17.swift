// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func supportOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        if ProcessInfo.processInfo.environment["TURTLEGIT_SUPPORT_CAPTURE"] == nil {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000))};supportOrder(mode,relativeTo:number)
    }
    @objc func supportFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
}
@main struct SupportReportVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var services = [SupportReportService]()
    @MainActor static var otherOwners = [NSWindowController]()
    @MainActor static var owners = [SupportReportWindowController]()
    @MainActor static var releaseHeld: (() -> Void)?
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<1800 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Support report wait at line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func cleanup() async {
        services.forEach { $0.retire() }; otherOwners.forEach { $0.close() }; owners.forEach { $0.close() }; releaseHeld?(); releaseHeld = nil
        for _ in 0..<1800 { if SupportReportWindowModel.activeReads == 0 && SupportReportWindowModel.activeWrites == 0 && SupportReportService.activeScans == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let swaps = [(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.supportOrder(_:relativeTo:)))),
                     (class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.supportFrame(_:to:))))]
        for(a,b) in swaps {if let a,let b {method_exchangeImplementations(a,b)}}
        defer {for(a,b) in swaps.reversed() {if let a,let b {method_exchangeImplementations(a,b)}}}
        let suite = "TurtleGit.Support.Geometry."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        defer {DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
        do { try await verify(); await cleanup(); try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet == nil},"Support owned window/sheet survived cleanup"); print("PASS: Native support report, owned pickers, explicit inclusion, exact copy/export, held read/write ownership and retired callbacks") }
        catch { await cleanup(); fputs("Support report failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func capture(_ window: NSWindow, prefix: String = "support-report") async throws {
        guard let directory = ProcessInfo.processInfo.environment["TURTLEGIT_SUPPORT_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture API unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Owned support window missing") }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(prefix + "-" + suffix + ".png"))
            print("Captured \(prefix)-\(suffix): \(config.width)x\(config.height)")
        }
    }
    @MainActor final class HeldCrashScan {
        let incident:SupportCrashIncident
        var continuation:CheckedContinuation<SupportCrashIncident?,Error>?
        var token:OperationCancellation?
        var reads=0
        init(incident:SupportCrashIncident) { self.incident = incident }
        func read(_ token:OperationCancellation) async throws -> SupportCrashIncident? {
            self.token = token;reads += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning:incident); continuation = nil }
    }
    @MainActor static func verifyRecovery(root:URL) async throws {
        let directory = root.appendingPathComponent("DiagnosticReports",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let suite = "TurtleGit.Recovery.Native."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let text = #"{"procName":"TurtleGitMac","bundleInfo":{"CFBundleIdentifier":"org.test.turtle"},"exception":{"type":"EXC_CRASH"},"fixture":"RECOVERY_BODY"}"#
        let file = directory.appendingPathComponent("TurtleGitMac-fixture.ips"); try Data(text.utf8).write(to:file)
        var services:[SupportReportService] = []
        defer { services.forEach { $0.retire() } }
        func service() -> SupportReportService {
            let value = SupportReportService(preferences:prefs,reportsDirectory:directory,processName:"TurtleGitMac",bundleIdentifier:"org.test.turtle")
            value.presentNotice = { $0.window!.alphaValue = 0; $0.window!.orderFront(nil) }
            value.presentReport = { $0.window!.alphaValue = 0; $0.window!.orderFront(nil) }
            services.append(value); Self.services.append(value); return value
        }
        let first = service(); first.checkForPreviousCrash(); first.checkForPreviousCrash()
        try await wait { SupportReportService.activeScans == 0 && first.recoveryNotice != nil }
        try require(first.controller == nil && SupportCrashRecoveryPreferences.handled(in:prefs).isEmpty,"Discovery opened/included/acknowledged a report before a choice")
        var notice = first.recoveryNotice
        weak var releasedNotice = notice
        try await capture(notice!.window!,prefix:"crash-recovery")
        notice!.dismiss(); notice!.review(); notice = nil
        try await wait { first.recoveryNotice == nil && releasedNotice == nil }
        try require(SupportCrashRecoveryPreferences.handled(in:prefs).count == 1 && first.controller == nil,"Dismiss lost receipt or opened report")
        let second = service(); second.checkForPreviousCrash(); try await wait { SupportReportService.activeScans == 0 }
        try require(second.recoveryNotice == nil,"Handled crash prompted again")
        try Data(text.replacingOccurrences(of:"EXC_CRASH",with:"EXC_BAD_ACCESS").utf8).write(to:file)
        let review = service(); review.checkForPreviousCrash(); try await wait { review.recoveryNotice != nil && SupportReportService.activeScans == 0 }
        review.show(); let report = review.controller!
        report.model.picking = true; review.recoveryNotice!.review()
        try require(review.recoveryNotice?.model.notice != nil && SupportCrashRecoveryPreferences.handled(in:prefs).count == 1,"Busy report accepted or acknowledged recovery")
        report.model.picking = false; review.recoveryNotice!.review()
        try require(review.recoveryNotice == nil && report.model.report?.text.contains("RECOVERY_BODY") == true && !report.model.draft.includeCrashReport && !report.model.preview.contains("RECOVERY_BODY"),"Review lost original report or silently included it")
        report.model.field(\.includeCrashReport,context:report.model.context).wrappedValue = true
        try require(report.model.preview.contains("RECOVERY_BODY"),"Explicit recovered inclusion missing")
        report.model.setCrashChecking(false,context:report.model.context)
        let disabled = service(); disabled.checkForPreviousCrash()
        try require(SupportReportService.activeScans == 0 && disabled.recoveryNotice == nil && !SupportCrashRecoveryPreferences.enabled(in:prefs),"Disabled discovery started work")
        report.model.setCrashChecking(true,context:report.model.context)
        let late = service()
        let incident = SupportCrashIncident(report:try SupportCrashReport.read(file),date:Date())
        let held = HeldCrashScan(incident:incident)
        releaseHeld = { held.finish() }
        late.discover = { _,_,_,_,token in try await held.read(token) }
        late.checkForPreviousCrash(); try await wait { held.continuation != nil }
        let count = SupportCrashRecoveryPreferences.handled(in:prefs).count
        late.retire()
        try require(held.token?.isCancelled == true && SupportReportService.activeScans == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired discovery lost cancellation/drain ownership")
        held.finish(); releaseHeld = nil
        try await wait { SupportReportService.activeScans == 0 }
        try require(late.recoveryNotice == nil && SupportCrashRecoveryPreferences.handled(in:prefs).count == count,"Retired discovery published/acknowledged")
        print("PASS: local crash discovery, exact identity, handled suppression, Review/Dismiss, busy review retry, explicit inclusion, private preference, cancellation/drain, retired callbacks and released notice")
    }
    struct Scope:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {true}
        func stopAccessing(_ url:URL) {}
    }
    @MainActor static func turn() async {await withCheckedContinuation { reply in DispatchQueue.main.async {reply.resume()} }}
    @MainActor static func phase(_ text:String) {print("Support phase: "+text);fflush(stdout)}
    struct Geometry:Equatable {let editor:NSRect,preview:NSRect,window:NSRect}
    @MainActor static func geometry(_ owner:SupportReportWindowController) async throws -> Geometry {
        await turn();await turn()
        guard let window=owner.window,let content=window.contentView else {throw Failure(description:"Geometry owner missing")}
        content.layoutSubtreeIfNeeded();content.displayIfNeeded()
        try await wait {
            content.layoutSubtreeIfNeeded()
            let texts=views(content).compactMap{$0 as? NSTextView}
            return texts.contains{$0.accessibilityLabel()=="Exact problem report" && ($0.enclosingScrollView?.frame.height ?? 0)>0} && texts.contains{$0.accessibilityLabel() != "Exact problem report" && ($0.enclosingScrollView?.frame.height ?? 0)>0}
        }
        let texts=views(content).compactMap{$0 as? NSTextView}
        guard let previewText=texts.first(where:{$0.accessibilityLabel()=="Exact problem report"}),
              let editor=texts.first(where:{$0 !== previewText})?.enclosingScrollView,
              let preview=previewText.enclosingScrollView else {throw Failure(description:"Mounted native editor/preview missing")}
        let result=Geometry(editor:editor.convert(editor.bounds,to:content),preview:preview.convert(preview.bounds,to:content),window:window.frame)
        try require(result.editor.height>50 && result.preview.height>=180,"Report editor/preview collapsed")
        return result
    }
    @MainActor static func sameGeometry(_ owner:SupportReportWindowController,_ baseline:Geometry,_ phase:String) async throws {
        let actual=try await geometry(owner)
        try require(actual==baseline,"Report layout jumped during \(phase): expected \(baseline), actual \(actual)")
    }
    /// SwiftUI can render a Button without an NSButton subview. Follow only
    /// public accessibility children/actions, including navigation-order proxy
    /// nodes. An invisible host may publish no actionable node; callers record
    /// the narrower fallback rather than treating that as physical button proof.
    @MainActor static func publicButton(_ window:NSWindow,identifier:String,label:String)->(action:(()->Bool)?,diagnostic:String) {
        var seen=Set<ObjectIdentifier>(),budget=4096,matched=[String]()
        func property(_ object:NSObject,_ name:String)->Any? {
            let selector=NSSelectorFromString(name)
            guard object.responds(to:selector) else{return nil}
            return object.perform(selector)?.takeUnretainedValue()
        }
        func visit(_ value:Any,_ depth:Int)->(()->Bool)? {
            guard depth<48,budget>0,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return nil}
            budget -= 1
            let element=value as? NSAccessibilityProtocol
            let actualLabel=element?.accessibilityLabel() ?? property(object,"accessibilityLabel") as? String
            let title=property(object,"accessibilityTitle") as? String
            let actualID=property(object,"accessibilityIdentifier") as? String
            let role=element?.accessibilityRole()?.rawValue ?? property(object,"accessibilityRole") as? String
            if actualID==identifier || (role==NSAccessibility.Role.button.rawValue && (actualLabel==label || title==label)) {
                matched.append("\(type(of:value)) role=\(role ?? "none")")
                if let element,element.isAccessibilityEnabled() {return {element.accessibilityPerformPress()}}
                let press=NSSelectorFromString("accessibilityPerformPress"),enabled=NSSelectorFromString("isAccessibilityEnabled")
                if object.responds(to:press),object.responds(to:enabled) {
                    typealias BooleanMethod = @convention(c) (AnyObject,Selector)->Bool
                    let can=unsafeBitCast(object.method(for:enabled),to:BooleanMethod.self)
                    if can(object,enabled) {return {let action=unsafeBitCast(object.method(for:press),to:BooleanMethod.self);return action(object,press)}}
                }
            }
            let children=(element?.accessibilityChildren() ?? property(object,"accessibilityChildren") as? [Any] ?? []) + (property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
            for child in children {if let action=visit(child,depth+1) {return action}}
            return nil
        }
        var action=visit(window,0)
        if action==nil {for view in views(window.contentView!) {if let found=visit(view,0) {action=found;break}}}
        return (action,"visited=\(seen.count), matched=\(matched)")
    }
    @MainActor static func verifyHelp(_ window:NSWindow) async throws {
        guard let bundle=Bundle(path:FileManager.default.currentDirectoryPath+"/build/Build/Products/Debug/TurtleGitMac.app") else {throw Failure(description:"Help app bundle missing")}
        let service=TurtleGitHelpService(bundle:bundle),previous=TurtleGitHelp.service
        guard let local=service.localURL(for:.reportProblem) else {throw Failure(description:"Bundled Report a Problem topic missing")}
        let html=try String(contentsOf:local,encoding:.utf8)
        try require(html.contains("name=\"topic-reportProblem\""),"Bundled support anchor missing")
        var routes=[String]()
        service.registerBook={_ in true};service.openAnchor={anchor,_ in routes.append(anchor)};service.openURL={url in routes.append(url.absoluteString)}
        TurtleGitHelp.service=service;defer {TurtleGitHelp.service=previous}
        try require(TurtleGitHelp.context(window) == .reportProblem,"Report/recovery contextual Help unbound")
        window.contentView?.layoutSubtreeIfNeeded();await turn();await turn()
        let identity=window.title.hasPrefix("Crash Report") ? "support-recovery-help":"support-report-help"
        let button=publicButton(window,identifier:identity,label:"Help")
        let pressed=button.action?() ?? false
        if pressed {
            phase("Help public accessibility press: "+identity+"; "+button.diagnostic)
        } else {
            // This is the real installed context-key handler, not a direct
            // service.show substitute. Button physical dispatch remains open.
            guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:122) else {throw Failure(description:"Support F1 event unavailable")}
            try require(TurtleGitHelp.handleHelpKey(event),"Support contextual F1 was not handled")
            phase("Help contextual F1 fallback; physical button dispatch unproven: "+identity+"; "+button.diagnostic)
        }
        try require(routes==["topic-reportProblem"],"Support Help route opened unrelated/default/external topic: \(routes)")
    }
    @MainActor static func verifyUtilityOwnership(root:URL,file:URL) async throws {
        phase("utility factory and retained owner admission")
        let suite="TurtleGit.Support.Ownership."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let service=SupportReportService(preferences:prefs,reportsDirectory:root,processName:"TurtleGitMac",bundleIdentifier:"org.test.turtle")
        services.append(service)
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in throw Failure(description:"Support utility constructed repository")})
        model.fileComparisonPreferences=prefs
        let delegate=TurtleGitApplicationDelegate(),scene=WorkspaceSceneOwner(commandModel:model)
        delegate.startupArguments=["--turtlegit-action-only"];delegate.startupDirectory=root.path
        delegate.activateStandaloneApplication={};delegate.prepareGitConfigurationReads={};delegate.configureStandaloneServices={_,_ in}
        delegate.configureGeneralApplication={scene.configure(applicationDelegate:$0)}
        delegate.presentExistingApplicationUtility={service.presentExistingUtility()}
        scene.makeModel={model};scene.installWorkspaceServices={_ in}
        var workspacePresentations=0
        scene.makeController={model,appearance,delegate in
            let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:delegate)
            owner.presentWindow={window in workspacePresentations += 1;window.alphaValue=0;window.orderFront(nil)}
            otherOwners.append(owner);return owner
        }
        defer {delegate.retireFinderServices();delegate.retireInboundURLBridge();delegate.workspaceOpenHandoff.retire();model.stopMonitoringForTermination();scene.storedController?.close();service.retire()}
        delegate.startupDidFinishLaunching()
        var reportFactories=0,noticeFactories=0,factoryFence=true
        let createReport=service.createReport,createNotice=service.createNotice
        service.createReport={information,preferences in
            reportFactories += 1
            factoryFence = factoryFence && service.hasOwnedUtilityWindow && service.presentExistingUtility()
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            factoryFence = factoryFence && scene.storedController==nil
            let owner=createReport(information,preferences);owners.append(owner);return owner
        }
        service.createNotice={incident in
            noticeFactories += 1
            factoryFence = factoryFence && service.hasOwnedUtilityWindow && service.presentExistingUtility()
            _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            factoryFence = factoryFence && scene.storedController==nil
            let owner=createNotice(incident);otherOwners.append(owner);return owner
        }
        service.presentReport={$0.window!.alphaValue=0;$0.window!.orderFront(nil)}
        service.presentNotice={$0.window!.alphaValue=0;$0.window!.orderFront(nil)}
        let incident=SupportCrashIncident(report:try SupportCrashReport.read(file),date:Date()),held=HeldCrashScan(incident:incident)
        releaseHeld={held.finish()}
        service.discover={_,_,_,_,token in try await held.read(token)}
        service.checkForPreviousCrash();try await wait {held.continuation != nil}
        try require(!service.hasOwnedUtilityWindow && !service.presentExistingUtility() && SupportReportService.activeScans==1,"Background-only scan became presentation owner")
        held.finish();releaseHeld=nil;try await wait {service.recoveryNotice != nil && SupportReportService.activeScans==0}
        guard let recovery=service.recoveryNotice,let recoveryWindow=recovery.window else {throw Failure(description:"Recovery owner missing")}
        try await verifyHelp(recoveryWindow)
        let recoveryWindows=Set(NSApp.windows.map(ObjectIdentifier.init))
        _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        service.checkForPreviousCrash()
        try require(service.recoveryNotice === recovery && noticeFactories==1 && held.reads==1 && scene.storedController==nil && Set(NSApp.windows.map(ObjectIdentifier.init))==recoveryWindows,"Recovery reopen replaced owner, rescanned or opened workspace")
        recoveryWindow.performClose(nil);try await wait {service.recoveryNotice==nil}
        try require(!service.hasOwnedUtilityWindow && !service.presentExistingUtility(),"Closed recovery retained presentation fence")
        try require(service.show(),"Direct report presentation refused")
        guard let report=service.controller else {throw Failure(description:"Report owner absent")}
        try await verifyHelp(report.window!)
        report.model.field(\.details,context:report.model.context).wrappedValue="Retained support draft"
        let reportWindows=Set(NSApp.windows.map(ObjectIdentifier.init))
        _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        try require(service.show() && service.controller === report && reportFactories==1 && report.model.draft.details=="Retained support draft" && held.reads==1 && scene.storedController==nil && Set(NSApp.windows.map(ObjectIdentifier.init))==reportWindows,"Report reopen lost draft/owner or created workspace/scan")
        var reportRead:CheckedContinuation<SupportCrashReport,Error>?,reportReadToken:OperationCancellation?
        report.model.readFile={_,token in reportReadToken=token;return try await withCheckedThrowingContinuation{reportRead=$0}}
        report.model.load(file,lease:RepositoryAccessLease(url:file,provider:Scope()))
        releaseHeld={let reply=reportRead;reportRead=nil;reply?.resume(throwing:CancellationError())}
        try await wait {reportRead != nil}
        _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        try require(service.controller === report && reportFactories==1 && scene.storedController==nil && held.reads==1,"Held import reopen replaced support owner or rescanned")
        report.window!.performClose(nil);try await wait {service.controller==nil}
        try require(reportReadToken?.isCancelled==true && SupportReportWindowModel.activeReads==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Native report Close released held import before drain")
        try require(!service.hasOwnedUtilityWindow && service.show(),"Closed report retained sticky owner")
        let replacement=service.controller!
        try require(replacement !== report && reportFactories==2 && replacement.model.draft.details.isEmpty && held.reads==1 && factoryFence && workspacePresentations==0,"Fresh report/factory admission lost ownership or reused retired draft")
        reportRead?.resume(throwing:Failure(description:"Late retired import diagnostic"));reportRead=nil;releaseHeld=nil
        try await wait {SupportReportWindowModel.activeReads==0}
        try require(report.model.error==nil && replacement.model.error==nil && replacement.model.report==nil,"Old report drain published into retired/replacement owner")
        replacement.window!.performClose(nil);try await wait {service.controller==nil}
        _=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        try require(workspacePresentations==1 && scene.storedController != nil && model.workspaceWindow === scene.storedController?.window,"Closing utility suppressed actual subsequent workspace intent")
        scene.storedController?.close()
        phase("utility actual Close and workspace successor complete")
    }
    @MainActor static func verifyImportCancellation(root:URL,file:URL) async throws {
        phase("import cancel/drain and stable native geometry")
        let owner=SupportReportWindowController(systemInformation:"Native support lifecycle",home:"/Users/example")
        owners.append(owner);owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        let model=owner.model,prior=try SupportCrashReport.read(file)
        let emptyGeometry=try await geometry(owner)
        try require(model.installRecoveredReport(prior),"Prior report setup refused")
        model.field(\.includeCrashReport,context:model.context).wrappedValue=true
        model.field(\.replaceHomePath,context:model.context).wrappedValue=false
        model.field(\.details,context:model.context).wrappedValue="Preserved private draft /Users/example/project"
        let baseline=try await geometry(owner),preview=model.preview,details=model.draft.details
        try require(baseline==emptyGeometry,"Choosing/inclusion of report moved native editor/preview")
        var completion:CheckedContinuation<SupportCrashReport,Error>?,token:OperationCancellation?,reads=0
        model.readFile={_,value in reads += 1;token=value;return try await withCheckedThrowingContinuation {completion=$0;releaseHeld={let reply=completion;completion=nil;reply?.resume(throwing:CancellationError())}}}
        var lease:RepositoryAccessLease?=RepositoryAccessLease(url:file,provider:Scope())
        weak var retainedLease=lease
        model.load(file,lease:lease);lease=nil;try await wait {completion != nil}
        let staleCancel=model.readContext
        try require(model.reading && !model.canEdit && model.canCancelRead && retainedLease != nil && SupportReportWindowModel.activeReads==1,"Held import lost scope or read ownership")
        try await sameGeometry(owner,baseline,"held import")
        let cancel=publicButton(owner.window!,identifier:"support-report-cancel-reading",label:"Cancel reading")
        if cancel.action?()==true {
            phase("Cancel reading public accessibility press; "+cancel.diagnostic)
        } else {
            // Same immutable request receipt captured by the SwiftUI body.
            // This proves admission/drain, not the physical button callback.
            model.cancelRead(context:staleCancel)
            phase("Cancel reading captured-receipt fallback; physical button dispatch unproven; "+cancel.diagnostic)
        }
        try require(token?.isCancelled==true && model.readCancelling && model.reading && !model.canCancelRead && !model.canEdit && retainedLease != nil && SupportReportWindowModel.activeReads==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Cancel released read/lease/Quit before worker drain")
        model.load(file,lease:nil);model.cancelRead(context:staleCancel)
        try require(reads==1 && model.preview==preview && model.report?.text==prior.text && model.draft.details==details && model.draft.includeCrashReport && !model.draft.replaceHomePath,"Cancelling import changed existing report/privacy or admitted replacement")
        try await sameGeometry(owner,baseline,"cancelling import")
        completion?.resume(throwing:Failure(description:String(repeating:"late cancelled diagnostic ",count:100)));completion=nil
        try await wait {!model.reading && SupportReportWindowModel.activeReads==0 && retainedLease==nil}
        try require(model.canEdit && !model.readCancelling && model.error==nil && model.preview==preview && model.report?.text==prior.text && model.draft.includeCrashReport && !model.draft.replaceHomePath,"Cancelled failure published or discarded report/privacy")
        try await sameGeometry(owner,baseline,"cancel completion")
        model.load(file,lease:nil);try await wait {completion != nil}
        model.cancelRead(context:staleCancel)
        try require(token?.isCancelled==false && model.canCancelRead,"Old cancel receipt cancelled a newer import")
        completion?.resume(throwing:Failure(description:String(repeating:"current diagnostic must remain available ",count:100)));completion=nil
        try await wait {!model.reading && model.error != nil}
        try require(model.preview==preview && model.report?.text==prior.text && model.draft.includeCrashReport && !model.draft.replaceHomePath,"Failed replacement discarded prior report/privacy")
        try await sameGeometry(owner,baseline,"long current error")
        let replacementFile=root.appendingPathComponent(String(repeating:"long-report-name-",count:9)+"replacement.ips")
        try Data(prior.text.replacingOccurrences(of:"CRASH_MARKER",with:"REPLACEMENT_MARKER").utf8).write(to:replacementFile)
        let replacement=try SupportCrashReport.read(replacementFile)
        model.load(replacementFile,lease:nil);try await wait {completion != nil}
        try await sameGeometry(owner,baseline,"replacement read")
        completion?.resume(returning:replacement);completion=nil
        try await wait {!model.reading && model.report?.text==replacement.text}
        try require(model.draft.details==details && !model.draft.includeCrashReport && !model.draft.replaceHomePath && !model.preview.contains("REPLACEMENT_MARKER") && model.error==nil,"Replacement changed draft/privacy or silently included crash data")
        try await sameGeometry(owner,baseline,"replacement completion")
        let output=root.appendingPathComponent("geometry-write.txt"),bytes=Data(model.preview.utf8)
        var writeReply:CheckedContinuation<Void,Never>?
        model.writeFile={data,url in await withCheckedContinuation {writeReply=$0};try data.write(to:url,options:.atomic)}
        model.save(bytes,to:output,lease:nil);try await wait {writeReply != nil}
        releaseHeld={writeReply?.resume();writeReply=nil}
        try await sameGeometry(owner,baseline,"held write")
        owner.window!.performClose(nil)
        try require(!model.retired && model.writing && SupportReportWindowModel.activeWrites==1,"Native Close retired accepted write")
        writeReply?.resume();writeReply=nil;releaseHeld=nil
        try await wait {!model.writing && model.notice != nil}
        try require((try Data(contentsOf:output))==bytes,"Stable write lost accepted immutable bytes")
        try await sameGeometry(owner,baseline,"write completion notice")
        model.removeReport(context:model.context)
        try require(model.report==nil && !model.draft.includeCrashReport,"Remove after replacement kept private crash report")
        try await sameGeometry(owner,emptyGeometry,"report removal")
        owner.window!.performClose(nil);try require(model.retired,"Native Close did not retire idle support owner")
        phase("import cancellation/replacement/write geometry complete")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = root.appendingPathComponent("TurtleGit-fixture.ips"), destination = root.appendingPathComponent("saved-report.txt")
        let body = #"{"bug_type":"309","incident_id":"fixture-only"}"# + "\n" + #"{"procName":"TurtleGitMac","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"procPath":"/Users/example/project/TurtleGitMac","fixture":"CRASH_MARKER","threads":[]}"#
        try Data(body.utf8).write(to: file)
        try await verifyRecovery(root:root)
        try await verifyUtilityOwnership(root:root,file:file)
        try await verifyImportCancellation(root:root,file:file)
        let bundle = Bundle(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app"))!
        let info = ApplicationAboutInformation(application: bundle.bundleURL, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        func owner() -> SupportReportWindowController {
            let value = SupportReportWindowController(systemInformation: info.versionText + "\nmacOS: " + ProcessInfo.processInfo.operatingSystemVersionString, home: "/Users/example")
            owners.append(value); value.window!.alphaValue = 0; value.window!.orderFront(nil); return value
        }
        func quitBlocked() -> Bool { TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel }
        var releaseCheck: SupportReportWindowController? = SupportReportWindowController(systemInformation: "Lifecycle fixture")
        weak var released = releaseCheck
        releaseCheck?.close(); releaseCheck = nil
        try await wait { released == nil }
        let controller = owner(), model = controller.model
        let board = NSPasteboard(name: .init("TurtleGit.Support.QA." + UUID().uuidString)); controller.clipboard = board; defer { board.clearContents() }
        var openReply: ((NSApplication.ModalResponse) -> Void)?, saveReply: ((NSApplication.ModalResponse) -> Void)?, openCount = 0, links = [URL]()
        controller.openURL = { links.append($0) }
        controller.presentOpen = { _, own, reply in precondition(own === controller.window); openReply = reply; openCount += 1 }
        controller.presentSave = { _, own, reply in precondition(own === controller.window); saveReply = reply }
        controller.panelURL = { _ in file }
        let initial = model.context, oldField = model.field(\.details, context: initial)
        oldField.wrappedValue = "Commit window closed while reviewing /Users/example/project."
        controller.importReport(context: initial)
        try require(model.picking && SupportReportWindowController.activePickers == 1 && quitBlocked(), "Picker did not own Quit")
        oldField.wrappedValue = "during picker"; controller.importReport(context: initial)
        try require(openCount == 1 && model.draft.details != "during picker", "Picker allowed retained field/action")
        openReply?(.OK); openReply?(.OK)
        try await wait { !model.reading && model.report != nil }
        try require(!model.draft.includeCrashReport && !model.preview.contains("CRASH_MARKER") && model.preview.contains("<HOME>/project"), "Import silently included report or missed home replacement")
        model.field(\.includeCrashReport, context: model.context).wrappedValue = true
        try require(model.preview.contains("CRASH_MARKER") && !model.preview.contains("/Users/example"), "Explicit inclusion did not reach preview")
        controller.copyReport(context: model.context); try require(board.string(forType: .string) == model.preview, "Copy differs from preview")
        controller.issueForm(context: model.context)
        try require(links.count == 1 && links[0].absoluteString == "https://github.com/jfk-solutions/turtle-git-mac/issues/new" && links[0].query == nil, "Issue action disclosed report in URL")
        let descendants = views(controller.window!.contentView!)
        guard let preview = descendants.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Exact problem report" }) else { throw Failure(description: "Native report preview missing") }
        try require(!preview.isEditable && preview.isSelectable, "Report preview not selectable/read-only")
        // Export freezes bytes before the Save sheet even if the model is changed directly.
        let snapshot = Data(model.preview.utf8); controller.panelURL = { _ in destination }; controller.exportReport(context: model.context)
        model.draft.details = "newer draft"; saveReply?(.OK); saveReply?(.OK)
        try await wait { !model.writing && model.notice != nil }
        try require(try Data(contentsOf: destination) == snapshot, "Save lost reviewed snapshot")
        model.field(\.details, context: model.context).wrappedValue = "Commit window closed while reviewing /Users/example/project."
        try await capture(controller.window!)
        model.writeFile = { _, _ in throw Failure(description: "Fixture write failure") }
        controller.exportReport(context: model.context); saveReply?(.OK); try await wait { !model.writing && model.error != nil }
        try require(model.notice == nil && (try Data(contentsOf: destination)) == snapshot, "Write failure lost existing report")
        model.removeReport(context: model.context); try require(model.report == nil && !model.preview.contains("CRASH_MARKER"), "Remove retained report payload")
        // Actual native sheet cancellation uses the private fixture directory.
        controller.presentOpen = { panel, own, reply in panel.directoryURL = root; panel.beginSheetModal(for: own, completionHandler: reply) }
        controller.importReport(context: model.context); try await wait { controller.window!.attachedSheet is NSOpenPanel }
        let panel = controller.window!.attachedSheet!
        try require(panel.sheetParent === controller.window, "Import attached to another window")
        controller.window!.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
        try await wait { !model.picking && SupportReportWindowController.activePickers == 0 }
        let beforeClose = board.string(forType: .string), stale = model.context; controller.close()
        controller.copyReport(context: stale); controller.issueForm(context: stale); model.field(\.details, context: stale).wrappedValue = "retired"
        try require(board.string(forType: .string) == beforeClose && links.count == 1 && model.draft.details != "retired", "Closed controller dispatched retained actions")
        let late = owner(); var lateReply: ((NSApplication.ModalResponse) -> Void)?
        late.presentOpen = { _, _, answer in lateReply = answer }; late.panelURL = { _ in file }
        late.importReport(context: late.model.context); late.close(); lateReply?(.OK)
        try require(late.model.report == nil && SupportReportWindowController.activePickers == 0, "Closed picker started read")
        let held = owner(), originalPreview = held.model.preview
        var finishRead: CheckedContinuation<SupportCrashReport, Error>?, token: OperationCancellation?
        held.model.readFile = { _, value in token = value; return try await withCheckedThrowingContinuation { finishRead = $0; releaseHeld = { finishRead?.resume(returning: try! SupportCrashReport.read(file)); finishRead = nil } } }
        held.model.load(file, lease: nil); try await wait { finishRead != nil }
        held.close(); try require(token?.isCancelled == true && SupportReportWindowModel.activeReads == 1 && quitBlocked(), "Read closure lost cancellation/count")
        releaseHeld?(); releaseHeld = nil; try await wait { SupportReportWindowModel.activeReads == 0 }
        try require(held.model.preview == originalPreview && held.model.report == nil && held.model.error == nil, "Retired read published")
        let writing = owner(), output = root.appendingPathComponent("accepted-after-close.txt"), acceptedBytes = Data("accepted immutable report".utf8)
        var finishWrite: CheckedContinuation<Void, Never>?
        writing.model.writeFile = { data, url in
            await withCheckedContinuation { finishWrite = $0; releaseHeld = { finishWrite?.resume(); finishWrite = nil } }
            try data.write(to: url, options: .atomic)
        }
        writing.model.save(acceptedBytes, to: output, lease: nil); try await wait { finishWrite != nil }
        writing.close(); try require(SupportReportWindowModel.activeWrites == 1 && quitBlocked(), "Accepted write lost Quit ownership")
        releaseHeld?(); releaseHeld = nil; try await wait { SupportReportWindowModel.activeWrites == 0 }
        try require((try Data(contentsOf: output)) == acceptedBytes && writing.model.notice == nil && writing.model.error == nil, "Accepted write or retired publication differs")

    }
}
