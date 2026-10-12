import SwiftUI
import AppKit
import TurtleGitCore

extension Notification.Name {
    static let mergeEditorPreferencesChanged = Notification.Name("TurtleGitMerge.PreferencesChanged")
}

struct MergeEditorSettings: View {
    private let preferences: UserDefaults
    private let profileURL: URL
    @Environment(\.settingsTransaction) private var transaction
    @State private var windowReference = MergeSettingsWindowReference()
    @State private var initialized = false
    @State private var general = MergeGeneralPreferences.load()
    @State private var fontSize = String(MergeGeneralPreferences.load().fontSize)
    @State private var preferUTF8 = false
    @State private var onePaneDefault = false
    @State private var patchContext = String(MergeUnifiedPatch.contextLines())
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
    init(defaults: UserDefaults = .standard, commentProfileURL: URL = MergeCommentProfileFile.url) {
        preferences = defaults; profileURL = commentProfileURL
        let general = MergeGeneralPreferences.load(from: defaults), editor = MergeEditorPreferences.load(from: defaults)
        _preferUTF8 = State(initialValue: ComparisonTextEncoding.preferUTF8(from: defaults))
        _onePaneDefault = State(initialValue: OnePaneFileComparison.defaultEnabled(from: defaults))
        _general = State(initialValue: general); _fontSize = State(initialValue: String(general.fontSize))
        _maximumInline = State(initialValue: String(general.maximumInlineLength)); _patchContext = State(initialValue: String(MergeUnifiedPatch.contextLines(from: defaults)))
        _draft = State(initialValue: editor); _tabSize = State(initialValue: String(editor.tabWidth))
        _comparison = State(initialValue: .load(from: defaults)); _locator = State(initialValue: .load(from: defaults))
        _whitespaceDisplay = State(initialValue: .load(from: defaults)); _backupOriginal = State(initialValue: MergeFileSaveOptions.backupEnabled(from: defaults))
    }
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
        return MergeEditorPreferences(tabWidth: width, useSpaces: draft.useSpaces, smartTab: draft.smartTab, showLineNumbers: draft.showLineNumbers, enableEditorConfig: draft.enableEditorConfig, autoAdd: draft.autoAdd) != .load(from: preferences) || generalDraft != .load(from: preferences) || comparison != .load(from: preferences) || locator != .load(from: preferences) || whitespaceDisplay != .load(from: preferences) || backupOriginal != MergeFileSaveOptions.backupEnabled(from: preferences) || MergeUnifiedPatch.validatedContext(patchContext) != MergeUnifiedPatch.contextLines(from: preferences) || preferUTF8 != ComparisonTextEncoding.preferUTF8(from: preferences) || onePaneDefault != OnePaneFileComparison.defaultEnabled(from: preferences) || profileText != savedProfileText
    }
    private var validationError: String? {
        if MergeUnifiedPatch.validatedContext(patchContext) == nil { return "Enter patch context lines from -1 (Git default) to 1000." }
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
            GroupBox("Misc") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Backup original file", isOn: $backupOriginal)
                    Toggle("Jump to first difference when loading", isOn: $general.firstDifference)
                    Toggle("Jump to first conflict when loading", isOn: $general.firstConflict).padding(.leading, 12).disabled(!general.firstDifference)
                    NativeMergeUTF8DefaultChoice(value: $preferUTF8).frame(height: 24)
                    Toggle("Use one-pane view as default for 2-file diff", isOn: $onePaneDefault)
                    Toggle("Show line numbers", isOn: $draft.showLineNumbers)
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
                }.padding(8)
            }
            GroupBox("Diffing") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Max line length for inline diffs:")
                        TextField("Max line length", text: $maximumInline).frame(width: 90)
                        Spacer()
                    }
                    if validFontSize == nil || validInlineLength == nil { Text(validationError ?? "").font(.caption).foregroundStyle(.red) }
                    Toggle("Ignore line endings (recommended)", isOn: $comparison.ignoreEndings)
                    Toggle("Ignore case changes", isOn: $comparison.ignoreCase)
                    HStack {
                        Text("Context lines for patches:")
                        NativePatchContextField(value: $patchContext).frame(width: 90, height: 24)
                        Text("-1 uses Git’s default").font(.caption).foregroundStyle(.secondary)
                    }
                    if MergeUnifiedPatch.validatedContext(patchContext) == nil { Text(validationError ?? "").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            GroupBox("Additional comparison and view options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Whitespaces", isOn: $whitespaceDisplay.visible)
                    Toggle("Use icons for CR, LF and CRLF", isOn: $whitespaceDisplay.endingIcons)
                    Toggle("Show locator bar", isOn: $locator.visible)
                    Toggle("Use fish-eye in locator bar", isOn: $locator.fishEye)
                    Picker("Whitespace comparison:", selection: $comparison.whitespace) {
                        ForEach(MergeWhitespaceComparison.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
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
        .onChange(of: preferUTF8) { _ in transaction?.notify() }
        .onChange(of: onePaneDefault) { _ in transaction?.notify() }
        .onChange(of: patchContext) { _ in transaction?.notify() }
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
                try MergeCommentProfileFile.save(profileText, at: profileURL, expected: savedProfileText)
                savedProfileText = profileText
            }
        } catch {
            // A failed write must not save the other preferences or notify open panes.
            let alert = NSAlert(); alert.messageText = "Comment profiles were not saved"
            alert.informativeText = error.localizedDescription; alert.runModal(); return false
        }
        preferences.set(preferUTF8, forKey: "TurtleGitMerge.UseUTF8")
        preferences.set(onePaneDefault, forKey: "TurtleGitMerge.OnePane")
        preferences.set(MergeUnifiedPatch.validatedContext(patchContext)!, forKey: "TurtleGitMerge.ContextLines")
        general = generalDraft; general.save(to: preferences)
        draft.tabWidth = width; draft.save(to: preferences); comparison.save(to: preferences); locator.save(to: preferences); whitespaceDisplay.save(to: preferences)
        MergeFileSaveOptions.saveBackupPreference(backupOriginal, to: preferences)
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil); return true
    }
    private var sheetValidationError: String? {
        do { try MergeCommentProfileFile.validate(sheetProfileText); return nil }
        catch { return error.localizedDescription }
    }
    private func restore() {
        preferUTF8 = ComparisonTextEncoding.preferUTF8(from: preferences)
        onePaneDefault = OnePaneFileComparison.defaultEnabled(from: preferences)
        patchContext = String(MergeUnifiedPatch.contextLines(from: preferences))
        general = .load(from: preferences); fontSize = String(general.fontSize); maximumInline = String(general.maximumInlineLength)
        draft = .load(from: preferences); comparison = .load(from: preferences); locator = .load(from: preferences); whitespaceDisplay = .load(from: preferences); tabSize = String(draft.tabWidth)
        backupOriginal = MergeFileSaveOptions.backupEnabled(from: preferences)
        do { profileText = try MergeCommentProfileFile.text(at: profileURL); savedProfileText = profileText; profileError = nil }
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

/// SetColorPage keeps both palettes as drafts until Apply.
@MainActor final class MergeColorsSettingsModel: ObservableObject {
    let preferences: UserDefaults
    @Published private(set) var draft: MergeColorPreferences
    @Published var dark: Bool
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
    func setColor(_ value: UInt32, role: MergeColorRole, foreground: Bool) {
        guard value <= 0xffffff, foreground ? role.supportsForeground : role.supportsBackground else { return }
        var colors = draft.colors(role, dark: dark)
        if foreground { colors.foreground = value } else { colors.background = value }
        if dark { draft.dark[role] = colors } else { draft.light[role] = colors }
        error = nil
    }
    func restoreDefault() { draft.restore(dark: dark); error = nil }
    func discard() { draft = .load(from: preferences); error = nil }
    func apply() -> Bool {
        do {
            try draft.save(to: preferences); MergePalette.reload(defaults: preferences)
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
        NativeMergeColorChoice(value: model.color(role, foreground: foreground), automatic: model.automatic(role, foreground: foreground),
            label: ([MergeColorRole.inlineAdded, .inlineRemoved].contains(role) ? "Inline " : "") + role.title + (foreground ? " foreground" : " background"), identifier: role.rawValue + (foreground ? ".foreground" : ".background"),
            changed: { model.setColor($0, role: role, foreground: foreground) })
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
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            NativeMergePaletteChoice(dark: $model.dark).frame(height: 26)
            HStack { Text(" ").frame(width: 140); Text("Foreground").frame(maxWidth: .infinity); Text("Background").frame(maxWidth: .infinity) }
            GroupBox("Line differences") { VStack(spacing: 10) { ForEach(rows, id: \.self) { row($0) } }.padding(8) }
            GroupBox("Inline differences") { VStack(spacing: 10) { row(.inlineAdded); row(.inlineRemoved) }.padding(8) }
            GroupBox("Misc") { row(.whitespace).padding(8) }
            HStack { Spacer(); Button("Restore Default") { model.restoreDefault() } }
            Text("Use each swatch’s menu for Automatic or More colors. Apply updates open merge panes, locator stripes and whitespace markers. App appearance is controlled in General.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if transaction == nil { HStack { Spacer(); Button("Cancel") { model.discard() }; Button("Apply") { _ = model.apply() }.disabled(!model.changed) } }
        }.padding(20) }
        .settingsParticipant("mergeColors", page: .mergeColors, value: model.draft, modified: { model.changed }, apply: { model.apply() }, cancel: { model.discard() })
    }
}

private struct NativeMergePaletteChoice: NSViewRepresentable {
    @Binding var dark: Bool
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.identifier = NSUserInterfaceItemIdentifier("MergeColors.Palette"); control.setAccessibilityLabel("Palette to edit")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) { context.coordinator.binding = $dark; control.selectedSegment = dark ? 1 : 0 }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $dark) }
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func choose(_ control: NSSegmentedControl) { binding.wrappedValue = control.selectedSegment == 1 }
    }
}

private struct NativeMergeColorChoice: NSViewRepresentable {
    let value: UInt32, automatic: UInt32
    let label: String, identifier: String
    let changed: (UInt32) -> Void
    func makeNSView(context: Context) -> MergeColorChoiceView { MergeColorChoiceView() }
    func updateNSView(_ view: MergeColorChoiceView, context: Context) {
        view.configure(value: value, automatic: automatic, label: label, identifier: identifier, changed: changed)
    }
    static func dismantleNSView(_ view: MergeColorChoiceView, coordinator: ()) { view.retire() }
}

/// A native color well plus the source Automatic/More colors dropdown.
@MainActor final class MergeColorChoiceView: NSView {
    let well = MergeSettingsColorWell()
    let arrow = NSButton()
    let choices = NSMenu()
    private var automatic: UInt32 = 0
    private var changed: ((UInt32) -> Void)?
    private var ownerObserver: NSObjectProtocol?
    var presentPanel: (NSColorPanel) -> Void = { $0.orderFront(nil) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        well.target = self; well.action = #selector(colorChanged(_:))
        arrow.title = "▾"; arrow.bezelStyle = .rounded; arrow.target = self; arrow.action = #selector(showChoices(_:))
        addSubview(well); addSubview(arrow)
        let automaticItem = NSMenuItem(title: "Automatic", action: #selector(useAutomatic(_:)), keyEquivalent: "")
        automaticItem.target = self; choices.addItem(automaticItem); choices.addItem(.separator())
        let custom = NSMenuItem(title: "More colors…", action: #selector(moreColors(_:)), keyEquivalent: "")
        custom.target = self; choices.addItem(custom)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout(); well.frame = NSRect(x: 0, y: 1, width: max(0, bounds.width - 20), height: bounds.height - 2)
        arrow.frame = NSRect(x: bounds.width - 20, y: 0, width: 20, height: bounds.height)
    }
    private static func color(_ rgb: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    func configure(value: UInt32, automatic: UInt32, label: String, identifier: String, changed: @escaping (UInt32) -> Void) {
        self.automatic = automatic; self.changed = changed
        self.identifier = NSUserInterfaceItemIdentifier("MergeColors." + identifier)
        well.color = Self.color(value); well.setAccessibilityLabel(label)
        well.identifier = NSUserInterfaceItemIdentifier("MergeColors." + identifier + ".well")
        arrow.identifier = NSUserInterfaceItemIdentifier("MergeColors." + identifier + ".choices")
        arrow.setAccessibilityLabel(label + " choices"); choices.title = label
        choices.items.first?.state = value == automatic ? .on : .off
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in Self.color(automatic).setFill(); rect.fill(); return true }
        choices.items.first?.image = image
    }
    @objc private func colorChanged(_ sender: Any?) {
        guard let changed, let color = well.color.usingColorSpace(.sRGB) else { return }
        func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, Int((value * 255).rounded())))) }
        let rgb = channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        well.color = Self.color(rgb); changed(rgb)
    }
    @objc private func useAutomatic(_ sender: Any?) { guard let changed else { return }; well.color = Self.color(automatic); changed(automatic) }
    @objc private func moreColors(_ sender: Any?) { guard changed != nil else { return }; well.activate(true); presentPanel(.shared) }
    @objc private func showChoices(_ sender: Any?) { guard changed != nil else { return }; choices.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY), in: self) }
    private func closeOwnedPanel() { if well.isActive { well.deactivate(); NSColorPanel.shared.orderOut(nil) } }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { closeOwnedPanel() }; super.viewWillMove(toWindow: newWindow) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
        if let window {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retire() }
            }
        }
    }
    func retire() { choices.cancelTracking(); closeOwnedPanel(); changed = nil; well.target = nil; arrow.target = nil; well.isEnabled = false; arrow.isEnabled = false }
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
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value); field.identifier = NSUserInterfaceItemIdentifier("MergePatchContext")
        field.setAccessibilityIdentifier("MergePatchContext"); field.setAccessibilityLabel("Context lines for patches")
        field.placeholderString = "-1…1000"; field.delegate = context.coordinator; return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.binding = $value
        if field.stringValue != value { field.stringValue = value }
    }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { binding.wrappedValue = field.stringValue }
        }
    }
}

private struct NativeMergeUTF8DefaultChoice: NSViewRepresentable {
    @Binding var value: Bool
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Default to UTF-8 encoding", target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("MergeUTF8Default"); button.setAccessibilityIdentifier("MergeUTF8Default")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.binding = $value; button.state = value ? .on : .off }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ button: NSButton) { binding.wrappedValue = button.state == .on }
    }
}
