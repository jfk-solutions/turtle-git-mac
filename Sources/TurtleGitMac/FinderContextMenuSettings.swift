// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FinderContextMenuSettingsModel: ObservableObject {
    let settingsRegistration = UUID()
    @Published var draft: FinderMenuSettings
    @Published var message: String?
    private var saved: FinderMenuSettings
    private let defaults: UserDefaults
    private let publish: (FinderMenuSettings) throws -> Bool
    var modified: Bool { draft != saved }
    init(defaults: UserDefaults = .standard, publish: @escaping (FinderMenuSettings) throws -> Bool = { try $0.write() }) {
        self.defaults = defaults; self.publish = publish
        let initial = FinderMenuSettings.from(defaults: defaults); draft = initial; saved = initial
    }
    func apply() -> Bool {
        do {
            // Advanced owns the icon preference. A page opened before an
            // Advanced edit must not republish its old icon setting.
            draft.showIcons = FinderMenuSettings.from(defaults: defaults).showIcons
            let shared = try publish(draft); try draft.save(to: defaults); saved = draft
            message = shared ? nil : "Preferences saved. Signed App Group access is required to update Finder."
            if shared { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func cancel() { draft = saved; message = nil }
    func restore(extendedOnly: Bool) {
        if extendedOnly { draft.extendedOnlyMask = FinderMenuEntry.defaultExtendedMask }
        else { draft.topLevelMask = FinderMenuEntry.defaultTopMask }
    }
}

struct FinderContextMenuSettingsPage: View {
    @ObservedObject var model: FinderContextMenuSettingsModel
    var extendedOnly = false
    @Environment(\.settingsTransaction) private var transaction
    private var mask: UInt64 { extendedOnly ? model.draft.extendedOnlyMask : model.draft.topLevelMask }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(extendedOnly ? "Hide the selected items in the context menu:" : "Show the selected items on the first level of the context menu:") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(extendedOnly ? "Checked items will only appear when Shift is held while opening the context menu." : "Unchecked items appear in the TurtleGit submenu. Checked items appear directly in the main context menu.")
                    List(FinderMenuEntry.allCases, id: \.self) { entry in
                        Toggle(isOn: Binding(get: { mask & entry.mask != 0 }, set: { model.draft.set(entry, checked: $0, extendedOnly: extendedOnly) })) {
                            HStack {
                                if let image = entry.image() { Image(nsImage: image) }
                                Text(entry.title)
                            }
                        }.disabled(!entry.availableInFinder)
                            .help(entry.availableInFinder ? "" : "Unavailable in this build")
                    }.frame(minHeight: extendedOnly ? 360 : 220)
                    HStack {
                        MenuSelectAllButton(mask: mask, allMask: FinderMenuEntry.allMask) { checked in
                            // Preserve bits outside the source's visible list.
                            if extendedOnly { model.draft.extendedOnlyMask = checked ? mask | FinderMenuEntry.allMask : mask & ~FinderMenuEntry.allMask }
                            else { model.draft.topLevelMask = checked ? mask | FinderMenuEntry.allMask : mask & ~FinderMenuEntry.allMask }
                        }.fixedSize()
                        Spacer()
                        Button("Restore Default") { model.restore(extendedOnly: extendedOnly) }
                    }
                    Text("Some commands are unavailable in this build.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            if !extendedOnly {
                Toggle("Hide menus for unversioned paths", isOn: $model.draft.hideForUnversioned)
                GroupBox("Do not show the context menu for the following paths:") {
                    TextEditor(text: $model.draft.excludedPaths).font(.system(.body, design: .monospaced)).frame(height: 80).border(Color.secondary.opacity(0.3)).padding(8)
                }
                Text("One absolute path per line. A path alone matches exactly; a trailing / includes its children; * matches a path prefix. ~ and $HOME expand to your home folder.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show clipboard Copy/Add and Move in Finder folders", isOn: $model.draft.clipboardTransfers)
                    .help("macOS clipboard actions appear in the TurtleGit submenu; source menu masks are preserved.")
                Toggle("Enable drag context menu", isOn: .constant(false)).disabled(true)
                    .help("Finder Sync does not provide drag context menus.")
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength: 0)
        }.padding(12)
        .onAppear {
            transaction?.register("contextMenu", participant: .init(page: .contextMenu, modified: { model.modified }, validate: { model.draft.valid ? nil : "Enter one absolute context-menu exclusion path per line." }, apply: model.apply, cancel: model.cancel), registration: model.settingsRegistration)
        }
        .onChange(of: model.draft) { _ in transaction?.notify() }
    }
}

/// Source Select/deselect all uses a native three-state checkbox.
private struct MenuSelectAllButton: NSViewRepresentable {
    let mask: UInt64, allMask: UInt64
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change
        let checked = mask & allMask
        button.state = checked == 0 ? .off : checked == allMask ? .on : .mixed
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) {
            if sender.state == .mixed { sender.state = .off }
            change(sender.state == .on)
        }
    }
}
