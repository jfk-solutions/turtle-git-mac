// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SetLookAndFeelPage / SetExtMenu, TortoiseGit 2011-2026
// and TortoiseSVN 2003-2008, 2011, 2014. See NOTICE and LICENSE.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FinderContextMenuSettingsModel: ObservableObject {
    enum Page: Equatable { case primary, extended }
    struct EditContext: Equatable { let owner: ObjectIdentifier; let revision: UUID; let page: Page }
    let settingsRegistration = UUID()
    @Published var draft: FinderMenuSettings
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var activePage: Page? = .primary
    @Published private(set) var revision = UUID()
    @Published private(set) var applying = false
    private(set) var retired = false
    private(set) weak var window: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    private var saved: FinderMenuSettings
    private let defaults: UserDefaults
    private let publish: (FinderMenuSettings) throws -> Bool
    private let notify: () -> Void
    var message: String? { error ?? notice }
    var modified: Bool { policy(draft) != policy(saved) }
    private func policy(_ value: FinderMenuSettings) -> FinderMenuSettings { var copy = value; copy.showIcons = true; return copy }
    init(defaults: UserDefaults = .standard, publish: @escaping (FinderMenuSettings) throws -> Bool = { try $0.write() },
         notify: @escaping () -> Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }) {
        self.defaults = defaults; self.publish = publish; self.notify = notify
        let initial = FinderMenuSettings.from(defaults: defaults); draft = initial; saved = initial
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func attach(to owner: NSWindow?, page: Page) {
        guard !retired else { return }
        guard let owner else { deactivate(page); return }
        guard window !== owner else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        window = owner; revision = UUID()
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.retired = true; self.activePage = nil; self.revision = UUID() }
        }
    }
    func setActive(_ page: Page?) { guard !retired, activePage != page else { return }; activePage = page; revision = UUID() }
    func deactivate(_ page: Page) { if activePage == page { setActive(nil) } }
    func context(_ page: Page) -> EditContext { .init(owner: ObjectIdentifier(self), revision: revision, page: page) }
    func accepts(_ context: EditContext) -> Bool { !retired && !applying && activePage == context.page && self.context(context.page) == context }
    func mask(_ page: Page) -> UInt64 { page == .extended ? draft.extendedOnlyMask : draft.topLevelMask }
    func set(_ entry: FinderMenuEntry, checked: Bool, context: EditContext, expectedMask: UInt64? = nil) {
        guard accepts(context), entry.availableInFinder, expectedMask == nil || expectedMask == mask(context.page) else { return }
        draft.set(entry, checked: checked, extendedOnly: context.page == .extended); error = nil; notice = nil
    }
    func selectAll(_ checked: Bool, context: EditContext, expectedMask: UInt64) {
        guard accepts(context), mask(context.page) == expectedMask else { return }
        let value = checked ? expectedMask | FinderMenuEntry.allMask : expectedMask & ~FinderMenuEntry.allMask
        if context.page == .extended { draft.extendedOnlyMask = value } else { draft.topLevelMask = value }
        error = nil; notice = nil
    }
    func binding<Value>(_ key: WritableKeyPath<FinderMenuSettings, Value>, context: EditContext) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: key] }, set: { if self.accepts(context), context.page == .primary { self.draft[keyPath: key] = $0; self.error = nil; self.notice = nil } })
    }
    var validationError: String? {
        guard !draft.valid else { return nil }
        let lines = draft.excludedPaths.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        for (index,line) in lines.enumerated() where !line.isEmpty {
            var value = FinderMenuSettings(); value.excludedPaths = line
            if !value.valid { return "Context-menu exclusion line \(index + 1): enter an absolute path, ~ or $HOME; NUL characters are not allowed." }
        }
        return "Enter one absolute context-menu exclusion path per line."
    }
    func apply() -> Bool {
        guard !retired, !applying else { return false }
        guard validationError == nil else { error = validationError; notice = nil; return false }
        let captured = draft
        var value = captured
        // Advanced owns this preference; use its current accepted value.
        value.showIcons = FinderMenuSettings.from(defaults: defaults).showIcons
        applying = true; revision = UUID()
        defer { applying = false; revision = UUID() }
        do {
            let shared = try publish(value)
            guard !retired, draft == captured, FinderMenuSettings.from(defaults: defaults).showIcons == value.showIcons else {
                error = "The settings changed during Finder publication. The current draft is retained; apply it again."; notice = nil; return false
            }
            try value.save(to: defaults); draft = value; saved = value
            error = nil; notice = shared ? nil : "Preferences saved. Signed App Group access is required to update Finder."
            if shared { notify() }
            return true
        } catch { self.error = error.localizedDescription; notice = nil; return false }
    }
    func cancel() {
        guard !retired, !applying else { return }; draft = saved
        draft.showIcons = FinderMenuSettings.from(defaults: defaults).showIcons
        error = nil; notice = nil; revision = UUID()
    }
    func restore(extendedOnly: Bool) {
        let page: Page = extendedOnly ? .extended : .primary
        restore(context: context(page))
    }
    func restore(context: EditContext) {
        guard accepts(context) else { return }
        if context.page == .extended { draft.extendedOnlyMask = FinderMenuEntry.defaultExtendedMask }
        else { draft.topLevelMask = FinderMenuEntry.defaultTopMask }
        error = nil; notice = nil; revision = UUID()
    }
}

struct FinderContextMenuSettingsPage: View {
    @ObservedObject var model: FinderContextMenuSettingsModel
    var extendedOnly = false
    @Environment(\.settingsTransaction) private var transaction
    private var page: FinderContextMenuSettingsModel.Page { extendedOnly ? .extended : .primary }
    var body: some View {
        let context = model.context(page), mask = model.mask(page)
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(extendedOnly ? "Hide the selected items in the context menu:" : "Show the selected items on the first level of the context menu:") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(extendedOnly ? "Checked items will be hidden by default and will only be visible if Shift is held while opening the context menu." : "Unchecked items appear in the TurtleGit submenu. Checked items appear directly in the main context menu.")
                        .fixedSize(horizontal: false, vertical: true)
                    FinderMenuSettingsList(model: model, page: page).frame(height: extendedOnly ? 360 : 220)
                    HStack {
                        MenuSelectAllButton(mask: mask, allMask: FinderMenuEntry.allMask) { checked in
                            model.selectAll(checked, context: context, expectedMask: mask)
                        }.fixedSize().disabled(!model.accepts(context))
                        Spacer()
                        Button("Restore Default") { model.restore(context: context) }.disabled(!model.accepts(context))
                    }
                }.padding(10)
            }
            if !extendedOnly {
                Toggle("Hide menus for unversioned paths", isOn: model.binding(\.hideForUnversioned, context: context)).disabled(!model.accepts(context))
                GroupBox("Do not show the context menu for the following paths:") {
                    TextEditor(text: model.binding(\.excludedPaths, context: context)).font(.system(.body, design: .monospaced)).frame(height: 80).border(Color.secondary.opacity(0.3)).padding(8)
                        .accessibilityLabel("Context-menu excluded paths").disabled(!model.accepts(context))
                }
                Text("One absolute path per line. A path alone matches exactly; a trailing / includes its children; * matches a path prefix. ~ and $HOME expand to your home folder.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let issue = model.validationError { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Toggle("Enable drag context menu", isOn: .constant(false)).disabled(true)
                    .help("Finder Sync does not provide drag context menus.")
                Text("Finder Sync does not provide drag context menus.").font(.caption).foregroundStyle(.secondary)
                GroupBox("macOS clipboard actions") {
                    Toggle("Show clipboard Copy/Add and Move in Finder folders", isOn: model.binding(\.clipboardTransfers, context: context))
                        .help("macOS clipboard actions appear in the TurtleGit submenu; source menu masks are preserved.")
                        .disabled(!model.accepts(context)).padding(8)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }.padding(12)
        .background(FinderMenuOwnerProbe(model: model, page: page).frame(width: 0, height: 0))
        .onAppear {
            model.setActive(page)
            transaction?.register("contextMenu", participant: .init(page: .contextMenu, modified: { model.modified }, validate: { model.validationError }, apply: model.apply, cancel: model.cancel), registration: model.settingsRegistration)
        }
        .onDisappear { model.deactivate(page) }
        .onChange(of: model.draft) { _ in transaction?.notify() }
    }
}

private struct FinderMenuOwnerProbe: NSViewRepresentable {
    let model: FinderContextMenuSettingsModel; let page: FinderContextMenuSettingsModel.Page
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; view.page = page; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window, page: page) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { if let page = view.page { view.model?.deactivate(page) }; view.model = nil }
    final class Probe: NSView {
        weak var model: FinderContextMenuSettingsModel?; var page: FinderContextMenuSettingsModel.Page?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let page { model?.attach(to: window, page: page) } }
    }
}

/// Native source list: checkbox, original icon and label, with single selection
/// and Space to toggle the selected command. It has no column header.
struct FinderMenuSettingsList: NSViewRepresentable {
    @ObservedObject var model: FinderContextMenuSettingsModel; let page: FinderContextMenuSettingsModel.Page
    func makeCoordinator() -> Coordinator { Coordinator(model: model, page: page) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let table = MenuTable(); table.headerView = nil; table.autoresizingMask = [.width]; table.rowHeight = 24; table.intercellSpacing = .zero; table.allowsMultipleSelection = false; table.usesAlternatingRowBackgroundColors = false
        let column = NSTableColumn(identifier: .init("command")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel(page == .extended ? "Shift-only context-menu commands" : "First-level context-menu commands")
        scroll.documentView = table; context.coordinator.table = table; table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.toggleSelection = { [weak coordinator = context.coordinator] in coordinator?.toggleSelected() }; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.retire() }
    final class MenuTable: NSTableView {
        var toggleSelection: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 && event.modifierFlags.intersection([.command,.control,.option]).isEmpty { toggleSelection?() }
            else { super.keyDown(with: event) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var model: FinderContextMenuSettingsModel?; let page: FinderContextMenuSettingsModel.Page
        weak var table: MenuTable?; private var live = true
        private var captured: FinderContextMenuSettingsModel.EditContext?
        private(set) var mask: UInt64 = 0
        init(model: FinderContextMenuSettingsModel, page: FinderContextMenuSettingsModel.Page) { self.model = model; self.page = page }
        func numberOfRows(in tableView: NSTableView) -> Int { FinderMenuEntry.allCases.count }
        func update() {
            guard live, let model, let table else { return }
            captured = model.context(page); mask = model.mask(page)
            let selected = table.selectedRow
            table.reloadData()
            if selected >= 0 && selected < FinderMenuEntry.allCases.count { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        }
        func toggleSelected() {
            guard let table, table.selectedRow >= 0, table.selectedRow < FinderMenuEntry.allCases.count else { return }
            choose(FinderMenuEntry.allCases[table.selectedRow], checked: mask & FinderMenuEntry.allCases[table.selectedRow].mask == 0)
        }
        private func choose(_ entry: FinderMenuEntry, checked: Bool) {
            guard live, let model, let table, table.window != nil, table.window === model.window, let captured, model.accepts(captured) else { return }
            model.set(entry, checked: checked, context: captured, expectedMask: mask)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = FinderMenuEntry.allCases[row], identifier = NSUserInterfaceItemIdentifier(entry.rawValue)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MenuRow ?? MenuRow(entry: entry)
            cell.identifier = identifier; cell.check.state = mask & entry.mask == 0 ? .off : .on
            cell.check.isEnabled = live && entry.availableInFinder && captured.map { model?.accepts($0) == true } == true
            let expected = mask, context = captured
            cell.change = { [weak self, weak tableView] checked in
                guard let self, self.live, self.mask == expected, self.captured == context, let tableView, tableView.window != nil else { return }
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self.choose(entry, checked: checked)
            }
            return cell
        }
        func retire() { live = false; table?.toggleSelection = nil; table?.delegate = nil; table?.dataSource = nil; model = nil }
    }
    final class MenuRow: NSTableCellView {
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        var change: ((Bool) -> Void)?
        init(entry: FinderMenuEntry) {
            super.init(frame: .zero)
            let image = NSImageView(image: entry.image() ?? NSImage()); image.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: entry.title); label.lineBreakMode = .byTruncatingTail
            check.target = self; check.action = #selector(clicked(_:)); check.setAccessibilityLabel(entry.title)
            let row = NSStackView(views: [check,image,label]); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
            addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 4), row.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -4), row.centerYAnchor.constraint(equalTo: centerYAnchor), check.widthAnchor.constraint(equalToConstant: 18), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)])
        }
        @objc private func clicked(_ sender: NSButton) { guard sender.isEnabled, sender.window != nil else { return }; change?(sender.state == .on) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}

/// Source Select/deselect all uses a native three-state checkbox.
struct MenuSelectAllButton: NSViewRepresentable {
    let mask: UInt64, allMask: UInt64
    let change: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change; button.isEnabled = enabled
        let checked = mask & allMask
        button.state = checked == 0 ? .off : checked == allMask ? .on : .mixed
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.live = false; button.isEnabled = false; button.target = nil; button.action = nil }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void; var live = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) {
            guard live, sender.isEnabled, sender.window != nil else { return }
            if sender.state == .mixed { sender.state = .off }
            change(sender.state == .on)
        }
    }
}
