import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BranchTagWindowController: NSWindowController, NSWindowDelegate {
    let model: BranchTagWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        model = BranchTagWindowModel(repository: repository, access: access, isTag: isTag, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Create \(isTag ? "Tag" : "Branch") – TurtleGit"
        window.minSize = NSSize(width: 650, height: 480); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BranchTagDialog(model: model, chooser: model.chooser))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 660, height: 470)); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.chooser.busy, !self.model.hasPendingNameConflict, self.window?.attachedSheet == nil else { return }; self.window?.close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.chooser.busy && !model.hasPendingNameConflict && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BranchTagWindowModel: ObservableObject {
    let chooser: SwitchWindowModel
    let isTag: Bool
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var invalidated = false, finished = false
    private var conflictSnapshot: (ReferenceCreationOptions, Bool, Bool, Bool)?
    private var descriptionSnapshot: ReferenceCreationOptions?
    var hasPendingNameConflict: Bool { nameConflict || conflictSnapshot != nil }
    var retryDescription: Bool { descriptionSnapshot != nil }
    var onSwitch: ((String, @escaping () -> Void) -> Void)?
    func invalidate() { invalidated = true; conflictSnapshot = nil }
    func abortNameConflict() { nameConflict = false; conflictSnapshot = nil }
    @Published var options = ReferenceCreationOptions()
    @Published var useHead = true
    @Published var currentBranch = ""
    @Published var switchAfterCreation = false
    @Published var canSwitch = true
    @Published var canSign = false
    @Published var pushAfterCreation = false
    @Published var busy = false
    @Published var error: String?
    @Published var nameConflict = false
    @Published var createdBranch: String?
    var close: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var onPushTag: (String) -> Void = { _ in }
    var remote: Bool { !isTag && !useHead && chooser.remote }
    private var previousSuggestion = ""
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        self.isTag = isTag; self.access = access; self.preferences = preferences; chooser = SwitchWindowModel(repository: repository, access: access)
    }
    func load(revision: String?) {
        guard !busy, !chooser.busy, !hasPendingNameConflict, createdBranch == nil, !invalidated, !finished else { return }
        chooser.load(revision: revision); options = ReferenceCreationOptions(); options.isTag = isTag
        createdBranch = nil; previousSuggestion = ""
        useHead = revision == nil || revision == "HEAD" || revision?.isEmpty == true
        switchAfterCreation = preferences.bool(forKey: "NewBranchSwitchTo")
        pushAfterCreation = preferences.bool(forKey: "PushTag")
        busy = true
        Task {
            defer { busy = false }
            do {
                currentBranch = try await chooser.repository.branch()
                canSwitch = try await chooser.repository.run(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) != "true"
                canSign = !((try? await chooser.repository.run(["config", "--get", "user.signingkey"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "").isEmpty
            } catch { self.error = error.localizedDescription }
        }
    }
    func changedBase() {
        guard remote, let reference = chooser.references.first(where: { $0.name == chooser.branchRevision }) else { return }
        if options.name.isEmpty || options.name == previousSuggestion { options.name = reference.suggestedBranch }
        previousSuggestion = reference.suggestedBranch
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func create(allowNameConflict: Bool = false) {
        guard !busy, !chooser.busy, !invalidated, !finished else { return }
        if let snapshot = descriptionSnapshot { saveDescription(snapshot); return }
        var snapshot = options; snapshot.revision = useHead ? "HEAD" : chooser.revision; snapshot.allowNameConflict = allowNameConflict
        snapshot.name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldSwitch = !isTag && canSwitch && switchAfterCreation, shouldPush = isTag && pushAfterCreation, switchPreference = switchAfterCreation
        if allowNameConflict, let captured = conflictSnapshot { snapshot = captured.0; snapshot.allowNameConflict = true; shouldSwitch = captured.1; shouldPush = captured.2; switchPreference = captured.3 }
        else if hasPendingNameConflict { return }
        conflictSnapshot = nil; nameConflict = false
        if !isTag { preferences.set(switchPreference, forKey: "NewBranchSwitchTo") }
        else { preferences.set(shouldPush, forKey: "PushTag") }
        let nativeHandoff = onSwitch != nil
        let routedSwitch = shouldSwitch ? onSwitch : nil
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try checkAccess()
                var output = ""
                if createdBranch == nil {
                    output = try await chooser.repository.createReference(snapshot, writeDescription: !nativeHandoff)
                    if shouldSwitch { createdBranch = snapshot.name }
                }
                if nativeHandoff {
                    onCreated(output)
                    if let routedSwitch {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            var answered = false
                            routedSwitch("refs/heads/" + snapshot.name) { if !answered { answered = true; continuation.resume() } }
                        }
                    }
                    guard !invalidated else { return }
                    if !isTag && !snapshot.message.isEmpty {
                        descriptionSnapshot = snapshot
                        do { try checkAccess(); try await chooser.repository.updateBranchDescription(snapshot.name, message: snapshot.message); descriptionSnapshot = nil }
                        catch { createdBranch = snapshot.name; self.error = "Branch \(snapshot.name) was created, but its description could not be saved. Retry the description or close this dialog.\n\n" + error.localizedDescription; return }
                    }
                    busy = false; finished = true; close(); if shouldPush { onPushTag("refs/tags/" + snapshot.name) }; return
                }
                if shouldSwitch, let createdBranch {
                    var checkout = CheckoutOptions(); checkout.revision = "refs/heads/" + createdBranch
                    do { output += try await chooser.repository.checkout(checkout) }
                    catch { self.error = "Branch \(createdBranch) was created, but checkout failed. Resolve the working-tree changes and retry checkout, or close this dialog.\n\n" + error.localizedDescription; return }
                }
                guard !invalidated else { return }; busy = false; finished = true; close(); onCreated(output)
                if shouldPush { onPushTag("refs/tags/" + snapshot.name) }
            } catch ReferenceCreationFailure.nameConflict { conflictSnapshot = (snapshot, shouldSwitch, shouldPush, switchPreference); nameConflict = true }
            catch { self.error = error.localizedDescription }
        }
    }
    private func saveDescription(_ snapshot: ReferenceCreationOptions) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try checkAccess(); try await chooser.repository.updateBranchDescription(snapshot.name, message: snapshot.message); descriptionSnapshot = nil; guard !invalidated else { return }; busy = false; finished = true; close() }
            catch { self.error = error.localizedDescription }
        }
    }

}

struct BranchTagDialog: View {
    @ObservedObject var model: BranchTagWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    func select(_ target: CheckoutTarget) { model.useHead = false; chooser.options.target = target; model.changedBase() }
    func radio(_ title: String, target: CheckoutTarget) -> some View {
        BaseRadio(title: title, selected: !model.useHead && chooser.options.target == target) { select(target) }
    }
    var body: some View {
        VStack(spacing: 14) {
            GroupBox("Name") { HStack { Text(model.isTag ? "Tag:" : "Branch:").frame(width: 100, alignment: .leading)
                TextField(model.isTag ? "Tag name" : "Branch name", text: $model.options.name)
            }.padding(8) }.disabled(model.createdBranch != nil)
            GroupBox("Base On") {
                VStack(spacing: 6) {
                    BaseRadio(title: "HEAD (\(model.currentBranch.isEmpty ? "detached" : model.currentBranch))", selected: model.useHead) { model.useHead = true }.frame(height: 22)
                    HStack { radio("Branch", target: .branch).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision).disabled(model.useHead || chooser.options.target != .branch)
                        Button("…") { chooser.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.useHead || chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { radio("Tag", target: .tag).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision).disabled(model.useHead || chooser.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { radio("Commit", target: .commit).frame(width: 100)
                        TextField("Commit", text: $chooser.commitRevision).disabled(model.useHead || chooser.options.target != .commit)
                        Button("…") { chooser.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.useHead || chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }.disabled(model.createdBranch != nil)
            GroupBox("Options") { HStack {
                TrackingCheckbox(value: $model.options.tracking, enabled: model.remote).frame(width: 115)
                Toggle("Force", isOn: $model.options.force)
                if model.isTag {
                    Toggle("Sign", isOn: $model.options.sign).disabled(!model.canSign)
                    Toggle("Push", isOn: $model.pushAfterCreation)
                } else if model.canSwitch { Toggle("Switch to new branch", isOn: $model.switchAfterCreation) }
                Spacer()
            }.padding(8) }.disabled(model.createdBranch != nil)
            GroupBox(model.isTag ? "Message" : "Description") { TextEditor(text: $model.options.message).font(.system(.body, design: .monospaced)).frame(minHeight: 75) }.disabled(model.createdBranch != nil)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                Button(model.retryDescription ? "Retry description" : model.createdBranch == nil ? "OK" : "Retry checkout") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-branchtag.html")!) }
            }
        }.padding(16).disabled(model.busy || chooser.busy)
        .onChange(of: chooser.branchRevision) { _ in model.changedBase() }
        .onChange(of: model.useHead) { _ in model.changedBase() }
        .onChange(of: model.options.name) { name in if model.remote, let reference = chooser.references.first(where: { $0.name == chooser.branchRevision }), name != reference.suggestedBranch { model.options.tracking = .noTrack } }
        .alert("Create reference failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
        .alert("Branch and tag share a name", isPresented: $model.nameConflict) { Button("Continue") { model.create(allowNameConflict: true) }; Button("Abort", role: .cancel) { model.abortNameConflict() } } message: { Text(ReferenceCreationFailure.nameConflict.localizedDescription) }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
}

struct BaseRadio: NSViewRepresentable {
    let title: String
    let selected: Bool
    let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.state = selected ? .on : .off; button.isEnabled = enabled; context.coordinator.select = select
    }
    final class Coordinator: NSObject {
        var select: () -> Void = {}
        @objc func clicked(_ sender: NSButton) { select() }
    }
}
