import AppKit
import Combine
import SwiftUI
import TurtleGitCore

@MainActor final class StatisticsMenuContext: ObservableObject {
    @Published private(set) var available = false
    private weak var model: StatisticsWindowModel?
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
    private var current: StatisticsWindowController? { NSApp.keyWindow?.delegate as? StatisticsWindowController }
    private func refresh() {
        let controller = current
        if model !== controller?.model {
            modelChanges = nil; model = controller?.model
            modelChanges = model?.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
        let enabled = controller.map { $0.model.canExportGraph && $0.window?.attachedSheet == nil } ?? false
        if available != enabled { available = enabled }
    }
    func saveGraphAs() { refresh(); guard available else { return }; current?.saveGraphAs() }
}

struct StatisticsFileCommands: Commands {
    @ObservedObject var context: StatisticsMenuContext
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button { context.saveGraphAs() } label: { CommandLabel(title: "Save Graph As…", icon: .saveAs) }.disabled(!context.available)
        }
    }
}
