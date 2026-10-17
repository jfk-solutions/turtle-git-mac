// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore
import Combine

/// Native projection of Settings.cpp's tree for pages currently implemented.
/// Pending pages are tracked in the inventory, rather than shown as empty panes.
enum SettingsPageID: String {
    case general, dialogs, dialogs2, dialogs3, colors1, colors2, colors3, commit, alternativeEditor, git, remote, email, diff
    case hooks, issueProviders, issueTracker, credential, network, contextMenu, contextMenu2, overlays, overlayHandlers, overlayIcons, watchedRepositories, mergeTool, mergeEditor, mergeColors, savedData, blame, unifiedDiff, advanced
    var minimumPageWidth:CGFloat {
        switch self {
        case .colors1, .colors2, .colors3, .mergeColors, .blame, .unifiedDiff: return 600
        default: return 730
        }
    }
    var applyOrder: Int { let pages: [SettingsPageID] = [.general, .contextMenu, .contextMenu2, .dialogs, .dialogs2, .dialogs3, .colors1, .colors2, .colors3, .commit, .alternativeEditor, .overlays, .overlayHandlers, .overlayIcons, .git, .remote, .hooks, .issueProviders, .issueTracker, .credential, .network, .email, .diff, .mergeTool, .mergeEditor, .mergeColors, .savedData, .blame, .unifiedDiff, .advanced]; return pages.firstIndex(of: self)! }
}
private final class SettingsPageNode: NSObject {
    let id: SettingsPageID, title: String, icon: MenuIcon
    let children: [SettingsPageNode]
    var descendants:[SettingsPageNode] { [self] + children.flatMap(\.descendants) }
    func path(to target:SettingsPageID) -> [SettingsPageNode]? {
        if id == target { return [self] }
        for child in children { if let path = child.path(to:target) { return [self] + path } }
        return nil
    }
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
    private let preferences: UserDefaults
    let globalOnly: Bool
    private let appearanceDraft: SettingsAppearanceDraft
    private let overlayDraft: FinderOverlaySettingsModel
    private let emailDraft: EmailSettingsModel
    private let contextMenuDraft: FinderContextMenuSettingsModel
    private let outline = NSOutlineView()
    private let content = SettingsPageViewport()
    private let pageSplit = NSSplitView()
    private var positionedDivider = false
    private var pageOrigins:[SettingsPageID:CGPoint] = [:]
    private let busyShield = SettingsBusyShield()
    private let heading = NSTextField(labelWithString: "General")
    let transaction = SettingsTransaction()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let helpButton = NSButton(title: "Help", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var roots: [SettingsPageNode] = []
    private var cache: [SettingsPageID: NSViewController] = [:]
    private var current: NSViewController?
    private(set) var selected: SettingsPageID = .general
    private var repositoryPath: String?
    private var remote: RemoteSettingsWindowModel?
    private var hooks: HookSettingsModel?
    private var delegateProxy: SettingsWindowDelegate?
    private var updating = false
    private var retired = false
    init(workspace: RepositoryModel, appearance: AppAppearance, globalOnly: Bool = false, preferences: UserDefaults = .standard, initialPage: SettingsPageID = .general, smtpCredentials: any SMTPCredentialStore = SMTPKeychainStore()) {
        overlayDraft = FinderOverlaySettingsModel(preferences:preferences)
        emailDraft = EmailSettingsModel(preferences:preferences,credentials:smtpCredentials)
        contextMenuDraft = FinderContextMenuSettingsModel(defaults:preferences)
        self.selected = initialPage; self.preferences = preferences; self.workspace = workspace; self.appearance = appearance; self.globalOnly = globalOnly; self.appearanceDraft = SettingsAppearanceDraft(appearance: appearance); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        // NSWindow adopts the controller view’s current size on assignment.
        // A real initial frame must not depend on the page’s minimum constraints.
        view = NSView(frame:NSRect(x:0,y:0,width:1040,height:740)); view.setAccessibilityLabel("TurtleGit settings")
        let column = NSTableColumn(identifier:.init("page")); column.minWidth = 0; column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self; outline.rowHeight = 28
        outline.allowsMultipleSelection = false; outline.allowsEmptySelection = false; outline.selectionHighlightStyle = .sourceList
        outline.setAccessibilityLabel("Settings pages")
        let sidebar = NSScrollView(); sidebar.documentView = outline; sidebar.hasVerticalScroller = true; sidebar.autohidesScrollers = true
        sidebar.drawsBackground = false
        heading.font = .systemFont(ofSize:17,weight:.semibold)
        heading.identifier = .init("Settings.PageHeading"); heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for (button, action) in [(okButton, #selector(acceptSettings)), (cancelButton, #selector(cancelSettings)), (applyButton, #selector(applySettings)), (helpButton, #selector(showPageHelp))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.setContentCompressionResistancePriority(.required,for:.horizontal)
        }
        okButton.keyEquivalent = "\r"; cancelButton.keyEquivalent = "\u{1b}"
        errorLabel.textColor = .systemRed
        let footer = NSStackView(views: [errorLabel, NSView(), okButton, cancelButton, applyButton, helpButton]); footer.orientation = .horizontal; footer.spacing = 8
        // Stack views align controls by alignment rects, whose bezel/focus-frame
        // insets differ across macOS releases. Reserve space for the entire
        // native button frames at the property sheet's edges.
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top:8,left:0,bottom:8,right:0)
        let right = NSStackView(views: [heading, NSBox(), content, footer]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8; right.distribution = .fill
        right.edgeInsets = NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        content.setContentHuggingPriority(.defaultLow,for:.vertical)
        heading.setContentHuggingPriority(.required,for:.vertical); footer.setContentHuggingPriority(.required,for:.vertical)
        heading.widthAnchor.constraint(lessThanOrEqualTo:right.widthAnchor,constant:-24).isActive = true
        footer.widthAnchor.constraint(equalTo: right.widthAnchor,constant:-24).isActive = true
        transaction.changed = { [weak self] in self?.renderFooter() }
        transaction.failed = { [weak self] page in
            guard let self, !self.retired else { return }; self.show(page)
            if self.selected == page { self.reveal(page) }
        }
        transaction.completed = { [weak self] close in if close { self?.view.window?.performClose(nil) } }
        (right.arrangedSubviews[1] as? NSBox)?.boxType = .separator
        let split = pageSplit; split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(sidebar); split.addArrangedSubview(right)
        split.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: view.topAnchor), split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:190), sidebar.widthAnchor.constraint(lessThanOrEqualToConstant:320),
            content.widthAnchor.constraint(equalTo:right.widthAnchor,constant:-24), right.widthAnchor.constraint(greaterThanOrEqualToConstant:520)
        ])
        rebuildTree(); show(selected); renderFooter()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !positionedDivider, pageSplit.bounds.width >= 710 else { return }
        positionedDivider = true; pageSplit.setPosition(270,ofDividerAt:0)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !retired, let window = view.window, delegateProxy == nil else { return }
        let proxy = SettingsWindowDelegate(owner: self, original: window.delegate); delegateProxy = proxy; window.delegate = proxy
        transaction.window = window
        TurtleGitHelp.attach(window, topic: TurtleGitHelp.settingsTopic(selected))
        window.title = globalOnly ? "Global Settings – TurtleGit for Mac" : "Settings – TurtleGit for Mac"
    }
    var canDismiss: Bool { GitConfigurationSettingsModel.activeFolderChoosers == 0 && GeneralGitSettingsModel.activeDialogs == 0 && ToolApplicationChooser.activeChoosers == 0 && !retired && workspace.finderWatches?.busy != true && !emailDraft.busy && !emailDraft.editingCredentials && !transaction.busy && remote?.busy != true && remote?.hasChild != true && GitConfigurationSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeSelections == 0 && NetworkSettingsModel.activeSaves == 0 && NetworkSettingsModel.activeSSHChoosers == 0 && IssueTrackerSettingsModel.activeSaves == 0 && HookSettingsModel.activeSaves == 0 && SavedSSHAuthenticationModel.activeOperations == 0 && view.window?.attachedSheet == nil }
    func updateRepository() {
        guard !retired, !globalOnly, isViewLoaded, workspace.root?.path != repositoryPath else { return }
        // A captured Remote model belongs to the repository that created it.
        hooks?.invalidate(); hooks = nil; cache.removeValue(forKey: .hooks); transaction.unregister("hooks")
        remote?.invalidate()
        if selected == .remote, let window = view.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        remote = nil; cache.removeValue(forKey: .remote); transaction.unregister("remote")
        transaction.unregister("git"); transaction.unregister("dialogs3"); transaction.unregister("issueTracker"); cache.removeValue(forKey: .issueTracker)
        transaction.unregister("credential"); cache.removeValue(forKey: .credential)
        transaction.unregister("network"); cache.removeValue(forKey: .network)
        cache.removeValue(forKey: .git); cache.removeValue(forKey: .dialogs3)
        if [.remote, .git, .dialogs3, .hooks, .issueTracker, .credential, .network].contains(selected) {
            current?.view.removeFromSuperview(); current?.removeFromParent(); current = nil
            show(selected == .remote ? .git : selected)
        }
        rebuildTree()
    }
    private func rebuildTree() {
        let initial = roots.isEmpty
        let expanded = Set(nodes.filter { outline.isItemExpanded($0) }.map(\.id))
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
            SettingsPageNode(.hooks, "Hook Scripts", .settingsHooks),
            SettingsPageNode(.issueProviders, "Issue Tracker Integration", .settingsIssueTracker, children: [SettingsPageNode(.issueTracker, "Issue Tracker Config", .settingsIssueTracker)]),
            SettingsPageNode(.network, "Network", .settingsNetwork),
            SettingsPageNode(.overlays, "Icon Overlays", .settingsOverlays, children: [SettingsPageNode(.overlayIcons, "Icon Set", .settingsOverlays), SettingsPageNode(.overlayHandlers, "Overlay Handlers", .settingsOverlays), SettingsPageNode(.watchedRepositories, "Watched Repositories", .repositoryBrowser)]),
            SettingsPageNode(.email, "Email", .sendMail),
            SettingsPageNode(.diff, "Diff Viewer", .compare, children: [SettingsPageNode(.mergeTool, "Merge Tool", .merge), SettingsPageNode(.mergeEditor, "Merge Editor", .merge, children: [SettingsPageNode(.mergeColors, "Colors", .settingsColors)])]),
            SettingsPageNode(.savedData, "Saved Data", .settingsSavedData), SettingsPageNode(.blame, "TurtleGitBlame", .blame),
            SettingsPageNode(.unifiedDiff, "Unified Diff", .settingsUnifiedDiff), SettingsPageNode(.advanced, "Advanced", .settingsGeneral)
        ]
        updating = true; outline.reloadData()
        for node in nodes where initial ? roots.contains(node) : expanded.contains(node.id) { outline.expandItem(node) }
        updating = false; reveal(selected)
    }
    private var nodes:[SettingsPageNode] { roots.flatMap(\.descendants) }
    private func reveal(_ page:SettingsPageID) {
        guard !retired, let path = roots.compactMap({ $0.path(to:page) }).first, let node = path.last else { return }
        let previous = updating; updating = true; defer { updating = previous }
        for ancestor in path.dropLast() { outline.expandItem(ancestor) }
        let row = outline.row(forItem:node)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); outline.scrollRowToVisible(row) }
    }
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
    private func host<V: View>(_ view: V) -> NSViewController { NSHostingController(rootView: view.environment(\.settingsTransaction, transaction).defaultAppStorage(preferences)) }
    private func show(_ page: SettingsPageID) {
        guard !retired, GitConfigurationSettingsModel.activeFolderChoosers == 0, GeneralGitSettingsModel.activeDialogs == 0, ToolApplicationChooser.activeChoosers == 0, !emailDraft.busy, !emailDraft.editingCredentials, !transaction.busy, view.window?.attachedSheet == nil, remote?.busy != true, remote?.hasChild != true, GitConfigurationSettingsModel.activeSaves == 0, CredentialSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeSelections == 0, NetworkSettingsModel.activeSaves == 0 && NetworkSettingsModel.activeSSHChoosers == 0, IssueTrackerSettingsModel.activeSaves == 0 && HookSettingsModel.activeSaves == 0 && SavedSSHAuthenticationModel.activeOperations == 0 else { return }
        if current != nil && selected == page { return }
        view.window?.makeFirstResponder(nil)
        let controller: NSViewController
        if let existing = cache[page] { controller = existing }
        else {
            switch page {
            case .general: controller = host(GeneralSettings(appearance: appearanceDraft, preferences: preferences))
            case .colors1, .colors2, .colors3: controller = host(SourceColorSettings(page: page, appearance: appearanceDraft, preferences: preferences))
            case .dialogs: controller = host(LogDialogSettings(defaults: preferences))
            case .hooks:
                let draft = HookSettingsModel(preferences:preferences); hooks = draft
                guard let context = try? workspace.gitConfigurationContext(globalOnly: globalOnly) else { return }
                controller = host(HookSettingsPage(model: draft, repository: context.localAvailable ? context.repository : nil, access: context.access))
            case .dialogs2: controller = host(DialogsBehaviorSettings(defaults: preferences))
            case .dialogs3: controller = host(ProjectDialogSettingsPage(workspace: workspace, globalOnly: globalOnly, preferences: preferences))
            case .commit: controller = host(CommitEditorSettings(editorOnly: true, preferences: preferences))
            case .alternativeEditor: controller = host(AlternativeEditorSettings(preferences: preferences))
            case .git: controller = host(GitConfigurationSettingsPage(workspace: workspace, globalOnly: globalOnly, preferences: preferences))
            case .credential:
                guard let context = try? workspace.gitConfigurationContext(globalOnly: globalOnly) else { return }
                controller = host(CredentialSettingsPage(model: CredentialSettingsModel(repository: context.repository, access: context.access, localAvailable: context.localAvailable)))
            case .network:
                guard let context = try? workspace.gitConfigurationContext(globalOnly: globalOnly) else { return }
                controller = host(NetworkSettingsPage(model: NetworkSettingsModel(repository: context.repository, access: context.access, localAvailable: context.localAvailable, preferences: preferences)))
            case .watchedRepositories:
                if let manager=workspace.finderWatches { controller=host(FinderWatchedRepositoriesPage(manager:manager)) }
                else { controller=host(Text("Watched repositories are unavailable.").padding(20)) }
            case .overlays: controller = host(FinderOverlaySettingsPage(model: overlayDraft))
            case .overlayHandlers: controller = host(FinderOverlaySettingsPage(model: overlayDraft, handlersOnly: true))
            case .overlayIcons: controller = host(FinderOverlaySettingsPage(model: overlayDraft, iconsOnly: true))
            case .contextMenu: controller = host(FinderContextMenuSettingsPage(model: contextMenuDraft))
            case .contextMenu2: controller = host(FinderContextMenuSettingsPage(model: contextMenuDraft, extendedOnly: true))
            case .issueProviders: controller = host(IssueProviderSettingsPage(workspace: workspace, preferences: preferences))
            case .issueTracker: controller = host(IssueTrackerSettingsPage(workspace: workspace, globalOnly: globalOnly, preferences: preferences))
            case .email: controller = host(EmailSettingsPage(model: emailDraft))
            case .diff: controller = host(DiffToolSettings(preferences: preferences))
            case .mergeTool: controller = host(MergeToolSettings(preferences: preferences))
            case .mergeEditor: controller = host(MergeEditorSettings(defaults: preferences))
            case .mergeColors: controller = host(MergeColorsSettings(model: MergeColorsSettingsModel(preferences: preferences)))
            case .savedData: controller = host(SavedDataSettingsPage(preferences: preferences))
            case .blame: controller = host(BlameSettings(preferences: preferences))
            case .unifiedDiff: controller = host(UnifiedDiffAppearanceSettings(preferences: preferences))
            case .advanced: controller = host(AdvancedSettingsPage(defaults: preferences))
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
        if current != nil { pageOrigins[selected] = content.contentView.bounds.origin }
        current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(controller); content.pageDocument.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo:content.pageDocument.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo:content.pageDocument.trailingAnchor), controller.view.topAnchor.constraint(equalTo:content.pageDocument.topAnchor), controller.view.bottomAnchor.constraint(equalTo:content.pageDocument.bottomAnchor)])
        if busyShield.superview == nil {
            busyShield.translatesAutoresizingMaskIntoConstraints = false; busyShield.isHidden = !transaction.busy
            content.addSubview(busyShield)
            NSLayoutConstraint.activate([busyShield.leadingAnchor.constraint(equalTo: content.leadingAnchor), busyShield.trailingAnchor.constraint(equalTo: content.trailingAnchor), busyShield.topAnchor.constraint(equalTo: content.topAnchor), busyShield.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        } else { content.addSubview(busyShield,positioned:.above,relativeTo:nil) }
        current = controller; selected = page; content.minimumPageWidth = page.minimumPageWidth; content.restoreOrigin(pageOrigins[page] ?? .zero)
        TurtleGitHelp.attach(view.window,topic:TurtleGitHelp.settingsTopic(page))
        heading.stringValue = nodes.first(where:{ $0.id == page })?.title ?? "Settings"
        heading.toolTip = roots.compactMap { $0.path(to:page) }.first?.map(\.title).joined(separator:" › ")
    }
    func invalidate() {
        guard !retired else { return }; retired = true
        transaction.invalidate(); emailDraft.invalidate(); hooks?.invalidate(); hooks = nil
        remote?.invalidate(); remote = nil
        if let window = view.window, let delegateProxy, window.delegate === delegateProxy { window.delegate = delegateProxy.original }
        delegateProxy = nil; current?.view.removeFromSuperview(); current?.removeFromParent(); current = nil; cache.removeAll()
    }
    @objc private func showPageHelp() { guard !retired else { return }; TurtleGitHelp.show(TurtleGitHelp.settingsTopic(selected)) }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SettingsPageNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SettingsPageNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SettingsPageNode)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SettingsPageNode else { return nil }
        let image = NSImageView(); image.image = node.icon.image(); image.imageScaling = .scaleProportionallyDown
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true; image.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let text = NSTextField(labelWithString:node.title); text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1; text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let row = NSTableCellView(); row.imageView = image; row.textField = text
        image.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(image); row.addSubview(text)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:row.leadingAnchor,constant:2),image.centerYAnchor.constraint(equalTo:row.centerYAnchor),text.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:7),text.trailingAnchor.constraint(equalTo:row.trailingAnchor,constant:-4),text.centerYAnchor.constraint(equalTo:row.centerYAnchor)])
        row.identifier = .init("Settings.Page." + node.id.rawValue); row.toolTip = node.title; text.toolTip = node.title
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
    func show(globalOnly: Bool = false, initialPage: SettingsPageID = .general) {
        guard let workspace, let appearance, !workspace.confirmingQuit else { return }
        if let navigation, navigation.globalOnly != globalOnly {
            guard prepareContextChange() else { return }
            controller?.window?.performClose(nil)
        }
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let navigation = SettingsNavigationController(workspace: workspace, appearance: appearance, globalOnly: globalOnly,initialPage:initialPage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Settings – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width:860,height:540)
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
        TurtleGitHelp.showContext()
    }
    static func showAbout() {
        TurtleGitAboutService.shared.show(.application)
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

/// Keep the property-sheet heading and actions visible on smaller screens.
/// Individual pages retain their normal layout and any existing inner scrolling.
@MainActor final class SettingsPageViewport:NSScrollView {
    final class Document:NSView { override var isFlipped:Bool { true } }
    let pageDocument = Document()
    private var pendingOrigin:CGPoint?
    var minimumPageWidth:CGFloat = 730 { didSet { if minimumPageWidth != oldValue { needsLayout = true } } }
    override init(frame:NSRect) {
        super.init(frame:frame)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        pageDocument.autoresizingMask = []; documentView = pageDocument
        identifier = .init("Settings.PageViewport"); setAccessibilityLabel("Settings page content")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func restoreOrigin(_ origin:CGPoint) { pendingOrigin = origin; needsLayout = true }
    override func layout() {
        super.layout()
        let visible = contentView.bounds.size
        let size = NSSize(width:max(minimumPageWidth,visible.width),height:max(640,visible.height))
        if pageDocument.frame.size != size { pageDocument.setFrameSize(size) }
        if let origin = pendingOrigin {
            pendingOrigin = nil
            contentView.scroll(to:CGPoint(x:min(max(0,origin.x),max(0,size.width - visible.width)),y:min(max(0,origin.y),max(0,size.height - visible.height))))
            reflectScrolledClipView(contentView)
        }
    }
}

/// Captures input during a property-sheet save; owned sheets remain interactive.
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
    private let defaults: UserDefaults
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
        self.defaults = defaults
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
    func apply() { for (key, value) in values { value.save(key, defaults: defaults) }; saved = values }
    func cancel() { values = saved }
}
private struct DialogsBehaviorSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var draft: DialogsBehaviorDraft
    init(defaults: UserDefaults = .standard) { _draft = StateObject(wrappedValue: DialogsBehaviorDraft(defaults: defaults)) }
    @StateObject private var autotextTester = AutotextTesterOwner()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Misc") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Autoclose Git progress dialog:", selection: draft.integer("AutoCloseGitProgress")) {
                            ForEach(GitProgressAutoClose.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        LogPreferenceCheckbox(title: "Use Trash when reverting", value: draft.boolean("RevertWithRecycleBin"))
                        LogPreferenceCheckbox(title: "Confirm to kill running git process", value: draft.boolean("ConfirmKillProcess"))
                        LogPreferenceCheckbox(title: "Randomize Sync Dialog startup position", value: draft.boolean("SyncDialogRandomPos"))
                        LogPreferenceCheckbox(title: "Hide unchanged refs in Ref Compare List", value: draft.boolean("RefCompareHideUnchanged"))
                        LogPreferenceCheckbox(title: "Show Git execution timings and timestamp", value: draft.boolean("ShowGitexeTimings"))
                        LogPreferenceCheckbox(title: "Sort tag list in reversed order", value: draft.boolean("SortTagsReversed"))
                        LogPreferenceCheckbox(title: "Disable sounds", value: draft.boolean("NoSounds"))
                        LogPreferenceCheckbox(title: "Include FETCH_HEAD in branch selection boxes", value: draft.boolean("BranchesIncludeFetchHead"))
                        LogPreferenceCheckbox(title: "Use .mailmap", value: draft.boolean("UseMailmap"))
                    }.padding(8)
                }
                GroupBox("Commit") {
                    VStack(alignment: .leading, spacing: 10) {
                        LogPreferenceCheckbox(title: "Use auto-completion of file paths and keywords", value: draft.boolean("Autocompletion"))
                        Button("Autotext Tester…", action: autotextTester.show)
                        Stepper("Timeout in seconds to stop auto-completion parsing: \(draft.integer("AutocompleteParseTimeout").wrappedValue)", value: draft.integer("AutocompleteParseTimeout"), in: 1...100)
                            .disabled(!draft.boolean("Autocompletion").wrappedValue)
                        Stepper("Max. items to keep in the log message history: \(draft.integer("MaxHistoryItems").wrappedValue)", value: draft.integer("MaxHistoryItems"), in: 1...100)
                        LogPreferenceCheckbox(title: "Select items automatically", value: draft.boolean("SelectFilesForCommit"))
                        LogPreferenceCheckbox(title: "Do not auto-select \"missing\" files (deleted, but unstaged)", value: draft.boolean("AutoselectMissingFiles"))
                        LogPreferenceCheckbox(title: "Strip lines starting with \"#\" in commit message", value: draft.boolean("StripCommentedLines"))
                        Text("Further options for the commit dialog are on Dialogs 3 page.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                Spacer()
            }.padding(20)
        }
        .onDisappear { autotextTester.close() }
        .settingsParticipant("dialogs2", page: .dialogs2, value: draft.values, modified: { draft.modified }, validate: { draft.validationError },
            apply: { draft.apply(); return true }, cancel: draft.cancel)
    }
}

// Native adaptations of the separate upstream tool About dialogs.
enum TurtleGitAboutTool: String, CaseIterable {
    case application, merge, blame, image, unified
    static var tools: [Self] { [.merge, .blame, .image, .unified] }
    var title: String {
        switch self { case .application: return "TurtleGit for Mac"; case .merge: return "TurtleGitMerge"; case .blame: return "TurtleGitBlame"; case .image: return "TurtleGitIDiff"; case .unified: return "TurtleGitUDiff" }
    }
    var icon: MenuIcon { switch self { case .application: return .turtle; case .merge: return .merge; case .blame: return .blame; case .image: return .imageOriginal; case .unified: return .unifiedDiff } }
    var purpose: String {
        switch self { case .application: return "A macOS fork of TortoiseGit"; case .merge: return "A native diff/patch and merge editor"; case .blame: return "A native source attribution viewer"; case .image: return "A native image comparison tool"; case .unified: return "A native unified-diff viewer" }
    }
    var credits: String {
        switch self {
        case .merge: return "Original TortoiseGitMerge / TortoiseMerge:\nStefan Küng — author\nLübbe Onken — icons, design and code\nBased on TortoiseSVN."
        case .blame: return "Original TortoiseGitBlame contributions:\nSven Strickroth, Sup Yut Sum, Frank Li and Martin Strauß.\nSee the upstream repository for the complete history."
        case .image: return "Based on TortoiseGitIDiff / TortoiseIDiff of TortoiseSVN.\nOriginal source and artwork attribution is retained in NOTICE."
        case .unified: return "Based on TortoiseGitUDiff and its credited editor components.\nOriginal source and artwork attribution is retained in NOTICE."
        case .application: return "Original TortoiseGit contributions:\nSven Strickroth, Sup Yut Sum, Frank Li, Yue Lin Ho, Colin Law, Myagi, Johan ’t Hart and Laszlo Papp.\nBased on TortoiseSVN; see the upstream repository for complete history."
        }
    }
}
@MainActor final class TurtleGitAboutService {
    static let shared = TurtleGitAboutService()
    private var controllers: [TurtleGitAboutTool: TurtleGitAboutController] = [:]
    func show(_ tool: TurtleGitAboutTool) {
        if let controller = controllers[tool] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let bundle = SubversionMergeDiff.applicationBundle()
        let information = ApplicationAboutInformation(application: bundle.bundleURL, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let controller = TurtleGitAboutController(tool: tool, information: information)
        controller.onClosed = { [weak self] in self?.controllers.removeValue(forKey: tool) }
        controllers[tool] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
@MainActor private final class TurtleGitAboutWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, attachedSheet == nil { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class TurtleGitAboutController: NSWindowController, NSWindowDelegate {
    let tool: TurtleGitAboutTool
    let information: ApplicationAboutInformation
    var diagnosticText: String { information.versionText + "\nmacOS: " + ProcessInfo.processInfo.operatingSystemVersionString }
    var onClosed: () -> Void = {}
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var checkUpdates: () -> Void = { ReleaseUpdateService.shared.show() }
    init(tool: TurtleGitAboutTool, information: ApplicationAboutInformation) {
        self.tool = tool; self.information = information
        let window = TurtleGitAboutWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 530), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "About " + tool.title; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 550, height: 430)
        super.init(window: window); window.delegate = self; window.center()
        let content = NSView(); window.contentView = content
        let icon = NSImageView(); icon.image = tool.icon.image(size: 48); icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: tool.title); name.font = .boldSystemFont(ofSize: 22)
        let subtitle = NSTextField(labelWithString: tool.purpose); subtitle.font = .systemFont(ofSize: 13)
        let title = NSStackView(views: [name, subtitle]); title.orientation = .vertical; title.alignment = .leading; title.spacing = 5
        let header = NSStackView(views: [icon, title]); header.orientation = .horizontal; header.spacing = 16
        let credits = NSTextField(wrappingLabelWithString: tool.credits); credits.isSelectable = true
        let links = NSStackView(); links.orientation = .horizontal; links.spacing = 14
        for (title, url) in [("Project website", "https://jfk-solutions.github.io/turtle-git-mac/"), ("Source code", "https://github.com/jfk-solutions/turtle-git-mac"), ("Upstream / contributors", "https://github.com/TortoiseGit/TortoiseGit")] {
            let button = NSButton(title: title, target: self, action: #selector(openLink(_:))); button.identifier = .init(url); button.bezelStyle = .inline; links.addArrangedSubview(button)
        }
        let versions = NSTextView(); versions.isEditable = false; versions.isRichText = false; versions.isSelectable = true
        versions.string = diagnosticText
        versions.font = .monospacedSystemFont(ofSize: 11, weight: .regular); versions.textColor = .labelColor; versions.backgroundColor = .textBackgroundColor
        versions.textContainerInset = NSSize(width: 8, height: 8); versions.setAccessibilityLabel("Version Information")
        let scroll = NSScrollView(); scroll.documentView = versions; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        versions.isVerticallyResizable = true; versions.autoresizingMask = [.width]; versions.textContainer?.widthTracksTextView = true
        let versionTitle = NSTextField(labelWithString: "Version Information"); versionTitle.font = .boldSystemFont(ofSize: 13)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        let copy = NSButton(title: "Copy Version Information", target: self, action: #selector(copyVersions(_:)))
        let license = NSButton(title: "License", target: self, action: #selector(openLicense(_:))); license.isEnabled = information.license != nil
        let notices = NSButton(title: "Notices", target: self, action: #selector(openNotices(_:))); notices.isEnabled = information.notices != nil
        let update = NSButton(title: "Check For Updates…", target: self, action: #selector(update(_:)))
        let ok = NSButton(title: "OK", target: self, action: #selector(closeAbout(_:))); ok.keyEquivalent = "\r"
        for button in [copy, license, notices, update, ok] { footer.addArrangedSubview(button) }
        let stack = NSStackView(views: [header, credits, links, versionTitle, scroll, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20), icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)])
        window.initialFirstResponder = ok
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func openLink(_ sender: NSButton) { if let value = sender.identifier?.rawValue, let url = URL(string: value) { open(url) } }
    @objc func openLicense(_ sender: Any?) { if let url = information.license { open(url) } }
    @objc func openNotices(_ sender: Any?) { if let url = information.notices { open(url) } }
    func copyVersionInformation(to pasteboard: NSPasteboard) { pasteboard.clearContents(); pasteboard.setString(diagnosticText, forType: .string) }
    @objc func copyVersions(_ sender: Any?) { copyVersionInformation(to: .general) }
    @objc func update(_ sender: Any?) { checkUpdates() }
    @objc func closeAbout(_ sender: Any?) { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) { onClosed() }
}
