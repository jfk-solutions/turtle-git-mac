import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SwitchWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        model = SwitchWindowModel(repository: repository, access: access, revision: revision)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 370),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Switch/Checkout – TurtleGit"
        window.minSize = NSSize(width: 600, height: 390); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SwitchDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 620, height: 370)); window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && model.browser == nil && !model.tagConflict && sender.attachedSheet == nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SwitchWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let initialRevision: String?
    @Published var references: [CheckoutReference] = []
    @Published var options = CheckoutOptions()
    @Published var branchRevision = ""
    @Published var tagRevision = ""
    @Published var commitRevision = "HEAD"
    @Published var busy = false
    @Published var error: String?
    @Published var tagConflict = false
    @Published var browser: CheckoutTarget?
    @Published var commits: [LogEntry] = []
    var close: () -> Void = {}
    var onSwitched: (String) -> Void = { _ in }
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote) && ($0.symbolicTarget == nil || $0.name == branchRevision) } }
    var tags: [CheckoutReference] { references.filter { $0.name.hasPrefix("refs/tags/") } }
    var revision: String { switch options.target { case .branch: return branchRevision; case .tag: return tagRevision; case .commit: return commitRevision } }
    var remote: Bool { options.target == .branch && references.first { $0.name == branchRevision }?.remote == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) { self.repository = repository; self.access = access; initialRevision = revision }
    func load(revision preset: String? = nil) {
        guard !busy else { return }; busy = true
        let revision = preset ?? initialRevision
        Task {
            defer { busy = false }
            do {
                references = try await repository.checkoutReferences()
                let current = try await repository.branch()
                branchRevision = branches.first { $0.name == "refs/heads/" + current }?.name ?? branches.first?.name ?? ""
                tagRevision = tags.first?.name ?? ""
                commitRevision = revision ?? "HEAD"; options = CheckoutOptions()
                if let revision, references.contains(where: { $0.name == revision }) {
                    if revision.hasPrefix("refs/tags/") { options.target = .tag; tagRevision = revision }
                    else { options.target = .branch; branchRevision = revision }
                } else { options.target = revision == nil ? .branch : .commit }
                defaults()
            } catch { self.error = error.localizedDescription }
        }
    }
    func defaults() {
        options.overrideBranch = false
        options.tracking = remote ? .automatic : .noTrack
        let reference = references.first { $0.name == revision }
        options.branchName = reference?.suggestedBranch ?? "Branch_" + String(commitRevision.prefix(7))
        switch options.target {
        case .branch: options.createBranch = remote
        case .tag: options.createBranch = UserDefaults.standard.object(forKey: "SwitchToTagNewBranch") as? Bool ?? true
        case .commit: options.createBranch = UserDefaults.standard.object(forKey: "SwitchToCommitNewBranch") as? Bool ?? true
        }
    }
    func browse(_ target: CheckoutTarget) {
        guard !busy else { return }
        if target != .commit { browser = target; return }
        busy = true
        Task {
            defer { busy = false }
            do { var history = HistoryOptions(); history.allBranches = true; history.limit = 200
                commits = try await repository.history(options: history); browser = target
            } catch { self.error = error.localizedDescription }
        }
    }
    func checkout(allowTagConflict: Bool = false) {
        guard !busy else { return }
        var snapshot = options; snapshot.revision = revision; snapshot.allowTagNameConflict = allowTagConflict
        if options.target == .tag { UserDefaults.standard.set(options.createBranch, forKey: "SwitchToTagNewBranch") }
        if options.target == .commit { UserDefaults.standard.set(options.createBranch, forKey: "SwitchToCommitNewBranch") }
        busy = true
        Task {
            defer { busy = false }
            do { let output = try await repository.checkout(snapshot); onSwitched(output); close() }
            catch CheckoutFailure.tagNameConflict { tagConflict = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SwitchDialog: View {
    @ObservedObject var model: SwitchWindowModel
    var body: some View {
        VStack(spacing: 16) {
            GroupBox("Switch To") {
                VStack(spacing: 6) {
                    HStack {
                        SwitchRadio(title: "Branch", target: .branch, selection: $model.options.target).frame(width: 100)
                        ReferencePopup(references: model.branches, selection: $model.branchRevision).disabled(model.options.target != .branch)
                        Button("…") { model.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.options.target != .branch)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Tag", target: .tag, selection: $model.options.target).frame(width: 100)
                        ReferencePopup(references: model.tags, selection: $model.tagRevision).disabled(model.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack {
                        SwitchRadio(title: "Commit", target: .commit, selection: $model.options.target).frame(width: 100)
                        TextField("Commit", text: $model.commitRevision).disabled(model.options.target != .commit)
                        Button("…") { model.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Option") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Create New Branch", isOn: $model.options.createBranch).frame(width: 180, alignment: .leading)
                        TextField("New branch name", text: $model.options.branchName).disabled(!model.options.createBranch)
                    }
                    HStack {
                        Toggle("Overwrite working tree changes (force)", isOn: $model.options.overwriteChanges)
                        Spacer(); Toggle("Merge", isOn: $model.options.merge)
                    }
                    TrackingCheckbox(value: $model.options.tracking, enabled: model.remote && model.options.createBranch)
                        .frame(height: 18).help("Mixed: use Git's automatic tracking configuration. Checked: track this remote branch. Unchecked: no tracking.")
                    Toggle("Override branch if exists", isOn: $model.options.overrideBranch).disabled(!model.options.createBranch)
                }.padding(8)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.checkout() }.keyboardShortcut(.defaultAction).disabled(model.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-switch.html")!) }
            }
        }.padding(16).disabled(model.busy)
        .onChange(of: model.options.target) { _ in model.defaults() }
        .onChange(of: model.branchRevision) { _ in if model.options.target == .branch { model.defaults() } }
        .onChange(of: model.tagRevision) { _ in if model.options.target == .tag { model.defaults() } }
        .onChange(of: model.commitRevision) { _ in if model.options.target == .commit { model.defaults() } }
        .onChange(of: model.options.branchName) { name in
            if model.remote, let reference = model.references.first(where: { $0.name == model.branchRevision }), name != reference.suggestedBranch { model.options.tracking = .noTrack }
        }
        .onChange(of: model.options.createBranch) { create in
            if !create { model.options.overrideBranch = false; model.options.tracking = .noTrack }
        }
        .alert("Switch/Checkout failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Branch and tag share a name", isPresented: $model.tagConflict) {
            Button("Continue") { model.checkout(allowTagConflict: true) }; Button("Abort", role: .cancel) {}
        } message: { Text(CheckoutFailure.tagNameConflict.localizedDescription) }
        .sheet(item: $model.browser) { target in SwitchReferenceChooser(model: model, target: target) }
    }
}

struct SwitchReferenceChooser: View {
    @ObservedObject var model: SwitchWindowModel
    let target: CheckoutTarget
    @State private var search = ""
    @State private var selected: String?
    var choices: [(String, String)] {
        let choices = target == .commit ? model.commits.map { ($0.hash, String($0.hash.prefix(8)) + "  " + $0.subject) } : model.branches.map { ($0.name, $0.label) }
        return choices.filter { search.isEmpty || $0.1.localizedCaseInsensitiveContains(search) || $0.0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target == .commit ? "Choose commit" : "Browse references").font(.headline)
            TextField("Filter", text: $search)
            List(selection: $selected) { ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) } }
            HStack { Spacer(); Button("Cancel") { model.browser = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard let selected else { return }
                    if target == .commit { model.commitRevision = selected } else { model.branchRevision = selected }
                    model.defaults(); model.browser = nil
                }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(16).frame(width: 650, height: 430)
    }
}

struct TrackingCheckbox: NSViewRepresentable {
    @Binding var value: CheckoutTracking
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Track", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = value == .automatic ? .mixed : (value == .track ? .on : .off); button.isEnabled = enabled
        context.coordinator.change = { value = $0 }; context.coordinator.value = value
    }
    final class Coordinator: NSObject {
        var change: (CheckoutTracking) -> Void = { _ in }; var value = CheckoutTracking.automatic
        @objc func clicked(_ sender: NSButton) { change(value == .automatic ? .noTrack : (value == .noTrack ? .track : .automatic)) }
    }
}

struct SwitchRadio: NSViewRepresentable {
    let title: String
    let target: CheckoutTarget
    @Binding var selection: CheckoutTarget
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = selection == target ? .on : .off; button.isEnabled = enabled
        context.coordinator.change = { selection = target }
    }
    final class Coordinator: NSObject {
        var change: () -> Void = {}
        @objc func clicked(_ sender: NSButton) { change() }
    }
}

struct ReferencePopup: NSViewRepresentable {
    let references: [CheckoutReference]
    @Binding var selection: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let names = references.map(\.name)
        if context.coordinator.names != names || button.numberOfItems == 0 {
            button.removeAllItems(); button.addItems(withTitles: references.isEmpty ? ["No references"] : references.map(\.label))
        }
        context.coordinator.names = names
        if let index = names.firstIndex(of: selection) { button.selectItem(at: index) }
        button.isEnabled = enabled && !references.isEmpty
        context.coordinator.change = { selection = $0 }
    }
    final class Coordinator: NSObject {
        var names: [String] = []; var change: (String) -> Void = { _ in }
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            guard names.indices.contains(sender.indexOfSelectedItem) else { return }; change(names[sender.indexOfSelectedItem])
        }
    }
}

// PerformSwitch's immediate branch command and its progress/post-command choices.
enum SwitchPostAction: String, CaseIterable, Hashable {
    case submoduleUpdate, mergePreviousBranch, pull, commit, resolve, stash, retry, switchWithMerge
    var title: String {
        switch self {
        case .submoduleUpdate: return "Submodule Update…"
        case .mergePreviousBranch: return "Merge…"
        case .pull: return "Pull…"
        case .commit: return "Commit…"
        case .resolve: return "Resolve…"
        case .stash: return "Stash Save…"
        case .retry: return "Retry"
        case .switchWithMerge: return "Switch with Merge"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .submoduleUpdate: return .fetch
        case .mergePreviousBranch: return .merge
        case .pull: return .pull
        case .commit: return .commit
        case .resolve: return .resolve
        case .stash: return .stash
        case .retry: return .mergeReload
        case .switchWithMerge: return .checkout
        }
    }
}
@MainActor final class SwitchProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SwitchProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String) {
        model = SwitchProgressWindowModel(repository: repository, access: access, reference: reference)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Switch Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 560, height: 300); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SwitchProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.model.busy, self.window?.attachedSheet == nil else { return }
            if let window = self.window { window.sheetParent?.endSheet(window); window.close() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard sender.attachedSheet == nil else { return false }
        sender.sheetParent?.endSheet(sender); return true
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SwitchProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let reference: String
    private let access: RepositoryAccessLease?
    private var cancellation = OperationCancellation()
    private var started = false
    private var merging = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var output = ""
    @Published private(set) var previousBranch = ""
    @Published private(set) var postActions: [SwitchPostAction] = []
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var onPostAction: ((SwitchPostAction, String) -> Void)?
    private let autoClosePolicy: GitProgressAutoClose
    var close: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, reference: String, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.reference = reference; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences) }
    func start() { Task { await run() } }
    func run() async { guard !started else { return }; started = true; await execute(merge: false) }
    func cancel() { guard busy else { return }; cancellation.cancel() }
    func perform(_ action: SwitchPostAction) {
        guard !busy, postActions.contains(action) else { return }
        if action == .retry || action == .switchWithMerge {
            let merge = action == .switchWithMerge || merging
            busy = true; cancellation = OperationCancellation()
            Task { await execute(merge: merge) }
        } else if let onPostAction { let branch = previousBranch; close(); onPostAction(action, branch) }
    }
    private func execute(merge: Bool) async {
        busy = true; success = false; cancelled = false; postActions = []; output = ""; merging = merge
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            guard reference.hasPrefix("refs/heads/"), try await !repository.isBare() else { throw CheckoutFailure.invalidRevision }
            previousBranch = try await repository.branch()
            var options = CheckoutOptions(); options.revision = reference; options.merge = merge
            output = try await repository.checkout(options, cancellation: cancellation)
            let conflicts = try await repository.status(refreshIndex: false).contains { $0.state == .conflicted }
            if merge && conflicts { output += "\nHas merge conflict" }
            else {
                if (try? await repository.submoduleUpdatePaths().isEmpty) == false { postActions.append(.submoduleUpdate) }
                if !previousBranch.isEmpty { postActions.append(.mergePreviousBranch) }
                if try await !repository.branch().isEmpty { postActions.append(.pull) }
                postActions.append(.commit)
                success = true
            }
        } catch { output += (output.isEmpty ? "" : "\n") + error.localizedDescription }
        cancelled = cancellation.isCancelled
        if !success {
            postActions = []
            let conflicts = merge ? ((try? await repository.status(refreshIndex: false).contains { $0.state == .conflicted }) == true) : false
            if conflicts { postActions.append(.resolve) }
            if !merge { postActions.append(.stash) }
            postActions.append(.retry)
            if !merge { postActions.append(.switchWithMerge) }
        }
        busy = false; onFinished(output, success)
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() }
    }
}
private struct SwitchProgressDialog: View {
    @ObservedObject var model: SwitchProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch to \(model.reference.dropFirst("refs/heads/".count))").font(.headline)
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("Switching…") }
                else { Text(model.cancelled ? "Cancelled" : model.success ? "Finished" : "Switch failed").foregroundStyle(model.success ? Color.green : Color.red) }
                Spacer()
            }
            HStack {
                if let first = model.postActions.first {
                    HStack(spacing: 2) {
                        Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                        Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Switch post-actions") }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.busy)
                }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12)
    }
}
