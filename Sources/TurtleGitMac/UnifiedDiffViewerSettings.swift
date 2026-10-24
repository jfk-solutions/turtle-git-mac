import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

/// Freeze the owning dialog's backend policy before an asynchronous read. Keep
/// executable, rename policy, askpass and any injected runtime together.
struct NativeDiffBackendIdentity:Equatable {
    let enabled:Bool,mask:UInt32,helper:Data?
    init(_ backend:GitLibGit2Configuration?) {enabled=backend?.enabled ?? true;mask=backend?.mask ?? GitLibGit2Configuration.defaultMask;helper=backend?.helperURL.map{Data($0.path.utf8)}}
}
extension GitRepository {
    nonisolated func capturingBackend(_ backend:GitLibGit2Configuration)->GitRepository {
        GitRepository(root:root,executable:executable,askpass:askpass,diffDetection:diffDetection,libgit2Configuration:backend)
    }
    @MainActor func capturingDiffBackend(preferences:UserDefaults)->GitRepository {
        let backend=GitLibGit2Configuration.load(from:preferences,helperURL:libgit2Configuration?.helperURL)
        return GitRepository(root:root,executable:executable,askpass:askpass,diffDetection:diffDetection,libgit2Configuration:backend)
    }
}

@MainActor enum UnifiedDiffPreviewFiles {
    private static var files: [URL: UnifiedDiffPreview] = [:]
    static func retain(_ preview: UnifiedDiffPreview) { files[preview.file] = preview }
    static func discard(_ file: URL) { files.removeValue(forKey: file)?.discard() }
    static func discardAll() { for preview in files.values { preview.discard() }; files.removeAll() }
}

@MainActor enum UnifiedDiffApplication {
    private(set) static var activeRequests = 0
    static func presentBuiltin(_ bytes: Data, repository: GitRepository, access: RepositoryAccessLease?, existing: PatchWindowController?, title: String, preferences: UserDefaults = .standard, onClosed: @escaping () -> Void) -> PatchWindowController {
        let controller = existing ?? PatchWindowController(repository: repository, access: access, preferences: preferences)
        controller.presentDocument(bytes, title: "\(repository.root.lastPathComponent) – Unified Diff – TurtleGit", comparison: title,
            information: bytes.isEmpty ? "No changes in this comparison." : "Edit the patch document; Save As exports it without changing repository files.")
        controller.onClosed = onClosed
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    /// Returns false when the caller should use its built-in viewer.
    static func openExternal(_ bytes: Data, alternate: Bool, preferences defaults: UserDefaults = .standard, title: String = "",
                             permissions: [RepositoryAccessLease] = [], cancellation: OperationCancellation? = nil,
                             provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(), requiresScopes: Bool = GitRuntime.isAppStoreBuild,
                             launch: ExternalDocumentApplication.Launch? = nil) async throws -> Bool {
        let preferences = UnifiedDiffViewerPreferences.load(from: defaults)
        guard case .external = try preferences.choice(alternate: alternate) else { return false }
        try cancellation?.check()
        let preview = try UnifiedDiffPreview.create(bytes)
        UnifiedDiffPreviewFiles.retain(preview)
        activeRequests += 1
        defer { activeRequests -= 1 }
        do {
            try await ExternalDocumentApplication.open(file: preview.file, program: preferences.program,
                arguments: preferences.expandedArguments(file: preview.file, title: title),
                nativeDocumentOpen: preferences.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                permissions: permissions, cancellation: cancellation, provider: provider, requiresScopes: requiresScopes, launch: launch)
            return true
        } catch { UnifiedDiffPreviewFiles.discard(preview.file); throw error }
    }
    static func open(_ file: URL, application: URL, bookmark: Data?, arguments: String = "", title: String = "", permissions: [RepositoryAccessLease] = [], completion: @escaping (String?) -> Void) {
        let preferences = UnifiedDiffViewerPreferences(enabled: true, applicationPath: application.path, bookmark: bookmark, arguments: arguments)
        activeRequests += 1
        Task {
            defer { activeRequests -= 1 }
            do {
                guard case .external = try preferences.choice() else { throw UnifiedDiffViewerFailure.application }
                try await ExternalDocumentApplication.open(file: file, program: preferences.program,
                    arguments: preferences.expandedArguments(file: file, title: title), nativeDocumentOpen: arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, permissions: permissions)
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }

}

struct UnifiedDiffViewerSettings: View {
    let settingsPage: SettingsPageID
    private let preferences: UserDefaults
    @Environment(\.settingsTransaction) private var transaction
    @State private var draft: UnifiedDiffViewerPreferences
    @State private var saved: UnifiedDiffViewerPreferences
    init(settingsPage: SettingsPageID = .unifiedDiff, preferences: UserDefaults = .standard) {
        self.settingsPage = settingsPage; self.preferences = preferences
        let value = UnifiedDiffViewerPreferences.load(from:preferences)
        _draft = State(initialValue:value); _saved = State(initialValue:value)
    }
    @State private var error: String?
    @StateObject private var chooser = ToolApplicationChooser()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Configure viewer program for GNU diff files (patch files)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Viewer", selection: $draft.enabled) {
                        Text("TurtleGit Unified Diff").tag(false)
                        Text("External").tag(true)
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                    HStack {
                        Text("External Program:").frame(width:120,alignment:.leading)
                        PathEntryField(text:Binding(get:{draft.applicationPath},set:{draft.applicationPath=$0;draft.bookmark=nil}),label:"Unified Diff program",preferences:preferences,mayEdit:{draft.enabled && !chooser.selecting}).frame(height:24)
                        Button("Browse…", action: browse)
                    }.disabled(!draft.enabled)
                    HStack {Text("Arguments:").frame(width:120,alignment:.leading);ToolLiteralTextField(text:$draft.arguments,label:"Unified Diff arguments",mayEdit:{draft.enabled && !chooser.selecting}).frame(height:24).accessibilityIdentifier("UnifiedDiff.ViewerArguments")}.disabled(!draft.enabled)
                    Text("Use %1 for the patch and %title for its title. The patch is appended when %1 is absent. Leave arguments empty to open a document in an app bundle. Quotes group an argument; filenames and titles are substituted afterward.").font(.caption).foregroundStyle(.secondary)
                    if !draft.valid { Text(draft.argumentsValid ? "Choose an application bundle or executable using its full path." : "Finish the quote or escape in the arguments.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Hold Shift when opening a unified diff from Format Patch, Log, Commit, Working Tree or Changed Files to reverse the viewer choice. A saved external application remains available while the built-in viewer is selected.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if transaction == nil { HStack { Spacer()
                Button("Cancel") { draft = saved; chooser.window?.performClose(nil) }
                Button("Apply") { draft.save(to:preferences); saved = draft }.disabled(!draft.valid || draft == saved)
            } }
        }.padding(20).disabled(chooser.selecting).background(ToolChooserProbe(chooser: chooser).frame(width: 0, height: 0)).onDisappear { chooser.cancel() }
            .settingsParticipant("unifiedDiff.viewer", page: settingsPage, value: draft, modified: { draft != saved },
                validate: { draft.valid ? nil : "Choose a valid viewer and argument template." },
                apply: { draft.save(to:preferences); saved = draft; return true }, cancel: { draft = saved })
            .alert("Unified Diff Viewer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func browse() {
        let captured=draft
        chooser.choose({ application, bookmark in draft.bookmark = bookmark; draft.applicationPath = application.path }, failure: { error = $0 }, allowExecutables: true,currentPath:captured.applicationPath,isCurrent:{draft == captured && draft.enabled})
    }
}
