import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleConflictWindowModel
    var onClosed: () -> Void = {}
    private(set) var sheets: ConflictReviewSheets!
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        model = SubmoduleConflictWindowModel(repository: repository, access: access, path: path, preferences: preferences)
        let size = NSSize(width: 780, height: 570)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule conflict – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleConflictDialog(model: model, operation: model.operation))
        window.contentMinSize = NSSize(width: 690, height: 570)
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center(); sheets = ConflictReviewSheets(window: window, operation: model.operation)
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.confirmChoice = { [weak self] in await self?.sheets.ask("Are you sure you want to mark the conflicted file(s) as resolved?", buttons: ["Yes", "No"]) == .alertFirstButtonReturn }
        model.confirmDeletion = { [weak self] request in
            await self?.sheets.ask("Delete submodule folder?", message: request.gitError + "\n\nMove “\(request.path)” to Trash to resolve its deletion?", buttons: ["Delete", "Abort"]) == .alertFirstButtonReturn
        }
        model.operation.confirmCancellation = { [weak self] reply in Task { reply(await self?.sheets.ask("The process is still running.", message: "Are you sure to abort?", buttons: ["Yes", "No"]) == .alertFirstButtonReturn) } }
        DialogGeometry.attach(window, identifier: "TurtleGit.SubmoduleConflict", legacyName: "TurtleGit.SubmoduleConflict")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.abort(); return false }; return model.operation.canClose && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { guard model.operation.active else { return }; model.invalidate(); sheets.retire(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SubmoduleConflictWindowModel: ObservableObject {
    let repository: GitRepository
    let path: String
    let operation: ConflictReviewOperation
    var busy: Bool { operation.busy }
    var error: String? { get { operation.error } set { operation.error = newValue } }
    @Published var details: SubmoduleConflictDetails?
    private var reloadQueued = false, closeAfterRead = false
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onLog: (GitRepository, String) -> Void = { _, _ in }
    var onReset: (GitRepository, String, @escaping () -> Void) -> Void = { _, _, _ in }
    var confirmChoice: () async -> Bool = { false }
    var confirmDeletion: @Sendable (SubmoduleDeletionRequest) async -> Bool = { request in await ConflictPrompts.deleteSubmodule(request) }
    var readDetails: ((OperationCancellation) async throws -> SubmoduleConflictDetails)?
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        self.repository = repository; self.path = path; operation = ConflictReviewOperation(repository: repository, access: access, preferences: preferences)
        operation.onIdle = { [weak self] in
            guard let self, self.operation.active, self.operation.canClose else { return }
            // Upstream's chooser explicitly closes progress on success, independent
            // of the general preference, then ends this chooser.
            if self.closeAfterRead || self.operation.success { self.closeAfterRead = false; self.close() }
            else if self.reloadQueued, !self.operation.showingProgress { self.reloadQueued = false; self.load() }
        }
    }
    func invalidate() { reloadQueued = false; operation.invalidate() }
    func abort() { guard operation.active else { return }; if busy { if !operation.showingProgress { closeAfterRead = true }; operation.cancel() } else if operation.canClose { close() } }
    func back() { guard operation.canClose else { return }; operation.back(); details = nil; load() }
    func load() {
        guard operation.active else { return }
        guard operation.canInteract else { reloadQueued = true; return }; reloadQueued = false
        let repository = self.repository.capturingDiffBackend(preferences: operation.preferences)
        let identityOptions = ConflictIdentityOptions(defaults: operation.preferences)
        let token = operation.begin()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                try operation.checkAccess(); let value: SubmoduleConflictDetails
                if let readDetails { value = try await readDetails(token) } else { value = try await repository.submoduleConflictDetails(path: path, identityOptions: identityOptions, cancellation: token) }
                try token.check(); guard operation.live(token) else { return }; details = value
            } catch { operation.fail(error, token: token) }
        }
    }
    func log(_ side: SubmoduleConflictSide) {
        guard operation.canInteract, side.canShowLog, let revision = side.revision, let original = details, let checkout = original.checkout,
              [original.base, original.mine, original.theirs].contains(where: { $0.stage == side.stage && $0.revision == revision && $0.canShowLog }) else { return }
        let repository = self.repository.capturingDiffBackend(preferences: operation.preferences)
        let identityOptions = ConflictIdentityOptions(defaults: operation.preferences)
        let token = operation.begin()
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                try operation.checkAccess(); let current = try await repository.submoduleConflictDetails(path: path, identityOptions: identityOptions, cancellation: token)
                guard current.entry == original.entry, current.checkout == checkout,
                      [current.base, current.mine, current.theirs].contains(where: { $0.stage == side.stage && $0.revision == revision && $0.canShowLog }) else { throw ResolveFailure.stale }
                let child = try await repository.submoduleWorkingRepository(path:path,cancellation:token)
                guard child.root == checkout else { throw ResolveFailure.stale }
                try token.check(); guard operation.live(token) else { return }; onLog(child, revision)
            } catch { operation.fail(error, token: token) }
        }
    }
    func choose(_ side: SubmoduleConflictSide) {
        guard operation.canInteract, let choice = side.choice, let details,
              [details.mine, details.theirs].contains(where: { $0.stage == side.stage && $0.revision == side.revision }) else { return }
        let generation = operation.generation
        Task {
            let accepted = await confirmChoice()
            guard operation.active, operation.generation == generation else { return }
            if accepted { apply(details.entry, choice: choice) } else { operation.onIdle() }
        }
    }
    func apply(_ entry: ConflictEntry, choice: ResolveChoice) {
        guard operation.active, !busy, !operation.hasQuestion, !operation.hasChild, !operation.confirmingCancellation else { return }
        let token = operation.begin(progress: true)
        Task {
            defer { operation.finish(token); withExtendedLifetime(operation.access) {} }
            do {
                let text = try await operation.stream(token) { [self] emit in
                    try await repository.resolveConflicts([entry], using: choice, confirmSubmoduleDeletion: confirmDeletion, cancellation: token, onOutput: emit)
                }
                guard operation.live(token) else { return }; operation.complete(token); onChanged(text)
            } catch ResolveFailure.submoduleCheckout {
                guard operation.live(token), !token.isCancelled else { return }
                do {
                    let (root, revision) = try await repository.submoduleResetTarget(entry, using: choice, cancellation: token)
                    try token.check(); guard operation.live(token) else { return }
                    let generation = operation.generation; operation.hasChild = true
                    onReset(GitRepository(root: root, executable: repository.executable), revision) { [weak self] in
                        guard let self, self.operation.active, self.operation.generation == generation, self.operation.hasChild, !self.busy else { return }
                        self.operation.hasChild = false; self.apply(entry, choice: choice)
                    }
                } catch { operation.fail(error, token: token) }
            } catch {
                guard operation.live(token) else { return }; operation.fail(error, token: token); onChanged(operation.output)
            }
        }
    }
    func dismissReset() { guard operation.active, operation.hasChild, !busy else { return }; operation.hasChild = false; back() }
}
private struct SubmoduleConflictDialog: View {
    @ObservedObject var model: SubmoduleConflictWindowModel
    @ObservedObject var operation: ConflictReviewOperation
    func tint(_ type: SubmoduleChangeType) -> Color {
        switch type {
        case .fastForward: return Color(red: 211/255, green: 249/255, blue: 154/255)
        case .rewind: return Color(red: 249/255, green: 199/255, blue: 229/255)
        case .newerTime: return Color(red: 176/255, green: 223/255, blue: 244/255)
        case .olderTime: return Color(red: 244/255, green: 207/255, blue: 159/255)
        default: return Color(red: 222/255, green: 222/255, blue: 222/255)
        }
    }
    func section(_ side: SubmoduleConflictSide, base: Bool = false) -> some View {
        GroupBox(side.title) {
            VStack(alignment: .leading, spacing: 9) {
                if !base {
                    HStack {
                        Text("Type:").frame(width: 65, alignment: .leading)
                        Text(side.change.rawValue).foregroundStyle(side.change == .identical ? Color.primary : .black)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(side.change == .identical ? Color.clear : tint(side.change)).cornerRadius(3)
                        Spacer()
                        Button("Use this") { model.choose(side) }.frame(width: 115).accessibilityLabel("Use \(side.title)")
                    }
                }
                HStack {
                    Text("Revision:").frame(width: 65, alignment: .leading)
                    Text(side.revision ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.log(side) } label: { CommandLabel(title: "Show log", icon: .log) }.frame(width: 115).disabled(!side.canShowLog).accessibilityLabel("Show log for \(side.title)")
                }
                HStack(alignment: .top) {
                    Text("Subject:").frame(width: 65, alignment: .leading)
                    Text(side.subject).foregroundStyle(side.available ? Color.primary : Color.red).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: base ? 28 : 42, alignment: .topLeading)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(!operation.canInteract)
    }
    var body: some View {
        Group {
        if operation.showingProgress { ConflictReviewProgressView(operation: operation, back: model.back) } else {
        VStack(spacing: 12) {
            HStack {
                Text("Submodule \"\(model.path)\"").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { TurtleGitHelp.show(.resolve) } label: { CommandLabel(title: "Help", icon: .help) }
            }
            if let details = model.details { section(details.base, base: true); section(details.mine); section(details.theirs) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Spacer(minLength: 0)
            if model.busy { HStack { ProgressView().controlSize(.small); Text("Reading conflict metadata…"); Spacer(); Button("Cancel") { model.abort() } } }
        }.padding(14)
        }
        }.onAppear { model.load() }
        .background(Button("") { model.abort() }.keyboardShortcut(.cancelAction).hidden())
        .alert("Could not resolve submodule conflict", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
