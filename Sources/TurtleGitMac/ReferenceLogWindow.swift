import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ReferenceLogWindowController: NSWindowController, NSWindowDelegate {
    let model: ReferenceLogWindowModel
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((ReferenceLogEntry?) -> Void)?
    private(set) var findController: ReferenceLogFindController?
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, onChoose: ((ReferenceLogEntry?) -> Void)? = nil) {
        model = ReferenceLogWindowModel(repository: repository, access: access, reference: reference, selecting: onChoose != nil)
        selectionCompletion = onChoose
        let window = ReferenceLogNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 530), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – RefLog – TurtleGit"
        window.minSize = NSSize(width: 800, height: 360); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ReferenceLogDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 530)); window.center()
        model.close = { [weak self] in
            guard let self else { return }
            if self.model.selecting { self.finishSelection(nil) } else { self.window?.close() }
        }
        model.onChoose = { [weak self] entry in self?.finishSelection(entry) }
        model.confirmDelete = { [weak window] count, clear, proceed in
            guard let window else { return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = clear ? "Delete all \(count) stashes?" : "Delete \(count) selected stash \(count == 1 ? "entry" : "entries")?"
            alert.informativeText = "The selected stash entries will be removed from the stash list."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Delete")
            alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { proceed() } }
        }
        model.openFind = { [weak self] in self?.openFind() }
        window.functionKey = { [weak self] code in
            guard let self, !self.model.busy else { return false }
            if code == 99 { self.model.openFind(); return true } // F3
            if code == 96 { self.model.reload(); return true } // F5
            return false
        }
        model.reload()
    }
    func openFind(visible: Bool = true) {
        guard !model.busy else { return }
        if let findController {
            if visible { findController.showWindow(nil); findController.window?.makeKeyAndOrderFront(nil) }
            return
        }
        model.find = ""; model.matchCase = false
        let finder = ReferenceLogFindController(model: model)
        findController = finder
        finder.onClosed = { [weak self] in self?.findController = nil }
        if visible { finder.showWindow(nil); finder.window?.makeKeyAndOrderFront(nil) }
    }
    private func finishSelection(_ entry: ReferenceLogEntry?) {
        guard let completion = selectionCompletion else { return }; selectionCompletion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }
        completion(entry)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.busy else { return false }
        if model.selecting { finishSelection(nil); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        findController?.close(); findController = nil
        let completion = selectionCompletion; selectionCompletion = nil; completion?(nil); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ReferenceLogWindowModel: ObservableObject {
    let repository: GitRepository
    let selecting: Bool
    private let access: RepositoryAccessLease?
    @Published var reference: String
    @Published var names: [String]
    @Published var entries: [ReferenceLogEntry] = []
    @Published var selection = Set<String>() {
        didSet { if !finding { searchIndex = entries.firstIndex { selection.contains($0.id) } ?? 0 } }
    }
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    var openFind: () -> Void = {}
    @Published private(set) var searchWrapped = false
    private var searchIndex = 0
    private var finding = false
    @Published var find = "" { didSet { searchWrapped = false } }
    @Published var matchCase = false { didSet { searchWrapped = false } }
    private var generation = 0
    var onChoose: (ReferenceLogEntry) -> Void = { _ in }
    func accept() { if selecting { if !busy, let entry = selectedEntry { onChoose(entry) } } else { close() } }
    var onApply: (String) -> Void = { _ in }
    var onChanged: (String) -> Void = { _ in }
    var confirmDelete: (Int, Bool, @escaping () -> Void) -> Void = { _, _, _ in }
    var close: () -> Void = {}
    var selectedEntry: ReferenceLogEntry? { let chosen = entries.filter { selection.contains($0.id) }; return chosen.count == 1 ? chosen.first : nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, selecting: Bool = false) {
        self.selecting = selecting; self.repository = repository; self.access = access; self.reference = reference; names = [reference]
    }
    func reload() {
        generation += 1; let request = generation, reference = reference; busy = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let refs = try await repository.referenceLogNames(), result = try await repository.referenceLog(reference)
                guard request == generation else { return }
                names = Array(Set(refs + [reference])).sorted(); entries = result
                selection.formIntersection(Set(result.map(\.id))); searchIndex = 0; searchWrapped = false; busy = false
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func apply(_ ids: Set<String>) {
        guard !selecting, !busy, reference == "refs/stash", ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        // Hash pins the selected entry even if another process changes stash indices.
        onApply(entry.hash)
    }
    func delete(_ ids: Set<String>, clear: Bool = false) {
        guard !selecting, !busy, reference == "refs/stash", !entries.isEmpty, clear || !ids.isEmpty else { return }
        let expected = entries
        confirmDelete(clear ? entries.count : ids.count, clear) { [weak self] in
            guard let self, !self.busy else { return }; self.busy = true
            Task {
                do { let output = try await self.repository.deleteStashEntries(ids, expected: expected, clear: clear); self.onChanged(output) }
                catch { self.error = error.localizedDescription }
                self.reload()
            }
        }
    }
    func findNext() {
        guard !busy, !entries.isEmpty, !find.isEmpty else { return }
        searchWrapped = searchIndex >= entries.count
        let start = searchWrapped ? 0 : searchIndex
        for offset in 0..<entries.count {
            let index = (start + offset) % entries.count, entry = entries[index]
            // RefLogDlg searches the displayed ref, action, hash and message,
            // separated by newlines. Reflog messages do not carry a commit body.
            let text = [entry.selector, entry.action, entry.hash, entry.message, ""].joined(separator: "\n")
            if text.range(of: find, options: matchCase ? [] : [.caseInsensitive]) != nil {
                finding = true; selection = [entry.id]; finding = false
                searchIndex = index + 1; return
            }
        }
        error = "\"\(find)\" was not found."
    }
    func copy(_ ids: Set<String>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries.filter { ids.contains($0.id) }.map(\.hash).joined(separator: "\n"), forType: .string)
    }
    func inspect(_ ids: Set<String>) {
        guard ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        Task {
            do { patch = try await repository.run(["show", "--first-parent", "--format=fuller", "--no-ext-diff", "--no-color", entry.hash, "--"]).text }
            catch { self.error = error.localizedDescription }
        }
    }
}
private struct ReferenceLogDialog: View {
    @ObservedObject var model: ReferenceLogWindowModel
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Ref:"); ReferenceLogPicker(names: model.names, selection: $model.reference).frame(maxWidth: .infinity).frame(height: 26) }
            Table(model.entries, selection: $model.selection) {
                TableColumn("Hash") { entry in Text(entry.hash).font(.system(.body, design: .monospaced)).help(entry.hash) }.width(min: 90, ideal: 120)
                TableColumn("Ref", value: \.selector).width(min: 100, ideal: 145)
                TableColumn("Action", value: \.action).width(min: 80, ideal: 100)
                TableColumn("Message") { entry in Text(entry.message).help(entry.subject) }.width(min: 160, ideal: 360)
                TableColumn("Date") { entry in if let date = entry.date { Text(date.formatted(date: .numeric, time: .standard)) } }.width(min: 140, ideal: 175)
            }.contextMenu(forSelectionType: String.self) { ids in
                TurtleGitContextMenu {
                    Button { model.inspect(ids) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.count != 1)
                    if !model.selecting && model.reference == "refs/stash" {
                        Button { model.apply(ids) } label: { CommandLabel(title: "Stash apply", icon: .stashPop) }.disabled(ids.count != 1)
                        Button { model.delete(ids) } label: { CommandLabel(title: "Delete", icon: .deleted) }.disabled(ids.isEmpty)
                    }
                    Divider()
                    Button { model.copy(ids) } label: { CommandLabel(title: "Copy hash", icon: .copy) }.disabled(ids.isEmpty)
                }
            } primaryAction: { ids in if model.selecting { model.selection = ids; model.accept() } else { model.inspect(ids) } }
            HStack {
                Button("Search…") { model.openFind() }.keyboardShortcut("f")
                if !model.selecting && model.reference == "refs/stash" { Button("Clear stash") { model.delete([], clear: true) }.disabled(model.entries.isEmpty) }
                Button("Refresh") { model.reload() }.keyboardShortcut("r")
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.accept() }.disabled(model.selecting && model.selectedEntry == nil).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-reflog.html")!) }
            }
        }.padding(12).disabled(model.busy)
        .onChange(of: model.reference) { _ in model.selection = []; model.reload() }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { OutputView(text: model.patch ?? ""); HStack { Spacer(); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12) }.frame(width: 900, height: 600)
        }
        .alert("RefLog", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

private struct ReferenceLogPicker: NSViewRepresentable {
    let names: [String]
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Ref:")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != names { button.removeAllItems(); button.addItems(withTitles: names) }
        button.selectItem(withTitle: selection)
    }
    final class Coordinator: NSObject {
        var parent: ReferenceLogPicker
        init(_ parent: ReferenceLogPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) { if let title = sender.titleOfSelectedItem { parent.selection = title } }
    }
}

/// Function keys are handled by the owning RefLog window, without a global event monitor.
@MainActor final class ReferenceLogNativeWindow: NSWindow {
    var functionKey: (UInt16) -> Bool = { _ in false }
    func handleFunctionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 99 || event.keyCode == 96 else { return false }
        return functionKey(event.keyCode)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleFunctionKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !handleFunctionKey(event) { super.keyDown(with: event) }
    }
}

@MainActor final class ReferenceLogFindController: NSWindowController, NSWindowDelegate {
    var onClosed: () -> Void = {}
    init(model: ReferenceLogWindowModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Find – RefLog – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ReferenceLogFindDialog(model: model, close: { [weak window] in window?.close() }))
        super.init(window: window); window.delegate = self; window.center()
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct ReferenceLogFindDialog: View {
    @ObservedObject var model: ReferenceLogWindowModel
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find what:", text: $model.find).textFieldStyle(.roundedBorder).focused($focused).onSubmit { model.findNext() }
            Toggle("Match case", isOn: $model.matchCase).toggleStyle(.checkbox)
            if model.searchWrapped { Text("Search wrapped to the beginning.").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Find Next") { model.findNext() }.disabled(model.find.isEmpty || model.busy).keyboardShortcut(.defaultAction)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction) }
        }.padding(20).onAppear { focused = true }
    }
}
