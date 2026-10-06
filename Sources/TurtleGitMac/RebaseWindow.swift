import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RebaseWindowController: NSWindowController, NSWindowDelegate {
    let model: RebaseWindowModel
    var onClosed: () -> Void = {}
    private var logPicker: LogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = RebaseWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Rebase – TurtleGit"; window.minSize = NSSize(width: 930, height: 620); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RebaseDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); model.close = { [weak window] in window?.close() }
        model.onModeChanged = { [weak window, weak model] in
            window?.title = "\(repository.root.lastPathComponent) – \(model?.operationTitle ?? "Rebase") – TurtleGit"
        }
        model.pickAdditionalCommits = { [weak self] in
            guard let self, self.model.canAdd, let window = self.window, window.attachedSheet == nil, self.logPicker == nil else { return }
            self.model.pickingCommits = true
            let picker = LogWindowController(repository: repository, access: access, onChooseMultiple: { [weak self] revisions in
                guard let self else { return }; self.model.finishPickingCommits(revisions?.map(\.hash))
            })
            self.logPicker = picker
            picker.onClosed = { [weak self] in self?.logPicker = nil }
            self.model.configureLogPicker(picker.model)
            if let child = picker.window { window.beginSheet(child) } else { self.logPicker = nil; self.model.pickingCommits = false }
        }
        model.chooseMainline = { [weak window] commit, choices in
            guard let window, window.attachedSheet == nil else { return nil }
            let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.alertStyle = .informational
            alert.informativeText = "\"\(commit.hash)\" - \"\(commit.subject)\"\nis a merge commit.\n\nWhich parent do you want to pick?"
            for choice in choices { alert.addButton(withTitle: choice.title) }
            let cancel = alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.keyEquivalent = ""; cancel.keyEquivalent = "\r"; alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            let response = await alert.beginSheetModal(for: window)
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return choices.indices.contains(index) ? choices[index].number : nil
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { logPicker?.close(); logPicker = nil; onClosed() }
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
    @Published var draftEntries: [RebaseEntry] = []
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
    @Published var pickingCommits = false
    var close: () -> Void = {}
    var onChanged: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onModeChanged: () -> Void = {}
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var pickAdditionalCommits: () -> Void = {}
    var chooseMainline: (LogEntry, [LogParentChoice]) async -> Int? = { _, _ in nil }
    var editorExecutable: URL? = Bundle.main.executableURL
    var isCherryPick: Bool { options.isCherryPick || state?.isCherryPick == true }
    var operationTitle: String { isCherryPick ? "Cherry Pick" : "Rebase" }
    var startTitle: String { isCherryPick ? "Continue" : "Start Rebase" }
    var helpURL: URL { URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-" + (isCherryPick ? "cherrypick" : "rebase") + ".html")! }
    private var planGeneration = 0
    private var detailGeneration = 0
    private var completion = "Rebase finished"
    private var pendingLoad: (upstream: String?, autoStart: Bool, preserveMerges: Bool, cherryPick: [String]?)?
    private func loadPendingHandoff() {
        guard !busy, !pickingCommits, let pending = pendingLoad else { return }
        pendingLoad = nil
        load(upstream: pending.upstream, autoStart: pending.autoStart, preserveMerges: pending.preserveMerges, cherryPick: pending.cherryPick)
    }
    var active: Bool { state?.active == true }
    var editable: Bool { !busy && !active && !finished && !pickingCommits }
    var canAdd: Bool { editable && !options.preserveMerges }
    // Upstream displays newest first, while replay proceeds from the oldest commit.
    var entries: [RebaseEntry] {
        if active { return recovered.reversed() }
        if plan?.disposition == .upToDate || plan?.disposition == .equal { return [] }
        return Array((plan?.entries ?? draftEntries).reversed())
    }
    func entryNumber(_ entry: RebaseEntry) -> Int {
        if active { return (state?.currentStep ?? 1) + (recovered.firstIndex(where: { $0.id == entry.id }) ?? 0) }
        return ((plan?.entries ?? draftEntries).firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }
    var canStart: Bool { editable && plan != nil && plan?.disposition != .upToDate && plan?.disposition != .equal && plan?.entries.first(where: { $0.action != .skip })?.action != .squash }
    var status: String {
        if finished { return completion }
        if active { return "Step \(state?.currentStep ?? 0) of \(state?.total ?? 0) • \(state?.conflicts.count ?? 0) unresolved paths" }
        if plan == nil { return "Choose valid branch and upstream revisions before starting." }
        switch plan?.disposition {
        case .equal: return "Branch and upstream are the same revision."
        case .upToDate: return "Branch is up to date. Enable Force Rebase to replay its commits."
        case .fastForward: return "The branch can fast-forward to upstream."
        default: return "\(plan?.entries.count ?? 0) commits in the \(operationTitle.lowercased()) plan"
        }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func load(upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil) {
        guard !busy, !pickingCommits else {
            if upstream != nil || cherryPick != nil { pendingLoad = (upstream, autoStart, preserveMerges, cherryPick) }
            return
        }; busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            var started = false
            defer { if !started { busy = false; loadPendingHandoff() } }
            do {
                try requireAccess()
                references = try await repository.checkoutReferences(); state = try await repository.rebaseState(); finished = false; output = ""; error = nil; confirmation = nil; draftEntries = []
                if active { options.isCherryPick = state?.isCherryPick == true; onModeChanged(); options.branch = state?.branch ?? "HEAD"; options.upstream = state?.onto ?? ""; plan = nil; recovered = try await repository.remainingRebaseEntries(); selection = Set(recovered.first.map { [$0.id] } ?? []); amendMessage = state?.message ?? ""; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selectCommit(); return }
                finished = false; plan = nil; recovered = []; selection = []; files = []; message = ""; options = RebaseOptions(); options.preserveMerges = preserveMerges; ontoEnabled = false
                if let cherryPick {
                    plan = try await repository.cherryPickPlan(revisions: cherryPick)
                    options = plan!.options
                    options.addCherryPickedFrom = UserDefaults.standard.bool(forKey: "CherrypickAddCherryPickedFrom")
                    updateAttribution()
                    onModeChanged(); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit(); return
                }
                onModeChanged()
                let branch = try await repository.branch(); options.branch = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
                let defaults = try await repository.pullDefaults()
                options.upstream = upstream ?? (defaults.trackedRemote.isEmpty || defaults.trackedBranch.isEmpty ? "" : "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch)
                if !options.upstream.isEmpty { plan = try await repository.rebasePlan(options); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
                busy = false
                if autoStart && canStart { started = true; execute("start") }
            } catch { self.error = error.localizedDescription }
        }
    }
    func reloadPlan() {
        guard editable, !isCherryPick else { return }; planGeneration += 1; detailGeneration += 1
        let request = planGeneration; var snapshot = options; if !ontoEnabled { snapshot.onto = "" }
        plan = nil; draftEntries = []; selection = []; files = []; message = ""
        Task {
            do { let value = try await repository.rebasePlan(snapshot); guard request == planGeneration, editable else { return }; plan = value; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit() }
            catch RebaseFailure.revision { /* Keep incomplete editable references without interrupting typing. */ }
            catch { if request == planGeneration { self.error = error.localizedDescription } }
        }
    }
    private func requireAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func updateAttribution() {
        guard isCherryPick, var value = plan, !active else { return }
        value.options.addCherryPickedFrom = options.addCherryPickedFrom
        plan = value
        UserDefaults.standard.set(options.addCherryPickedFrom, forKey: "CherrypickAddCherryPickedFrom")
    }
    private func prepareCherryPick() {
        guard canStart, var snapshot = plan else { return }
        busy = true
        Task {
            do {
                try requireAccess()
                for index in snapshot.entries.indices where snapshot.entries[index].action != .skip && snapshot.entries[index].commit.parents.count > 1 {
                    let commit = snapshot.entries[index].commit
                    let choices = try await repository.logParentChoices(commit)
                    guard let parent = await chooseMainline(commit, choices) else { busy = false; loadPendingHandoff(); return }
                    snapshot.entries[index].mainline = parent
                }
                plan = snapshot; busy = false; execute("start")
            } catch { busy = false; self.error = error.localizedDescription; loadPendingHandoff() }
        }
    }
    func finishPickingCommits(_ revisions: [String]?) {
        pickingCommits = false
        if let revisions, !revisions.isEmpty { addCommits(revisions) }
        else { loadPendingHandoff() }
    }
    func addCommits(_ revisions: [String]) {
        guard canAdd, !revisions.isEmpty else { return }
        let snapshot = plan, draft = draftEntries
        var settings = options; if !ontoEnabled { settings.onto = "" }
        busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            defer { busy = false; loadPendingHandoff() }
            do {
                try requireAccess()
                let added: [RebaseEntry]
                if let snapshot {
                    let value = try await repository.addingRebaseCommits(snapshot, revisions: revisions)
                    plan = value; added = value.entries
                } else {
                    let draftResult = try await repository.addingRebaseEntries(draft, revisions: revisions)
                    var captured: RebasePlan?
                    do { captured = try await repository.rebasePlan(settings) }
                    catch RebaseFailure.revision { /* Draft Add is available before references are complete. */ }
                    if let captured {
                        let value = try await repository.addingRebaseCommits(captured, revisions: draftResult.reversed().map { $0.commit.hash })
                        plan = value; draftEntries = []; added = value.entries
                    } else { draftEntries = draftResult; added = draftResult }
                }
                selection = Set(added.suffix(revisions.count).map(\.id)); selectCommit()
            } catch { self.error = error.localizedDescription }
        }
    }
    func setAction(_ action: RebaseAction, ids: Set<String>? = nil) {
        guard editable, !options.preserveMerges else { return }
        var values = plan?.entries ?? draftEntries
        let targets = ids ?? selection
        for index in values.indices where targets.contains(values[index].id) { values[index].action = action }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    func move(up: Bool) {
        guard editable, !options.preserveMerges, selection.count == 1, let id = selection.first else { return }
        var values = plan?.entries ?? draftEntries
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + (up ? 1 : -1)
        guard values.indices.contains(destination) else { return }; values.swapAt(index, destination)
        if plan != nil { plan?.entries = values } else { draftEntries = values }
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
            defer { busy = false; loadPendingHandoff() }
            do { let wasActive = active; state = try await repository.rebaseState(); onModeChanged(); if active { recovered = try await repository.remainingRebaseEntries(); amendMessage = state?.message ?? ""; selectCommit() } else if wasActive { finished = true; completion = "\(operationTitle) session ended" }; onChanged() }
            catch { self.error = error.localizedDescription }
        }
    }
    func request(_ action: String) {
        if action == "start", isCherryPick { prepareCherryPick(); return }
        if action == "start" { guard canStart else { return }; confirmation = "Start rewriting the selected branch using this commit plan?" }
        else if action == "abort" { confirmation = "Abort this \(operationTitle.lowercased()) and restore its original branch? Current conflict-resolution edits will be discarded." }
        else if action == "skip" { confirmation = "Skip the current commit? Its changes and current conflict-resolution edits will be discarded." }
        else { execute(action) }
    }
    func execute(_ action: String) {
        guard !busy, !pickingCommits, action != "start" || canStart else { return }
        let snapshot = plan; busy = true; tab = 2
        Task {
            defer { busy = false; loadPendingHandoff() }
            do {
                try requireAccess()
                let result: RebaseExecution
                switch action {
                case "start": guard let snapshot, let executable = editorExecutable else { throw RebaseFailure.plan }; result = try await repository.startRebase(snapshot, editorExecutable: executable)
                case "abort": result = try await repository.abortRebase()
                case "skip": result = try await repository.skipRebase()
                default: result = try await repository.continueRebase()
                }
                output += result.output + "\n"; state = result.state; finished = result.exitCode == 0 && !result.state.active; completion = action == "abort" ? "\(operationTitle) aborted" : "\(operationTitle) finished"
                if active { recovered = try await repository.remainingRebaseEntries(); amendMessage = state?.message ?? ""; if amendMessage.isEmpty, let commit = recovered.first { amendMessage = commit.commit.message }; selection = Set(state?.stoppedEntryID.isEmpty == false ? [state!.stoppedEntryID] : []) }
                if result.exitCode != 0 { error = result.output }
                onChanged()
            } catch { self.error = error.localizedDescription }
        }
    }
    func amend() {
        guard active, !busy else { return }; busy = true; let text = amendMessage
        Task { defer { busy = false; loadPendingHandoff() }; do { try requireAccess(); output += try await repository.amendRebaseCommit(message: text); onChanged() } catch { self.error = error.localizedDescription } }
    }

}
struct RebaseDialog: View {
    @ObservedObject var model: RebaseWindowModel
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if model.isCherryPick {
                    Text("Branch:"); TextField("", text: .constant("")).disabled(true)
                    Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16).opacity(0.4)
                    Text("Upstream:"); TextField("", text: .constant("HEAD")).disabled(true)
                    Button("…") {}.disabled(true); Toggle("Onto", isOn: .constant(false)).toggleStyle(.button).disabled(true)
                } else {
                Text("Branch:"); PushRefCombo(value: $model.options.branch, choices: model.references.filter { $0.name.hasPrefix("refs/heads/") }.map(\.name), local: true)
                Button { let branch = model.options.branch; model.options.branch = model.options.upstream; model.options.upstream = branch; model.reloadPlan() } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }.accessibilityLabel("Reverse branch and upstream")
                Text("Upstream:"); PushRefCombo(value: $model.options.upstream, choices: model.references.map(\.name), local: true)
                Button("…") { model.browsing = true }.accessibilityLabel("Browse upstream references")
                Toggle("Onto", isOn: $model.ontoEnabled).toggleStyle(.button)
                }
            }.disabled(!model.editable)
            if model.ontoEnabled { HStack { Text("Onto:"); PushRefCombo(value: $model.options.onto, choices: model.references.map(\.name), local: true) }.disabled(!model.editable) }
            VSplitView {
                VStack(spacing: 8) {
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("REBASE") { entry in HStack(spacing: 5) { Image(nsImage: entry.action.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(entry.action == .skip ? "Skip" : entry.action.rawValue.capitalized) } }.width(90)
                        TableColumn("ID") { entry in Text(String(model.entryNumber(entry))) }.width(40)
                        TableColumn("Hash") { entry in Text(String(entry.id.prefix(9))).font(.system(.caption, design: .monospaced)) }.width(95)
                        TableColumn("Message") { entry in Text(entry.commit.subject) }
                        TableColumn("Author") { entry in Text(entry.commit.author) }.width(130)
                        TableColumn("Date") { entry in Text(HistoryDateSettings.load().format(entry.commit.date)) }.width(150)
                    }.contextMenu(forSelectionType: String.self) { ids in
                        TurtleGitContextMenu {
     ForEach(RebaseAction.allCases, id: \.self) { action in Button { model.setAction(action, ids: ids) } label: { CommandLabel(title: action == .skip ? "Skip" : action.rawValue.capitalized, icon: action.icon) }.disabled(ids.isEmpty || !model.editable || model.options.preserveMerges) }
                        }
                    }
                    HStack {
                        Button("Pick ALL") { model.setAction(.pick, ids: Set(model.entries.map(\.id))) }.disabled(!model.editable || model.options.preserveMerges)
                        Menu("Options") {
                            ForEach(RebaseAction.allCases.filter { $0 != .skip }, id: \.self) { action in Button("Select all: " + (action == .skip ? "Skip" : action.rawValue.capitalized)) { model.setAction(action, ids: Set(model.entries.map(\.id))) } }
                            Divider()
                            ForEach([RebaseAction.skip, .squash, .edit], id: \.self) { action in Button("Unselected: " + (action == .skip ? "Skip" : action.rawValue.capitalized)) { model.setAction(action, ids: Set(model.entries.map(\.id)).subtracting(model.selection)) } }
                        }.disabled(!model.editable || model.options.preserveMerges)
                        Button("Up") { model.move(up: true) }.disabled(!model.editable || model.options.preserveMerges || model.selection.count != 1)
                        Button("Down") { model.move(up: false) }.disabled(!model.editable || model.options.preserveMerges || model.selection.count != 1)
                        Button { model.pickAdditionalCommits() } label: { CommandLabel(title: "Add", icon: .add) }.disabled(!model.canAdd)
                        Spacer()
                        if model.isCherryPick { Toggle("add \"cherry picked from\"", isOn: $model.options.addCherryPickedFrom) }
                        else { Toggle("Preserve merges", isOn: $model.options.preserveMerges); Toggle("Force Rebase", isOn: $model.options.force) }
                    }.disabled(!model.editable)
                }.frame(minHeight: 180)
                TabView(selection: $model.tab) {
                    Table(model.files, selection: $model.selectedFiles) {
                        TableColumn("Path", value: \.path)
                        TableColumn("Extension") { file in Text((file.path as NSString).pathExtension) }.width(70)
                        TableColumn("Status", value: \.status).width(100)
                        TableColumn("Lines added") { file in Text(file.added.map(String.init) ?? "–") }.width(85)
                        TableColumn("Lines removed") { file in Text(file.removed.map(String.init) ?? "–") }.width(95)
                    }.tabItem { Text("Revision Files") }.tag(0)
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
                Button(model.finished ? "Done" : model.active ? "Continue" : model.startTitle) { if model.finished { model.close() } else { model.request(model.active ? "continue" : "start") } }.keyboardShortcut(.defaultAction).disabled(!model.finished && !model.active && !model.canStart)
                Button(model.active || model.isCherryPick ? "Abort" : "Cancel") { if model.active { model.request("abort") } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(model.helpURL) }
            }
        }.padding(12).disabled(model.busy)
        .onChange(of: model.options.branch) { _ in model.reloadPlan() }
        .onChange(of: model.options.upstream) { _ in model.reloadPlan() }
        .onChange(of: model.options.onto) { _ in model.reloadPlan() }
        .onChange(of: model.ontoEnabled) { _ in model.reloadPlan() }
        .onChange(of: model.options.addCherryPickedFrom) { _ in model.updateAttribution() }
        .onChange(of: model.options.force) { _ in model.reloadPlan() }
        .onChange(of: model.options.preserveMerges) { _ in model.reloadPlan() }
        .onChange(of: model.selection) { _ in model.selectCommit() }
        .alert(model.operationTitle, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } message: { Text(model.error ?? "") }
        .alert("Confirm " + model.operationTitle, isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
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
