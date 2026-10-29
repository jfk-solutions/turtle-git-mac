import AppKit
import Combine
import SwiftUI
import TurtleGitCore

/// Keeps shared app menus bound to the key diff window, including native panels.
/// Repository, Settings and other editors must not act on a background diff.
@MainActor final class PatchMenuContext: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var darkMode = false
    @Published private(set) var caretCommands=Set<PatchCaretCommand>()
    @Published private(set) var selectionCommands=Set<PatchSelectionCommand>()
    @Published private(set) var navigationCommands=Set<PatchNavigationCommand>()
    @Published private(set) var caretOvertype=false
    @Published private(set) var lineCommands = Set<PatchLineCommand>()
    @Published private(set) var columnSelectionAvailable = false
    @Published private(set) var documentAvailable = false
    @Published private(set) var documentVisible = false
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
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification, NSTextView.didChangeSelectionNotification] {
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
        let dark = controller?.model.darkMode ?? false
        if darkMode != dark { darkMode = dark }
        let enabled = controller.map { !$0.model.retired && !$0.model.busy && !$0.model.confirmingQuit && $0.model.error == nil && $0.window?.attachedSheet == nil && NSApp.modalWindow == nil } ?? false
        if available != enabled { available = enabled }
        let text = controller?.window?.firstResponder as? PatchTextView.PatchText
        let navigation=Set(PatchNavigationCommand.allCases.filter{enabled && text?.canPerformNavigationCommand($0)==true})
        if navigationCommands != navigation {navigationCommands=navigation}
        let selection=Set(PatchSelectionCommand.allCases.filter{enabled && text?.canPerformSelectionCommand($0)==true})
        if selectionCommands != selection {selectionCommands=selection}
        let caret=Set(PatchCaretCommand.allCases.filter{enabled && text?.canPerformCaretCommand($0)==true})
        if caretCommands != caret {caretCommands=caret}
        let overtype=text?.caretOvertype ?? false
        if caretOvertype != overtype {caretOvertype=overtype}
        let commands = Set(PatchLineCommand.allCases.filter { enabled && text?.canPerformLineCommand($0) == true })
        if lineCommands != commands { lineCommands = commands }
        let columns = enabled && text?.columnSelection?.available == true
        if columnSelectionAvailable != columns { columnSelectionAvailable = columns }
        let visible = controller?.documentSession.enabled == true
        if documentVisible != visible { documentVisible = visible }
        let document = enabled && visible
        if documentAvailable != document { documentAvailable = document }
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
    func extendColumnSelection(_ direction: PatchColumnDirection) {
        refresh()
        guard columnSelectionAvailable, let controller = current,
              let text = controller.window?.firstResponder as? PatchTextView.PatchText,
              text.coordinator?.model === controller.model else { return }
        _ = text.columnSelection?.extendRectangle(direction: direction)
        refresh()
    }
    func performNavigationCommand(_ command:PatchNavigationCommand) {
        refresh()
        guard navigationCommands.contains(command),let controller=current,
              let text=controller.window?.firstResponder as? PatchTextView.PatchText,text.coordinator?.model === controller.model else{return}
        _ = text.performNavigationCommand(command);refresh()
    }
    func performSelectionCommand(_ command:PatchSelectionCommand) {
        refresh()
        guard selectionCommands.contains(command),let controller=current,
              let text=controller.window?.firstResponder as? PatchTextView.PatchText,text.coordinator?.model === controller.model else{return}
        _ = text.performSelectionCommand(command);refresh()
    }
    func performCaretCommand(_ command:PatchCaretCommand) {
        refresh()
        guard caretCommands.contains(command),let controller=current,
              let text=controller.window?.firstResponder as? PatchTextView.PatchText,text.coordinator?.model === controller.model else{return}
        _ = text.performCaretCommand(command);refresh()
    }
    func performLineCommand(_ command: PatchLineCommand) {
        refresh()
        guard lineCommands.contains(command), let controller = current,
              let text = controller.window?.firstResponder as? PatchTextView.PatchText,
              text.coordinator?.model === controller.model else { return }
        _ = text.performLineCommand(command)
        refresh()
    }
    func apply(staged: Bool, entireHunks: Bool) {
        refresh()
        guard available, partialAvailable, let model = current?.model, model.staged == staged else { return }
        model.apply(entireHunks: entireHunks)
    }
    func setDarkMode(_ dark: Bool) { refresh(); guard available else { return }; current?.setDarkMode(dark); refresh() }
    func copyPatch() { refresh(); guard available else { return }; current?.model.copyPatch() }
    func saveDocument() { refresh(); guard documentAvailable else { return }; current?.documentSession.saveDocument() }
    func openDocument() { refresh(); guard documentAvailable else { return }; current?.documentSession.openDocument() }
    func applyPatch() { refresh(); guard documentAvailable else { return }; current?.documentSession.applyPatch() }
    func showSettings() { refresh(); guard documentAvailable else { return }; current?.documentSession.showSettings() }
    func saveAs() { refresh(); guard available else { return }; current?.model.saveAs() }
    func printDiff() { refresh(); guard available else { return }; current?.model.printDiff() }
    func pageSetup() { refresh(); guard available else { return }; current?.model.pageSetup() }
}

struct PatchFileCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    var body: some Commands {
        PatchLineEditingCommands(context: context)
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
            if context.documentVisible { Button { context.saveDocument() } label: { CommandLabel(title: "Save", icon: .mergeSave) }.keyboardShortcut("s").disabled(!context.documentAvailable) }
            Button { context.copyPatch() } label: { CommandLabel(title: "Copy Patch", icon: .copy) }.disabled(!context.available)
            Button("Save As…") { context.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!context.available)
            Toggle("Dark Mode", isOn: Binding(get: { context.darkMode }, set: { context.setDarkMode($0) })).disabled(!context.available)
            if context.documentVisible {
                Divider()
                Button { context.applyPatch() } label: { CommandLabel(title: "Apply Patch…", icon: .patch) }.disabled(!context.documentAvailable)
                    .help("Review the saved patch file; save document edits first.")
                Button { context.showSettings() } label: { CommandLabel(title: "Unified Diff Settings…", icon: .settingsUnifiedDiff) }.disabled(!context.documentAvailable)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { context.pageSetup() }.disabled(!context.available)
            Button("Print…") { context.printDiff() }
                .keyboardShortcut("p").disabled(!context.available)
        }
    }
}
