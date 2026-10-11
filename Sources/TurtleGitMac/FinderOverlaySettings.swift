// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FinderOverlaySettingsModel: ObservableObject {
    @Published var draft = FinderOverlaySettings.from()
    @Published var error: String?
    private var saved = FinderOverlaySettings.from()
    var modified: Bool { draft != saved }
    func apply() -> Bool {
        do {
            let shared = try draft.write(); try draft.save(); saved = draft
            error = shared ? nil : "Finder preferences saved. Signed App Group access is required to update the extension."
            if shared { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancel() { draft = saved; error = nil }
}
struct FinderOverlaySettingsPage: View {
    @ObservedObject var model: FinderOverlaySettingsModel
    var handlersOnly = false
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if handlersOnly {
                GroupBox("Enabled Overlay Handlers") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose the status badges shown in Finder.")
                        ForEach([FileState.ignored, .untracked, .added, .deleted], id: \.self) { state in
                            Toggle(isOn: Binding(get: { !model.draft.hiddenStates.contains(state) }, set: { if $0 { model.draft.hiddenStates.remove(state) } else { model.draft.hiddenStates.insert(state) } })) {
                                CommandLabel(title: state == .untracked ? "Unversioned" : state.rawValue.capitalized, icon: state.icon)
                            }
                        }
                        Text("Normal, modified and conflicted badges remain enabled. Finder badge preferences apply to TurtleGit’s extension.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            } else {
                GroupBox("Icon Overlays") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Unversioned files mark parent folder as modified", isOn: $model.draft.unversionedAsModified).disabled(model.draft.cacheMode != .standard)
                        Toggle("Show status of subrepositories in parent folders", isOn: $model.draft.recurseSubmodules).disabled(model.draft.cacheMode != .standard)
                        Text("Overlays and context menus are provided by the Finder extension.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                GroupBox("Status cache") {
                    Picker("Status cache", selection: $model.draft.cacheMode) { Text("Default").tag(FinderOverlayCacheMode.standard); Text("None — normal folder badges").tag(FinderOverlayCacheMode.none) }.pickerStyle(.radioGroup).labelsHidden().padding(10)
                }
                GroupBox("Drive Types") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        volume("Removable drives", .removable); volume("CD-ROM", .optical)
                        volume("Network drives", .network); volume("RAM drives", .ram)
                        volume("Fixed drives", .fixed); volume("Unknown drives", .unknown)
                    }.padding(10)
                }
                pathEditor("Exclude paths:", text: $model.draft.excludePaths)
                pathEditor("Include paths:", text: $model.draft.includePaths)
                Text("One absolute path per line. A trailing * includes descendants; ? matches only that path. ~ and $HOME expand to your home folder. More specific paths take precedence.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show excluded folders as normal", isOn: $model.draft.showExcludedAsNormal)
            }
            if let error = model.error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer()
        }.padding(12)
        .onAppear {
            transaction?.register("overlays", participant: .init(page: .overlays, modified: { model.modified }, validate: { model.draft.valid ? nil : "Enter one absolute overlay path per line." }, apply: { model.apply() }, cancel: model.cancel))
        }
        .onChange(of: model.draft) { _ in transaction?.notify() }
    }
    private func volume(_ title: String, _ kind: FinderVolumeKind) -> some View {
        Toggle(title, isOn: Binding(get: { model.draft.volumes.contains(kind) }, set: { if $0 { model.draft.volumes.insert(kind) } else { model.draft.volumes.remove(kind) } }))
    }
    private func pathEditor(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) { Text(title).frame(width: 110, alignment: .leading); TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(height: 58).border(Color.secondary.opacity(0.3)) }
    }
}
