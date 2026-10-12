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
    @State private var locator = MergeLocatorPreferences.load()
    @State private var backupOriginal = MergeFileSaveOptions.backupEnabled()
    @State private var tabSize = String(MergeEditorPreferences.load().tabWidth)
    @State private var profileText = ""
    @State private var savedProfileText = ""
    @State private var profileError: String?
    @State private var editingProfiles = false
    @State private var sheetProfileText = ""
    private var validWidth: Int? {
        guard let width = Int(tabSize), (1...1000).contains(width) else { return nil }
        return width
    }
    private var changed: Bool {
        guard let width = validWidth else { return true }
        return MergeEditorPreferences(tabWidth: width, useSpaces: draft.useSpaces, smartTab: draft.smartTab, showLineNumbers: draft.showLineNumbers, enableEditorConfig: draft.enableEditorConfig, autoAdd: draft.autoAdd) != .load() || comparison != .load() || locator != .load() || backupOriginal != MergeFileSaveOptions.backupEnabled() || profileText != savedProfileText
    }
    private var validationError: String? {
        if validWidth == nil { return "Enter a tab size from 1 to 1000." }
        if let profileError { return profileError }
        do { try MergeCommentProfileFile.validate(profileText); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Backup original file", isOn: $backupOriginal)
                    Toggle("Show line numbers", isOn: $draft.showLineNumbers)
                    Toggle("Show locator bar", isOn: $locator.visible)
                    Toggle("Use fish-eye in locator bar", isOn: $locator.fishEye)
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
                    HStack {
                        Toggle("Ignore comments", isOn: $comparison.ignoreComments)
                        Spacer()
                        Button("Edit Comment Profiles…") { sheetProfileText = profileText; editingProfiles = true }
                            .disabled(profileError != nil)
                    }
                    Text("Custom profiles replace the built-in extension list. Open comparisons use them on reload.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let profileError { Text(profileError).font(.caption).foregroundStyle(.red) }
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
                    _ = applyDraft()
                }.disabled(!changed || validationError != nil)
            } }
        }.padding(20).background(MergeSettingsWindowProbe(reference: windowReference).frame(width: 0, height: 0)).onAppear { if !initialized { initialized = true; restore() } }
        .onChange(of: tabSize) { _ in transaction?.notify() }
        .onChange(of: comparison) { _ in transaction?.notify() }
        .onChange(of: locator) { _ in transaction?.notify() }
        .onChange(of: backupOriginal) { _ in transaction?.notify() }
        .onChange(of: profileText) { _ in transaction?.notify() }
        .sheet(isPresented: $editingProfiles) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Comment Profiles").font(.headline)
                Text("One definition per line: extensions=line marker,block start,block end. Separate extensions with commas. Spaces in markers are significant.")
                TextEditor(text: $sheetProfileText).font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.4))
                Text("Example: swift=//,/*,*/     SQL uses a space after --.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = sheetValidationError { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Restore Defaults") { sheetProfileText = MergeCommentProfiles.bundledText() }
                    Spacer()
                    Button("Cancel") { editingProfiles = false }.keyboardShortcut(.cancelAction)
                    Button("OK") { profileText = sheetProfileText; editingProfiles = false }
                        .keyboardShortcut(.defaultAction).disabled(sheetValidationError != nil)
                }
            }.padding(20).frame(width: 740, height: 480)
        }
        .settingsParticipant("mergeEditor", page: .mergeEditor, value: draft,
            modified: { changed }, validate: { validationError },
            apply: { applyDraft() }, cancel: restore)
    }
    private func applyDraft() -> Bool {
        guard let width = validWidth, validationError == nil else { return false }
        do {
            if profileText != savedProfileText {
                try MergeCommentProfileFile.save(profileText, expected: savedProfileText)
                savedProfileText = profileText
            }
        } catch {
            // A failed write must not save the other preferences or notify open panes.
            let alert = NSAlert(); alert.messageText = "Comment profiles were not saved"
            alert.informativeText = error.localizedDescription; alert.runModal(); return false
        }
        draft.tabWidth = width; draft.save(); comparison.save(); locator.save()
        MergeFileSaveOptions.saveBackupPreference(backupOriginal)
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true
    }
    private var sheetValidationError: String? {
        do { try MergeCommentProfileFile.validate(sheetProfileText); return nil }
        catch { return error.localizedDescription }
    }
    private func restore() {
        draft = .load(); comparison = .load(); locator = .load(); tabSize = String(draft.tabWidth)
        backupOriginal = MergeFileSaveOptions.backupEnabled()
        do { profileText = try MergeCommentProfileFile.text(); savedProfileText = profileText; profileError = nil }
        catch { profileError = error.localizedDescription }
    }
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
