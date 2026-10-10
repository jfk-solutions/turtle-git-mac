// Native replacement of TortoiseGit's RevisionGraphDlg/RevisionGraphWnd.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import TurtleGitCore
import UniformTypeIdentifiers

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
    private(set) var pointers = Set<String>()
    var changed: () -> Void = {}
    var becameIdle: () -> Void = {}
    var onLog: (String) -> Void = { _ in }
    var onBrowse: (String) -> Void = { _ in }
    var onCompare: (ComparisonRevision, ComparisonRevision) -> Void = { _, _ in }
    var onCreateReference: (Bool, String) -> Void = { _, _ in }
    var onCheckout: (String) -> Void = { _ in }
    var onReset: (String) -> Void = { _ in }
    var onUnified: (Data) -> Void = { _ in }
    static let font = NSFont.systemFont(ofSize: 11)
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, layoutExecutable: URL? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences; self.layoutExecutable = layoutExecutable
    }
    deinit { cancellation?.cancel(); worker?.cancel() }
    func lines(_ node: RevisionGraphNode, pointers: Set<String>? = nil) -> [(String, LogColorRole?)] {
        var result: [(String, LogColorRole?)] = []
        if (pointers ?? self.pointers).contains(node.hash) { result.append(("super-project-pointer", .otherRef)) }
        result += node.references.isEmpty ? [(String(node.hash.prefix(8)), nil)] : node.references.map { ($0.label, LogColorRole.reference($0)) }
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
                let graph = try await repository.revisionGraph(options: options, cancellation: token)
                guard !closed, !token.isCancelled, request == generation else { return }
                let sizes = graph.nodes.map { node -> CGSize in
                    let labels = self.lines(node, pointers: graph.superprojectHashes)
                    let widths = labels.map { ($0.0 as NSString).size(withAttributes: [.font: Self.font]).width }
                    return CGSize(width: ceil(widths.max() ?? 0) + 40, height: CGFloat(labels.count) * (ceil(Self.font.ascender - Self.font.descender) + 10))
                }
                let executable = layoutExecutable
                let layout = try await Task.detached {
                    try RevisionGraphLayoutRuntime.layout(nodes: graph.nodes, sizes: sizes, executable: executable, cancellation: token)
                }.value
                guard !closed, !token.isCancelled, request == generation else { return }
                nodes = graph.nodes; pointers = graph.superprojectHashes; geometry = layout
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
    func friendName(_ hash: String) -> String { nodes.first { $0.hash == hash }?.references.first?.name ?? hash }
    func compare(head: Bool = false, working: Bool = false) {
        guard !busy, !closed, let first = selection.first, (head || working) ? selection.count == 1 : selection.count == 2 else { return }
        onCompare(.revision(friendName(first)), working ? .workingTree : .revision(head ? "HEAD" : friendName(selection[1])))
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
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class RevisionGraphWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: RevisionGraphWindowModel
    let canvas: RevisionGraphCanvas
    let scroll = NSScrollView()
    let status = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let overview: RevisionGraphOverview
    private var filter: RevisionGraphFilterController?
    private var closing = false
    private var exporting = false
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
                                 ("View", [("Zoom in", "zoomIn"), ("Zoom out", "zoomOut"), ("Zoom to 100%", "zoom100"), ("Fit height", "fitHeight"), ("Fit width", "fitWidth"), ("Fit graph", "fit"), ("Filter…", "filter"), ("Show Overview", "overview"), ("Show branchings and merges", "branchings"), ("Show all tags", "tags"), ("Arrows point towards merges", "arrows")]),
                                 ("Git", [("Compare revisions", "compare"), ("Compare HEAD revisions", "compareHead"), ("Unified diff", "unified"), ("Unified diff of HEAD revisions", "unifiedHead")]), ("Help", [("Help", "help")])] {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true); popup.addItem(withTitle: title)
            for (label, command) in commands { popup.menu?.addItem(menuItem(label, command: command)) }
            bar.addArrangedSubview(popup)
        }
        for (title, command, icon) in [("Refresh", "refresh", MenuIcon.refresh), ("Filter", "filter", .repositoryBrowser), ("Zoom in", "zoomIn", .imageZoomIn), ("Zoom out", "zoomOut", .imageZoomOut), ("Fit graph", "fit", .imageFit)] {
            let button = NSButton(image: icon.image() ?? NSImage(), target: self, action: #selector(clicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(command); button.toolTip = title; button.setAccessibilityLabel(title); bar.addArrangedSubview(button)
        }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 560)); host.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = canvas
        scroll.frame = CGRect(x: 0, y: 0, width: 960, height: 560); scroll.autoresizingMask = [.width, .height]; host.addSubview(scroll)
        overview.frame = CGRect(x: 800, y: 350, width: 150, height: 200); overview.autoresizingMask = [.minXMargin, .minYMargin]; overview.scroll = scroll; host.addSubview(overview)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let footer = NSStackView(views: [status, cancelButton]); footer.orientation = .horizontal; footer.distribution = .fill; footer.spacing = 12
        cancelButton.target = self; cancelButton.action = #selector(cancelGraphOperation)
        let stack = NSStackView(views: [bar, host, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8); stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor), host.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16), host.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        host.setContentHuggingPriority(.defaultLow, for: .vertical); host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvas.contextMenu = { [weak self] in self?.nodeMenu() ?? NSMenu() }
        model.changed = { [weak self] in self?.update() }
        model.becameIdle = { [weak self] in if self?.closing == true { self?.window?.close() } }
        model.onUnified = { [weak self] bytes in guard let self else { return }; self.unifiedViewer = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.unifiedViewer, title: "Revision Graph changes", onClosed: { [weak self] in self?.unifiedViewer = nil }) }
        window.command = { [weak self] in self?.perform($0) }; update(); window.center()
        DialogGeometry.attach(window, identifier: "RevisionGraph")
        if automaticallyLoad { model.load() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func menuItem(_ title: String, command: String, icon: MenuIcon? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command
        item.image = icon?.contextImage(defaults: model.preferences); return item
    }
    func nodeMenu() -> NSMenu {
        let menu = NSMenu(); guard !model.selection.isEmpty else { return menu }
        menu.addItem(menuItem("Show Log", command: "log", icon: .log))
        if model.selection.count == 1 {
            for (title, command, icon) in [("Browse repository", "browse", MenuIcon.repositoryBrowser), ("Switch/Checkout…", "checkout", .checkout), ("Create branch…", "branch", .branch), ("Create tag…", "tag", .tag), ("Reset…", "reset", .reset)] { menu.addItem(menuItem(title, command: command, icon: icon)) }
            menu.addItem(.separator())
            menu.addItem(menuItem("Compare with HEAD", command: "compareHead", icon: .compare)); menu.addItem(menuItem("Compare with working tree", command: "compareWorking", icon: .compare))
            menu.addItem(menuItem("Unified diff with HEAD", command: "unifiedHead", icon: .unifiedDiff))
        } else {
            menu.addItem(menuItem("Compare revisions", command: "compare", icon: .compare)); menu.addItem(menuItem("Unified diff", command: "unified", icon: .unifiedDiff))
        }
        menu.addItem(.separator()); menu.addItem(menuItem("Copy ref names", command: "copyRefs")); menu.addItem(menuItem("Copy hash", command: "copyHash"))
        return menu
    }
    @objc private func menuCommand(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { perform(command) } }
    @objc private func clicked(_ sender: NSButton) { if let command = sender.identifier?.rawValue { perform(command) } }
    @objc private func cancelGraphOperation() { model.cancel() }
    @objc private func scrolled() { overview.needsDisplay = true }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? String else { return true }
        item.state = ((command == "overview" && model.showOverview) || (command == "branchings" && model.options.showBranchingsAndMerges) || (command == "tags" && model.options.showAllTags) || (command == "arrows" && model.arrowsTowardMerges)) ? .on : .off
        if model.busy || filter != nil || exporting { return command == "close" }
        if ["compare", "unified"].contains(command) { return model.selection.count == 2 }
        if ["compareHead", "compareWorking", "unifiedHead", "log", "browse", "checkout", "branch", "tag", "reset", "copyRefs", "copyHash"].contains(command) { return model.selection.count == 1 || command == "log" || command == "copyHash" }
        return true
    }
    func perform(_ command: String) {
        if command == "close" { window?.performClose(nil); return }
        guard !model.busy, !model.closed, filter == nil, !exporting else { return }
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
        case "overview": model.showOverview.toggle()
        case "arrows": model.arrowsTowardMerges.toggle()
        case "branchings": model.options.showBranchingsAndMerges.toggle(); model.load()
        case "tags": model.options.showAllTags.toggle(); model.load()
        case "filter": showFilter()
        case "compare": model.compare()
        case "compareHead": model.compare(head: true)
        case "compareWorking": model.compare(working: true)
        case "unified", "unifiedHead": model.unified(head: command == "unifiedHead")
        case "log", "browse", "checkout", "branch", "tag", "reset":
            if let hash = model.selection.first {
                let ref = model.friendName(hash)
                switch command { case "log": model.onLog(ref); case "browse": model.onBrowse(ref); case "checkout": model.onCheckout(ref); case "branch", "tag": model.onCreateReference(command == "tag", ref); default: model.onReset(ref) }
            }
        case "copyHash", "copyRefs":
            let text = command == "copyHash" ? model.selection.joined(separator: "\n") : model.nodes.filter { model.selection.contains($0.hash) }.flatMap { $0.references.map(\.name) }.joined(separator: "\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        case "save": saveGraph()
        case "help": NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-revgraph.html")!)
        default: break
        }
        update()
    }
    func update() {
        canvas.resize(to: scroll.contentSize); canvas.needsDisplay = true; overview.needsDisplay = true
        overview.isHidden = !model.showOverview || model.busy || model.nodes.isEmpty || model.nodes.count > 10_000
        status.stringValue = model.error ?? (model.busy ? "Loading…" : "\(model.nodes.count) revisions • \(Int((model.zoom * 100).rounded()))%")
        cancelButton.isEnabled = model.busy
    }
    func showFilter() {
        guard let window, window.attachedSheet == nil else { return }
        let filter = RevisionGraphFilterController(model: model) { [weak self] options in
            guard let self else { return }; self.filter = nil
            if let options { self.model.options = options; self.model.load() }
        }
        self.filter = filter; if let child = filter.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
    }
    private func saveGraph() {
        guard let window, window.attachedSheet == nil, model.geometry != nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Revision Graph.pdf"; exporting = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.exporting = false
            if response == .OK, let url = panel.url {
                do { let data = self.canvas.dataWithPDF(inside: self.canvas.bounds); try data.write(to: url) }
                catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil, filter == nil, !exporting, unifiedViewer?.model.busy != true, unifiedViewer?.window?.attachedSheet == nil else { return false }
        if model.busy { closing = true; model.cancel(); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self); model.invalidate(); unifiedViewer?.close(); unifiedViewer = nil
        filter?.close(); filter = nil; onClosed()
    }
}

@MainActor final class RevisionGraphCanvas: NSView, NSViewToolTipOwner {
    let model: RevisionGraphWindowModel
    var contextMenu: () -> NSMenu = { NSMenu() }
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
    func drawGraph(text: Bool) {
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
                let background = label.1.map { LogPalette.native($0, preferences: model.preferences) } ?? NSColor.textBackgroundColor
                let bright = background.blended(withFraction: 0.5, of: .textBackgroundColor) ?? background
                NSGradient(starting: bright, ending: background)?.draw(in: row, angle: 90)
                if text {
                    let attributes: [NSAttributedString.Key: Any] = [.font: RevisionGraphWindowModel.font, .foregroundColor: LogPalette.foreground(background: background)]
                    let size = (label.0 as NSString).size(withAttributes: attributes)
                    (label.0 as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: row.midY - size.height / 2), withAttributes: attributes)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            (model.selection.contains(node.hash) ? NSColor.selectedControlColor : NSColor.labelColor).setStroke(); path.lineWidth = model.selection.contains(node.hash) ? 3 : 1; path.stroke()
        }
    }
    func hit(_ point: CGPoint) -> String? {
        let p = CGPoint(x: (point.x - 10) / model.zoom, y: (point.y - 10) / model.zoom)
        return model.geometry?.nodes.first { $0.rect.contains(p) }?.hash
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        model.select(hit(convert(event.locationInWindow, from: nil)), extending: event.modifierFlags.intersection([.command, .control]).isEmpty == false)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !model.busy, let hash = hit(convert(event.locationInWindow, from: nil)) else { return nil }
        if !model.selection.contains(hash) { model.select(hash, extending: false) }; return contextMenu()
    }
}

@MainActor final class RevisionGraphOverview: NSView {
    let model: RevisionGraphWindowModel
    weak var scroll: NSScrollView?
    override var isFlipped: Bool { true }
    init(model: RevisionGraphWindowModel) { self.model = model; super.init(frame: .zero); setAccessibilityLabel("Graph overview") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var scale: CGFloat { guard let size = model.geometry?.size, size.width > 0, size.height > 0 else { return 1 }; return min((bounds.width - 8) / size.width, (bounds.height - 8) / size.height) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState(); let transform = NSAffineTransform(); transform.translateX(by: 4, yBy: 4); transform.scale(by: scale); transform.concat()
        (scroll?.documentView as? RevisionGraphCanvas)?.drawGraph(text: false); NSGraphicsContext.restoreGraphicsState()
        if let visible = scroll?.documentVisibleRect {
            let rect = CGRect(x: (visible.minX - 10) / model.zoom * scale + 4, y: (visible.minY - 10) / model.zoom * scale + 4, width: visible.width / model.zoom * scale, height: visible.height / model.zoom * scale)
            NSColor.selectedControlColor.setStroke(); let path = NSBezierPath(rect: rect.intersection(bounds)); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { navigate(event) }
    override func mouseDragged(with event: NSEvent) { navigate(event) }
    private func navigate(_ event: NSEvent) {
        guard let scroll else { return }; let point = convert(event.locationInWindow, from: nil)
        let origin = CGPoint(x: max(0, (point.x - 4) / scale * model.zoom - scroll.contentSize.width / 2), y: max(0, (point.y - 4) / scale * model.zoom - scroll.contentSize.height / 2))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView); needsDisplay = true
    }
}
