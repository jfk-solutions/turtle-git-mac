import SwiftUI
import AppKit
import TurtleGitCore

extension Notification.Name {
    static let mergeEditorPreferencesChanged = Notification.Name("TurtleGitMerge.PreferencesChanged")
}

/// Coherent native draft for SetMainPage and the owned comment-profile editor.
@MainActor final class MergeEditorSettingsModel: ObservableObject {
    static private(set) var activeProfileEditors = 0
    let preferences: UserDefaults
    let profileURL: URL
    @Published var general = MergeGeneralPreferences.load()
    @Published var fontSize = "10"
    @Published var maximumInline = "3000"
    @Published var tabSize = "4"
    @Published var patchContext = "-1"
    @Published var legacyEncoding = ComparisonTextEncoding.windows1252
    @Published var preferUTF8 = false
    @Published var onePaneDefault = false
    @Published var backupOriginal = true
    @Published var editor = MergeEditorPreferences.load()
    @Published var comparison = MergeComparisonOptions.load()
    @Published var locator = MergeLocatorPreferences.load()
    @Published var whitespaceDisplay = MergeWhitespaceDisplayPreferences.load()
    @Published var profileText = ""
    private var savedProfileText = ""
    @Published private(set) var profileError: String?
    @Published private(set) var error: String?
    @Published private(set) var active = true
    @Published private(set) var revision = UUID()
    private var retired = false
    private(set) weak var window: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    struct EditContext: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var editContext: EditContext { .init(owner: ObjectIdentifier(self), revision: revision) }
    struct ProfileSession: Identifiable { let id = UUID(); let original: Data; var text: String }
    @Published private(set) var profileSession: ProfileSession?
    var readProfiles: (URL) throws -> String = { try MergeCommentProfileFile.text(at: $0) }
    var saveProfiles: (String, URL, String) throws -> Void = { try MergeCommentProfileFile.save($0, at: $1, expected: $2) }
    init(defaults: UserDefaults = .standard, commentProfileURL: URL = MergeCommentProfileFile.url) {
        preferences = defaults; profileURL = commentProfileURL; restore()
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func attach(to owner: NSWindow?) {
        guard !retired else { return }
        guard let owner else { setActive(false); return }
        guard window !== owner else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        window = owner; revision = UUID(); setActive(true)
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.cancelProfiles(); self.active = false; self.retired = true; self.revision = UUID() }
        }
    }
    func setActive(_ value: Bool) {
        guard !retired, active != value else { return }; active = value; revision = UUID()
        if !value { cancelProfiles() }
    }
    private func accepts(_ context: EditContext) -> Bool { !retired && active && profileSession == nil && context == editContext }
    func binding<Value>(_ key: ReferenceWritableKeyPath<MergeEditorSettingsModel, Value>) -> Binding<Value> {
        let context = editContext
        return Binding(get: { self[keyPath: key] }, set: { if self.accepts(context) { self[keyPath: key] = $0 } })
    }
    func editTabSize(_ value: Int, context: EditContext) { guard accepts(context) else { return }; tabSize = String(value) }
    var validWidth: Int? { Int(tabSize).flatMap { (1...1000).contains($0) ? $0 : nil } }
    var validFontSize: Int? { Int(fontSize).flatMap { (6...72).contains($0) ? $0 : nil } }
    var validInlineLength: Int? { Int(maximumInline).flatMap { (0...100_000).contains($0) ? $0 : nil } }
    var generalDraft: MergeGeneralPreferences {
        .init(fontName: general.fontName, fontSize: validFontSize ?? general.fontSize, maximumInlineLength: validInlineLength ?? general.maximumInlineLength, firstDifference: general.firstDifference, firstConflict: general.firstConflict)
    }
    struct State: Equatable {
        let general: MergeGeneralPreferences, editor: MergeEditorPreferences, comparison: MergeComparisonOptions, locator: MergeLocatorPreferences, whitespace: MergeWhitespaceDisplayPreferences
        let fontSize: String, maximumInline: String, tabSize: String, patchContext: String
        let legacyEncoding: ComparisonTextEncoding
        let utf8: Bool, onePane: Bool, backup: Bool, profiles: Data
    }
    var state: State { .init(general: general, editor: editor, comparison: comparison, locator: locator, whitespace: whitespaceDisplay, fontSize: fontSize, maximumInline: maximumInline, tabSize: tabSize, patchContext: patchContext, legacyEncoding:legacyEncoding, utf8: preferUTF8, onePane: onePaneDefault, backup: backupOriginal, profiles: Data(profileText.utf8)) }
    var changed: Bool {
        guard let width = validWidth, validFontSize != nil, validInlineLength != nil else { return true }
        return MergeEditorPreferences(tabWidth: width, useSpaces: editor.useSpaces, smartTab: editor.smartTab, showLineNumbers: editor.showLineNumbers, enableEditorConfig: editor.enableEditorConfig, autoAdd: editor.autoAdd) != .load(from: preferences) || generalDraft != .load(from: preferences) || comparison != .load(from: preferences) || locator != .load(from: preferences) || whitespaceDisplay != .load(from: preferences) || backupOriginal != MergeFileSaveOptions.backupEnabled(from: preferences) || MergeUnifiedPatch.validatedContext(patchContext) != MergeUnifiedPatch.contextLines(from: preferences) || legacyEncoding != ComparisonTextEncoding.legacyEncoding(from:preferences) || preferUTF8 != ComparisonTextEncoding.preferUTF8(from: preferences) || onePaneDefault != OnePaneFileComparison.defaultEnabled(from: preferences) || !profileText.utf8.elementsEqual(savedProfileText.utf8)
    }
    var validationError: String? {
        if legacyEncoding.legacyCodePage == nil { return "Choose a supported legacy text encoding." }
        if profileSession != nil { return "Finish editing Comment Profiles before applying settings." }
        if MergeUnifiedPatch.validatedContext(patchContext) == nil { return "Enter patch context lines from -1 (Git default) to 1000." }
        if validWidth == nil { return "Enter a tab size from 1 to 1000." }
        if validFontSize == nil { return "Enter a font size from 6 to 72 points." }
        if validInlineLength == nil { return "Enter an inline-diff line length from 0 to 100000." }
        if let profileError { return profileError }
        do { try MergeCommentProfileFile.validate(profileText); return nil } catch { return error.localizedDescription }
    }
    func openProfiles(context: EditContext) {
        guard accepts(context), profileError == nil, let window, window.attachedSheet == nil else { return }
        profileSession = .init(original: Data(profileText.utf8), text: profileText); revision = UUID(); Self.activeProfileEditors += 1
    }
    func profileBinding(_ session: ProfileSession) -> Binding<String> {
        Binding(get: { self.profileSession?.id == session.id ? self.profileSession!.text : session.text }, set: {
            guard !self.retired, self.active, self.profileSession?.id == session.id else { return }; self.profileSession?.text = $0
        })
    }
    var sheetValidationError: String? {
        guard let session = profileSession else { return nil }
        if session.original != Data(profileText.utf8) { return "The profile draft changed. Cancel and reopen Comment Profiles." }
        do { try MergeCommentProfileFile.validate(session.text); return nil } catch { return error.localizedDescription }
    }
    func restoreProfiles(_ session: ProfileSession) { guard !retired, active, profileSession?.id == session.id else { return }; profileSession?.text = MergeCommentProfiles.bundledText() }
    func cancelProfiles(_ session: ProfileSession? = nil) {
        guard let current = profileSession, session == nil || current.id == session?.id else { return }
        profileSession = nil; Self.activeProfileEditors -= 1; revision = UUID()
    }
    func acceptProfiles(_ session: ProfileSession) {
        guard !retired, active, profileSession?.id == session.id, sheetValidationError == nil else { return }
        profileText = profileSession!.text; cancelProfiles(session)
    }
    func reloadProfiles(context: EditContext) {
        guard accepts(context) else { return }
        do { let text = try readProfiles(profileURL); profileText = text; savedProfileText = text; profileError = nil; error = nil; revision = UUID() }
        catch { profileError = error.localizedDescription }
    }
    func restore() {
        guard !retired else { return }; cancelProfiles(); revision = UUID()
        legacyEncoding = ComparisonTextEncoding.legacyEncoding(from:preferences)
        preferUTF8 = ComparisonTextEncoding.preferUTF8(from: preferences); onePaneDefault = OnePaneFileComparison.defaultEnabled(from: preferences)
        patchContext = String(MergeUnifiedPatch.contextLines(from: preferences)); general = .load(from: preferences)
        fontSize = String(general.fontSize); maximumInline = String(general.maximumInlineLength)
        editor = .load(from: preferences); comparison = .load(from: preferences); locator = .load(from: preferences); whitespaceDisplay = .load(from: preferences); tabSize = String(editor.tabWidth)
        backupOriginal = MergeFileSaveOptions.backupEnabled(from: preferences); error = nil
        do { let text = try readProfiles(profileURL); profileText = text; savedProfileText = text; profileError = nil } catch { profileError = error.localizedDescription }
    }
    func apply() -> Bool {
        guard !retired, let width = validWidth, validationError == nil else { return false }
        let captured = state, profiles = profileText, preparedGeneral = generalDraft
        var preparedEditor = editor; preparedEditor.tabWidth = width
        do {
            if !profiles.utf8.elementsEqual(savedProfileText.utf8) { try saveProfiles(profiles, profileURL, savedProfileText) }
            guard !retired, state == captured else { error = "The settings context changed. Review the draft before applying again."; return false }
            savedProfileText = profiles
        } catch { self.error = "Comment profiles were not saved: " + error.localizedDescription; return false }
        preferences.set(Int(captured.legacyEncoding.legacyCodePage!),forKey:"TurtleGitMerge.LegacyCodePage")
        preferences.set(captured.utf8, forKey: "TurtleGitMerge.UseUTF8"); preferences.set(captured.onePane, forKey: "TurtleGitMerge.OnePane")
        preferences.set(MergeUnifiedPatch.validatedContext(captured.patchContext)!, forKey: "TurtleGitMerge.ContextLines")
        preparedGeneral.save(to: preferences); preparedEditor.save(to: preferences); captured.comparison.save(to: preferences); captured.locator.save(to: preferences); captured.whitespace.save(to: preferences)
        MergeFileSaveOptions.saveBackupPreference(captured.backup, to: preferences)
        general = preparedGeneral; editor = preparedEditor; error = nil; revision = UUID()
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true
    }
}

@MainActor struct MergeEditorSettings: View {
    @StateObject private var model: MergeEditorSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    init(defaults: UserDefaults = .standard, commentProfileURL: URL = MergeCommentProfileFile.url, model: MergeEditorSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? MergeEditorSettingsModel(defaults: defaults, commentProfileURL: commentProfileURL))
    }
    var body: some View {
        let context = model.editContext
        return VStack(alignment: .leading, spacing: 16) {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
            GroupBox("Misc") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Backup original file", isOn: model.binding(\.backupOriginal))
                    Toggle("Jump to first difference when loading", isOn: model.binding(\.general.firstDifference))
                    Toggle("Jump to first conflict when loading", isOn: model.binding(\.general.firstConflict)).padding(.leading, 12).disabled(!model.general.firstDifference)
                    Picker("Legacy text encoding",selection:model.binding(\.legacyEncoding)) {
                        ForEach(ComparisonTextEncoding.legacyChoices,id:\.self) { value in Text(value.legacyName).tag(value) }
                    }.help("Encoding used for non-Unicode files detected as ASCII/ANSI. Reload open files to apply a changed default.")
                    NativeMergeUTF8DefaultChoice(value: model.binding(\.preferUTF8)).frame(height: 24)
                    Toggle("Use one-pane view as default for 2-file diff", isOn: model.binding(\.onePaneDefault))
                    Toggle("Show line numbers", isOn: model.binding(\.editor.showLineNumbers))
                    Toggle("Add new files automatically to Git", isOn: model.binding(\.editor.autoAdd))
                    HStack {
                        Toggle("Use spaces", isOn: model.binding(\.editor.useSpaces))
                        Spacer()
                        Toggle("Smart tab char", isOn: model.binding(\.editor.smartTab))
                    }
                    HStack {
                        Text("Tab size:")
                        TextField("Tab size", text: model.binding(\.tabSize)).frame(width: 65)
                        Stepper("", value: Binding(get: { model.validWidth ?? model.editor.tabWidth }, set: { model.editTabSize($0, context: context) }), in: 1...1000).labelsHidden()
                        Spacer()
                        Toggle("Enable EditorConfig", isOn: model.binding(\.editor.enableEditorConfig))
                    }
                    HStack {
                        Text("Font:"); NativeFixedFontChoice(value: model.binding(\.general.fontName)).frame(height: 24)
                        NativeFontSizeChoice(value: model.binding(\.fontSize)).frame(width: 75, height: 24)
                    }
                }.padding(8)
            }
            GroupBox("Diffing") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Max line length for inline diffs:")
                        TextField("Max line length", text: model.binding(\.maximumInline)).frame(width: 90)
                        Spacer()
                    }
                    if model.validFontSize == nil || model.validInlineLength == nil { Text(model.validationError ?? "").font(.caption).foregroundStyle(.red) }
                    Toggle("Ignore line endings (recommended)", isOn: model.binding(\.comparison.ignoreEndings))
                    Toggle("Ignore case changes", isOn: model.binding(\.comparison.ignoreCase))
                    HStack {
                        Text("Context lines for patches:")
                        NativePatchContextField(value: model.binding(\.patchContext)).frame(width: 90, height: 24)
                        Text("-1 uses Git’s default").font(.caption).foregroundStyle(.secondary)
                    }
                    if MergeUnifiedPatch.validatedContext(model.patchContext) == nil { Text(model.validationError ?? "").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            GroupBox("Additional comparison and view options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Whitespaces", isOn: model.binding(\.whitespaceDisplay.visible))
                    Toggle("Use icons for CR, LF and CRLF", isOn: model.binding(\.whitespaceDisplay.endingIcons))
                    Toggle("Show locator bar", isOn: model.binding(\.locator.visible))
                    Toggle("Use fish-eye in locator bar", isOn: model.binding(\.locator.fishEye))
                    Picker("Whitespace comparison:", selection: model.binding(\.comparison.whitespace)) {
                        ForEach(MergeWhitespaceComparison.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Toggle("Ignore comments", isOn: model.binding(\.comparison.ignoreComments))
                        Spacer()
                        Button("Edit Comment Profiles…") { model.openProfiles(context: context) }
                            .disabled(model.profileError != nil)
                    }
                    Text("Custom profiles replace the built-in extension list. Open comparisons use them on reload.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let profileError = model.profileError { Text(profileError).font(.caption).foregroundStyle(.red) }
                    if model.validWidth == nil { Text("Enter a tab size from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Apply indentation defaults to open panes and new windows. Enable EditorConfig sets the default for new windows; open panes retain their individual toggles.")
                .font(.caption).foregroundStyle(.secondary)
            } }
            if let message = model.error { Text(message).font(.caption).foregroundStyle(.red) }
            if model.profileError != nil || model.error != nil {
                Button("Reload Profiles") { model.reloadProfiles(context: context) }.help("Reload profiles from disk and discard the profile draft.")
            }
            if transaction == nil { HStack {
                Spacer()
                Button("Cancel") { model.restore(); model.window?.performClose(nil) }
                Button("Apply") { _ = model.apply() }.disabled(!model.changed || model.validationError != nil)
            } }
        }.padding(20).disabled(!model.active || model.profileSession != nil)
        .background(MergeEditorOwnerProbe(model: model).frame(width: 0, height: 0))
        .onAppear { model.setActive(true) }.onDisappear { model.setActive(false) }
        .sheet(item: Binding(get: { model.profileSession }, set: { if $0 == nil { model.cancelProfiles() } })) { session in
            VStack(alignment: .leading, spacing: 12) {
                Text("Comment Profiles").font(.headline)
                Text("One definition per line: extensions=line marker,block start,block end. Separate extensions with commas. Spaces in markers are significant.")
                TextEditor(text: model.profileBinding(session)).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.4))
                Text("Example: swift=//,/*,*/     SQL uses a space after --.").font(.caption).foregroundStyle(.secondary)
                if let message = model.sheetValidationError { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Restore Defaults") { model.restoreProfiles(session) }
                    Spacer()
                    Button("Cancel") { model.cancelProfiles(session) }.keyboardShortcut(.cancelAction)
                    Button("OK") { model.acceptProfiles(session) }.keyboardShortcut(.defaultAction).disabled(model.sheetValidationError != nil)
                }
            }.padding(20).frame(width: 740, height: 480).environment(\.isEnabled, model.active)
        }
        .settingsParticipant("mergeEditor", page: .mergeEditor, value: model.state,
            modified: { model.changed }, validate: { model.validationError }, apply: { model.apply() }, cancel: { model.restore() })
    }
}
private struct MergeEditorOwnerProbe: NSViewRepresentable {
    let model: MergeEditorSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.model?.attach(to: nil); view.model = nil }
    final class Probe: NSView {
        weak var model: MergeEditorSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to: window) }
    }
}

/// SetColorPage keeps both palettes as drafts until Apply.
@MainActor final class MergeColorsSettingsModel: ObservableObject {
    let preferences: UserDefaults
    @Published private(set) var draft: MergeColorPreferences
    @Published var dark: Bool { didSet { if oldValue != dark { editRevision = UUID() } } }
    @Published private(set) var active = true
    @Published private(set) var editRevision = UUID()
    private var retired = false
    private weak var ownerWindow: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    struct EditContext: Equatable {
        let owner: ObjectIdentifier
        let revision: UUID
        let dark: Bool
        var identity: String { revision.uuidString + (dark ? ".dark" : ".light") }
    }
    var editContext: EditContext { .init(owner: ObjectIdentifier(self), revision: editRevision, dark: dark) }
    func accepts(_ context: EditContext) -> Bool { !retired && active && context == editContext }
    func setActive(_ value: Bool) { guard !retired, active != value else { return }; active = value; editRevision = UUID() }
    func attach(to window: NSWindow?) {
        guard !retired, ownerWindow !== window else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
        ownerWindow = window; editRevision = UUID(); setActive(window != nil)
        if let window {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.active = false; self.retired = true; self.editRevision = UUID() }
            }
        }
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func selectPalette(_ value: Bool, context: EditContext) { guard accepts(context) else { return }; dark = value }
    @Published private(set) var error: String?
    init(preferences: UserDefaults = .standard, dark: Bool? = nil) {
        self.preferences = preferences; draft = .load(from: preferences)
        self.dark = dark ?? (NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    var changed: Bool { draft != .load(from: preferences) }
    func color(_ role: MergeColorRole, foreground: Bool) -> UInt32 {
        let colors = draft.colors(role, dark: dark)
        return foreground ? colors.foreground : colors.background
    }
    func automatic(_ role: MergeColorRole, foreground: Bool) -> UInt32 {
        let colors = MergeColorPreferences.standard(role, dark: dark)
        return foreground ? colors.foreground : colors.background
    }
    func setColor(_ value: UInt32, role: MergeColorRole, foreground: Bool) { setColor(value, role: role, foreground: foreground, context: editContext) }
    func setColor(_ value: UInt32, role: MergeColorRole, foreground: Bool, context: EditContext) {
        guard accepts(context), value <= 0xffffff, foreground ? role.supportsForeground : role.supportsBackground else { return }
        var colors = draft.colors(role, dark: dark)
        if foreground { colors.foreground = value } else { colors.background = value }
        if dark { draft.dark[role] = colors } else { draft.light[role] = colors }
        error = nil
    }
    func restoreDefault() { restoreDefault(context: editContext) }
    func restoreDefault(context: EditContext) { guard accepts(context) else { return }; draft.restore(dark: dark); editRevision = UUID(); error = nil }
    func discard() { draft = .load(from: preferences); editRevision = UUID(); error = nil }
    func apply() -> Bool {
        guard !retired else { return false }
        do {
            try draft.save(to: preferences); editRevision = UUID(); MergePalette.reload(defaults: preferences)
            NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil)
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

@MainActor struct MergeColorsSettings: View {
    @StateObject private var model: MergeColorsSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    private let rows: [MergeColorRole] = [.normal, .added, .removed, .modified, .conflicted, .resolved, .empty, .filtered]
    init(model: MergeColorsSettingsModel? = nil) { _model = StateObject(wrappedValue: model ?? MergeColorsSettingsModel()) }
    private func swatch(_ role: MergeColorRole, foreground: Bool) -> some View {
        let context = model.editContext
        return NativeSettingsColorChoice(value: model.color(role, foreground: foreground), automatic: model.automatic(role, foreground: foreground), contextIdentity: context.identity,
            label: ([MergeColorRole.inlineAdded, .inlineRemoved].contains(role) ? "Inline " : "") + role.title + (foreground ? " foreground" : " background"), identifier: role.rawValue + (foreground ? ".foreground" : ".background"),
            changed: { model.setColor($0, role: role, foreground: foreground, context: context) })
            .frame(width: 76, height: 26)
    }
    private func row(_ role: MergeColorRole) -> some View {
        HStack {
            Text(role.title).frame(width: 140, alignment: .leading)
            HStack { if role.supportsForeground { swatch(role, foreground: true) } }.frame(maxWidth: .infinity)
            HStack { if role.supportsBackground { swatch(role, foreground: false) } }.frame(maxWidth: .infinity)
        }
    }
    var body: some View {
        let context = model.editContext
        return ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack { Text(" ").frame(width: 140); Text("Foreground").frame(maxWidth: .infinity); Text("Background").frame(maxWidth: .infinity) }
            GroupBox("Line differences") { VStack(spacing: 10) { ForEach(rows, id: \.self) { row($0) } }.padding(8) }
            GroupBox("Inline differences") { VStack(spacing: 10) { row(.inlineAdded); row(.inlineRemoved) }.padding(8) }
            GroupBox("Misc") { row(.whitespace).padding(8) }
            HStack {
                Text("Palette to edit:")
                NativeSettingsPaletteChoice(dark: Binding(get: { model.dark }, set: { model.selectPalette($0, context: context) })).frame(width: 150, height: 26)
                Spacer()
                Button("Restore Default") { model.restoreDefault(context: context) }
            }
            Text("Use each swatch’s menu for Automatic or More colors. Apply updates open merge panes, locator stripes and whitespace markers. App appearance is controlled in General.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if transaction == nil { HStack { Spacer(); Button("Cancel") { model.discard() }; Button("Apply") { _ = model.apply() }.disabled(!model.changed) } }
        }.padding(20).disabled(!model.active) }
        .background(MergeColorsOwnerProbe(model: model).frame(width: 0, height: 0))
        .onAppear { model.setActive(true) }.onDisappear { model.setActive(false) }
        .settingsParticipant("mergeColors", page: .mergeColors, value: model.draft, modified: { model.changed }, apply: { model.apply() }, cancel: { model.discard() })
    }
}

private struct MergeColorsOwnerProbe: NSViewRepresentable {
    let model: MergeColorsSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.model?.attach(to: nil); view.model = nil }
    final class Probe: NSView {
        weak var model: MergeColorsSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to: window) }
    }
}

struct NativeSettingsPaletteChoice: NSViewRepresentable {
    @Binding var dark: Bool
    var identifier = "MergeColors.Palette"
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.identifier = NSUserInterfaceItemIdentifier(identifier); control.setAccessibilityLabel("Palette to edit")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) { guard !context.coordinator.retired else { return }; context.coordinator.binding = $dark; control.selectedSegment = dark ? 1 : 0; control.isEnabled = enabled }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $dark) }
    static func dismantleNSView(_ control: NSSegmentedControl, coordinator: Coordinator) { coordinator.retired = true; control.target = nil; control.isEnabled = false }
    final class Coordinator: NSObject {
        var retired = false
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func choose(_ control: NSSegmentedControl) { guard !retired, control.isEnabled, control.window != nil, (0...1).contains(control.selectedSegment) else { return }; binding.wrappedValue = control.selectedSegment == 1 }
    }
}

/// Source color-button behavior shared by the native settings pages.
struct NativeSettingsColorChoice: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    var namespace = "MergeColors"
    let value: UInt32, automatic: UInt32
    var contextIdentity: String? = nil
    let label: String, identifier: String
    let changed: (UInt32) -> Void
    func makeNSView(context: Context) -> MergeColorChoiceView { MergeColorChoiceView() }
    func updateNSView(_ view: MergeColorChoiceView, context: Context) {
        view.configure(value:value, automatic:automatic, label:label, identifier:identifier, namespace:namespace, enabled:enabled, contextIdentity:contextIdentity, changed:changed)
    }
    static func dismantleNSView(_ view: MergeColorChoiceView, coordinator: ()) { view.retire() }
}

enum SettingsColorValue {
    static func packed(_ rgb:[Int]) -> UInt32 {
        UInt32(rgb[0]) << 16 | UInt32(rgb[1]) << 8 | UInt32(rgb[2])
    }
    static func channels(_ rgb:UInt32) -> [Int] { [Int(rgb >> 16 & 255),Int(rgb >> 8 & 255),Int(rgb & 255)] }
}

/// A native color well plus the source Automatic/More colors dropdown.
@MainActor final class MergeColorChoiceView: NSView, NSMenuDelegate {
    let well = MergeSettingsColorWell()
    let arrow = NSButton()
    let choices = NSMenu()
    private var automatic: UInt32 = 0
    private var changed: ((UInt32) -> Void)?
    private var ownerObserver: NSObjectProtocol?
    private var retired = false
    private var enabled = true
    private var contextIdentity: String?
    private var configuredValue: UInt32?
    private var generation = UUID()
    private final class MenuChoice: NSObject {
        let generation: UUID
        let automatic: UInt32
        var used = false
        init(generation: UUID, automatic: UInt32) { self.generation = generation; self.automatic = automatic }
    }
    var presentPanel: (NSColorPanel) -> Void = { $0.orderFront(nil) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        well.target = self; well.action = #selector(colorChanged(_:))
        arrow.title = "▾"; arrow.bezelStyle = .rounded; arrow.target = self; arrow.action = #selector(showChoices(_:))
        addSubview(well); addSubview(arrow)
        choices.delegate = self; rebuildChoices()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout(); well.frame = NSRect(x: 0, y: 1, width: max(0, bounds.width - 20), height: bounds.height - 2)
        arrow.frame = NSRect(x: bounds.width - 20, y: 0, width: 20, height: bounds.height)
    }
    private static func color(_ rgb: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    func configure(value: UInt32, automatic: UInt32, label: String, identifier: String, namespace:String = "MergeColors", enabled:Bool = true, contextIdentity:String? = nil, changed: @escaping (UInt32) -> Void) {
        guard !retired else { return }
        let identity = namespace + "." + identifier + "." + (contextIdentity ?? "default")
        let contextChanged = self.contextIdentity != identity
        let choicesChanged = contextChanged || configuredValue != value || self.automatic != automatic || self.enabled != enabled
        if contextChanged { choices.cancelTracking(); closeOwnedPanel() }
        self.contextIdentity = identity; configuredValue = value
        self.enabled = enabled
        if !enabled { choices.cancelTracking(); closeOwnedPanel() }
        well.isEnabled = enabled; arrow.isEnabled = enabled
        self.automatic = automatic; self.changed = changed
        self.identifier = NSUserInterfaceItemIdentifier(namespace + "." + identifier)
        well.color = Self.color(value); well.setAccessibilityLabel(label)
        well.identifier = NSUserInterfaceItemIdentifier(namespace + "." + identifier + ".well")
        arrow.identifier = NSUserInterfaceItemIdentifier(namespace + "." + identifier + ".choices")
        arrow.setAccessibilityLabel(label + " choices"); choices.title = label
        if choicesChanged { generation = UUID(); rebuildChoices() }
    }
    private func rebuildChoices() {
        choices.removeAllItems()
        let automaticItem = NSMenuItem(title: "Automatic", action: #selector(useAutomatic(_:)), keyEquivalent: "")
        automaticItem.target = self; automaticItem.representedObject = MenuChoice(generation: generation, automatic: automatic)
        automaticItem.state = configuredValue == automatic ? .on : .off
        automaticItem.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { [automatic] rect in Self.color(automatic).setFill(); rect.fill(); return true }
        choices.addItem(automaticItem); choices.addItem(.separator())
        let custom = NSMenuItem(title: "More colors…", action: #selector(moreColors(_:)), keyEquivalent: "")
        custom.target = self; custom.representedObject = MenuChoice(generation: generation, automatic: automatic); choices.addItem(custom)
    }
    func menuNeedsUpdate(_ menu: NSMenu) { guard menu === choices, enabled, !retired else { return }; generation = UUID(); rebuildChoices() }
    private func take(_ sender: Any?) -> MenuChoice? {
        guard enabled, !retired, window != nil, let item = sender as? NSMenuItem,
              let request = item.representedObject as? MenuChoice, request.generation == generation, !request.used else { return nil }
        request.used = true; return request
    }
    @objc private func colorChanged(_ sender: Any?) {
        guard enabled, !retired, window != nil, let changed, let color = well.color.usingColorSpace(.sRGB) else { return }
        func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, Int((value * 255).rounded())))) }
        let rgb = channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        well.color = Self.color(rgb); changed(rgb)
    }
    @objc private func useAutomatic(_ sender: Any?) { guard let request = take(sender), let changed else { return }; well.color = Self.color(request.automatic); changed(request.automatic) }
    @objc private func moreColors(_ sender: Any?) { guard take(sender) != nil, changed != nil else { return }; well.activate(true); presentPanel(.shared) }
    @objc private func showChoices(_ sender: Any?) { guard enabled, !retired, window != nil, changed != nil else { return }; choices.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY), in: self) }
    private func closeOwnedPanel() { if well.isActive { well.deactivate(); NSColorPanel.shared.orderOut(nil) } }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if window !== newWindow { choices.cancelTracking(); closeOwnedPanel() }; super.viewWillMove(toWindow: newWindow) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
        if !retired, let window {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retire() }
            }
        }
    }
    func retire() {
        retired = true; generation = UUID(); choices.cancelTracking(); closeOwnedPanel(); changed = nil; choices.delegate = nil
        well.target = nil; arrow.target = nil; well.isEnabled = false; arrow.isEnabled = false
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
}

@MainActor final class MergeSettingsColorWell: NSColorWell {
    private var previousAlpha: Bool?
    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        if previousAlpha == nil { previousAlpha = NSColorPanel.shared.showsAlpha }
        NSColorPanel.shared.showsAlpha = false
    }
    override func deactivate() {
        let active = isActive; super.deactivate()
        if active, let previousAlpha { NSColorPanel.shared.showsAlpha = previousAlpha }
        previousAlpha = nil
    }
}

/// Native edit control keeps source signed context values and stable accessibility.
private struct NativePatchContextField: NSViewRepresentable {
    @Binding var value: String
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value); field.identifier = NSUserInterfaceItemIdentifier("MergePatchContext")
        field.setAccessibilityIdentifier("MergePatchContext"); field.setAccessibilityLabel("Context lines for patches")
        field.placeholderString = "-1…1000"; field.delegate = context.coordinator; return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        guard !context.coordinator.retired else { return }
        field.isEnabled = enabled; context.coordinator.binding = $value
        if field.stringValue != value { field.stringValue = value }
    }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.retired = true; field.delegate = nil; field.isEnabled = false }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var retired = false
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func controlTextDidChange(_ notification: Notification) {
            if !retired, let field = notification.object as? NSTextField, field.isEnabled, field.window != nil { binding.wrappedValue = field.stringValue }
        }
    }
}

private struct NativeMergeUTF8DefaultChoice: NSViewRepresentable {
    @Binding var value: Bool
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Default to UTF-8 encoding", target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("MergeUTF8Default"); button.setAccessibilityIdentifier("MergeUTF8Default")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { guard !context.coordinator.retired else { return }; button.isEnabled = enabled; context.coordinator.binding = $value; button.state = value ? .on : .off }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.retired = true; button.target = nil; button.isEnabled = false }
    final class Coordinator: NSObject {
        var retired = false
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ button: NSButton) { guard !retired, button.isEnabled, button.window != nil else { return }; binding.wrappedValue = button.state == .on }
    }
}
