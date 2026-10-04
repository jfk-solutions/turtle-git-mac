import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleConflictWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        model = SubmoduleConflictWindowModel(repository: repository, access: access, path: path)
        let size = NSSize(width: 780, height: 570)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule conflict – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleConflictDialog(model: model))
        window.minSize = NSSize(width: 690, height: 570)
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center(); window.setFrameAutosaveName("TurtleGit.SubmoduleConflict")
        model.close = { [weak window] in window?.close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SubmoduleConflictWindowModel: ObservableObject {
    let repository: GitRepository
    let path: String
    private let access: RepositoryAccessLease?
    @Published var details: SubmoduleConflictDetails?
    @Published var busy = false
    @Published var error: String?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onLog: (GitRepository, String) -> Void = { _, _ in }
    var onReset: (GitRepository, String, @escaping () -> Void) -> Void = { _, _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) { self.repository = repository; self.access = access; self.path = path }
    func load() {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { details = try await repository.submoduleConflictDetails(path: path) } catch { self.error = error.localizedDescription } }
    }
    func log(_ side: SubmoduleConflictSide) {
        guard !busy, side.canShowLog, let revision = side.revision, let checkout = details?.checkout else { return }
        onLog(GitRepository(root: checkout, executable: repository.executable), revision)
    }
    func choose(_ side: SubmoduleConflictSide) {
        guard !busy, let choice = side.choice, let details else { return }
        let alert = NSAlert(); alert.messageText = "Are you sure you want to mark the conflicted file(s) as resolved?"
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(details.entry, choice: choice)
    }
    func apply(_ entry: ConflictEntry, choice: ResolveChoice) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let output = try await repository.resolveConflicts([entry], using: choice, confirmSubmoduleDeletion: { request in await ConflictPrompts.deleteSubmodule(request) })
                onChanged(output); close()
            } catch ResolveFailure.cancelled {
                Task { @MainActor [weak self] in self?.load() }
            } catch ResolveFailure.submoduleCheckout {
                do {
                    let (root, revision) = try await repository.submoduleResetTarget(entry, using: choice)
                    busy = false
                    onReset(GitRepository(root: root, executable: repository.executable), revision) { [weak self] in self?.apply(entry, choice: choice) }
                } catch { self.error = error.localizedDescription }
            } catch { self.error = error.localizedDescription }
        }
    }
}
private struct SubmoduleConflictDialog: View {
    @ObservedObject var model: SubmoduleConflictWindowModel
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
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Submodule \"\(model.path)\"").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-resolve.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
            if let details = model.details { section(details.base, base: true); section(details.mine); section(details.theirs) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Spacer(minLength: 0)
        }.padding(14).disabled(model.busy).onAppear { model.load() }
        .alert("Could not resolve submodule conflict", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
