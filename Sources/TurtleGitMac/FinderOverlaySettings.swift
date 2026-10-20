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
    private let readStatusPolicy: () throws -> FinderStatusPolicy
    private let fenceStatusPolicy: (FinderStatusPolicy) throws -> Void
    private let configureStatusPolicy:FinderStatusSettingsPublication.Transaction?
    private var applying=false
    private let extensionState: () -> Bool
    private let openExtensionManager: () -> Void
    @Published private(set) var extensionEnabled = false
    init(preferences: UserDefaults = .standard,
         publish: @escaping (FinderOverlaySettings) throws -> Bool = { try $0.write() },
         notify: @escaping () -> Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil);DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderStatusPolicyPreferences.notification),object:nil) },
         extensionState: @escaping () -> Bool = { FIFinderSyncController.isExtensionEnabled },
         openExtensionManager: @escaping () -> Void = { FIFinderSyncController.showExtensionManagementInterface() },
         readStatusPolicy: (() throws -> FinderStatusPolicy)? = nil,
         fenceStatusPolicy: ((FinderStatusPolicy) throws -> Void)? = nil,
         configureStatusPolicy: FinderStatusSettingsPublication.Transaction? = nil) {
        self.preferences = preferences; self.publish = publish; self.notify = notify
        self.extensionState = extensionState; self.openExtensionManager = openExtensionManager
        self.configureStatusPolicy=configureStatusPolicy ?? FinderStatusSettingsPublication.shared(defaults:preferences,ownedURL:FinderOverlaySettings.sharedURL)
        self.readStatusPolicy=readStatusPolicy ?? {
            if preferences === UserDefaults.standard {return try FinderStatusPolicy.read()}
            return FinderStatusPolicy(settings:FinderOverlaySettings.from(defaults:preferences),preferences:FinderStatusPolicyPreferences.from(defaults:preferences))
        }
        self.fenceStatusPolicy=fenceStatusPolicy ?? { policy in
            if preferences === UserDefaults.standard,let url=FinderIntegration.snapshotURL {try FinderSnapshotStore(url:url).setStatusPolicy(policy)}
        }
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
    private func accepts(_ context: FormContext, page: Page) -> Bool { !retired && !applying && self.page == page && context == formContext }
    func nativeControlAllowed(_ context:FormContext,window candidate:NSWindow?)->Bool {
        accepts(context,page:.overlays) && candidate != nil && candidate === window && candidate?.isVisible == true && candidate?.attachedSheet == nil
    }
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
        guard !retired,!applying else { return false }
        revision = UUID();let acceptedRevision=revision
        let value = draft, previous=saved
        guard validationError == nil else { error = validationError; notice = nil; return false }
        applying=true;defer {applying=false}
        var prior:FinderStatusPolicy?,published=false
        do {
            var shared=false
            let derive:() throws -> FinderStatusPolicy = {
                let current=try self.readStatusPolicy();prior=current
                return FinderStatusPolicy(cacheMode:value.cacheMode,caseSensitive:current.caseSensitive,contentCheckLimitKiB:current.contentCheckLimitKiB,blockStatus:current.blockStatus)
            }
            let write:() throws -> Void = {
                guard !self.retired,self.revision==acceptedRevision,self.draft==value else {throw GitConfigurationFailure.invalidValue}
                shared=try self.publish(value);published=shared
                guard !self.retired,self.revision==acceptedRevision,self.draft==value else {throw GitConfigurationFailure.invalidValue}
            }
            if let configureStatusPolicy {try configureStatusPolicy(derive,write,{_ = try self.publish(previous)})}
            else {try fenceStatusPolicy(derive());try write()}
            try value.save(to: preferences); saved = value
            error = nil; notice = shared ? nil : "Finder preferences saved. Signed App Group access is required to update the extension."
            if shared { notify() }
            return true
        } catch {
            if configureStatusPolicy==nil {
                if published {_ = try? publish(previous)}
                if let prior {try? fenceStatusPolicy(prior)}
            }
            self.error = error.localizedDescription; notice = nil; return false
        }
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
                            FinderOverlayCheckbox(title:"Unversioned files mark parent folder as modified",value:model.field(\.unversionedAsModified,context:context),enabled:model.draft.cacheMode == .standard,available:{model.nativeControlAllowed(context,window:$0)})
                            FinderOverlayCheckbox(title:"Show status of subrepositories in parent folders",value:model.field(\.recurseSubmodules,context:context),enabled:model.draft.cacheMode == .standard,available:{model.nativeControlAllowed(context,window:$0)})
                            Text("Overlays and context menus are provided by the Finder extension.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    GroupBox("Status cache") {
                        FinderOverlayCacheChoices(selection:model.field(\.cacheMode,context:context),available:{model.nativeControlAllowed(context,window:$0)}).padding(10)
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

@MainActor private struct FinderOverlayCacheChoices:NSViewRepresentable {
    @Binding var selection:FinderOverlayCacheMode
    let available:(NSWindow?)->Bool
    static let choices:[(String,FinderOverlayCacheMode)]=[("Default",.standard),("Shell Extended",.shellExtended),("Shell",.shell),("None",.none)]
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSStackView {
        let stack=NSStackView();stack.orientation = .horizontal;stack.alignment = .centerY;stack.spacing=20
        for (title,mode) in Self.choices {
            let button=NSButton(radioButtonWithTitle:NSLocalizedString(title,comment:""),target:context.coordinator,action:#selector(Coordinator.changed(_:)))
            button.tag=mode.rawValue;button.setContentHuggingPriority(.required,for:.horizontal);stack.addArrangedSubview(button)
        }
        stack.setAccessibilityLabel(NSLocalizedString("Status cache",comment:""));return stack
    }
    func updateNSView(_ stack:NSStackView,context:Context) {
        context.coordinator.parent=self
        for case let button as NSButton in stack.arrangedSubviews {button.state=button.tag==selection.rawValue ? .on:.off}
    }
    static func dismantleNSView(_ stack:NSStackView,coordinator:Coordinator) {
        coordinator.retired=true
        for case let button as NSButton in stack.arrangedSubviews {button.target=nil;button.action=nil}
    }
    @MainActor final class Coordinator:NSObject {
        var parent:FinderOverlayCacheChoices,retired=false
        init(_ parent:FinderOverlayCacheChoices){self.parent=parent}
        @objc func changed(_ sender:NSButton) {
            guard !retired,sender.isEnabled,parent.available(sender.window),let mode=FinderOverlayCacheMode(rawValue:sender.tag) else{return}
            parent.selection=mode
        }
    }
}
@MainActor private struct FinderOverlayCheckbox:NSViewRepresentable {
    let title:String
    @Binding var value:Bool
    let enabled:Bool
    let available:(NSWindow?)->Bool
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSButton {
        NSButton(checkboxWithTitle:NSLocalizedString(title,comment:""),target:context.coordinator,action:#selector(Coordinator.changed(_:)))
    }
    func updateNSView(_ button:NSButton,context:Context) {context.coordinator.parent=self;button.isEnabled=enabled;button.state=value ? .on:.off}
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {coordinator.retired=true;button.target=nil;button.action=nil}
    @MainActor final class Coordinator:NSObject {
        var parent:FinderOverlayCheckbox,retired=false
        init(_ parent:FinderOverlayCheckbox){self.parent=parent}
        @objc func changed(_ sender:NSButton) {
            guard !retired,parent.enabled,sender.isEnabled,parent.available(sender.window) else{return}
            parent.value=sender.state == .on
        }
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
