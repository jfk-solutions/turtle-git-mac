import SwiftUI
import AppKit
import TurtleGitCore

extension Notification.Name {
    static let mergeEditorPreferencesChanged = Notification.Name("TurtleGitMerge.PreferencesChanged")
}

struct MergeEditorSettings: View {
    @State private var windowReference = MergeSettingsWindowReference()
    @State private var draft = MergeEditorPreferences.load()
    @State private var tabSize = String(MergeEditorPreferences.load().tabWidth)
    private var validWidth: Int? {
        guard let width = Int(tabSize), (1...1000).contains(width) else { return nil }
        return width
    }
    private var changed: Bool {
        guard let width = validWidth else { return true }
        return MergeEditorPreferences(tabWidth: width, useSpaces: draft.useSpaces, smartTab: draft.smartTab, showLineNumbers: draft.showLineNumbers) != .load()
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
                    if validWidth == nil { Text("Enter a tab size from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Apply these defaults to open merge panes and new merge windows. Pane menus can override them for the current session.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { restore(); windowReference.window?.performClose(nil) }
                Button("Apply") {
                    guard let width = validWidth else { return }
                    draft.tabWidth = width; draft.save()
                    NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil)
                }.disabled(!changed || validWidth == nil)
            }
        }.padding(20).background(MergeSettingsWindowProbe(reference: windowReference).frame(width: 0, height: 0)).onAppear { restore() }
    }
    private func restore() { draft = .load(); tabSize = String(draft.tabWidth) }
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
