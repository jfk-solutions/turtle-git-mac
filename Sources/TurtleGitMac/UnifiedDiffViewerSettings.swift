import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor enum UnifiedDiffPreviewFiles {
    private static var files: [URL: UnifiedDiffPreview] = [:]
    static func retain(_ preview: UnifiedDiffPreview) { files[preview.file] = preview }
    static func discard(_ file: URL) { files.removeValue(forKey: file)?.discard() }
    static func discardAll() { for preview in files.values { preview.discard() }; files.removeAll() }
}

@MainActor enum UnifiedDiffApplication {
    static func open(_ file: URL, application: URL, bookmark: Data?, completion: @escaping (String?) -> Void) {
        var target = application
        if let bookmark {
            do {
                var stale = false
                target = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            } catch { completion("Choose the viewer again using Browse in Settings → Unified Diff Viewer."); return }
        }
        let scoped = target.startAccessingSecurityScopedResource()
        guard !GitRuntime.isAppStoreBuild || scoped else { completion("Choose the viewer using Browse in Settings → Unified Diff Viewer to grant access."); return }
        NSWorkspace.shared.open([file], withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if scoped { target.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }
}

struct UnifiedDiffViewerSettings: View {
    @State private var draft = UnifiedDiffViewerPreferences.load()
    @State private var saved = UnifiedDiffViewerPreferences.load()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Configure viewer program for GNU diff files (patch files)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Viewer", selection: $draft.enabled) {
                        Text("TurtleGit Unified Diff").tag(false)
                        Text("External").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    HStack {
                        TextField("Viewer application", text: Binding(get: { draft.applicationPath }, set: { draft.applicationPath = $0; draft.bookmark = nil }))
                        Button("Browse…", action: browse)
                    }.disabled(!draft.enabled)
                    if !draft.valid { Text("Choose an application (.app) using its full path.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Hold Shift when opening Format Patch’s unified diff to reverse the viewer choice. A saved external application remains available while the built-in viewer is selected.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer()
                Button("Cancel") { draft = saved; NSApp.keyWindow?.performClose(nil) }
                Button("Apply") { draft.save(); saved = draft }.disabled(!draft.valid || draft == saved)
            }
        }.padding(20).onAppear { saved = .load(); draft = saved }
            .alert("Unified Diff Viewer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func browse() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel(); panel.title = "Select unified diff viewer"; panel.prompt = "Select"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let application = panel.url else { return }
            do {
                draft.bookmark = try application.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                draft.applicationPath = application.path
            } catch { self.error = error.localizedDescription }
        }
    }
}
