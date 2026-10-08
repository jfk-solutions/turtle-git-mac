import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SavedDataSettingsModel: ObservableObject {
    @Published var maximumLines: String
    @Published private(set) var available = false
    @Published var error: String?
    @Published private(set) var summaries: [SavedDataCategory: SavedDataSummary] = [:]
    private let savedData: SavedDataStore
    let store: ActionLogStore
    private let preferences: UserDefaults
    private let showFile: (URL) -> Bool
    init(store: ActionLogStore = ActionLogStore(), preferences: UserDefaults = .standard,
         showFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.store = store; self.preferences = preferences; self.savedData = SavedDataStore(preferences: preferences); self.showFile = showFile
        maximumLines = String(ActionLogStore.maximumLines(preferences: preferences)); refresh()
    }
    var valid: Bool { !maximumLines.isEmpty && maximumLines.utf8.allSatisfy { (48...57).contains($0) } && UInt32(maximumLines) != nil }
    func apply() { guard valid, let value = UInt32(maximumLines) else { return }; preferences.set(NSNumber(value: value), forKey: "MaxLinesInLogfile") }
    func refresh() { available = store.exists; summaries = Dictionary(uniqueKeysWithValues: SavedDataCategory.allCases.map { ($0, savedData.summary($0)) }) }
    func clear(_ category: SavedDataCategory) { savedData.clear(category); refresh() }
    func show() { refresh(); guard available else { return }; if !showFile(store.storageURL) { error = "The action log could not be opened." } }
    func clear() { do { try store.clear(); error = nil } catch { self.error = error.localizedDescription }; refresh() }
}
struct SavedDataSettingsPage: View {
    @StateObject private var model = SavedDataSettingsModel()
    private func help(_ category: SavedDataCategory) -> String {
        let count = model.summaries[category]
        switch category {
        case .urlHistory: return "\(count?.entries ?? 0) saved URLs or directories in \(count?.histories ?? 0) histories."
        case .messageHistory: return "\(count?.entries ?? 0) saved messages in \(count?.histories ?? 0) repository histories."
        case .storedDecisions: return "Show previously suppressed questions again and forget their remembered answers."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(SavedDataCategory.allCases, id: \.self) { category in
                HStack {
                    Text(category.title)
                    Spacer()
                    Button("Clear") { model.clear(category) }
                        .disabled(category != .storedDecisions && model.summaries[category]?.available != true)
                }.help(help(category))
            }
            GroupBox("Action log") {
                HStack {
                    Text("Max. lines in action log")
                    TextField("4000", text: $model.maximumLines).frame(width: 100)
                        .onChange(of: model.maximumLines) { _ in model.apply() }
                    Spacer()
                    Button("Show") { model.show() }.disabled(!model.available)
                    Button("Clear") { model.clear() }.disabled(!model.available)
                }.padding(8)
                if !model.valid { Text("Enter a whole number from 0 to 4294967295.").foregroundStyle(.red) }
            }
            Spacer()
        }.padding(20).onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in model.refresh() }
        .alert("Action log", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
