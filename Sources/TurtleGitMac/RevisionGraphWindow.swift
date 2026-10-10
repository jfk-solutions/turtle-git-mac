// Native replacement of TortoiseGit's RevisionGraphDlg/RevisionGraphWnd.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import TurtleGitCore
import UniformTypeIdentifiers

final class RevisionGraphSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// RevisionGraphDlgDraw uses solid COLORLINE fills and sRGB luminance,
// independently of GitLogListBase's contrast threshold.
@MainActor enum RevisionGraphPalette {
    static func background(_ role: LogColorRole?, pointer: Bool, preferences: UserDefaults) -> NSColor {
        if pointer {
            let traits = StatusTextPalette.appearanceTraits(NSAppearance.current)
            let rgb = StatusTextPalette.transform([246, 153, 253], dark: traits.dark, highContrast: traits.highContrast)
            return NSColor(srgbRed: CGFloat(rgb[0])/255, green: CGFloat(rgb[1])/255, blue: CGFloat(rgb[2])/255, alpha: 1)
        }
        if var role {
            if role == .bisectSkip { role = .bisectBad }
            if role == .currentBranch, preferences.bool(forKey: "Graph.RevGraphUseLocalForCur") { role = .localBranch }
            return LogPalette.native(role, preferences: preferences)
        }
        // LimitedScaleColor(window, red, .9): the upstream unlabelled commit tint.
        let window = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: 0.1 + window.redComponent * 0.9, green: window.greenComponent * 0.9, blue: window.blueComponent * 0.9, alpha: 1)
    }
    static func foreground(_ background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.5 ? .black : .white
    }
}

@MainActor final class RevisionGraphWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let layoutExecutable: URL?
    var options = RevisionGraphOptions()
    @Published private(set) var nodes: [RevisionGraphNode] = []
    @Published private(set) var geometry: RevisionGraphLayout?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var selection: [String] = []
    var zoom: CGFloat = 1
    var showOverview = false
    var arrowsTowardMerges = false
    private(set) var closed = false
    private var generation = UUID()
    private var cancellation: OperationCancellation?
    private var worker: Task<Void, Never>?
    private(set) var pointers: [String: [String]] = [:]
    var changed: () -> Void = {}
    var becameIdle: () -> Void = {}
    var onLog: (String) -> Void = { _ in }
    var onLogRange: (HistoryRevisionRange) -> Void = { _ in }
    var onSwitchBranch: (String) -> Void = { _ in }
    let sshSettings: SSHTransportSettings
    var confirmReferenceDeletion: (HistoryReferenceDeletion) async -> HistoryReferenceDeleteChoice = { _ in .abort }
    var acknowledgeReferenceDeletionFailure: (String) async -> Void = { _ in }
    var copyReferences: (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private(set) var bare = false
    var onBrowse: (String) -> Void = { _ in }
    var onCompare: (ComparisonRevision, ComparisonRevision) -> Void = { _, _ in }
    var onCheckout: (String) -> Void = { _ in }
    var onUnified: (Data) -> Void = { _ in }
    static let font = NSFont.systemFont(ofSize: 12)
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, layoutExecutable: URL? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences; self.layoutExecutable = layoutExecutable; sshSettings = SSHTransportSettings(repository: repository)
        // InitialSetMenu defaults and keys from RevisionGraphDlg.cpp. These
        // display choices are global; the revision filter and zoom are transient.
        showOverview = preferences.bool(forKey: "ShowRevGraphOverview")
        arrowsTowardMerges = preferences.bool(forKey: "ArrowPointToMerges")
        options.showBranchingsAndMerges = preferences.bool(forKey: "ShowRevGraphBranchesMerges")
        options.showAllTags = preferences.object(forKey: "ShowRevGraphAllTags") == nil ? true : preferences.bool(forKey: "ShowRevGraphAllTags")
        options.showSuperprojectPointers = preferences.object(forKey: "LogShowSuperProjectSubmodulePointer") == nil ? true : preferences.bool(forKey: "LogShowSuperProjectSubmodulePointer")
    }
    deinit { cancellation?.cancel(); worker?.cancel() }
    func lines(_ node: RevisionGraphNode, pointers: [String: [String]]? = nil) -> [(String, LogColorRole?, Bool)] {
        var result: [(String, LogColorRole?, Bool)] = []
        for label in (pointers ?? self.pointers)[node.hash] ?? [] { result.append((label, .otherRef, true)) }
        result += node.references.isEmpty ? [(String(node.hash.prefix(8)), nil, false)] : node.references.map { ($0.label, LogColorRole.reference($0), false) }
        return result
    }
    func load() {
        guard !closed, !busy else { return }
        busy = true; error = nil; changed()
        let token = OperationCancellation(), request = UUID(), options = self.options
        cancellation = token; generation = request
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == request { busy = false; cancellation = nil; worker = nil; changed(); becameIdle() }
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let isBare = try await repository.isBare(cancellation: token)
                let graph = try await repository.revisionGraph(options: options, cancellation: token)
                guard !closed, !token.isCancelled, request == generation else { return }
                let sizes = graph.nodes.map { node -> CGSize in
                    let labels = self.lines(node, pointers: graph.superprojectLabels)
                    let widths = labels.map { ($0.0 as NSString).size(withAttributes: [.font: Self.font]).width }
                    return CGSize(width: ceil(max(widths.max() ?? 0, ("88888888" as NSString).size(withAttributes: [.font: Self.font]).width)) + 40, height: CGFloat(labels.count) * (ceil(Self.font.ascender - Self.font.descender) + 10))
                }
                let executable = layoutExecutable
                let layout = try await Task.detached {
                    try RevisionGraphLayoutRuntime.layout(nodes: graph.nodes, sizes: sizes, executable: executable, cancellation: token)
                }.value
                guard !closed, !token.isCancelled, request == generation else { return }
                bare = isBare; nodes = graph.nodes; pointers = graph.superprojectLabels; geometry = layout
                selection = selection.filter { hash in self.nodes.contains { $0.hash == hash } }
            } catch { if !closed, !token.isCancelled, request == generation { self.error = error.localizedDescription } }
        }
    }
    func cancel() { cancellation?.cancel(); worker?.cancel() }
    func invalidate() { closed = true; generation = UUID(); cancel(); changed = {}; becameIdle = {} }
    func select(_ hash: String?, extending: Bool) {
        guard !busy, !closed else { return }
        guard let hash else { selection = []; changed(); return }
        if extending {
            if let index = selection.firstIndex(of: hash) { selection.remove(at: index) }
            else { if selection.count == 2 { selection.removeLast() }; selection.append(hash) }
        } else { selection = [hash] }
        changed()
    }
    // Mouse selection toggles the first node; programmatic routing keeps select
    // idempotent so opening a menu or restoring a selection cannot clear it.
    func clickSelection(_ hash: String?, extending: Bool) {
        guard !busy, !closed else { return }
        if extending, hash == nil { return }
        if !extending, hash == selection.first { select(nil, extending: false) }
        else { select(hash, extending: extending) }
    }
    static func fullReferenceName(_ ref: RevisionReference) -> String { ref.kind == .annotatedTag ? ref.name + "^{}" : ref.name }
    func friendName(_ hash: String) -> String { nodes.first { $0.hash == hash }?.references.first.map(Self.fullReferenceName) ?? hash }
    func compare(head: Bool = false, working: Bool = false) {
        guard !busy, !closed, let first = selection.first, (head || working) ? selection.count == 1 : selection.count == 2, !working || !bare else { return }
        onCompare(.revision(friendName(first)), working ? .workingTree : .revision(head ? "HEAD" : friendName(selection[1])))
    }
    var selectedNode: RevisionGraphNode? { selection.count == 1 ? nodes.first { $0.hash == selection[0] } : nil }
    var deletableReferences: [RevisionReference] {
        // GetFriendRefNames excludes the current branch's short name for every
        // reference kind, including a same-named tag; retain its ordinal check.
        let current = nodes.lazy.flatMap(\.references).first { $0.isCurrent }?.label
        return selectedNode?.references.filter { ref in !ref.isCurrent && (current.map { !GitReferenceName.equal(ref.label, $0) } ?? true) } ?? []
    }
    var switchBranches: [RevisionReference] { deletableReferences.filter { $0.name.utf8.starts(with: "refs/heads/".utf8) } }
    var checkoutReference: RevisionReference? {
        guard switchBranches.isEmpty else { return nil }
        let refs = deletableReferences
        return refs.first { $0.name.utf8.starts(with: "refs/remotes/".utf8) }
            ?? refs.first { $0.name.utf8.starts(with: "refs/tags/".utf8) && $0.kind != .annotatedTag }
            ?? refs.first { $0.name.utf8.starts(with: "refs/tags/".utf8) }
    }
    func showLog() {
        guard !busy, !closed, let first = selection.first else { return }
        if selection.count == 2 { onLogRange(HistoryRevisionRange(from: first, to: selection[1])) }
        else { onLog(first) }
    }
    func copyRefNames() {
        guard !busy, !closed, let node = selectedNode else { return }
        copyReferences(node.references.isEmpty ? node.hash : node.references.map(Self.fullReferenceName).joined(separator: "\n"))
    }
    func deleteReferences(_ names: [String], hash: String) {
        guard !busy, !closed, selectedNode?.hash == hash, !names.isEmpty,
              names.allSatisfy({ name in deletableReferences.contains { GitReferenceName.equal($0.name, name) } }) else { return }
        let token = OperationCancellation(), request = UUID(), factory = sshSettings.capture()
        busy = true; error = nil; cancellation = token; generation = request; changed()
        worker = Task { [weak self] in
            guard let self else { return }
            let coordinator = factory?(); var refresh = false
            defer {
                coordinator?.close()
                if generation == request {
                    busy = false; cancellation = nil; worker = nil; changed(); becameIdle()
                    if refresh, !closed { load() }
                }
                withExtendedLifetime(access) {}
            }
            for name in names {
                guard !closed, generation == request, !token.isCancelled, selectedNode?.hash == hash else { break }
                var choice = HistoryReferenceDeleteChoice.abort
                do {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let snapshot = try await repository.prepareHistoryReferenceDeletion(name, cancellation: token)
                    let resolved = try await repository.run(["rev-parse", "--verify", "--end-of-options", snapshot.name + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
                    guard resolved == hash else { throw HistoryReferenceDeletionFailure.changed }
                    choice = await confirmReferenceDeletion(snapshot)
                    guard choice != .abort, !closed, !token.isCancelled, generation == request else { break }
                    _ = try await repository.deleteHistoryReference(snapshot, choice: choice, cancellation: token, prepareTransport: coordinator?.preparation)
                    refresh = true
                } catch {
                    guard !closed, !token.isCancelled else { break }
                    self.error = error.localizedDescription
                    await acknowledgeReferenceDeletionFailure(error.localizedDescription)
                    if [.remoteAndLocal, .stashAll, .stashOne].contains(choice) { refresh = true } else { break }
                }
            }
        }
    }
    func unified(head: Bool) {
        guard !busy, !closed, let first = selection.first, head ? selection.count == 1 : selection.count == 2 else { return }
        let from = friendName(first), to = head ? "HEAD" : friendName(selection[1])
        let token = OperationCancellation(), request = UUID()
        busy = true; cancellation = token; generation = request; changed()
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if request == generation { busy = false; cancellation = nil; worker = nil; changed(); becameIdle() }; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let a = try await repository.run(["rev-parse", "--verify", "--end-of-options", from + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
                let b = try await repository.run(["rev-parse", "--verify", "--end-of-options", to + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
                let bytes = try await repository.run(["diff", "--no-ext-diff", "--no-color", a, b, "--"], cancellation: token).stdout
                guard !closed, request == generation, !token.isCancelled else { return }; onUnified(bytes)
            } catch { if !closed, request == generation, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

final class RevisionGraphNativeWindow: NSWindow {
    var command: (String) -> Void = { _ in }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { command("refresh"); return true }
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers {
            if key == "+" || key == "=" { command("zoomIn"); return true }
            if key == "-" { command("zoomOut"); return true }
            if key == "f" { command("find"); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum RevisionGraphReferenceCommand {
    case switchBranch(String, hash: String), checkout(String, hash: String), delete([String], hash: String)
}

@MainActor final class RevisionGraphWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSComboBoxDelegate {
    let model: RevisionGraphWindowModel
    let canvas: RevisionGraphCanvas
    let scroll = NSScrollView()
    let status = NSTextField(labelWithString: "")
    let zoomBox = NSComboBox()
    private var displayedZoom: CGFloat?
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var toolbarButtons: [NSButton] = []
    private let overview: RevisionGraphOverview
    private(set) var filter: RevisionGraphFilterController?
    private(set) var find: RevisionGraphFindController?
    private var hasFindError: Bool { find?.acknowledgingFailure == true || find?.window?.attachedSheet != nil }
    private var closing = false
    private var exporting = false
    private var pendingRepositoryRefresh = false
    private var unifiedViewer: PatchWindowController?
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, layoutExecutable: URL? = nil, automaticallyLoad: Bool = true) {
        let model = RevisionGraphWindowModel(repository: repository, access: access, preferences: preferences, layoutExecutable: layoutExecutable)
        self.model = model; canvas = RevisionGraphCanvas(model: model); overview = RevisionGraphOverview(model: model)
        let window = RevisionGraphNativeWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 670), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Revision Graph – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = CGSize(width: 700, height: 420)
        super.init(window: window); window.delegate = self
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 8
        for (title, commands) in [("File", [("Save graph as…", "save"), ("Exit", "close")]),
                                 ("View", [("Zoom in", "zoomIn"), ("Zoom out", "zoomOut"), ("Zoom to 100%", "zoom100"), ("Fit height", "fitHeight"), ("Fit width", "fitWidth"), ("Fit graph", "fit"), ("Filter…", "filter"), ("Find…", "find"), ("Show Overview", "overview"), ("Show branchings and merges", "branchings"), ("Show all tags", "tags"), ("Arrows point towards merges", "arrows")]),
                                 ("Git", [("Compare revisions", "compare"), ("Compare HEAD revisions", "compareHead"), ("Unified diff", "unified"), ("Unified diff of HEAD revisions", "unifiedHead")]), ("Help", [("Help", "help")])] {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true); popup.addItem(withTitle: title)
            for (label, command) in commands { popup.menu?.addItem(menuItem(label, command: command)) }
            bar.addArrangedSubview(popup)
        }
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 2
        toolbar.identifier = NSUserInterfaceItemIdentifier("RevisionGraphToolbar")
        func addButton(_ title: String, _ command: String, _ image: NSImage?) {
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .regularSquare; button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(command); button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 27).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            toolbarButtons.append(button); toolbar.addArrangedSubview(button)
        }
        func separator() {
            let line = NSBox(); line.boxType = .separator
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 22).isActive = true
            toolbar.addArrangedSubview(line)
        }
        for (title, command, icon) in [("Zoom in", "zoomIn", RevisionGraphToolbarIcon.zoomIn), ("Zoom out", "zoomOut", .zoomOut), ("Zoom to 100%", "zoom100", .zoom100), ("Fit height", "fitHeight", .fitHeight), ("Fit width", "fitWidth", .fitWidth), ("Fit graph", "fit", .fitGraph)] {
            addButton(title, command, icon.image())
        }
        separator()
        // Upstream inserts each preset at index zero, producing descending order.
        zoomBox.addItems(withObjectValues: ["200%", "100%", "75%", "50%", "40%", "20%", "10%", "5%"])
        zoomBox.isEditable = true; zoomBox.completes = false; zoomBox.alignment = .right
        zoomBox.delegate = self; zoomBox.target = self; zoomBox.action = #selector(commitZoom(_:))
        zoomBox.setAccessibilityLabel("Zoom percentage"); zoomBox.toolTip = "Zoom percentage"
        zoomBox.widthAnchor.constraint(equalToConstant: 82).isActive = true; toolbar.addArrangedSubview(zoomBox)
        separator(); addButton("Filter", "filter", RevisionGraphToolbarIcon.filter.image())
        separator(); addButton("Show Overview", "overview", RevisionGraphToolbarIcon.overview.image())
        separator(); addButton("Find", "find", RevisionGraphToolbarIcon.find.image())
        separator(); addButton("Refresh", "refresh", MenuIcon.refresh.image(size: 20))
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 560)); host.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = canvas
        scroll.frame = CGRect(x: 0, y: 0, width: 960, height: 560); scroll.autoresizingMask = [.width, .height]; host.addSubview(scroll)
        overview.scroll = scroll; host.addSubview(overview)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        let footer = NSStackView(views: [status, cancelButton]); footer.orientation = .horizontal; footer.distribution = .fill; footer.spacing = 12
        cancelButton.target = self; cancelButton.action = #selector(cancelGraphOperation)
        let stack = NSStackView(views: [bar, toolbar, host, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8); stack.translatesAutoresizingMaskIntoConstraints = false
        let content = RevisionGraphSurface(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor), host.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16), host.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        host.setContentHuggingPriority(.defaultLow, for: .vertical); host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvas.interactionAllowed = { [weak self] in self?.hasFindError == false }
        overview.interactionAllowed = { [weak self] in self?.hasFindError == false }
        canvas.contextMenu = { [weak self] in self?.nodeMenu() ?? NSMenu() }
        model.changed = { [weak self] in self?.update() }
        model.becameIdle = { [weak self] in if self?.closing == true { self?.window?.close() } }
        model.onUnified = { [weak self] bytes in guard let self else { return }; self.unifiedViewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.unifiedViewer, title: "Revision Graph changes", onClosed: { [weak self] in self?.unifiedViewer = nil }) }
        model.confirmReferenceDeletion = { [weak self, weak window] request in
            guard let self, let window, window.attachedSheet == nil, !self.hasFindError else { return .abort }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = request.message
                for option in request.choices { alert.addButton(withTitle: option.title).keyEquivalent = "" }
                let abort = alert.buttons.last!; abort.keyEquivalent = "\r"; window.makeFirstResponder(nil)
                alert.window.defaultButtonCell = abort.cell as? NSButtonCell; abort.keyEquivalent = "\r"
                alert.window.alphaValue = window.alphaValue
                alert.beginSheetModal(for: window) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    continuation.resume(returning: request.choices.indices.contains(index) ? request.choices[index].choice : .abort)
                }
                // NSAlert layout clears custom equivalents during presentation.
                for button in alert.buttons { button.keyEquivalent = ""; button.keyEquivalentModifierMask = [] }
                abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
            }
        }
        model.acknowledgeReferenceDeletionFailure = { [weak self, weak window] message in
            guard let self, let window, window.attachedSheet == nil, !self.hasFindError else { return }
            await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Could not delete reference."; alert.informativeText = message
                alert.addButton(withTitle: "OK"); alert.window.alphaValue = window.alphaValue
                alert.beginSheetModal(for: window) { _ in continuation.resume() }
            }
        }
        model.sshSettings.load(preferences, key: "Graph.AutoLoadSSHKey")
        model.sshSettings.present = { [weak window] prompt in
            guard let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            child.alphaValue = window.alphaValue; window.beginSheet(child); return true
        }
        window.command = { [weak self] in self?.perform($0) }; update(); window.center()
        DialogGeometry.attach(window, identifier: "RevisionGraph")
        if automaticallyLoad { model.load() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func menuItem(_ title: String, command: String, icon: MenuIcon? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command
        item.image = icon?.contextImage(defaults: model.preferences); return item
    }
    private func referenceItem(_ title: String, command: RevisionGraphReferenceCommand, icon: MenuIcon) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = command; item.image = icon.contextImage(defaults: model.preferences); return item
    }
    func nodeMenu() -> NSMenu {
        let menu = NSMenu(); guard !model.busy, window?.attachedSheet == nil && !hasFindError, !model.selection.isEmpty else { return menu }
        menu.addItem(menuItem("Show Log", command: "log", icon: .log))
        if let node = model.selectedNode {
            menu.addItem(menuItem("Browse repository", command: "browse", icon: .repositoryBrowser))
            let branches = model.switchBranches
            if branches.count == 1 {
                menu.addItem(referenceItem("Switch to branch \"" + branches[0].label + "\"", command: .switchBranch(branches[0].name, hash: node.hash), icon: .checkout))
            } else if branches.count > 1 {
                let parent = menuItem("Switch to branch", command: "referenceSubmenu", icon: .checkout), child = NSMenu()
                for ref in branches { child.addItem(referenceItem(ref.label, command: .switchBranch(ref.name, hash: node.hash), icon: .checkout)) }
                parent.submenu = child; menu.addItem(parent)
            } else if let ref = model.checkoutReference {
                menu.addItem(referenceItem("Switch/Checkout to this…", command: .checkout(ref.name, hash: node.hash), icon: .checkout))
            }
            menu.addItem(menuItem("Copy ref names", command: "copyRefs", icon: .copy))
            let refs = model.deletableReferences
            if refs.count == 1 { menu.addItem(referenceItem("Delete " + RevisionGraphWindowModel.fullReferenceName(refs[0]), command: .delete([refs[0].name], hash: node.hash), icon: .remove)) }
            else if refs.count > 1 {
                let parent = menuItem("Delete branch/tag", command: "referenceSubmenu", icon: .remove), child = NSMenu()
                for ref in refs { child.addItem(referenceItem(RevisionGraphWindowModel.fullReferenceName(ref), command: .delete([ref.name], hash: node.hash), icon: .remove)) }
                child.addItem(referenceItem("All", command: .delete(refs.map(\.name), hash: node.hash), icon: .remove))
                parent.submenu = child; menu.addItem(parent)
            }
            menu.addItem(menuItem("Compare with HEAD", command: "compareHead", icon: .compare))
            menu.addItem(menuItem("Unified diff with HEAD", command: "unifiedHead", icon: .unifiedDiff))
            menu.addItem(menuItem("Compare with working tree", command: "compareWorking", icon: .compare))
        } else {
            menu.addItem(menuItem("Compare revisions", command: "compare", icon: .compare))
            menu.addItem(menuItem("Unified diff", command: "unified", icon: .unifiedDiff))
        }
        return menu
    }
    @objc private func menuCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { perform(command); return }
        guard validateMenuItem(sender), let command = sender.representedObject as? RevisionGraphReferenceCommand else { return }
        switch command {
        case .switchBranch(let name, _): model.onSwitchBranch(name)
        case .checkout(let name, _): model.onCheckout(name)
        case .delete(let names, let hash): model.deleteReferences(names, hash: hash)
        }
    }
    @objc private func clicked(_ sender: NSButton) { if let command = sender.identifier?.rawValue { perform(command) } }
    @objc private func commitZoom(_ sender: Any?) {
        guard !model.busy, !model.closed, filter == nil, !exporting, window?.attachedSheet == nil && !hasFindError else { synchronizeZoom(force: true); return }
        let scanner = Scanner(string: zoomBox.stringValue); scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let percent = scanner.scanDouble() else { synchronizeZoom(force: true); return }
        _ = scanner.scanString("%")
        let zoom = CGFloat(percent / 100)
        let size = model.geometry?.size ?? CGSize(width: 1, height: 1)
        // Unlike the fixed zoom buttons, upstream accepts custom scales above
        // 200%. Reject values that cannot form finite native view geometry.
        guard scanner.isAtEnd, percent.isFinite, percent > 0, percent <= Double(Int32.max), zoom > 0, (1 / zoom).isFinite,
              size.width * zoom + 20 <= CGFloat(Int32.max), size.height * zoom + 20 <= CGFloat(Int32.max) else { synchronizeZoom(force: true); return }
        model.zoom = zoom; model.changed()
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSComboBox === zoomBox, zoomBox.indexOfSelectedItem >= 0 else { return }
        zoomBox.stringValue = zoomBox.itemObjectValue(at: zoomBox.indexOfSelectedItem) as? String ?? zoomBox.stringValue
        commitZoom(zoomBox)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSComboBox === zoomBox { commitZoom(zoomBox) }
    }
    private func synchronizeZoom(force: Bool = false) {
        guard force || displayedZoom != model.zoom else { return }
        displayedZoom = model.zoom; zoomBox.stringValue = String(format: "%.0f%%", model.zoom * 100)
    }
    @objc private func cancelGraphOperation() { model.cancel() }
    @objc private func scrolled() { overview.needsDisplay = true }
    func windowDidResize(_ notification: Notification) { update() }
    @objc private func sheetEnded() { update() }
    func requestRepositoryRefresh() { guard !model.closed else { return }; pendingRepositoryRefresh = true; update() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let target = item.representedObject as? RevisionGraphReferenceCommand {
            guard !model.busy, !model.closed, filter == nil, !exporting, window?.attachedSheet == nil && !hasFindError, let node = model.selectedNode else { return false }
            switch target {
            case .switchBranch(let name, let hash): return !model.bare && node.hash == hash && model.switchBranches.contains { GitReferenceName.equal($0.name, name) }
            case .checkout(let name, let hash): return !model.bare && node.hash == hash && model.checkoutReference.map { GitReferenceName.equal($0.name, name) } == true
            case .delete(let names, let hash): return node.hash == hash && !names.isEmpty && names.allSatisfy { name in model.deletableReferences.contains { GitReferenceName.equal($0.name, name) } }
            }
        }
        guard let command = item.representedObject as? String else { return true }
        item.state = ((command == "overview" && model.showOverview) || (command == "branchings" && model.options.showBranchingsAndMerges) || (command == "tags" && model.options.showAllTags) || (command == "arrows" && model.arrowsTowardMerges)) ? .on : .off
        if model.busy || model.closed || filter != nil || exporting || window?.attachedSheet != nil || hasFindError { return command == "close" }
        if ["compare", "unified"].contains(command) { return model.selection.count == 2 }
        if ["compareHead", "compareWorking", "unifiedHead", "log", "browse", "copyRefs"].contains(command) { return command == "log" ? !model.selection.isEmpty : model.selection.count == 1 && (command != "compareWorking" || !model.bare) }
        return true
    }
    func perform(_ command: String) {
        if command == "close" { window?.performClose(nil); return }
        guard !model.busy, !model.closed, filter == nil, !exporting, window?.attachedSheet == nil && !hasFindError else { return }
        switch command {
        case "refresh": model.load()
        case "zoomIn": model.zoom = min(2, model.zoom / 0.9)
        case "zoomOut": model.zoom = max(0.01, model.zoom * 0.9)
        case "zoom100": model.zoom = 1
        case "fit", "fitWidth", "fitHeight":
            if let size = model.geometry?.size, size.width > 0, size.height > 0 {
                let viewport = scroll.contentSize; let x = (viewport.width - 20) / size.width, y = (viewport.height - 20) / size.height
                model.zoom = max(0.01, min(2, command == "fitWidth" ? x : command == "fitHeight" ? y : min(x, y)))
            }
        case "overview": model.showOverview.toggle(); model.preferences.set(model.showOverview, forKey: "ShowRevGraphOverview")
        case "arrows": model.arrowsTowardMerges.toggle(); model.preferences.set(model.arrowsTowardMerges, forKey: "ArrowPointToMerges")
        case "branchings": model.options.showBranchingsAndMerges.toggle(); model.preferences.set(model.options.showBranchingsAndMerges, forKey: "ShowRevGraphBranchesMerges"); model.load()
        case "tags": model.options.showAllTags.toggle(); model.preferences.set(model.options.showAllTags, forKey: "ShowRevGraphAllTags"); model.load()
        case "filter": showFilter()
        case "find": showFind()
        case "compare": model.compare()
        case "compareHead": model.compare(head: true)
        case "compareWorking": model.compare(working: true)
        case "unified", "unifiedHead": model.unified(head: command == "unifiedHead")
        case "log": model.showLog()
        case "browse": if let hash = model.selectedNode?.hash { model.onBrowse(model.friendName(hash)) }
        case "copyRefs": model.copyRefNames()
        case "save": saveGraph()
        case "help": NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-revgraph.html")!)
        default: break
        }
        update()
    }
    func update() {
        synchronizeZoom()
        find?.updateAvailability()
        zoomBox.isEnabled = !model.busy && !model.closed && filter == nil && !exporting && window?.attachedSheet == nil && !hasFindError
        for button in toolbarButtons {
            button.isEnabled = zoomBox.isEnabled
            button.state = button.identifier?.rawValue == "overview" && model.showOverview ? .on : .off
        }
        canvas.resize(to: scroll.contentSize); canvas.needsDisplay = true; overview.updateFrame(); overview.needsDisplay = true
        overview.isHidden = !model.showOverview || model.busy || model.nodes.isEmpty || model.nodes.count > 10_000
        status.stringValue = model.error ?? (model.busy ? "Loading…" : "\(model.nodes.count) revisions • \(Int((model.zoom * 100).rounded()))%")
        cancelButton.isEnabled = model.busy
        if pendingRepositoryRefresh, !model.closed, !model.busy, !closing, filter == nil, !exporting, window?.attachedSheet == nil && !hasFindError {
            pendingRepositoryRefresh = false; model.load()
        }
    }
    func showFilter() {
        guard let window, window.attachedSheet == nil, !hasFindError else { return }
        let filter = RevisionGraphFilterController(model: model) { [weak self] options in
            guard let self else { return }; self.filter = nil
            if let options { self.pendingRepositoryRefresh = false; self.model.options = options; self.model.load() }
            self.update()
        }
        self.filter = filter; if let child = filter.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        update()
    }
    private func saveGraph() {
        guard let window, window.attachedSheet == nil, model.geometry != nil else { return }
        let picker = RevisionGraphSavePanel(); exporting = true
        picker.panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            var failure: String?
            defer { self.exporting = false; self.update(); if let failure { self.status.stringValue = failure } }
            if response == .OK, let url = picker.panel.url {
                do {
                    let data = try RevisionGraphExport.data(canvas: self.canvas, viewport: self.scroll.contentSize, format: picker.format, appearance: window.effectiveAppearance)
                    try data.write(to: url, options: .atomic)
                } catch { failure = error.localizedDescription }
            }
        }
    }

    func showFind(regexExecutable: URL? = nil) {
        guard !model.closed, !model.busy, filter == nil, !exporting, let parent = window, parent.attachedSheet == nil, !hasFindError else { return }
        if let find { find.window?.makeKey(); return }
        let child = RevisionGraphFindController(repository: model.repository, access: model.access, preferences: model.preferences, regexExecutable: regexExecutable)
        find = child
        child.snapshot = { [weak model] in model?.nodes ?? [] }
        child.canSearch = { [weak self] in guard let self else { return false }; return !self.model.closed && !self.model.busy && self.filter == nil && !self.exporting && self.window?.attachedSheet == nil && !self.hasFindError }
        child.navigate = { [weak self] hash, select in
            guard let self, let rect = self.model.geometry?.nodes.first(where: { $0.hash == hash })?.rect else { return }
            if select { self.model.select(hash, extending: false) }
            let point = NSPoint(x: rect.minX * self.model.zoom + 10, y: max(0, rect.minY * self.model.zoom + 10 - max(1, 25 * self.model.zoom)))
            self.scroll.contentView.scroll(to: self.scroll.contentView.constrainBoundsRect(NSRect(origin: point, size: self.scroll.contentView.bounds.size)).origin)
            self.scroll.reflectScrolledClipView(self.scroll.contentView); self.overview.needsDisplay = true
        }
        child.modalChanged = { [weak self] in self?.update() }
        child.onClosed = { [weak self, weak parent] in
            if let window = self?.find?.window { parent?.removeChildWindow(window) }; self?.find = nil
        }
        if let window = child.window { window.alphaValue = parent.alphaValue; window.appearance = parent.appearance; parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.searchBox) }
        child.updateAvailability(); child.loadReferences()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil, !hasFindError, filter == nil, !exporting, unifiedViewer?.model.busy != true, unifiedViewer?.window?.attachedSheet == nil else { return false }
        if model.busy { closing = true; model.cancel(); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self); model.invalidate(); unifiedViewer?.close(); unifiedViewer = nil
        filter?.close(); filter = nil; find?.close(); find = nil; onClosed()
    }
}

@MainActor final class RevisionGraphCanvas: NSView, NSViewToolTipOwner {
    var interactionAllowed: () -> Bool = { true }
    let model: RevisionGraphWindowModel
    var contextMenu: () -> NSMenu = { NSMenu() }
    private var panPoint: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: RevisionGraphWindowModel) { self.model = model; super.init(frame: CGRect(x: 0, y: 0, width: 900, height: 550)); setAccessibilityRole(.group); setAccessibilityLabel("Revision Graph") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func resize(to viewport: CGSize) {
        let size = model.geometry?.size ?? .zero
        setFrameSize(CGSize(width: max(viewport.width, size.width * model.zoom + 20), height: max(viewport.height, size.height * model.zoom + 20)))
        removeAllToolTips()
        for node in model.geometry?.nodes ?? [] {
            let rect = CGRect(x: node.rect.minX * model.zoom + 10, y: node.rect.minY * model.zoom + 10, width: node.rect.width * model.zoom, height: node.rect.height * model.zoom)
            addToolTip(rect, owner: self, userData: nil)
        }
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard let hash = hit(point), let node = model.nodes.first(where: { $0.hash == hash }) else { return "" }
        return [hash, node.author, node.authorDate, node.message].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        if model.busy || model.nodes.isEmpty {
            ((model.busy ? "Loading…" : "No graph available") as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]); return
        }
        NSGraphicsContext.saveGraphicsState(); let transform = NSAffineTransform(); transform.translateX(by: 10, yBy: 10); transform.scale(by: model.zoom); transform.concat()
        drawGraph(text: true); NSGraphicsContext.restoreGraphicsState()
    }
    func drawGraph(text: Bool, renderingZoom: CGFloat? = nil) {
        let zoom = renderingZoom ?? model.zoom
        guard let geometry = model.geometry else { return }
        NSColor.labelColor.setStroke()
        for edge in geometry.edges {
            let points = model.arrowsTowardMerges ? Array(edge.points.reversed()) : edge.points
            guard let start = points.first, let end = points.last else { continue }
            let path = NSBezierPath(); path.move(to: start); for point in points.dropFirst() { path.line(to: point) }; path.lineWidth = 2; path.stroke()
            let previous = points[points.count - 2], angle = atan2(end.y - previous.y, end.x - previous.x), length: CGFloat = 8
            let arrow = NSBezierPath(); arrow.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 8), y: end.y - length * sin(angle - .pi / 8))); arrow.line(to: end); arrow.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 8), y: end.y - length * sin(angle + .pi / 8))); arrow.lineWidth = 2; arrow.stroke()
        }
        let nodes = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.hash, $0) })
        for geometry in geometry.nodes {
            guard let node = nodes[geometry.hash] else { continue }
            let rect = geometry.rect, path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            let labels = model.lines(node), height = rect.height / CGFloat(labels.count)
            for (index, label) in labels.enumerated() {
                let row = CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * height, width: rect.width, height: height)
                let background = RevisionGraphPalette.background(label.1, pointer: label.2, preferences: model.preferences)
                background.setFill(); row.fill()
                if text {
                    let attributes: [NSAttributedString.Key: Any] = [.font: RevisionGraphWindowModel.font, .foregroundColor: RevisionGraphPalette.foreground(background)]
                    let size = (label.0 as NSString).size(withAttributes: attributes)
                    (label.0 as NSString).draw(at: CGPoint(x: rect.minX + 20, y: row.midY - size.height / 2), withAttributes: attributes)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            if let index = model.selection.firstIndex(of: node.hash) {
                let color = index == 0 ? NSColor.selectedControlColor : NSColor(srgbRed: 136.0/255, green: 0, blue: 21.0/255, alpha: 1)
                color.setStroke(); path.lineWidth = max(4, 1 / zoom); path.stroke()
                if text {
                    let marker = NSBezierPath(); marker.lineWidth = path.lineWidth
                    for x in (index == 0 ? [CGFloat(10)] : [CGFloat(5), CGFloat(15)]) {
                        marker.move(to: CGPoint(x: rect.minX + x, y: rect.minY - 25)); marker.line(to: CGPoint(x: rect.minX + x, y: rect.minY - 5))
                    }
                    marker.stroke()
                    if index == 0, model.selection.count == 2 {
                        ("(Base)" as NSString).draw(at: CGPoint(x: rect.minX + 14, y: rect.minY - 25), withAttributes: [.font: RevisionGraphWindowModel.font, .foregroundColor: color])
                    }
                }
            }
        }
    }
    func hit(_ point: CGPoint) -> String? {
        let p = CGPoint(x: (point.x - 10) / model.zoom, y: (point.y - 10) / model.zoom)
        return model.geometry?.nodes.first { $0.rect.contains(p) }?.hash
    }
    override func mouseDown(with event: NSEvent) {
        panPoint = nil
        guard interactionAllowed(), !model.busy, !model.closed else { return }
        window?.makeFirstResponder(self)
        let hash = hit(convert(event.locationInWindow, from: nil))
        let extending = !event.modifierFlags.intersection([.command, .control]).isEmpty
        model.clickSelection(hash, extending: extending)
        if hash == nil, !extending { panPoint = event.locationInWindow }
    }
    override func mouseDragged(with event: NSEvent) {
        guard interactionAllowed(), !model.busy, !model.closed, let previous = panPoint, let scroll = enclosingScrollView else { panPoint = nil; return }
        let clip = scroll.contentView
        let before = clip.convert(previous, from: nil), after = clip.convert(event.locationInWindow, from: nil)
        self.scroll(to: NSPoint(x: clip.bounds.minX - (after.x - before.x), y: clip.bounds.minY - (after.y - before.y)))
        panPoint = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) { panPoint = nil }
    private func scroll(to origin: NSPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
    override func scrollWheel(with event: NSEvent) {
        guard interactionAllowed(), !model.busy, !model.closed else { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            guard event.scrollingDeltaY != 0 else { return }
            model.zoom = max(0.01, min(2, model.zoom * (event.scrollingDeltaY < 0 ? 0.9 : 1 / 0.9)))
            model.changed()
        } else if event.modifierFlags.contains(.shift), let clip = enclosingScrollView?.contentView {
            // Precise trackpad events retain AppKit's acceleration and phases.
            if event.hasPreciseScrollingDeltas { super.scrollWheel(with: event); return }
            scroll(to: NSPoint(x: clip.bounds.minX - event.scrollingDeltaY, y: clip.bounds.minY - event.scrollingDeltaX))
        } else { super.scrollWheel(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionAllowed(), !model.busy, !model.closed, let hash = hit(convert(event.locationInWindow, from: nil)) else { return nil }
        // Upstream preserves a selected pair and rejects menus on a third node.
        if model.selection.count == 2, !model.selection.contains(hash) { return nil }
        if !model.selection.contains(hash) { model.select(hash, extending: false) }
        return contextMenu()
    }
}

@MainActor final class RevisionGraphOverview: NSView {
    var interactionAllowed: () -> Bool = { true }
    let model: RevisionGraphWindowModel
    weak var scroll: NSScrollView?
    override var isFlipped: Bool { true }
    init(model: RevisionGraphWindowModel) { self.model = model; super.init(frame: .zero); setAccessibilityLabel("Graph overview") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private(set) var scale: CGFloat = 1
    // BuildPreview uses a quarter of the viewport, at least 100 × 200,
    // caps preview zoom at 100%, and keeps each resulting dimension >= 30.
    // Four-point native drawing insets keep strokes inside the border.
    static func layout(graph: CGSize, viewport: CGSize) -> (size: CGSize, scale: CGFloat) {
        guard graph.width > 0, graph.height > 0, viewport.width > 0, viewport.height > 0 else { return (.zero, 1) }
        let limit = CGSize(width: min(viewport.width, max(100, viewport.width / 4)), height: min(viewport.height, max(200, viewport.height / 4)))
        let scale = max(0.000001, min(1, (limit.width - 8) / graph.width, (limit.height - 8) / graph.height))
        return (CGSize(width: min(limit.width, max(30, graph.width * scale + 8)), height: min(limit.height, max(30, graph.height * scale + 8))), scale)
    }
    func updateFrame() {
        guard let scroll, let host = superview else { return }
        let layout = Self.layout(graph: model.geometry?.size ?? .zero, viewport: scroll.contentSize)
        scale = layout.scale
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
        // Upstream DrawGraph positions the preview at width-previewWidth,
        // height-previewHeight: the lower right, despite its top-right comment.
        frame = CGRect(x: viewport.maxX - layout.size.width, y: host.isFlipped ? viewport.maxY - layout.size.height : viewport.minY, width: layout.size.width, height: layout.size.height)
    }
    var viewportRect: CGRect {
        guard let scroll else { return .zero }
        let visible = scroll.documentVisibleRect
        return CGRect(x: (visible.minX - 10) / model.zoom * scale + 4, y: (visible.minY - 10) / model.zoom * scale + 4, width: visible.width / model.zoom * scale, height: visible.height / model.zoom * scale).intersection(bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState(); let transform = NSAffineTransform(); transform.translateX(by: 4, yBy: 4); transform.scale(by: scale); transform.concat()
        (scroll?.documentView as? RevisionGraphCanvas)?.drawGraph(text: true, renderingZoom: scale); NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke(); let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        let rect = viewportRect
        if !rect.isNull, !rect.isEmpty {
            NSColor.black.withAlphaComponent(0.25).setFill(); rect.fill()
            NSColor.selectedControlColor.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { navigate(event) }
    override func mouseDragged(with event: NSEvent) { navigate(event) }
    private func navigate(_ event: NSEvent) {
        guard interactionAllowed(), !model.busy, !model.closed, let scroll else { return }; let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let origin = CGPoint(x: max(0, (point.x - 4) / scale * model.zoom - scroll.contentSize.width / 2), y: max(0, (point.y - 4) / scale * model.zoom - scroll.contentSize.height / 2))
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin); scroll.reflectScrolledClipView(scroll.contentView); needsDisplay = true
    }
}

final class RevisionGraphFindWindow: NSWindow {
    var findWithoutSelection: () -> Void = {}
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36, event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift, attachedSheet == nil {
            findWithoutSelection(); return
        }
        super.sendEvent(event)
    }
}

/// Modeless owned replacement of CFindDlg / TortoiseLoglistCommon IDD_FIND.
@MainActor final class RevisionGraphFindController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    let searchBox = NSComboBox()
    let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let regex = NSButton(checkboxWithTitle: "Regular Expression", target: nil, action: nil)
    let findButton = NSButton(title: "Find", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let table = NSTableView()
    let referenceFilter = NSTextField()
    let status = NSTextField(labelWithString: "")
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private let regexExecutable: URL?
    var snapshot: () -> [RevisionGraphNode] = { [] }
    var canSearch: () -> Bool = { false }
    var navigate: (String, Bool) -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    var modalChanged: () -> Void = {}
    private(set) var acknowledgingFailure = false
    private var failures: [(String, String)] = []
    private var errorAlert: NSAlert?
    private(set) var references: [String] = []
    private(set) var visibleReferences: [String] = []
    private(set) var busy = false
    private(set) var closed = false
    private var cursor: String?
    private var request = UUID()
    private var token: OperationCancellation?
    private var worker: Task<Void, Never>?
    private var refToken = OperationCancellation()
    private var refWorker: Task<Void, Never>?
    private var filterWorker: Task<Void, Never>?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults, regexExecutable: URL? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences; self.regexExecutable = regexExecutable
        let window = RevisionGraphFindWindow(contentRect: NSRect(x: 0, y: 0, width: 575, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Find – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 500, height: 400)
        super.init(window: window); window.delegate = self
        window.findWithoutSelection = { [weak self] in self?.beginSearch(reference: nil, select: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(errorSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        matchCase.state = preferences.bool(forKey: "LogDialog.FindMatchCase") ? .on : .off
        regex.state = preferences.bool(forKey: "LogDialog.FindRegex") ? .on : .off
        searchBox.isEditable = true; searchBox.completes = false; searchBox.delegate = self
        let history = preferences.stringArray(forKey: "History.Find.Search") ?? []
        searchBox.addItems(withObjectValues: history); searchBox.stringValue = history.first ?? ""
        searchBox.setAccessibilityLabel("Search for"); searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        searchBox.target = self; searchBox.action = #selector(findNext)
        findButton.target = self; findButton.action = #selector(findNext); findButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelFind); cancelButton.keyEquivalent = "\u{1b}"
        let queryRow = NSStackView(views: [NSTextField(labelWithString: "Search for:"), searchBox]); queryRow.spacing = 8
        let flags = NSStackView(views: [matchCase, regex]); flags.spacing = 16
        let left = NSStackView(views: [queryRow, flags]); left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        let actions = NSStackView(views: [findButton, cancelButton]); actions.orientation = .vertical; actions.spacing = 8
        let full = NSStackView(views: [left, actions]); full.spacing = 8
        full.distribution = .fill; full.alignment = .centerY
        actions.widthAnchor.constraint(equalToConstant: 76).isActive = true
        left.widthAnchor.constraint(equalTo: full.widthAnchor, constant: -84).isActive = true
        queryRow.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        findButton.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        cancelButton.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        searchBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        func group(_ title: String, contents: NSView) -> NSBox {
            let box = NSBox(); box.title = title
            let container = NSView(); box.contentView = container
            contents.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(contents)
            NSLayoutConstraint.activate([contents.leadingAnchor.constraint(equalTo: container.leadingAnchor), contents.trailingAnchor.constraint(equalTo: container.trailingAnchor), contents.topAnchor.constraint(equalTo: container.topAnchor), contents.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            return box
        }
        let textGroup = group("Full text search", contents: full)
        textGroup.heightAnchor.constraint(equalToConstant: 105).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Ref")); column.title = "Ref"; column.width = 520; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 22; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(referenceClicked); table.allowsMultipleSelection = false
        table.setAccessibilityLabel("References; click to go to revision")
        let scroller = NSScrollView(); scroller.hasVerticalScroller = true; scroller.documentView = table
        scroller.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        referenceFilter.delegate = self; referenceFilter.setAccessibilityLabel("Reference filter")
        let filterRow = NSStackView(views: [NSTextField(labelWithString: "Filter:"), referenceFilter]); filterRow.spacing = 8
        let refContents = NSStackView(views: [scroller, filterRow]); refContents.orientation = .vertical; refContents.alignment = .leading; refContents.spacing = 8
        scroller.widthAnchor.constraint(equalTo: refContents.widthAnchor).isActive = true
        filterRow.widthAnchor.constraint(equalTo: refContents.widthAnchor).isActive = true
        let refGroup = group("Ref (Click it then go to)", contents: refContents)
        refGroup.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        let stack = NSStackView(views: [textGroup, refGroup, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        let content = RevisionGraphSurface(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor), textGroup.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20), refGroup.widthAnchor.constraint(equalTo: textGroup.widthAnchor)])
        refGroup.setContentHuggingPriority(.defaultLow, for: .vertical)
        refGroup.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        DialogGeometry.attach(window, identifier: "FindDlg")
        updateAvailability()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func loadReferences() {
        guard !closed, refWorker == nil else { return }
        let repo = repository, cancellation = refToken
        refWorker = Task { [weak self, access] in
            _ = access
            let result = await Task.detached { () -> Result<[String], Error> in
                do { return .success(String(decoding: try await repo.run(["for-each-ref", "--format=%(refname)"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout, as: UTF8.self).split(separator: "\n").map(String.init)) } catch { return .failure(error) }
            }.value
            guard let self, !self.closed, !cancellation.isCancelled else { return }
            self.refWorker = nil
            switch result { case .success(let refs): self.references = refs; self.applyReferenceFilter()
            case .failure(let error): self.presentFailure("Could not get all refs.", detail: error.localizedDescription) }
        }
    }
    func updateAvailability() {
        let enabled = !closed && !busy && !acknowledgingFailure && window?.attachedSheet == nil && canSearch()
        findButton.isEnabled = enabled && !searchBox.stringValue.isEmpty
        searchBox.isEnabled = enabled; matchCase.isEnabled = enabled; regex.isEnabled = enabled
        table.isEnabled = enabled; referenceFilter.isEnabled = !closed && !acknowledgingFailure
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === referenceFilter {
            filterWorker?.cancel(); filterWorker = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.applyReferenceFilter()
            }
        } else { updateAvailability() }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) { updateAvailability() }
    func applyReferenceFilter() {
        guard !closed else { return }
        visibleReferences = references.filter { referenceFilter.stringValue.isEmpty || $0.contains(referenceFilter.stringValue) }
        table.deselectAll(nil); table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleReferences.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleReferences.indices.contains(row) else { return nil }
        let name = visibleReferences[row]
        let icon = ReferenceTypeIcon(referenceName: name)
        let image = NSImageView(); image.image = icon?.image()
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: name); label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [image, label]); row.spacing = 5; return row
    }
    @objc func referenceClicked() {
        guard visibleReferences.indices.contains(table.selectedRow) else { return }
        searchReference(visibleReferences[table.selectedRow], select: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
    }
    func searchReference(_ reference: String, select: Bool = true) { beginSearch(reference: reference, select: select) }
    @objc func findNext() { beginSearch(reference: nil, select: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)) }
    private func beginSearch(reference: String?, select: Bool) {
        guard !closed, !busy, !acknowledgingFailure, window?.attachedSheet == nil, canSearch(), reference != nil || !searchBox.stringValue.isEmpty else { return }
        window?.makeFirstResponder(nil)
        let nodes = snapshot(), query = searchBox.stringValue, useRegex = regex.state == .on, sensitive = matchCase.state == .on
        if reference == nil {
            preferences.set(sensitive, forKey: "LogDialog.FindMatchCase"); preferences.set(useRegex, forKey: "LogDialog.FindRegex")
            var history = preferences.stringArray(forKey: "History.Find.Search") ?? []; history.removeAll { $0 == query }; history.insert(query, at: 0); history = Array(history.prefix(25))
            preferences.set(history, forKey: "History.Find.Search"); searchBox.removeAllItems(); searchBox.addItems(withObjectValues: history); searchBox.stringValue = query
        }
        let previous = cursor.flatMap { hash in nodes.firstIndex { $0.hash == hash } }, repo = repository, helper = regexExecutable
        let cancellation = OperationCancellation(), generation = UUID(); token = cancellation; request = generation; busy = true; status.stringValue = "Searching…"; updateAvailability()
        worker = Task { [weak self, access] in
            _ = access
            let result = await Task.detached { () -> Result<(String, Bool)?, Error> in
                do {
                    if let reference {
                        let hash = String(decoding: try await repo.run(["rev-parse", "--verify", "--end-of-options", reference + "^{}"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
                        return .success(nodes.contains { $0.hash == hash } ? (hash, false) : nil)
                    }
                    let matches = try RevisionGraphSearch.matches(nodes, query: query, regex: useRegex, caseSensitive: sensitive, regexExecutable: helper, cancellation: cancellation)
                    guard let found = RevisionGraphSearch.next(matches, after: previous) else { return .success(nil) }
                    return .success((nodes[found.index].hash, found.wrapped))
                } catch { return .failure(error) }
            }.value
            guard let self, !self.closed, self.request == generation, !cancellation.isCancelled else { return }
            self.busy = false; self.worker = nil; self.token = nil; self.updateAvailability()
            guard self.canSearch(), self.snapshot().map(\.hash) == nodes.map(\.hash) else { self.status.stringValue = "The graph changed. Search again."; return }
            switch result {
            case .success(let found):
                if let (hash, wrapped) = found { self.cursor = hash; self.navigate(hash, select); self.status.stringValue = wrapped ? "Search continued from the beginning." : "" }
                else { self.status.stringValue = "No further match in the displayed graph." }
            case .failure(let error): self.presentFailure(reference.map { "Could not get hash of ref \"" + $0 + "^{}\"." } ?? "Could not search the graph.", detail: error.localizedDescription)
            }
        }
    }
    private func presentFailure(_ title: String, detail: String) {
        guard !closed else { return }
        status.stringValue = ""; failures.append((title, detail)); acknowledgingFailure = true
        updateAvailability(); modalChanged(); showNextFailure()
    }
    private func showNextFailure() {
        guard !closed, let window, errorAlert == nil, window.attachedSheet == nil else { return }
        guard !failures.isEmpty else {
            acknowledgingFailure = false; updateAvailability(); modalChanged(); window.makeFirstResponder(searchBox); return
        }
        let (title, detail) = failures.removeFirst()
        let alert = NSAlert(); errorAlert = alert; alert.alertStyle = .critical
        alert.messageText = title; alert.informativeText = detail
        let ok = alert.addButton(withTitle: "OK"); alert.window.alphaValue = window.alphaValue
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self, !self.closed else { return }; self.errorAlert = nil; self.showNextFailure()
        }
        ok.keyEquivalent = "\r"; alert.window.defaultButtonCell = ok.cell as? NSButtonCell
    }
    @objc private func errorSheetEnded() { showNextFailure() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil && !acknowledgingFailure }
    @objc private func cancelFind() { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; request = UUID()
        NotificationCenter.default.removeObserver(self); failures.removeAll(); acknowledgingFailure = false
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }
        errorAlert = nil; token?.cancel(); worker?.cancel(); refToken.cancel(); refWorker?.cancel(); filterWorker?.cancel(); updateAvailability(); onClosed()
    }
}
