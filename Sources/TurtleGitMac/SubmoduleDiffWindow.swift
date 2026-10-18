import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleWorkingLogSession {
    private(set) static var activeReads = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    private var retired = false
    private var token: OperationCancellation?
    var readCheckout: (String, OperationCancellation) async throws -> GitRepository
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        self.repository = repository; self.access = access
        readCheckout = { try await repository.submoduleWorkingRepository(path: $0, cancellation: $1) }
    }
    var isReading: Bool { token != nil }
    func cancel() { token?.cancel() }
    func retire() { retired = true; cancel() }
    func load(_ path: String, cancellation: OperationCancellation? = nil) async throws -> GitRepository {
        guard !retired, token == nil else { throw OperationCancellationFailure.cancelled }
        let request = cancellation ?? OperationCancellation(); token = request; Self.activeReads += 1
        defer { Self.activeReads -= 1; if token === request { token = nil }; withExtendedLifetime(access) {} }
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
        let child = try await readCheckout(path, request)
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
    private(set) var updateOptions: SubmoduleUpdateWindowController?
    private(set) var updateProgress: SubmoduleUpdateProgressWindowController?
    var onUpdated: (String) -> Void = { _ in }
    var onAttemptCompleted: (SubmoduleUpdateResult) -> Void = { _ in }
    var onBisect: (BisectOperation) -> Void = { _ in }
    private var pendingSheetAction: (() -> Void)?
    private let preferences: UserDefaults
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String? = nil, fromPath: String? = nil, fromIndex: Bool = false, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        model = SubmoduleDiffWindowModel(repository: repository, access: access, path: path, from: from, to: to, fromPath: fromPath, fromIndex: fromIndex)
        let size = NSSize(width: 900, height: fromPath.map { !GitReferenceName.equal($0, path) } == true && !fromIndex ? 360:320)
        let window = SubmoduleDiffNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Submodule Diff", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: size.height)
        window.contentViewController = NSHostingController(rootView: SubmoduleDiffDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        model.close = { [weak window] in window?.close() }
        model.onUpdate = { [weak self] done in self?.presentUpdate(done) }
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
        options.onClosed = { [weak window, weak options] in
            if let child = options?.window, window?.attachedSheet === child { window?.endSheet(child) }
        }
        guard let child = options.window else { updateOptions = nil; done(); return }
        child.appearance = window.appearance; child.alphaValue = window.alphaValue
        window.beginSheet(child) { [weak self] _ in
            guard let self else { return }; self.updateOptions = nil
            guard !self.closed else { return }
            self.pendingSheetAction = { [weak self] in
                guard let self, !self.closed else { return }
                guard let (paths, values) = submission else { done(); return }
                self.presentUpdateProgress(paths: paths, options: values, done: done)
            }
            self.drainSheetAction()
        }
    }
    private func presentUpdateProgress(paths: [String], options: SubmoduleUpdateOptions, done: @escaping () -> Void) {
        guard !closed, let window, window.attachedSheet == nil else { done(); return }
        let progress = SubmoduleUpdateProgressWindowController(repository: model.repository, access: model.access, paths: paths, options: options, preferences: preferences)
        updateProgress = progress
        progress.model.onUpdated = { [weak self] in self?.onUpdated($0) }
        let attemptCompleted=onAttemptCompleted
        progress.model.onAttemptCompleted = { attemptCompleted($0) }
        progress.model.onBisect = { [weak self] in self?.onBisect($0) }
        progress.onClosed = { [weak window, weak progress] in
            if let child = progress?.window, window?.attachedSheet === child { window?.endSheet(child) }
        }
        guard let child = progress.window else { updateProgress = nil; done(); return }
        child.appearance = window.appearance; child.alphaValue = window.alphaValue
        window.beginSheet(child) { [weak self] _ in
            guard let self else { return }; self.updateProgress = nil
            if !self.closed { self.pendingSheetAction = done; self.drainSheetAction() }
        }
        progress.model.start()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.invalidate(); pendingSheetAction = nil; NotificationCenter.default.removeObserver(self)
        updateOptions?.model.invalidate(); updateProgress?.model.invalidate()
        if let child = window?.attachedSheet { window?.endSheet(child, returnCode: .abort); child.close() }
        updateOptions?.window?.close(); updateProgress?.window?.close()
        updateOptions = nil; updateProgress = nil; onClosed()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.requestClose() && sender.attachedSheet == nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SubmoduleDiffWindowModel: ObservableObject {
    private(set) static var activeReads = 0
    private(set) var retired = false
    private var token: OperationCancellation?
    private var generation = UUID()
    var readCommand: (SubmoduleComparison, SubmoduleComparisonAction, OperationCancellation) async throws -> PreparedSubmoduleComparison
    var onConflict: (() -> Void)?
    var close: () -> Void = {}
    private var closeAfterRead = false
    private var updateTicket: UUID?
    @Published private(set) var hasUpdateChild = false
    var readDetails: (OperationCancellation) async throws -> SubmoduleComparison
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let path: String
    let from: String
    let fromPath: String
    let fromIndex: Bool
    let to: String?
    @Published var details: SubmoduleComparison?
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    var onLog: (GitRepository, String) -> Void = { _, _ in }
    var onStatus: (GitRepository) -> Void = { _ in }
    var onCompare: (GitRepository, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _ in }
    var onUpdate: (@escaping () -> Void) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String?, fromPath: String? = nil, fromIndex: Bool = false) {
        self.repository = repository; self.access = access; self.path = path; self.from = from; self.to = to
        self.fromPath = fromPath ?? path; self.fromIndex = fromIndex
        readCommand = {try await repository.prepareSubmoduleComparison($0,action:$1,cancellation:$2)}
        readDetails = {try await repository.submoduleComparison(path:path,from:from,to:to,fromPath:fromPath,fromIndex:fromIndex,cancellation:$0)}
    }
    @discardableResult func cancelRead() -> Bool { guard let token else { return false }; token.cancel(); return true }
    func invalidate() { retired = true; generation = UUID(); token?.cancel(); updateTicket = nil; hasUpdateChild = false }
    func requestClose() -> Bool { if hasUpdateChild { return false }; if cancelRead() { closeAfterRead = true; return false }; return !confirmingQuit }
    private func settled(_ request: OperationCancellation) {
        if token === request { token = nil; busy = false; if closeAfterRead && !retired { closeAfterRead = false; close() } }
    }
    func load() {
        guard !retired, !busy, !confirmingQuit, !hasUpdateChild else { return }; busy = true
        let request = OperationCancellation(), epoch = UUID(); token = request; generation = epoch; Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; settled(request); withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let next = try await readDetails(request)
                guard !retired, generation == epoch, !request.isCancelled else { return }
                details = next
            } catch {
                if !retired, generation == epoch, !request.isCancelled {
                    if case SubmoduleComparisonFailure.conflicted = error, let onConflict { onConflict() }
                    else { self.error = error.localizedDescription }
                }
            }
        }
    }
    func log(_ side: SubmoduleComparisonSide) {
        guard let details, side.canShowLog else { return }
        if side.revision == details.from.revision { dispatch(.logFrom) }
        else if side.revision == details.to.revision { dispatch(.logTo) }
    }
    func compare(workingTree: Bool = false) { dispatch(workingTree ? .compareWorkingTree : .compareRevisions) }
    private func dispatch(_ action: SubmoduleComparisonAction) {
        guard !retired, !busy, !confirmingQuit, !hasUpdateChild, let details else { return }
        let alternate = ComparisonToolInvocation.capture
        let request = OperationCancellation(), epoch = UUID()
        token = request; generation = epoch; busy = true; Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; settled(request); withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let prepared = try await readCommand(details, action, request)
                guard !retired, generation == epoch, !request.isCancelled else { return }
                if GitRuntime.isAppStoreBuild && access?.contains(prepared.repository.root) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                ComparisonToolInvocation.$alternate.withValue(alternate) {
                    switch prepared.command {
                    case .log(let hash): onLog(prepared.repository, hash)
                    case .status: onStatus(prepared.repository)
                    case .compare(let from, let to): onCompare(prepared.repository, from, to)
                    }
                }
            } catch { if !retired, generation == epoch, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func update() {
        guard !retired, !busy, !confirmingQuit, !hasUpdateChild else { return }
        let ticket = UUID(); updateTicket = ticket; hasUpdateChild = true
        onUpdate { [weak self] in
            guard let self, !self.retired, self.updateTicket == ticket else { return }
            self.updateTicket = nil; self.hasUpdateChild = false; self.load()
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
        GroupBox(to ? "To" + (details.toWorkingTree ? " (Working tree)" : "") : "From" + (model.fromIndex ? " (Index)":"")) {
            VStack(alignment: .leading, spacing: 9) {
                if to {
                    HStack {
                        Text("Type:").frame(width: 65, alignment: .leading)
                        Text(details.change.rawValue).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(details.change == .identical ? Color.primary : .black)
                            .background(details.change == .identical ? Color.clear : tint(details.change)).cornerRadius(3)
                        Spacer()
                        if details.toWorkingTree || !details.from.available || !details.to.available { Button { model.update() } label: { CommandLabel(title: "Update", icon: .fetch) } }
                        HStack(spacing: 0) {
                            Button { model.compare() } label: { CommandLabel(title: details.change == .identical ? "Compare" : "Show diff", icon: .compare) }
                            if details.dirty && details.change != .unknown && details.change != .identical {
                                Menu { Button { model.compare() } label: { CommandLabel(title: "Show diff", icon: .compare) }; Button { model.compare(workingTree: true) } label: { CommandLabel(title: "Compare", icon: .compare) } } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).frame(width: 25)
                            }
                        }.disabled(!details.from.available || !details.to.available)
                    }
                }
                HStack {
                    Text("Revision:").frame(width: 65, alignment: .leading)
                    Text((side.revision ?? "") + (to && details.dirty ? "-dirty" : "")).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .foregroundStyle(to && details.dirty ? Color.red : Color.primary)
                        .padding(.horizontal, 3).background(to && details.dirty ? Color.yellow : Color.clear)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.log(side) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(!side.canShowLog).accessibilityLabel(to ? "Show log for To" : "Show log for From")
                }
                HStack(alignment: .top) {
                    Text("Subject:").frame(width: 65, alignment: .leading)
                    Text(side.subject).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
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
