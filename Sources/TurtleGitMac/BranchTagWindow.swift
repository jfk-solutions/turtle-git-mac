import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BranchTagWindowController: NSWindowController, NSWindowDelegate {
    let model: BranchTagWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool) {
        model = BranchTagWindowModel(repository: repository, access: access, isTag: isTag)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Create \(isTag ? "Tag" : "Branch") – TurtleGit"
        window.minSize = NSSize(width: 650, height: 480); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BranchTagDialog(model: model, chooser: model.chooser))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 660, height: 470)); window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BranchTagWindowModel: ObservableObject {
    let chooser: SwitchWindowModel
    let isTag: Bool
    @Published var options = ReferenceCreationOptions()
    @Published var useHead = true
    @Published var currentBranch = ""
    @Published var switchAfterCreation = false
    @Published var canSwitch = true
    @Published var canSign = false
    @Published var busy = false
    @Published var error: String?
    @Published var nameConflict = false
    @Published var createdBranch: String?
    var close: () -> Void = {}
    var onCreated: (String) -> Void = { _ in }
    var remote: Bool { !isTag && !useHead && chooser.remote }
    private var previousSuggestion = ""
    init(repository: GitRepository, access: RepositoryAccessLease?, isTag: Bool) {
        self.isTag = isTag; chooser = SwitchWindowModel(repository: repository, access: access)
    }
    func load(revision: String?) {
        chooser.load(revision: revision); options = ReferenceCreationOptions(); options.isTag = isTag
        createdBranch = nil; previousSuggestion = ""
        useHead = revision == nil
        switchAfterCreation = UserDefaults.standard.bool(forKey: "NewBranchSwitchTo")
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
    func create(allowNameConflict: Bool = false) {
        guard !busy, !chooser.busy else { return }
        var snapshot = options; snapshot.revision = useHead ? "HEAD" : chooser.revision; snapshot.allowNameConflict = allowNameConflict
        snapshot.name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSwitch = !isTag && canSwitch && switchAfterCreation
        if !isTag { UserDefaults.standard.set(switchAfterCreation, forKey: "NewBranchSwitchTo") }
        busy = true
        Task {
            defer { busy = false }
            do {
                var output = ""
                if createdBranch == nil {
                    output = try await chooser.repository.createReference(snapshot)
                    if shouldSwitch { createdBranch = snapshot.name }
                }
                if shouldSwitch, let createdBranch {
                    var checkout = CheckoutOptions(); checkout.revision = "refs/heads/" + createdBranch
                    do { output += try await chooser.repository.checkout(checkout) }
                    catch { self.error = "Branch \(createdBranch) was created, but checkout failed. Resolve the working-tree changes and retry checkout, or close this dialog.\n\n" + error.localizedDescription; return }
                }
                close(); onCreated(output)
            } catch ReferenceCreationFailure.nameConflict { nameConflict = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct BranchTagDialog: View {
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
                    Toggle("Push", isOn: .constant(false)).disabled(true).help("Tag push options will be available with the native Push dialog port.")
                } else if model.canSwitch { Toggle("Switch to new branch", isOn: $model.switchAfterCreation) }
                Spacer()
            }.padding(8) }.disabled(model.createdBranch != nil)
            GroupBox(model.isTag ? "Message" : "Description") { TextEditor(text: $model.options.message).font(.system(.body, design: .monospaced)).frame(minHeight: 75) }.disabled(model.createdBranch != nil)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                Button(model.createdBranch == nil ? "OK" : "Retry checkout") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-branchtag.html")!) }
            }
        }.padding(16).disabled(model.busy || chooser.busy)
        .onChange(of: chooser.branchRevision) { _ in model.changedBase() }
        .onChange(of: model.useHead) { _ in model.changedBase() }
        .onChange(of: model.options.name) { name in if model.remote, let reference = chooser.references.first(where: { $0.name == chooser.branchRevision }), name != reference.suggestedBranch { model.options.tracking = .noTrack } }
        .alert("Create reference failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
        .alert("Branch and tag share a name", isPresented: $model.nameConflict) { Button("Continue") { model.create(allowNameConflict: true) }; Button("Abort", role: .cancel) {} } message: { Text(ReferenceCreationFailure.nameConflict.localizedDescription) }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
    }
}

private struct BaseRadio: NSViewRepresentable {
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
