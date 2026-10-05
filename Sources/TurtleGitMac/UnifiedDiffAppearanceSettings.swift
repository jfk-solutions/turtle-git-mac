import AppKit
import SwiftUI
import TurtleGitCore

extension Notification.Name { static let unifiedDiffAppearanceChanged = Notification.Name("TurtleGit.UnifiedDiffAppearanceChanged") }
struct UnifiedDiffAppearanceSettings: View {
    @State private var draft = UnifiedDiffAppearance.load()
    @State private var saved = UnifiedDiffAppearance.load()
    @State private var size = String(UnifiedDiffAppearance.load().fontSize)
    @State private var tabs = String(UnifiedDiffAppearance.load().tabSize)
    @State private var dark = false
    private var fonts: [String] {
        Array(Set(NSFontManager.shared.availableFontFamilies.filter {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 10)?.isFixedPitch == true
        } + [draft.fontName])).sorted()
    }
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
                    HStack { Text("Font:"); Picker("Font", selection: $draft.fontName) { ForEach(fonts, id: \.self) { Text($0).tag($0) } }.labelsHidden(); NativeFontSizeChoice(value: $size).frame(width: 75, height: 24) }
                    HStack { Text("Tab size:"); Spacer(); TextField("Tab size", text: $tabs).frame(width: 60) }
                    if value == nil { Text("Enter font and tab sizes from 1 to 1000.").font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            Text("These settings also apply to Patch Viewer previews. Choose the built-in or external program in the Viewer tab.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack { Spacer(); Button("Cancel") { draft = saved; size = String(saved.fontSize); tabs = String(saved.tabSize); NSApp.keyWindow?.performClose(nil) }
                Button("Apply") { guard let value else { return }; value.save(); saved = value; NotificationCenter.default.post(name: .unifiedDiffAppearanceChanged, object: nil) }.disabled(value == nil || value == saved)
            }
        }.padding(20).onAppear { saved = .load(); draft = saved; size = String(saved.fontSize); tabs = String(saved.tabSize) }
    }
}

/// Settings scenes promote nested TabViews into their toolbar. Keep the viewer
/// subpages inside the Unified Diff page so Appearance cannot select the global tab.
struct UnifiedDiffSettingsPage: View {
    @State private var appearance = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Unified diff settings", selection: $appearance) {
                Text("Viewer").tag(false)
                Text("Appearance").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 16)
            if appearance { UnifiedDiffAppearanceSettings() }
            else { UnifiedDiffViewerSettings() }
        }
    }
}
