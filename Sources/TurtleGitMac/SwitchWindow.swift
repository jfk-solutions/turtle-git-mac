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
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote) && $0.symbolicTarget == nil } }
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
