import AppKit
import SwiftUI
import TurtleGitCore

extension Notification.Name {
    static let blamePreferencesChanged = Notification.Name("TurtleGitBlame.PreferencesChanged")
}

struct BlameSettings: View {
    @State private var reference = BlameSettingsWindowReference()
    @State private var draft = GitBlamePreferences.load()
    @State private var within = String(GitBlamePreferences.load().withinFileCharacters)
    @State private var between = String(GitBlamePreferences.load().betweenFileCharacters)
    @State private var presentation = GitBlamePresentation.load()
    @State private var fontSize = String(GitBlamePresentation.load().fontSize)
    @State private var tabSize = String(GitBlamePresentation.load().tabSize)
    @State private var darkColors = false
    private var fonts: [String] {
        let fixed = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 10)?.isFixedPitch == true
        }
        return Array(Set(fixed + [presentation.fontName])).sorted()
    }
    private var validPresentation: GitBlamePresentation? {
        guard let font = Int(fontSize), let tabs = Int(tabSize), (1...1000).contains(font), (1...1000).contains(tabs) else { return nil }
        var value = presentation; value.fontSize = font; value.tabSize = tabs; return value
    }
    private func colorBinding(recent: Bool) -> Binding<Color> {
        Binding(get: {
            let rgb = darkColors ? (recent ? presentation.darkRecentColor : presentation.darkOldColor) : (recent ? presentation.recentColor : presentation.oldColor)
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, Int((value * 255).rounded())))) }
            let value = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
            if darkColors { if recent { presentation.darkRecentColor = value } else { presentation.darkOldColor = value } }
            else { if recent { presentation.recentColor = value } else { presentation.oldColor = value } }
        })
    }
    private func count(_ value: String) -> UInt32? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(value)
    }
    private var options: GitBlameOptions? {
        guard let within = count(within), let between = count(between) else { return nil }
        var result = draft; result.withinFileCharacters = within; result.betweenFileCharacters = between
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Colors") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Appearance", selection: $darkColors) { Text("Light").tag(false); Text("Dark").tag(true) }.pickerStyle(.segmented)
                    ColorPicker("Recently modified lines", selection: colorBinding(recent: true), supportsOpacity: false)
                    ColorPicker("Older lines", selection: colorBinding(recent: false), supportsOpacity: false)
                    HStack {
                        Spacer()
                        Button("Restore Default") {
                            let defaults = GitBlamePresentation()
                            presentation.recentColor = defaults.recentColor; presentation.oldColor = defaults.oldColor
                            presentation.darkRecentColor = defaults.darkRecentColor; presentation.darkOldColor = defaults.darkOldColor
                        }
                    }
                }.padding(8)
            }
            GroupBox("Font") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Font:", selection: $presentation.fontName) { ForEach(fonts, id: \.self) { Text($0).tag($0) } }
                        BlameFontSizeChoice(value: $fontSize).frame(width: 75, height: 24)
                    }
                    HStack { Text("Tab size:"); TextField("Tab size", text: $tabSize).frame(width: 65); Spacer() }
                    if validPresentation == nil { Text("Enter font and tab sizes from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            GroupBox("Blame") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Detect moved or copied lines:", selection: $draft.detectionMode) {
                        ForEach(GitBlameDetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text("Number of characters required for moved or copied line detection:").font(.caption)
                    HStack {
                        Text("Within a file:")
                        TextField("Characters within a file", text: $within).frame(width: 70).disabled(draft.detectionMode != .withinFile)
                        Spacer()
                        Text("Between files:")
                        TextField("Characters between files", text: $between).frame(width: 70).disabled(!draft.detectionMode.betweenFiles)
                    }
                    Toggle("Ignore whitespace", isOn: $draft.ignoreWhitespace)
                    Toggle("Only consider first parents on blame", isOn: $draft.onlyFirstParent)
                    if options == nil { Text("Enter character counts from 0 to 4294967295.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("Apply these defaults to open and new Blame windows. Each window retains its source encoding.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { restore(); reference.window?.performClose(nil) }
                Button("Apply") {
                    guard let options, let validPresentation else { return }
                    GitBlamePreferences.save(options)
                    validPresentation.save()
                    NotificationCenter.default.post(name: .blamePreferencesChanged, object: nil)
                }.disabled(options == nil || validPresentation == nil || (options == GitBlamePreferences.load() && validPresentation == GitBlamePresentation.load()))
            }
        }.padding(20).background(BlameSettingsWindowProbe(reference: reference).frame(width: 0, height: 0)).onAppear { restore() }
    }
    private func restore() {
        draft = GitBlamePreferences.load(); within = String(draft.withinFileCharacters); between = String(draft.betweenFileCharacters)
        presentation = .load(); fontSize = String(presentation.fontSize); tabSize = String(presentation.tabSize)
    }
}
private struct BlameFontSizeChoice: NSViewRepresentable {
    @Binding var value: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: stride(from: 6, through: 30, by: 2).map(String.init))
        combo.delegate = context.coordinator
        combo.setAccessibilityLabel("Font size")
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.value = $value
        if combo.stringValue != value { combo.stringValue = value }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var value: Binding<String>
        init(value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            value.wrappedValue = combo.stringValue
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox,
                  let selected = combo.objectValueOfSelectedItem as? String else { return }
            value.wrappedValue = selected
        }
    }
}
private final class BlameSettingsWindowReference { weak var window: NSWindow? }
private struct BlameSettingsWindowProbe: NSViewRepresentable {
    let reference: BlameSettingsWindowReference
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); view.reference = reference; return view }
    func updateNSView(_ view: ProbeView, context: Context) { reference.window = view.window }
    final class ProbeView: NSView {
        var reference: BlameSettingsWindowReference?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window }
    }
}
