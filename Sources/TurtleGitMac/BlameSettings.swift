import AppKit
import SwiftUI
import TurtleGitCore

extension Notification.Name {
    static let blamePreferencesChanged = Notification.Name("TurtleGitBlame.PreferencesChanged")
}

struct BlameSettings: View {
    @State private var reference = BlameSettingsWindowReference()
    @State private var draft = GitBlamePreferences.load()
    @State private var within = String(GitBlamePreferences.load().withinFileCharacters)
    @State private var between = String(GitBlamePreferences.load().betweenFileCharacters)
    private func count(_ value: String) -> UInt32? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(value)
    }
    private var options: GitBlameOptions? {
        guard let within = count(within), let between = count(between) else { return nil }
        var result = draft; result.withinFileCharacters = within; result.betweenFileCharacters = between
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Blame") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Detect moved or copied lines:", selection: $draft.detectionMode) {
                        ForEach(GitBlameDetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text("Number of characters required for moved or copied line detection:").font(.caption)
                    HStack {
                        Text("Within a file:")
                        TextField("Characters within a file", text: $within).frame(width: 70).disabled(draft.detectionMode != .withinFile)
                        Spacer()
                        Text("Between files:")
                        TextField("Characters between files", text: $between).frame(width: 70).disabled(!draft.detectionMode.betweenFiles)
                    }
                    Toggle("Ignore whitespace", isOn: $draft.ignoreWhitespace)
                    Toggle("Only consider first parents on blame", isOn: $draft.onlyFirstParent)
                    if options == nil { Text("Enter character counts from 0 to 4294967295.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Apply these defaults to open and new Blame windows. Each window retains its source encoding.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { restore(); reference.window?.performClose(nil) }
                Button("Apply") {
                    guard let options else { return }
                    GitBlamePreferences.save(options)
                    NotificationCenter.default.post(name: .blamePreferencesChanged, object: nil)
                }.disabled(options == nil || options == GitBlamePreferences.load())
            }
        }.padding(20).background(BlameSettingsWindowProbe(reference: reference).frame(width: 0, height: 0)).onAppear { restore() }
    }
    private func restore() {
        draft = GitBlamePreferences.load(); within = String(draft.withinFileCharacters); between = String(draft.betweenFileCharacters)
    }
}
private final class BlameSettingsWindowReference { weak var window: NSWindow? }
private struct BlameSettingsWindowProbe: NSViewRepresentable {
    let reference: BlameSettingsWindowReference
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); view.reference = reference; return view }
    func updateNSView(_ view: ProbeView, context: Context) { reference.window = view.window }
    final class ProbeView: NSView {
        var reference: BlameSettingsWindowReference?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window }
    }
}
