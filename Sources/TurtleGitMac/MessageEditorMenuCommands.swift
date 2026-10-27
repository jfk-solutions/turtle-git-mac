// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI

/// Main-menu discovery follows the focused message editor. Every action resolves
/// that editor again; a menu opened for one dialog cannot edit a background one.
@MainActor final class MessageEditorMenuContext: ObservableObject {
    @Published private(set) var present = false
    @Published private(set) var lineCommands = Set<MessageEditorLineCommand>()
    @Published private(set) var zoomActions = Set<MessageEditorZoomAction>()
    private let keyWindow: () -> NSWindow?
    private var changes: [AnyCancellable] = []

    init(keyWindow: (() -> NSWindow?)? = nil) {
        self.keyWindow = keyWindow ?? { NSApp.keyWindow }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.didUpdateNotification,
                     NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
            changes.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private var current: ProjectMessageTextView? {
        guard let window = keyWindow(), window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              let editor = window.firstResponder as? ProjectMessageTextView,
              editor.window === window else { return nil }
        return editor
    }
    func refresh() {
        let editor = current
        let visible = editor != nil
        let lines = Set(MessageEditorLineCommand.allCases.filter { editor?.canPerformMessageLineCommand($0) == true })
        let zoom = Set(MessageEditorZoomAction.allCases.filter { editor?.canPerformMessageZoom($0) == true })
        if present != visible { present = visible }
        if lineCommands != lines { lineCommands = lines }
        if zoomActions != zoom { zoomActions = zoom }
    }
    func perform(_ command: MessageEditorLineCommand) {
        guard let editor = current, editor.canPerformMessageLineCommand(command) else { refresh(); return }
        _ = editor.performMessageLineCommand(command)
        refresh()
    }
    func zoom(_ action: MessageEditorZoomAction) {
        guard let editor = current, editor.canPerformMessageZoom(action) else { refresh(); return }
        editor.performMessageZoom(action)
        refresh()
    }
}

struct MessageEditorCommands: Commands {
    @ObservedObject var context: MessageEditorMenuContext
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            if context.present {
                Menu("Message Lines") {
                    ForEach(MessageEditorLineCommand.allCases) { command in
                        Button { context.perform(command) } label: {
                            CommandLabel(title: command.title, icon: command.icon)
                        }
                        .keyboardShortcut(KeyEquivalent(command.key), modifiers: [.command, .option])
                        .disabled(!context.lineCommands.contains(command))
                    }
                }
                Menu("Message Text Size") {
                    Button { context.zoom(.zoomIn) } label: { CommandLabel(title: "Zoom In", icon: .imageZoomIn) }
                        .keyboardShortcut("+", modifiers: .command).disabled(!context.zoomActions.contains(.zoomIn))
                    Button { context.zoom(.zoomOut) } label: { CommandLabel(title: "Zoom Out", icon: .imageZoomOut) }
                        .keyboardShortcut("-", modifiers: .command).disabled(!context.zoomActions.contains(.zoomOut))
                    Button { context.zoom(.actualSize) } label: { CommandLabel(title: "Actual Size", icon: .imageOriginal) }
                        .keyboardShortcut("0", modifiers: .command).disabled(!context.zoomActions.contains(.actualSize))
                }
            }
        }
    }
}
