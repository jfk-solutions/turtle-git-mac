// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Native projection of Settings.cpp's tree for pages currently implemented.
/// Pending pages are tracked in the inventory, rather than shown as empty panes.
enum SettingsPageID: String {
    case general, dialogs, commit, alternativeEditor, git, remote, email
    case mergeEditor, savedData, blame, unifiedDiff, advanced
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
    private let outline = NSOutlineView()
    private let content = NSView()
    private let heading = NSTextField(labelWithString: "General")
    private var roots: [SettingsPageNode] = []
    private var cache: [SettingsPageID: NSViewController] = [:]
    private var current: NSViewController?
    private(set) var selected: SettingsPageID = .general
    private var repositoryPath: String?
    private var remote: RemoteSettingsWindowModel?
    private var delegateProxy: SettingsWindowDelegate?
    private var updating = false
    init(workspace: RepositoryModel, appearance: AppAppearance) { self.workspace = workspace; self.appearance = appearance; super.init(nibName: nil, bundle: nil) }
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
        let right = NSStackView(views: [heading, NSBox(), content]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
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
        rebuildTree(); show(.general)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, delegateProxy == nil else { return }
        let proxy = SettingsWindowDelegate(owner: self, original: window.delegate); delegateProxy = proxy; window.delegate = proxy
        window.title = "Settings – TurtleGit for Mac"
    }
    var canDismiss: Bool { remote?.busy != true && remote?.hasChild != true && GitConfigurationSettingsModel.activeSaves == 0 && view.window?.attachedSheet == nil }
    func updateRepository() {
        guard isViewLoaded, workspace.root?.path != repositoryPath else { return }
        // A captured Remote model belongs to the repository that created it.
        remote?.invalidate()
        if selected == .remote, let window = view.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        remote = nil; cache.removeValue(forKey: .remote)
        if selected == .remote { show(.git) }
        rebuildTree()
    }
    private func rebuildTree() {
        repositoryPath = workspace.root?.path
        roots = [
            SettingsPageNode(.general, "General", .settingsGeneral, children: [
                SettingsPageNode(.dialogs, "Dialogs", .settingsDialogs),
                SettingsPageNode(.commit, "Commit", .settingsDialogs),
                SettingsPageNode(.alternativeEditor, "Alternative Editor", .editor)]),
            SettingsPageNode(.git, "Git", .settingsGit, children: workspace.root == nil ? [] : [SettingsPageNode(.remote, "Remote", .settingsRemote)]),
            SettingsPageNode(.email, "Email", .sendMail), SettingsPageNode(.mergeEditor, "Merge Editor", .merge),
            SettingsPageNode(.savedData, "Saved Data", .settingsSavedData), SettingsPageNode(.blame, "TortoiseGitBlame", .blame),
            SettingsPageNode(.unifiedDiff, "Unified Diff", .settingsUnifiedDiff), SettingsPageNode(.advanced, "Advanced", .settingsGeneral)
        ]
        updating = true; outline.reloadData(); roots.forEach { outline.expandItem($0) }
        if let node = nodes.first(where: { $0.id == selected }) { let row = outline.row(forItem: node); if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
        updating = false
    }
    private var nodes: [SettingsPageNode] { roots.flatMap { [$0] + $0.children } }
    private func show(_ page: SettingsPageID) {
        guard view.window?.attachedSheet == nil, remote?.busy != true, remote?.hasChild != true, GitConfigurationSettingsModel.activeSaves == 0 else { return }
        if current != nil && selected == page { return }
        view.window?.makeFirstResponder(nil)
        let controller: NSViewController
        if let existing = cache[page] { controller = existing }
        else {
            switch page {
            case .general: controller = NSHostingController(rootView: AppearanceSettings(appearance: appearance))
            case .dialogs: controller = NSHostingController(rootView: LogDialogSettings())
            case .commit: controller = NSHostingController(rootView: CommitEditorSettings())
            case .alternativeEditor: controller = NSHostingController(rootView: AlternativeEditorSettings())
            case .git: controller = NSHostingController(rootView: GitConfigurationSettingsPage(workspace: workspace))
            case .email: controller = NSHostingController(rootView: EmailSettingsPage())
            case .mergeEditor: controller = NSHostingController(rootView: MergeEditorSettings())
            case .savedData: controller = NSHostingController(rootView: SavedDataSettingsPage())
            case .blame: controller = NSHostingController(rootView: BlameSettings())
            case .unifiedDiff: controller = NSHostingController(rootView: UnifiedDiffSettingsPage())
            case .advanced: controller = NSHostingController(rootView: AdvancedSettingsPage())
            case .remote:
                guard let context = try? workspace.gitConfigurationContext(), context.localAvailable else { return }
                let model = RemoteSettingsWindowModel(repository: context.repository, access: context.access)
                remote = model; workspace.configureSettingsRemote(model)
                model.close = { [weak self] in guard let self, self.canDismiss else { return }; self.view.window?.performClose(nil) }
                controller = NSViewController(); controller.view = RemoteSettingsNativeView(model: model); model.load()
            }
            cache[page] = controller
        }
        current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(controller); content.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor), controller.view.topAnchor.constraint(equalTo: content.topAnchor), controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        current = controller; selected = page; heading.stringValue = nodes.first(where: { $0.id == page })?.title ?? page.rawValue
    }
    func invalidate() {
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
