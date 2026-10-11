// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class GeneralGitSettingsModel: ObservableObject {
    @Published var draft = GitEnginePreferences.load() { didSet { if draft != oldValue { version = "" } } }
    @Published private(set) var busy = false
    @Published var version = ""
    @Published var error: String?
    private var saved = GitEnginePreferences.load()
    private var token: OperationCancellation?
    private var request = UUID()
    private var updateAlert: NSAlert?
    private var panel: NSOpenPanel?
    private var active = false
    weak var window: NSWindow?
    var modified: Bool { draft != saved }
    func activate() { active = true }
    func suspend() {
        active = false; request = UUID(); token?.cancel(); token = nil; busy = false
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        if let updateAlert { window?.endSheet(updateAlert.window, returnCode: .abort) }; updateAlert = nil
    }
    private func executable(_ settings: GitEnginePreferences) throws -> URL {
        if !GitRuntime.isAppStoreBuild, settings.choice == .custom {
            guard settings.valid else { throw GitRuntimeFailure.customGitInvalid }
            return try settings.selectedExecutable()
        }
        if !GitRuntime.isAppStoreBuild, settings.choice == .system { return URL(fileURLWithPath: "/usr/bin/git") }
        let suite = "TurtleGit.EngineCheck." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { throw GitRuntimeFailure.customGitInvalid }
        defer { preferences.removePersistentDomain(forName: suite) }
        return try GitRuntime.executable(preferences: preferences)
    }
    private func inspect(_ settings: GitEnginePreferences, cancellation: OperationCancellation?) async throws -> String {
        let engine = try executable(settings)
        let suite = "TurtleGit.EngineCheck." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { throw GitRuntimeFailure.customGitInvalid }
        defer { preferences.removePersistentDomain(forName: suite) }
        if !GitRuntime.isAppStoreBuild { try settings.save(to: preferences) }
        var environment = GitRuntime.environment(executable: engine, preferences: preferences)
        if environment["PATH"] == nil { environment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin" }
        let directory = try TurtleGitTemporaryStorage.root
        let repository = GitRepository(root: directory, executable: engine)
        let response = try await repository.run(["--version"], environmentOverrides: environment, cancellation: cancellation)
        let version = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("git version ") else { throw GitRuntimeFailure.customGitInvalid }
        return version
    }
    func check() {
        guard active, !busy else { return }
        let cancellation = OperationCancellation(), generation = UUID(), settings = draft
        token = cancellation; request = generation; busy = true; error = nil
        Task {
            defer { if request == generation { busy = false; token = nil } }
            do { let result = try await inspect(settings, cancellation: cancellation); if active, request == generation, !cancellation.isCancelled { version = result } }
            catch { if active, request == generation, !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func apply(validateUnchanged: Bool = false) async -> Bool {
        guard modified || validateUnchanged else { return true }
        guard !busy else { return false }
        let settings = draft
        do {
            version = try await inspect(settings, cancellation: nil)
            if !GitRuntime.isAppStoreBuild { try settings.save() }
            saved = settings; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancel() { draft = saved; error = nil }
    func confirmDisableUpdates(_ completion: @escaping () -> Void) {
        guard active, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Disable automatic update checks?"
        alert.informativeText = "You can still check manually using Check now."
        alert.addButton(withTitle: "Disable update checks"); alert.addButton(withTitle: "Abort")
        updateAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.active, self.updateAlert === alert else { return }; self.updateAlert = nil
            if response == .alertFirstButtonReturn { completion() }
        }
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
    }
    func browse() {
        guard active, !busy, !GitRuntime.isAppStoreBuild, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.title = "Select Git executable"; chooser.prompt = "Select Git"
        chooser.canChooseFiles = true; chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.directoryURL = URL(fileURLWithPath: draft.path.isEmpty ? "/usr/bin" : (draft.path as NSString).deletingLastPathComponent)
        panel = chooser
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === chooser else { return }; self.panel = nil
            guard response == .OK, self.active, let file = chooser.url else { return }
            do { self.draft.bookmark = try file.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); self.draft.path = file.path; self.draft.choice = .custom }
            catch { self.error = error.localizedDescription }
        }
    }
    func environment() -> String {
        var values = ProcessInfo.processInfo.environment
        if let engine = try? executable(draft) {
            let suite = "TurtleGit.Environment." + UUID().uuidString
            if let preferences = UserDefaults(suiteName: suite) {
                defer { preferences.removePersistentDomain(forName: suite) }
                if !GitRuntime.isAppStoreBuild { try? draft.save(to: preferences) }
                values.merge(GitRuntime.environment(executable: engine, preferences: preferences)) { _, runtime in runtime }
            }
        }
        values["GIT_TERMINAL_PROMPT"] = "0"; values["GIT_PAGER"] = "cat"; values["LC_ALL"] = "C"
        return values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "\n")
    }
}
struct GeneralSettings: View {
    @ObservedObject var appearance: SettingsAppearanceDraft
    @StateObject private var model = GeneralGitSettingsModel()
    @State private var environment: String?
    @State private var updates = ReleaseUpdateService.enabled
    @State private var savedUpdates = ReleaseUpdateService.enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("TurtleGit for Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Language:", selection: .constant("en")) { Text("English").tag("en") }
                    HStack {
                        Toggle("Automatically check for newer versions every week", isOn: Binding(get: { updates }, set: { enabled in
                            if enabled { updates = true } else { model.confirmDisableUpdates { updates = false } }
                        })).disabled(GitRuntime.isAppStoreBuild)
                        Spacer(); Button("Check now") { ReleaseUpdateService.shared.show() }
                    }
                    Button("Re-run First Start Wizard") { FirstStartWizardService.shared.show() }
                    Picker("Appearance:", selection: $appearance.choice) { ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) } }
                }.padding(10)
            }
            GroupBox("Git for macOS") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Git engine:", selection: Binding(get: { GitRuntime.isAppStoreBuild ? .automatic : model.draft.choice }, set: { model.draft.choice = $0 })) {
                        Text("Automatic (bundled when available)").tag(GitEngineChoice.automatic)
                        Text("System Git").tag(GitEngineChoice.system)
                        Text("Custom Git").tag(GitEngineChoice.custom)
                    }.disabled(GitRuntime.isAppStoreBuild || model.busy)
                    HStack {
                        Text("Git executable:")
                        TextField("/opt/homebrew/bin/git", text: Binding(get: { model.draft.path }, set: { model.draft.path = $0; model.draft.bookmark = nil }))
                        Button("Browse…", action: model.browse)
                    }.disabled(GitRuntime.isAppStoreBuild || model.draft.choice != .custom || model.busy)
                    TextField("Extra PATH:", text: $model.draft.extraPath).disabled(GitRuntime.isAppStoreBuild || model.busy)
                    HStack { Text("Version: " + model.version); Spacer(); Button("Check now", action: model.check).disabled(model.busy) }
                    Button("Show Environment Variables") { environment = model.environment() }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(10)
            }
            Text(GitRuntime.isAppStoreBuild ? "The App Store build uses the Git and SSH engines included in the app." : "Git engine changes apply to newly opened repositories and dialogs. Reopen the repository after changing the engine.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).background(GeneralSettingsProbe(model: model).frame(width: 0, height: 0))
        .onAppear { model.activate() }.onDisappear { model.suspend() }
        .settingsParticipant("general", page: .general, value: appearance.choice, modified: { appearance.changed }, apply: { appearance.apply(); return true }, cancel: appearance.cancel)
        .settingsParticipant("general.updates", page: .general, value: updates, modified: { updates != savedUpdates }, apply: { UserDefaults.standard.set(updates, forKey: "VersionCheck"); savedUpdates = updates; return true }, cancel: { updates = savedUpdates })
        .settingsParticipant("general.git", page: .general, value: model.draft, modified: { model.modified }, validate: { GitRuntime.isAppStoreBuild || model.draft.valid ? nil : "Choose a valid Git executable and absolute Extra PATH directories." }, apply: { await model.apply() }, cancel: model.cancel)
        .sheet(isPresented: Binding(get: { environment != nil }, set: { if !$0 { environment = nil } })) {
            VStack(alignment: .leading) {
                Text("Git Environment Variables").font(.headline)
                ScrollView([.vertical, .horizontal]) { Text(environment ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(8) }
                HStack { Spacer(); Button("Close") { environment = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 760, height: 500)
        }
    }
}
private struct GeneralSettingsProbe: NSViewRepresentable {
    let model: GeneralGitSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.window = view.window }
    final class Probe: NSView {
        weak var model: GeneralGitSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window }
    }
}
