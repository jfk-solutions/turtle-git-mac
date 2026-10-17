// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore
import FinderSync

@MainActor final class FinderOverlaySettingsModel: ObservableObject {
    let settingsRegistration = UUID()
    @Published var draft: FinderOverlaySettings {
        didSet { if oldValue.cacheMode != draft.cacheMode { revision = UUID() } }
    }
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var saved: FinderOverlaySettings
    private let preferences: UserDefaults
    private let publish: (FinderOverlaySettings) throws -> Bool
    private let notify: () -> Void
    private let extensionState: () -> Bool
    private let openExtensionManager: () -> Void
    @Published private(set) var extensionEnabled = false
    init(preferences: UserDefaults = .standard,
         publish: @escaping (FinderOverlaySettings) throws -> Bool = { try $0.write() },
         notify: @escaping () -> Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) },
         extensionState: @escaping () -> Bool = { FIFinderSyncController.isExtensionEnabled },
         openExtensionManager: @escaping () -> Void = { FIFinderSyncController.showExtensionManagementInterface() }) {
        self.preferences = preferences; self.publish = publish; self.notify = notify
        self.extensionState = extensionState; self.openExtensionManager = openExtensionManager
        let initial = FinderOverlaySettings.effective(defaults: preferences); draft = initial; saved = initial
    }
    enum Page: Equatable { case overlays, handlers, icons }
    struct FormContext: Equatable { let owner: ObjectIdentifier; let revision: UUID; let page: Page? }
    @Published private var revision = UUID()
    @Published private(set) var largeIcons = false
    private var page: Page?
    private var retired = false
    private weak var window: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    var formContext: FormContext { .init(owner: ObjectIdentifier(self), revision: revision, page: page) }
    func activate(_ page: Page) { guard !retired else { return }; self.page = page; revision = UUID() }
    func suspend(_ page: Page) { if self.page == page { self.page = nil; revision = UUID() } }
    func attach(to owner: NSWindow?) {
        guard !retired, let owner, window !== owner || ownerObserver == nil else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        window = owner; revision = UUID()
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retired = true; self?.page = nil; self?.revision = UUID() }
        }
    }
    private func accepts(_ context: FormContext, page: Page) -> Bool { !retired && self.page == page && context == formContext }
    func refreshExtensionStatus(context: FormContext) {
        guard accepts(context, page: .overlays) else { return }
        let value = extensionState(); if extensionEnabled != value { extensionEnabled = value }
    }
    func manageExtension(context: FormContext) {
        guard accepts(context, page: .overlays), let window, window.isVisible, window.attachedSheet == nil else { return }
        openExtensionManager()
    }
    var extensionStatus: String {
        extensionEnabled ? NSLocalizedString("Finder extension enabled.", comment: "") : NSLocalizedString("Finder extension disabled.", comment: "")
    }
    func field<Value>(_ key: WritableKeyPath<FinderOverlaySettings, Value>, context: FormContext) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: key] }, set: { value in
            let allowed: [AnyKeyPath]
            switch context.page {
            case .overlays: allowed = [\FinderOverlaySettings.cacheMode, \FinderOverlaySettings.unversionedAsModified, \FinderOverlaySettings.recurseSubmodules, \FinderOverlaySettings.showExcludedAsNormal, \FinderOverlaySettings.excludePaths, \FinderOverlaySettings.includePaths]
            case .handlers: allowed = [\FinderOverlaySettings.showSkipWorktree, \FinderOverlaySettings.showAssumeUnchanged]
            case .icons: allowed = [\FinderOverlaySettings.iconSet]
            case nil: return
            }
            guard let page = context.page, self.accepts(context, page: page), allowed.contains(key) else { return }
            if key == \FinderOverlaySettings.unversionedAsModified || key == \FinderOverlaySettings.recurseSubmodules { guard self.draft.cacheMode == .standard else { return } }
            self.draft[keyPath: key] = value
        })
    }
    func volume(_ kind: FinderVolumeKind, context: FormContext) -> Binding<Bool> {
        Binding(get: { self.draft.volumes.contains(kind) }, set: { value in
            guard self.accepts(context, page: .overlays) else { return }
            if value { self.draft.volumes.insert(kind) } else { self.draft.volumes.remove(kind) }
        })
    }
    func handler(_ state: FileState, context: FormContext) -> Binding<Bool> {
        Binding(get: { !self.draft.hiddenStates.contains(state) }, set: { value in
            guard self.accepts(context, page: .handlers), [FileState.ignored, .untracked, .added, .deleted].contains(state) else { return }
            if value { self.draft.hiddenStates.remove(state) } else { self.draft.hiddenStates.insert(state) }
        })
    }
    func preview(context: FormContext) -> Binding<Bool> {
        Binding(get: { self.largeIcons }, set: { if self.accepts(context, page: .icons) { self.largeIcons = $0 } })
    }
    var modified: Bool { draft != saved }
    var validationError: String? { draft.pathPolicy.issue?.message }
    func apply() -> Bool {
        guard !retired else { return false }
        revision = UUID()
        let value = draft
        guard validationError == nil else { error = validationError; notice = nil; return false }
        do {
            let shared = try publish(value); try value.save(to: preferences); saved = value
            error = nil; notice = shared ? nil : "Finder preferences saved. Signed App Group access is required to update the extension."
            if shared { notify() }
            return true
        } catch { self.error = error.localizedDescription; notice = nil; return false }
    }
    func cancel() { revision = UUID(); draft = saved; error = nil; notice = nil }
}
struct FinderOverlaySettingsPage: View {
    @ObservedObject var model: FinderOverlaySettingsModel
    var handlersOnly = false
    var iconsOnly = false
    @Environment(\.settingsTransaction) private var transaction
    private var page: FinderOverlaySettingsModel.Page { iconsOnly ? .icons : handlersOnly ? .handlers : .overlays }
    var body: some View {
        let context = model.formContext
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if iconsOnly {
                    Picker("Icon set:", selection: model.field(\.iconSet, context: context)) { ForEach(FinderOverlayIconSet.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Preview:", selection: model.preview(context: context)) { Text("List").tag(false); Text("Symbols").tag(true) }.pickerStyle(.radioGroup)
                    if model.largeIcons {
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
                                Toggle(isOn: model.handler(state, context: context)) {
                                    badgeLabel(FinderOverlayBadge(rawValue: state.rawValue)!)
                                }
                            }
                            Toggle(isOn: model.field(\.showSkipWorktree, context: context)) { badgeLabel(.skipWorktree) }
                            Toggle(isOn: model.field(\.showAssumeUnchanged, context: context)) { badgeLabel(.assumeUnchanged) }
                            Toggle(isOn: model.handler(.deleted, context: context)) { badgeLabel(.deleted) }
                            Text("Normal, modified and conflicted badges remain enabled. Finder badge preferences apply to TurtleGit’s extension.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else {
                    GroupBox("Finder Extension") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.extensionStatus).foregroundStyle(model.extensionEnabled ? Color.green : Color.secondary)
                                Spacer()
                                Button { model.manageExtension(context: context) } label: { CommandLabel(title: "Manage Finder Extension…", icon: .settings) }
                            }
                            Text("Enable TurtleGit in the Finder extensions list. Apply saves badge preferences; macOS controls extension activation.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    GroupBox("Icon Overlays") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Unversioned files mark parent folder as modified", isOn: model.field(\.unversionedAsModified, context: context)).disabled(model.draft.cacheMode != .standard)
                            Toggle("Show status of subrepositories in parent folders", isOn: model.field(\.recurseSubmodules, context: context)).disabled(model.draft.cacheMode != .standard)
                            Text("Overlays and context menus are provided by the Finder extension.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    GroupBox("Status cache") {
                        Picker("Status cache", selection: model.field(\.cacheMode, context: context)) { Text("Default").tag(FinderOverlayCacheMode.standard); Text("None — normal folder badges").tag(FinderOverlayCacheMode.none) }.pickerStyle(.radioGroup).labelsHidden().padding(10)
                    }
                    GroupBox("Drive Types") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                            volume("Removable drives", .removable); volume("CD-ROM", .optical)
                            volume("Network drives", .network); volume("RAM drives", .ram)
                            volume("Fixed drives", .fixed); volume("Unknown drives", .unknown)
                        }.padding(10)
                    }
                    pathEditor("Exclude paths:", text: model.field(\.excludePaths, context: context))
                    pathEditor("Include paths:", text: model.field(\.includePaths, context: context))
                    Text("One absolute path per line. A trailing * includes descendants; ? matches only that path. ~ and $HOME expand to your home folder. More specific paths take precedence. Matching follows each volume’s case sensitivity.").font(.caption).foregroundStyle(.secondary)
                    if let issue = model.validationError { Text(issue).font(.caption).foregroundStyle(.red).accessibilityLabel("Overlay path error: " + issue) }
                    else { Text("\(model.draft.pathPolicy.includeCount) include rule(s), \(model.draft.pathPolicy.excludeCount) exclude rule(s)").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Show excluded folders as normal", isOn: model.field(\.showExcludedAsNormal, context: context))
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
            }.padding(12)
        }
        .background(FinderOverlayOwnerProbe(model: model).frame(width: 0, height: 0))
        .onAppear {
            model.activate(page)
            model.refreshExtensionStatus(context: model.formContext)
            transaction?.register("overlays", participant: .init(page: .overlays, modified: { model.modified }, validate: { model.validationError }, apply: { model.apply() }, cancel: model.cancel), registration: model.settingsRegistration)
        }
        .onDisappear { model.suspend(page) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshExtensionStatus(context: model.formContext) }
        .onChange(of: model.draft) { _ in transaction?.notify() }
    }
    private func badgeLabel(_ badge: FinderOverlayBadge) -> some View {
        HStack {
            if let image = badge.image(set: model.draft.iconSet) { Image(nsImage: image) }
            Text(badge == .untracked ? "Unversioned" : badge == .assumeUnchanged ? "Assume valid/unchanged" : badge.title)
        }
    }
    private func volume(_ title: String, _ kind: FinderVolumeKind) -> some View {
        Toggle(title, isOn: model.volume(kind, context: model.formContext))
    }
    private func pathEditor(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) { Text(title).frame(width: 110, alignment: .leading); TextEditor(text: text).accessibilityLabel(title).font(.system(.body, design: .monospaced)).frame(height: 58).border(Color.secondary.opacity(0.3)) }
    }
}

private struct FinderOverlayOwnerProbe: NSViewRepresentable {
    let model: FinderOverlaySettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window) }
    final class Probe: NSView {
        weak var model: FinderOverlaySettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to: window) }
    }
}
