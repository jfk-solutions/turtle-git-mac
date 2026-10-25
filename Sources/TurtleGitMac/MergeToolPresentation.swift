// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import TurtleGitCore

/// Delay the production repository owner until the workspace Scene reads it.
/// Merely installing the App's StateObjects must not restore Finder watches in
/// an unrelated standalone Merge process.
@MainActor final class WorkspaceSceneOwner: ObservableObject {
    private(set) var storedModel: RepositoryModel?
    var makeModel: () -> RepositoryModel = { RepositoryModel() }
    var model: RepositoryModel {
        if let storedModel { return storedModel }
        let model = makeModel(); storedModel = model; return model
    }
}

/// Use the same parser for scene selection and command delivery. A recognized
/// but malformed Merge request still belongs to the tool, so its error exits
/// without briefly opening a repository workspace.
enum TurtleGitLaunchMode: Equatable {
    case workspace, mergeTool, unifiedDiff, actionOnly
    static func resolve(arguments: [String], currentDirectory: String) -> Self {
        do { if try UnifiedDiffInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) != nil { return .unifiedDiff } }
        catch { return .unifiedDiff }
        do { if try MergeToolInvocation.parse(arguments: arguments, currentDirectory: currentDirectory) != nil { return .mergeTool } }
        catch { return .mergeTool }
        if arguments == ["--turtlegit-action-only"] { return .actionOnly }
        do { if try PrimaryCommandInvocation.parse(arguments:arguments,currentDirectory:currentDirectory) != nil { return .actionOnly } }
        catch { return .actionOnly }
        return .workspace
    }
}

/// Only Save All needs an application-level supplement: the existing editor
/// contributions already own Open, Save, Save As, Edit, Navigate, View and Help.
/// Re-resolve the actual key window at invocation rather than retaining a command
/// against a previously focused/retired editor. Settings and sheets cannot save a
/// background document.
@MainActor final class MergeToolMenuContext: ObservableObject {
    @Published private(set) var canSaveAll = false
    @Published private(set) var canClose = false
    private let keyWindow: () -> NSWindow?
    private var notifications: [AnyCancellable] = []
    private var modelChanges: AnyCancellable?
    private weak var observedModel: AnyObject?
    init(keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow = keyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSApplication.didUpdateNotification] {
            notifications.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    private func comparison(in window: NSWindow) -> FileComparisonWindowController? {
        guard let owner = window.delegate as? FileComparisonWindowController,
              owner.window === window, window.attachedSheet == nil,
              owner.editorOpenWorkflow == nil, !owner.preparingReplacement,
              owner.model.contextCommandsAllowed, !owner.model.filtering,
              !owner.model.mergeToolReadOnly, owner.model.dirty else { return nil }
        return owner
    }
    private func conflict(in window: NSWindow) -> TextConflictWindowController? {
        guard let owner = window.delegate as? TextConflictWindowController,
              owner.window === window, window.attachedSheet == nil,
              owner.editorOpenWorkflow == nil, !owner.preparingReplacement,
              owner.model.sourceToolsAllowed, owner.model.sourceMutationsAllowed,
              !owner.model.mergeToolHasPendingWork, !owner.model.confirmingQuit,
              !owner.model.patchResultCompleted, owner.model.hasUnsavedEditorWork else { return nil }
        return owner
    }
    private func closableWindow() -> NSWindow? {
        guard let window = keyWindow(), window.isVisible, window.styleMask.contains(.closable), window.attachedSheet == nil else { return nil }
        if let owner = window.delegate as? FileComparisonWindowController {
            guard owner.window === window, owner.model.copyCommandsAllowed, !owner.model.confirmingQuit,
                  !owner.preparingReplacement, owner.editorOpenWorkflow == nil else { return nil }
        } else if let owner = window.delegate as? TextConflictWindowController {
            guard owner.window === window, !owner.model.retired, !owner.model.confirmingQuit,
                  !owner.preparingReplacement, owner.editorOpenWorkflow == nil else { return nil }
        } else if let owner = window.delegate as? WorkingTreePatchWindowController {
            guard owner.window === window, owner.commandsAvailable, !owner.model.confirmingQuit else { return nil }
        } else if let owner = window.delegate as? MergeOpenWindowController {
            guard owner.window === window else { return nil }
        } else if let owner = window.delegate as? ReviewPatchWorkflow {
            guard owner.window === window else { return nil }
        } else if SettingsPresentationService.shared.controller?.window === window {
            guard SettingsPresentationService.shared.navigation?.canDismiss == true else { return nil }
        } else { return nil }
        return window
    }
    @discardableResult func close() -> Bool {
        guard let window = closableWindow() else { refresh(); return false }
        // Always preserve each controller's dirty-save and in-flight load
        // cancellation policy. A dispatched Close can legitimately be refused
        // or finish asynchronously; it never force-closes its owner.
        window.performClose(nil); refresh(); return true
    }
    func refresh() {
        let window = keyWindow()
        let model: AnyObject?
        let changes: ObservableObjectPublisher?
        if let owner = window?.delegate as? FileComparisonWindowController { model = owner.model; changes = owner.model.objectWillChange }
        else if let owner = window?.delegate as? TextConflictWindowController { model = owner.model; changes = owner.model.objectWillChange }
        else { model = nil; changes = nil }
        if observedModel !== model {
            modelChanges = nil; observedModel = model
            modelChanges = changes?.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
        let next = window.map { ($0.firstResponder as? NSTextView)?.isFieldEditor != true && (comparison(in: $0) != nil || conflict(in: $0) != nil) } ?? false
        if canSaveAll != next { canSaveAll = next }
        let closeAvailable = closableWindow() != nil
        if canClose != closeAvailable { canClose = closeAvailable }
    }
    @discardableResult func saveAll() -> Bool {
        refresh()
        guard let window = keyWindow(), (window.firstResponder as? NSTextView)?.isFieldEditor != true else { return false }
        if let owner = comparison(in: window) { owner.model.saveAll(); return true }
        if let owner = conflict(in: window) { owner.model.saveRetainedEditorWork(); return true }
        return false
    }
}

/// Five command domains, below the hosted SDK's ten-child builder limit. The
/// Settings-only tool Scene supplies the normal macOS Close/Edit/Window/Quit
/// commands; focused AppKit Merge controllers contribute their source menus.
struct MergeToolBaseCommands: Commands {
    @ObservedObject var context: MergeToolMenuContext
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Close") { context.close() }
                .keyboardShortcut("w").disabled(!context.canClose)
        }
        CommandGroup(replacing: .saveItem) {
            Button { context.saveAll() } label: { CommandLabel(title: "Save All", icon: .mergeSave) }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!context.canSaveAll)
        }
        CommandGroup(replacing: .appSettings) { }
        CommandGroup(replacing: .appInfo) {
            Button("About TurtleGitMerge…") { TurtleGitAboutService.shared.show(.merge) }
        }
        CommandGroup(replacing: .help) {
            Button("TurtleGit Help") { TurtleGitHelp.showContext() }.keyboardShortcut("?", modifiers: .command)
        }
    }
}
