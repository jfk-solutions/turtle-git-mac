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
    @State private var general = MergeGeneralPreferences.load()
    @State private var fontSize = String(MergeGeneralPreferences.load().fontSize)
    @State private var maximumInline = String(MergeGeneralPreferences.load().maximumInlineLength)
    @State private var draft = MergeEditorPreferences.load()
    @State private var comparison = MergeComparisonOptions.load()
    @State private var locator = MergeLocatorPreferences.load()
    @State private var whitespaceDisplay = MergeWhitespaceDisplayPreferences.load()
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
    private var validFontSize: Int? { Int(fontSize).flatMap { (6...72).contains($0) ? $0 : nil } }
    private var validInlineLength: Int? { Int(maximumInline).flatMap { (0...100_000).contains($0) ? $0 : nil } }
    private var generalDraft: MergeGeneralPreferences {
        .init(fontName: general.fontName, fontSize: validFontSize ?? general.fontSize, maximumInlineLength: validInlineLength ?? general.maximumInlineLength,
              firstDifference: general.firstDifference, firstConflict: general.firstConflict)
    }
    private var changed: Bool {
        guard let width = validWidth, validFontSize != nil, validInlineLength != nil else { return true }
        return MergeEditorPreferences(tabWidth: width, useSpaces: draft.useSpaces, smartTab: draft.smartTab, showLineNumbers: draft.showLineNumbers, enableEditorConfig: draft.enableEditorConfig, autoAdd: draft.autoAdd) != .load() || generalDraft != .load() || comparison != .load() || locator != .load() || whitespaceDisplay != .load() || backupOriginal != MergeFileSaveOptions.backupEnabled() || profileText != savedProfileText
    }
    private var validationError: String? {
        if validWidth == nil { return "Enter a tab size from 1 to 1000." }
        if validFontSize == nil { return "Enter a font size from 6 to 72 points." }
        if validInlineLength == nil { return "Enter an inline-diff line length from 0 to 100000." }
        if let profileError { return profileError }
        do { try MergeCommentProfileFile.validate(profileText); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Backup original file", isOn: $backupOriginal)
                    Toggle("Jump to first difference when loading", isOn: $general.firstDifference)
                    Toggle("Jump to first conflict when loading", isOn: $general.firstConflict).padding(.leading, 12).disabled(!general.firstDifference)
                    Toggle("Show line numbers", isOn: $draft.showLineNumbers)
                    Toggle("Show Whitespaces", isOn: $whitespaceDisplay.visible)
                    Toggle("Use icons for CR, LF and CRLF", isOn: $whitespaceDisplay.endingIcons)
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
                    HStack {
                        Text("Font:"); NativeFixedFontChoice(value: $general.fontName).frame(height: 24)
                        NativeFontSizeChoice(value: $fontSize).frame(width: 75, height: 24)
                    }
                    HStack {
                        Text("Max line length for inline diffs:")
                        TextField("Max line length", text: $maximumInline).frame(width: 90)
                        Spacer()
                    }
                    if validFontSize == nil || validInlineLength == nil { Text(validationError ?? "").font(.caption).foregroundStyle(.red) }
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
            } }
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
        .onChange(of: general) { _ in transaction?.notify() }
        .onChange(of: fontSize) { _ in transaction?.notify() }
        .onChange(of: maximumInline) { _ in transaction?.notify() }
        .onChange(of: comparison) { _ in transaction?.notify() }
        .onChange(of: locator) { _ in transaction?.notify() }
        .onChange(of: whitespaceDisplay) { _ in transaction?.notify() }
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
        general = generalDraft; general.save()
        draft.tabWidth = width; draft.save(); comparison.save(); locator.save(); whitespaceDisplay.save()
        MergeFileSaveOptions.saveBackupPreference(backupOriginal)
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true
    }
    private var sheetValidationError: String? {
        do { try MergeCommentProfileFile.validate(sheetProfileText); return nil }
        catch { return error.localizedDescription }
    }
    private func restore() {
        general = .load(); fontSize = String(general.fontSize); maximumInline = String(general.maximumInlineLength)
        draft = .load(); comparison = .load(); locator = .load(); whitespaceDisplay = .load(); tabSize = String(draft.tabWidth)
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

/// SetColorPage's source rows, with independent native light/dark editing.
struct MergeColorsSettings: View {
    @State private var draft = MergeColorPreferences.load()
    @State private var dark = false
    @Environment(\.settingsTransaction) private var transaction
    private let rows: [MergeColorRole] = [.normal, .added, .removed, .modified, .conflicted, .resolved, .empty, .filtered]
    private func binding(_ role: MergeColorRole, foreground: Bool) -> Binding<Color> {
        Binding(get: {
            let colors = draft.colors(role, dark: dark), rgb = foreground ? colors.foreground : colors.background
            return Color(.sRGB, red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, Int((value * 255).rounded())))) }
            let value = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
            var colors = draft.colors(role, dark: dark)
            if foreground { colors.foreground = value } else { colors.background = value }
            if dark { draft.dark[role] = colors } else { draft.light[role] = colors }
        })
    }
    private func row(_ role: MergeColorRole) -> some View {
        HStack {
            Text(role.title).frame(width: 140, alignment: .leading)
            if role.supportsForeground { ColorPicker(role.title + " foreground", selection: binding(role, foreground: true), supportsOpacity: false).labelsHidden().frame(maxWidth: .infinity) }
            else { Color.clear.frame(maxWidth: .infinity) }
            if role.supportsBackground { ColorPicker(role.title + " background", selection: binding(role, foreground: false), supportsOpacity: false).labelsHidden().frame(maxWidth: .infinity) }
            else { Color.clear.frame(maxWidth: .infinity) }
        }
    }
    private func apply() -> Bool {
        do { try draft.save(); MergePalette.reload(); NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true }
        catch { return false }
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Picker("Palette", selection: $dark) { Text("Light").tag(false); Text("Dark").tag(true) }.pickerStyle(.segmented)
            HStack { Text(" ").frame(width: 140); Text("Foreground").frame(maxWidth: .infinity); Text("Background").frame(maxWidth: .infinity) }
            GroupBox("Line differences") { VStack(spacing: 10) { ForEach(rows, id: \.self) { row($0) } }.padding(8) }
            GroupBox("Inline differences") { VStack(spacing: 10) { row(.inlineAdded); row(.inlineRemoved) }.padding(8) }
            GroupBox("Misc") { row(.whitespace).padding(8) }
            HStack { Spacer(); Button("Restore Default") { draft.restore(dark: dark) } }
            Text("Palette edits apply to open merge panes, locator stripes and whitespace markers when you choose Apply. App appearance is controlled in General.").font(.caption).foregroundStyle(.secondary)
            if transaction == nil { HStack { Spacer(); Button("Cancel") { draft = .load() }; Button("Apply") { _ = apply() }.disabled(draft == .load()) } }
        }.padding(20) }
        .settingsParticipant("mergeColors", page: .mergeColors, value: draft, modified: { draft != .load() }, apply: { apply() }, cancel: { draft = .load() })
    }
}
