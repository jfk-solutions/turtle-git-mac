import AppKit
import SwiftUI
import Darwin
import TurtleGitCore

/// Serializes the accepted policy fence with its one owned settings file.
/// Rollback restores exact bytes without replacing another settings page's draft.
@MainActor enum FinderStatusSettingsPublication {
    typealias Transaction = (() throws -> FinderStatusPolicy, () throws -> Void, () throws -> Void) throws -> Void
    static func shared(defaults:UserDefaults,ownedURL:URL?) -> Transaction? {
        guard defaults === UserDefaults.standard,let statusURL=FinderIntegration.snapshotURL,let ownedURL else{return nil}
        return transaction(statusURL:statusURL,ownedURL:ownedURL)
    }
    static func transaction(statusURL:URL,ownedURL:URL) -> Transaction {
        return {policy,publish,_ in
            var original:Data?,permissions:Any?,captured=false
            try FinderSnapshotStore(url:statusURL).configureStatusPolicy(policy:{
                var info=stat()
                if lstat(ownedURL.path,&info)==0 {
                    guard info.st_mode&S_IFMT==S_IFREG,info.st_size>=0,info.st_size<=1024*1024 else{throw GitConfigurationFailure.invalidValue}
                    let attributes=try FileManager.default.attributesOfItem(atPath:ownedURL.path)
                    original=try Data(contentsOf:ownedURL);permissions=attributes[.posixPermissions]
                } else if errno != ENOENT {throw GitConfigurationFailure.invalidValue}
                captured=true;return try policy()
            },publish:publish,rollback:{
                guard captured else{return}
                if let original {try original.write(to:ownedURL,options:.atomic);if let permissions {try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:ownedURL.path)}}
                else if FileManager.default.fileExists(atPath:ownedURL.path) {
                    guard try FileManager.default.attributesOfItem(atPath:ownedURL.path)[.type] as? FileAttributeType == .typeRegular else{throw GitConfigurationFailure.invalidValue}
                    try FileManager.default.removeItem(at:ownedURL)
                }
            })
        }
    }
}

@MainActor final class AdvancedSettingsModel: ObservableObject {
    static let cachePersistencePendingKey = "TurtleGit.CacheSavePublicationPending"
    let store: AdvancedSettingsStore
    private let defaults: UserDefaults
    private let publishFinderMenu: (FinderMenuSettings) throws -> Void
    private let publishCachePersistence: (FinderCachePersistencePreferences) throws -> Void
    @Published private(set) var cachePersistencePublicationPending = false
    private let publishCacheTray: (FinderCacheTrayPreferences) throws -> Void
    private let readStatusPolicy: () throws -> FinderStatusPolicy
    private let publishStatusPolicy: (FinderStatusPolicyPreferences) throws -> Bool
    private let fenceStatusPolicy: (FinderStatusPolicy) throws -> Void
    private let notifyStatusPolicy: () -> Void
    private let configureStatusPolicy:FinderStatusSettingsPublication.Transaction?
    private var retired=false,pageActive=true,applying=false,revision=UUID()
    private weak var window:NSWindow?
    private var ownerObserver:NSObjectProtocol?
    static let statusPolicyNames:Set<String>=["OverlaysCaseSensitive","TGitCacheCheckContentMaxSize","BlockStatus"]
    @Published var values: [String: String] {didSet {if oldValue != values {revision=UUID()}}}
    @Published var error: String?
    @Published private var original: [String: String]
    var onApplied: () -> Void = {}
    var modified: Bool { values != original || cachePersistencePublicationPending }
    init(defaults: UserDefaults = .standard,
         publishFinderMenu: @escaping (FinderMenuSettings) throws -> Void = { _ = try $0.write() },
         publishCachePersistence: @escaping (FinderCachePersistencePreferences) throws -> Void = { if try $0.write() { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderCachePersistencePreferences.notification),object:nil) } },
         publishCacheTray: @escaping (FinderCacheTrayPreferences) throws -> Void = { if try $0.write() { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderCacheTrayPreferences.notification),object:nil) } },
         readStatusPolicy: (() throws -> FinderStatusPolicy)? = nil,
         publishStatusPolicy: ((FinderStatusPolicyPreferences) throws -> Bool)? = nil,
         fenceStatusPolicy: ((FinderStatusPolicy) throws -> Void)? = nil,
         notifyStatusPolicy: (() -> Void)? = nil,
         configureStatusPolicy: FinderStatusSettingsPublication.Transaction? = nil) {
        self.defaults = defaults; self.publishFinderMenu = publishFinderMenu; self.publishCacheTray = publishCacheTray; self.publishCachePersistence = publishCachePersistence
        store = AdvancedSettingsStore(defaults: defaults); let initial = store.values(); original = initial; values = initial
        cachePersistencePublicationPending=defaults.bool(forKey:Self.cachePersistencePendingKey)
        self.readStatusPolicy=readStatusPolicy ?? {
            if defaults === UserDefaults.standard {return try FinderStatusPolicy.read()}
            return FinderStatusPolicy(settings:FinderOverlaySettings.from(defaults:defaults),preferences:FinderStatusPolicyPreferences.from(defaults:defaults))
        }
        self.publishStatusPolicy=publishStatusPolicy ?? {value in defaults === UserDefaults.standard ? try value.write() : false}
        self.fenceStatusPolicy=fenceStatusPolicy ?? {value in
            if defaults === UserDefaults.standard,let url=FinderIntegration.snapshotURL {try FinderSnapshotStore(url:url).setStatusPolicy(value)}
        }
        self.configureStatusPolicy=configureStatusPolicy ?? FinderStatusSettingsPublication.shared(defaults:defaults,ownedURL:FinderIntegration.snapshotURL?.appendingPathExtension("policy"))
        self.notifyStatusPolicy=notifyStatusPolicy ?? {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderStatusPolicyPreferences.notification),object:nil)
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil)
        }
    }
    deinit {if let ownerObserver {NotificationCenter.default.removeObserver(ownerObserver)}}
    func activate() {guard !retired else{return};pageActive=true;revision=UUID()}
    func suspend() {pageActive=false;revision=UUID()}
    func attach(to owner:NSWindow?) {
        guard !retired,let owner,window !== owner || ownerObserver==nil else{return}
        if let ownerObserver {NotificationCenter.default.removeObserver(ownerObserver)}
        window=owner;revision=UUID()
        ownerObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:owner,queue:.main){[weak self] _ in
            MainActor.assumeIsolated {self?.retired=true;self?.pageActive=false;self?.revision=UUID()}
        }
    }
    var canEdit:Bool {!retired && pageActive && !applying && window?.attachedSheet == nil}
    func owns(_ candidate:NSWindow?)->Bool {window == nil || window === candidate}
    func edit(_ name: String, text: String) -> Bool {
        guard canEdit,let setting = AdvancedSettingDefinition.all.first(where: { $0.name == name }), setting.accepts(text) else { return false }
        values[name] = text; return true
    }
    func apply() {
        guard !retired,!applying else{return}
        let accepted=values,epoch=revision,changes=values.filter {original[$0.key] != $0.value}
        applying=true;defer {applying=false}
        var prior:FinderStatusPolicy?,published=false
        do {
            for setting in AdvancedSettingDefinition.all where changes[setting.name] != nil {
                guard setting.accepts(changes[setting.name]!) else{throw AdvancedSettingsFailure.invalidValue(setting.name)}
            }
            let updatesStatusPolicy=changes.keys.contains {Self.statusPolicyNames.contains($0)}
            if updatesStatusPolicy {
                var next=FinderStatusPolicyPreferences()
                let derive:() throws -> FinderStatusPolicy = {
                    let current=try self.readStatusPolicy();prior=current
                    next=FinderStatusPolicyPreferences(caseSensitive:current.caseSensitive,contentCheckLimitKiB:current.contentCheckLimitKiB,blockStatus:current.blockStatus)
                    if let text=changes["OverlaysCaseSensitive"] {next.caseSensitive=text.isEmpty || text=="true"}
                    if let text=changes["BlockStatus"] {next.blockStatus=text=="true"}
                    if let text=changes["TGitCacheCheckContentMaxSize"] {next.contentCheckLimitKiB=text.isEmpty ? 10240:UInt32(text.utf8.reduce(Int64(0)){min(Int64(Int32.max),$0*10+Int64($1-48))})}
                    return FinderStatusPolicy(cacheMode:current.cacheMode,caseSensitive:next.caseSensitive,contentCheckLimitKiB:next.contentCheckLimitKiB,blockStatus:next.blockStatus)
                }
                let publish:() throws -> Void = {
                    guard !self.retired,self.revision==epoch,self.values==accepted else{throw GitConfigurationFailure.invalidValue}
                    published=try self.publishStatusPolicy(next)
                    guard !self.retired,self.revision==epoch,self.values==accepted else{throw GitConfigurationFailure.invalidValue}
                }
                if let configureStatusPolicy {try configureStatusPolicy(derive,publish,{if let prior {_ = try self.publishStatusPolicy(FinderStatusPolicyPreferences(caseSensitive:prior.caseSensitive,contentCheckLimitKiB:prior.contentCheckLimitKiB,blockStatus:prior.blockStatus))}})}
                else {try fenceStatusPolicy(derive());try publish()}
            }
            guard !retired,revision==epoch,values==accepted else{throw GitConfigurationFailure.invalidValue}
            try store.apply(changes)
            original = store.values(); values=original; error = nil; RepositoryWindowTitles.refreshAll(); onApplied()
            if published {notifyStatusPolicy()}
            if changes["CacheSave"] != nil || cachePersistencePublicationPending {
                cachePersistencePublicationPending = true
                defaults.set(true,forKey:Self.cachePersistencePendingKey)
                do {
                    try publishCachePersistence(FinderCachePersistencePreferences.from(defaults:defaults))
                    cachePersistencePublicationPending = false
                    defaults.removeObject(forKey:Self.cachePersistencePendingKey)
                } catch { self.error = "Settings saved, but cache persistence preferences could not be updated. Apply again to retry: " + error.localizedDescription }
            }
            if changes["CacheTrayIcon"] != nil || changes["ShowAppContextMenuIcons"] != nil {
                do { try publishCacheTray(FinderCacheTrayPreferences.from(defaults:defaults)) }
                catch { self.error = "Settings saved, but cache menu preferences could not be updated: " + error.localizedDescription }
            }
            if changes["ShowContextMenuIcons"] != nil {
                do { try publishFinderMenu(FinderMenuSettings.from(defaults: defaults)) }
                catch { self.error = "Settings saved, but Finder menu preferences could not be updated: " + error.localizedDescription }
            }
        }
        catch {
            if configureStatusPolicy==nil,let prior {
                if published {_ = try? publishStatusPolicy(FinderStatusPolicyPreferences(caseSensitive:prior.caseSensitive,contentCheckLimitKiB:prior.contentCheckLimitKiB,blockStatus:prior.blockStatus))}
                try? fenceStatusPolicy(prior)
            }
            self.error = error.localizedDescription
        }
    }
    func cancel() { original = store.values(); values = original; error = nil }
}

struct AdvancedSettingsPage: View {
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var model: AdvancedSettingsModel
    init(defaults: UserDefaults = .standard) { _model = StateObject(wrappedValue:AdvancedSettingsModel(defaults:defaults)) }
    @StateObject private var windowReference = AdvancedSettingsWindowReference()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdvancedSettingsTable(model: model)
            Text("WARNING:\nOnly change these settings if you are absolutely sure what you are doing!\nTo set the values to their default, delete the value text.")
                .fixedSize(horizontal: false, vertical: true)
            if transaction == nil { HStack { Spacer()
                Button("Cancel") { windowReference.window?.makeFirstResponder(nil); model.cancel(); windowReference.window?.performClose(nil) }
                Button("Apply") { windowReference.window?.makeFirstResponder(nil); model.apply() }.disabled(!model.modified)
            } }
        }.padding(20)
        .settingsParticipant("advanced", page: .advanced, value: model.values, modified: { model.modified },
            apply: { model.apply(); return model.error == nil }, cancel: model.cancel)
        .onAppear { model.activate();if !model.modified { model.cancel() }; model.onApplied = { for window in NSApp.windows { if let view = window.contentView { Self.invalidate(view) } } } }
        .onDisappear {model.suspend()}
        .alert("Advanced Settings", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let closed = notification.object as? NSWindow, closed === windowReference.window { model.cancel() }
        }
        .background(AdvancedWindowProbe(reference: windowReference,model:model))
    }
    private static func invalidate(_ view: NSView) { view.needsDisplay = true; for child in view.subviews { invalidate(child) } }
}

struct AdvancedSettingsTable: NSViewRepresentable {
    @ObservedObject var model: AdvancedSettingsModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.model = model; context.coordinator.table?.reloadData() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AdvancedSettingsModel
        weak var table: NSTableView?
        init(model: AdvancedSettingsModel) { self.model = model }
        func makeScrollView() -> NSScrollView {
            let table = AdvancedTableView(); table.rowHeight = 23; table.allowsMultipleSelection = false; table.allowsColumnReordering = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id, title, width) in [("name", "Name", 420.0), ("value", "Value", 130.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
                column.isEditable = id == "value"; column.minWidth = 80; table.addTableColumn(column)
            }
            table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(beginEdit)
            table.setAccessibilityLabel("Advanced settings")
            self.table = table
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder; scroll.documentView = table; return scroll
        }
        func numberOfRows(in tableView: NSTableView) -> Int { AdvancedSettingDefinition.all.count }
        func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
            guard AdvancedSettingDefinition.all.indices.contains(row) else { return nil }
            let setting = AdvancedSettingDefinition.all[row]
            return column?.identifier.rawValue == "name" ? setting.name : model.values[setting.name]
        }
        func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for column: NSTableColumn?, row: Int) {
            guard tableView===table,let owner=tableView.window,owner.isVisible,model.owns(owner),model.canEdit,column?.identifier.rawValue == "value", AdvancedSettingDefinition.all.indices.contains(row), let text = object as? String else { return }
            if !model.edit(AdvancedSettingDefinition.all[row].name, text: text) { NSSound.beep() }
            tableView.reloadData()
        }
        func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
            guard AdvancedSettingDefinition.all.indices.contains(row) else { return "" }
            let setting = AdvancedSettingDefinition.all[row]
            let effective: Set<String> = ["FullRowSelect", "OverlaysCaseSensitive", "TGitCacheCheckContentMaxSize", "BlockStatus", "CacheSave", "UseCustomWordBreak", "RefreshFileListAfterResolvingConflict", "ReaddUnselectedAddedFilesAfterCommit", "CacheTrayIcon", "DialogTitles", "ShowListFullPathTooltip", "ShortHashLengthForHyperLinkInLogMessage", "DownloadAnimation", "FetchVerbose", "ConflictDontGuessBranchNames", "MaxRefHistoryItems", "DiffSimilarityIndexThreshold", "AutoCompleteMinChars", "AutocompleteParseMaxSize", "AutocompleteParseUnversioned", "AutocompleteRemovesExtensions", "StyleCommitMessages", "ShowListBackgroundImage", "ShowAppContextMenuIcons", "ShowContextMenuIcons", "LogIncludeBoundaryCommits", "LogIncludeWorkingTreeChanges", "LogFontForLogCtrl", "LogFontForFileListCtrl", "NoSortLocalBranchesFirst", "LogTooManyItemsThreshold", "NumDiffWarning", "LogShowSuperProjectSubmodulePointer", "NamedRemoteFetchAll", "RememberFileListPosition", "SanitizeCommitMsg", "SquashDate", "StyleGitOutput", "VersionCheck", "VersionCheckPreview"]
            if setting.name=="FullRowSelect" {return "Highlight the whole row in file, reference and progress lists. Disabling highlights the primary label only. Revision history always keeps full-row selection."}
            if setting.name=="OverlaysCaseSensitive" {return "Match Finder status paths with exact case when enabled. Disabling compares path case without combining different Unicode spellings."}
            if setting.name=="TGitCacheCheckContentMaxSize" {return "Maximum file size in KiB for Finder's content check when index stat data changes. Larger files retain stat-based status."}
            if setting.name=="BlockStatus" {return "Keep cached Finder status while TurtleGit modifies the repository; refresh when the operation finishes."}
            if setting.name=="CacheSave" { return "Save completed Finder status for the next cache session. Disabling this keeps current badges and watched repositories active, but discards saved warm status." }
            if setting.name=="UseLibgit2" { return "Optional libgit2 engine, selected by UseLibgit2_mask, for Add, checkbox Commit preparation, Clone, Fetch, remote-reference listing/deletion and historical file output. Source defaults use libgit2 for Add and filtered historical output and retain Git for checkbox Commit preparation and remote operations; ordinary Push uses Git." }
            if setting.name=="UseCustomWordBreak" {return "URL/path word navigation: 0 uses macOS behavior; 1 customizes path/branch/author fields; 2 also customizes editable history controls. Other nonzero values customize plain fields only."}
            return effective.contains(setting.name) ? setting.name : "This preference has no effect on TurtleGit yet."
        }
        @objc func beginEdit() {
            guard let table,let owner=table.window,owner.isVisible,model.owns(owner),model.canEdit,table.selectedRow >= 0 else { return }
            let valueColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("value"))
            guard valueColumn >= 0 else { return }
            table.editColumn(valueColumn, row: table.selectedRow, with: nil, select: true)
        }
    }
}

private final class AdvancedTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120, let coordinator = delegate as? AdvancedSettingsTable.Coordinator { coordinator.beginEdit(); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class AdvancedSettingsWindowReference: ObservableObject {
    weak var window: NSWindow?
}

private struct AdvancedWindowProbe: NSViewRepresentable {
    let reference: AdvancedSettingsWindowReference
    let model:AdvancedSettingsModel
    func makeNSView(context: Context) -> NSView { let view = Probe(); view.reference = reference;view.model=model; return view }
    func updateNSView(_ view: NSView, context: Context) { reference.window = view.window;model.attach(to:view.window) }
    private final class Probe: NSView {
        var reference: AdvancedSettingsWindowReference?
        weak var model:AdvancedSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window;model?.attach(to:window) }
    }
}

/// Repository windows retain their semantic title, so applying DialogTitles can
/// update existing windows without losing a scope, progress phase or revision.
@MainActor enum RepositoryWindowTitles {
    private final class Record {
        weak var window: NSWindow?
        let repository: URL
        let location: URL?
        let dialog: String
        let preferences: UserDefaults
        init(_ window: NSWindow, repository: URL, location: URL?, dialog: String, preferences: UserDefaults) {
            self.window = window; self.repository = repository; self.location = location
            self.dialog = dialog; self.preferences = preferences
        }
        func refresh() {
            window?.title = RepositoryPresentationSettings(defaults: preferences).title(repository: repository, location: location, dialog: dialog)
        }
    }
    private static var records: [ObjectIdentifier: Record] = [:]
    private static var observers: [NSObjectProtocol] = []
    static func set(_ window: NSWindow?, repository: URL, location: URL? = nil, dialog: String, preferences: UserDefaults = .standard) {
        guard let window else { return }
        TurtleGitHelp.attach(window, topic: TurtleGitHelp.topic(dialog: dialog))
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in refreshAll() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { records.removeValue(forKey: ObjectIdentifier(window)) }
            })
        }
        records = records.filter { $0.value.window != nil }
        let record = Record(window, repository: repository, location: location, dialog: dialog, preferences: preferences)
        records[ObjectIdentifier(window)] = record; record.refresh()
    }
    static func refreshAll() {
        records = records.filter { $0.value.window != nil }
        for record in records.values { record.refresh() }
    }
}

private struct RepositoryFileHelp: ViewModifier {
    let repository: URL
    let path: String
    let detail: String
    @AppStorage private var enabled: Int
    init(repository: URL, path: String, detail: String, preferences: UserDefaults) {
        self.repository = repository; self.path = path; self.detail = detail
        _enabled = AppStorage(wrappedValue: 1, "ShowListFullPathTooltip", store: preferences)
    }
    func body(content: Content) -> some View {
        let fullPath = repository.appendingPathComponent(path).standardizedFileURL.path
        content.help(enabled == 1 ? fullPath + (detail.isEmpty ? "" : "\n" + detail) : "")
    }
}
extension View {
    func repositoryFileHelp(repository: URL, path: String, detail: String = "", preferences: UserDefaults = .standard) -> some View {
        modifier(RepositoryFileHelp(repository: repository, path: path, detail: detail, preferences: preferences))
    }
}
