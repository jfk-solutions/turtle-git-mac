import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class SubmoduleWorkingLogSession {
    private(set) static var activeReads = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    private var retired = false
    private var token: OperationCancellation?
    var readCheckout: ((String, OperationCancellation) async throws -> GitRepository)?
    private let preferences: UserDefaults
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
    }
    var isReading: Bool { token != nil }
    func cancel() { token?.cancel() }
    func retire() { retired = true; cancel() }
    func load(_ path: String, cancellation: OperationCancellation? = nil) async throws -> GitRepository {
        guard !retired, token == nil else { throw OperationCancellationFailure.cancelled }
        let request = cancellation ?? OperationCancellation(); token = request; Self.activeReads += 1
        defer { Self.activeReads -= 1; if token === request { token = nil }; withExtendedLifetime(access) {} }
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
        let repository = self.repository.capturingDiffBackend(preferences: preferences)
        let child: GitRepository
        if let readCheckout { child = try await readCheckout(path, request) }
        else { child = try await repository.submoduleWorkingRepository(path: path, cancellation: request) }
        guard !retired, !request.isCancelled else { throw OperationCancellationFailure.cancelled }
        if GitRuntime.isAppStoreBuild && access?.contains(child.root) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
        return child
    }
}

private final class SubmoduleDiffNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.window === self,commandKeyWindow() === self,attachedSheet == nil,event.keyCode == 96,
           event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class SubmoduleDiffWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleDiffWindowModel
    var onClosed: () -> Void = {}
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    private var closed = false
    private var releaseTask:Task<Void,Never>?
    private var conflictHandoff:(()->Void)?
    private var retiringSheets:[NSWindow]=[]
    private(set) static var activeReleases=0
    var canReuse:Bool {!closed && !model.retired}
    var hasPendingWork:Bool {releaseTask != nil || model.hasPendingWork || updateOptions != nil || updateProgress != nil || window?.attachedSheet != nil || window?.sheetParent != nil || retiringSheets.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    func closeForConflict(_ action:@escaping()->Void) {
        guard !closed,!model.confirmingQuit,conflictHandoff==nil else{return}
        conflictHandoff=action;window?.close()
    }
    private(set) var updateOptions: SubmoduleUpdateWindowController?
    private(set) var updateProgress: SubmoduleUpdateProgressWindowController?
    var onUpdated: (String) -> Void = { _ in }
    var onAttemptCompleted: (SubmoduleUpdateResult) -> Void = { _ in }
    var onBisect: (BisectOperation) -> Void = { _ in }
    private var pendingSheetAction: (() -> Void)?
    private let preferences: UserDefaults
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String? = nil, fromPath: String? = nil, fromIndex: Bool = false, toIndex: Bool = false, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        model = SubmoduleDiffWindowModel(repository: repository, access: access, path: path, from: from, to: to, fromPath: fromPath, fromIndex: fromIndex, toIndex: toIndex, preferences: preferences)
        let size = NSSize(width: 900, height: fromPath.map { !GitReferenceName.equal($0, path) } == true && !fromIndex ? 360:320)
        let window = SubmoduleDiffNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Submodule Diff", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: size.height)
        let host=NSHostingController(rootView:SubmoduleDiffDialog(model:model).defaultAppStorage(preferences))
        host.sizingOptions=[];window.contentViewController=host
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(greaterThanOrEqualToConstant:800),host.view.heightAnchor.constraint(greaterThanOrEqualToConstant:size.height)])
        super.init(window: window); window.delegate = self
        model.presentationAvailable={ [weak self,weak window] in self?.closed==false && window != nil && window?.attachedSheet==nil }
        model.close = { [weak window] in window?.close() }
        model.onUpdate = { [weak self] done in self?.presentUpdate(done) }
        model.quitStateChanged={ [weak self] value in self?.updateOptions?.model.confirmingQuit=value;self?.updateProgress?.model.confirmingQuit=value }
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        window.setContentSize(size); window.center()
        window.refresh = { [weak model] in model?.load() }
        window.commandKeyWindow = { [weak self] in self?.commandKeyWindow() }

        DialogGeometry.attach(window, identifier: "SubmoduleDiffDialog", legacyName: "SubmoduleDiffDialog")
    }
    @objc private func sheetEnded() { drainSheetAction() }
    private func drainSheetAction() {
        guard !closed, window?.attachedSheet == nil, let action = pendingSheetAction else { return }
        pendingSheetAction = nil; action()
    }
    private func presentUpdate(_ done: @escaping () -> Void) {
        guard !closed, let window, window.attachedSheet == nil, updateOptions == nil, updateProgress == nil else { done(); return }
        let options = SubmoduleUpdateWindowController(repository: model.repository, access: model.access, scope: [], selected: [model.path], preferences: preferences)
        updateOptions = options
        var submission: ([String], SubmoduleUpdateOptions)?
        options.model.onSubmit = { paths, values in submission = (paths, values) }
        options.model.close = { [weak window, weak options] in
            guard let window, let child = options?.window else { return }
            window.endSheet(child); child.close()
        }
        options.onClosed = { [weak self,weak options] in
            guard let self,let options,self.updateOptions===options else{return}
            self.updateOptions=nil
            guard !self.closed else{return}
            self.pendingSheetAction={ [weak self] in
                guard let self,!self.closed,!self.model.confirmingQuit else{done();return}
                guard let (paths,values)=submission else{done();return}
                self.presentUpdateProgress(paths:paths,options:values,done:done)
            }
            self.drainSheetAction()
        }
        guard let child = options.window else { updateOptions = nil; done(); return }
        child.appearance = window.appearance; child.alphaValue = window.alphaValue
        window.beginSheet(child) { [weak self] _ in self?.drainSheetAction() }
    }
    private func presentUpdateProgress(paths: [String], options: SubmoduleUpdateOptions, done: @escaping () -> Void) {
        guard !closed, let window, window.attachedSheet == nil else { done(); return }
        let progress = SubmoduleUpdateProgressWindowController(repository: model.repository, access: model.access, paths: paths, options: options, preferences: preferences)
        updateProgress = progress
        progress.model.onUpdated = { [weak self] path in guard let self,!self.closed,!self.model.confirmingQuit else{return};self.onUpdated(path) }
        let attemptCompleted=onAttemptCompleted
        progress.model.onAttemptCompleted = { attemptCompleted($0) }
        progress.model.onBisect = { [weak self] operation in guard let self,!self.closed,!self.model.confirmingQuit else{return};self.onBisect(operation) }
        progress.onClosed = { [weak self,weak progress] in
            guard let self,let progress,self.updateProgress===progress else{return}
            self.updateProgress=nil
            if !self.closed {self.pendingSheetAction=done;self.drainSheetAction()}
        }
        guard let child = progress.window else { updateProgress = nil; done(); return }
        child.appearance = window.appearance; child.alphaValue = window.alphaValue
        window.beginSheet(child) { [weak self] _ in self?.drainSheetAction() }
        progress.model.start()
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow===window,!closed else{return}
        closed=true;model.invalidate();pendingSheetAction=nil;NotificationCenter.default.removeObserver(self)
        updateOptions?.model.invalidate();updateProgress?.model.invalidate()
        if let child=window?.attachedSheet {retiringSheets.append(child);window?.endSheet(child,returnCode:.abort);child.close()}
        updateOptions?.window?.close();updateProgress?.window?.close()
        if let window,let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)}
        Self.activeReleases += 1
        releaseTask=Task{@MainActor [self] in
            while model.pendingReads>0 || updateOptions != nil || updateProgress != nil || window?.attachedSheet != nil || window?.sheetParent != nil || retiringSheets.contains(where:{$0.sheetParent != nil || $0.attachedSheet != nil}) {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            let handoff=conflictHandoff;conflictHandoff=nil;retiringSheets=[];releaseTask=nil;Self.activeReleases -= 1
            let done=onClosed;onClosed={};done()
            if !model.confirmingQuit {handoff?()}
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.requestClose() && sender.attachedSheet == nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SubmoduleDiffWindowModel: ObservableObject {
    private(set) static var activeReads = 0
    private(set) var pendingReads=0
    var hasPendingWork:Bool {pendingReads>0 || hasUpdateChild}
    private(set) var retired = false
    private var token: OperationCancellation?
    private var generation = UUID()
    var readCommand: ((SubmoduleComparison, SubmoduleComparisonAction, OperationCancellation) async throws -> PreparedSubmoduleComparison)?
    var onConflict: (() -> Void)?
    var close: () -> Void = {}
    private var closeAfterRead = false
    private var updateTicket: UUID?
    @Published private(set) var hasUpdateChild = false
    var readDetails: ((OperationCancellation) async throws -> SubmoduleComparison)?
    private let preferences: UserDefaults
    var presentationPreferences:UserDefaults {preferences}
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let path: String
    let from: String
    let fromPath: String
    let fromIndex: Bool
    let toIndex: Bool
    let to: String?
    enum ComparisonAction:String,CaseIterable {case showDiff="Show diff",compare="Compare"}
    struct ActionReceipt:Equatable {let generation:UUID}
    var actionReceipt:ActionReceipt {ActionReceipt(generation:generation)}
    var presentationAvailable:()->Bool={true}
    var canInteract:Bool {!retired && !busy && !confirmingQuit && !hasUpdateChild && presentationAvailable()}
    @Published private(set) var selectedComparisonAction:ComparisonAction = .showDiff
    var comparisonActions:[ComparisonAction] {
        guard let details else{return []}
        if details.change == .identical {return [.compare]}
        return details.dirty && details.change != .unknown ? [.showDiff,.compare]:[.showDiff]
    }
    @Published var details: SubmoduleComparison? {
        didSet {generation=UUID();selectedComparisonAction=details?.change == .identical ? .compare:.showDiff}
    }
    @Published var busy = false
    var quitStateChanged:(Bool)->Void={_ in}
    @Published var confirmingQuit = false {
        didSet {
            guard confirmingQuit != oldValue else{return}
            generation=UUID()
            if confirmingQuit {token?.cancel()}
            quitStateChanged(confirmingQuit)
        }
    }
    @Published var error: String?
    var onLog: (GitRepository, String) -> Void = { _, _ in }
    var onStatus: (GitRepository) -> Void = { _ in }
    var onCompare: (GitRepository, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _ in }
    var onUpdate: (@escaping () -> Void) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String?, fromPath: String? = nil, fromIndex: Bool = false, toIndex: Bool = false, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.repository = repository; self.access = access; self.path = path; self.from = from; self.to = to
        self.fromPath = fromPath ?? path; self.fromIndex = fromIndex; self.toIndex = toIndex
    }
    @discardableResult func cancelRead() -> Bool { guard let token else { return false }; token.cancel(); return true }
    func invalidate() { retired = true; generation = UUID(); token?.cancel(); updateTicket = nil; hasUpdateChild = false }
    func requestClose() -> Bool { if hasUpdateChild { return false }; if cancelRead() { closeAfterRead = true; return false }; return !confirmingQuit }
    private func settled(_ request: OperationCancellation) {
        if token === request { token = nil; busy = false; if closeAfterRead && !retired { closeAfterRead = false; close() } }
    }
    func load() {
        guard canInteract else { return }; busy = true;error=nil
        let repository = self.repository.capturingDiffBackend(preferences: preferences)
        let request = OperationCancellation(), epoch = UUID(); token = request; generation = epoch; Self.activeReads += 1;pendingReads += 1
        Task {
            var handoff:(()->Void)?
            defer {
                Self.activeReads -= 1;pendingReads -= 1;settled(request)
                if !retired,!confirmingQuit,generation==epoch,!request.isCancelled {handoff?()}
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let next: SubmoduleComparison
                if let readDetails { next = try await readDetails(request) }
                else { next = try await repository.submoduleComparison(path:path,from:from,to:to,fromPath:fromPath,fromIndex:fromIndex,toIndex:toIndex,cancellation:request) }
                guard !retired, generation == epoch, !request.isCancelled else { return }
                details = next
            } catch {
                if !retired, generation == epoch, !request.isCancelled {
                    if case SubmoduleComparisonFailure.conflicted = error, let onConflict { handoff=onConflict }
                    else { self.error = error.localizedDescription }
                }
            }
        }
    }
    func log(_ side: SubmoduleComparisonSide,receipt:ActionReceipt?=nil) {
        guard receipt==nil || receipt==actionReceipt,let details, side.canShowLog else { return }
        if side.revision == details.from.revision { dispatch(.logFrom) }
        else if side.revision == details.to.revision { dispatch(.logTo) }
    }
    func compare(workingTree: Bool = false) {performComparison(workingTree || details?.change == .identical ? .compare:.showDiff,receipt:actionReceipt,alternate:ComparisonToolInvocation.capture)}
    func performComparison(_ action:ComparisonAction,receipt:ActionReceipt,alternate:Bool) {
        guard canInteract,receipt==actionReceipt,comparisonActions.contains(action),let details,details.from.available,details.to.available else{return}
        selectedComparisonAction=action
        dispatch(action == .compare ? .compareWorkingTree:.compareRevisions,alternate:alternate)
    }
    private func dispatch(_ action: SubmoduleComparisonAction,alternate:Bool?=nil) {
        guard canInteract, let details else { return }
        let repository = self.repository.capturingDiffBackend(preferences: preferences)
        let alternate = alternate ?? ComparisonToolInvocation.capture
        let request = OperationCancellation(), epoch = UUID()
        token = request; generation = epoch; busy = true; Self.activeReads += 1;pendingReads += 1
        Task {
            var handoff:(()->Void)?
            defer {
                Self.activeReads -= 1;pendingReads -= 1;settled(request)
                if !retired,!confirmingQuit,generation==epoch,!request.isCancelled {handoff?()}
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let prepared: PreparedSubmoduleComparison
                if let readCommand { prepared = try await readCommand(details, action, request) }
                else { prepared = try await repository.prepareSubmoduleComparison(details,action:action,cancellation:request) }
                guard !retired, generation == epoch, !request.isCancelled else { return }
                if GitRuntime.isAppStoreBuild && access?.contains(prepared.repository.root) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                handoff={ [self] in
                    ComparisonToolInvocation.$alternate.withValue(alternate) {
                        switch prepared.command {
                        case .log(let hash): onLog(prepared.repository,hash)
                        case .status: onStatus(prepared.repository)
                        case .compare(let from,let to): onCompare(prepared.repository,from,to)
                        }
                    }
                }
            } catch { if !retired, generation == epoch, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func update(receipt:ActionReceipt?=nil) {
        guard canInteract,receipt==nil || receipt==actionReceipt,let details,details.toWorkingTree || !details.from.available || !details.to.available else { return }
        generation=UUID()
        let ticket = UUID(); updateTicket = ticket; hasUpdateChild = true
        onUpdate { [weak self] in
            guard let self, !self.retired, self.updateTicket == ticket else { return }
            self.updateTicket = nil; self.hasUpdateChild = false;if !self.confirmingQuit {self.load()}
        }
    }
}
private struct SubmoduleDiffDialog: View {
    @ObservedObject var model: SubmoduleDiffWindowModel
    private func tint(_ change: SubmoduleChangeType) -> Color {
        switch change {
        case .fastForward: return Color(red: 211/255, green: 249/255, blue: 154/255)
        case .rewind: return Color(red: 249/255, green: 199/255, blue: 229/255)
        case .newerTime: return Color(red: 176/255, green: 223/255, blue: 244/255)
        case .olderTime: return Color(red: 244/255, green: 207/255, blue: 159/255)
        default: return Color(red: 222/255, green: 222/255, blue: 222/255)
        }
    }
    private func section(_ side: SubmoduleComparisonSide, details: SubmoduleComparison, to: Bool) -> some View {
        let receipt=model.actionReceipt
        return GroupBox(to ? "To" + (model.toIndex ? " (Index)":details.toWorkingTree ? " (Working tree)" : "") : "From" + (model.fromIndex ? " (Index)":"")) {
            VStack(alignment: .leading, spacing: 9) {
                if to {
                    HStack {
                        Text("Type:").frame(width: 65, alignment: .leading)
                        Text(details.change.rawValue).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(details.change == .identical ? Color.primary : .black)
                            .background(details.change == .identical ? Color.clear : tint(details.change)).cornerRadius(3)
                        Spacer()
                        if details.toWorkingTree || !details.from.available || !details.to.available { Button { model.update(receipt:receipt) } label: { CommandLabel(title: "Update", icon: .fetch) } }
                        SubmoduleDiffActionControl(model:model).fixedSize().disabled(!details.from.available || !details.to.available)
                    }
                }
                HStack {
                    Text("Revision:").frame(width: 65, alignment: .leading)
                    Text((side.revision ?? "") + (to && details.dirty ? "-dirty" : "")).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .foregroundStyle(to && details.dirty ? Color.red : Color.primary)
                        .padding(.horizontal, 3).background(to && details.dirty ? Color.yellow : Color.clear)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.log(side,receipt:receipt) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(!side.canShowLog).accessibilityLabel(to ? "Show log for To" : "Show log for From")
                }
                HStack(alignment: .top) {
                    Text("Subject:").frame(width: 65, alignment: .leading)
                    Text(side.subject).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(side.subject).frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                        .foregroundStyle(side.available ? Color.primary : .white).padding(.horizontal, 3).background(side.available ? Color.clear : Color.red)
                }
            }.padding(8)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Submodule " + String(reflecting:model.path)).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(model.path)
            if !GitReferenceName.equal(model.fromPath, model.path) && !model.fromIndex {Text("Renamed from " + String(reflecting:model.fromPath)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            if let details = model.details { section(details.from, details: details, to: false); section(details.to, details: details, to: true) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(12).disabled(model.busy || model.confirmingQuit || model.retired || model.hasUpdateChild)
        .overlay(alignment: .bottomLeading) { if model.busy { Button("Cancel") { model.cancelRead() }.padding(12) } }.onAppear { model.load() }
        .alert("Submodule comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

/// Native CMenuButton adaptation. Menu selection becomes the primary command
/// until F5 installs another source dialog snapshot; it is never a global pref.
@MainActor final class SubmoduleDiffNativeActionControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    var primaryKeyAction:((Bool)->Void)?
    var captureAlternate:()->Bool={ComparisonToolInvocation.capture}
    override var acceptsFirstResponder:Bool {isEnabled && !lifetime.retired}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();lifetime.observe(self)}
    @discardableResult func showActionMenu()->Bool {
        guard isEnabled,!lifetime.retired,segmentCount==2,let window,window.attachedSheet==nil,let menu=menu(forSegment:1) else{return false}
        return menu.popUp(positioning:nil,at:NSPoint(x:bounds.maxX,y:bounds.minY),in:self)
    }
    override func accessibilityPerformShowMenu()->Bool {showActionMenu()}
    override func keyDown(with event:NSEvent) {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==118 && flags.isEmpty || event.keyCode==125 && flags == .option || event.keyCode==109 && flags == .shift {_=showActionMenu();return}
        if [36,76,49].contains(event.keyCode),(flags.isEmpty || flags == .shift),isEnabled,!lifetime.retired {primaryKeyAction?(flags.contains(.shift));return}
        super.keyDown(with:event)
    }
}
struct SubmoduleDiffActionControl:NSViewRepresentable {
    @ObservedObject var model:SubmoduleDiffWindowModel
    @Environment(\.isEnabled) private var environmentEnabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->SubmoduleDiffNativeActionControl {
        let control=SubmoduleDiffNativeActionControl(labels:["Show diff"],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.identifier = .init("Submodule comparison action")
        control.setAccessibilityLabel(NSLocalizedString("Submodule comparison action",comment:""))
        context.coordinator.control=control
        control.primaryKeyAction={ [weak coordinator=context.coordinator] alternate in coordinator?.invokePrimary(alternate:alternate) }
        control.lifetime.onRetire={ [weak coordinator=context.coordinator,weak control] in control?.primaryKeyAction=nil;coordinator?.retire() }
        return control
    }
    func updateNSView(_ control:SubmoduleDiffNativeActionControl,context:Context) {
        let coordinator=context.coordinator
        guard !control.lifetime.retired else{control.isEnabled=false;return}
        coordinator.bind(model)
        let actions=model.comparisonActions,split=actions.count>1
        control.segmentCount=split ? 2:1
        control.isEnabled=environmentEnabled && model.canInteract && model.details?.from.available==true && model.details?.to.available==true
        let title=NSLocalizedString(model.selectedComparisonAction.rawValue,comment:"")
        control.setLabel(title,forSegment:0);control.toolTip=title
        control.setImage(MenuIcon.compare.contextImage(defaults:model.presentationPreferences),forSegment:0)
        control.setWidth(max(110,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width)+46),forSegment:0)
        if split {
            control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1)
            // Fresh items mean retained old items can never become valid again
            // when a later F5 happens to offer the same two captions.
            let menu=NSMenu();menu.autoenablesItems=false;menu.delegate=coordinator
            for action in actions {
                let item=NSMenuItem(title:NSLocalizedString(action.rawValue,comment:""),action:#selector(Coordinator.chosen(_:)),keyEquivalent:"")
                item.target=coordinator;item.representedObject=action.rawValue;item.state=action==model.selectedComparisonAction ? .on:.off
                item.image=MenuIcon.compare.contextImage(defaults:model.presentationPreferences);item.isEnabled=control.isEnabled;menu.addItem(item)
            }
            control.setMenu(menu,forSegment:1)
        }
        control.invalidateIntrinsicContentSize()
    }
    static func dismantleNSView(_ control:SubmoduleDiffNativeActionControl,coordinator:Coordinator) {
        control.primaryKeyAction=nil;control.lifetime.retire();coordinator.retire()
        if control.segmentCount>1 {control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1)}
        control.target=nil;control.action=nil;control.isEnabled=false
    }
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:SubmoduleDiffNativeActionControl?
        private weak var model:SubmoduleDiffWindowModel?
        private var observation:AnyCancellable?,menuReceipt:SubmoduleDiffWindowModel.ActionReceipt?
        private var retired=false,menuEpoch=UUID()
        func bind(_ model:SubmoduleDiffWindowModel) {
            guard !retired,self.model !== model else{return};self.model=model
            observation=model.objectWillChange.sink{[weak self] _ in self?.menuReceipt=nil;self?.menuEpoch=UUID()}
        }
        func retire(){retired=true;menuReceipt=nil;observation=nil;model=nil}
        private var ready:Bool {
            guard !retired,let model,let control,control.isEnabled,!control.lifetime.retired,let window=control.window else{return false}
            return model.canInteract && window.attachedSheet==nil
        }
        func invokePrimary(alternate:Bool?=nil) {
            guard ready,let model else{return}
            model.performComparison(model.selectedComparisonAction,receipt:model.actionReceipt,alternate:alternate ?? control?.captureAlternate() ?? false)
        }
        @objc func clicked(_ sender:NSSegmentedControl) {guard sender===control,sender.selectedSegment==0 else{return};invokePrimary()}
        func menuWillOpen(_ menu:NSMenu) {
            menuReceipt=nil;menuEpoch=UUID()
            guard ready,let control,control.segmentCount==2,control.menu(forSegment:1)===menu,let model else{for item in menu.items{item.isEnabled=false};return}
            menuReceipt=model.actionReceipt
            for item in menu.items {item.isEnabled=true}
        }
        func menuDidClose(_ menu:NSMenu) {
            let epoch=menuEpoch;DispatchQueue.main.async{[weak self] in guard let self,self.menuEpoch==epoch else{return};self.menuReceipt=nil}
        }
        @objc func chosen(_ item:NSMenuItem) {
            guard ready,let control,control.segmentCount==2,item.menu===control.menu(forSegment:1),item.isEnabled,
                  let raw=item.representedObject as? String,let action=SubmoduleDiffWindowModel.ComparisonAction(rawValue:raw),
                  let model,let receipt=menuReceipt else{return}
            let alternate=control.captureAlternate();menuReceipt=nil
            model.performComparison(action,receipt:receipt,alternate:alternate)
        }
    }
}
