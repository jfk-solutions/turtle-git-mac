import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BranchTagWindowController: NSWindowController, NSWindowDelegate {
    let model: BranchTagWindowModel
    var onClosed: () -> Void = {}
    private var pickers: VersionPickerCoordinator!
    private(set) var cancellationAlert: NSAlert?
    var referencePicker: ReferenceBrowserWindowController? { pickers.referencePicker }
    var commitPicker: LogWindowController? { pickers.commitPicker }
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void { get { pickers.configureReferencePicker } set { pickers.configureReferencePicker = newValue } }
    var configureCommitPicker: (LogWindowModel) -> Void { get { pickers.configureCommitPicker } set { pickers.configureCommitPicker = newValue } }
    var presentPicker: (NSWindow, NSWindow) -> Bool { get { pickers.presentPicker } set { pickers.presentPicker = newValue } }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, @escaping (LogEntry?) -> Void, UserDefaults, String?) -> LogWindowController { get { pickers.makeCommitPicker } set { pickers.makeCommitPicker = newValue } }

    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        model = BranchTagWindowModel(repository: repository, access: access, isTag: isTag, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Create \(isTag ? "Tag" : "Branch")", preferences: preferences)
        window.minSize = NSSize(width: 650, height: 480); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BranchTagDialog(model: model, chooser: model.chooser).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        pickers = VersionPickerCoordinator(window: window, model: model.chooser, access: access, preferences: preferences, allowed: { [weak model] in model?.canPickBase == true })
        pickers.contextualDraft = { [weak model] in guard let model else { return [] }; return [String(model.useHead), model.options.name, String(model.switchAfterCreation), String(model.pushAfterCreation)].map { GitReferenceName($0) } }
        pickers.onSelection = { [weak model] in if model?.useHead == false { model?.changedBase() } }
        window.setContentSize(NSSize(width: 660, height: 470)); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.chooser.busy, self.model.chooser.pickerTarget == nil, !self.model.hasPendingNameConflict, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; self.window?.close() }

        model.confirmCancellation = { [weak self, weak window] answer in
            guard let self, let window, window.attachedSheet == nil else { answer(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            self.cancellationAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak window] response in
                self?.cancellationAlert = nil
                Task { @MainActor in
                    // Defer the follow-up close/Push until AppKit detaches the sheet.
                    while window?.attachedSheet === alert.window { await Task.yield() }
                    answer(response == .alertFirstButtonReturn)
                }
            }
        }
        DialogGeometry.attach(window, identifier: "BranchTagWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.hasActiveCreation { model.cancel(); return false }
        return !model.busy && !model.confirmingCancellation && !model.chooser.busy && model.chooser.pickerTarget == nil && !model.hasPendingNameConflict && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        model.invalidate(); pickers.invalidate()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        cancellationAlert = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BranchTagWindowModel: ObservableObject {
    private(set) static var activeReads = 0
    private(set) static var activeCreations = 0
    var presentationPreferences: UserDefaults { preferences }
    var hasActiveCreation: Bool { creationToken != nil }
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var awaitingSwitch = false
    private var cancelAnswer: ((Bool) -> Void)?
    private var switchAnswer: (() -> Void)?
    var cancelSwitchPresentation: (() -> Void)?
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    private var closeWhenIdle = false, completionReady = false
    private var pendingPush: String?
    private var createdOptions: ReferenceCreationOptions?
    private var createdOutput = ""
    private var notifiedCreation = false
    private var createdShouldSwitch = false, createdShouldPush = false
    let chooser: SwitchWindowModel
    let isTag: Bool
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var loadToken: OperationCancellation?
    private var creationToken: OperationCancellation?
    private var invalidated = false, finished = false
    private var conflictSnapshot: (ReferenceCreationOptions, Bool, Bool, Bool)?
    private var descriptionSnapshot: ReferenceCreationOptions?
    var hasPendingNameConflict: Bool { nameConflict || conflictSnapshot != nil }
    var retryDescription: Bool { descriptionSnapshot != nil }
    var onSwitch: ((String, @escaping () -> Void) -> Void)?
    func invalidate() {
        guard !invalidated else { return }; invalidated = true
        loadToken?.cancel(); creationToken?.cancel(); conflictSnapshot = nil
        let answer = cancelAnswer; cancelAnswer = nil; answer?(false)
        let stop = cancelSwitchPresentation; cancelSwitchPresentation = nil; stop?()
        let finish = switchAnswer; switchAnswer = nil; finish?()
        chooser.invalidate(); busy = false; completionReady = false; pendingPush = nil
    }
    var canCancel: Bool { !invalidated && !finished && (!chooser.busy || chooser.initialReadActive) && !confirmingCancellation && !cancelling && !awaitingSwitch && chooser.pickerTarget == nil && !hasPendingNameConflict }
    func cancel() {
        guard canCancel else { return }
        guard let token = creationToken else {
            if loadToken != nil || chooser.initialReadActive {
                closeWhenIdle = true; cancelling = true; loadToken?.cancel(); _ = chooser.cancelInitialRead()
                finishCloseWhenReady()
            } else { close() }
            return
        }
        let stop: (Bool) -> Void = { [weak self] approved in
            guard let self, !self.invalidated, approved else { return }
            self.closeWhenIdle = true; self.abortNameConflict()
            if self.creationToken === token { self.cancelling = true; token.cancel() }
            self.finishCloseWhenReady()
        }
        guard preferences.bool(forKey: "ConfirmKillProcess") else { stop(true); return }
        confirmingCancellation = true; Self.activeCreations += 1
        var answered = false
        let answer: (Bool) -> Void = { [weak self] approved in
            guard !answered else { return }; answered = true; Self.activeCreations -= 1
            guard let self else { return }; self.cancelAnswer = nil; self.confirmingCancellation = false
            stop(approved); self.finishCloseWhenReady(); withExtendedLifetime(self.access) {}
        }
        cancelAnswer = answer; confirmCancellation(answer)
    }
    private func finishCloseWhenReady() {
        guard !invalidated, !busy, loadToken == nil, creationToken == nil, !chooser.busy, !confirmingCancellation, !awaitingSwitch else { return }
        guard completionReady || closeWhenIdle else { return }
        completionReady = false; closeWhenIdle = false; cancelling = false
        let push = pendingPush; pendingPush = nil
        close(); if let push { onPushTag(push) }
    }
    private func complete(push: String? = nil) {
        finished = true; completionReady = true; pendingPush = push
    }
    private func notifyCreated() { if !notifiedCreation { notifiedCreation = true; onCreated(createdOutput) } }
    private func handoffSwitch(_ reference: String, using route: (String, @escaping () -> Void) -> Void) async {
        awaitingSwitch = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var answered = false
            let done: () -> Void = { [weak self] in
                guard !answered else { return }; answered = true
                self?.switchAnswer = nil; self?.cancelSwitchPresentation = nil; self?.awaitingSwitch = false
                continuation.resume()
            }
            switchAnswer = done; route(reference, done)
        }
    }
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
    var canPickBase: Bool { !busy && !chooser.busy && !useHead && !hasPendingNameConflict && createdBranch == nil && !invalidated && !finished && !confirmingCancellation && !cancelling }
    var remote: Bool { !isTag && !useHead && chooser.remote }
    private var previousSuggestion = ""
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool, preferences: UserDefaults = .standard) {
        self.isTag = isTag; self.access = access; self.preferences = preferences; chooser = SwitchWindowModel(repository: repository, access: access, preferences: preferences)
        chooser.onInitialReadSettled = { [weak self] in self?.changedBase(); self?.finishCloseWhenReady() }
    }
    func load(revision: String?) {
        guard !busy, !chooser.busy, chooser.pickerTarget == nil, !hasPendingNameConflict, createdBranch == nil, !invalidated, !finished, !confirmingCancellation, !cancelling else { return }
        chooser.load(revision: revision); options = ReferenceCreationOptions(); options.isTag = isTag
        createdBranch = nil; previousSuggestion = ""
        useHead = revision == nil || revision == "HEAD" || revision?.isEmpty == true
        switchAfterCreation = preferences.bool(forKey: "NewBranchSwitchTo")
        pushAfterCreation = preferences.bool(forKey: "PushTag")
        busy = true; let token = OperationCancellation(); loadToken = token
        Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(access) {}; if loadToken === token { loadToken = nil; busy = false }; changedBase(); finishCloseWhenReady() }
            do {
                try checkAccess()
                let current = try await chooser.repository.branch(cancellation: token)
                let workingTree = !(try await chooser.repository.isBare(cancellation: token))
                let signing = !((try? await chooser.repository.run(["config", "--get", "user.signingkey"], cancellation: token).stdout).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "").isEmpty
                guard !invalidated, loadToken === token, !token.isCancelled else { return }
                currentBranch = current; canSwitch = workingTree; canSign = signing
            } catch { if !invalidated, loadToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func changedBase() {
        guard !invalidated, !finished, !busy, !chooser.busy, chooser.pickerTarget == nil, createdBranch == nil, remote, let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) else { return }
        if options.name.isEmpty || options.name == previousSuggestion { options.name = reference.suggestedBranch }
        previousSuggestion = reference.suggestedBranch
    }
    func nameChanged() {
        guard !invalidated, !finished, !busy, !chooser.busy, chooser.pickerTarget == nil, createdBranch == nil, remote,
              let reference = chooser.references.first(where: { GitReferenceName.equal($0.name, chooser.branchRevision) }) else { return }
        let suffix = Array(("/" + options.name).utf16)
        if !reference.name.utf16.suffix(suffix.count).elementsEqual(suffix) { options.tracking = .noTrack }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func create(allowNameConflict: Bool = false) {
        guard !busy, !chooser.busy, chooser.pickerTarget == nil, !invalidated, !finished, !confirmingCancellation, !cancelling else { return }
        if let snapshot = descriptionSnapshot { saveDescription(snapshot); return }
        var snapshot = options; snapshot.revision = useHead ? "HEAD" : chooser.revision; snapshot.allowNameConflict = allowNameConflict
        snapshot.name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldSwitch = !isTag && canSwitch && switchAfterCreation, shouldPush = isTag && pushAfterCreation, switchPreference = switchAfterCreation
        if allowNameConflict, let captured = conflictSnapshot { snapshot = captured.0; snapshot.allowNameConflict = true; shouldSwitch = captured.1; shouldPush = captured.2; switchPreference = captured.3 }
        else if hasPendingNameConflict { return }
        conflictSnapshot = nil; nameConflict = false
        if !isTag { preferences.set(switchPreference, forKey: "NewBranchSwitchTo") }
        else { preferences.set(shouldPush, forKey: "PushTag") }
        if let createdOptions {
            snapshot = createdOptions; shouldSwitch = createdShouldSwitch; shouldPush = createdShouldPush
        }
        let routedSwitch = shouldSwitch ? onSwitch : nil
        busy = true; error = nil; let token = OperationCancellation(); creationToken = token; Self.activeCreations += 1
        Task {
            defer { Self.activeCreations -= 1; if creationToken === token { creationToken = nil; busy = false }; finishCloseWhenReady(); withExtendedLifetime(access) {} }
            do {
                try checkAccess()
                if createdOptions == nil {
                    let output = try await chooser.repository.createReference(snapshot, writeDescription: false, cancellation: token)
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                    createdOutput = output; createdShouldSwitch = shouldSwitch; createdShouldPush = shouldPush
                    // Remember the mutation before any later suspension or phase.
                    // Retrying checkout/description must never create it again.
                    createdOptions = snapshot; createdBranch = snapshot.name
                }
                guard !invalidated, creationToken === token, !token.isCancelled, let created = createdOptions else { return }
                if let routedSwitch {
                    notifyCreated()
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                    await handoffSwitch("refs/heads/" + created.name, using: routedSwitch)
                    guard !invalidated, creationToken === token, !token.isCancelled else { return }
                } else if shouldSwitch {
                    var checkout = CheckoutOptions(); checkout.revision = "refs/heads/" + created.name
                    do { createdOutput += try await chooser.repository.checkout(checkout, cancellation: token) }
                    catch {
                        guard !invalidated, creationToken === token, !token.isCancelled else { return }
                        notifyCreated(); self.error = "Branch \(created.name) was created, but checkout failed. Resolve the working-tree changes and retry checkout, or close this dialog.\n\n" + error.localizedDescription; return
                    }
                }
                guard !invalidated, creationToken === token, !token.isCancelled else { return }
                if !isTag && !created.message.isEmpty {
                    descriptionSnapshot = created
                    do { try checkAccess(); try await chooser.repository.updateBranchDescription(created.name, message: created.message, cancellation: token); descriptionSnapshot = nil }
                    catch {
                        guard !invalidated, creationToken === token, !token.isCancelled else { return }
                        notifyCreated(); self.error = "Branch \(created.name) was created, but its description could not be saved. Retry the description or close this dialog.\n\n" + error.localizedDescription; return
                    }
                }
                notifyCreated(); guard !invalidated else { return }; complete(push: shouldPush ? "refs/tags/" + created.name : nil)
            } catch ReferenceCreationFailure.nameConflict { guard !invalidated, creationToken === token else { return }; conflictSnapshot = (snapshot, shouldSwitch, shouldPush, switchPreference); nameConflict = true }
            catch { if !invalidated, creationToken === token, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func saveDescription(_ snapshot: ReferenceCreationOptions) {
        busy = true; error = nil; let token = OperationCancellation(); creationToken = token; Self.activeCreations += 1
        Task {
            defer { Self.activeCreations -= 1; if creationToken === token { creationToken = nil; busy = false }; finishCloseWhenReady(); withExtendedLifetime(access) {} }
            do {
                try checkAccess(); try await chooser.repository.updateBranchDescription(snapshot.name, message: snapshot.message, cancellation: token)
                guard !invalidated, creationToken === token, !token.isCancelled else { return }
                descriptionSnapshot = nil; notifyCreated(); guard !invalidated else { return }; complete()
            } catch { if !invalidated, creationToken === token, !token.isCancelled { self.error = error.localizedDescription } }
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
            }.padding(8) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox("Base On") {
                VStack(spacing: 6) {
                    BaseRadio(title: "HEAD (\(model.currentBranch.isEmpty ? "detached" : model.currentBranch))", selected: model.useHead) { model.useHead = true }.frame(height: 22)
                    HStack { radio("Branch", target: .branch).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision, accessibilityLabel: "Base branch revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .branch) }).disabled(model.useHead || chooser.options.target != .branch)
                        Button("…") { chooser.browse(.branch) }.accessibilityLabel("Browse references").disabled(model.useHead || chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { radio("Tag", target: .tag).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision, accessibilityLabel: "Base tag revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .tag) }).disabled(model.useHead || chooser.options.target != .tag)
                        Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { radio("Commit", target: .commit).frame(width: 100)
                        VersionRevisionField(text: $chooser.commitRevision, choices: chooser.commitChoices, accessibilityLabel: "Base commit revision", focusRequest: chooser.referenceFocusRequest, onFocus: { chooser.focusReference($0, target: .commit) }).disabled(model.useHead || chooser.options.target != .commit)
                        Button("…") { chooser.browse(.commit) }.accessibilityLabel("Choose commit").disabled(model.useHead || chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox("Options") { HStack {
                TrackingCheckbox(value: $model.options.tracking, enabled: model.remote).frame(width: 115).help("Checked passes --track, unchecked passes --no-track; mixed passes neither (see Help).")
                Toggle("Force", isOn: $model.options.force).help("Force creation of branch/tag, even if one with the same name already exists.")
                if model.isTag {
                    Toggle("Sign", isOn: $model.options.sign).disabled(!model.canSign).help("GPG signs the tag; see the manual for details.")
                    Toggle("Push", isOn: $model.pushAfterCreation)
                } else if model.canSwitch { Toggle("Switch to new branch", isOn: $model.switchAfterCreation) }
                Spacer()
            }.padding(8) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            GroupBox(model.isTag ? "Message" : "Description") { TextEditor(text: $model.options.message).font(.system(.body, design: .monospaced)).frame(minHeight: 75) }.disabled(model.createdBranch != nil || model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation)
            HStack { if model.busy || chooser.busy || chooser.pickerTarget != nil { ProgressView().controlSize(.small) }; Spacer()
                Button(model.retryDescription ? "Retry description" : model.createdBranch == nil ? "OK" : "Retry checkout") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.busy || chooser.busy || chooser.pickerTarget != nil || model.confirmingCancellation || model.options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { TurtleGitHelp.show(.branchTag) }
            }
        }.padding(16)
        .onChange(of: chooser.branchRevision) { _ in model.changedBase() }
        .onChange(of: model.useHead) { _ in model.changedBase() }
        .onChange(of: model.options.name) { _ in model.nameChanged() }
        .alert("Create reference failed", isPresented: Binding(get: { !model.confirmingCancellation && (model.error != nil || chooser.error != nil) }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
        .alert("Branch and tag share a name", isPresented: Binding(get: { model.nameConflict && !model.confirmingCancellation }, set: { model.nameConflict = $0 })) { Button("Continue") { model.create(allowNameConflict: true) }; Button("Abort", role: .cancel) { model.abortNameConflict() } } message: { Text(ReferenceCreationFailure.nameConflict.localizedDescription) }
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
