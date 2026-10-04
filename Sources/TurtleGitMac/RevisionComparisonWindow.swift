import AppKit
import SwiftUI
import TurtleGitCore

private final class RevisionComparisonNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(); return true }; return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class RevisionComparisonWindowController: NSWindowController, NSWindowDelegate {
    let model: RevisionComparisonWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, from: ComparisonRevision, to: ComparisonRevision) {
        model = RevisionComparisonWindowModel(repository: repository, access: access, from: from, to: to)
        let size = NSSize(width: 1000, height: 700)
        let window = RevisionComparisonNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Changed Files – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 530)
        window.contentViewController = NSHostingController(rootView: RevisionComparisonDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.setFrameAutosaveName("FileDiffDialog"); window.center()
        model.window = window; window.refresh = { [weak model] in model?.load() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && model.patchWindow?.model.busy != true }
    func windowWillClose(_ notification: Notification) { model.patchWindow?.close(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RevisionComparisonWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    weak var window: NSWindow?
    @Published var from: String
    @Published var to: String
    @Published var snapshot: RevisionComparisonSnapshot?
    @Published var selection = Set<String>()
    @Published var filter = ""
    @Published var options = RevisionDiffOptions()
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var showingPatch = false
    var patchWindow: PatchWindowController?
    private var patchGeneration = 0
    var onLog: (String?) -> Void = { _ in }
    var visibleFiles: [CommitFile] { snapshot?.files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) || $0.oldPath?.localizedCaseInsensitiveContains(filter) == true } ?? [] }
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
                snapshot = try await repository.revisionComparison(from: old, to: new, options: settings)
                if showingPatch { updatePatch() }
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func swap() { guard !busy, !confirmingQuit, side(to) != .workingTree else { return }; (from, to) = (to, from); load() }
    func log() {
        guard !busy, !confirmingQuit, let snapshot else { return }
        if case .revision(let value) = snapshot.to { onLog(value) } else { onLog(nil) }
    }
    func copyPaths(_ ids: Set<String>) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(visibleFiles.filter { ids.contains($0.path) }.map(\.path).joined(separator: "\n"), forType: .string) }
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
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Revision", text: value).textFieldStyle(.roundedBorder).onSubmit { model.load() }
                    Menu("HEAD") {
                        Button("HEAD") { value.wrappedValue = "HEAD"; model.load() }
                        Button("Working tree") { value.wrappedValue = "Working tree"; model.load() }
                        Button("Empty tree") { value.wrappedValue = "Empty tree"; model.load() }
                    }.frame(width: 100)
                }
                Text(base ? model.snapshot?.from.label ?? "" : model.snapshot?.to.label ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1)
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
            Table(model.visibleFiles, selection: $model.selection) {
                TableColumn("File") { file in HStack { Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(file.path).foregroundStyle(model.selection.contains(file.path) ? Color.primary : state(file).textColor) }.help(file.oldPath.map { "Renamed from \($0)" } ?? file.path) }.width(min: 350, ideal: 500)
                TableColumn("Extension") { file in Text((file.path as NSString).pathExtension) }.width(75)
                TableColumn("Action", value: \.status).width(100)
                TableColumn("Lines added") { file in Text(file.added.map(String.init) ?? "–") }.width(85)
                TableColumn("Lines deleted") { file in Text(file.removed.map(String.init) ?? "–") }.width(95)
            }.contextMenu(forSelectionType: String.self) { ids in
                Button { model.showPatch(ids) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.isEmpty)
                Button { model.copyPaths(ids) } label: { CommandLabel(title: "Copy paths to clipboard", icon: .copy) }.disabled(ids.isEmpty)
            } primaryAction: { model.showPatch($0) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text("\(model.visibleFiles.count) changed file(s)").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.showingPatch ? "Hide Patch<<" : "View Patch>>") { model.togglePatch() }.buttonStyle(.link).disabled(model.snapshot == nil) }
        }.padding(12).disabled(model.busy || model.confirmingQuit).onAppear { model.load() }
        .onChange(of: model.options) { _ in model.load() }
        .onChange(of: model.selection) { _ in model.updatePatch() }
        .onChange(of: model.filter) { _ in model.selection.formIntersection(model.visibleFiles.map(\.path)); model.updatePatch() }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
