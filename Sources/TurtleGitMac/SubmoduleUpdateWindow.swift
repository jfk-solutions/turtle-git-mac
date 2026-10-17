import AppKit
import SwiftUI
import TurtleGitCore

private final class SubmoduleUpdateNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96, event.window === self, attachedSheet == nil, event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class SubmoduleUpdateWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleUpdateWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String] = [], preferences: UserDefaults = .standard) {
        model = SubmoduleUpdateWindowModel(repository: repository, access: access, scope: scope, selected: selected, preferences: preferences)
        let size = NSSize(width: 760, height: 500)
        let window = SubmoduleUpdateNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Submodule Update", preferences: preferences)
        window.contentMinSize = NSSize(width: 700, height: 460); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: SubmoduleUpdateDialog(model: model).defaultAppStorage(preferences))
        host.sizingOptions = []; window.contentViewController = host
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 700), host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 460)])
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        model.close = { [weak window] in window?.close() }; window.refresh = { [weak model] in model?.load() }

        model.scopeTitleChanged = { [weak window, weak model] in
            guard let window, let model else { return }
            RepositoryWindowTitles.set(window, repository: repository.root, dialog: model.dialogTitle, preferences: preferences)
        }; model.scopeTitleChanged()
        DialogGeometry.attach(window, identifier: "SubmoduleUpdateDialog", legacyName: "SubmoduleUpdateDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.confirmingQuit && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleUpdateWindowModel: ObservableObject {
    private(set) static var activeReads = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let scope: [String]
    private let requestedSelection: [String]
    private var loaded = false, invalidated = false, submitted = false
    private let preferences: UserDefaults
    private var loadToken: OperationCancellation?
    private var formRevision = UUID()
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var formContext: FormContext { .init(owner: ObjectIdentifier(self), revision: formRevision) }
    var canEdit: Bool { !busy && !confirmingQuit && !invalidated && !submitted }
    private func accepts(_ context: FormContext) -> Bool { canEdit && context == formContext }
    func option(_ key: WritableKeyPath<SubmoduleUpdateOptions,Bool>, context: FormContext) -> Binding<Bool> {
        Binding(get: { self.options[keyPath:key] }, set: { value in
            guard self.accepts(context) else { return }; self.options[keyPath:key] = value
        })
    }
    func wholeProjectBinding(context: FormContext) -> Binding<Bool> {
        Binding(get: { self.wholeProject }, set: { value in
            guard self.accepts(context), self.canChooseScope, self.wholeProject != value else { return }
            self.wholeProject = value; self.scopeChanged()
        })
    }
    func setSelectedPaths(_ selected: Set<GitReferenceName>, context: FormContext) { guard accepts(context) else { return }; setSelectedPaths(selected) }
    func selectAll(context: FormContext) { guard accepts(context) else { return }; selectAll() }
    func apply(context: FormContext) { guard accepts(context) else { return }; apply() }
    func cancel() { guard !confirmingQuit, !submitted, !invalidated else { return }; invalidate(); close() }
    var scopeTitleChanged: () -> Void = {}
    var dialogTitle: String {
        let prefixes = scope.filter { !$0.isEmpty && $0 != "." }
        guard !wholeProject, let first = prefixes.first else { return "Submodule Update" }
        return "Submodule Update – " + first + (prefixes.count > 1 ? ", …" : "")
    }
    @Published var options = SubmoduleUpdateOptions()
    @Published var paths: [String] = []
    @Published var selection = Set<GitReferenceName>()
    @Published var wholeProject = false
    @Published var busy = false { didSet { if busy != oldValue { formRevision = UUID() } } }
    @Published var confirmingQuit = false { didSet { if confirmingQuit != oldValue { formRevision = UUID() } } }
    @Published var error: String?
    var close: () -> Void = {}
    var onSubmit: (([String], SubmoduleUpdateOptions) -> Void)?
    private var key: String { "SubmoduleUpdate." + repository.root.path }
    var canApply: Bool { !busy && !confirmingQuit && !invalidated && !submitted && error == nil && !selection.isEmpty && onSubmit != nil }
    var canChooseScope: Bool { scope.contains { !$0.isEmpty && $0 != "." } }
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], selected: [String], preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.scope = scope; requestedSelection = selected; self.preferences = preferences
        wholeProject = preferences.bool(forKey: key + ".wholeProject")
        if let data = preferences.data(forKey: key + ".options"), let saved = try? JSONDecoder().decode(SubmoduleUpdateOptions.self, from: data) { options = saved }
    }
    func invalidate() { invalidated = true; formRevision = UUID(); loadToken?.cancel() }
    func load() {
        guard !busy, !confirmingQuit, !invalidated, !submitted else { return }; busy = true; error = nil
        let token = OperationCancellation(); loadToken = token; Self.activeReads += 1
        let requestedScope = wholeProject ? [] : scope
        Task {
            defer {
                Self.activeReads -= 1
                if loadToken === token { loadToken = nil; busy = false }
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let next = try await repository.submoduleUpdatePaths(scope: requestedScope, cancellation: token)
                guard !invalidated, !token.isCancelled else { return }
                let saved = requestedSelection.isEmpty ? preferences.stringArray(forKey: key + ".selection") ?? [] : requestedSelection
                let checks = loaded ? selection : Set((saved.isEmpty ? next : saved).map { GitReferenceName($0) })
                paths = next; selection = checks.intersection(next.map { GitReferenceName($0) }); loaded = true
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func scopeChanged() { guard !busy, !confirmingQuit, !invalidated, !submitted else { return }; preferences.set(wholeProject, forKey: key + ".wholeProject"); loaded = false; scopeTitleChanged(); load() }
    func setSelectedPaths(_ selected: Set<GitReferenceName>) {
        guard !busy, !confirmingQuit, !invalidated, !submitted else { return }; selection = selected.intersection(paths.map { GitReferenceName($0) })
    }
    func selectAll() { guard !busy, !confirmingQuit, !invalidated, !submitted else { return }; selection = selection.isEmpty ? Set(paths.map { GitReferenceName($0) }) : [] }
    func apply() {
        guard canApply, let onSubmit else { return }
        let selected = paths.filter { selection.contains(GitReferenceName($0)) }, snapshot = options
        guard !selected.isEmpty else { return }; submitted = true
        preferences.set(selected, forKey: key + ".selection")
        if let data = try? JSONEncoder().encode(snapshot) { preferences.set(data, forKey: key + ".options") }
        onSubmit(selected, snapshot); close()
    }

}

private struct SubmoduleUpdateDialog: View {
    @ObservedObject var model: SubmoduleUpdateWindowModel
    var body: some View {
        let context = model.formContext
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                Text("Path:").frame(width: 55, alignment: .leading).padding(.top, 8)
                SubmoduleUpdatePathList(model:model).disabled(!model.canEdit)
            }
            GroupBox("Submodule Update Options") {
                HStack(alignment: .top, spacing: 25) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Initialize submodules (--init)", isOn: model.option(\.initialize, context: context))
                        Toggle("Recursive", isOn: model.option(\.recursive, context: context))
                        Toggle("Force", isOn: model.option(\.force, context: context))
                        Toggle("Remote tracking branch", isOn: model.option(\.remote, context: context))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("No fetch", isOn: model.option(\.noFetch, context: context))
                        Toggle("Merge", isOn: model.option(\.merge, context: context))
                        Toggle("Rebase", isOn: model.option(\.rebase, context: context))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8)
            }.disabled(!model.canEdit)
            if let error = model.error {
                HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Retry") { model.load() }.disabled(!model.canEdit) }
            }
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    SelectionAllCheckbox(checked: model.selection.count, total: model.paths.count, checkedCount: { model.selection.count }) { _ in model.selectAll(context: context) }.frame(width: 190, height: 22)
                    Toggle("Whole Project", isOn: model.wholeProjectBinding(context: context)).disabled(!model.canChooseScope)
                }.disabled(!model.canEdit)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("OK") { model.apply(context: context) }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.confirmingQuit)
                Button { TurtleGitHelp.show(.submodules) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).onAppear { model.load() }
    }
}
