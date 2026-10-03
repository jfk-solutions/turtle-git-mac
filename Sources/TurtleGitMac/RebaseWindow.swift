import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RebaseWindowController: NSWindowController, NSWindowDelegate {
    let model: RebaseWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = RebaseWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Rebase – TurtleGit"; window.minSize = NSSize(width: 930, height: 620); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RebaseDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); model.close = { [weak window] in window?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RebaseWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var options = RebaseOptions()
    @Published var ontoEnabled = false
    @Published var references: [CheckoutReference] = []
    @Published var plan: RebasePlan?
    @Published var recovered: [RebaseEntry] = []
    @Published var state: RebaseState?
    @Published var selection = Set<String>()
    @Published var files: [CommitFile] = []
    @Published var selectedFiles = Set<String>()
    @Published var message = ""
    @Published var amendMessage = ""
    @Published var output = ""
    @Published var tab = 0
    @Published var busy = false
    @Published var finished = false
    @Published var error: String?
    @Published var confirmation: String?
    @Published var browsing = false
    var close: () -> Void = {}
    var onChanged: () -> Void = {}
    var onShowStatus: () -> Void = {}
    private var planGeneration = 0
    private var detailGeneration = 0
    private var completion = "Rebase finished"
    var active: Bool { state?.active == true }
    var editable: Bool { !busy && !active && !finished }
    // Upstream displays newest first, while replay proceeds from the oldest commit.
    var entries: [RebaseEntry] {
        if active { return recovered.reversed() }
        if plan?.disposition == .upToDate || plan?.disposition == .equal { return [] }
        return Array((plan?.entries ?? []).reversed())
    }
    var canStart: Bool { editable && plan != nil && plan?.disposition != .upToDate && plan?.disposition != .equal }
    var status: String {
        if finished { return completion }
        if active { return "Step \(state?.currentStep ?? 0) of \(state?.total ?? 0) • \(state?.conflicts.count ?? 0) unresolved paths" }
        switch plan?.disposition {
        case .equal: return "Branch and upstream are the same revision."
        case .upToDate: return "Branch is up to date. Enable Force Rebase to replay its commits."
        case .fastForward: return "The branch can fast-forward to upstream."
        default: return "\(plan?.entries.count ?? 0) commits in the rebase plan"
        }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func load(upstream: String? = nil) {
        guard !busy else { return }; busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            defer { busy = false }
            do {
                references = try await repository.checkoutReferences(); state = try await repository.rebaseState()
                if active { options.branch = state?.branch ?? "HEAD"; options.upstream = state?.onto ?? ""; plan = nil; recovered = try await repository.remainingRebaseEntries(); selection = Set(recovered.first.map { [$0.id] } ?? []); amendMessage = state?.message ?? ""; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selectCommit(); return }
                finished = false; plan = nil; recovered = []; selection = []; files = []; message = ""; options = RebaseOptions(); ontoEnabled = false
                let branch = try await repository.branch(); options.branch = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
                let defaults = try await repository.pullDefaults()
                options.upstream = upstream ?? (defaults.trackedRemote.isEmpty || defaults.trackedBranch.isEmpty ? "" : "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch)
                if !options.upstream.isEmpty { plan = try await repository.rebasePlan(options); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func reloadPlan() {
        guard editable else { return }; planGeneration += 1; detailGeneration += 1
        let request = planGeneration; var snapshot = options; if !ontoEnabled { snapshot.onto = "" }
        plan = nil; selection = []; files = []; message = ""
        Task {
            do { let value = try await repository.rebasePlan(snapshot); guard request == planGeneration, editable else { return }; plan = value; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
            catch RebaseFailure.revision { /* Keep incomplete editable references without interrupting typing. */ }
            catch { if request == planGeneration { self.error = error.localizedDescription } }
        }
    }
    func setAction(_ action: RebaseAction, ids: Set<String>? = nil) {
        guard editable, !options.preserveMerges, var value = plan else { return }
        let targets = ids ?? selection
        for index in value.entries.indices where targets.contains(value.entries[index].id) { value.entries[index].action = action }
        plan = value
    }
    func move(up: Bool) {
        guard editable, !options.preserveMerges, selection.count == 1, let id = selection.first, var value = plan, let index = value.entries.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + (up ? 1 : -1)
        guard value.entries.indices.contains(destination) else { return }; value.entries.swapAt(index, destination); plan = value
    }
    func selectCommit() {
        detailGeneration += 1; let request = detailGeneration
        files = []; message = ""
        guard let entry = entries.first(where: { selection.contains($0.id) }) else { return }
        message = entry.commit.message
        Task {
            do { let changed = try await repository.files(in: entry.commit); guard request == detailGeneration else { return }; files = changed }
            catch { if request == detailGeneration { self.error = error.localizedDescription } }
        }
    }
    func refreshState() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { let wasActive = active; state = try await repository.rebaseState(); if active { recovered = try await repository.remainingRebaseEntries(); amendMessage = state?.message ?? ""; selectCommit() } else if wasActive { finished = true; completion = "Rebase session ended" }; onChanged() }
            catch { self.error = error.localizedDescription }
        }
    }
    func request(_ action: String) {
        if action == "start" { confirmation = "Start rewriting the selected branch using this commit plan?" }
        else if action == "abort" { confirmation = "Abort this rebase and restore its original branch? Current conflict-resolution edits will be discarded." }
        else if action == "skip" { confirmation = "Skip the current commit? Its changes and current conflict-resolution edits will be discarded." }
        else { execute(action) }
    }
    func execute(_ action: String) {
        guard !busy else { return }
        let snapshot = plan; busy = true; tab = 2
        Task {
            defer { busy = false }
            do {
                let result: RebaseExecution
                switch action {
                case "start": guard let snapshot, let executable = Bundle.main.executableURL else { throw RebaseFailure.plan }; result = try await repository.startRebase(snapshot, editorExecutable: executable)
                case "abort": result = try await repository.abortRebase()
                case "skip": result = try await repository.skipRebase()
                default: result = try await repository.continueRebase()
                }
                output += result.output + "\n"; state = result.state; finished = result.exitCode == 0 && !result.state.active; completion = action == "abort" ? "Rebase aborted" : "Rebase finished"
                if active { recovered = try await repository.remainingRebaseEntries(); amendMessage = state?.message ?? ""; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selection = Set(state?.stoppedCommit.isEmpty == false ? [state!.stoppedCommit] : []) }
                if result.exitCode != 0 { error = result.output }
                onChanged()
            } catch { self.error = error.localizedDescription }
        }
    }
    func amend() {
        guard active, !busy else { return }; busy = true; let text = amendMessage
        Task { defer { busy = false }; do { output += try await repository.amendRebaseCommit(message: text); onChanged() } catch { self.error = error.localizedDescription } }
    }

}
private struct RebaseDialog: View {
    @ObservedObject var model: RebaseWindowModel
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Branch:"); PushRefCombo(value: $model.options.branch, choices: model.references.filter { $0.name.hasPrefix("refs/heads/") }.map(\.name), local: true)
                Button { let branch = model.options.branch; model.options.branch = model.options.upstream; model.options.upstream = branch; model.reloadPlan() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }.accessibilityLabel("Reverse branch and upstream")
                Text("Upstream:"); PushRefCombo(value: $model.options.upstream, choices: model.references.map(\.name), local: true)
                Button("…") { model.browsing = true }.accessibilityLabel("Browse upstream references")
                Toggle("Onto", isOn: $model.ontoEnabled).toggleStyle(.button)
            }.disabled(!model.editable)
            if model.ontoEnabled { HStack { Text("Onto:"); PushRefCombo(value: $model.options.onto, choices: model.references.map(\.name), local: true) }.disabled(!model.editable) }
            VSplitView {
                VStack(spacing: 8) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("Action") { entry in HStack(spacing: 5) { Image(nsImage: entry.action.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.action == .skip ? "Skip" : entry.action.rawValue.capitalized) } }.width(90)
                        TableColumn("Message") { entry in Text(entry.commit.subject) }
                        TableColumn("Author") { entry in Text(entry.commit.author) }.width(130)
                        TableColumn("Date") { entry in Text(entry.commit.date) }.width(150)
                        TableColumn("Hash") { entry in Text(String(entry.id.prefix(9))).font(.system(.caption, design: .monospaced)) }.width(95)
                    }.contextMenu(forSelectionType: String.self) { ids in ForEach(RebaseAction.allCases, id: \.self) { action in Button { model.setAction(action, ids: ids) } label: { CommandLabel(title: action == .skip ? "Skip" : action.rawValue.capitalized, icon: action.icon) }.disabled(ids.isEmpty || !model.editable || model.options.preserveMerges) } }
                    HStack {
                        Menu("Select all options") {
                            ForEach(RebaseAction.allCases.filter { $0 != .skip }, id: \.self) { action in Button("Select all: " + (action == .skip ? "Skip" : action.rawValue.capitalized)) { model.setAction(action, ids: Set(model.entries.map(\.id))) } }
                            Divider()
                            ForEach([RebaseAction.skip, .squash, .edit], id: \.self) { action in Button("Unselected: " + (action == .skip ? "Skip" : action.rawValue.capitalized)) { model.setAction(action, ids: Set(model.entries.map(\.id)).subtracting(model.selection)) } }
                        }.disabled(!model.editable || model.options.preserveMerges)
                        Button("Up") { model.move(up: true) }.disabled(!model.editable || model.options.preserveMerges || model.selection.count != 1)
                        Button("Down") { model.move(up: false) }.disabled(!model.editable || model.options.preserveMerges || model.selection.count != 1)
                        Button("Add") {}.disabled(true).help("Adding commits outside this plan is still being ported.")
                        Spacer(); Toggle("Preserve merges", isOn: $model.options.preserveMerges); Toggle("Force Rebase", isOn: $model.options.force)
                    }.disabled(!model.editable)
                }.frame(minHeight: 180)
                TabView(selection: $model.tab) {
                    Table(model.files, selection: $model.selectedFiles) {
                        TableColumn("Path", value: \.path)
                        TableColumn("Extension") { file in Text((file.path as NSString).pathExtension) }.width(70)
                        TableColumn("Status", value: \.status).width(100)
                        TableColumn("Lines added") { file in Text(file.added.map(String.init) ?? "–") }.width(85)
                        TableColumn("Lines removed") { file in Text(file.removed.map(String.init) ?? "–") }.width(95)
                    }.tabItem { Text("Changed Files") }.tag(0)
                    ScrollView { Text(model.message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) }.tabItem { Text("Commit Message") }.tag(1)
                    OutputView(text: model.output).tabItem { Text("Progress") }.tag(2)
                }.frame(minHeight: 150)
            }
            if model.active {
                HStack { Button("Open Working Tree") { model.onShowStatus() }; Button("Refresh State") { model.refreshState() }; Spacer(); Button("Skip") { model.request("skip") } }
                HStack { Text("Edit commit message:"); TextField("Commit message", text: $model.amendMessage); Button("Amend") { model.amend() }.disabled(model.amendMessage.isEmpty || model.state?.conflicts.isEmpty != true) }
            }
            if model.busy { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: model.finished ? 1 : Double(model.state?.currentStep ?? 0), total: model.finished ? 1 : Double(max(model.state?.total ?? 1, 1))) }
            HStack {
                Text(model.status).font(.caption); Spacer()
                Button(model.finished ? "Done" : model.active ? "Continue" : "Start Rebase") { if model.finished { model.close() } else { model.request(model.active ? "continue" : "start") } }.keyboardShortcut(.defaultAction).disabled(!model.finished && !model.active && !model.canStart)
                Button(model.active ? "Abort" : "Cancel") { if model.active { model.request("abort") } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-rebase.html")!) }
            }
        }.padding(12).disabled(model.busy)
        .onChange(of: model.options.branch) { _ in model.reloadPlan() }
        .onChange(of: model.options.upstream) { _ in model.reloadPlan() }
        .onChange(of: model.options.onto) { _ in model.reloadPlan() }
        .onChange(of: model.ontoEnabled) { _ in model.reloadPlan() }
        .onChange(of: model.options.force) { _ in model.reloadPlan() }
        .onChange(of: model.options.preserveMerges) { _ in model.reloadPlan() }
        .onChange(of: model.selection) { _ in model.selectCommit() }
        .alert("Rebase", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } message: { Text(model.error ?? "") }
        .alert("Confirm Rebase", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            Button("Continue") { let text = model.confirmation ?? ""; model.confirmation = nil; model.execute(text.hasPrefix("Abort") ? "abort" : text.hasPrefix("Skip") ? "skip" : "start") }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.confirmation ?? "") }
        .sheet(isPresented: $model.browsing) { RebaseReferenceChooser(model: model) }
    }
}
private struct RebaseReferenceChooser: View {
    @ObservedObject var model: RebaseWindowModel
    @State private var selection: String?
    @State private var filter = ""
    var body: some View { VStack(spacing: 12) {
        Text("Browse upstream references").font(.headline); TextField("Filter", text: $filter)
        List(model.references.filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) }, selection: $selection) { Text($0.label).tag($0.name) }
        HStack { Spacer(); Button("Cancel") { model.browsing = false }.keyboardShortcut(.cancelAction); Button("OK") { if let selection { model.options.upstream = selection; model.browsing = false } }.keyboardShortcut(.defaultAction).disabled(selection == nil) }
    }.padding(16).frame(width: 650, height: 430) }
}

private extension RebaseAction {
    var icon: MenuIcon {
        switch self { case .pick: return .rebasePick; case .skip: return .rebaseSkip; case .edit: return .rebaseEdit; case .squash: return .rebaseSquash }
    }
}
