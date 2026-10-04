import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

private final class RevisionComparisonNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(); return true }; return super.performKeyEquivalent(with: event)
    }
}
enum ComparisonSide: String, Identifiable { case base, destination; var id: String { rawValue } }

@MainActor final class RevisionComparisonWindowController: NSWindowController, NSWindowDelegate {
    let model: RevisionComparisonWindowModel
    var onClosed: () -> Void = {}
    private var logPicker: LogWindowController?
    private var reflogPicker: ReferenceLogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision) {
        model = RevisionComparisonWindowModel(repository: repository, access: access, from: from, to: to)
        let size = NSSize(width: 1000, height: 700)
        let window = RevisionComparisonNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Changed Files – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 530)
        window.contentViewController = NSHostingController(rootView: RevisionComparisonDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.setFrameAutosaveName("FileDiffDialog"); window.center()
        model.pickHistory = { [weak self] side, reflog in self?.showHistoryPicker(side: side, reflog: reflog) }
        model.window = window; window.refresh = { [weak model] in model?.load() }
    }
    private func showHistoryPicker(side: ComparisonSide, reflog: Bool) {
        guard let window, window.attachedSheet == nil, !model.busy, !model.confirmingQuit else { return }
        if reflog {
            let picker = ReferenceLogWindowController(repository: model.repository, access: model.access, reference: "HEAD") { [weak model] entry in
                if let entry { model?.choose(entry.hash, side: side) }
            }
            reflogPicker = picker; picker.onClosed = { [weak self] in self?.reflogPicker = nil }
            if let child = picker.window { window.beginSheet(child) }
        } else {
            let picker = LogWindowController(repository: model.repository, access: model.access) { [weak model] entry in
                if let entry { model?.choose(entry.hash, side: side) }
            }
            logPicker = picker; picker.onClosed = { [weak self] in self?.logPicker = nil }
            let revision = side == .base ? model.snapshot?.from : model.snapshot?.to
            if case .revision(let hash) = revision { picker.model.endRevision = hash; picker.model.reload() }
            if let child = picker.window { window.beginSheet(child) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil && !model.busy && model.patchWindow?.model.busy != true && !model.comparisonWindows.values.contains { $0.model.busy } }
    func windowWillClose(_ notification: Notification) { model.patchWindow?.close(); Array(model.comparisonWindows.values).forEach { $0.close() }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RevisionComparisonWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    weak var window: NSWindow?
    @Published var from: String
    @Published var to: String
    @Published var references: [CheckoutReference] = []
    @Published var browser: ComparisonSide?
    var pickHistory: (ComparisonSide, Bool) -> Void = { _, _ in }
    @Published var snapshot: RevisionComparisonSnapshot?
    @Published var selection = Set<String>()
    @Published var filter = ""
    @Published var sortOrder = [KeyPathComparator(\CommitFile.sortPath)]
    @Published var options = RevisionDiffOptions()
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var showingPatch = false
    var patchWindow: PatchWindowController?
    private var patchGeneration = 0
    var onLog: (String?) -> Void = { _ in }
    var onFileLog: (String, String?) -> Void = { _, _ in }
    var onSubmoduleCompare: (String, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _ in }
    var comparisonWindows: [String: FileComparisonWindowController] = [:]
    var visibleFiles: [CommitFile] { snapshot?.files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) || $0.oldPath?.localizedCaseInsensitiveContains(filter) == true }.sorted(using: sortOrder) ?? [] }
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision) { self.repository = repository; self.access = access; self.from = from.label; self.to = to.label }
    private func side(_ input: String) -> ComparisonRevision {
        switch input.lowercased() { case "working tree": return .workingTree; case "empty tree": return .emptyTree; default: return .revision(input) }
    }
    func load() {
        guard !busy, !confirmingQuit else { return }; busy = true
        let old = side(from), new = side(to), settings = options
        snapshot = nil; selection = []; patchGeneration += 1; patchWindow?.model.document = GitPatch(text: ""); patchWindow?.model.busy = false
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                references = try await repository.checkoutReferences(includeAll: true)
                snapshot = try await repository.revisionComparison(from: old, to: new, options: settings)
                if showingPatch { updatePatch() }
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func choose(_ revision: String, side: ComparisonSide) {
        guard !busy, !confirmingQuit else { return }
        if side == .base { from = revision } else { to = revision }
        load()
    }
    func revisionDescription(base: Bool) -> String {
        guard let snapshot else { return "" }
        if let detail = base ? snapshot.fromDetails : snapshot.toDetails { return detail.shortHash + ": " + detail.subject }
        return (base ? snapshot.from : snapshot.to).label
    }
    func revisionTooltip(base: Bool) -> String {
        guard let snapshot, let detail = base ? snapshot.fromDetails : snapshot.toDetails else { return "" }
        return (detail.authorDate?.formatted(date: .numeric, time: .standard) ?? "") + "  " + detail.author
    }
    func revisionTitle(base: Bool) -> String {
        let title = base ? "Version 1 (Base)" : "Version 2"
        guard let a = snapshot?.fromDetails?.committerDate, let b = snapshot?.toDetails?.committerDate else { return title }
        return (base ? a > b : b > a) ? title + " (newer)" : title
    }
    func swap() { guard !busy, !confirmingQuit, side(to) != .workingTree else { return }; (from, to) = (to, from); load() }
    func log() {
        guard !busy, !confirmingQuit, let snapshot else { return }
        if case .revision(let value) = snapshot.to { onLog(value) } else { onLog(nil) }
    }
    func logFiles(_ ids: Set<String>) {
        guard !busy, !confirmingQuit, let snapshot else { return }
        let revision: String? = { if case .revision(let value) = snapshot.to { return value }; return nil }()
        for file in visibleFiles where ids.contains(file.path) { onFileLog(file.path, revision) }
    }
    func compare(_ ids: Set<String>) {
        guard !busy, !confirmingQuit, let snapshot else { return }
        for file in visibleFiles where ids.contains(file.path) {
            if file.isSubmodule { onSubmoduleCompare(file.path, snapshot.from, snapshot.to); continue }
            let key = file.path + "\0" + snapshot.from.label + "\0" + snapshot.to.label
            let controller = comparisonWindows[key] ?? FileComparisonWindowController(repository: repository, access: access, snapshot: snapshot, path: file.path)
            controller.onClosed = { [weak self] in self?.comparisonWindows.removeValue(forKey: key) }
            comparisonWindows[key] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    func copyPaths(_ ids: Set<String>, extended: Bool = false) {
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ComparisonFileList.clipboard(files, extended: extended), forType: .string)
    }
    func saveList(_ ids: Set<String>) {
        guard !busy, !confirmingQuit, let snapshot, let window else { return }
        let files = visibleFiles.filter { ids.contains($0.path) }; guard !files.isEmpty else { return }
        let text = ComparisonFileList.savedList(files, from: snapshot.from, to: snapshot.to)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "changed-files.txt"; panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self?.error = error.localizedDescription }
        }
    }
    func togglePatch() {
        guard !busy, !confirmingQuit else { return }
        if showingPatch { patchWindow?.close(); return }
        let controller = PatchWindowController(repository: repository, access: access)
        controller.window?.title = "\(repository.root.lastPathComponent) – Unified Diff – TurtleGit"
        controller.model.readOnly = true
        controller.model.readOnlyInformation = "Read-only comparison. Select files in Changed Files to inspect their patch."
        controller.model.customRefresh = { [weak self] in self?.updatePatch() }
        controller.onClosed = { [weak self] in self?.patchGeneration += 1; self?.showingPatch = false; self?.patchWindow = nil }
        patchWindow = controller; showingPatch = true
        if let window, let patch = controller.window, let screen = window.screen {
            let visible = screen.visibleFrame
            let x = max(visible.minX, min(window.frame.maxX + 8, visible.maxX - patch.frame.width))
            let y = max(visible.minY, min(window.frame.maxY - patch.frame.height, visible.maxY - patch.frame.height))
            patch.setFrameOrigin(NSPoint(x: x, y: y))
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); updatePatch()
    }
    func showPatch(_ ids: Set<String>) { guard !ids.isEmpty else { return }; selection = ids; if !showingPatch { togglePatch() } else { updatePatch() } }
    func updatePatch() {
        guard showingPatch, let controller = patchWindow, let snapshot else { return }
        patchGeneration += 1; let request = patchGeneration
        let paths = visibleFiles.filter { selection.contains($0.path) }.map(\.path)
        controller.model.busy = true; controller.model.comparisonTitle = "\(snapshot.from.label.prefix(12)) → \(snapshot.to.label.prefix(12))"
        controller.model.paths = paths
        Task {
            do {
                let text = paths.isEmpty ? "" : try await repository.revisionComparisonPatch(snapshot, paths: paths)
                guard request == patchGeneration else { return }
                controller.model.document = GitPatch(text: text); controller.model.busy = false
            } catch { if request == patchGeneration { controller.model.error = error.localizedDescription; controller.model.busy = false } }
        }
    }
}
private struct RevisionComparisonDialog: View {
    @ObservedObject var model: RevisionComparisonWindowModel
    private func revisionGroup(_ title: String, value: Binding<String>, base: Bool) -> some View {
        GroupBox(model.revisionTitle(base: base)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Revision", text: value).textFieldStyle(.roundedBorder).onSubmit { model.load() }
                    Menu("HEAD") {
                        Button { model.browser = base ? .base : .destination } label: { CommandLabel(title: "Browse references…", icon: .branch) }
                        Button { model.pickHistory(base ? .base : .destination, false) } label: { CommandLabel(title: "Log…", icon: .log) }
                        Button { model.pickHistory(base ? .base : .destination, true) } label: { CommandLabel(title: "RefLog…", icon: .log) }
                        Divider()
                        Button("HEAD") { value.wrappedValue = "HEAD"; model.load() }
                        Button("Working tree") { value.wrappedValue = "Working tree"; model.load() }
                        Button("Empty tree") { value.wrappedValue = "Empty tree"; model.load() }
                    }.frame(width: 100)
                }
                Text(model.revisionDescription(base: base)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).help(model.revisionTooltip(base: base))
            }.padding(5)
        }
    }
    private func state(_ file: CommitFile) -> FileState {
        switch file.action.first { case "A": return .added; case "D": return .deleted; default: return .modified }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Difference between"); Spacer()
                Menu("Diff Options") {
                    Toggle("Ignore space at end of line", isOn: $model.options.ignoreSpaceAtEnd)
                    Toggle("Ignore space changes", isOn: $model.options.ignoreSpaceChange)
                    Toggle("Ignore all spaces", isOn: $model.options.ignoreAllSpace)
                    Toggle("Ignore blank lines", isOn: $model.options.ignoreBlankLines)
                    Toggle("Common ancestor", isOn: $model.options.commonAncestor)
                }.frame(width: 130)
                Button { model.log() } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.snapshot == nil)
                Button { model.swap() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()) }.help("Swap revisions").accessibilityLabel("Swap revisions").disabled(model.to.lowercased() == "working tree")
            }
            revisionGroup("Version 1 (Base)", value: $model.from, base: true)
            revisionGroup("Version 2", value: $model.to, base: false)
            HStack { TextField("Filter paths", text: $model.filter).textFieldStyle(.roundedBorder); if !model.filter.isEmpty { Button("Clear") { model.filter = "" } } }
            Table(model.visibleFiles, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("File", value: \.sortPath) { file in HStack { Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(file.path).foregroundStyle(model.selection.contains(file.path) ? Color.primary : state(file).textColor) }.help(file.oldPath.map { "Renamed from \($0)" } ?? file.path) }.width(min: 350, ideal: 500)
                TableColumn("Extension", value: \.sortExtension) { file in Text(file.fileExtension) }.width(75)
                TableColumn("Action", value: \.sortAction) { file in Text(file.status) }.width(100)
                TableColumn("Lines added", value: \.sortAdded) { file in Text(file.addedText) }.width(85)
                TableColumn("Lines deleted", value: \.sortRemoved) { file in Text(file.removedText) }.width(95)
            }.contextMenu(forSelectionType: String.self) { ids in
                Button { model.compare(ids) } label: { CommandLabel(title: "Compare revisions", icon: .compare) }.disabled(ids.isEmpty)
                Button { model.showPatch(ids) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty)
                Button { model.logFiles(ids) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(ids.isEmpty)
                Divider()
                Button { model.saveList(ids) } label: { CommandLabel(title: "Save list of selected files…", icon: .saveAs) }.disabled(ids.isEmpty)
                Button { model.copyPaths(ids, extended: true) } label: { CommandLabel(title: "Copy all columns to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                Button { model.copyPaths(ids) } label: { CommandLabel(title: "Copy paths to clipboard", icon: .copy) }.disabled(ids.isEmpty)
            } primaryAction: { model.compare($0) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text("\(model.visibleFiles.count) changed file(s)").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.showingPatch ? "Hide Patch<<" : "View Patch>>") { model.togglePatch() }.buttonStyle(.link).disabled(model.snapshot == nil) }
        }.padding(12).disabled(model.busy || model.confirmingQuit).onAppear { model.load() }
        .onChange(of: model.options) { _ in model.load() }
        .onChange(of: model.selection) { _ in model.updatePatch() }
        .onChange(of: model.filter) { _ in model.selection.formIntersection(model.visibleFiles.map(\.path)); model.updatePatch() }
        .sheet(item: $model.browser) { side in ComparisonReferenceChooser(model: model, side: side) }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

private struct ComparisonReferenceChooser: View {
    @ObservedObject var model: RevisionComparisonWindowModel
    let side: ComparisonSide
    @State private var filter = ""
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse references").font(.headline)
            TextField("Filter references", text: $filter).textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(model.references.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { ref in
                    HStack { Image(nsImage: (ref.name.hasPrefix("refs/tags/") ? MenuIcon.tag : MenuIcon.branch).image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(ref.name) }.tag(ref.name)
                }
            }
            HStack { Spacer(); Button("Cancel") { model.browser = nil }.keyboardShortcut(.cancelAction)
                Button("OK") { if let selection { model.browser = nil; model.choose(selection, side: side) } }.disabled(selection == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 640, height: 430)
    }
}
