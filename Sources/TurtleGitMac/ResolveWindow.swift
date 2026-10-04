import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ResolveWindowController: NSWindowController, NSWindowDelegate {
    let model: ResolveWindowModel
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice? = nil) {
        model = ResolveWindowModel(repository: repository, access: access, paths: paths, quick: quick)
        let size = quick == nil ? NSSize(width: 780, height: 450) : NSSize(width: 480, height: 110)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: quick == nil ? [.titled, .closable, .miniaturizable, .resizable] : [.titled], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Resolve – TurtleGit"
        window.contentMinSize = quick == nil ? NSSize(width: 660, height: 340) : size
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResolveDialog(model: model))
        super.init(window: window); window.delegate = self
        if quick == nil { window.setFrameAutosaveName("ResolveDialog") }
        window.setContentSize(size); window.center()
        model.close = { [weak window] in window?.close() }
        model.confirm = { [weak self] choice, entries in self?.confirm(choice, entries: entries) }
        model.onChanged = { [weak self] output in self?.onChanged(output) }
        model.onFinished = { [weak self] count in self?.finished(count) }
    }
    private func confirm(_ choice: ResolveChoice, entries: [ConflictEntry]) {
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to mark the conflicted file(s) as resolved?"
        alert.informativeText = choice == .current ? "The current working contents will be staged." : "This replaces the selected working contents with index stage \(choice.rawValue). A missing stage resolves the path as deleted."
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: window) { [weak model] response in
            guard let model else { return }
            if response == .alertFirstButtonReturn { model.apply(entries, using: choice) }
            else if model.quick != nil { model.close() }
        }
    }
    private func finished(_ count: Int) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Resolved \(count) files."
        alert.informativeText = "Reminder: Commit your change after resolve."
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Commit…")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if self.model.closeAfterResolution || response == .alertSecondButtonReturn { self.close() } else { self.model.load() }
            if response == .alertSecondButtonReturn { self.onCommit() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ResolveWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let quick: ResolveChoice?
    let paths: [String]
    @Published var entries: [ConflictEntry] = []
    @Published var checked = Set<String>()
    @Published var selection = Set<String>()
    @Published var rebase = false
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    private var loaded = false
    var closeAfterResolution = true
    var close: () -> Void = {}
    var confirm: (ResolveChoice, [ConflictEntry]) -> Void = { _, _ in }
    var onChanged: (String) -> Void = { _ in }
    var onFinished: (Int) -> Void = { _ in }
    var onSubmoduleReset: (GitRepository, String, @escaping () -> Void) -> Void = { _, _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], quick: ResolveChoice?) {
        self.repository = repository; self.access = access; self.paths = paths; self.quick = quick
    }
    func load() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let next = try await repository.conflicts(paths: paths)
                entries = next; rebase = try await repository.conflictIsRebase()
                let available = Set(next.map(\.path))
                checked = loaded ? checked.intersection(available) : available; loaded = true
                selection.formIntersection(available)
                if let quick {
                    guard !next.isEmpty else { throw ResolveFailure.stale }
                    confirm(quick, next)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func resolveChecked() { closeAfterResolution = true; apply(entries.filter { checked.contains($0.path) }, using: .current) }
    func request(_ choice: ResolveChoice, ids: Set<String>) {
        let selected = entries.filter { ids.contains($0.path) }
        guard !busy, !selected.isEmpty else { return }; closeAfterResolution = false; confirm(choice, selected)
    }
    func apply(_ selected: [ConflictEntry], using choice: ResolveChoice) {
        guard !busy else { return }
        do {
            guard !selected.isEmpty else { throw ResolveFailure.selection }
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            busy = true
            Task {
                defer { busy = false }
                do {
                    let output = try await repository.resolveConflicts(selected, using: choice)
                    onChanged(output); onFinished(selected.count)
                } catch ResolveFailure.submoduleCheckout(let path) {
                    do {
                        guard let entry = selected.first(where: { $0.path == path }) else { throw ResolveFailure.stale }
                        let (root, revision) = try await repository.submoduleResetTarget(entry, using: choice)
                        busy = false
                        onSubmoduleReset(GitRepository(root: root, executable: repository.executable), revision) { [weak self] in self?.apply(selected, using: choice) }
                    } catch { self.error = error.localizedDescription }
                } catch { self.error = error.localizedDescription; onChanged(error.localizedDescription) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func compare(_ ids: Set<String>) {
        guard !busy, !ids.isEmpty else { return }; busy = true
        Task {
            defer { busy = false }
            do { patch = try await repository.run(["diff", "--no-ext-diff", "--no-color", "--base", "--"] + entries.filter { ids.contains($0.path) }.map(\.path)).text }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ResolveDialog: View {
    @ObservedObject var model: ResolveWindowModel
    var body: some View {
        Group {
            if model.quick != nil {
                HStack(spacing: 16) { ProgressView().controlSize(.small); Text(model.busy ? "Resolving selected conflicts…" : "Review the selected resolution.") }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("") { entry in
                            Toggle("Resolve \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.path) }, set: { if $0 { model.checked.insert(entry.path) } else { model.checked.remove(entry.path) } })).labelsHidden().toggleStyle(.checkbox)
                        }.width(24)
                        TableColumn("Path") { entry in HStack { Image(nsImage: FileState.conflicted.icon.image() ?? NSImage()); Text(entry.path).foregroundStyle(FileState.conflicted.textColor) } }.width(min: 260, ideal: 440)
                        TableColumn("Extension") { Text(($0.path as NSString).pathExtension) }.width(70)
                        TableColumn("Status") { _ in Text("Conflicted").foregroundStyle(FileState.conflicted.textColor) }.width(95)
                    }.contextMenu(forSelectionType: String.self) { ids in
                        Button { model.compare(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty)
                        Divider()
                        ResolveSelectionMenu(paths: Array(ids), rebase: model.rebase) { action, paths in model.request(action.resolveChoice ?? .current, ids: Set(paths)) }
                    } primaryAction: { ids in model.compare(ids) }
                    HStack {
                        ResolveAllCheckbox(checked: model.checked.count, total: model.entries.count) { model.checked = $0 ? Set(model.entries.map(\.path)) : [] }.fixedSize()
                        Spacer()
                        Text("Reminder: Commit your change after resolve").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("OK") { model.resolveChecked() }.disabled(model.checked.isEmpty).keyboardShortcut(.defaultAction)
                        Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                        Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-resolve.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
                    }
                }.padding(12).disabled(model.busy)
                .background(Button("") { model.load() }.keyboardShortcut(KeyEquivalent("\u{f708}"), modifiers: []).hidden())
            }
        }.onAppear { model.load() }
        .alert("Could not resolve conflicts", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil; if model.quick != nil { model.close() } }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
struct ResolveSelectionMenu: View {
    let paths: [String]
    var rebase = false
    let action: (RepositoryAction, [String]) -> Void
    var body: some View {
        Button { action(.resolveCurrent, paths) } label: { CommandLabel(title: "Resolved", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveTheirs, paths) } label: { CommandLabel(title: rebase ? "Resolve using commit being replayed" : "Resolve conflict using ‘theirs’", icon: .resolve) }.disabled(paths.isEmpty)
        Button { action(.resolveMine, paths) } label: { CommandLabel(title: rebase ? "Resolve using branch being rebased onto" : "Resolve conflict using ‘mine’", icon: .resolve) }.disabled(paths.isEmpty)
    }
}
private struct ResolveAllCheckbox: NSViewRepresentable {
    let checked: Int
    let total: Int
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = checked == 0 ? .off : checked == total ? .on : .mixed
        button.isEnabled = total > 0; context.coordinator.change = change
        context.coordinator.selectOnClick = checked == 0
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        var selectOnClick = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { change(selectOnClick) }
    }
}
