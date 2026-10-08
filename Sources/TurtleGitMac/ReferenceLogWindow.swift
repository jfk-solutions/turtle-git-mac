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
        model.confirmDelete = { [weak window] message, clear, proceed in
            guard let window, window.attachedSheet == nil else { return }
            let alert = Self.deletionAlert(message: message, clear: clear)
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { proceed() } }
        }
        model.presentDeletionFailure = { [weak self] issue in await self?.showDeletionFailure(issue) }
        model.openFind = { [weak self] in self?.openFind() }
        window.functionKey = { [weak self] code in
            guard let self, !self.model.busy else { return false }
            if code == 99 { self.model.openFind(); return true } // F3
            if code == 96 { self.model.reload(); return true } // F5
            return false
        }
        model.reload()
    }
    private func showDeletionFailure(_ issue: ReferenceLogDeleteIssue) async {
        guard let window, window.attachedSheet == nil else { return }
        await withCheckedContinuation { continuation in
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = issue.details; alert.informativeText = issue.selector
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in continuation.resume() }
        }
    }
    static func deletionAlert(message: String, clear: Bool) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = message
        let delete = alert.addButton(withTitle: "Delete"), abort = alert.addButton(withTitle: "Abort")
        delete.keyEquivalent = clear ? "" : "\r"; abort.keyEquivalent = clear ? "\r" : ""
        alert.window.defaultButtonCell = (clear ? abort : delete).cell as? NSButtonCell
        return alert
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
    @Published private(set) var deletionReport: String?
    var presentDeletionFailure: (@Sendable (ReferenceLogDeleteIssue) async -> Void)?
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
    var onLog: ((String) -> Void)?
    var onLogRange: ((HistoryRevisionRange) -> Void)?
    var onBrowseRepository: ((String) -> Void)?
    var onCreateReference: ((Bool, String) -> Void)?
    var onExport: ((String) -> Void)?
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    @Published private(set) var hasWorkingTree = false
    @Published private(set) var currentStashHash: String?
    private var currentStashIndexParent: String?
    var onChanged: (String) -> Void = { _ in }
    var confirmDelete: (String, Bool, @escaping () -> Void) -> Void = { _, _, _ in }
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
                let bare = try await repository.isBare()
                var stashHash: String?, indexParent: String?
                if refs.contains("refs/stash") {
                    let hash = try await repository.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/stash"], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines)
                    if !hash.isEmpty {
                        stashHash = hash
                        let parents = ((try? await repository.run(["rev-list", "--parents", "-n", "1", hash, "--"]).text) ?? "").split(whereSeparator: \.isWhitespace)
                        if parents.count == 3 { indexParent = String(parents[2]) }
                    }
                }
                guard request == generation else { return }
                currentStashHash = stashHash; currentStashIndexParent = indexParent
                hasWorkingTree = !bare
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
        guard !selecting, !busy, !entries.isEmpty,
              clear ? reference == "refs/stash" : (!ids.isEmpty && ids.isSubset(of: Set(entries.map(\.id)))) else { return }
        let expected = entries, reference = reference
        let message: String
        if clear { message = "Do you really want to delete ALL \(entries.count) stash?" }
        else if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) {
            message = "\"\(entry.selector)\" will be permanently deleted. It can NOT be recovered!\n\nDo you really want to continue?"
        } else { message = "Do you really want to permanently delete the \(ids.count) selected refs? It can NOT be recovered!" }
        confirmDelete(message, clear) { [weak self] in
            guard let self, !self.busy else { return }
            guard self.reference == reference, self.entries == expected else { self.error = ReferenceLogFailure.stale.localizedDescription; return }
            self.busy = true; self.error = nil; self.deletionReport = nil
            Task {
                do {
                    let output = clear ? try await self.repository.deleteStashEntries([], expected: expected, clear: true) : try await self.repository.deleteReferenceLogEntries(ids, reference: reference, expected: expected, onFailure: self.presentDeletionFailure)
                    self.onChanged(output)
                }
                catch let failure as ReferenceLogDeleteBatchFailure {
                    self.deletionReport = failure.localizedDescription
                    self.onChanged(failure.output + failure.localizedDescription)
                    if self.presentDeletionFailure == nil { self.error = failure.localizedDescription }
                }
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
    func isOnStash(_ entry: ReferenceLogEntry) -> Bool {
        if entry.hash == currentStashHash { return true }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return false }
        return entries[index - 1].hash == currentStashHash && entry.hash == currentStashIndexParent
    }
    func canPerform(_ command: ReferenceLogRevisionCommand, ids: Set<String>) -> Bool {
        guard !busy, ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return false }
        switch command {
        case .browseRepository: return onBrowseRepository != nil
        case .export: return onExport != nil
        case .createBranch, .createTag: return !selecting && !isOnStash(entry) && onCreateReference != nil
        }
    }
    func perform(_ command: ReferenceLogRevisionCommand, ids: Set<String>) {
        guard canPerform(command, ids: ids), let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        switch command {
        case .browseRepository: onBrowseRepository?(entry.hash)
        case .export: onExport?(entry.hash)
        case .createBranch: onCreateReference?(false, entry.hash)
        case .createTag: onCreateReference?(true, entry.hash)
        }
    }
    func activateRows(_ ids: Set<String>) {
        guard !busy else { return }
        if selecting { selection = ids; accept() }
        else if let entry = entries.first(where: { ids.contains($0.id) }) { onLog?(entry.hash) }
    }
    func comparisonSides(_ command: ReferenceLogComparisonCommand, ids: Set<String>) -> (ComparisonRevision, ComparisonRevision)? {
        guard !busy, !ids.isEmpty else { return nil }
        let indices = entries.indices.filter { ids.contains(entries[$0].id) }
        guard indices.count == ids.count, let first = indices.first, let last = indices.last else { return nil }
        switch command {
        case .workingTree:
            guard ids.count == 1, hasWorkingTree else { return nil }
            return (.revision(entries[first].hash), .workingTree)
        case .revisions:
            guard ids.count >= 2, ids.count == 2 || last - first + 1 == ids.count else { return nil }
            return (.revision(entries[last].hash), .revision(entries[first].hash))
        }
    }
    func canCompare(_ command: ReferenceLogComparisonCommand, ids: Set<String>) -> Bool {
        onCompare != nil && comparisonSides(command, ids: ids) != nil
    }
    func compare(_ command: ReferenceLogComparisonCommand, ids: Set<String>) {
        guard let onCompare, let (from, to) = comparisonSides(command, ids: ids) else { return }
        onCompare(from, to)
    }
    func showLog(_ ids: Set<String>) {
        guard !busy, ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        onLog?(entry.hash)
    }
    static func configureRevisionLog(_ log: LogWindowModel, revision: String) {
        log.revisionRange = nil
        log.endRevision = revision; log.selected = [revision]
        log.search = ""; log.useDates = false
        log.allBranches = false; log.showWorkingTree = false
        log.configureWholeProjectScope()
    }
    func logRange(_ command: ReferenceLogRangeCommand, ids: Set<String>) -> HistoryRevisionRange? {
        guard !busy, ids.count == 2 else { return nil }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == 2 else { return nil }
        let first = selected[0].hash, last = selected[1].hash
        return HistoryRevisionRange(from: command == .reverse ? first : last, to: command == .reverse ? last : first, kind: command == .symmetric ? .symmetricDifference : .difference)
    }
    func showLogRange(_ command: ReferenceLogRangeCommand, ids: Set<String>) {
        guard let range = logRange(command, ids: ids) else { return }
        onLogRange?(range)
    }
    static func configureRangeLog(_ log: LogWindowModel, range: HistoryRevisionRange) {
        log.endRevision = nil; log.revisionRange = range; log.selected = []
        log.search = ""; log.useDates = false; log.allBranches = false; log.showWorkingTree = false
        log.configureWholeProjectScope()
    }
    func clipboardText(_ ids: Set<String>, format: ReferenceLogCopyFormat, dates: HistoryDateSettings = .load()) -> String? {
        let chosen = entries.filter { ids.contains($0.id) }
        guard !busy, !chosen.isEmpty else { return nil }
        switch format {
        case .hashes: return chosen.map(\.hash).joined(separator: "\r\n")
        case .messages: return chosen.map { "* " + Self.message($0) + "\r\n\r\n" }.joined()
        case .full: return chosen.map {
            "Revision: " + $0.hash + "\r\nDate: " + Self.dateText($0, dates: dates) + "\r\nMessage: " + Self.message($0) + "\r\n"
        }.joined()
        }
    }
    private static func message(_ entry: ReferenceLogEntry) -> String {
        (entry.action.isEmpty ? "" : entry.action + ": ") + entry.message
    }
    static func dateText(_ entry: ReferenceLogEntry, dates: HistoryDateSettings = .load()) -> String {
        guard let date = entry.date else { return entry.timestamp }
        return dates.format(ISO8601DateFormatter().string(from: date))
    }
    func copy(_ ids: Set<String>, format: ReferenceLogCopyFormat = .hashes, pasteboard: NSPasteboard = .general) {
        guard let text = clipboardText(ids, format: format) else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    func inspect(_ ids: Set<String>) {
        guard ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        Task {
            do { patch = try await repository.run(["show", "--first-parent", "--format=fuller", "--no-ext-diff", "--no-color", entry.hash, "--"]).text }
            catch { self.error = error.localizedDescription }
        }
    }
}
enum ReferenceLogCopyFormat { case full, hashes, messages }
enum ReferenceLogRangeCommand: CaseIterable, Hashable { case forward, reverse, symmetric }
enum ReferenceLogComparisonCommand {
    case workingTree, revisions
    var title: String { self == .workingTree ? "Compare with working tree" : "Compare revisions" }
    var icon: MenuIcon { .compare }
}
enum ReferenceLogRevisionCommand: CaseIterable, Hashable {
    case browseRepository, createBranch, createTag, export
    var title: String {
        switch self {
        case .browseRepository: return "Browse repository"
        case .createBranch: return "Create Branch at this version…"
        case .createTag: return "Create Tag at this version…"
        case .export: return "Export this version…"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .browseRepository: return .repositoryBrowser
        case .createBranch: return .branch
        case .createTag: return .tag
        case .export: return .export
        }
    }
}

private struct ReferenceLogDialog: View {
    @ObservedObject var model: ReferenceLogWindowModel
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var useSystemLocale = true
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Ref:"); ReferenceLogPicker(names: model.names, selection: $model.reference).frame(maxWidth: .infinity).frame(height: 26) }
            Table(model.entries, selection: $model.selection) {
                TableColumn("Hash") { entry in Text(entry.hash).font(.system(.body, design: .monospaced)).help(entry.hash) }.width(min: 90, ideal: 120)
                TableColumn("Ref", value: \.selector).width(min: 100, ideal: 145)
                TableColumn("Action", value: \.action).width(min: 80, ideal: 100)
                TableColumn("Message") { entry in Text(entry.message).help(entry.subject) }.width(min: 160, ideal: 360)
                TableColumn("Date") { entry in if entry.date != nil { Text(ReferenceLogWindowModel.dateText(entry, dates: HistoryDateSettings(shortDate: shortDate, relative: relativeTimes, useSystemLocale: useSystemLocale))) } }.width(min: 140, ideal: 175)
            }.contextMenu(forSelectionType: String.self) { ids in
                TurtleGitContextMenu {
                    if ids.count == 1 {
                        Button { model.compare(.workingTree, ids: ids) } label: { CommandLabel(title: ReferenceLogComparisonCommand.workingTree.title, icon: .compare) }.disabled(!model.canCompare(.workingTree, ids: ids))
                        Button { model.inspect(ids) } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }
                        Divider()
                    }
                    Button { model.showLog(ids) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(ids.count != 1 || model.onLog == nil)
                    ForEach(ReferenceLogRevisionCommand.allCases, id: \.self) { command in
                        Button { model.perform(command, ids: ids) } label: { CommandLabel(title: command.title, icon: command.icon) }.disabled(!model.canPerform(command, ids: ids))
                    }
                    Divider()
                    if !model.selecting { Button { model.delete(ids) } label: { CommandLabel(title: "Delete", icon: .deleted) }.disabled(ids.isEmpty) }
                    if !model.selecting && model.reference == "refs/stash" {
                        Button { model.apply(ids) } label: { CommandLabel(title: "Stash apply", icon: .stashPop) }.disabled(ids.count != 1)
                    }
                    Divider()
                    if ids.count >= 2 {
                        Button { model.compare(.revisions, ids: ids) } label: { CommandLabel(title: ReferenceLogComparisonCommand.revisions.title, icon: .compare) }.disabled(!model.canCompare(.revisions, ids: ids))
                        if ids.count == 2 {
                            ForEach(ReferenceLogRangeCommand.allCases, id: \.self) { command in
                                if let range = model.logRange(command, ids: ids) {
                                    Button { model.showLogRange(command, ids: ids) } label: { CommandLabel(title: "Show log of " + range.from.prefix(7) + range.separator + range.to.prefix(7), icon: .log) }.disabled(model.onLogRange == nil)
                                }
                            }
                        }
                        Divider()
                    }
                    Menu {
                        Button { model.copy(ids, format: .full) } label: { CommandLabel(title: "Full data", icon: .copy) }
                        Button { model.copy(ids, format: .hashes) } label: { CommandLabel(title: "SHA-1", icon: .copy) }
                        Button { model.copy(ids, format: .messages) } label: { CommandLabel(title: "Messages", icon: .copy) }
                    } label: { CommandLabel(title: "Copy to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                }
            } primaryAction: { ids in model.activateRows(ids) }
            if let report = model.deletionReport { Text(report).font(.caption).foregroundStyle(.red).lineLimit(3).help(report) }
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
