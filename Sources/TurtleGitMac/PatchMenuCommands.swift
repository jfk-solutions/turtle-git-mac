import AppKit
import Combine
import SwiftUI

/// Keeps shared app menus bound to the key diff window, including native panels.
/// Repository, Settings and other editors must not act on a background diff.
@MainActor final class PatchMenuContext: ObservableObject {
    @Published private(set) var available = false
    private weak var observedModel: PatchWindowModel?
    private var modelChanges: AnyCancellable?
    private var windowChanges: [AnyCancellable] = []
    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowChanges.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private var current: PatchWindowController? { NSApp.keyWindow?.delegate as? PatchWindowController }
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
        let enabled = controller.map { !$0.model.busy && !$0.model.confirmingQuit && $0.window?.attachedSheet == nil } ?? false
        if available != enabled { available = enabled }
    }
    func saveAs() { refresh(); guard available else { return }; current?.model.saveAs() }
    func printDiff() { refresh(); guard available else { return }; current?.model.printDiff() }
    func pageSetup() { refresh(); guard available else { return }; current?.model.pageSetup() }
}

struct PatchFileCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    var body: some Commands {
        CommandGroup(after: .saveItem) {
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
