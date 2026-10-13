import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor enum AlternativeEditor {
    static func open(_ file: URL, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let preferences = AlternativeEditorPreferences.load()
        guard preferences.valid else { completion("Choose a macOS editor application in Settings → Alternative Editor."); return }
        var application = preferences.customApplication
        if application != nil, let bookmark = preferences.bookmark {
            do {
                var stale = false
                application = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            } catch { completion("The saved editor is unavailable. Choose it again in Settings → Alternative Editor."); return }
        }
        guard let application = application ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            completion("TextEdit is unavailable. Choose a custom editor in Settings → Alternative Editor."); return
        }
        let scoped = application.startAccessingSecurityScopedResource()
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if scoped { application.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }
}

struct AlternativeEditorSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var initialized = false
    private let preferences: UserDefaults
    @State private var chooser = ToolApplicationChooser()
    @State private var draft: AlternativeEditorPreferences
    @State private var saved: AlternativeEditorPreferences
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let value = AlternativeEditorPreferences.load(from:preferences)
        _draft = State(initialValue:value); _saved = State(initialValue:value)
    }
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Alternative editor") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Editor", selection: $draft.custom) {
                        Text("TextEdit").tag(false)
                        Text("Custom").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    HStack {
                        TextField("Editor application", text: Binding(get: { draft.applicationPath }, set: {
                            guard $0 != draft.applicationPath else { return }
                            draft.applicationPath = $0; draft.bookmark = nil
                        }))
                        Button("Browse…", action: browse)
                    }.disabled(!draft.custom)
                    if !draft.valid { Text("Choose an application (.app) using its full path.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("The editor command opens working files in TextEdit or your chosen application. Open uses the file’s default application; Open With lets you choose an application once.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if transaction == nil { HStack {
                Spacer()
                Button("Cancel") { draft = saved; chooser.window?.performClose(nil) }
                Button("Apply") { draft.save(to:preferences); saved = draft }.disabled(!draft.valid || draft == saved)
            } }
        }.padding(20).background(ToolChooserProbe(chooser:chooser).frame(width:0,height:0)).onDisappear { chooser.cancel() }.onAppear { if !initialized { initialized = true; saved = .load(from:preferences); draft = saved } }
            .settingsParticipant("alternativeEditor", page: .alternativeEditor, value: draft,
                modified: { draft != saved }, validate: { draft.valid ? nil : "Choose a macOS editor application." },
                apply: { draft.save(to:preferences); saved = draft; return true }, cancel: { draft = saved })
            .alert("Alternative editor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func browse() {
        chooser.choose({ application, bookmark in draft.applicationPath = application.path; draft.bookmark = bookmark },failure:{ error = $0 })
    }
}
