import AppKit
import SwiftUI
import TurtleGitCore

extension Notification.Name { static let unifiedDiffAppearanceChanged = Notification.Name("TurtleGit.UnifiedDiffAppearanceChanged") }
struct UnifiedDiffAppearanceSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var initialized = false
    private let preferences: UserDefaults
    @State private var draft: UnifiedDiffAppearance
    @State private var saved: UnifiedDiffAppearance
    @State private var size: String
    @State private var tabs: String
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let value = UnifiedDiffAppearance.load(from:preferences)
        _draft = State(initialValue:value); _saved = State(initialValue:value)
        _size = State(initialValue:String(value.fontSize)); _tabs = State(initialValue:String(value.tabSize))
    }
    @State private var dark = false
    private var value: UnifiedDiffAppearance? {
        guard let font = Int(size), let tab = Int(tabs), (1...1000).contains(font), (1...1000).contains(tab) else { return nil }
        var value = draft; value.fontSize = font; value.tabSize = tab; return value
    }
    private func color(_ style: UnifiedDiffLineStyle, foreground: Bool) -> Binding<Color> {
        Binding(get: {
            let palette = draft.colors(style, dark: dark), rgb = foreground ? palette.foreground : palette.background
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, Int((value * 255).rounded())))) }
            let packed = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
            var palette = draft.colors(style, dark: dark)
            if foreground { palette.foreground = packed } else { palette.background = packed }
            if dark { draft.dark[style] = palette } else { draft.light[style] = palette }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Colors") {
                        VStack(spacing: 10) {
                            Picker("Appearance", selection: $dark) { Text("Light").tag(false); Text("Dark").tag(true) }.pickerStyle(.segmented)
                            HStack { Text(" ").frame(width: 150); Text("Foreground").frame(maxWidth: .infinity); Text("Background").frame(maxWidth: .infinity) }
                            ForEach(UnifiedDiffLineStyle.configurable, id: \.self) { style in
                                HStack {
                                    Text(style.label).frame(width: 150, alignment: .leading)
                                    ColorPicker(style.label + " foreground", selection: color(style, foreground: true), supportsOpacity: false).labelsHidden().frame(maxWidth: .infinity)
                                    ColorPicker(style.label + " background", selection: color(style, foreground: false), supportsOpacity: false).labelsHidden().frame(maxWidth: .infinity)
                                }
                            }
                            HStack { Spacer(); Button("Restore Default") { draft.restoreColors(dark: dark) } }
                        }.padding(8)
                    }
                    GroupBox("Font") {
                        VStack(spacing: 10) {
                            HStack { Text("Font:"); NativeFixedFontChoice(value: $draft.fontName).frame(height: 24); NativeFontSizeChoice(value: $size).frame(width: 75, height: 24) }
                            HStack { Text("Tab size:"); Spacer(); TextField("Tab size", text: $tabs).frame(width: 60) }
                            if value == nil { Text("Enter font and tab sizes from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                        }.padding(8)
                    }
                    Text("These settings also apply to Patch Viewer previews. Choose the built-in or external program in the Viewer tab.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if transaction == nil { HStack { Spacer(); Button("Cancel") { draft = saved; size = String(saved.fontSize); tabs = String(saved.tabSize); NSApp.keyWindow?.performClose(nil) }
                Button("Apply") { guard let value else { return }; value.save(to:preferences); saved = value; NotificationCenter.default.post(name: .unifiedDiffAppearanceChanged, object: nil) }.disabled(value == nil || value == saved)
            } }
        }.padding(20).onAppear { if !initialized { initialized = true; saved = .load(from:preferences); draft = saved; size = String(saved.fontSize); tabs = String(saved.tabSize) } }
        .settingsParticipant("unifiedDiff.appearance", page: .unifiedDiff, value: draft,
            modified: { value != saved }, validate: { value == nil ? "Enter font and tab sizes from 1 to 1000." : nil },
            apply: { guard let value else { return false }; value.save(to:preferences); saved = value; NotificationCenter.default.post(name: .unifiedDiffAppearanceChanged, object: nil); return true },
            cancel: { draft = saved; size = String(saved.fontSize); tabs = String(saved.tabSize) })
        .onChange(of: size) { _ in transaction?.notify() }
        .onChange(of: tabs) { _ in transaction?.notify() }
    }
}

/// Settings scenes promote nested TabViews into their toolbar. Keep the viewer
/// subpages inside the Unified Diff page so Appearance cannot select the global tab.
struct UnifiedDiffSettingsPage: View {
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    @State private var appearance = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Unified diff settings", selection: $appearance) {
                Text("Viewer").tag(false)
                Text("Appearance").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 16)
            ZStack {
                UnifiedDiffViewerSettings(preferences:preferences).opacity(appearance ? 0 : 1).disabled(appearance).accessibilityHidden(appearance)
                UnifiedDiffAppearanceSettings(preferences:preferences).opacity(appearance ? 1 : 0).disabled(!appearance).accessibilityHidden(!appearance)
            }
        }
    }
}
