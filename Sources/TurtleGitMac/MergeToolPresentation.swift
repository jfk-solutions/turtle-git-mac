// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import TurtleGitCore
import os

/// Local phase timing for diagnosing dialog startup. Never records paths,
/// messages, configuration values or repository contents.
enum NativeDialogStartupTrace {
    private static let log = Logger(subsystem: "org.turtlegit.macos", category: "DialogStartup")
    static func mark(_ phase: String, began: TimeInterval? = nil, count: Int = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = began.map { now - $0 } ?? 0
        log.notice("phase=\(phase, privacy: .public) uptime_s=\(now, privacy: .public) elapsed_s=\(elapsed, privacy: .public) count=\(count, privacy: .public)")
    }
}

/// General launches start with a lightweight command/router context. Restoring
/// repository access and creating the workspace are explicit presentation work.
@MainActor final class WorkspaceSceneOwner: ObservableObject {
    static let shared = WorkspaceSceneOwner()
    @Published private(set) var commandModel: RepositoryModel
    private(set) var storedModel: RepositoryModel?
    private(set) var storedController: WorkspaceWindowController?
    let appearance = AppAppearance()
    private weak var applicationDelegate: TurtleGitApplicationDelegate?
    var makeModel: () -> RepositoryModel = { RepositoryModel() }
    var installWorkspaceServices: (NSWindow) -> Void = { window in
        FirstStartWizardService.shared.install(isAvailable: { [weak window] in window?.isVisible == true })
        ReleaseUpdateService.shared.install()
    }
    var makeController: (RepositoryModel, AppAppearance, TurtleGitApplicationDelegate) -> WorkspaceWindowController = {
        WorkspaceWindowController(model: $0, appearance: $1, applicationDelegate: $2)
    }
    init(commandModel: RepositoryModel? = nil) {
        let router = commandModel ?? RepositoryModel(startMonitoring: false, initializePreferences: false)
        if commandModel == nil { router.enableActionRoutingAccess() }
        self.commandModel = router
        makeModel = { [router] in router.makeWorkspaceSharingActionAccess() }
    }
    // Retained for callers that explicitly request the repository owner.
    var model: RepositoryModel {
        if let storedModel { return storedModel }
        let model = makeModel(); storedModel = model; return model
    }
    func configure(applicationDelegate: TurtleGitApplicationDelegate) {
        self.applicationDelegate = applicationDelegate
        applicationDelegate.makeStandaloneWorkspace = { [commandModel] in commandModel }
        applicationDelegate.makeStandaloneAppearance = { [appearance] in appearance }
        applicationDelegate.presentWorkspace = { [weak self] in _ = self?.presentWorkspace() }
    }
    @discardableResult func presentWorkspace() -> RepositoryModel? {
        guard let applicationDelegate else { return nil }
        if let storedController {
            storedController.present()
            scheduleWorkspaceServices(storedController)
            return storedModel
        }
        // Switching the shared Settings context must never discard its draft.
        guard SettingsPresentationService.shared.prepareContextChange() else { return nil }
        let model = self.model
        let controller = makeController(model, appearance, applicationDelegate)
        storedController = controller
        applicationDelegate.attachWorkspaceModel(model, appearance: appearance)
        commandModel = model
        controller.present()
        // Automatic setup/update presentation is owned by this attached host.
        // Constructing an action router (including folder permission UI) cannot
        // create unrelated setup windows or start automatic update presentation.
        scheduleWorkspaceServices(controller)
        return model
    }
    private func scheduleWorkspaceServices(_ controller: WorkspaceWindowController) {
        // The native host is presented before bookmark/cache/watch restoration
        // and automatic workspace services. A cold Finder action never enters
        // this explicit workspace presentation path.
        Task { @MainActor [weak self, weak controller] in
            await GitConfigurationPermissions.restoreForGitReads()
            guard !Task.isCancelled, let self, let controller, self.storedController === controller,
                  self.storedModel === controller.model, !controller.model.isRetired,
                  let window = controller.window, window.isVisible else { return }
            controller.model.startWorkspaceServices()
            self.installWorkspaceServices(window)
        }
    }
}

/// One native owner survives ordinary Close, including its child Git operations.
/// Settings-only scenes avoid an automatic window for document/URL launches on
/// every supported macOS version, including macOS 13 and 14.
@MainActor final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate {
    let model: RepositoryModel
    private weak var applicationDelegate: TurtleGitApplicationDelegate?
    private var updates: AnyCancellable?
    var presentWindow: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    static let toolbarIdentifiers: [NSToolbarItem.Identifier] = ["TurtleGitOpen", "TurtleGitRefresh", "TurtleGitCommit", "TurtleGitLog"].map { NSToolbarItem.Identifier($0) }
    init(model: RepositoryModel, appearance: AppAppearance, applicationDelegate: TurtleGitApplicationDelegate) {
        self.model = model; self.applicationDelegate = applicationDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "TurtleGit for Mac"
        window.identifier = NSUserInterfaceItemIdentifier("workspace")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 920, height: 650)
        window.contentViewController = NSHostingController(rootView: WorkspaceHostedContent(model: model, applicationDelegate: applicationDelegate))
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "TurtleGitWorkspace")
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        updates = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshToolbar() }
        }
        refreshToolbar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        guard let window else { return }
        DialogGeometry.attach(window, identifier: "workspace")
        model.workspaceWindow = window
        presentWindow(window)
        applicationDelegate?.workspaceWindowDidAttach()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarIdentifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarIdentifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = Self.toolbarIdentifiers.firstIndex(of: identifier) else { return nil }
        let captions = ["Open", "Refresh", "Commit", "Show log"]
        let symbols = ["folder", "arrow.clockwise", "checkmark.circle", "clock"]
        let actions: [Selector] = [#selector(openRepository), #selector(refresh), #selector(commit), #selector(showLog)]
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = NSLocalizedString(captions[index], comment: "")
        item.paletteLabel = item.label; item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: item.label)
        item.target = self; item.action = actions[index]
        item.autovalidates = false
        item.isEnabled = toolbarEnabled(index)
        return item
    }
    private func toolbarEnabled(_ index: Int?) -> Bool {
        !model.busy && !model.confirmingQuit &&
            (index == 0 || model.root != nil) && (index != 2 || !model.bare)
    }
    private func refreshToolbar() {
        for item in window?.toolbar?.items ?? [] {
            item.isEnabled = toolbarEnabled(Self.toolbarIdentifiers.firstIndex(of: item.itemIdentifier))
        }
    }
    @objc private func openRepository() { guard !model.busy, !model.confirmingQuit else { return }; model.chooseRepository() }
    @objc private func refresh() { guard model.root != nil, !model.busy, !model.confirmingQuit else { return }; Task { await model.refresh() } }
    @objc private func commit() { guard model.root != nil, !model.busy, !model.bare, !model.confirmingQuit else { return }; model.activate(.commit) }
    @objc private func showLog() { guard model.root != nil, !model.busy, !model.confirmingQuit else { return }; model.activate(.log) }
}

@MainActor private struct WorkspaceHostedContent: View {
    @ObservedObject var model: RepositoryModel
    let applicationDelegate: TurtleGitApplicationDelegate
    var body: some View {
        RepositoryWindow(model: model, onWorkspaceWindowAttached: applicationDelegate.workspaceWindowDidAttach)
            .disabled(model.confirmingQuit)
            #if DEBUG
            .onAppear {
                if Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true, model.root == nil,
                   let path = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationRepository") as? String {
                    model.open(URL(fileURLWithPath: path, isDirectory: true)) {
                        if let request = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationRequest") as? String,
                           let url = URL(string: request), FinderRequest(url: url) != nil { model.handle(url) }
                    }
                }
            }
            #endif
    }
}

/// Use the same parser for scene selection and command delivery. A recognized
/// but malformed Merge request still belongs to the tool, so its error exits
/// without briefly opening a repository workspace.
enum TurtleGitLaunchMode: Equatable {
    case workspace, mergeTool, unifiedDiff, actionOnly
    static func resolve(arguments: [String], currentDirectory: String) -> Self {
        // Recognize malformed private envelopes too, so they report an action
        // error instead of accidentally becoming a default workspace launch.
        if arguments.contains(FinderActionDelivery.argumentFlag) { return .actionOnly }
        do { if try UnifiedDiffInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) != nil { return .unifiedDiff } }
        catch { return .unifiedDiff }
        do { if try MergeToolInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) != nil { return .mergeTool } }
        catch { return .mergeTool }
        if arguments == ["--turtlegit-action-only"] { return .actionOnly }
        do { if try PrimaryCommandInvocation.parse(arguments:arguments,currentDirectory:currentDirectory) != nil { return .actionOnly } }
        catch { return .actionOnly }
        return .workspace
    }
}

/// Only Save All needs an application-level supplement: the existing editor
/// contributions already own Open, Save, Save As, Edit, Navigate, View and Help.
/// Re-resolve the actual key window at invocation rather than retaining a command
/// against a previously focused/retired editor. Settings and sheets cannot save a
/// background document.
@MainActor final class MergeToolMenuContext: ObservableObject {
    @Published private(set) var canSaveAll = false
    @Published private(set) var canClose = false
    private let keyWindow: () -> NSWindow?
    private var notifications: [AnyCancellable] = []
    private var modelChanges: AnyCancellable?
    private weak var observedModel: AnyObject?
    init(keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow = keyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSApplication.didUpdateNotification] {
            notifications.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private func comparison(in window: NSWindow) -> FileComparisonWindowController? {
        guard let owner = window.delegate as? FileComparisonWindowController,
              owner.window === window, window.attachedSheet == nil,
              owner.editorOpenWorkflow == nil, !owner.preparingReplacement,
              owner.model.contextCommandsAllowed, !owner.model.filtering,
              !owner.model.mergeToolReadOnly, owner.model.dirty else { return nil }
        return owner
    }
    private func conflict(in window: NSWindow) -> TextConflictWindowController? {
        guard let owner = window.delegate as? TextConflictWindowController,
              owner.window === window, window.attachedSheet == nil,
              owner.editorOpenWorkflow == nil, !owner.preparingReplacement,
              owner.model.sourceToolsAllowed, owner.model.sourceMutationsAllowed,
              !owner.model.mergeToolHasPendingWork, !owner.model.confirmingQuit,
              !owner.model.patchResultCompleted, owner.model.hasUnsavedEditorWork else { return nil }
        return owner
    }
    private func closableWindow() -> NSWindow? {
        guard let window = keyWindow(), window.isVisible, window.styleMask.contains(.closable), window.attachedSheet == nil else { return nil }
        if let owner = window.delegate as? FileComparisonWindowController {
            guard owner.window === window, owner.model.copyCommandsAllowed, !owner.model.confirmingQuit,
                  !owner.preparingReplacement, owner.editorOpenWorkflow == nil else { return nil }
        } else if let owner = window.delegate as? TextConflictWindowController {
            guard owner.window === window, !owner.model.retired, !owner.model.confirmingQuit,
                  !owner.preparingReplacement, owner.editorOpenWorkflow == nil else { return nil }
        } else if let owner = window.delegate as? WorkingTreePatchWindowController {
            guard owner.window === window, owner.commandsAvailable, !owner.model.confirmingQuit else { return nil }
        } else if let owner = window.delegate as? MergeOpenWindowController {
            guard owner.window === window else { return nil }
        } else if let owner = window.delegate as? ReviewPatchWorkflow {
            guard owner.window === window else { return nil }
        } else if let owner = window.delegate as? TurtleGitAboutController {
            guard owner.window === window, !owner.retired else { return nil }
        } else if let navigation = window.contentViewController as? SettingsNavigationController {
            // Each scoped service has its own delegate proxy and draft. Admit
            // that exact native owner rather than borrowing shared Settings.
            guard navigation.view.window === window, navigation.canDismiss,
                  !navigation.completionPending else { return nil }
        } else { return nil }
        return window
    }
    @discardableResult func close() -> Bool {
        guard let window = closableWindow() else { refresh(); return false }
        // Always preserve each controller's dirty-save and in-flight load
        // cancellation policy. A dispatched Close can legitimately be refused
        // or finish asynchronously; it never force-closes its owner.
        window.performClose(nil); refresh(); return true
    }
    func refresh() {
        let window = keyWindow()
        let model: AnyObject?
        let changes: ObservableObjectPublisher?
        if let owner = window?.delegate as? FileComparisonWindowController { model = owner.model; changes = owner.model.objectWillChange }
        else if let owner = window?.delegate as? TextConflictWindowController { model = owner.model; changes = owner.model.objectWillChange }
        else { model = nil; changes = nil }
        if observedModel !== model {
            modelChanges = nil; observedModel = model
            modelChanges = changes?.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
        let next = window.map { ($0.firstResponder as? NSTextView)?.isFieldEditor != true && (comparison(in: $0) != nil || conflict(in: $0) != nil) } ?? false
        if canSaveAll != next { canSaveAll = next }
        let closeAvailable = closableWindow() != nil
        if canClose != closeAvailable { canClose = closeAvailable }
    }
    @discardableResult func saveAll() -> Bool {
        refresh()
        guard let window = keyWindow(), (window.firstResponder as? NSTextView)?.isFieldEditor != true else { return false }
        if let owner = comparison(in: window) { owner.model.saveAll(); return true }
        if let owner = conflict(in: window) { owner.model.saveRetainedEditorWork(); return true }
        return false
    }
}

/// Five command domains, below the hosted SDK's ten-child builder limit. The
/// Settings-only tool Scene supplies the normal macOS Close/Edit/Window/Quit
/// commands; focused AppKit Merge controllers contribute their source menus.
struct MergeToolBaseCommands: Commands {
    @ObservedObject var context: MergeToolMenuContext
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Close") { context.close() }
                .keyboardShortcut("w").disabled(!context.canClose)
        }
        CommandGroup(replacing: .saveItem) {
            Button { context.saveAll() } label: { CommandLabel(title: "Save All", icon: .mergeSave) }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!context.canSaveAll)
        }
        CommandGroup(replacing: .appSettings) { }
        CommandGroup(replacing: .appInfo) {
            Button("About TurtleGitMerge…") { TurtleGitAboutService.shared.show(.merge) }
        }
        CommandGroup(replacing: .help) {
            Button("TurtleGit Help") { TurtleGitHelp.showContext() }.keyboardShortcut("?", modifiers: .command)
        }
    }
}
