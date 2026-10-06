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
    @State private var draft = AlternativeEditorPreferences.load()
    @State private var saved = AlternativeEditorPreferences.load()
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
            HStack {
                Spacer()
                Button("Cancel") { draft = saved; NSApp.keyWindow?.performClose(nil) }
                Button("Apply") { draft.save(); saved = draft }.disabled(!draft.valid || draft == saved)
            }
        }.padding(20).onAppear { saved = .load(); draft = saved }
            .alert("Alternative editor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func browse() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel(); panel.title = "Select editor application"; panel.prompt = "Select"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let application = panel.url else { return }
            do {
                let bookmark = try application.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                draft.applicationPath = application.path; draft.bookmark = bookmark
            } catch { self.error = error.localizedDescription }
        }
    }
}
