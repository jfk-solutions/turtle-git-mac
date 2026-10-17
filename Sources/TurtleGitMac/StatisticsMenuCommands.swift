import AppKit
import Combine
import SwiftUI
import TurtleGitCore

@MainActor final class StatisticsMenuContext: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var targetRevision: UUID?
    private weak var model: StatisticsWindowModel?
    private var modelChanges: AnyCancellable?
    private var windowChanges: [AnyCancellable] = []
    private let keyWindow: () -> NSWindow?
    init(keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow = keyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowChanges.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private var current: StatisticsWindowController? { keyWindow()?.delegate as? StatisticsWindowController }
    func refresh() {
        let controller = current
        let changedOwner = model !== controller?.model
        if changedOwner {
            modelChanges = nil; model = controller?.model
            modelChanges = model?.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
        let revision = controller?.model.formRevision
        if changedOwner || targetRevision != revision { targetRevision = revision }
        let enabled = controller.map { $0.canSaveGraph } ?? false
        if available != enabled { available = enabled }
    }
    func saveGraphAs() { refresh(); guard available else { return }; current?.saveGraphAs() }
    func capturedSaveAction() -> () -> Void {
        let owner = current, revision = owner?.model.formRevision
        return { [weak owner] in
            guard let owner, owner.model.formRevision == revision else { return }
            owner.saveGraphAs()
        }
    }
}

struct StatisticsFileCommands: Commands {
    @ObservedObject var context: StatisticsMenuContext
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(action: context.capturedSaveAction()) { CommandLabel(title: "Save Graph As…", icon: .saveAs) }.disabled(!context.available)
        }
    }
}
