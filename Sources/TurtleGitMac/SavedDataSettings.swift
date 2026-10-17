import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SavedDataSettingsModel: ObservableObject {
    private(set) var retired = false
    private(set) static var activeCacheClears = 0
    @Published private(set) var clearingHistoryCache = false
    private var historyClearGeneration = UUID()
    var clearHistoryRecords: @Sendable (HistoryFileCache) async throws -> Void = { try $0.clearSavedRecords() }
    func activate() { retired = false }
    func cancelTransientOperations() { temporaryClearGeneration += 1; confirmingTemporaryClear = false; confirmTemporaryClear = { $0(false) } }
    func retire() { retired = true; historyClearGeneration = UUID(); cancelTransientOperations() }
    private(set) var savedMaximumLines: String = ""
    var modified: Bool { maximumLines != savedMaximumLines }
    func cancelDraft() { maximumLines = savedMaximumLines }
    @Published var maximumLines: String
    @Published private(set) var available = false
    @Published var error: String?
    @Published private(set) var summaries: [SavedDataCategory: SavedDataSummary] = [:]
    private let savedData: SavedDataStore
    private let temporaryFiles: TemporaryFileStore
    private let historyCache: HistoryFileCache
    @Published private(set) var historyCacheRecords = 0
    private var temporaryClearGeneration = 0
    @Published private(set) var canClearTemporaryFiles = true
    @Published private(set) var confirmingTemporaryClear = false
    var confirmTemporaryClear: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    let store: ActionLogStore
    private let preferences: UserDefaults
    private let showFile: (URL) -> Bool
    init(store: ActionLogStore = ActionLogStore(), preferences: UserDefaults = .standard,
         temporaryFiles: TemporaryFileStore = TemporaryFileStore(),
         historyCache: HistoryFileCache = HistoryFileCache(),
         showFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.historyCache = historyCache; self.temporaryFiles = temporaryFiles; self.store = store; self.preferences = preferences; self.savedData = SavedDataStore(preferences: preferences); self.showFile = showFile
        maximumLines = String(ActionLogStore.maximumLines(preferences: preferences)); savedMaximumLines = maximumLines; refresh()
    }
    var valid: Bool { !maximumLines.isEmpty && maximumLines.utf8.allSatisfy { (48...57).contains($0) } && UInt32(maximumLines) != nil }
    func apply() { guard !retired, valid, let value = UInt32(maximumLines) else { return }; preferences.set(NSNumber(value: value), forKey: "MaxLinesInLogfile"); savedMaximumLines = maximumLines }
    func refresh() { guard !retired else { return }; if !clearingHistoryCache { historyCacheRecords = (try? historyCache.savedRecordCount()) ?? 0 }; available = store.exists; summaries = Dictionary(uniqueKeysWithValues: SavedDataCategory.allCases.map { ($0, savedData.summary($0)) }) }
    func clearHistoryCache() {
        guard !retired, !clearingHistoryCache else { return }
        let request = UUID(); historyClearGeneration = request
        let cache = historyCache, clear = clearHistoryRecords
        clearingHistoryCache = true; error = nil; Self.activeCacheClears += 1
        // Accepted deletion owns its lifetime through completion, including a
        // forced Settings close. Retired pages never receive a late error/result.
        Task {
            let result = await Task.detached { () -> String? in
                do { try await clear(cache); return nil } catch { return error.localizedDescription }
            }.value
            Self.activeCacheClears -= 1; clearingHistoryCache = false
            guard !retired else { return }
            if request == historyClearGeneration { error = result }
            refresh()
        }
    }
    func clear(_ category: SavedDataCategory) { guard !retired else { return }; savedData.clear(category); refresh() }
    func resetTemporaryAvailability() { if !confirmingTemporaryClear { canClearTemporaryFiles = true } }
    static func temporaryClearAlert() -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "TurtleGit"
        alert.informativeText = "To clear temporary files, ensure that no other TurtleGit operations or external viewers are using them.\n\nDownloaded Gravatar images may also remain in the system HTTP cache."
        let abort = alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Proceed")
        abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
        return alert
    }
    func clearTemporaryFiles() {
        guard !retired, canClearTemporaryFiles, !confirmingTemporaryClear else { return }
        confirmingTemporaryClear = true; temporaryClearGeneration += 1; let generation = temporaryClearGeneration
        confirmTemporaryClear { [weak self] proceed in
            guard let self, !self.retired, self.confirmingTemporaryClear, self.temporaryClearGeneration == generation else { return }; self.confirmingTemporaryClear = false
            guard proceed else { return }
            do {
                let remaining = try self.temporaryFiles.clear(); self.canClearTemporaryFiles = remaining != 0
                self.error = remaining == 0 ? nil : "\(remaining) temporary items could not be removed."
            } catch { self.error = error.localizedDescription }
        }
    }
    func show() { refresh(); guard !retired, available else { return }; if !showFile(store.storageURL) { error = "The action log could not be opened." } }
    func clear() { guard !retired else { return }; do { try store.clear(); error = nil } catch { self.error = error.localizedDescription }; refresh() }
}
struct SavedDataSettingsPage: View {
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var model: SavedDataSettingsModel
    @StateObject private var authentication = SavedDataAuthenticationOwner()
    init(preferences: UserDefaults = .standard) { _model = StateObject(wrappedValue: SavedDataSettingsModel(preferences: preferences)) }
    init(model: SavedDataSettingsModel, authentication: SavedDataAuthenticationOwner) {
        _model = StateObject(wrappedValue:model); _authentication = StateObject(wrappedValue:authentication)
    }
    private func help(_ category: SavedDataCategory) -> String {
        let count = model.summaries[category]
        switch category {
        case .urlHistory: return "\(count?.entries ?? 0) saved URLs or directories in \(count?.histories ?? 0) histories."
        case .messageHistory: return "\(count?.entries ?? 0) saved messages in \(count?.histories ?? 0) repository histories."
        case .dialogGeometry: return "\(count?.histories ?? 0) saved dialog sizes and positions."
        case .storedDecisions: return "Show previously suppressed questions again and forget their remembered answers."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([SavedDataCategory.urlHistory, .messageHistory], id: \.self) { category in
                HStack {
                    Text(category.title)
                    Spacer()
                    Button("Clear") { model.clear(category) }
                        .disabled(category != .storedDecisions && model.summaries[category]?.available != true)
                }.help(help(category))
            }
            HStack {
                Text("Log messages (Show log dialog)")
                Spacer()
                SavedLogCacheClearButton(enabled: model.historyCacheRecords > 0 && !model.clearingHistoryCache) { model.clearHistoryCache() }.fixedSize()
                if model.clearingHistoryCache { ProgressView().controlSize(.small) }
            }.help("\(model.historyCacheRecords) cached repository log file records.")
            HStack {
                Text(SavedDataCategory.dialogGeometry.title)
                Spacer()
                Button("Clear") { model.clear(.dialogGeometry) }.disabled(model.summaries[.dialogGeometry]?.available != true)
            }.help(help(.dialogGeometry))
            HStack {
                Text("Authentication data")
                Spacer()
                Button("Clear…") { authentication.show(owner: transaction?.window) }
            }.help("Review and remove TurtleGit’s saved SSH authentication entries.")
            HStack {
                Text("SSH key file permissions")
                Spacer()
                Button("Manage…") { authentication.show(owner: transaction?.window, section: .keyFiles) }
            }
            HStack {
                Text("Temp files (including Gravatar images)")
                Spacer()
                Button("Clear") { model.clearTemporaryFiles() }.disabled(!model.canClearTemporaryFiles || model.confirmingTemporaryClear)
            }
            HStack {
                Text(SavedDataCategory.storedDecisions.title)
                Spacer()
                Button("Clear") { model.clear(.storedDecisions) }.help(help(.storedDecisions))
            }
            GroupBox("Action log") {
                HStack {
                    Text("Max. lines in action log")
                    TextField("4000", text: $model.maximumLines).frame(width: 100)
                        .onChange(of: model.maximumLines) { _ in if transaction == nil { model.apply() } }
                    Spacer()
                    Button("Show") { model.show() }.disabled(!model.available)
                    Button("Clear") { model.clear() }.disabled(!model.available)
                }.padding(8)
                if !model.valid { Text("Enter a whole number from 0 to 4294967295.").foregroundStyle(.red) }
            }
            Spacer()
        }.padding(20).onAppear {
            model.activate(); model.refresh(); model.resetTemporaryAvailability()
            model.confirmTemporaryClear = { choose in
                let alert = SavedDataSettingsModel.temporaryClearAlert()
                choose(alert.runModal() == .alertSecondButtonReturn)
            }
        }
        .onDisappear { authentication.close(); model.cancelTransientOperations() }
        .settingsParticipant("savedData", page: .savedData, value: model.maximumLines, modified: { model.modified },
            validate: { model.valid ? nil : "Enter a whole number from 0 to 4294967295 for action log lines." },
            apply: { model.apply(); return !model.modified }, cancel: model.cancelDraft)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let owner = transaction?.window, let closed = notification.object as? NSWindow, owner === closed { model.retire(); authentication.close() }
            else { model.refresh() }
        }
        .alert("Saved Data", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}


@MainActor final class SavedDataAuthenticationOwner: ObservableObject {
    private(set) var controller: SavedSSHAuthenticationWindowController?
    private let store: any SSHAuthenticationStore
    private let identities: SSHIdentityAccessStore
    init(store: any SSHAuthenticationStore = SSHKeychainAuthenticationStore.shared, identities: SSHIdentityAccessStore = SSHIdentityAccessStore()) { self.store = store; self.identities = identities }
    func show(owner: NSWindow?, section: SavedSSHAuthenticationSection = .passphrases) {
        guard controller == nil, owner?.attachedSheet == nil else { return }
        let child = SavedSSHAuthenticationWindowController(store:store, identities: identities, section: section); controller = child
        child.onClosed = { [weak self, weak child] in
            if let window = child?.window, let parent = window.sheetParent { parent.endSheet(window) }
            if self?.controller === child { self?.controller = nil }
        }
        if let owner, let window = child.window { owner.beginSheet(window) }
        else { child.showWindow(nil) }
    }
    func close() { let child = controller; controller = nil; child?.close() }
}

/// A native target/action control keeps keyboard and accessibility activation on
/// the same once-only model gate as pointer activation.
private struct SavedLogCacheClearButton: NSViewRepresentable {
    let enabled: Bool
    let invoke: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Clear", target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .rounded; button.setAccessibilityIdentifier("SavedData.ClearLogCache")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = NSLocalizedString("Clear", comment: "")
        button.isEnabled = enabled; context.coordinator.invoke = invoke
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.invoke = {}; button.target = nil
    }
    @MainActor final class Coordinator: NSObject {
        var invoke: () -> Void = {}
        @objc func press() { invoke() }
    }
}
