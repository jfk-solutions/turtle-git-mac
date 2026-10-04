import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ResetWindowController: NSWindowController, NSWindowDelegate {
    let model: ResetWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String? = nil) {
        model = ResetWindowModel(repository: repository, access: access, revision: revision)
        let size = NSSize(width: 690, height: 405)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Reset – TurtleGit"
        window.contentMinSize = size; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ResetDialog(model: model, chooser: model.chooser))
        super.init(window: window); window.delegate = self
        window.setFrameAutosaveName("ResetDialog"); window.setContentSize(size); window.center()
        model.close = { [weak window] in window?.close() }
        model.confirmHard = { [weak self] plan in
            guard let self, let window = self.window else { return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Discard all local changes?"
            alert.informativeText = "Hard reset replaces the index and tracked working files with \(plan.revision). Untracked files that obstruct checkout can also be removed."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reset")
            alert.beginSheetModal(for: window) { [weak model] response in if response == .alertSecondButtonReturn { model?.apply(plan) } }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.chooser.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ResetWindowModel: ObservableObject {
    let chooser: SwitchWindowModel
    private let access: RepositoryAccessLease?
    private let initialRevision: String?
    @Published var currentBranch = ""
    @Published var mode = ResetMode.mixed
    @Published var bare = false
    @Published var busy = false
    @Published var error: String?
    var close: () -> Void = {}
    var confirmHard: (ResetPlan) -> Void = { _ in }
    var onReset: (String) -> Void = { _ in }
    var onStatus: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String?) {
        chooser = SwitchWindowModel(repository: repository, access: access); self.access = access; initialRevision = revision
    }
    func load() {
        guard !busy else { return }; busy = true; chooser.load(revision: initialRevision)
        Task {
            defer { busy = false }
            do { currentBranch = try await chooser.repository.branch(); bare = try await chooser.repository.isBare(); if bare { mode = .soft } }
            catch { self.error = error.localizedDescription }
        }
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(chooser.repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func reset() {
        guard !busy, !chooser.busy else { return }; busy = true
        let revision = chooser.revision, mode = mode
        Task {
            do {
                try validateAccess()
                let plan = try await chooser.repository.prepareReset(to: revision, mode: mode)
                busy = false
                if mode == .hard { confirmHard(plan) } else { apply(plan) }
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func apply(_ plan: ResetPlan) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try validateAccess(); let output = try await chooser.repository.reset(plan); onReset(output); close() }
            catch { self.error = error.localizedDescription }
        }
    }
}
private struct ResetDialog: View {
    @ObservedObject var model: ResetWindowModel
    @ObservedObject var chooser: SwitchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Current branch:").frame(width: 110, alignment: .leading); Text(model.currentBranch.isEmpty ? "detached HEAD" : model.currentBranch).textSelection(.enabled); Spacer() }
            GroupBox("Reset active branch") {
                VStack(spacing: 6) {
                    HStack { SwitchRadio(title: "Branch", target: .branch, selection: $chooser.options.target).frame(width: 100)
                        ReferencePopup(references: chooser.branches, selection: $chooser.branchRevision).disabled(chooser.options.target != .branch)
                        Button("…") { chooser.browse(.branch) }.accessibilityLabel("Browse references").disabled(chooser.options.target != .branch)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Tag", target: .tag, selection: $chooser.options.target).frame(width: 100)
                        ReferencePopup(references: chooser.tags, selection: $chooser.tagRevision).disabled(chooser.options.target != .tag); Color.clear.frame(width: 29)
                    }.frame(height: 26)
                    HStack { SwitchRadio(title: "Commit", target: .commit, selection: $chooser.options.target).frame(width: 100)
                        TextField("Commit", text: $chooser.commitRevision).disabled(chooser.options.target != .commit)
                        Button("…") { chooser.browse(.commit) }.accessibilityLabel("Choose commit").disabled(chooser.options.target != .commit)
                    }.frame(height: 26)
                }.padding(8)
            }
            GroupBox("Reset Type") {
                VStack(alignment: .leading, spacing: 7) {
                    ResetRadio(title: "Soft: Leave working tree and index untouched", value: .soft, selection: $model.mode).frame(height: 22)
                    ResetRadio(title: "Mixed: Leave working tree untouched, reset index", value: .mixed, selection: $model.mode).frame(height: 22).disabled(model.bare)
                    ResetRadio(title: "Hard: Reset working tree and index (discard all local changes)", value: .hard, selection: $model.mode).frame(height: 22).disabled(model.bare)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.onStatus() } label: { CommandLabel(title: "Show modified files in working tree", icon: .status).frame(maxWidth: .infinity) }.disabled(model.bare)
            HStack { if model.busy || chooser.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("OK") { model.reset() }.keyboardShortcut(.defaultAction).disabled(chooser.revision.isEmpty)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-reset.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(model.busy || chooser.busy).onAppear { model.load() }
        .sheet(item: $chooser.browser) { target in SwitchReferenceChooser(model: chooser, target: target) }
        .alert("Reset failed", isPresented: Binding(get: { model.error != nil || chooser.error != nil }, set: { if !$0 { model.error = nil; chooser.error = nil } })) { Button("OK") { model.error = nil; chooser.error = nil } } message: { Text(model.error ?? chooser.error ?? "") }
    }
}
private struct ResetRadio: NSViewRepresentable {
    let title: String
    let value: ResetMode
    @Binding var selection: ResetMode
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) { button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled; context.coordinator.select = { selection = value } }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
}
