import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor enum AlternativeEditor {
    private(set) static var activeRequests = 0
    enum Failure: LocalizedError {
        case configuration, unavailable
        var errorDescription: String? {
            switch self {
            case .configuration: return "Choose an application bundle or executable in Settings → Alternative Editor."
            case .unavailable: return "TextEdit is unavailable. Choose a custom editor in Settings → Alternative Editor."
            }
        }
    }
    static func open(_ file: URL, preferences defaults: UserDefaults = .standard, permissions: [RepositoryAccessLease] = [], completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let settings = AlternativeEditorPreferences.load(from: defaults)
        guard settings.valid else { completion(Failure.configuration.localizedDescription); return }
        activeRequests += 1
        Task {
            defer { activeRequests -= 1 }
            do { try await perform(file, settings: settings, permissions: permissions); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    /// Awaitable form for dialog owners: capture settings at invocation and keep
    /// cancellation, permissions and error delivery in the originating workflow.
    static func openDocument(_ file: URL, settings: AlternativeEditorPreferences,
                             permissions: [RepositoryAccessLease], cancellation: OperationCancellation,
                             launch: ExternalDocumentApplication.Launch? = nil) async throws {
        activeRequests += 1; defer { activeRequests -= 1 }
        try await perform(file, settings: settings, permissions: permissions, cancellation: cancellation, launch: launch)
    }
    private static func perform(_ file: URL, settings: AlternativeEditorPreferences,
                                permissions: [RepositoryAccessLease], cancellation: OperationCancellation? = nil,
                                launch: ExternalDocumentApplication.Launch? = nil) async throws {
        try cancellation?.check()
        guard settings.valid else { throw Failure.configuration }
        let custom = settings.customApplication
        guard let application = custom ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { throw Failure.unavailable }
        var program = settings.program; program.applicationPath = application.path
        if custom == nil { program.bookmark = nil }
        try await ExternalDocumentApplication.open(file: file, program: program, arguments: [file.path], nativeDocumentOpen: true,
            permissions: permissions + GitConfigurationPermissions.retained(for: file), cancellation: cancellation,
            requiresProgramScope: custom != nil, launch: launch)
    }

}

struct AlternativeEditorSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var initialized = false
    @State private var presented = false
    @State private var presentation = UUID()
    private let preferences: UserDefaults
    @StateObject private var chooser = ToolApplicationChooser()
    @State private var draft: AlternativeEditorPreferences
    @State private var saved: AlternativeEditorPreferences
    init(preferences: UserDefaults = .standard, chooser:ToolApplicationChooser? = nil) {
        self.preferences = preferences
        _chooser=StateObject(wrappedValue:chooser ?? ToolApplicationChooser())
        let value = AlternativeEditorPreferences.load(from:preferences)
        _draft = State(initialValue:value); _saved = State(initialValue:value)
    }
    @State private var error: String?
    var body: some View {
        let receipt=presentation
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Alternative editor") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Editor", selection: Binding(get:{draft.custom},set:{value in
                        guard presented,presentation==receipt,!chooser.selecting else{return};draft.custom=value
                    })) {
                        Text("TextEdit").tag(false)
                        Text("Custom").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    HStack {
                        ToolLiteralTextField(text: Binding(get: { draft.applicationPath }, set: {
                            guard presented,presentation==receipt,draft.custom,!chooser.selecting,
                                  !$0.utf8.elementsEqual(draft.applicationPath.utf8) else { return }
                            draft.applicationPath = $0; draft.bookmark = nil
                        }),label:"Editor application",placeholder:"Editor application",mayEdit:{presented && presentation==receipt && draft.custom && !chooser.selecting}).id(receipt).frame(height:24)
                        Button("Browse…") {browse(receipt:receipt)}.id(receipt)
                    }.disabled(!draft.custom)
                    if !draft.valid { Text("Choose an application bundle or executable using its full path.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("The editor command opens working files in TextEdit or your chosen app/executable. Open uses the file’s default application; Open With lets you choose an application once.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if transaction == nil { HStack {
                Spacer()
                Button("Cancel") { guard presented,presentation==receipt else{return};cancelDraft(); chooser.window?.performClose(nil) }
                Button("Apply") { guard presented,presentation==receipt,!chooser.selecting,draft.valid else{return};draft.save(to:preferences); saved = draft }.disabled(!draft.valid || draft == saved)
            } }
        }.padding(20).disabled(!presented || chooser.selecting).background(ToolChooserProbe(chooser:chooser).frame(width:0,height:0)).onDisappear { presented=false;presentation=UUID();chooser.cancel() }.onAppear {
            presentation=UUID();presented=true
            if !initialized { initialized = true; saved = .load(from:preferences); draft = saved }
        }
            .settingsParticipant("alternativeEditor", page: .alternativeEditor, value: draft,
                modified: { draft != saved }, validate: { draft.valid ? nil : "Choose an editor application or executable." },
                apply: { draft.save(to:preferences); saved = draft; return true }, cancel: cancelDraft)
            .alert("Alternative editor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func cancelDraft() {
        presentation=UUID();chooser.cancel();draft=saved;error=nil
    }
    private func browse(receipt:UUID) {
        guard presented,presentation==receipt,draft.custom,!chooser.selecting else{return}
        let captured=draft
        chooser.choose({ application, bookmark in draft.applicationPath = application.path; draft.bookmark = bookmark },failure:{ error = $0 }, allowExecutables: true,currentPath:captured.applicationPath,isCurrent:{presented && presentation==receipt && draft == captured && draft.custom})
    }
}
