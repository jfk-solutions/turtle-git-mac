import AppKit
import SwiftUI
import TurtleGitCore

private final class SubmoduleDiffNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class SubmoduleDiffWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleDiffWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String? = nil) {
        model = SubmoduleDiffWindowModel(repository: repository, access: access, path: path, from: from, to: to)
        let size = NSSize(width: 900, height: 320)
        let window = SubmoduleDiffNativeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Submodule Diff – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 320)
        window.contentViewController = NSHostingController(rootView: SubmoduleDiffDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        window.refresh = { [weak model] in model?.load() }

        DialogGeometry.attach(window, identifier: "SubmoduleDiffDialog", legacyName: "SubmoduleDiffDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class SubmoduleDiffWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let path: String
    let from: String
    let to: String?
    @Published var details: SubmoduleComparison?
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    var onLog: (GitRepository, String) -> Void = { _, _ in }
    var onStatus: (GitRepository) -> Void = { _ in }
    var onCompare: (GitRepository, ComparisonRevision, ComparisonRevision) -> Void = { _, _, _ in }
    var onUpdate: (@escaping () -> Void) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, from: String, to: String?) { self.repository = repository; self.access = access; self.path = path; self.from = from; self.to = to }
    func load() {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task { defer { busy = false }; do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            details = try await repository.submoduleComparison(path: path, from: from, to: to)
        } catch { self.error = error.localizedDescription } }
    }
    func log(_ side: SubmoduleComparisonSide) {
        guard !busy, !confirmingQuit, side.canShowLog, let hash = side.revision, let root = details?.checkout else { return }
        onLog(GitRepository(root: root, executable: repository.executable), hash)
    }
    func compare(workingTree: Bool = false) {
        guard !busy, !confirmingQuit, let details, details.from.available, details.to.available, let root = details.checkout else { return }
        let child = GitRepository(root: root, executable: repository.executable)
        if details.change == .identical { onStatus(child); return }
        let old = details.from.revision.map(ComparisonRevision.revision) ?? .emptyTree
        let new: ComparisonRevision = workingTree || (details.dirty && details.change == .unknown) ? .workingTree : details.to.revision.map(ComparisonRevision.revision) ?? .emptyTree
        onCompare(child, old, new)
    }
    func update() { guard !busy, !confirmingQuit else { return }; onUpdate { [weak self] in self?.load() } }
}
private struct SubmoduleDiffDialog: View {
    @ObservedObject var model: SubmoduleDiffWindowModel
    private func tint(_ change: SubmoduleChangeType) -> Color {
        switch change {
        case .fastForward: return Color(red: 211/255, green: 249/255, blue: 154/255)
        case .rewind: return Color(red: 249/255, green: 199/255, blue: 229/255)
        case .newerTime: return Color(red: 176/255, green: 223/255, blue: 244/255)
        case .olderTime: return Color(red: 244/255, green: 207/255, blue: 159/255)
        default: return Color(red: 222/255, green: 222/255, blue: 222/255)
        }
    }
    private func section(_ side: SubmoduleComparisonSide, details: SubmoduleComparison, to: Bool) -> some View {
        GroupBox(to ? "To" + (details.toWorkingTree ? " (Working tree)" : "") : "From") {
            VStack(alignment: .leading, spacing: 9) {
                if to {
                    HStack {
                        Text("Type:").frame(width: 65, alignment: .leading)
                        Text(details.change.rawValue).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(details.change == .identical ? Color.primary : .black)
                            .background(details.change == .identical ? Color.clear : tint(details.change)).cornerRadius(3)
                        Spacer()
                        if details.toWorkingTree || !details.from.available || !details.to.available { Button { model.update() } label: { CommandLabel(title: "Update", icon: .fetch) } }
                        HStack(spacing: 0) {
                            Button { model.compare() } label: { CommandLabel(title: details.change == .identical ? "Compare" : "Show diff", icon: .compare) }
                            if details.dirty && details.change != .unknown && details.change != .identical {
                                Menu { Button { model.compare() } label: { CommandLabel(title: "Show diff", icon: .compare) }; Button { model.compare(workingTree: true) } label: { CommandLabel(title: "Compare", icon: .compare) } } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).frame(width: 25)
                            }
                        }.disabled(!details.from.available || !details.to.available)
                    }
                }
                HStack {
                    Text("Revision:").frame(width: 65, alignment: .leading)
                    Text((side.revision ?? "") + (to && details.dirty ? "-dirty" : "")).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .foregroundStyle(to && details.dirty ? Color.red : Color.primary)
                        .padding(.horizontal, 3).background(to && details.dirty ? Color.yellow : Color.clear)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.log(side) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(!side.canShowLog).accessibilityLabel(to ? "Show log for To" : "Show log for From")
                }
                HStack(alignment: .top) {
                    Text("Subject:").frame(width: 65, alignment: .leading)
                    Text(side.subject).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                        .foregroundStyle(side.available ? Color.primary : .white).padding(.horizontal, 3).background(side.available ? Color.clear : Color.red)
                }
            }.padding(8)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Submodule \"\(model.path)\"").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let details = model.details { section(details.from, details: details, to: false); section(details.to, details: details, to: true) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(12).disabled(model.busy || model.confirmingQuit).onAppear { model.load() }
        .alert("Submodule comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
