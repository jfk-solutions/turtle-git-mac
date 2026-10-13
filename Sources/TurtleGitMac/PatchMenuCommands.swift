import AppKit
import Combine
import SwiftUI
import TurtleGitCore

/// Keeps shared app menus bound to the key diff window, including native panels.
/// Repository, Settings and other editors must not act on a background diff.
@MainActor final class PatchMenuContext: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var partialAvailable = false
    @Published private(set) var stageLinesAvailable = false
    @Published private(set) var stageHunksAvailable = false
    @Published private(set) var unstageLinesAvailable = false
    @Published private(set) var unstageHunksAvailable = false
    private let keyWindow: () -> NSWindow?
    private weak var observedModel: PatchWindowModel?
    private var modelChanges: AnyCancellable?
    private var windowChanges: [AnyCancellable] = []
    init(keyWindow: (() -> NSWindow?)? = nil) {
        self.keyWindow = keyWindow ?? { NSApp.keyWindow }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
            windowChanges.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private var current: PatchWindowController? {
        var candidate = keyWindow(), seen = Set<ObjectIdentifier>()
        while let window = candidate, seen.insert(ObjectIdentifier(window)).inserted {
            if let owner = window.delegate as? PatchWindowController { return owner }
            candidate = window.sheetParent ?? window.parent
        }
        return nil
    }
    private func refresh() {
        let controller = current
        if observedModel !== controller?.model {
            modelChanges = nil
            observedModel = controller?.model
            modelChanges = observedModel?.objectWillChange.sink { [weak self] _ in
                // Published sends before mutation; evaluate availability after it.
                Task { @MainActor in self?.refresh() }
            }
        }
        let enabled = controller.map { !$0.model.retired && !$0.model.busy && !$0.model.confirmingQuit && $0.model.error == nil && $0.window?.attachedSheet == nil } ?? false
        if available != enabled { available = enabled }
        let partial = controller.map { !$0.model.retired && !$0.model.readOnly } ?? false
        if partialAvailable != partial { partialAvailable = partial }
        let model = controller?.model
        let stageLines = enabled && partial && model?.staged == false && model?.canApplyLines == true
        let stageHunks = enabled && partial && model?.staged == false && model?.canApplyHunks == true
        let unstageLines = enabled && partial && model?.staged == true && model?.canApplyLines == true
        let unstageHunks = enabled && partial && model?.staged == true && model?.canApplyHunks == true
        if stageLinesAvailable != stageLines { stageLinesAvailable = stageLines }
        if stageHunksAvailable != stageHunks { stageHunksAvailable = stageHunks }
        if unstageLinesAvailable != unstageLines { unstageLinesAvailable = unstageLines }
        if unstageHunksAvailable != unstageHunks { unstageHunksAvailable = unstageHunks }
    }
    func apply(staged: Bool, entireHunks: Bool) {
        refresh()
        guard available, partialAvailable, let model = current?.model, model.staged == staged else { return }
        model.apply(entireHunks: entireHunks)
    }
    func copyPatch() { refresh(); guard available else { return }; current?.model.copyPatch() }
    func saveAs() { refresh(); guard available else { return }; current?.model.saveAs() }
    func printDiff() { refresh(); guard available else { return }; current?.model.printDiff() }
    func pageSetup() { refresh(); guard available else { return }; current?.model.pageSetup() }
}

struct PatchFileCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    var body: some Commands {
        if context.partialAvailable {
            CommandMenu("Staging") {
                Button { context.apply(staged: false, entireHunks: false) } label: { CommandLabel(title: "Stage selected lines", icon: .add) }.disabled(!context.stageLinesAvailable)
                Button { context.apply(staged: false, entireHunks: true) } label: { CommandLabel(title: "Stage selected hunks", icon: .add) }.disabled(!context.stageHunksAvailable)
            }
            CommandMenu("Unstaging") {
                Button { context.apply(staged: true, entireHunks: false) } label: { CommandLabel(title: "Unstage selected lines", icon: .revert) }.disabled(!context.unstageLinesAvailable)
                Button { context.apply(staged: true, entireHunks: true) } label: { CommandLabel(title: "Unstage selected hunks", icon: .revert) }.disabled(!context.unstageHunksAvailable)
            }
        }
        CommandGroup(after: .saveItem) {
            Button { context.copyPatch() } label: { CommandLabel(title: "Copy Patch", icon: .copy) }.disabled(!context.available)
            Button("Save As…") { context.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!context.available)
        }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { context.pageSetup() }.disabled(!context.available)
            Button("Print…") { context.printDiff() }
                .keyboardShortcut("p").disabled(!context.available)
        }
    }
}
