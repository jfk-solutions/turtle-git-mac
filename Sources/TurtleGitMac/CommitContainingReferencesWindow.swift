// Native adaptation of CommitIsOnRefsDlg. SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private final class CommitReferencesSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class CommitReferencesWindow: NSWindow {
    var key: (NSEvent) -> Bool = { _ in false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { key(event) || super.performKeyEquivalent(with: event) }
    override func cancelOperation(_ sender: Any?) { if let event = NSApp.currentEvent, key(event) { return }; performClose(sender) }
}

@MainActor final class CommitContainingReferencesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSSearchFieldDelegate {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let revision = NSComboBox()
    let subject = NSTextField(labelWithString: "")
    let filter = NSSearchField()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    let showLog = NSButton(title: "Show log", target: nil, action: nil)
    let chooser = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var snapshot: CommitContainingReferences?
    private(set) var rows: [GitReferenceName] = []
    private(set) var busy = false
    private(set) var closed = false
    private(set) var picker: NSWindowController?
    var onClosed: () -> Void = {}
    var onLog: ((String?, Bool, HistoryRevisionRange?) -> Void)?
    var onBrowse: ((String) -> Void)?
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onUnified: ((Data, Bool) async throws -> Void)?
    var onNavigate: (String, Bool) -> Void = { _, _ in }
    var copyText: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    var read: ((String, OperationCancellation) async throws -> CommitContainingReferences)?
    private var worker: Task<Void, Never>?
    private var token: OperationCancellation?
    private var request = UUID()
    private var revisionTimer: Timer?
    private var filterTimer: Timer?
    private var lastSelected: GitReferenceName?
    private var previousSelection = IndexSet()
    private var completionCache: [GitReferenceName]?
    private var unifiedViewer: PatchWindowController?
    private var canAct: Bool { !closed && !busy && picker == nil && window?.attachedSheet == nil && window?.parent?.attachedSheet == nil }

    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
        let window = CommitReferencesWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "References commit is on – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 470, height: 300)
        window.contentView = CommitReferencesSurface(frame: window.contentView!.frame)
        super.init(window: window); window.delegate = self
        self.revision.stringValue = revision; self.revision.completes = true; self.revision.delegate = self
        filter.delegate = self; filter.placeholderString = "Filter references"
        subject.lineBreakMode = .byTruncatingTail; subject.isSelectable = true
        showLog.target = self; showLog.action = #selector(showCommitLog)
        chooser.addItem(withTitle: "…")
        for (index, title, icon) in [(0, "Browse References", MenuIcon.repositoryBrowser), (1, "Log", .log), (2, "Reflog", .log)] {
            let item = NSMenuItem(title: title, action: #selector(chooseRevision(_:)), keyEquivalent: ""); item.target = self; item.tag = index; item.image = icon.contextImage(defaults: preferences); chooser.menu?.addItem(item)
        }
        let column = NSTableColumn(identifier: .init("reference")); column.title = "Ref"; table.addTableColumn(column)
        table.headerView = nil; table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self; table.rowHeight = 22
        table.target = self; table.doubleAction = #selector(navigateReference)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.borderType = .bezelBorder
        let top = NSStackView(views: [self.revision, chooser]); top.orientation = .horizontal
        let summary = NSStackView(views: [subject, showLog]); summary.orientation = .horizontal
        summary.distribution = .fill; top.distribution = .fill
        let bottom = NSStackView(views: [NSTextField(labelWithString: "Filter:"), filter]); bottom.orientation = .horizontal; bottom.distribution = .fill
        let content = NSStackView(views: [top, summary, scroll, status, bottom]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 8; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -14), top.widthAnchor.constraint(equalTo: content.widthAnchor), summary.widthAnchor.constraint(equalTo: content.widthAnchor), scroll.widthAnchor.constraint(equalTo: content.widthAnchor), bottom.widthAnchor.constraint(equalTo: content.widthAnchor), chooser.widthAnchor.constraint(equalToConstant: 36), showLog.widthAnchor.constraint(equalToConstant: 86)])
        self.revision.setContentHuggingPriority(.defaultLow, for: .horizontal); subject.setContentHuggingPriority(.defaultLow, for: .horizontal); filter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.key = { [weak self] event in self?.handleKey(event) ?? false }
        DialogGeometry.attach(window, identifier: "CommitIsOnRefsDlg", legacyName: "CommitIsOnRefsDlg")
        updateAvailability()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func cancelRead() { request = UUID(); token?.cancel(); token = nil; worker?.cancel(); worker = nil; busy = false }
    func refresh(reloadCompletion: Bool = false) {
        guard !closed, picker == nil, window?.attachedSheet == nil, window?.parent?.attachedSheet == nil else { return }
        revisionTimer?.invalidate(); revisionTimer = nil; filterTimer?.invalidate(); filterTimer = nil
        cancelRead(); snapshot = nil; rows = []; subject.stringValue = ""; subject.toolTip = nil; table.reloadData(); previousSelection = []; lastSelected = nil
        let name = revision.stringValue
        if reloadCompletion { completionCache = nil; revision.removeAllItems(); revision.stringValue = name }
        let cancellation = OperationCancellation(), generation = UUID(); request = generation; token = cancellation; busy = true; status.stringValue = "Loading…"; updateAvailability()
        worker = Task { [weak self] in
            guard let self else { return }
            defer { withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                if completionCache == nil {
                    let names = try await repository.commitContainingReferenceCompletion(cancellation: cancellation)
                    guard !closed, request == generation, !cancellation.isCancelled else { return }
                    completionCache = names
                    revision.removeAllItems(); revision.addItems(withObjectValues: names.map(\.rawValue)); revision.stringValue = name
                }
                guard !name.isEmpty else { busy = false; token = nil; worker = nil; status.stringValue = ""; updateAvailability(); return }
                let data: CommitContainingReferences
                if let read { data = try await read(name, cancellation) }
                else { data = try await repository.commitContainingReferences(name, includeCompletion: false, cancellation: cancellation) }
                guard !closed, request == generation, !cancellation.isCancelled else { return }
                snapshot = data; busy = false; token = nil; worker = nil
                subject.stringValue = data.abbreviatedHash + ": " + data.subject; subject.toolTip = HistoryDateSettings.load(defaults: preferences).format(data.authorDate, absolute: true) + "  " + data.author
                applyFilter(); updateAvailability()
            } catch {
                guard !closed, request == generation, !cancellation.isCancelled else { return }
                busy = false; token = nil; worker = nil; status.stringValue = "Invalid revision \"" + name + "\".\n" + error.localizedDescription; updateAvailability()
            }
        }
    }
    func applyFilter() {
        guard !closed else { return }; filterTimer?.invalidate(); filterTimer = nil
        rows = snapshot?.filtered(filter.stringValue) ?? []; previousSelection = []; lastSelected = nil; table.deselectAll(nil); table.reloadData()
        if snapshot != nil { status.stringValue = rows.isEmpty ? "No references found." : "" }
    }
    private func updateAvailability() {
        showLog.isEnabled = canAct && snapshot != nil && onLog != nil; chooser.isEnabled = canAct; filter.isEnabled = canAct && snapshot != nil; table.isEnabled = canAct
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === revision {
            cancelRead(); snapshot = nil; rows = []; subject.stringValue = ""; table.reloadData(); updateAvailability(); revisionTimer?.invalidate()
            revisionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        } else if notification.object as? NSSearchField === filter {
            filterTimer?.invalidate()
            if filter.stringValue.isEmpty { applyFilter() }
            else { filterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.applyFilter() } } }
        }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSComboBox === revision, revision.indexOfSelectedItem >= 0 else { return }
        revision.stringValue = revision.itemObjectValue(at: revision.indexOfSelectedItem) as? String ?? revision.stringValue
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: revision))
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), control === filter, !filter.stringValue.isEmpty { filter.stringValue = ""; applyFilter(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), control === revision { refresh(); return true }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = NSTableCellView(); let image = NSImageView(); let text = NSTextField(labelWithString: rows[row].rawValue); text.lineBreakMode = .byTruncatingTail
        image.image = ReferenceTypeIcon(referenceName: rows[row].rawValue)?.image(); image.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(text); cell.imageView = image; cell.textField = text
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let added = table.selectedRowIndexes.subtracting(previousSelection)
        if let index = added.last, rows.indices.contains(index) { lastSelected = rows[index] }
        previousSelection = table.selectedRowIndexes
    }
    var selectedReferences: [GitReferenceName] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    @objc private func showCommitLog() { guard canAct, let data = snapshot else { return }; onLog?(data.hash, true, nil) }
    @objc private func navigateReference() {
        guard canAct, table.clickedRow >= 0, rows.indices.contains(table.clickedRow) else { return }
        let name = rows[table.clickedRow].rawValue, select = NSApp.currentEvent?.modifierFlags.contains(.shift) != true
        performRead { [weak self] token in
            guard let self else { return }
            let hash = try await repository.run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
            if !closed, !token.isCancelled { onNavigate(hash, select) }
        }
    }
    private func performRead(_ action: @escaping (OperationCancellation) async throws -> Void) {
        guard canAct else { return }; let cancellation = OperationCancellation(), generation = UUID(); token = cancellation; request = generation; busy = true; updateAvailability()
        worker = Task { [weak self] in
            guard let self else { return }; defer { withExtendedLifetime(access) {} }
            do { try await action(cancellation) }
            catch { if !closed, request == generation, !cancellation.isCancelled { status.stringValue = error.localizedDescription } }
            if !closed, request == generation { busy = false; token = nil; worker = nil; updateAvailability() }
        }
    }
    @objc private func chooseRevision(_ sender: NSMenuItem) {
        guard canAct, let owner = window else { return }
        switch sender.tag {
        case 0:
            let child = ReferenceBrowserWindowController(repository: repository, access: access, initial: revision.stringValue, preferences: preferences, onChoose: { [weak self] value in self?.finishPicker(value) })
            picker = child; child.model.load()
        case 1:
            let child = LogWindowController(repository: repository, access: access, onChoose: { [weak self] value in self?.finishPicker(value?.hash) }, labelDefaults: preferences, initialRevision: revision.stringValue)
            child.model.onContainingLog = onLog; child.model.onBrowseRepository = onBrowse; child.model.onCompare = onCompare; child.model.onUnifiedDiff = onUnified
            picker = child
        default:
            picker = ReferenceLogWindowController(repository: repository, access: access, reference: "HEAD", onChoose: { [weak self] value in self?.finishPicker(value?.hash) }, preferences: preferences)
        }
        if let child = picker?.window { child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child) }
        updateAvailability()
    }
    private func finishPicker(_ value: String?) {
        guard !closed, let owner = window else { return }
        picker = nil
        if let sheet = owner.attachedSheet { owner.endSheet(sheet) }
        if let value { revision.stringValue = value; refresh() } else { updateAvailability() }
        owner.makeFirstResponder(revision)
    }
    var hasBlockingChild: Bool { picker != nil || window?.attachedSheet != nil || unifiedViewer?.model.busy == true || unifiedViewer?.window?.attachedSheet != nil }
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(reloadCompletion: true); return true }
        if event.keyCode == 53, let editor = filter.currentEditor(), window?.firstResponder === editor, !filter.stringValue.isEmpty { filter.stringValue = ""; applyFilter(); return true }
        if event.modifierFlags.contains(.command), window?.firstResponder === table {
            if event.charactersIgnoringModifiers == "a", canAct { table.selectAll(nil); return true }
            if event.charactersIgnoringModifiers == "c", canAct { copySelection(); return true }
        }
        return false
    }
    func copySelection() { guard canAct else { return }; let names = selectedReferences; if !names.isEmpty { copyText(names.map(\.rawValue).joined(separator: "\n") + "\n") } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canAct && unifiedViewer?.model.busy != true && unifiedViewer?.window?.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        closed = true; cancelRead(); revisionTimer?.invalidate(); filterTimer?.invalidate()
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }
        picker?.close(); picker = nil; unifiedViewer?.close(); unifiedViewer = nil; onClosed()
    }
}

extension CommitContainingReferencesWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        guard canAct else { return }; let names = selectedReferences
        func item(_ title: String, _ command: String, _ icon: MenuIcon, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command; item.image = icon.contextImage(defaults: preferences); item.isEnabled = enabled; menu.addItem(item)
        }
        if names.count == 2 {
            item("Compare revisions", "compare", .compare, enabled: onCompare != nil); item("Unified diff", "unified", .unifiedDiff); menu.addItem(.separator())
            let range = ReferenceBrowserRange(references: names, lastSelected: lastSelected)!
            item("Show log of " + range.label(), "range", .log, enabled: onLog != nil)
            item("Show log of " + range.label(symmetric: true), "symmetric", .log, enabled: onLog != nil); menu.addItem(.separator())
        } else if names.count == 1 {
            item("Show log", "log", .log, enabled: onLog != nil); menu.addItem(.separator()); item("Browse repository", "browse", .repositoryBrowser, enabled: onBrowse != nil)
            if snapshot?.bare == false { menu.addItem(.separator()); item("Compare with working tree", "working", .compare, enabled: onCompare != nil) }
            menu.addItem(.separator())
        }
        if !names.isEmpty { item("Copy", "copy", .copy) }
    }
    @objc func menuAction(_ item: NSMenuItem) {
        guard canAct, let command = item.representedObject as? String else { return }; let names = selectedReferences
        switch command {
        case "copy": copySelection()
        case "log" where names.count == 1: onLog?(names[0].rawValue, false, nil)
        case "browse" where names.count == 1: onBrowse?(names[0].rawValue)
        case "working" where names.count == 1 && snapshot?.bare == false: onCompare?(.revision(names[0].rawValue), .workingTree)
        case "compare" where names.count == 2: onCompare?(.revision(names[0].rawValue), .revision(names[1].rawValue))
        case "range", "symmetric": if let range = ReferenceBrowserRange(references: names, lastSelected: lastSelected) { onLog?(nil, false, range.history(symmetric: command == "symmetric")) }
        case "unified" where names.count == 2:
            let alternate = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            performRead { [weak self] token in
                guard let self else { return }
                let data = try await repository.revisionComparison(from: .revision(names[0].rawValue), to: .revision(names[1].rawValue), cancellation: token)
                let bytes = try await repository.revisionComparisonPatchData(data, cancellation: token)
                guard !closed, !token.isCancelled else { return }
                if let onUnified { try await onUnified(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate), !closed, !token.isCancelled {
                    unifiedViewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedViewer, title: names.map(\.rawValue).joined(separator: ":"), onClosed: { [weak self] in self?.unifiedViewer = nil })
                }
            }
        default: break
        }
    }
}
