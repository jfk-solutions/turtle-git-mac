import SwiftUI
import AppKit
import TurtleGitCore

extension Notification.Name {
    static let mergeEditorPreferencesChanged = Notification.Name("TurtleGitMerge.PreferencesChanged")
}

struct MergeEditorSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var windowReference = MergeSettingsWindowReference()
    @State private var initialized = false
    @State private var draft = MergeEditorPreferences.load()
    @State private var comparison = MergeComparisonOptions.load()
    @State private var tabSize = String(MergeEditorPreferences.load().tabWidth)
    private var validWidth: Int? {
        guard let width = Int(tabSize), (1...1000).contains(width) else { return nil }
        return width
    }
    private var changed: Bool {
        guard let width = validWidth else { return true }
        return MergeEditorPreferences(tabWidth: width, useSpaces: draft.useSpaces, smartTab: draft.smartTab, showLineNumbers: draft.showLineNumbers, enableEditorConfig: draft.enableEditorConfig, autoAdd: draft.autoAdd) != .load() || comparison != .load()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show line numbers", isOn: $draft.showLineNumbers)
                    HStack {
                        Toggle("Use spaces", isOn: $draft.useSpaces)
                        Spacer()
                        Toggle("Smart tab char", isOn: $draft.smartTab)
                    }
                    HStack {
                        Text("Tab size:")
                        TextField("Tab size", text: $tabSize).frame(width: 65)
                        Stepper("", value: Binding(get: { validWidth ?? draft.tabWidth }, set: { tabSize = String($0) }), in: 1...1000).labelsHidden()
                        Spacer()
                    }
                    Toggle("Add new files to Git after saving a patched result", isOn: $draft.autoAdd)
                    Toggle("Enable EditorConfig", isOn: $draft.enableEditorConfig)
                    Divider()
                    Picker("Whitespace comparison:", selection: $comparison.whitespace) {
                        ForEach(MergeWhitespaceComparison.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    Toggle("Ignore line endings (recommended)", isOn: $comparison.ignoreEndings)
                    Toggle("Ignore case changes", isOn: $comparison.ignoreCase)
                    if validWidth == nil { Text("Enter a tab size from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Apply indentation defaults to open panes and new windows. Enable EditorConfig sets the default for new windows; open panes retain their individual toggles.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if transaction == nil { HStack {
                Spacer()
                Button("Cancel") { restore(); windowReference.window?.performClose(nil) }
                Button("Apply") {
                    guard let width = validWidth else { return }
                    draft.tabWidth = width; draft.save(); comparison.save()
                    NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil)
                }.disabled(!changed || validWidth == nil)
            } }
        }.padding(20).background(MergeSettingsWindowProbe(reference: windowReference).frame(width: 0, height: 0)).onAppear { if !initialized { initialized = true; restore() } }
        .onChange(of: tabSize) { _ in transaction?.notify() }
        .onChange(of: comparison) { _ in transaction?.notify() }
        .settingsParticipant("mergeEditor", page: .mergeEditor, value: draft,
            modified: { changed }, validate: { validWidth == nil ? "Enter a tab size from 1 to 1000." : nil },
            apply: { applyDraft() }, cancel: restore)
    }
    private func applyDraft() -> Bool {
        guard let width = validWidth else { return false }; draft.tabWidth = width; draft.save(); comparison.save()
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true
    }
    private func restore() { draft = .load(); comparison = .load(); tabSize = String(draft.tabWidth) }
}
private final class MergeSettingsWindowReference { weak var window: NSWindow? }
private struct MergeSettingsWindowProbe: NSViewRepresentable {
    let reference: MergeSettingsWindowReference
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); view.reference = reference; return view }
    func updateNSView(_ view: ProbeView, context: Context) { reference.window = view.window }
    final class ProbeView: NSView {
        var reference: MergeSettingsWindowReference?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window }
    }
}
