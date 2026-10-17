// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// The source filter's information menu and clear button share one native field.
struct LogFilterField: NSViewRepresentable {
    enum Kind: Equatable { case history, paths }
    @ObservedObject var model: LogWindowModel
    var kind: Kind = .history
    func makeCoordinator() -> Coordinator { Coordinator(model: model, kind: kind) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.delegate = context.coordinator
        field.target = context.coordinator; field.action = #selector(Coordinator.searchAction(_:))
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field; context.coordinator.update(); return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.retired = true; coordinator.menuGeneration = UUID(); field.delegate = nil; field.target = nil
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let wordCommands=GitInputWordCommands()
        weak var field: NSSearchField?
        let model: LogWindowModel, kind: Kind
        var retired = false, menuGeneration = UUID()
        init(model: LogWindowModel, kind: Kind) { self.model = model; self.kind = kind }
        var available: Bool { !retired && (kind == .history ? model.canEditLogFilters : model.canEditPathFilter) }
        var text: String { kind == .history ? model.search : model.pathFilterDraft }
        func update() {
            guard !retired, let field else { return }
            if field.stringValue != text { field.stringValue = text }
            field.isEnabled = available
            field.placeholderString = kind == .history ? cue : "Filter paths"
            field.setAccessibilityLabel(kind == .history ? "Filter revisions" : "Filter changed paths")
            field.toolTip = kind == .history ? (model.searchFilterError ?? (model.searchRegex ? "ECMAScript regular expression; begin with ! to invert. Invalid expressions keep the current history." : "Require words, exclude with -word, offer alternatives with +word, quote phrases, or begin with ! to invert.")) : "Filter current and old paths: require words, exclude with -word, add alternatives with +word, quote phrases, or begin with ! to invert. Return applies immediately; Escape clears."
            field.textColor = kind == .history && model.searchFilterError != nil ? .systemRed : .labelColor
            field.setAccessibilityHelp(field.toolTip)
            if kind == .history {
                field.searchMenuTemplate = makeMenu()
                (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image = MenuIcon.historyFind.image()
            }
        }
        private static let fields: [(String, HistorySearchFields)] = [("Subject", .subject), ("Messages", .messages), ("Paths", .paths), ("Authors", .authors), ("Emails", .emails), ("Revisions", .revisions), ("Refname", .referenceNames), ("Tag Info", .tagInfo), ("Notes", .notes), ("Bug IDs", .bugIDs)]
        var cue: String {
            "Filter by: " + Self.fields.filter { model.searchFields.contains($0.1) && ($0.1 != .bugIDs || model.issueProperties.showsBugIDColumn) }.map(\.0).joined(separator: ", ")
        }
        func makeMenu() -> NSMenu {
            menuGeneration = UUID(); let generation = menuGeneration
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, checked: Bool? = nil, _ action: @escaping @MainActor (LogWindowModel) -> Void) {
                let target = LogFilterMenuTarget { [weak self] in
                    guard let self, available, menuGeneration == generation else { return }
                    menuGeneration = UUID(); action(model)
                }
                let item = NSMenuItem(title: title, action: #selector(LogFilterMenuTarget.invoke(_:)), keyEquivalent: "")
                item.target = target; item.representedObject = target; item.isEnabled = available
                item.image = MenuIcon.historyFind.contextImage(defaults: model.colorPreferences)
                if let checked { item.state = checked ? .on : .off }; menu.addItem(item)
            }
            for (title, flag) in Self.fields where flag != .bugIDs || model.issueProperties.showsBugIDColumn {
                add(title, checked: model.searchFields.contains(flag)) { model in
                    var selected = model.searchFields
                    if selected.contains(flag) { selected.remove(flag) } else { selected.insert(flag) }
                    model.selectSearchFields(selected)
                }
            }
            menu.addItem(.separator()); add("Toggle filters") { $0.toggleSearchFields() }; add("All") { $0.selectAllSearchFields() }
            menu.addItem(.separator()); add("Use regular expression", checked: model.searchRegex) { $0.setSearchRegex(!$0.searchRegex) }
            add("Case-sensitive", checked: model.searchCaseSensitive) { $0.setSearchCaseSensitive(!$0.searchCaseSensitive) }
            return menu
        }
        private func change(_ value: String, submit: Bool = false) {
            guard available else { return }
            if kind == .history { model.editSearch(value, submit: submit) }
            else { model.editPathFilter(value, submit: submit) }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            change(field.stringValue)
        }
        @objc func searchAction(_ sender: NSSearchField) { if sender.stringValue != text { change(sender.stringValue) } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard available, let field, !textView.hasMarkedText() else { return false }
            if command == #selector(NSResponder.insertNewline(_:)) { change(field.stringValue, submit: true); return true }
            if command == #selector(NSResponder.cancelOperation(_:)), !field.stringValue.isEmpty { field.stringValue = ""; change("", submit: true); return true }
            wordCommands.policy=GitInputWordBreak(defaults:model.colorPreferences)
            return wordCommands.handle(control,text:textView,selector:command,combo:false,owner:self)
        }
    }
}

@MainActor private final class LogFilterMenuTarget: NSObject {
    let action: () -> Void
    private var used = false
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { guard !used else { return }; used = true; action() }
}
