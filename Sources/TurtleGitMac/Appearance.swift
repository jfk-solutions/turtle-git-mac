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
    private let preferences: UserDefaults
    @Published var choice: AppearanceChoice {
        didSet { preferences.set(choice.rawValue, forKey: "appearance"); apply() }
    }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        choice = AppearanceChoice(rawValue: preferences.string(forKey: "appearance") ?? "system") ?? .system
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

@MainActor final class SettingsAppearanceDraft: ObservableObject {
    @Published var choice: AppearanceChoice
    private let appearance: AppAppearance
    init(appearance: AppAppearance) { self.appearance = appearance; choice = appearance.choice }
    var changed: Bool { choice != appearance.choice }
    func apply() { appearance.choice = choice }
    func cancel() { choice = appearance.choice }
}

struct AppearanceSettings: View {
    @ObservedObject var draft: SettingsAppearanceDraft
    var body: some View {
        Form {
            Picker("Appearance", selection: $draft.choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text("Status colors, reference labels and graph lanes are configured on Colors 1, Colors 2 and Colors 3.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsParticipant("general", page: .general, value: draft.choice,
            modified: { draft.changed }, apply: { draft.apply(); return true }, cancel: draft.cancel)
    }
}

/// Native projections of SettingsColors.cpp / SettingsColors2.cpp / SettingsColors3.cpp.
struct SourceColorSettings: View {
    let page: SettingsPageID
    @ObservedObject var appearance: SettingsAppearanceDraft
    @Environment(\.settingsTransaction) private var transaction
    @StateObject private var status: StatusColorSettingsModel
    @StateObject private var log: LogColorSettingsModel
    @State private var useLocal: Bool
    @State private var savedUseLocal: Bool
    private let preferences: UserDefaults
    init(page: SettingsPageID, appearance: SettingsAppearanceDraft, preferences: UserDefaults = .standard) {
        self.page = page; self.appearance = appearance; self.preferences = preferences
        _status = StateObject(wrappedValue: StatusColorSettingsModel(preferences: preferences))
        _log = StateObject(wrappedValue: LogColorSettingsModel(preferences: preferences))
        let value = preferences.bool(forKey: "Graph.RevGraphUseLocalForCur")
        _useLocal = State(initialValue: value); _savedUseLocal = State(initialValue: value)
    }
    private var roles: [LogColorRole] {
        switch page {
        case .colors1: return [.noteNode, .otherRef]
        case .colors2: return [.currentBranch, .localBranch, .remoteBranch, .tag, .filterMatch]
        default: return LogColorRole.lanes
        }
    }
    private var modified: Bool { log.changed || (page == .colors1 && (status.changed || useLocal != savedUseLocal)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if page == .colors1 {
                GroupBox("Status and action colors") {
                    VStack(spacing: 10) {
                        statusRow(.conflict, "possible or real conflict/obstructed")
                        statusRow(.added, "added files")
                        statusRow(.deleted, "missing/deleted/replaced")
                        statusRow(.merged, "merged")
                        statusRow(.modified, "modified/copied")
                        statusRow(.renamed, "renamed")
                    }.padding(10)
                }
                GroupBox("Revision graph") {
                    VStack(alignment: .leading, spacing: 10) {
                        logRow(.noteNode, "Note node")
                        logRow(.otherRef, "Unknown ref-types")
                        Toggle("Use local branch color for current branch", isOn: $useLocal)
                    }.padding(10)
                }
                Toggle("Dark theme", isOn: Binding(get: { appearance.choice == .dark }, set: { appearance.choice = $0 ? .dark : .light }))
                Text("Follow System is available on General. Colors use TortoiseGit’s dark-mode conversion.").font(.caption).foregroundStyle(.secondary)
            } else if page == .colors2 {
                GroupBox("Log Graphic") {
                    VStack(spacing: 10) {
                        logRow(.currentBranch, "Current Branch")
                        logRow(.localBranch, "Local Branch")
                        logRow(.remoteBranch, "Remote Branch")
                        logRow(.tag, "Tag")
                    }.padding(10)
                }
                logRow(.filterMatch, "Filter match").padding(.horizontal, 10)
            } else {
                GroupBox("Log Branch Line") {
                    VStack(spacing: 10) {
                        ForEach(Array(LogColorRole.lanes.enumerated()), id: \.element) { index, role in logRow(role, "LINE" + String(index + 1)) }
                        Picker("Line width", selection: Binding(get: { log.draft.lineWidth }, set: log.setLineWidth)) {
                            ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                        }
                        Picker("Node size", selection: Binding(get: { log.draft.nodeSize }, set: log.setNodeSize)) {
                            ForEach(1...30, id: \.self) { Text(String($0)).tag($0) }
                        }
                    }.padding(10)
                }
            }
            Spacer()
            HStack { Spacer(); StatusColorButton("Restore Default", action: restore) }
        }.padding(20)
        .settingsParticipant(page.rawValue, page: page, value: log.draft, modified: { modified }, apply: { apply(); return true }, cancel: cancel)
        .onChange(of: status.draft) { _ in transaction?.notify() }
        .onChange(of: useLocal) { _ in transaction?.notify() }
        .onChange(of: appearance.choice) { _ in transaction?.notify() }
    }
    private func statusRow(_ role: StatusTextRole, _ title: String) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { status.color(role) }, set: { status.setColor(role, color: $0) }), supportsOpacity: false)
            StatusColorButton("Default") { status.automatic(role) }
        }
    }
    private func logRow(_ role: LogColorRole, _ title: String) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { log.color(role) }, set: { log.setColor(role, color: $0) }), supportsOpacity: false)
            StatusColorButton("Default") { log.automatic(role) }
        }
    }
    private func restore() {
        for role in roles { log.automatic(role) }
        if page == .colors1 { status.restoreDefaults(); useLocal = false }
        if page == .colors3 { log.setLineWidth(2); log.setNodeSize(10) }
    }
    private func apply() {
        if page == .colors1 {
            status.apply()
            if useLocal != savedUseLocal {
                preferences.set(useLocal, forKey: "Graph.RevGraphUseLocalForCur"); savedUseLocal = useLocal
                NotificationCenter.default.post(name: .statusColorsChanged, object: nil)
            }
        }
        log.apply(roles: roles, dimensions: page == .colors3)
    }
    private func cancel() { status.cancel(); log.cancel(); useLocal = savedUseLocal }
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
    static func appearanceTraits(_ appearance: NSAppearance) -> (dark: Bool, highContrast: Bool) {
        let dark = appearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua
        // AppKit resolves named accessibility appearances to Aqua/Dark Aqua
        // when system Increase Contrast is off. Read the actual accessibility
        // setting; bestMatch alone cannot distinguish the high-contrast mode.
        return (dark, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
    static func native(_ role: StatusTextRole, preferences: UserDefaults = .standard) -> NSColor {
        let base = StatusColorPreferences.load(preferences).rgb(role)
        return NSColor(name: nil) { appearance in
            let mode = appearanceTraits(appearance)
            let channels = transform(base, dark: mode.dark, highContrast: mode.highContrast)
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
    private var accessibilityObserver: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .statusColorsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.revision += 1 }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
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
    @Environment(\.settingsTransaction) private var transaction
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
                    if transaction == nil {
                        StatusColorButton("Cancel") { model.cancel() }.disabled(!model.changed)
                        StatusColorButton("Apply") { model.apply() }.disabled(!model.changed)
                    }
                }
            }.padding(8)
        }
    }
}

@MainActor struct StatusColorButton: NSViewRepresentable {
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
