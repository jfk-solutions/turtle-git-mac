// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FinderOverlaySettingsModel: ObservableObject {
    let settingsRegistration = UUID()
    @Published var draft: FinderOverlaySettings
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var saved: FinderOverlaySettings
    private let preferences: UserDefaults
    private let publish: (FinderOverlaySettings) throws -> Bool
    private let notify: () -> Void
    init(preferences: UserDefaults = .standard,
         publish: @escaping (FinderOverlaySettings) throws -> Bool = { try $0.write() },
         notify: @escaping () -> Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }) {
        self.preferences = preferences; self.publish = publish; self.notify = notify
        let initial = FinderOverlaySettings.from(defaults: preferences); draft = initial; saved = initial
    }
    var modified: Bool { draft != saved }
    var validationError: String? { draft.pathPolicy.issue?.message }
    func apply() -> Bool {
        let value = draft
        guard validationError == nil else { error = validationError; notice = nil; return false }
        do {
            let shared = try publish(value); try value.save(to: preferences); saved = value
            error = nil; notice = shared ? nil : "Finder preferences saved. Signed App Group access is required to update the extension."
            if shared { notify() }
            return true
        } catch { self.error = error.localizedDescription; notice = nil; return false }
    }
    func cancel() { draft = saved; error = nil; notice = nil }
}
struct FinderOverlaySettingsPage: View {
    @ObservedObject var model: FinderOverlaySettingsModel
    var handlersOnly = false
    var iconsOnly = false
    @State private var largeIcons = false
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if iconsOnly {
                    Picker("Icon set:", selection: $model.draft.iconSet) { ForEach(FinderOverlayIconSet.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Preview:", selection: $largeIcons) { Text("List").tag(false); Text("Symbols").tag(true) }.pickerStyle(.radioGroup)
                    if largeIcons {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 20) {
                            ForEach(FinderOverlayBadge.allCases, id: \.self) { badge in
                                VStack { if let image = badge.image(set: model.draft.iconSet, size: 32) { Image(nsImage: image) }; Text(badge.title) }.padding(12)
                            }
                        }
                    } else {
                        List(FinderOverlayBadge.allCases, id: \.self) { badge in
                            HStack { if let image = badge.image(set: model.draft.iconSet) { Image(nsImage: image) }; Text(badge.title) }
                        }.frame(height: 300)
                    }
                    Text("Finder uses this icon set after Apply.").font(.caption).foregroundStyle(.secondary)
                } else if handlersOnly {
                    GroupBox("Enabled Overlay Handlers") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Choose the status badges shown in Finder.")
                            ForEach([FileState.ignored, .untracked, .added], id: \.self) { state in
                                Toggle(isOn: Binding(get: { !model.draft.hiddenStates.contains(state) }, set: { if $0 { model.draft.hiddenStates.remove(state) } else { model.draft.hiddenStates.insert(state) } })) {
                                    badgeLabel(FinderOverlayBadge(rawValue: state.rawValue)!)
                                }
                            }
                            Toggle(isOn: $model.draft.showSkipWorktree) { badgeLabel(.skipWorktree) }
                            Toggle(isOn: $model.draft.showAssumeUnchanged) { badgeLabel(.assumeUnchanged) }
                            Toggle(isOn: Binding(get: { !model.draft.hiddenStates.contains(.deleted) }, set: { if $0 { model.draft.hiddenStates.remove(.deleted) } else { model.draft.hiddenStates.insert(.deleted) } })) { badgeLabel(.deleted) }
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
                    Text("One absolute path per line. A trailing * includes descendants; ? matches only that path. ~ and $HOME expand to your home folder. More specific paths take precedence. Matching follows each volume’s case sensitivity.").font(.caption).foregroundStyle(.secondary)
                    if let issue = model.validationError { Text(issue).font(.caption).foregroundStyle(.red).accessibilityLabel("Overlay path error: " + issue) }
                    else { Text("\(model.draft.pathPolicy.includeCount) include rule(s), \(model.draft.pathPolicy.excludeCount) exclude rule(s)").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Show excluded folders as normal", isOn: $model.draft.showExcludedAsNormal)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
            }.padding(12)
        }
        .onAppear {
            transaction?.register("overlays", participant: .init(page: .overlays, modified: { model.modified }, validate: { model.validationError }, apply: { model.apply() }, cancel: model.cancel), registration: model.settingsRegistration)
        }
        .onChange(of: model.draft) { _ in transaction?.notify() }
    }
    private func badgeLabel(_ badge: FinderOverlayBadge) -> some View {
        HStack {
            if let image = badge.image(set: model.draft.iconSet) { Image(nsImage: image) }
            Text(badge == .untracked ? "Unversioned" : badge == .assumeUnchanged ? "Assume valid/unchanged" : badge.title)
        }
    }
    private func volume(_ title: String, _ kind: FinderVolumeKind) -> some View {
        Toggle(title, isOn: Binding(get: { model.draft.volumes.contains(kind) }, set: { if $0 { model.draft.volumes.insert(kind) } else { model.draft.volumes.remove(kind) } }))
    }
    private func pathEditor(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) { Text(title).frame(width: 110, alignment: .leading); TextEditor(text: text).accessibilityLabel(title).font(.system(.body, design: .monospaced)).frame(height: 58).border(Color.secondary.opacity(0.3)) }
    }
}
