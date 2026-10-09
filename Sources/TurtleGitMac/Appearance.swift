import AppKit
import SwiftUI
import TurtleGitCore
import CoreFoundation

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
    @StateObject private var colors = StatusColorSettingsModel()
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text("Status colors, graph lanes and original command icons retain their colors in both appearances.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            StatusColorsSettings(model: colors)
        }.padding(20).frame(width: 590)
    }
}

/// Default CColors status roles and CTheme fixed-color conversion at the
/// pinned upstream revision. RGB values here use ordinary R/G/B ordering.
enum StatusTextRole: String, CaseIterable {
    case conflict, modified, merged, deleted, added, renamed
    var title: String { rawValue.capitalized }
    var preferenceKey: String { "Colors." + title }
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
        transform(role.rgb, dark: dark, highContrast: highContrast)
    }
    static func transform(_ rgb: [Int], dark: Bool, highContrast: Bool = false) -> [Int] {
        precondition(rgb.count == 3 && rgb.allSatisfy { (0...255).contains($0) })
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
    static func native(_ role: StatusTextRole, preferences: UserDefaults = .standard) -> NSColor {
        let base = StatusColorPreferences.load(preferences).rgb(role)
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,.accessibilityHighContrastAqua,.darkAqua,.aqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let channels = transform(base, dark: dark, highContrast: match == .accessibilityHighContrastDarkAqua)
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
    func statusTextColor(selected: Bool = false, preferences: UserDefaults = .standard) -> Color {
        if selected { return .primary }
        return statusTextRole.map { Color(nsColor: StatusTextPalette.native($0, preferences: preferences)) } ?? Color(nsColor: .labelColor)
    }
}

extension CommitFile {
    /// CTGitPath::ParseStatus followed by GitStatusListCtrl's action colors.
    /// Rename/copy scores do not affect the action; type changes are Modified.
    var statusTextRole: StatusTextRole? {
        switch action.first {
        case "U": return .conflict
        case "M", "T": return .modified
        case "A", "C": return .added
        case "D", "K": return .deleted
        case "R": return .renamed
        default: return nil
        }
    }
    func statusTextColor(selected: Bool = false, gray: Bool = false, preferences: UserDefaults = .standard) -> Color {
        if selected { return .primary }
        if gray { return .secondary }
        return statusTextRole.map { Color(nsColor: StatusTextPalette.native($0, preferences: preferences)) } ?? .primary
    }
}

extension FileState {
    var textColor: Color { textColor(preferences: .standard) }
    func textColor(preferences: UserDefaults) -> Color {
        let role: StatusTextRole?
        switch self {
        case .modified: role = .modified
        case .added: role = .added
        case .deleted: role = .deleted
        case .conflicted: role = .conflict
        case .normal, .untracked, .ignored: role = nil
        }
        return role.map { Color(nsColor: StatusTextPalette.native($0, preferences: preferences)) } ?? Color(nsColor: .labelColor)
    }
}

extension LFSFileResult {
    /// Source LFS file notifications are neutral; ReportError uses Conflict.
    var resultTextColor: Color { resultTextColor(preferences: .standard) }
    func resultTextColor(preferences: UserDefaults) -> Color { success ? .primary : Color(nsColor: StatusTextPalette.native(.conflict, preferences: preferences)) }
}

struct StatusColorPreferences: Equatable {
    private var values: [String: Int] = [:]
    init() {}
    static func load(_ preferences: UserDefaults) -> Self {
        var result = Self()
        for role in StatusTextRole.allCases {
            guard let value = preferences.object(forKey: role.preferenceKey) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  (0...0xffffff).contains(value.intValue), value.doubleValue == Double(value.intValue) else { continue }
            result.values[role.rawValue] = value.intValue
        }
        return result
    }
    func rgb(_ role: StatusTextRole) -> [Int] {
        guard let value = values[role.rawValue] else { return role.rgb }
        return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
    }
    mutating func set(_ role: StatusTextRole, rgb: [Int]) {
        guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return }
        values[role.rawValue] = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
    }
    func save(_ preferences: UserDefaults) {
        for role in StatusTextRole.allCases {
            let channels = rgb(role)
            preferences.set(channels[0] << 16 | channels[1] << 8 | channels[2], forKey: role.preferenceKey)
        }
        preferences.set(preferences.integer(forKey: StatusTextRole.modified.preferenceKey), forKey: "Colors.PropertyChanged")
    }
}

extension Notification.Name {
    static let statusColorsChanged = Notification.Name("TurtleGit.StatusColorsChanged")
}

/// Native and SwiftUI list owners subscribe so Apply updates existing windows.
final class StatusColorUpdates: ObservableObject {
    static let shared = StatusColorUpdates()
    @Published private(set) var revision = 0
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .statusColorsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor final class StatusColorSettingsModel: ObservableObject {
    private let preferences: UserDefaults
    @Published private(set) var draft: StatusColorPreferences
    private var saved: StatusColorPreferences
    var changed: Bool { draft != saved }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let value = StatusColorPreferences.load(preferences); draft = value; saved = value
    }
    func color(_ role: StatusTextRole) -> Color {
        let rgb = draft.rgb(role)
        return Color(.sRGB, red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255)
    }
    func setColor(_ role: StatusTextRole, color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        set(role, rgb: [rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { min(255,max(0,Int(($0 * 255).rounded()))) })
    }
    func set(_ role: StatusTextRole, rgb: [Int]) { draft.set(role, rgb: rgb) }
    func automatic(_ role: StatusTextRole) { draft.set(role, rgb: role.rgb) }
    func restoreDefaults() { draft = StatusColorPreferences() }
    func cancel() { draft = saved }
    func apply() {
        guard changed else { return }
        draft.save(preferences); saved = draft
        NotificationCenter.default.post(name: .statusColorsChanged, object: nil)
    }
}

struct StatusColorsSettings: View {
    @ObservedObject var model: StatusColorSettingsModel
    private let roles: [StatusTextRole] = [.added,.deleted,.merged,.modified,.conflict,.renamed]
    var body: some View {
        GroupBox("Status colors") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(roles, id: \.self) { role in
                    HStack {
                        ColorPicker(role.title, selection: Binding(get: { model.color(role) }, set: { model.setColor(role, color: $0) }), supportsOpacity: false)
                        StatusColorButton("Default") { model.automatic(role) }.help("Restore the default \(role.title.lowercased()) color")
                    }
                }
                Text("Choose light-mode colors. Dark mode follows TortoiseGit’s color conversion.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    StatusColorButton("Restore Defaults") { model.restoreDefaults() }
                    Spacer()
                    StatusColorButton("Cancel") { model.cancel() }.disabled(!model.changed)
                    StatusColorButton("Apply") { model.apply() }.disabled(!model.changed)
                }
            }.padding(8)
        }
    }
}

@MainActor private struct StatusColorButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .rounded; button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.isEnabled = enabled; context.coordinator.action = action
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.intrinsicContentSize }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { guard sender.isEnabled else { return }; action() }
    }
}
