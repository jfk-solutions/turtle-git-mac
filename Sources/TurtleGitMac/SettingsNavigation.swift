// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore
import Combine

/// Native projection of Settings.cpp's tree for pages currently implemented.
/// Pending pages are tracked in the inventory, rather than shown as empty panes.
enum SettingsPageID: String {
    case general, dialogs, dialogs2, dialogs3, colors1, colors2, colors3, commit, alternativeEditor, git, remote, email, diff
    case credential, network, contextMenu, contextMenu2, overlays, overlayHandlers, overlayIcons, mergeTool, mergeEditor, mergeColors, savedData, blame, unifiedDiff, advanced
    var applyOrder: Int { let pages: [SettingsPageID] = [.general, .contextMenu, .contextMenu2, .dialogs, .dialogs2, .dialogs3, .colors1, .colors2, .colors3, .commit, .alternativeEditor, .overlays, .overlayHandlers, .overlayIcons, .git, .remote, .credential, .network, .email, .diff, .mergeTool, .mergeEditor, .mergeColors, .savedData, .blame, .unifiedDiff, .advanced]; return pages.firstIndex(of: self)! }
}
private final class SettingsPageNode: NSObject {
    let id: SettingsPageID, title: String, icon: MenuIcon
    let children: [SettingsPageNode]
    init(_ id: SettingsPageID, _ title: String, _ icon: MenuIcon, children: [SettingsPageNode] = []) {
        self.id = id; self.title = title; self.icon = icon; self.children = children
    }
}
struct SettingsNavigation: NSViewControllerRepresentable {
    @ObservedObject var workspace: RepositoryModel
    @ObservedObject var appearance: AppAppearance
    func makeNSViewController(context: Context) -> SettingsNavigationController { SettingsNavigationController(workspace: workspace, appearance: appearance) }
    func updateNSViewController(_ controller: SettingsNavigationController, context: Context) { controller.updateRepository() }
    static func dismantleNSViewController(_ controller: SettingsNavigationController, coordinator: ()) { controller.invalidate() }
}
@MainActor final class SettingsNavigationController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let workspace: RepositoryModel, appearance: AppAppearance
    let globalOnly: Bool
    private let appearanceDraft: SettingsAppearanceDraft
    private let overlayDraft = FinderOverlaySettingsModel()
    private let contextMenuDraft = FinderContextMenuSettingsModel()
    private let outline = NSOutlineView()
    private let content = NSView()
    private let busyShield = SettingsBusyShield()
    private let heading = NSTextField(labelWithString: "General")
    let transaction = SettingsTransaction()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var roots: [SettingsPageNode] = []
    private var cache: [SettingsPageID: NSViewController] = [:]
    private var current: NSViewController?
    private(set) var selected: SettingsPageID = .general
    private var repositoryPath: String?
    private var remote: RemoteSettingsWindowModel?
    private var delegateProxy: SettingsWindowDelegate?
    private var updating = false
    init(workspace: RepositoryModel, appearance: AppAppearance, globalOnly: Bool = false) { self.workspace = workspace; self.appearance = appearance; self.globalOnly = globalOnly; self.appearanceDraft = SettingsAppearanceDraft(appearance: appearance); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = NSView(); view.setAccessibilityLabel("TurtleGit settings")
        let column = NSTableColumn(identifier: .init("page")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self; outline.rowHeight = 28
        outline.allowsMultipleSelection = false; outline.allowsEmptySelection = false; outline.selectionHighlightStyle = .sourceList
        outline.setAccessibilityLabel("Settings pages")
        let sidebar = NSScrollView(); sidebar.documentView = outline; sidebar.hasVerticalScroller = true; sidebar.autohidesScrollers = true
        sidebar.drawsBackground = false
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        for (button, action) in [(okButton, #selector(acceptSettings)), (cancelButton, #selector(cancelSettings)), (applyButton, #selector(applySettings))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        okButton.keyEquivalent = "\r"; cancelButton.keyEquivalent = "\u{1b}"
        errorLabel.textColor = .systemRed
        let footer = NSStackView(views: [errorLabel, NSView(), okButton, cancelButton, applyButton]); footer.orientation = .horizontal; footer.spacing = 8
        let right = NSStackView(views: [heading, NSBox(), content, footer]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        footer.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        transaction.changed = { [weak self] in self?.renderFooter() }
        transaction.failed = { [weak self] page in
            guard let self else { return }; self.show(page)
            if let node = self.nodes.first(where: { $0.id == page }) { let row = self.outline.row(forItem: node); if row >= 0 { self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
        }
        transaction.completed = { [weak self] close in if close { self?.view.window?.performClose(nil) } }
        (right.arrangedSubviews[1] as? NSBox)?.boxType = .separator
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(sidebar); split.addArrangedSubview(right)
        split.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: view.topAnchor), split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 190), sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            content.widthAnchor.constraint(equalTo: right.widthAnchor), right.widthAnchor.constraint(greaterThanOrEqualToConstant: 730),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 640)
        ])
        split.setPosition(220, ofDividerAt: 0)
        rebuildTree(); show(.general); renderFooter()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, delegateProxy == nil else { return }
        let proxy = SettingsWindowDelegate(owner: self, original: window.delegate); delegateProxy = proxy; window.delegate = proxy
        transaction.window = window
        window.title = globalOnly ? "Global Settings – TurtleGit for Mac" : "Settings – TurtleGit for Mac"
    }
    var canDismiss: Bool { !transaction.busy && remote?.busy != true && remote?.hasChild != true && GitConfigurationSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeSaves == 0 && NetworkSettingsModel.activeSaves == 0 && view.window?.attachedSheet == nil }
    func updateRepository() {
        guard !globalOnly, isViewLoaded, workspace.root?.path != repositoryPath else { return }
        // A captured Remote model belongs to the repository that created it.
        remote?.invalidate()
        if selected == .remote, let window = view.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        remote = nil; cache.removeValue(forKey: .remote); transaction.unregister("remote")
        transaction.unregister("git"); transaction.unregister("dialogs3")
        transaction.unregister("credential"); cache.removeValue(forKey: .credential)
        transaction.unregister("network"); cache.removeValue(forKey: .network)
        cache.removeValue(forKey: .git); cache.removeValue(forKey: .dialogs3)
        if [.remote, .git, .dialogs3, .credential, .network].contains(selected) {
            current?.view.removeFromSuperview(); current?.removeFromParent(); current = nil
            show(selected == .remote ? .git : selected)
        }
        rebuildTree()
    }
    private func rebuildTree() {
        repositoryPath = workspace.root?.path
        roots = [
            SettingsPageNode(.general, "General", .settingsGeneral, children: [
                SettingsPageNode(.contextMenu, "Context Menu", .settingsContextMenu),
                SettingsPageNode(.contextMenu2, "Context Menu 2", .settingsContextMenu),
                SettingsPageNode(.dialogs, "Dialogs 1", .settingsDialogs),
                SettingsPageNode(.dialogs2, "Dialogs 2", .settingsDialogs),
                SettingsPageNode(.dialogs3, "Dialogs 3", .settingsDialogs),
                SettingsPageNode(.colors1, "Colors 1", .settingsColors),
                SettingsPageNode(.colors2, "Colors 2", .settingsColors),
                SettingsPageNode(.colors3, "Colors 3", .settingsColors),
                SettingsPageNode(.commit, "Message Editor", .editor),
                SettingsPageNode(.alternativeEditor, "Alternative Editor", .editor)]),
            SettingsPageNode(.git, "Git", .settingsGit, children: (globalOnly || workspace.root == nil ? [] : [SettingsPageNode(.remote, "Remote", .settingsRemote)]) + [SettingsPageNode(.credential, "Credential", .settingsCredential)]),
            SettingsPageNode(.network, "Network", .settingsNetwork),
            SettingsPageNode(.overlays, "Icon Overlays", .settingsOverlays, children: [SettingsPageNode(.overlayIcons, "Icon Set", .settingsOverlays), SettingsPageNode(.overlayHandlers, "Overlay Handlers", .settingsOverlays)]),
            SettingsPageNode(.email, "Email", .sendMail),
            SettingsPageNode(.diff, "Diff Viewer", .compare, children: [SettingsPageNode(.mergeTool, "Merge Tool", .merge), SettingsPageNode(.mergeEditor, "Merge Editor", .merge, children: [SettingsPageNode(.mergeColors, "Colors", .settingsColors)])]),
            SettingsPageNode(.savedData, "Saved Data", .settingsSavedData), SettingsPageNode(.blame, "TortoiseGitBlame", .blame),
            SettingsPageNode(.unifiedDiff, "Unified Diff", .settingsUnifiedDiff), SettingsPageNode(.advanced, "Advanced", .settingsGeneral)
        ]
        updating = true; outline.reloadData(); roots.forEach { outline.expandItem($0) }
        if let node = nodes.first(where: { $0.id == selected }) { let row = outline.row(forItem: node); if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
        updating = false
    }
    private var nodes: [SettingsPageNode] { roots.flatMap { [$0] + $0.children } }
    private func renderFooter() {
        applyButton.isEnabled = !transaction.busy && transaction.modified
        okButton.isEnabled = !transaction.busy; cancelButton.isEnabled = !transaction.busy
        errorLabel.stringValue = transaction.error ?? ""
        let wasHidden = busyShield.isHidden
        busyShield.isHidden = !transaction.busy
        if transaction.busy && wasHidden { view.window?.makeFirstResponder(busyShield) }

    }
    @objc private func applySettings() { guard canDismiss else { return }; view.window?.makeFirstResponder(nil); transaction.apply(closeAfter: false) }
    @objc private func acceptSettings() { guard canDismiss else { return }; view.window?.makeFirstResponder(nil); transaction.apply(closeAfter: true) }
    @objc private func cancelSettings() { guard canDismiss else { return }; view.window?.makeFirstResponder(nil); transaction.cancel(); view.window?.performClose(nil) }
    private func host<V: View>(_ view: V) -> NSViewController { NSHostingController(rootView: view.environment(\.settingsTransaction, transaction)) }
    private func show(_ page: SettingsPageID) {
        guard view.window?.attachedSheet == nil, remote?.busy != true, remote?.hasChild != true, GitConfigurationSettingsModel.activeSaves == 0, CredentialSettingsModel.activeSaves == 0, NetworkSettingsModel.activeSaves == 0 else { return }
        if current != nil && selected == page { return }
        view.window?.makeFirstResponder(nil)
        let controller: NSViewController
        if let existing = cache[page] { controller = existing }
        else {
            switch page {
            case .general: controller = host(GeneralSettings(appearance: appearanceDraft))
            case .colors1, .colors2, .colors3: controller = host(SourceColorSettings(page: page, appearance: appearanceDraft))
            case .dialogs: controller = host(LogDialogSettings())
            case .dialogs2: controller = host(DialogsBehaviorSettings())
            case .dialogs3: controller = host(ProjectDialogSettingsPage(workspace: workspace, globalOnly: globalOnly))
            case .commit: controller = host(CommitEditorSettings(editorOnly: true))
            case .alternativeEditor: controller = host(AlternativeEditorSettings())
            case .git: controller = host(GitConfigurationSettingsPage(workspace: workspace, globalOnly: globalOnly))
            case .credential:
                guard let context = try? workspace.gitConfigurationContext(globalOnly: globalOnly) else { return }
                controller = host(CredentialSettingsPage(model: CredentialSettingsModel(repository: context.repository, access: context.access, localAvailable: context.localAvailable)))
            case .network:
                guard let context = try? workspace.gitConfigurationContext(globalOnly: globalOnly) else { return }
                controller = host(NetworkSettingsPage(model: NetworkSettingsModel(repository: context.repository, access: context.access, localAvailable: context.localAvailable)))
            case .overlays: controller = host(FinderOverlaySettingsPage(model: overlayDraft))
            case .overlayHandlers: controller = host(FinderOverlaySettingsPage(model: overlayDraft, handlersOnly: true))
            case .overlayIcons: controller = host(FinderOverlaySettingsPage(model: overlayDraft, iconsOnly: true))
            case .contextMenu: controller = host(FinderContextMenuSettingsPage(model: contextMenuDraft))
            case .contextMenu2: controller = host(FinderContextMenuSettingsPage(model: contextMenuDraft, extendedOnly: true))
            case .email: controller = host(EmailSettingsPage())
            case .diff: controller = host(DiffToolSettings())
            case .mergeTool: controller = host(MergeToolSettings())
            case .mergeEditor: controller = host(MergeEditorSettings())
            case .mergeColors: controller = host(MergeColorsSettings())
            case .savedData: controller = host(SavedDataSettingsPage())
            case .blame: controller = host(BlameSettings())
            case .unifiedDiff: controller = host(UnifiedDiffAppearanceSettings())
            case .advanced: controller = host(AdvancedSettingsPage())
            case .remote:
                guard let context = try? workspace.gitConfigurationContext(), context.localAvailable else { return }
                let model = RemoteSettingsWindowModel(repository: context.repository, access: context.access)
                remote = model; workspace.configureSettingsRemote(model)
                model.close = { [weak self] in guard let self, self.canDismiss else { return }; self.view.window?.performClose(nil) }
                controller = NSViewController(); controller.view = RemoteSettingsNativeView(model: model, embeddedSettings: true)
                let render = model.updated
                model.updated = { [weak transaction] in render(); transaction?.notify() }
                transaction.register("remote", participant: .init(page: .remote, modified: { !model.changed.isEmpty },
                    validate: { model.busy || model.hasChild ? "Finish the Remote operation first." : nil },
                    apply: { await model.applyForSettings() }, cancel: model.invalidate))
                model.load()
            }
            cache[page] = controller
        }
        current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(controller); content.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor), controller.view.topAnchor.constraint(equalTo: content.topAnchor), controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        if busyShield.superview == nil {
            busyShield.translatesAutoresizingMaskIntoConstraints = false; busyShield.isHidden = !transaction.busy
            content.addSubview(busyShield)
            NSLayoutConstraint.activate([busyShield.leadingAnchor.constraint(equalTo: content.leadingAnchor), busyShield.trailingAnchor.constraint(equalTo: content.trailingAnchor), busyShield.topAnchor.constraint(equalTo: content.topAnchor), busyShield.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        } else { content.addSubview(busyShield, positioned: .above, relativeTo: controller.view) }
        current = controller; selected = page; heading.stringValue = nodes.first(where: { $0.id == page })?.title ?? page.rawValue
    }
    func invalidate() {
        transaction.invalidate()
        remote?.invalidate(); remote = nil
        if let window = view.window, let delegateProxy, window.delegate === delegateProxy { window.delegate = delegateProxy.original }
        delegateProxy = nil; current?.view.removeFromSuperview(); current?.removeFromParent(); current = nil; cache.removeAll()
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SettingsPageNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SettingsPageNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SettingsPageNode)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SettingsPageNode else { return nil }
        let image = NSImageView(); image.image = node.icon.image(); image.imageScaling = .scaleProportionallyDown
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true; image.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let text = NSTextField(labelWithString: node.title); text.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [image, text]); row.orientation = .horizontal; row.spacing = 7
        row.setAccessibilityLabel(node.title); return row
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { updating || canDismiss }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let node = outline.item(atRow: outline.selectedRow) as? SettingsPageNode else { return }; show(node.id)
    }
}
/// App-menu and Finder Settings use one native property-sheet owner. Closing it
/// discards drafts; reopening creates a fresh transaction and page cache.
@MainActor final class SettingsPresentationService: NSObject, NSWindowDelegate {
    static let shared = SettingsPresentationService()
    private weak var workspace: RepositoryModel?
    private weak var appearance: AppAppearance?
    private var controller: NSWindowController?
    private var navigation: SettingsNavigationController?
    private var updates: AnyCancellable?
    func install(workspace: RepositoryModel, appearance: AppAppearance) {
        self.workspace = workspace; self.appearance = appearance
        workspace.onSettings = { Self.shared.show(globalOnly: $0) }
        workspace.canChangeSettingsContext = { Self.shared.prepareContextChange() }
        workspace.onHelp = { Self.showHelp() }
        workspace.onAbout = { Self.showAbout() }
    }
    func prepareContextChange() -> Bool {
        guard let navigation else { return true }
        guard navigation.canDismiss, !navigation.transaction.modified else {
            controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
            if let window = controller?.window, window.attachedSheet == nil {
                let alert = NSAlert(); alert.messageText = "Finish the current Settings first"
                alert.informativeText = "Close the current Settings window before opening settings for a different context. Unsaved changes and active operations are retained."
                alert.beginSheetModal(for: window)
            }
            return false
        }
        return true
    }
    func show(globalOnly: Bool = false) {
        guard let workspace, let appearance, !workspace.confirmingQuit else { return }
        if let navigation, navigation.globalOnly != globalOnly {
            guard prepareContextChange() else { return }
            controller?.window?.performClose(nil)
        }
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let navigation = SettingsNavigationController(workspace: workspace, appearance: appearance, globalOnly: globalOnly)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Settings – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 980, height: 700)
        window.delegate = self; window.contentViewController = navigation
        let controller = NSWindowController(window: window)
        self.navigation = navigation; self.controller = controller
        updates = workspace.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.navigation?.updateRepository() }
        }
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { navigation?.canDismiss == true }
    func windowWillClose(_ notification: Notification) {
        navigation?.invalidate(); updates?.cancel(); updates = nil
        navigation = nil; controller = nil
    }
    static func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://jfk-solutions.github.io/turtle-git-mac/")!)
    }
    static func showAbout() {
        let credits = NSMutableAttributedString(string: "A macOS fork of TortoiseGit\nLicensed under GNU GPL v2.\n\nOriginal Git UI and artwork: TortoiseGit.\nOriginal overlay artwork: TortoiseSVN and credited icon contributors.\n\n")
        credits.append(NSAttributedString(string: "Project and source code", attributes: [.link: URL(string: "https://github.com/jfk-solutions/turtle-git-mac")!]))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "TurtleGit for Mac", .credits: credits])
    }
}

@MainActor private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    weak var owner: SettingsNavigationController?
    nonisolated(unsafe) let original: NSWindowDelegate?
    init(owner: SettingsNavigationController, original: NSWindowDelegate?) { self.owner = owner; self.original = original }
    func windowShouldClose(_ sender: NSWindow) -> Bool { owner?.canDismiss == true && (original?.windowShouldClose?(sender) ?? true) }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        original?.windowWillClose?(notification); owner?.invalidate()
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

/// Captures pointer and keyboard input while a property-sheet save is in flight.
/// Owned confirmation sheets remain interactive above the Settings window.
@MainActor private final class SettingsBusyShield: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
}

/// Implemented SetDialogs2 preferences, kept separate from message-editor extras.
@MainActor private final class DialogsBehaviorDraft: ObservableObject {
    @Published var values: [String: SettingsScalar]
    private var saved: [String: SettingsScalar]
    static let booleans: [(String, Bool)] = [
        ("RevertWithRecycleBin", true), ("ConfirmKillProcess", false),
        ("SyncDialogRandomPos", false), ("BranchesIncludeFetchHead", true), ("UseMailmap", true), ("NoSounds", false),
        ("RefCompareHideUnchanged", false), ("ShowGitexeTimings", true),
        ("SortTagsReversed", false), ("Autocompletion", true),
        ("SelectFilesForCommit", true), ("AutoselectMissingFiles", false),
        ("StripCommentedLines", false)
    ]
    init(defaults: UserDefaults = .standard) {
        var initial: [String: SettingsScalar] = [:]
        for (key, fallback) in Self.booleans { initial[key] = .boolean((defaults.object(forKey: key) as? NSNumber)?.boolValue ?? fallback) }
        for (key, fallback) in [("AutoCloseGitProgress", 0), ("AutocompleteParseTimeout", 5), ("MaxHistoryItems", 25)] {
            initial[key] = .integer((defaults.object(forKey: key) as? NSNumber)?.intValue ?? fallback)
        }
        // Migrate the earlier Commit-only history limit to the source shared key.
        if defaults.object(forKey: "MaxHistoryItems") == nil, let old = defaults.object(forKey: "Commit.MaxHistoryItems") as? NSNumber { initial["MaxHistoryItems"] = .integer(old.intValue) }
        values = initial; saved = initial
    }
    var modified: Bool { values != saved }
    func boolean(_ key: String) -> Binding<Bool> {
        Binding(get: { if case .boolean(let value) = self.values[key] { return value }; return false }, set: { self.values[key] = .boolean($0) })
    }
    func integer(_ key: String) -> Binding<Int> {
        Binding(get: { if case .integer(let value) = self.values[key] { return value }; return 0 }, set: { self.values[key] = .integer($0) })
    }
    var validationError: String? {
        for key in ["AutocompleteParseTimeout", "MaxHistoryItems"] {
            guard case .integer(let value) = values[key], (1...100).contains(value) else {
                return "Enter a value from 1 to 100 for " + (key == "MaxHistoryItems" ? "message history items." : "auto-completion timeout.")
            }
        }
        return nil
    }
    func apply() { for (key, value) in values { value.save(key) }; saved = values }
    func cancel() { values = saved }
}
private struct DialogsBehaviorSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var draft = DialogsBehaviorDraft()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Misc") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Autoclose Git progress dialog:", selection: draft.integer("AutoCloseGitProgress")) {
                            ForEach(GitProgressAutoClose.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        Toggle("Use Trash when reverting", isOn: draft.boolean("RevertWithRecycleBin"))
                        Toggle("Confirm to kill running git process", isOn: draft.boolean("ConfirmKillProcess"))
                        Toggle("Randomize Sync Dialog startup position", isOn: draft.boolean("SyncDialogRandomPos"))
                        Toggle("Hide unchanged refs in Ref Compare List", isOn: draft.boolean("RefCompareHideUnchanged"))
                        Toggle("Show Git execution timings and timestamp", isOn: draft.boolean("ShowGitexeTimings"))
                        Toggle("Sort tag list in reversed order", isOn: draft.boolean("SortTagsReversed"))
                        Toggle("Disable sounds", isOn: draft.boolean("NoSounds"))
                        Toggle("Include FETCH_HEAD in branch selection boxes", isOn: draft.boolean("BranchesIncludeFetchHead"))
                        Toggle("Use .mailmap", isOn: draft.boolean("UseMailmap"))
                    }.padding(8)
                }
                GroupBox("Commit") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Use auto-completion of file paths and keywords", isOn: draft.boolean("Autocompletion"))
                        Stepper("Timeout in seconds to stop auto-completion parsing: \(draft.integer("AutocompleteParseTimeout").wrappedValue)", value: draft.integer("AutocompleteParseTimeout"), in: 1...100)
                            .disabled(!draft.boolean("Autocompletion").wrappedValue)
                        Stepper("Max. items to keep in the log message history: \(draft.integer("MaxHistoryItems").wrappedValue)", value: draft.integer("MaxHistoryItems"), in: 1...100)
                        Toggle("Select items automatically", isOn: draft.boolean("SelectFilesForCommit"))
                        Toggle("Do not auto-select \"missing\" files (deleted, but unstaged)", isOn: draft.boolean("AutoselectMissingFiles"))
                        Toggle("Strip lines starting with \"#\" in commit message", isOn: draft.boolean("StripCommentedLines"))
                    }.padding(8)
                }
                Spacer()
            }.padding(20)
        }
        .settingsParticipant("dialogs2", page: .dialogs2, value: draft.values, modified: { draft.modified }, validate: { draft.validationError },
            apply: { draft.apply(); return true }, cancel: draft.cancel)
    }
}
