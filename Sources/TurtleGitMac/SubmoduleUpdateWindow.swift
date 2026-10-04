import AppKit
import SwiftUI
import TurtleGitCore

private final class SubmoduleUpdateNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class SubmoduleUpdateWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleUpdateWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = []) {
        model = SubmoduleUpdateWindowModel(repository: repository, access: access, scope: scope, selected: selected)
        let size = NSSize(width: 760, height: 500)
        let window = SubmoduleUpdateNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Submodule Update – TurtleGit"
        window.contentMinSize = NSSize(width: 700, height: 460); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleUpdateDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.setFrameAutosaveName("SubmoduleUpdateDialog"); window.center()
        model.close = { [weak window] in window?.close() }; window.refresh = { [weak model] in model?.load() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleUpdateWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let scope: [String]
    private let requestedSelection: [String]
    private var loaded = false
    @Published var options = SubmoduleUpdateOptions()
    @Published var paths: [String] = []
    @Published var selection = Set<String>()
    @Published var wholeProject = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var output = ""
    @Published var error: String?
    var close: () -> Void = {}
    var onUpdated: (String) -> Void = { _ in }
    private var key: String { "SubmoduleUpdate." + repository.root.path }
    var canApply: Bool { !busy && !confirmingQuit && !selection.isEmpty }
    var canChooseScope: Bool { scope.contains { !$0.isEmpty && $0 != "." } }
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String]) {
        self.repository = repository; self.access = access; self.scope = scope; requestedSelection = selected
        wholeProject = UserDefaults.standard.bool(forKey: key + ".wholeProject")
        if let data = UserDefaults.standard.data(forKey: key + ".options"), let saved = try? JSONDecoder().decode(SubmoduleUpdateOptions.self, from: data) { options = saved }
    }
    func load() {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let next = try await repository.submoduleUpdatePaths(scope: wholeProject ? [] : scope)
                let saved = requestedSelection.isEmpty ? UserDefaults.standard.stringArray(forKey: key + ".selection") ?? [] : requestedSelection
                let checks = loaded ? selection : Set(saved.isEmpty ? next : saved)
                paths = next; selection = checks.intersection(next); loaded = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func scopeChanged() { UserDefaults.standard.set(wholeProject, forKey: key + ".wholeProject"); loaded = false; load() }
    func selectAll() { guard !busy, !confirmingQuit else { return }; selection = selection.isEmpty ? Set(paths) : [] }
    func apply() {
        guard canApply else { return }; busy = true; output = "Updating submodules…"
        let selected = paths.filter { selection.contains($0) }, snapshot = options
        UserDefaults.standard.set(selected, forKey: key + ".selection")
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key + ".options") }
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                output = try await repository.updateSubmodules(paths: selected, options: snapshot)
                if output.isEmpty { output = "Submodule update completed." }
                onUpdated(output)
            } catch { output = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
}

private struct SubmoduleUpdatePath: Identifiable { let id: String }
private struct SubmoduleUpdateDialog: View {
    @ObservedObject var model: SubmoduleUpdateWindowModel
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                Text("Path:").frame(width: 55, alignment: .leading).padding(.top, 8)
                List(model.paths.map { SubmoduleUpdatePath(id: $0) }, selection: $model.selection) { row in
                    Text(row.id).lineLimit(1).help(row.id).tag(row.id)
                }.border(Color.secondary.opacity(0.35))
            }
            GroupBox("Submodule Update Options") {
                HStack(alignment: .top, spacing: 25) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Initialize submodules (--init)", isOn: $model.options.initialize)
                        Toggle("Recursive", isOn: $model.options.recursive)
                        Toggle("Force", isOn: $model.options.force)
                        Toggle("Remote tracking branch", isOn: $model.options.remote)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("No fetch", isOn: $model.options.noFetch)
                        Toggle("Merge", isOn: $model.options.merge)
                        Toggle("Rebase", isOn: $model.options.rebase)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8)
            }
            if !model.output.isEmpty { ScrollView { Text(model.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100) }
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    SelectionAllCheckbox(checked: model.selection.count, total: model.paths.count) { _ in model.selectAll() }.frame(width: 190, height: 22)
                    Toggle("Whole Project", isOn: $model.wholeProject).disabled(!model.canChooseScope).onChange(of: model.wholeProject) { _ in model.scopeChanged() }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-submodules.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(model.busy || model.confirmingQuit).onAppear { model.load() }
        .alert("Submodule update failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
