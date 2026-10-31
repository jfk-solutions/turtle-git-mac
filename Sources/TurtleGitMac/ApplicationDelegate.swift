import AppKit
import Combine
import Carbon
import os
import TurtleGitCore

/// The Settings-only SwiftUI scene does not forward GetURL Apple events to
/// NSApplicationDelegate.open. Own that event explicitly; never forward the same
/// event into AppKit again, and never deduplicate legitimate repeated requests.
@MainActor private final class InboundURLAppleEvents: NSObject {
    private static weak var current: InboundURLAppleEvents?
    private weak var delegate: TurtleGitApplicationDelegate?
    private var retired = false
    private var received = 0
    private static let log = Logger(subsystem: "org.turtlegit.macos", category: "InboundURL")
    init(delegate: TurtleGitApplicationDelegate) { self.delegate = delegate }
    func install(initial: Bool = false) {
        guard !retired, initial || Self.current === self else { return }
        Self.current = self
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(receive(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    func retire() {
        retired = true
        guard Self.current === self else { return }
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        Self.current = nil
    }
    @objc private func receive(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard !retired, Self.current === self else { return }
        received += 1
        guard event.eventClass == AEEventClass(kInternetEventClass), event.eventID == AEEventID(kAEGetURL),
              let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              text.utf8.count <= 1_048_576, !text.contains("\0"),
              let url = URL(string: text), WorkspaceOpenHandoff.accepts(url), let delegate else {
            Self.log.notice("GetURL event rejected; count=\(self.received, privacy: .public)")
            return
        }
        Self.log.notice("GetURL event accepted; count=\(self.received, privacy: .public)")
        delegate.application(NSApp, open: [url])
    }
}

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    private var menuImageObservers: [NSObjectProtocol] = []
    private var applyingMenuImages = false
    /// SwiftUI also creates native menu items after the menu's initial build.
    /// Observe image/item changes rather than replacing menu delegates, targets,
    /// validation or tracking ownership in every editor and dialog.
    func installMenuImageVisibility() {
        guard menuImageObservers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            menuImageObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.applyingMenuImages, let menu = notification.object as? NSMenu else { return }
                    self.applyingMenuImages = true
                    defer { self.applyingMenuImages = false }
                    MenuImageVisibility.apply(to: menu)
                }
            })
        }
        if let menu = NSApp.mainMenu { MenuImageVisibility.apply(to: menu) }
    }
    func retireMenuImageVisibility() {
        for observer in menuImageObservers { NotificationCenter.default.removeObserver(observer) }
        menuImageObservers.removeAll()
    }
    static var generalApplicationConfiguration:((TurtleGitApplicationDelegate)->Void)?
    var configureGeneralApplication:((TurtleGitApplicationDelegate)->Void)?
    private(set) var generalApplicationConfigured=false
    private var inboundURLBridge: InboundURLAppleEvents?
    private var inboundURLBridgeRetired = false
    private var receivedExternalLaunchIntent = false
    private var pendingDefaultWorkspaceLaunch = false
    private var reopenTraceCount = 0
    private static let launchLog = Logger(subsystem: "org.turtlegit.macos", category: "LaunchRouting")
    var diagnosticPreferences:UserDefaults = .standard
    var presentCommandDiagnostic:(CommandDiagnosticPreviewController)->Void = {$0.present()}
    private(set) var commandDiagnosticController:CommandDiagnosticPreviewController?
    private enum DiagnosticDecision {case pending,accepted,cancelled}
    private var diagnosticKey:String?,diagnosticAnswer:Bool?
    private func debugEnabled(startup:Bool=false)->Bool {
        if startupLaunchMode == .mergeTool {return startup && (diagnosticPreferences.object(forKey:"TurtleGitMerge.Debug") as? NSNumber)?.uint32Value == 1}
        guard isGeneralApplication else{return false}
        return (diagnosticPreferences.object(forKey:"Debug") as? NSNumber)?.uint32Value == 1
    }
    private func diagnosticDecision(_ key:String,arguments:[String],startup:Bool=false)->DiagnosticDecision {
        if diagnosticKey==key {guard let answer=diagnosticAnswer else{return .pending};return answer ? .accepted:.cancelled}
        guard diagnosticKey==nil else{return .pending}
        guard debugEnabled(startup:startup) else{return .accepted}
        diagnosticKey=key;diagnosticAnswer=nil
        let controller=CommandDiagnosticPreviewController(arguments:arguments) {[weak self] accepted in
            guard let self,self.acceptingOpenURLs,self.diagnosticKey==key else{return}
            self.commandDiagnosticController=nil;self.diagnosticAnswer=accepted
            NativeCommandDiagnostics.trace(accepted ? "command acknowledged":"command cancelled",arguments:arguments,preferences:self.diagnosticPreferences)
            DispatchQueue.main.async {[weak self] in self?.deliverStartupCommand();self?.deliverPendingOpenURLs();self?.deliverPendingFinderService()}
        }
        commandDiagnosticController=controller;activateStandaloneApplication();presentCommandDiagnostic(controller)
        return .pending
    }
    private func consumeDiagnostic(){diagnosticKey=nil;diagnosticAnswer=nil}
    func retireCommandDiagnostics(){commandDiagnosticController?.retire();commandDiagnosticController=nil;consumeDiagnostic()}



    func applicationWillFinishLaunching(_ notification: Notification) {
        installInboundURLBridge()
    }
    private func installInboundURLBridge() {
        guard acceptingOpenURLs, !inboundURLBridgeRetired else { return }
        if inboundURLBridge == nil {
            let bridge = InboundURLAppleEvents(delegate: self)
            inboundURLBridge = bridge; bridge.install(initial: true)
        } else { inboundURLBridge?.install() }
    }
    func retireInboundURLBridge() {
        inboundURLBridgeRetired = true
        inboundURLBridge?.retire(); inboundURLBridge = nil
    }
    private var defaultWorkspaceRequested=false
    private var isGeneralApplication:Bool {startupLaunchMode == .workspace || startupLaunchMode == .actionOnly}
    private func configureGeneralApplicationIfNeeded() {
        guard isGeneralApplication,!generalApplicationConfigured,
              let configure=configureGeneralApplication ?? Self.generalApplicationConfiguration else{return}
        generalApplicationConfigured=true
        configure(self)
    }
    // SwiftUI installs scene handlers during launch. Reassert our one owner
    // after that setup and once at the next main-queue boundary. The deferred
    // operation retains neither the delegate nor permission to create a new owner.
    func finishInstallingInboundURLBridge() {
        installInboundURLBridge()
        DispatchQueue.main.async { [weak bridge = inboundURLBridge] in bridge?.install() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        finishInstallingInboundURLBridge()
        configureGeneralApplicationIfNeeded()
        installMenuImageVisibility()
        #if SWIFT_PACKAGE
        let iconBundle = Bundle.module
        #else
        let iconBundle = Bundle.main
        #endif
        if let file = iconBundle.url(forResource:"ApplicationIcon",withExtension:"png",subdirectory:"Branding"),let icon=NSImage(contentsOf:file) {NSApp.applicationIconImage=icon}
        TurtleGitHelp.install()
        startupDidFinishLaunching(defaultLaunch:notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool)
        if startupLaunchMode == .workspace { SupportReportService.shared.checkForPreviousCrash() }
        installFinderServices()
    }
    @objc func showHelp(_ sender: Any?) { TurtleGitHelp.showContext() }
    lazy var finderServicesProvider = TurtleGitFinderServicesProvider(open: { [weak self] paths in
        guard let self else {throw TurtleGitFinderServicesProvider.Failure.unavailable}
        try self.submitOpenServiceSelection(paths)
    }) { [weak self] request in
        guard let self else { throw TurtleGitFinderServicesProvider.Failure.unavailable }
        try self.submitServiceRequest(request)
    }
    private var previousFinderServicesProvider: Any?
    private var finderServicesInstalled = false
    private var deliveringFinderService=false
    var workspaceServiceHandler: (RepositoryModel, FinderRequest) -> Bool = { $0.handleFinderService($1) }
    private(set) var pendingFinderServiceRequest: FinderRequest?
    private(set) var pendingOpenServiceSelection:[URL]?
    var workspaceOpenSelectionHandler:(RepositoryModel,[URL])->Bool = {$0.handleOpenServiceSelection($1)}
    private var pendingFinderServiceError: String?
    func installFinderServices() {
        guard !finderServicesInstalled, acceptingOpenURLs else { return }
        previousFinderServicesProvider = NSApp.servicesProvider
        finderServicesInstalled = true
        NSApp.servicesProvider = finderServicesProvider
    }
    func retireFinderServices() {
        if diagnosticKey?.hasPrefix("service") == true {retireCommandDiagnostics()}
        finderServicesProvider.retire()
        pendingFinderServiceRequest = nil; pendingOpenServiceSelection=nil; pendingFinderServiceError = nil
        guard finderServicesInstalled else { return }
        finderServicesInstalled = false
        if (NSApp.servicesProvider as AnyObject?) === finderServicesProvider {
            NSApp.servicesProvider = previousFinderServicesProvider
        }
        previousFinderServicesProvider = nil
    }
    func submitOpenServiceSelection(_ paths:[URL])throws {
        guard acceptingOpenURLs,!finderServicesProvider.retired,!confirmingQuit,repositoryModel?.confirmingQuit != true else{throw TurtleGitFinderServicesProvider.Failure.unavailable}
        let captured=try FinderServiceCommand.status.request(paths:paths).paths
        if !isGeneralApplication || (startupLaunchMode != .workspace && presentWorkspace == nil) {
            workspaceOpenHandoff.submit([try TurtleGitFinderServicesProvider.openSelectionURL(captured)]);return
        }
        guard pendingOpenServiceSelection==nil,pendingFinderServiceRequest==nil,repositoryModel?.busy != true,repositoryModel?.hasPendingRepositoryWork != true else{throw TurtleGitFinderServicesProvider.Failure.busy}
        receivedExternalLaunchIntent=true
        pendingOpenServiceSelection=captured;deliverPendingFinderService()
    }
    func submitServiceRequest(_ request: FinderRequest) throws {
        guard acceptingOpenURLs,!finderServicesProvider.retired,!confirmingQuit else {throw TurtleGitFinderServicesProvider.Failure.unavailable}
        guard let command=FinderServiceCommand(rawValue:request.action.rawValue) else {throw TurtleGitFinderServicesProvider.Failure.command}
        let captured=try command.request(paths:request.paths,alternateTool:request.alternateTool)
        if startupLaunchMode == .mergeTool || startupLaunchMode == .imageTool || startupLaunchMode == .unifiedDiff {
            workspaceOpenHandoff.submit([try command.serviceURL(paths:captured.paths,alternateTool:captured.alternateTool)]);return
        }
        guard pendingFinderServiceRequest == nil else {throw TurtleGitFinderServicesProvider.Failure.busy}
        receivedExternalLaunchIntent=true
        if captured.action != .registerRepository {activateStandaloneApplication()}
        if startupReady,startupDelivered,!deliveringFinderService,pendingOpenServiceSelection==nil,!debugEnabled(),diagnosticKey==nil,configurationReadsReady() {
            let target=actionRoutingModel()
            guard !target.busy,!target.hasPendingRepositoryWork,!target.confirmingQuit,workspaceServiceHandler(target,captured) else {throw TurtleGitFinderServicesProvider.Failure.busy}
        } else {pendingFinderServiceRequest=captured;deliverPendingFinderService()}
    }
    private func deliverPendingFinderService() {
        guard acceptingOpenURLs,!confirmingQuit,!deliveringFinderService,startupReady,startupDelivered,repositoryModel != nil else{return}
        deliveringFinderService=true
        var consumed=false
        defer {
            deliveringFinderService=false
            if consumed,(pendingOpenServiceSelection != nil || pendingFinderServiceRequest != nil) {
                DispatchQueue.main.async {[weak self] in self?.deliverPendingFinderService()}
            }
        }
        if pendingOpenServiceSelection != nil || pendingFinderServiceRequest != nil {
            let arguments=pendingOpenServiceSelection.map{["Service: Open"]+$0.map(\.path)} ?? pendingFinderServiceRequest.map{["Service: "+$0.action.rawValue]+$0.paths.map(\.path)} ?? []
            switch diagnosticDecision(pendingOpenServiceSelection != nil ? "service-open":"service",arguments:arguments) {
            case .pending:return
            case .cancelled:pendingOpenServiceSelection=nil;pendingFinderServiceRequest=nil;consumeDiagnostic();return
            case .accepted:break
            }
            guard configurationReadsReady() else { return }
        }
        if let paths=pendingOpenServiceSelection {
            guard isGeneralApplication,workspaceDeliveryReady(),let currentWorkspace=repositoryModel else{return}
            pendingOpenServiceSelection=nil;consumeDiagnostic();consumed=true
            if confirmingQuit || !workspaceOpenSelectionHandler(currentWorkspace,paths) {pendingFinderServiceError=TurtleGitFinderServicesProvider.Failure.busy.localizedDescription}
        } else if let request=pendingFinderServiceRequest {
            pendingFinderServiceRequest=nil;consumeDiagnostic();consumed=true
            let target=actionRoutingModel()
            if confirmingQuit || target.confirmingQuit || target.busy || target.hasPendingRepositoryWork || !workspaceServiceHandler(target,request) {pendingFinderServiceError="TurtleGit could not begin the queued service. Finish or cancel the current operation, then invoke the service again."}
        }
        if let message=pendingFinderServiceError {pendingFinderServiceError=nil;actionRoutingModel(loadSavedAccess: false).error=message}
    }
    weak var repositoryModel: RepositoryModel? { didSet { deliverStartupCommand(); deliverPendingOpenURLs(); deliverPendingFinderService() } }
    // Installed by the identified workspace scene. A standalone Merge process
    // never installs this route or creates a repository window for incoming URLs.
    var presentWorkspace: (() -> Void)?
    private var workspacePresentationRequested = false
    private var pendingWorkspaceRepositoryChoice = false
    private func workspaceDeliveryReady() -> Bool {
        guard let presentWorkspace else { return true } // Injected/headless owners.
        guard repositoryModel?.workspaceWindow != nil else {
            if !workspacePresentationRequested {
                workspacePresentationRequested = true
                presentWorkspace()
                // The general AppKit host is synchronous. A refused Settings
                // context change must not latch an unfulfillable scene request.
                if generalApplicationConfigured,repositoryModel?.workspaceWindow == nil {workspacePresentationRequested=false}
            }
            return repositoryModel?.workspaceWindow != nil
        }
        return true
    }
    func workspaceWindowDidAttach() {
        guard acceptingOpenURLs, isGeneralApplication, repositoryModel?.workspaceWindow != nil else { return }
        workspacePresentationRequested = false
        deliverStartupCommand(); deliverPendingOpenURLs(); deliverPendingFinderService();deliverWorkspaceRepositoryChoice()
    }
    var startupArguments = Array(CommandLine.arguments.dropFirst())
    var startupDirectory = FileManager.default.currentDirectoryPath
    var startupCommandHandler: ((RepositoryModel, [String], String) -> Void)?
    var startupMergeToolExit: (Int32) -> Void = { exit($0) }
    private var startupMergeToolActive = false
    private var pendingMergeToolExit: Int32?
    private var completingMergeToolExit = false
    private var mergeToolShutdownPrepared = false, mergeToolExitDelivered = false
    var consumeFinderAction: (FinderActionDelivery) throws -> FinderRequest = { delivery in
        guard let store = FinderActionHandoff.current else { throw FinderActionLaunchFailure.unavailable }
        return try store.consume(delivery)
    }
    private var finderActionReceipts: [String: RepositoryAction] = [:]
    private var finderActionReceiptOrder: [String] = []
    private func acceptFinderAction(_ delivery: FinderActionDelivery) {
        guard acceptingOpenURLs, !confirmingQuit else { return }
        if let action = finderActionReceipts[delivery.receipt] {
            if action != delivery.action { pendingFinderServiceError = FinderActionLaunchFailure.collision.localizedDescription }
            return
        }
        // Claim transport delivery, not repository authority. Even a failed
        // opaque-file read owns one diagnostic rather than one per argv/GetURL
        // channel; a new Finder click publishes a fresh independently usable ID.
        finderActionReceipts[delivery.receipt] = delivery.action
        finderActionReceiptOrder.append(delivery.receipt)
        if finderActionReceiptOrder.count > 1024 {
            finderActionReceipts.removeValue(forKey: finderActionReceiptOrder.removeFirst())
        }
        do {
            let request = try consumeFinderAction(delivery)
            guard request.action == delivery.action, let url = request.url else { throw FinderActionLaunchFailure.invalid }
            receivedExternalLaunchIntent = true
            pendingOpenURLs.append(url)
        } catch {
            pendingFinderServiceError = FinderActionLaunchFailure.invalid.localizedDescription + "\n\n" + error.localizedDescription
        }
    }
    private var pendingOpenURLs: [URL] = []
    private var deliveringOpenURLs = false, acceptingOpenURLs = true
    var workspaceOpenHandler: (RepositoryModel, URL) -> Void = { $0.handle($1) }
    lazy var workspaceOpenHandoff: WorkspaceOpenHandoff = {
        let value = WorkspaceOpenHandoff()
        value.onStateChanged = { [weak self] in self?.completeMergeToolExitIfReady() }
        return value
    }()
    func application(_ application: NSApplication, open urls: [URL]) {
        guard acceptingOpenURLs else { return }
        if urls.contains(where: WorkspaceOpenHandoff.accepts) { receivedExternalLaunchIntent = true }
        if startupLaunchMode == .mergeTool || startupLaunchMode == .imageTool || startupLaunchMode == .unifiedDiff { workspaceOpenHandoff.submit(urls) }
        else {
            for url in urls {
                if let delivery = FinderActionDelivery(url: url) {
                    acceptFinderAction(delivery)
                } else if url.scheme=="turtlegit",url.host=="service-open" {
                    do {try submitOpenServiceSelection(TurtleGitFinderServicesProvider.openSelection(from:url))}
                    catch {pendingFinderServiceError=error.localizedDescription}
                } else if url.scheme == "turtlegit", url.host == "service" {
                    do { try submitServiceRequest(FinderServiceCommand.request(serviceURL: url)) }
                    catch { pendingFinderServiceError = error.localizedDescription }
                } else { pendingOpenURLs.append(url) }
            }
            deliverPendingOpenURLs(); deliverPendingFinderService()
        }
    }
    /// Only typed utility requests which do not capture a repository context
    /// can open before Git configuration and saved authority are prepared.
    /// CLI Settings always carries its current/explicit path; an empty-path
    /// Settings URL deliberately asks for the global native property sheet.
    static func isRepositoryIndependentUtility(_ request:FinderRequest)->Bool {
        request.action.isApplicationUtility && (request.action != .settings || request.paths.isEmpty)
    }
    private var repositoryIndependentStartup:Bool {
        switch startupLaunchMode {
        case .imageTool,.unifiedDiff:return true
        case .mergeTool:
            guard let input=try? MergeToolInvocation.parse(arguments:startupArguments,currentDirectory:startupDirectory) else{return false}
            // Open and two/three-way readers use only captured local files and
            // the bundled MergeDiff engine. Patch review discovers a Git target;
            // patch generation runs Git diff --no-index, so retain their gate.
            return input.help || input.diff == nil && input.patchPath == nil && !input.createUnifiedDiff
        case .workspace:return false
        case .actionOnly:
            guard let invocation=try? PrimaryCommandInvocation.parse(arguments:startupArguments,currentDirectory:startupDirectory) else{return false}
            return Self.isRepositoryIndependentUtility(invocation.request)
        }
    }
    private func deliverPendingOpenURLs() {
        guard acceptingOpenURLs, !confirmingQuit, !deliveringOpenURLs, startupReady, startupDelivered,
              let repositoryModel else { return }
        deliveringOpenURLs = true
        defer { deliveringOpenURLs = false }
        while acceptingOpenURLs, !confirmingQuit, let url = pendingOpenURLs.first {
            // A request owns asynchronous saved-authority discovery before Git
            // starts. Leave later URLs in FIFO order until that owner is ready;
            // an open draft dialog alone does not hold this routing queue.
            if let action = actionRepositoryModel,
               action.busy || action.finderActionAuthorityPending { return }
            let diagnosticArguments=FinderRequest(url:url).map{["/command:"+$0.action.rawValue]+$0.paths.map{"/path:"+$0.path}} ?? [url.absoluteString]
            switch diagnosticDecision("url:"+url.absoluteString,arguments:diagnosticArguments) {
            case .pending:return
            case .cancelled:pendingOpenURLs.removeFirst();consumeDiagnostic();continue
            case .accepted:break
            }
            let workspaceRequest = ["turtlegit://workspace", "turtlegit://workspace?open=repository"].contains(url.absoluteString)
            // A typed local patch document retains its own file permission and
            // read lifetime. It needs no Git configuration until Apply; an
            // earlier queued Git request still owns FIFO admission before it.
            let localPatchDocument=WorkspaceOpenHandoff.acceptsPatchDocument(url)
            let finderRequest=FinderRequest(url:url)
            let independentUtility=finderRequest.map(Self.isRepositoryIndependentUtility) ?? false
            if !workspaceRequest && !localPatchDocument && !independentUtility {guard configurationReadsReady() else{return}}
            if workspaceRequest {
                pendingOpenURLs.removeFirst()
                requestWorkspace(openRepository: url.query == "open=repository")
            } else if FinderRequest(url: url) != nil || url.isFileURL {
                let target = actionRoutingModel(loadSavedAccess:!localPatchDocument && !independentUtility)
                guard !target.busy, !target.finderActionAuthorityPending else { return }
                pendingOpenURLs.removeFirst()
                if FinderRequest(url: url)?.action != .registerRepository { activateStandaloneApplication() }
                workspaceOpenHandler(target, url)
            } else {
                pendingOpenURLs.removeFirst()
                workspaceOpenHandler(repositoryModel, url)
            }
            consumeDiagnostic()
            NativeCommandDiagnostics.trace("URL admitted",arguments:diagnosticArguments,preferences:diagnosticPreferences)
            // Reentrant handlers append behind the remaining original URLs.
            // Recheck readiness after every admission instead of removing a
            // whole cohort that the next asynchronous owner could refuse.
        }
    }
    /// Dialog requests have a retained routing owner but no repository scene.
    /// Its scoped Settings service cannot evict the user's workspace Settings.
    private(set) var actionRepositoryModel:RepositoryModel?
    private var actionSettingsService:SettingsPresentationService?
    private var actionAppearance:AppAppearance?
    private var actionErrors:AnyCancellable?
    private var actionReadiness: AnyCancellable?
    private(set) var actionErrorController:WorkspaceHandoffFailureController?
    private var queuedActionErrors:[String]=[]
    private func actionRoutingModel(loadSavedAccess: Bool = true)->RepositoryModel {
        if let actionRepositoryModel {
            actionRepositoryModel.configureActionRouting(from: repositoryModel === actionRepositoryModel ? nil : repositoryModel, loadSavedAccess: loadSavedAccess)
            return actionRepositoryModel
        }
        let model:RepositoryModel
        if (startupLaunchMode == .actionOnly || generalApplicationConfigured),let standaloneWorkspace {model=standaloneWorkspace}
        else {
            model=makeStandaloneWorkspace()
            let appearance=AppAppearance(preferences:model.fileComparisonPreferences),service=SettingsPresentationService()
            actionAppearance=appearance;actionSettingsService=service
            service.install(workspace:model,appearance:appearance)
        }
        model.configureActionRouting(from:repositoryModel === model ? nil:repositoryModel, loadSavedAccess: loadSavedAccess)
        actionRepositoryModel=model
        actionReadiness = Publishers.CombineLatest(model.$busy, model.$finderActionAuthorityPending)
            .sink { [weak self, weak model] busy, preparingAuthority in
                guard !busy, !preparingAuthority else { return }
                // Published values arrive before their storage mutation. Resume
                // on the next main turn, then recheck the actual retained owner.
                DispatchQueue.main.async { [weak self, weak model] in
                    guard let self, let model, self.acceptingOpenURLs, !self.confirmingQuit,
                          self.actionRepositoryModel === model, !model.isRetired,
                          !model.busy, !model.finderActionAuthorityPending else { return }
                    self.deliverPendingOpenURLs()
                    if !model.busy, !model.finderActionAuthorityPending { self.deliverPendingFinderService() }
                }
            }
        model.onFinderRegistrationSaved={ [weak self,weak model] in
            guard let self,let model,self.actionRepositoryModel === model,!model.isRetired else{return}
            if self.repositoryModel !== model {self.repositoryModel?.refreshRegisteredRepositories()}
        }
        actionErrors=model.$error.compactMap{$0}.sink { [weak self,weak model] message in
            Task { @MainActor in
                guard let self,let model,self.acceptingOpenURLs,!model.isRetired,self.actionRepositoryModel === model else{return}
                self.queuedActionErrors.append(message);self.showNextActionError()
            }
        }
        return model
    }
    private func showNextActionError() {
        guard acceptingOpenURLs,!confirmingQuit,actionErrorController == nil,!queuedActionErrors.isEmpty else{return}
        let message=queuedActionErrors.removeFirst()
        let controller=WorkspaceHandoffFailureController(message:message,heading:"TurtleGit could not complete the requested action") { [weak self] in
            guard let self else{return};self.actionErrorController=nil
            if self.actionRepositoryModel?.error == message {self.actionRepositoryModel?.error=nil}
            self.showNextActionError()
        }
        actionErrorController=controller;activateStandaloneApplication();controller.present(owner:nil)
    }
    func requestWorkspace(openRepository:Bool = false) {
        guard acceptingOpenURLs,!confirmingQuit else{return}
        pendingDefaultWorkspaceLaunch=false
        defaultWorkspaceRequested=true
        activateStandaloneApplication()
        if isGeneralApplication,(presentWorkspace != nil || startupLaunchMode == .workspace) {
            pendingWorkspaceRepositoryChoice = pendingWorkspaceRepositoryChoice || openRepository
            let alreadyAttached=repositoryModel?.workspaceWindow != nil
            if !workspaceDeliveryReady() {return}
            if alreadyAttached {presentWorkspace?()}
            deliverWorkspaceRepositoryChoice()
        } else if let url=URL(string:openRepository ? "turtlegit://workspace?open=repository":"turtlegit://workspace") {workspaceOpenHandoff.submit([url])}
    }
    private func deliverWorkspaceRepositoryChoice() {
        guard pendingWorkspaceRepositoryChoice,isGeneralApplication,workspaceDeliveryReady(),let repositoryModel else{return}
        guard configurationReadsReady() else { return }
        pendingWorkspaceRepositoryChoice=false
        repositoryModel.chooseRepository()
    }
    /// Keep the router's Settings callbacks alive when the shared App-menu
    /// service adopts the explicitly presented workspace context.
    func attachWorkspaceModel(_ model:RepositoryModel,appearance:AppAppearance) {
        let action=actionRoutingModel(loadSavedAccess: false)
        action.configureActionRouting(from:model,loadSavedAccess:false)
        if action === standaloneWorkspace,actionSettingsService == nil {
            let scopedAppearance=AppAppearance(preferences:action.fileComparisonPreferences)
            let service=SettingsPresentationService()
            actionAppearance=scopedAppearance;actionSettingsService=service
            service.install(workspace:action,appearance:scopedAppearance)
        }
        SettingsPresentationService.shared.install(workspace:model,appearance:appearance)
        repositoryModel=model
    }
    private var routingModels:[RepositoryModel] {
        var models:[RepositoryModel]=[]
        for model in [repositoryModel,actionRepositoryModel].compactMap({$0}) where !models.contains(where:{$0 === model}) {models.append(model)}
        return models
    }
    func didResolveSavedMergeOutput(root:URL,path:String) {
        // Notify only existing owners. A standalone merge must not construct or
        // open a workspace merely to refresh the repository it actually changed.
        for model in routingModels {model.didResolveSavedMergeOutput(root:root,path:path)}
    }
    private func setRoutingQuitConfirmation(_ value:Bool) {for model in routingModels {model.confirmingQuit=value};if !value {showNextActionError()}}
    private func shutdownRoutingModels() async {
        for model in routingModels {model.stopMonitoringForTermination();await model.finderWatches?.shutdown();await model.shutdownFinderPublication()}
    }
    private func finishMergeToolStartup(_ status: Int32) {
        guard pendingMergeToolExit == nil, !completingMergeToolExit, !mergeToolExitDelivered else { return }
        pendingMergeToolExit = status; completeMergeToolExitIfReady()
    }
    private func completeMergeToolExitIfReady() {
        guard let status = pendingMergeToolExit, !completingMergeToolExit, !workspaceOpenHandoff.hasPendingWork else { return }
        completingMergeToolExit = true
        Task { [self] in
            if !mergeToolShutdownPrepared {
                repositoryModel?.stopMonitoringForTermination()
                await repositoryModel?.finderWatches?.shutdown();await repositoryModel?.shutdownFinderPublication()
                mergeToolShutdownPrepared = true
            }
            completingMergeToolExit = false
            // Launch Services may deliver another request while shutdown yields.
            // Its accepted launch/acknowledgment must finish before process exit.
            guard !workspaceOpenHandoff.hasPendingWork, !mergeToolExitDelivered else { return }
            pendingMergeToolExit = nil; mergeToolExitDelivered = true; startupMergeToolActive = false
            applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            startupMergeToolExit(status)
        }
    }
    // Native routing waits asynchronously; the Core command boundary also
    // protects direct menu/UI reads which can arrive before this queue drains.
    var prepareGitConfigurationReads: () async -> Void = { await GitConfigurationPermissions.restoreForGitReads() }
    private(set) var gitConfigurationReadsReady = false
    private var gitConfigurationPreparation: Task<Void, Never>?
    private func configurationReadsReady() -> Bool {
        if gitConfigurationReadsReady { return true }
        guard startupReady, acceptingOpenURLs, !confirmingQuit else { return false }
        if gitConfigurationPreparation == nil {
            gitConfigurationPreparation = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepareGitConfigurationReads()
                self.gitConfigurationPreparation = nil
                guard !Task.isCancelled, self.acceptingOpenURLs else { return }
                self.gitConfigurationReadsReady = true
                guard !self.confirmingQuit else { return }
                self.deliverStartupCommand()
                self.deliverPendingOpenURLs()
                self.deliverPendingFinderService()
                self.deliverWorkspaceRepositoryChoice()
                self.finishPendingDefaultWorkspaceLaunch()
            }
        }
        return false
    }
    private var startupReady = false
    private(set) var startupDelivered = false
    var startupLaunchMode: TurtleGitLaunchMode { TurtleGitLaunchMode.resolve(arguments: startupArguments, currentDirectory: startupDirectory) }
    // The standalone Scene has no RepositoryWindow.onAppear. Retain its minimal
    // routing owner here, without starting Finder monitors or opening a workspace.
    private(set) var standaloneWorkspace: RepositoryModel?
    private var standaloneAppearance: AppAppearance?
    private var standaloneActivationRequested = false
    var activateStandaloneApplication: () -> Void = {
        // A tool executed directly by Git has no SwiftUI document window to
        // activate the process. makeKeyAndOrderFront on the later AppKit editor
        // cannot establish its key-window menu owner while the app is inactive.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    var makeStandaloneWorkspace: () -> RepositoryModel = {
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false)
        model.enableActionRoutingAccess()
        return model
    }
    var makeStandaloneAppearance:()->AppAppearance = {AppAppearance(preferences:.standard)}
    var configureStandaloneServices: (RepositoryModel, AppAppearance) -> Void = { workspace, appearance in
        appearance.apply()
        SettingsPresentationService.shared.install(workspace: workspace, appearance: appearance)
        // Automatic first-run/update UI belongs to an explicitly presented
        // workspace, not this lightweight command/URL routing owner.
    }
    func bootstrapStandaloneToolIfNeeded() {
        guard (startupLaunchMode != .workspace || generalApplicationConfigured), repositoryModel == nil, standaloneWorkspace == nil else { return }
        let workspace = makeStandaloneWorkspace(), appearance = makeStandaloneAppearance()
        standaloneWorkspace = workspace; standaloneAppearance = appearance
        configureStandaloneServices(workspace, appearance)
        repositoryModel = workspace
    }
    func startupDidFinishLaunching(defaultLaunch:Bool? = nil) {
        NativeCommandDiagnostics.configure(preferences:diagnosticPreferences)
        configureGeneralApplicationIfNeeded()
        bootstrapStandaloneToolIfNeeded(); startupReady = true
        if standaloneWorkspace != nil, startupLaunchMode != .workspace, !headlessRegistrationStartup, !standaloneActivationRequested {
            standaloneActivationRequested = true; activateStandaloneApplication()
        }
        // Install command/error ownership without restoring saved repository
        // access. Explicit actions acquire that authority on demand below.
        if startupLaunchMode == .actionOnly || generalApplicationConfigured { _ = actionRoutingModel(loadSavedAccess: false) }
        deliverStartupCommand();deliverPendingOpenURLs();deliverPendingFinderService()
        // Defer the fallback through the initial Apple-event delivery boundary.
        // An accepted URL/Service or an explicit workspace request in that same
        // launch transaction takes precedence over AppKit's default-launch flag.
        // A missing flag is never inferred to mean a default launch.
        if generalApplicationConfigured,startupLaunchMode == .workspace,defaultLaunch == true,!receivedExternalLaunchIntent,!defaultWorkspaceRequested {
            pendingDefaultWorkspaceLaunch=true
            DispatchQueue.main.async { [weak self] in self?.finishPendingDefaultWorkspaceLaunch() }
        }
    }
    private var headlessRegistrationStartup:Bool {
        startupArguments == ["--turtlegit-action-only"] ||
            FinderActionDelivery.parse(arguments: startupArguments)?.action == .registerRepository ||
            (try? PrimaryCommandInvocation.parse(arguments:startupArguments,currentDirectory:startupDirectory))?.request.action == .registerRepository
    }
    /// Also used by the launch fixture to drive the same queued boundary without
    /// manufacturing an application activation or a user Dock reopen.
    func finishPendingDefaultWorkspaceLaunch() {
        guard pendingDefaultWorkspaceLaunch else{return}
        pendingDefaultWorkspaceLaunch=false
        guard acceptingOpenURLs,!confirmingQuit,startupReady,startupDelivered,
              generalApplicationConfigured,startupLaunchMode == .workspace,
              !receivedExternalLaunchIntent,!defaultWorkspaceRequested else{return}
        Self.launchLog.notice("Presenting workspace for default application launch")
        requestWorkspace()
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {false}
    func applicationOpenUntitledFile(_ sender:NSApplication)->Bool {
        // This callback is AppKit's untitled-document fallback, not an explicit
        // repository request. In particular, activating a standalone permission
        // panel must never promote its headless command owner into a workspace.
        // Normal launch, Dock reopen and Open Repository have separate routes.
        Self.launchLog.notice("Refused automatic untitled workspace presentation")
        return false
    }
    // Closing the workspace must not end an owned Git/editor child or stop
    // Finder routing. Reopen and the next external request use the same scene.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private var actionPresentationPending:Bool {
        guard let action=actionRepositoryModel,!action.isRetired else{return false}
        return action.busy || action.hasPendingRepositoryWork
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Diagnostic metadata is deliberately bounded and excludes URLs, paths,
        // command arguments and permission payloads. Physical acceptance can
        // distinguish this route from the default/untitled routes without
        // inferring which Cocoa callback caused an unexpected host.
        if reopenTraceCount < 32 {
            reopenTraceCount += 1
            let mode=String(describing:startupLaunchMode)
            let branch = !acceptingOpenURLs || confirmingQuit ? "retired-or-quitting" :
                (!startupReady || !startupDelivered ? "startup-pending" :
                    (isGeneralApplication && flag ? "existing-window" :
                        (isGeneralApplication && actionPresentationPending ? "action-work-pending" :
                            (isGeneralApplication ? "workspace-request" : "tool-refused"))))
            Self.launchLog.notice("Reopen route: \(branch, privacy: .public); mode=\(mode, privacy: .public); startupReady=\(self.startupReady, privacy: .public); startupDelivered=\(self.startupDelivered, privacy: .public); hasVisibleWindows=\(flag, privacy: .public)")
        }
        guard acceptingOpenURLs,!confirmingQuit else{return false}
        // A launch-time callback cannot outrun initial command/URL ownership.
        // Once startup has delivered, an actual Dock reopen remains an explicit
        // request, including after a headless registration has finished.
        guard startupReady,startupDelivered else{return false}
        // Let AppKit raise the existing operation/utility window. Its flag also
        // includes minimized windows; scanning isVisible would miss those and
        // create an unrelated workspace over the user's dialog. Explicit Open
        // Repository, workspace URLs and the Open Service keep their own route.
        if isGeneralApplication, flag {return true}
        // A command can own preparation before its panel becomes visible and
        // while that panel detaches. Preserve that owner across the presentation
        // gap; only the action model participates, not background workspace work.
        if isGeneralApplication,actionPresentationPending {return false}
        if startupLaunchMode == .actionOnly {requestWorkspace();return false}
        guard startupLaunchMode == .workspace else{return false}
        guard let presentWorkspace else { return true }
        activateStandaloneApplication()
        // With no visible windows, Dock reopen restores the retained workspace.
        presentWorkspace()
        return false
    }
    private func deliverStartupCommand() {
        guard acceptingOpenURLs,!confirmingQuit,startupReady, !startupDelivered, let repositoryModel,
              generalApplicationConfigured || startupLaunchMode != .workspace || workspaceDeliveryReady(), !startupDelivered else { return }
        if startupArguments != ["--turtlegit-action-only"],!startupArguments.contains(FinderActionDelivery.argumentFlag) {
            switch diagnosticDecision("startup",arguments:startupArguments,startup:true) {
            case .pending:return
            case .cancelled:consumeDiagnostic();startupDelivered=true;deliverPendingOpenURLs();deliverPendingFinderService();return
            case .accepted:break
            }
        }
        // Empty/default workspace launch can present its native host first.
        // Repository CLI/tool reads wait without blocking the application loop.
        // Local image/Unified Diff inputs and typed repository-independent
        // utilities own their own admission; none needs unrelated Git grants.
        if !repositoryIndependentStartup && !startupArguments.isEmpty && !startupArguments.contains(FinderActionDelivery.argumentFlag) && startupArguments != ["--turtlegit-action-only"] {
            guard configurationReadsReady() else { return }
        }
        consumeDiagnostic();startupDelivered = true
        NativeCommandDiagnostics.trace("startup admitted",arguments:startupArguments,preferences:diagnosticPreferences)
        if startupArguments.contains(FinderActionDelivery.argumentFlag) {
            receivedExternalLaunchIntent = true
            if let delivery = FinderActionDelivery.parse(arguments: startupArguments) {
                if startupLaunchMode == .mergeTool || startupLaunchMode == .imageTool || startupLaunchMode == .unifiedDiff { workspaceOpenHandoff.submit([delivery.url]) }
                else { acceptFinderAction(delivery) }
            } else { pendingFinderServiceError = FinderActionLaunchFailure.invalid.localizedDescription }
            deliverPendingOpenURLs(); deliverPendingFinderService(); return
        }
        if let startupCommandHandler { startupCommandHandler(repositoryModel, startupArguments, startupDirectory) }
        else {
          if startupArguments == ["--turtlegit-action-only"] {deliverPendingOpenURLs();deliverPendingFinderService();return}
          if startupLaunchMode == .imageTool {
            startupMergeToolActive=repositoryModel.handleImageToolCommandLine(arguments:startupArguments,currentDirectory:startupDirectory,completion:{[weak self] status in self?.finishMergeToolStartup(status)})
            return
          }
          if startupLaunchMode == .unifiedDiff {
            // Unified Diff uses ordinary document Quit decisions. The Merge
            // flag instead drains MergeToolLaunchSession's accepted outputs.
            _ = repositoryModel.handleUnifiedDiffCommandLine(arguments: startupArguments, currentDirectory: startupDirectory, completion: { [weak self] status in self?.finishMergeToolStartup(status) })
            return
          }
          let mergeTool = repositoryModel.handleMergeToolCommandLine(arguments: startupArguments, currentDirectory: startupDirectory, completion: { [weak self, weak repositoryModel] status in
            guard let self else { return }
            self.finishMergeToolStartup(status)
          })
          startupMergeToolActive = mergeTool
          if !mergeTool { repositoryModel.handleCommandLine(arguments: startupArguments, currentDirectory: startupDirectory) }
        }
        deliverPendingOpenURLs(); deliverPendingFinderService()
    }
    private var confirmingQuit = false
    private var drainingUnifiedDiffQuit = false
    var replyToTermination: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    func applicationWillTerminate(_ notification: Notification) { retireCommandDiagnostics();gitConfigurationPreparation?.cancel(); gitConfigurationPreparation=nil; retireMenuImageVisibility(); retireFinderServices(); acceptingOpenURLs = false; retireInboundURLBridge(); presentWorkspace = nil; workspacePresentationRequested = false; workspaceOpenHandoff.retire(); pendingOpenURLs.removeAll(); finderActionReceipts.removeAll(); finderActionReceiptOrder.removeAll(); SupportReportService.shared.retire(); DockProgressPresenter.shared.clear(); for model in routingModels {model.stopMonitoringForTermination();model.finderWatches?.retire()};actionErrors=nil;actionReadiness=nil;actionErrorController?.close();actionErrorController=nil;queuedActionErrors.removeAll(); HistoricalPreviewFiles.discardAll(); RepositoryBrowserExportFiles.discardAll(); FileListDrag.discardAll(); UnifiedDiffPreviewFiles.discardAll(); GitConfigurationPreviewFiles.discardAll(); DiffToolApplication.discardAll(); MergeToolApplication.discardAll() }
    private func setTransferQuitConfirmation(_ sender: NSApplication, _ value: Bool) {
        for window in sender.windows {
            (window.delegate as? FileDropTransferWindowController)?.model.confirmingQuit = value
            (window.delegate as? FileMoveWindowController)?.model.confirmingQuit = value
            (window.delegate as? FileCopyWindowController)?.model.confirmingQuit = value
            (window.delegate as? ResolveWindowController)?.model.confirmingQuit = value
            (window.delegate as? AddProgressWindowController)?.model.confirmingQuit = value
            (window.delegate as? RevertProgressWindowController)?.model.confirmingQuit = value
            (window.delegate as? PresentationComparisonWindowController)?.model.confirmingQuit = value
            (window.delegate as? RevisionGraphWindowController)?.model.confirmingQuit = value
            (window.delegate as? StatisticsWindowController)?.model.confirmingQuit = value
            (window.delegate as? GitDaemonWindowController)?.model.confirmingQuit = value
            (window.delegate as? ReferenceLogWindowController)?.model.confirmingQuit = value
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision=terminationDecision(sender)
        if decision == .terminateNow {retireCommandDiagnostics()}
        return decision
    }
    private func terminationDecision(_ sender:NSApplication)->NSApplication.TerminateReply {
        // A scoped action Settings owner retains drafts just like the workspace
        // service. Refuse Quit and focus its existing owner until it is settled.
        for service in [SettingsPresentationService.shared,actionSettingsService].compactMap({$0}) {
            if !service.prepareContextChange() {return .terminateCancel}
        }
        if drainingUnifiedDiffQuit { return .terminateLater }
        if UnifiedDiffInputSession.activeOperations > 0 || PatchDocumentSession.activeStartupInputs > 0 {
            drainingUnifiedDiffQuit = true
            // Accept cancellation in this actor turn, before returning Later.
            // A ready producer must not publish success while the drain Task is
            // merely queued behind its continuation on the main executor.
            PatchDocumentSession.cancelAllStartupInputs()
            UnifiedDiffInputSession.cancelAll()
            Task { [self] in
                await UnifiedDiffInputSession.cancelAllAndWait()
                await PatchDocumentSession.waitForStartupInputs()
                drainingUnifiedDiffQuit = false
                let reply = applicationShouldTerminate(sender)
                if reply != .terminateLater { replyToTermination(sender, reply == .terminateNow) }
            }
            return .terminateLater
        }
        if (pendingFinderServiceRequest != nil || pendingOpenServiceSelection != nil),!(diagnosticKey?.hasPrefix("service") == true && commandDiagnosticController != nil) { return .terminateCancel }
        if MergeExternalReloadCoordinator.activeRequests > 0 { return .terminateCancel }
        if SettingsSheetController.activeSheets > 0 || workspaceOpenHandoff.hasPendingWork || RepositoryModel.activeCommandFileOperations > 0 || routingModels.contains(where:{$0.hasPendingRepositoryWork}) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RepositoryAccessWindowController }).contains(where:{ $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryModel.activeInaccessiblePreparations > 0 || InaccessibleRepositoryWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? InaccessibleRepositoryWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if MergeSourceExport.activeExports > 0 || sender.windows.compactMap({ $0.delegate as? TextConflictWindowController }).contains(where: { $0.model.sourceExporter.hasPendingWork }) { return .terminateCancel }
        if MergeEditorOpenWorkflow.activeSaves > 0 || sender.windows.contains(where: { ($0.delegate as? FileComparisonWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? FileComparisonWindowController)?.preparingReplacement == true || ($0.delegate as? TextConflictWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? TextConflictWindowController)?.preparingReplacement == true || ($0.delegate as? WorkingTreePatchWindowController)?.preparingReplacement == true }) { return .terminateCancel }
        if RevertWindowModel.activeOperations > 0 || sender.windows.compactMap({$0.delegate as? RevertWindowController}).contains(where:{$0.model.hasChild || $0.model.commands.busy || $0.window?.attachedSheet != nil}) { return .terminateCancel }
        if ImageComparisonViewModel.activeFileReads > 0 || ImageLoadWindowController.activeReleases > 0 { return .terminateCancel }
        if FinderFilesystemWorkflowRelease.activeRetirements > 0 || CleanProgressWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? CleanProgressWindowController }).contains(where: { $0.model.authorizing || $0.model.confirmingCancellation }) { return .terminateCancel }
        if sender.windows.contains(where:{ window in
            switch window.delegate {
            case let owner as WorktreeListWindowController:return owner.finderServiceWorkPending
            case let owner as WorktreeCreateWindowController:return owner.finderServiceWorkPending
            case let owner as SubmoduleAddWindowController:return owner.finderServiceWorkPending
            case let owner as SubmoduleAddProgressWindowController:return owner.finderServiceWorkPending
            case let owner as SubmoduleUpdateWindowController:return owner.finderServiceWorkPending
            case let owner as SubmoduleUpdateProgressWindowController:return owner.finderServiceWorkPending
            case let owner as SubmoduleSyncWindowController:return owner.finderServiceWorkPending
            case let owner as RenameWindowController:return owner.finderServiceWorkPending
            case let owner as RemoveWindowController:return owner.finderServiceWorkPending
            case let owner as CleanWindowController:return owner.finderServiceWorkPending
            case let owner as CleanProgressWindowController:return owner.finderServiceWorkPending
            default:return false
            }
        }) {return .terminateCancel}
        if CloneWindowModel.activeOperations > 0 || CloneProgressWindowModel.activeOperations > 0 || CreateRepositoryWindowModel.activeOperations > 0 { return .terminateCancel }
        if CloneWindowController.activeChildReleases > 0 || CreateRepositoryWindowController.activeReleases > 0 { return .terminateCancel }
        if BranchTagWindowController.activeReleases > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CreateRepositoryWindowController }).contains(where: { !$0.model.canClose || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if CommitWindowModel.activeIssueProviderOperations > 0 || IssueProviderPickerModel.activeOperations > 0 || IssueProviderCredentialEditorModel.activeReads > 0 || IssueProviderCredentialDrafts.activeOperations > 0 { return .terminateCancel }
        if RevertProgressWindowModel.activeOperations > 0 || RevertProgressWindowController.activeReleases > 0 || sender.windows.compactMap({$0.delegate as? RevertProgressWindowController}).contains(where:{$0.model.fileActionBusy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil}) { return .terminateCancel }
        if FileDropTransferModel.activePreparations > 0 || FileDropTransferWindowController.activeReleases > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FileDropTransferWindowController }).contains(where: { !$0.model.retired }) { return .terminateCancel }
        if ReferenceBrowserWindowModel.activeComparisons > 0 || ReferenceBrowserWindowController.activeChildReleases > 0 || RenameWindowModel.activeOperations > 0 || ReferenceBrowserWindowModel.activeMutations > 0 { return .terminateCancel }
        if RemoveWindowModel.activeOperations > 0 { return .terminateCancel }
        if RebaseWindowModel.activeReplayOperations > 0 { return .terminateCancel }
        if sender.windows.compactMap({$0.delegate as? RebaseWindowController}).contains(where:{$0.model.revisionHistoryBlocked || $0.model.containingReferenceBlocked || $0.model.revisionFindBlocked || $0.model.pendingConfirmation != nil || $0.model.hasReplayQuestion || $0.model.confirmingReplayCancellation || $0.window?.attachedSheet != nil}) {return .terminateCancel}
        if RebaseWindowModel.activePreparationReads > 0 || RebaseWindowController.activeReferencePickers > 0 || RebaseWindowController.activeCommitPickers > 0 { return .terminateCancel }
        if RebaseWindowModel.activeColumnReads > 0 { return .terminateCancel }
        if RebaseWindowModel.activeStashRestorations > 0 { return .terminateCancel }
        if SynchronizationProgressModel.activeOperations > 0 || SynchronizationWindowModel.activePushWorkflows > 0 || SynchronizationWindowModel.activeInlineOperations > 0 || SynchronizationWindowController.activeInlineReleases > 0 { return .terminateCancel }
        if LogWindowModel.activeActionReads > 0 || LogWindowModel.activeWorkingCommandReads > 0 { return .terminateCancel }
        if ReferenceLogWindowModel.activeRevisionReads > 0 || ReferenceLogWindowModel.activeOwnedOperations > 0 { return .terminateCancel }
        if WorktreeListWindowModel.activeOperations > 0 || WorktreeCreateWindowModel.activeOperations > 0 { return .terminateCancel }
        if PushWindowModel.activePreparationReads > 0 || PushWindowModel.activePushWorkflows > 0 || FetchWindowModel.activePreparationReads > 0 { return .terminateCancel }
        if sender.windows.compactMap({$0.delegate as? CloneProgressWindowController}).contains(where:{$0.model.fileActionBusy}) || sender.windows.compactMap({$0.delegate as? FetchProgressWindowController}).contains(where:{$0.model.fileActionBusy}) {return .terminateCancel}
        if FetchWindowModel.activeProgressOperations > 0 || FetchWindowController.activeProgressReleases > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ExportWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if StashSaveProgressWindowModel.activeOperations > 0 || ExportWindowModel.activeOperations > 0 || ExportWindowController.activeReleases > 0 || ExportProgressWindowModel.activeOperations > 0 || ExportProgressWindowController.activeReleases > 0 { return .terminateCancel }
        if MergeProgressWindowModel.activeOperations > 0 || MergeWindowController.activeChildReleases > 0 { return .terminateCancel }
        if SwitchProgressWindowModel.activeOperations > 0 || SwitchWindowController.activeChildReleases > 0 || ResetProgressWindowModel.activeOperations > 0 || ResetWindowController.activeChildReleases > 0 || BisectWindowController.activeChildReleases > 0 { return .terminateCancel }
        if StatisticsWindowModel.activeOperations > 0 || StatisticsWindowController.activeExports > 0 || sender.windows.compactMap({ $0.delegate as? StatisticsWindowController }).contains(where: { $0.hasPendingWork || $0.model.hasSheet || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RevisionGraphFindController.activeOperations > 0 || CommitContainingReferencesWindowController.activeOperations > 0 || RevisionGraphWindowModel.activeOperations > 0 || RevisionGraphFilterController.activeOperations > 0 { return .terminateCancel }
        if FileCopyWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileCopyWindowController }).contains(where: { $0.model.question || $0.model.confirmingCancel }) { return .terminateCancel }
        if FileMoveWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileMoveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.choosingFolder || $0.model.confirmingCancellation }) { return .terminateCancel }
        if ConflictReviewOperation.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? DeleteConflictWindowController }).contains(where: { !$0.model.operation.canClose }) || sender.windows.compactMap({ $0.delegate as? SubmoduleConflictWindowController }).contains(where: { $0.hasPendingWork || !$0.model.operation.canClose }) { return .terminateCancel }
        if ResolveWindowModel.activeOperations > 0 || ResolveWindowController.activeReleases > 0 || sender.windows.compactMap({ $0.delegate as? ResolveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.hasChild || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if IgnoreWindowModel.activeOperations > 0 { return .terminateCancel }
        if LogMessageView.Coordinator.activeOperations > 0 { return .terminateCancel }
        if AddWindowModel.activeOperations > 0 || AddProgressWindowModel.activeOperations > 0 || AddProgressWindowController.activeReleases > 0 { return .terminateCancel }
        if CommitWindowModel.activeCommitPreflights > 0 { return .terminateCancel }
        if CommitWindowModel.activeReloads > 0 || CommitWindowModel.activeFileOperations > 0 || CommitWindowModel.activePreferenceOperations > 0 || CommitWindowModel.activeMetadataOperations > 0 { return .terminateCancel }
        if CommitWindowModel.activeFileDrops > 0 { return .terminateCancel }
        if LogWindowModel.activeNoteReads > 0 || LogWindowModel.activeNoteSaves > 0 || CommitNotePresenter.activeWarnings > 0 { return .terminateCancel }
        if LogRevisionColumnQuestion.activeCount > 0 { return .terminateCancel }
        if MessageEditorStylingSession.activeOperations > 0 { return .terminateCancel }
        if InputWindowController.activeSaves > 0 { return .terminateCancel }
        if AddRemoteWindowModel.activeOperations > 0 || RemoteReferenceWindowModel.activeOperations > 0 || RemoteTagWindowModel.activeOperations > 0 { return .terminateCancel }
        if BisectWindowModel.activeOperations > 0 { return .terminateCancel }
        if GitPropertiesWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? GitPropertiesWindowController }).contains(where:{ $0.model.busy || $0.model.hasSettings || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserWindowModel.activeOperations > 0 || RepositoryBrowserFileOperation.activeRequests > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BlameWindowController }).contains(where:{ $0.model.busy || $0.model.openingDocument || $0.model.searchFeedbackBusy || $0.hasBlockingHistoryChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if BlameDocumentOpener.activeReads > 0 { return .terminateCancel }
        if BlameWindowModel.activeHistoryOperations > 0 { return .terminateCancel }
        if BlameWindowModel.activeSyntaxRequests > 0 { return .terminateCancel }
        if MergeRegexFilterListController.activeEditors > 0 { return .terminateCancel }
        if ReleaseUpdateModel.activeOperations > 0 { return .terminateCancel }
        if MergeRegexOperations.activeRequests > 0 { return .terminateCancel }
        if TurtleGitAboutController.activeReads > 0 {return .terminateCancel}
        if SupportReportService.activeScans > 0 { return .terminateCancel }
        if SupportReportWindowModel.activeReads > 0 || SupportReportWindowModel.activeWrites > 0 || SupportReportWindowController.activePickers > 0 { return .terminateCancel }
        if SVNWindowModel.activeOperations > 0 { return .terminateCancel }
        if SendPatchWindowModel.activeLoads > 0 || SendPatchWindowController.activeTargetReads > 0 {return .terminateCancel}
        if SendPatchProgressModel.activeSubmissions > 0 || SendPatchProgressWindowController.activeReleases > 0 {return .terminateCancel}
        if ImportPatchWindowModel.activeWorkers > 0 || ImportPatchWindowController.activeReleases > 0 {return .terminateCancel}
        if ReviewPatchWorkflow.activeLoads > 0 { return .terminateCancel }
        if SendPatchWindowController.activeReleases > 0 || ReviewPatchWorkflow.activeReleases > 0 || WorkingTreePatchWindowController.activeReleases > 0 { return .terminateCancel }
        if ImageConflictWindowModel.activeOperations > 0 { return .terminateCancel }
        if FileListComparisonSession.activeOperations > 0 { return .terminateCancel }
        if RevisionComparisonWindowModel.activeFileOperations > 0 { return .terminateCancel }
        if LogWindowModel.activeReferenceReads > 0 || LogWindowController.activeReferencePickers > 0 || ReferenceBrowserWindowModel.activeReads > 0 { return .terminateCancel }
        if LogWindowModel.activeFileOpenReads > 0 || LogWindowModel.activeFileNavigationActivities > 0 || LogDocumentOpenSession.activeRequests > 0 || LogWindowModel.activeHistoryLoads > 0 || LogWindowModel.activeHistoryProjectionWorkers > 0 || LogWindowModel.activeFilterValidations > 0 { return .terminateCancel }
        if ExportWindowModel.activeReads > 0 || BranchTagWindowModel.activeReads > 0 || BranchTagWindowModel.activeCreations > 0 || MergeWindowModel.activeReads > 0 || ResetWindowModel.activeReads > 0 || SwitchWindowModel.activeReads > 0 || SubmoduleUpdateWindowModel.activeReads > 0 || SubmoduleWorkingLogSession.activeReads > 0 || SubmoduleUpdateProgressWindowModel.activeOperations > 0 || SubmoduleDiffWindowModel.activeReads > 0 || SubmoduleDiffWindowController.activeReleases > 0 { return .terminateCancel }
        if RequestPullWindowModel.activeOperations > 0 || RequestPullWindowController.activeReleases > 0 || sender.windows.compactMap({ $0.delegate as? RequestPullWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if FormatPatchWindowModel.activeOperations > 0 || FormatPatchWindowController.activeReleases > 0 { return .terminateCancel }
        if RebaseCompletionMailWindowModel.activeOperations > 0 || RebaseCompletionMailWindowController.activeReleases > 0 { return .terminateCancel }
        if LocalGitCommandProgress.activeOperations > 0 { return .terminateCancel }
        if StatusWindowModel.activeOperations > 0 { return .terminateCancel }
        if MissingStagedFileRecoverySession.activeRequests > 0 { return .terminateCancel }
        if WorkingTreePatchWindowModel.activeOperations > 0 || FileComparisonWindowModel.activePaneExports > 0 || FileComparisonWindowModel.activeProjectionChoices > 0 { return .terminateCancel }
        if RevisionGraphWindowController.activeRetirements>0 || sender.windows.contains(where:{ window in
            if let controller=window.delegate as? GitDaemonWindowController {return controller.hasPendingWork}
            if let controller=window.delegate as? ReferenceLogWindowController {return controller.hasPendingWork}
            if let controller=window.delegate as? ReferenceBrowserWindowController {return controller.hasPendingWork}
            if let controller=window.delegate as? RepositoryBrowserWindowController {return controller.hasPendingWork}
            return false
        }) {return .terminateCancel}
        if GitDaemonWindowModel.activeOperations > 0 || GitDaemonWindowModel.activeQuestions > 0 { return .terminateCancel }
        if FirstStartWizardModel.activeWrites > 0 || GeneralGitSettingsModel.activeOperations > 0 || GeneralGitSettingsModel.activeDialogs > 0 { return .terminateCancel }
        if GitConfigurationSettingsModel.activeFolderChoosers > 0 {return .terminateCancel}
        if GitConfigurationSettingsModel.activeSheetReleases > 0 || CredentialSettingsModel.activeSheetReleases > 0 || NetworkSettingsModel.activeSheetReleases > 0 || HookSettingsModel.activeReads > 0 || HookConfigurationController.activeReleases > 0 || HookConfigurationController.activeChoosers > 0 || RemoteSettingsWindowModel.activeRetirements > 0 || SettingsTransaction.activeRetirements > 0 {return .terminateCancel}
        if MergeFormatPrompt.activeDialogs > 0 { return .terminateCancel }
        if MergeEditorSettingsModel.activeProfileEditors > 0 { return .terminateCancel }
        if MergeNavigationRequests.activeRequests > 0 { return .terminateCancel }
        if MergeOpenWindowController.activeChoices > 0 { return .terminateCancel }
        if ToolApplicationChooser.activeChoosers > 0 {return .terminateCancel}
        if CredentialSettingsModel.activeSaves > 0 || CredentialSettingsModel.activeReads > 0 || CredentialSettingsModel.activeSelections > 0 { return .terminateCancel }
        if SSHKeyImportModel.activeOperations > 0 { return .terminateCancel }
        if SSHKeyGenerationModel.activeOperations > 0 { return .terminateCancel }
        if SSHIdentityPermissionsModel.activeOperations > 0 { return .terminateCancel }
        if SavedDataSettingsModel.activeCacheClears > 0 || SavedSSHAuthenticationModel.activeOperations > 0 { return .terminateCancel }
        if SSHTransportCoordinator.activeOperations > 0 { return .terminateCancel }
        if NetworkSettingsModel.activeSaves > 0 || NetworkSettingsModel.activeReads > 0 || NetworkSettingsModel.activeSSHChoosers > 0 { return .terminateCancel }
        if EmailSettingsModel.activeOperations > 0 || EmailSettingsModel.activeCredentialEditors > 0 { return .terminateCancel }
        if LFSLocksWindowModel.activeOperations > 0 { return .terminateCancel }
        if StashRestoreWindowModel.activeOperations > 0 || StashWindowModel.activePreparations > 0 || StashWindowController.activeChildReleases > 0 { return .terminateCancel }
        if SubmoduleAddProgressWindowModel.activeOperations > 0 || SubmoduleSyncWindowModel.activeOperations > 0 || SubmoduleUpdateProgressWindowController.activeChildReleases > 0 { return .terminateCancel }
        if ClientHookProcessPool.shared.activeScripts > 0 || ClientHookSession.activeOperations > 0 || ClientHookSession.activeQuestionReleases > 0 { return .terminateCancel }
        if HookSettingsModel.activeSaves > 0 { return .terminateCancel }
        if AutotextTesterModel.activeRequests > 0 { return .terminateCancel }
        if IssueRegexTesterModel.activeRequests > 0 { return .terminateCancel }
        if ProjectDialogSettingsModel.activeSaves > 0 || ProjectDialogSettingsModel.activeReads > 0 || GitConfigurationSettingsModel.activeReads > 0 || IssueTrackerSettingsModel.activeReads > 0 { return .terminateCancel }
        if IssueTrackerSettingsModel.activeSaves > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SynchronizationWindowController }).contains(where: { $0.model.busy || $0.model.hasBlockingChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RevisionGraphWindowController.activeExportOperations > 0 || sender.windows.compactMap({ $0.delegate as? RevisionGraphWindowController }).contains(where: { $0.hasPendingWork || $0.hasExportSheet || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeAbortWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeAbortProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if confirmingQuit { return .terminateLater }
        if sender.windows.compactMap({ $0.delegate as? MergeOpenWindowController }).contains(where: { $0.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImageLoadWindowController }).contains(where: { !$0.retired }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CommitWindowController }).contains(where: { $0.hasMessagePicker || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImageConflictWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if ImageSelectionWindowModel.activeOperations > 0 || sender.windows.compactMap({$0.delegate as? ImageSelectionWindowController}).contains(where:{$0.model.hasPendingWork || $0.model.busy || $0.window?.attachedSheet != nil}) {return .terminateCancel}
        if sender.windows.compactMap({ $0.delegate as? RemoteSettingsWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({$0.delegate as? AddRemoteWindowController}).contains(where:{$0.model.error != nil || $0.window?.attachedSheet != nil}) || sender.windows.compactMap({$0.delegate as? RemoteReferenceWindowController}).contains(where:{$0.model.error != nil || $0.window?.attachedSheet != nil}) {return .terminateCancel}
        if sender.windows.compactMap({ $0.delegate as? RemoteTagWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserExportFiles.activeLoads > 0 || FileListDrag.activeLoads > 0 { return .terminateCancel }
        if PresentationComparisonWindowModel.activeRequests > 0 || sender.windows.compactMap({$0.delegate as? PresentationComparisonWindowController}).contains(where:{$0.window?.attachedSheet != nil}) {return .terminateCancel}
        if AlternativeEditor.activeRequests > 0 || ExternalDocumentApplication.activeRequests > 0 || ExternalToolProcesses.activeRequests > 0 || UnifiedDiffApplication.activeRequests > 0 || DiffToolApplication.activeRequests > 0 || MergeToolApplication.activeRequests > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneWindowController }).contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PushWindowController }).contains(where: { $0.model.busy || $0.model.preparing || $0.model.choosingReference || $0.model.managingRemotes || $0.model.confirmation != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FetchWindowController }).contains(where: { $0.model.operationActive || $0.model.browsing || $0.model.managing || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PullProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingConflictHint || $0.model.confirmingResultClose || $0.model.pendingOperations>0 || $0.model.dispatchingAction || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FetchProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingRebaseDecision || $0.model.dispatchingAction || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeWindowController }).contains(where: { $0.model.busy || $0.model.progress != nil || $0.model.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingConflictHint || $0.model.confirmingDeletion || $0.model.checkingDismissal || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchWindowController }).contains(where: { $0.model.busy || $0.model.progress != nil || $0.model.hasPendingTagConflict || $0.model.browser != nil || $0.model.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.confirmingHard || $0.model.progress != nil || $0.model.showingModifiedFiles || $0.model.showingCommitPicker || $0.model.showingReferencePicker || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetProgressWindowController }).contains(where: { $0.model.busy || $0.model.hasPendingWork || $0.model.fileActionBusy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ReferenceBrowserWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.renameReference != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BranchTagWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.model.hasPendingNameConflict || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashWindowController }).contains(where: { $0.model.busy || $0.model.preparing || $0.model.hasIdentitySettings || $0.model.confirmingUntracked || $0.model.progress != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashSaveProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashRestoreWindowController }).contains(where: { $0.model.busy || $0.model.prompt != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if PatchDocumentSession.activeOperations != 0 { return .terminateCancel }
        if PatchWindowModel.activeOperations != 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PatchWindowController }).contains(where: { !$0.model.retired && ($0.model.busy || $0.window?.attachedSheet != nil) }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LogWindowController }).contains(where: { $0.model.busy || $0.model.orderingBlocked || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StatusWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        // A forced owner close can remove the window before its Git child has
        // stopped. Keep termination fenced until that child or atomic save ends.
        if HistoryCombineSelectionReader.activeReads > 0 || HistoryCombineWindowModel.activeOperations > 0 || HistoryRevertWindowModel.activeOperations > 0 ||
            HistoryNotesWindowModel.activeMutations > 0 || HistoryNotesWindowModel.activeReads > 0 || SynchronizationWindowModel.activeHistoryDeletions > 0 ||
            LogWindowModel.activeHistoryDeletions > 0 || GitConfigurationSettingsModel.activeSaves > 0 ||
            RemoteSettingsWindowModel.activeOperations > 0 || SettingsTransaction.activeApplications > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? HistoryNotesWindowController }).contains(where: { $0.model.loading || $0.model.saving || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? HistoryRevertWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BisectWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ExportWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorkingTreePatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImportPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FormatPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RebaseCompletionMailWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeCreateWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.contains(where: { $0.delegate is LFSFileOperationController }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LFSLocksWindowController }).contains(where: { $0.model.busy || $0.model.showingProgress || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeListWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CommitContainingReferencesWindowController }).contains(where: { $0.busy || $0.hasBlockingChild }) { return .terminateCancel }
        // NSApplication can retain closed windows. Retired document owners are
        // not unsaved participants and must never be made visible by Quit.
        // Process/release counters above still fence their draining workers.
        let reviews = sender.windows.compactMap { $0.delegate as? WorkingTreePatchWindowController }.filter { $0.canReuse }
        let presentations = sender.windows.compactMap { $0.delegate as? PresentationComparisonWindowController }.filter { !$0.model.retired }
        let imports = sender.windows.compactMap { $0.delegate as? ImportPatchWindowController }.filter { $0.canReuse }
        let controllers = sender.windows.compactMap { $0.delegate as? TextConflictWindowController }.filter { !$0.model.retired }
        let commits = sender.windows.compactMap { $0.delegate as? CommitWindowController }.filter { $0.canReuse }
        let adds = sender.windows.compactMap { $0.delegate as? AddWindowController }
        let lfsLocks = sender.windows.compactMap { $0.delegate as? LFSLocksWindowController }
        let statuses = sender.windows.compactMap { $0.delegate as? StatusWindowController }
        let historyReplays = sender.windows.compactMap { $0.delegate as? RebaseWindowController }
        let referenceBrowsers = sender.windows.compactMap { $0.delegate as? ReferenceBrowserWindowController }
        let blames = sender.windows.compactMap { $0.delegate as? BlameWindowController }
        let logs = sender.windows.compactMap { $0.delegate as? LogWindowController }
        let pushes = sender.windows.compactMap { $0.delegate as? PushWindowController }
        let fetches = sender.windows.compactMap { $0.delegate as? FetchWindowController }
        let pullsInProgress = sender.windows.compactMap { $0.delegate as? PullProgressWindowController }
        let fetchesInProgress = sender.windows.compactMap { $0.delegate as? FetchProgressWindowController }
        let merges = sender.windows.compactMap { $0.delegate as? MergeWindowController }
        let mergesInProgress = sender.windows.compactMap { $0.delegate as? MergeProgressWindowController }
        let referenceCreations = sender.windows.compactMap { $0.delegate as? BranchTagWindowController }
        let clones = sender.windows.compactMap { $0.delegate as? CloneWindowController }
        let clonesInProgress = sender.windows.compactMap { $0.delegate as? CloneProgressWindowController }
        let creations = sender.windows.compactMap { $0.delegate as? CreateRepositoryWindowController }
        let requestPulls = sender.windows.compactMap { $0.delegate as? RequestPullWindowController }
        let inaccessibleDiagnostics = sender.windows.compactMap { $0.delegate as? InaccessibleRepositoryWindowController }
        let mailProgresses = sender.windows.compactMap { $0.delegate as? SendPatchProgressWindowController }
        let formatPatches = sender.windows.compactMap { $0.delegate as? FormatPatchWindowController }
        let rebaseCompletionMails = sender.windows.compactMap { $0.delegate as? RebaseCompletionMailWindowController }
        let exports = sender.windows.compactMap { $0.delegate as? ExportWindowController }
        let exportsInProgress = sender.windows.compactMap { $0.delegate as? ExportProgressWindowController }
        let stashSaves = sender.windows.compactMap { $0.delegate as? StashWindowController }
        let stashProgress = sender.windows.compactMap { $0.delegate as? StashSaveProgressWindowController }
        let stashRestores = sender.windows.compactMap { $0.delegate as? StashRestoreWindowController }
        let switches = sender.windows.compactMap { $0.delegate as? SwitchWindowController }
        let switchProgress = sender.windows.compactMap { $0.delegate as? SwitchProgressWindowController }
        let resets = sender.windows.compactMap { $0.delegate as? ResetWindowController }
        let resetProgress = sender.windows.compactMap { $0.delegate as? ResetProgressWindowController }
        let bisects = sender.windows.compactMap { $0.delegate as? BisectWindowController }
        let addProgress = sender.windows.compactMap { $0.delegate as? AddProgressWindowController }
        let reverts = sender.windows.compactMap { $0.delegate as? RevertWindowController }
        let browsers = sender.windows.compactMap { $0.delegate as? RepositoryBrowserWindowController }
        let synchronizations = sender.windows.compactMap { $0.delegate as? SynchronizationWindowController }
        let submoduleSyncs = sender.windows.compactMap { $0.delegate as? SubmoduleSyncWindowController }
        if submoduleSyncs.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let submoduleAdds = sender.windows.compactMap { $0.delegate as? SubmoduleAddWindowController }
        if submoduleAdds.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let submoduleAddProgress = sender.windows.compactMap { $0.delegate as? SubmoduleAddProgressWindowController }
        if submoduleAddProgress.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let updateProgress = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateProgressWindowController }
        if updateProgress.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let updates = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateWindowController }
        let submoduleDiffs = sender.windows.compactMap { $0.delegate as? SubmoduleDiffWindowController }
        let submoduleConflicts = sender.windows.compactMap { $0.delegate as? SubmoduleConflictWindowController }
        let patchDocuments = sender.windows.compactMap { $0.delegate as? PatchWindowController }.filter { !$0.model.retired && $0.documentSession.enabled }
        let comparisons = sender.windows.compactMap { $0.delegate as? RevisionComparisonWindowController }
        let fileComparisons = sender.windows.compactMap { $0.delegate as? FileComparisonWindowController }.filter { $0.model.copyCommandsAllowed }
        let progress = sender.windows.compactMap { $0.delegate as? RevertProgressWindowController }
        guard !adds.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !addProgress.contains(where: { $0.model.busy }), !browsers.contains(where: { $0.model.mutating }), !fileComparisons.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !submoduleDiffs.contains(where: { $0.hasPendingWork || $0.model.busy || $0.model.hasUpdateChild }), !comparisons.contains(where: { $0.model.busy || $0.model.patchWindow?.model.busy == true || $0.model.unifiedWindows.values.contains(where: { $0.model.busy }) }), !updates.contains(where: { $0.model.busy }), !progress.contains(where: { $0.model.busy }), !reverts.contains(where: { $0.model.busy }), !commits.contains(where: { $0.model.busy }), !routingModels.contains(where:{$0.busy}), !controllers.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) else { return .terminateCancel }
        guard patchDocuments.contains(where: { $0.documentSession.dirty }) || !imports.isEmpty || !commits.isEmpty || controllers.contains(where: { $0.model.hasUnsavedEditorWork }) || fileComparisons.contains(where: { $0.model.dirty }) || reviews.contains(where: { $0.model.dirty }) || presentations.contains(where: { $0.model.revision.isDirty }) else { return finishBackgroundWatches(sender) }
        confirmingQuit = true
        for controller in patchDocuments { controller.model.confirmingQuit = true }
        for controller in lfsLocks { controller.model.confirmingQuit = true }
        for controller in statuses { controller.model.confirmingQuit = true }
        for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = true }
        for controller in referenceBrowsers { controller.model.confirmingQuit = true }
        for controller in blames { controller.model.confirmingQuit = true }
        for controller in logs { controller.model.confirmingQuit = true }
        for controller in pushes { controller.model.confirmingQuit = true }
        for controller in fetches { controller.model.confirmingQuit = true }
        for controller in pullsInProgress { controller.model.confirmingQuit = true }
        for controller in fetchesInProgress { controller.model.confirmingQuit = true }
        for controller in merges { controller.model.confirmingQuit = true }
        for controller in mergesInProgress { controller.model.confirmingQuit = true }
        for controller in referenceCreations { controller.model.confirmingQuit = true }
        for controller in clones { controller.model.confirmingQuit = true }
        for controller in clonesInProgress { controller.model.confirmingQuit = true }
        for controller in creations { controller.model.confirmingQuit = true }
        for controller in requestPulls { controller.model.confirmingQuit = true }
        for controller in mailProgresses { controller.model.confirmingQuit = true }
        for controller in formatPatches { controller.model.confirmingQuit = true }
        for controller in rebaseCompletionMails { controller.confirmingQuit = true }
        for controller in exports { controller.model.confirmingQuit = true }
        for controller in exportsInProgress { controller.model.confirmingQuit = true }
        for controller in stashSaves { controller.model.confirmingQuit = true }
        for controller in stashProgress { controller.model.confirmingQuit = true }
        for controller in stashRestores { controller.model.confirmingQuit = true }
        for controller in switches { controller.model.confirmingQuit = true }
        for controller in switchProgress { controller.model.confirmingQuit = true }
        for controller in resets { controller.model.confirmingQuit = true }
        for controller in resetProgress { controller.model.confirmingQuit = true }
        for controller in bisects { controller.model.confirmingQuit = true }
        for controller in imports { controller.setQuitConfirmation(true) }
        for controller in reviews { controller.setQuitConfirmation(true) }
        for controller in inaccessibleDiagnostics { controller.model.confirmingQuit = true }
        setTransferQuitConfirmation(sender, true); setRoutingQuitConfirmation(true)
        for browser in browsers { browser.model.confirmingQuit = true }
        for comparison in fileComparisons { comparison.model.confirmingQuit = true }
        for diff in submoduleDiffs { diff.model.confirmingQuit = true }
        for conflict in submoduleConflicts { conflict.model.confirmingQuit = true }
        for comparison in comparisons { comparison.model.confirmingQuit = true; comparison.model.patchWindow?.model.confirmingQuit = true; for viewer in comparison.model.unifiedWindows.values { viewer.model.confirmingQuit = true } }
        for update in updates { update.model.confirmingQuit = true }
        for update in updateProgress { update.model.confirmingQuit = true }
        for add in submoduleAdds { add.model.confirmingQuit = true }
        for add in submoduleAddProgress { add.model.confirmingQuit = true }
        for sync in submoduleSyncs { sync.model.confirmingQuit = true }
        for sync in synchronizations { sync.model.confirmingQuit = true }
        for add in adds { add.model.confirmingQuit = true }; for add in addProgress { add.model.confirmingQuit = true }
        for revert in reverts { revert.model.confirmingQuit = true }
        for commit in commits { commit.setQuitConfirmation(true) }
        for controller in controllers { controller.model.confirmingQuit = true }
        Task {
            var allowQuit = true
            for controller in patchDocuments where !controller.model.retired && controller.documentSession.dirty {
                if !(await controller.documentSession.resolveChanges()) { allowQuit = false; break }
            }
            for controller in reviews where allowQuit && controller.canReuse && controller.model.dirty {
                if !(await controller.model.resolveDraft(discardImmediately: false)) { allowQuit = false; break }
            }
            for controller in presentations where allowQuit && !controller.model.retired && controller.model.revision.isDirty {
                if !(await controller.confirmQuit()) {allowQuit=false;break}
            }
            for controller in fileComparisons where allowQuit && controller.model.copyCommandsAllowed && controller.model.dirty {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.unsavedFilesDescription)” before quitting?"
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let saved = await withCheckedContinuation { continuation in controller.model.saveAllForQuit { continuation.resume(returning: $0) } }
                    if !saved { allowQuit = false }
                case .alertSecondButtonReturn: break
                default: allowQuit = false
                }
                if !allowQuit { break }
            }
            for controller in controllers where allowQuit && !controller.model.retired && controller.model.hasUnsavedEditorWork {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.path)” before quitting?"
                if controller.model.hasKeptSourceChanges { alert.informativeText = String(localized:"Save copies of the retained source panes before saving the merged result.") }
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let saved = await withCheckedContinuation { continuation in
                        controller.model.saveForQuit { continuation.resume(returning: $0) }
                    }
                    if !saved { allowQuit = false }
                case .alertSecondButtonReturn: break
                default: allowQuit = false
                }
                if !allowQuit { break }
            }
            if allowQuit {
                for commit in commits where commit.canReuse {
                    commit.window?.makeKeyAndOrderFront(nil)
                    let approved = await withCheckedContinuation { continuation in
                        commit.model.cancel(closeWindow: false) { continuation.resume(returning: $0) }
                    }
                    if !approved { allowQuit = false; break }
                }
            }
            if allowQuit {
                for controller in imports where controller.canReuse {
                    if !(await controller.model.confirmQuit()) { allowQuit = false; break }
                }
            }
            if allowQuit { for commit in commits { commit.model.restoreCopies.removeAll() };for presentation in presentations {presentation.discardAfterApprovedQuit()} }
            if allowQuit, startupMergeToolActive { repositoryModel?.closeMergeToolLaunchesAfterApprovedQuit(); return }
            if allowQuit {await shutdownRoutingModels()}
            for browser in browsers { browser.model.confirmingQuit = false }
            for diff in submoduleDiffs { diff.model.confirmingQuit = false }
            for conflict in submoduleConflicts { conflict.model.confirmingQuit = false }
            for comparison in fileComparisons { comparison.model.confirmingQuit = false }
            for comparison in comparisons { comparison.model.confirmingQuit = false; comparison.model.patchWindow?.model.confirmingQuit = false; for viewer in comparison.model.unifiedWindows.values { viewer.model.confirmingQuit = false } }
            for update in updates { update.model.confirmingQuit = false }
            for update in updateProgress { update.model.confirmingQuit = false }
            for add in submoduleAdds { add.model.confirmingQuit = false }
            for add in submoduleAddProgress { add.model.confirmingQuit = false }
            for sync in submoduleSyncs { sync.model.confirmingQuit = false }
            for sync in synchronizations { sync.model.confirmingQuit = false }
            for add in adds { add.model.confirmingQuit = false }; for add in addProgress { add.model.confirmingQuit = false }
            for revert in reverts { revert.model.confirmingQuit = false }
            for commit in commits { commit.setQuitConfirmation(false) }
            for controller in inaccessibleDiagnostics { controller.model.confirmingQuit = false }
            setTransferQuitConfirmation(sender, false); setRoutingQuitConfirmation(false)
            for controller in controllers { controller.model.confirmingQuit = false }
            for controller in imports { controller.setQuitConfirmation(false) }
            for controller in reviews { controller.setQuitConfirmation(false) }
            for controller in patchDocuments { controller.model.confirmingQuit = false }
            for controller in lfsLocks { controller.model.confirmingQuit = false }
            for controller in statuses { controller.model.confirmingQuit = false }
            for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = false }
            for controller in referenceBrowsers { controller.model.confirmingQuit = false }
            for controller in blames { controller.model.confirmingQuit = false }
            for controller in logs { controller.model.confirmingQuit = false }
            for controller in pushes { controller.model.confirmingQuit = false }
            for controller in fetches { controller.model.confirmingQuit = false }
            for controller in pullsInProgress { controller.model.confirmingQuit = false }
            for controller in fetchesInProgress { controller.model.confirmingQuit = false }
            for controller in merges { controller.model.confirmingQuit = false }
            for controller in mergesInProgress { controller.model.confirmingQuit = false }
            for controller in referenceCreations { controller.model.confirmingQuit = false }
            for controller in clones { controller.model.confirmingQuit = false }
            for controller in clonesInProgress { controller.model.confirmingQuit = false }
            for controller in creations { controller.model.confirmingQuit = false }
            for controller in requestPulls { controller.model.confirmingQuit = false }
            for controller in mailProgresses { controller.model.confirmingQuit = false }
            for controller in formatPatches { controller.model.confirmingQuit = false }
            for controller in rebaseCompletionMails { controller.confirmingQuit = false }
            for controller in exports { controller.model.confirmingQuit = false }
            for controller in exportsInProgress { controller.model.confirmingQuit = false }
            for controller in stashSaves { controller.model.confirmingQuit = false }
            for controller in stashProgress { controller.model.confirmingQuit = false }
            for controller in stashRestores { controller.model.confirmingQuit = false }
            for controller in switches { controller.model.confirmingQuit = false }
            for controller in switchProgress { controller.model.confirmingQuit = false }
            for controller in resets { controller.model.confirmingQuit = false }
            for controller in resetProgress { controller.model.confirmingQuit = false }
            for controller in bisects { controller.model.confirmingQuit = false }
            if allowQuit {retireCommandDiagnostics()}
            confirmingQuit = false
            if allowQuit,finishDedicatedUnifiedDiffAfterApprovedQuit(){return}
            replyToTermination(sender, allowQuit)
            if !allowQuit {
                // Configuration/authority readiness can arrive while the owned
                // Quit question suppresses routing. Refusing Quit restores that
                // queue after every owner's confirmation flag has been cleared.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.acceptingOpenURLs, !self.confirmingQuit else { return }
                    self.deliverStartupCommand()
                    self.deliverPendingOpenURLs()
                    self.deliverPendingFinderService()
                    self.deliverWorkspaceRepositoryChoice()
                    self.finishPendingDefaultWorkspaceLaunch()
                }
            }
        }
        return .terminateLater
    }
    private func finishDedicatedUnifiedDiffAfterApprovedQuit()->Bool {
        guard startupLaunchMode == .unifiedDiff,
              (try? UnifiedDiffInvocation.parse(arguments:startupArguments,currentDirectory:startupDirectory))?.isStandaloneTool == true else{return false}
        repositoryModel?.completeStandaloneUnifiedDiffForTermination()
        // Completion now also awaits this owner's post-load document/Apply
        // work. Its callback will enter the existing handoff/exit drain later.
        return true
    }
    private func finishBackgroundWatches(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if finishDedicatedUnifiedDiffAfterApprovedQuit(){return .terminateLater}
        if startupMergeToolActive {
            confirmingQuit = true; repositoryModel?.closeMergeToolLaunchesAfterApprovedQuit(); return .terminateLater
        }
        for model in routingModels {model.stopMonitoringForTermination()}
        var managers:[FinderWatchManager]=[]
        for model in routingModels {if let manager=model.finderWatches,!managers.contains(where:{$0 === manager}) {managers.append(manager)}}
        let pending=managers.reduce(0) {$0+$1.pendingOperations+($1.backgroundService?.busy == true ? 1:0)}
        for manager in managers {manager.retire()}
        // A live foreground writer must be retired before process exit even if
        // its last scan finished and no watched-root operation remains.
        guard pending>0 || routingModels.contains(where:{$0.hasPendingFinderPublication || $0.finderWatches?.hasPendingFinderPublication == true || ($0.finderWatches?.pendingOperations ?? 0)>0}) else { return .terminateNow }
        confirmingQuit=true
        let historyReplays = sender.windows.compactMap { $0.delegate as? RebaseWindowController }
        let referenceBrowsers = sender.windows.compactMap { $0.delegate as? ReferenceBrowserWindowController }
        let blames = sender.windows.compactMap { $0.delegate as? BlameWindowController }
        let logs = sender.windows.compactMap { $0.delegate as? LogWindowController }
        let pushes = sender.windows.compactMap { $0.delegate as? PushWindowController }
        let fetches = sender.windows.compactMap { $0.delegate as? FetchWindowController }
        let pullsInProgress = sender.windows.compactMap { $0.delegate as? PullProgressWindowController }
        let fetchesInProgress = sender.windows.compactMap { $0.delegate as? FetchProgressWindowController }
        let merges = sender.windows.compactMap { $0.delegate as? MergeWindowController }
        let mergesInProgress = sender.windows.compactMap { $0.delegate as? MergeProgressWindowController }
        let referenceCreations = sender.windows.compactMap { $0.delegate as? BranchTagWindowController }
        let clones = sender.windows.compactMap { $0.delegate as? CloneWindowController }
        let clonesInProgress = sender.windows.compactMap { $0.delegate as? CloneProgressWindowController }
        let creations = sender.windows.compactMap { $0.delegate as? CreateRepositoryWindowController }
        let requestPulls = sender.windows.compactMap { $0.delegate as? RequestPullWindowController }
        let inaccessibleDiagnostics = sender.windows.compactMap { $0.delegate as? InaccessibleRepositoryWindowController }
        let mailProgresses = sender.windows.compactMap { $0.delegate as? SendPatchProgressWindowController }
        let formatPatches = sender.windows.compactMap { $0.delegate as? FormatPatchWindowController }
        let rebaseCompletionMails = sender.windows.compactMap { $0.delegate as? RebaseCompletionMailWindowController }
        let exports = sender.windows.compactMap { $0.delegate as? ExportWindowController }
        let exportsInProgress = sender.windows.compactMap { $0.delegate as? ExportProgressWindowController }
        let stashSaves = sender.windows.compactMap { $0.delegate as? StashWindowController }
        let stashProgress = sender.windows.compactMap { $0.delegate as? StashSaveProgressWindowController }
        let stashRestores = sender.windows.compactMap { $0.delegate as? StashRestoreWindowController }
        let switches = sender.windows.compactMap { $0.delegate as? SwitchWindowController }
        let switchProgress = sender.windows.compactMap { $0.delegate as? SwitchProgressWindowController }
        let resets = sender.windows.compactMap { $0.delegate as? ResetWindowController }
        let resetProgress = sender.windows.compactMap { $0.delegate as? ResetProgressWindowController }
        let bisects = sender.windows.compactMap { $0.delegate as? BisectWindowController }
        for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = true }
        for controller in referenceBrowsers { controller.model.confirmingQuit = true }
        for controller in blames { controller.model.confirmingQuit = true }
        for controller in logs { controller.model.confirmingQuit = true }
        for controller in pushes { controller.model.confirmingQuit = true }
        for controller in fetches { controller.model.confirmingQuit = true }
        for controller in pullsInProgress { controller.model.confirmingQuit = true }
        for controller in fetchesInProgress { controller.model.confirmingQuit = true }
        for controller in merges { controller.model.confirmingQuit = true }
        for controller in mergesInProgress { controller.model.confirmingQuit = true }
        for controller in referenceCreations { controller.model.confirmingQuit = true }
        for controller in clones { controller.model.confirmingQuit = true }
        for controller in clonesInProgress { controller.model.confirmingQuit = true }
        for controller in creations { controller.model.confirmingQuit = true }
        for controller in requestPulls { controller.model.confirmingQuit = true }
        for controller in mailProgresses { controller.model.confirmingQuit = true }
        for controller in formatPatches { controller.model.confirmingQuit = true }
        for controller in rebaseCompletionMails { controller.confirmingQuit = true }
        for controller in exports { controller.model.confirmingQuit = true }
        for controller in exportsInProgress { controller.model.confirmingQuit = true }
        for controller in stashSaves { controller.model.confirmingQuit = true }
        for controller in stashProgress { controller.model.confirmingQuit = true }
        for controller in stashRestores { controller.model.confirmingQuit = true }
        for controller in switches { controller.model.confirmingQuit = true }
        for controller in switchProgress { controller.model.confirmingQuit = true }
        for controller in resets { controller.model.confirmingQuit = true }
        for controller in resetProgress { controller.model.confirmingQuit = true }
        for controller in bisects { controller.model.confirmingQuit = true }
        let submoduleSyncs = sender.windows.compactMap { $0.delegate as? SubmoduleSyncWindowController }
        let submoduleAdds = sender.windows.compactMap { $0.delegate as? SubmoduleAddWindowController }
        let submoduleAddProgress = sender.windows.compactMap { $0.delegate as? SubmoduleAddProgressWindowController }
        let updates = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateWindowController }
        let submoduleDiffs = sender.windows.compactMap { $0.delegate as? SubmoduleDiffWindowController }
        let submoduleConflicts = sender.windows.compactMap { $0.delegate as? SubmoduleConflictWindowController }
        let updateProgress = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateProgressWindowController }
        for controller in submoduleSyncs { controller.model.confirmingQuit = true }
        for controller in submoduleAdds { controller.model.confirmingQuit = true }
        for controller in submoduleAddProgress { controller.model.confirmingQuit = true }
        for controller in updates { controller.model.confirmingQuit = true }
        for controller in submoduleDiffs { controller.model.confirmingQuit = true }
        for controller in submoduleConflicts { controller.model.confirmingQuit = true }
        for controller in updateProgress { controller.model.confirmingQuit = true }
        for controller in inaccessibleDiagnostics { controller.model.confirmingQuit = true }
        setTransferQuitConfirmation(sender, true); setRoutingQuitConfirmation(true)
        Task {
            await shutdownRoutingModels()
            for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = false }
            for controller in referenceBrowsers { controller.model.confirmingQuit = false }
            for controller in blames { controller.model.confirmingQuit = false }
            for controller in logs { controller.model.confirmingQuit = false }
            for controller in pushes { controller.model.confirmingQuit = false }
            for controller in fetches { controller.model.confirmingQuit = false }
            for controller in pullsInProgress { controller.model.confirmingQuit = false }
            for controller in fetchesInProgress { controller.model.confirmingQuit = false }
            for controller in merges { controller.model.confirmingQuit = false }
            for controller in mergesInProgress { controller.model.confirmingQuit = false }
            for controller in referenceCreations { controller.model.confirmingQuit = false }
            for controller in clones { controller.model.confirmingQuit = false }
            for controller in clonesInProgress { controller.model.confirmingQuit = false }
            for controller in creations { controller.model.confirmingQuit = false }
            for controller in requestPulls { controller.model.confirmingQuit = false }
            for controller in mailProgresses { controller.model.confirmingQuit = false }
            for controller in formatPatches { controller.model.confirmingQuit = false }
            for controller in rebaseCompletionMails { controller.confirmingQuit = false }
            for controller in exports { controller.model.confirmingQuit = false }
            for controller in exportsInProgress { controller.model.confirmingQuit = false }
            for controller in stashSaves { controller.model.confirmingQuit = false }
            for controller in stashProgress { controller.model.confirmingQuit = false }
            for controller in stashRestores { controller.model.confirmingQuit = false }
            for controller in switches { controller.model.confirmingQuit = false }
            for controller in switchProgress { controller.model.confirmingQuit = false }
            for controller in resets { controller.model.confirmingQuit = false }
            for controller in resetProgress { controller.model.confirmingQuit = false }
            for controller in bisects { controller.model.confirmingQuit = false }
            for controller in submoduleSyncs { controller.model.confirmingQuit = false }
            for controller in submoduleAdds { controller.model.confirmingQuit = false }
            for controller in submoduleAddProgress { controller.model.confirmingQuit = false }
            for controller in updates { controller.model.confirmingQuit = false }
            for controller in submoduleDiffs { controller.model.confirmingQuit = false }
            for controller in submoduleConflicts { controller.model.confirmingQuit = false }
            for controller in updateProgress { controller.model.confirmingQuit = false }
            for controller in inaccessibleDiagnostics { controller.model.confirmingQuit = false }
            setTransferQuitConfirmation(sender, false); setRoutingQuitConfirmation(false)
            retireCommandDiagnostics();confirmingQuit=false;replyToTermination(sender,true)
        }
        return .terminateLater
    }

}

/// Services supplies a private selection pasteboard. Capture it before returning
/// to the caller, then use the same owned permission/discovery route as Finder.
@MainActor final class TurtleGitFinderServicesProvider: NSObject {
    enum Failure: LocalizedError {
        case unavailable, busy, command, selection, selectionChanged, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return "TurtleGit cannot accept a Services request while it is closing."
            case .busy: return "TurtleGit is preparing another repository operation. Finish or cancel it, then invoke the service again."
            case .command: return "The requested TurtleGit service is not supported."
            case .selection: return "Select file or folder URLs to use this TurtleGit service."
            case .selectionChanged: return "The selected files changed while TurtleGit was receiving them. Invoke the service again."
            case .tooLarge: return "Select at most 10,000 items with no more than 1 MiB of file URL data."
            }
        }
    }
    private static let maximumItems = FinderServiceCommand.maximumPaths, maximumBytes = FinderServiceCommand.maximumRequestBytes
    private(set) var retired = false
    private var submit: (FinderRequest) throws -> Void
    private var openSelection:([URL])throws->Void
    init(open:@escaping([URL])throws->Void = {_ in throw Failure.unavailable},submit: @escaping (FinderRequest) throws -> Void) { self.submit = submit;openSelection=open; super.init() }
    func retire() { retired = true; submit = { _ in throw Failure.unavailable };openSelection={_ in throw Failure.unavailable} }
    @objc(openInTurtleGit:userData:error:)
    func openInTurtleGit(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            guard !retired else{throw Failure.unavailable}
            guard userData=="open" else{throw Failure.command}
            let paths=try FinderServiceCommand.status.request(paths:Self.selection(from:pasteboard)).paths
            try openSelection(paths)
        }catch let failure {error.pointee=failure.localizedDescription as NSString}
    }
    static func openSelectionURL(_ paths:[URL])throws->URL {
        let paths=try FinderServiceCommand.status.request(paths:paths).paths
        var parts=URLComponents();parts.scheme="turtlegit";parts.host="service-open"
        parts.queryItems=paths.map{URLQueryItem(name:"path",value:$0.absoluteString)}
        guard let url=parts.url,url.absoluteString.utf8.count<=maximumBytes else{throw Failure.tooLarge};return url
    }
    static func openSelection(from url:URL)throws->[URL] {
        guard let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),parts.scheme=="turtlegit",parts.host=="service-open",parts.path.isEmpty,parts.user==nil,parts.password==nil,parts.port==nil,parts.fragment==nil,
              let items=parts.queryItems,!items.isEmpty,items.allSatisfy({$0.name=="path" && $0.value != nil}),items.count<=maximumItems,url.absoluteString.utf8.count<=maximumBytes else{throw Failure.command}
        let paths=try items.map{item->URL in guard let value=item.value,let path=URL(string:value) else{throw Failure.selection};return path}
        return try FinderServiceCommand.status.request(paths:paths).paths
    }
    @objc(performFinderAction:userData:error:)
    func performFinderAction(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            guard !retired else { throw Failure.unavailable }
            guard let userData, let command = FinderServiceCommand(rawValue: userData) else { throw Failure.command }
            let paths = try Self.selection(from: pasteboard)
            let alternate = command.capturesAlternateTool ? ComparisonToolInvocation.capture : nil
            let request = try command.request(paths: paths, alternateTool: alternate)
            try submit(request)
        } catch let failure { error.pointee = failure.localizedDescription as NSString }
    }
    static func selection(from pasteboard: NSPasteboard) throws -> [URL] {
        let generation = pasteboard.changeCount, items = pasteboard.pasteboardItems ?? []
        var result: [URL] = [], bytes = 0
        func count(_ raw: String) throws {
            guard raw.utf8.count <= maximumBytes - bytes else { throw Failure.tooLarge }
            bytes += raw.utf8.count
        }
        guard items.count <= maximumItems else { throw Failure.tooLarge }
        if items.contains(where: { $0.types.contains(.fileURL) }) {
            // Never silently narrow a heterogeneous selection to the URLs that
            // readObjects(fileURLsOnly:) happens to understand.
            for item in items {
                guard item.types.contains(.fileURL), let raw = item.string(forType: .fileURL) else { throw Failure.selection }
                try count(raw)
                guard let url = URL(string: raw), url.isFileURL else { throw Failure.selection }
                result.append(url)
            }
        } else {
            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            guard items.count <= 1 else { throw Failure.selection }
            guard let paths = pasteboard.propertyList(forType: filenames) as? [String], !paths.isEmpty else { throw Failure.selection }
            guard paths.count <= maximumItems else { throw Failure.tooLarge }
            for path in paths {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.selection }
                try count(path); result.append(FileTransferPaths.fileURL(path))
            }
        }
        guard !result.isEmpty else { throw Failure.selection }
        guard generation == pasteboard.changeCount else { throw Failure.selectionChanged }
        return result
    }
}

private enum FinderActionLaunchFailure: LocalizedError {
    case unavailable, invalid, collision
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The Finder action handoff is unavailable. Invoke the command again from Finder."
        case .invalid: return "The Finder action could not be read. Invoke the command again from Finder."
        case .collision: return "The Finder action receipt does not match its command. Invoke the command again from Finder."
        }
    }
}
