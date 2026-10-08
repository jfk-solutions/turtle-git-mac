import AppKit
import SwiftUI
import TurtleGitCore

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Follow System" : rawValue.capitalized }
}

@MainActor final class AppAppearance: ObservableObject {
    @Published var choice: AppearanceChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "appearance"); apply() }
    }
    init() {
        choice = AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system
        #if DEBUG
        if Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true,
           let value = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationAppearance") as? String,
           let preset = AppearanceChoice(rawValue: value) { choice = preset }
        #endif
    }
    func apply() {
        NSApp.appearance = choice == .system ? nil : NSAppearance(named: choice == .dark ? .darkAqua : .aqua)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppAppearance
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text("Status colors, graph lanes and original command icons retain their colors in both appearances.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 390)
    }
}

/// Default CColors status roles and CTheme fixed-color conversion at the
/// pinned upstream revision. RGB values here use ordinary R/G/B ordering.
enum StatusTextRole: String, CaseIterable {
    case conflict, modified, merged, deleted, added, renamed
    var rgb: [Int] {
        switch self {
        case .conflict: return [255,0,0]
        case .modified: return [0,50,160]
        case .merged: return [0,100,0]
        case .deleted: return [100,0,0]
        case .added: return [100,0,100]
        case .renamed: return [0,0,255]
        }
    }
}

enum StatusTextPalette {
    static func rgb(_ role: StatusTextRole, dark: Bool, highContrast: Bool = false) -> [Int] {
        let rgb = role.rgb
        guard dark else { return rgb }
        let r = Float(rgb[0]) / 255, g = Float(rgb[1]) / 255, b = Float(rgb[2]) / 255
        let maximum = max(r,g,b), minimum = min(r,g,b), delta = maximum - minimum
        var lightness = (maximum + minimum) / 2
        var saturation: Float = 0, hue: Float = 0
        if maximum != minimum {
            saturation = lightness < 0.5 ? delta / (maximum + minimum) : delta / ((2 - maximum) - minimum)
            if maximum == r { hue = (g - b) / delta }
            else if maximum == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
        }
        saturation *= 100
        hue *= 60
        if hue < 0 { hue += 360 }
        lightness = 100 - lightness * 100
        if !highContrast { lightness = min(90,max(5,lightness)) }
        if saturation == 0 { return Array(repeating: Int(lightness / 100 * 255), count: 3) }
        let l = lightness / 100, h = hue / 360, s = saturation / 100
        let first = l < 0.5 ? l * (1 + s) : l + s - l * s
        let second = 2 * l - first
        func channel(_ hue: Float) -> Int {
            var value = hue
            if value > 1 { value -= 1 }
            if value < 0 { value += 1 }
            let percent: Float
            if value * 6 < 1 { percent = (second + (first - second) * 6 * value) * 100 }
            else if value * 2 < 1 { percent = first * 100 }
            else if value * 3 < 2 { percent = (second + (first - second) * (0.66666 - value) * 6) * 100 }
            else { percent = second * 100 }
            return min(255,max(0,Int(percent / 100 * 255)))
        }
        return [channel(h + 0.33333), channel(h), channel(h - 0.33333)]
    }
    static func native(_ role: StatusTextRole) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,.accessibilityHighContrastAqua,.darkAqua,.aqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let channels = rgb(role, dark: dark, highContrast: match == .accessibilityHighContrastDarkAqua)
            return NSColor(srgbRed: CGFloat(channels[0]) / 255, green: CGFloat(channels[1]) / 255, blue: CGFloat(channels[2]) / 255, alpha: 1)
        }
    }
}

extension StatusEntry {
    /// The source combines index/worktree action bits, then chooses one role.
    /// Modification precedes add/copy, deletion and rename; conflicts precede all.
    var statusTextRole: StatusTextRole? {
        if state == .conflicted { return .conflict }
        let actions = [index,worktree]
        if actions.contains("M") || actions.contains("T") { return .modified }
        if actions.contains("A") || actions.contains("C") { return .added }
        if actions.contains("D") || actions.contains("K") { return .deleted }
        if actions.contains("R") { return .renamed }
        return nil
    }
    func statusTextColor(selected: Bool = false) -> Color {
        if selected { return .primary }
        return statusTextRole.map { Color(nsColor: StatusTextPalette.native($0)) } ?? Color(nsColor: .labelColor)
    }
}

extension FileState {
    var textColor: Color {
        let role: StatusTextRole?
        switch self {
        case .modified: role = .modified
        case .added: role = .added
        case .deleted: role = .deleted
        case .conflicted: role = .conflict
        case .normal, .untracked, .ignored: role = nil
        }
        return role.map { Color(nsColor: StatusTextPalette.native($0)) } ?? Color(nsColor: .labelColor)
    }
}

extension LFSFileResult {
    /// Source LFS file notifications are neutral; ReportError uses Conflict.
    var resultTextColor: Color { success ? .primary : Color(nsColor: StatusTextPalette.native(.conflict)) }
}
