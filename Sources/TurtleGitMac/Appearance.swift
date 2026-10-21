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
    private var previews:[(UUID,AppearanceChoice)]=[]
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
        let effective=previews.last?.1 ?? choice
        NSApp.appearance = effective == .system ? nil : NSAppearance(named: effective == .dark ? .darkAqua : .aqua)
    }
    func preview(_ value:AppearanceChoice,owner:UUID) {
        if let index=previews.firstIndex(where:{$0.0==owner}) {previews[index].1=value}
        else {previews.append((owner,value))}
        apply()
    }
    func endPreview(owner:UUID) {previews.removeAll{$0.0==owner};apply()}

}

@MainActor final class SettingsAppearanceDraft: ObservableObject {
    @Published var choice: AppearanceChoice {didSet {if previewing {appearance.preview(choice,owner:previewID)}}}
    private let previewID=UUID()
    private var previewing=false
    private let appearance: AppAppearance
    init(appearance: AppAppearance) { self.appearance = appearance; choice = appearance.choice }
    var changed: Bool { choice != appearance.choice }
    func apply() { appearance.choice = choice }
    func cancel() { choice = appearance.choice }
    func beginPreview() {guard !previewing else{return};previewing=true;appearance.preview(choice,owner:previewID)}
    func endPreview() {guard previewing else{return};previewing=false;appearance.endPreview(owner:previewID)}
}

/// Standalone General pages retain their registration; the property sheet owns
/// this participant once, independently of which cached pages were visited.
struct SettingsAppearanceParticipant:ViewModifier {
    @Environment(\.settingsTransaction) private var transaction
    @State private var registration=UUID()
    @ObservedObject var draft:SettingsAppearanceDraft
    let managedByOwner:Bool
    func body(content:Content)->some View {
        content.onAppear {
            guard !managedByOwner else{return}
            transaction?.register("general",participant:.init(page:.general,modified:{draft.changed},validate:{nil},apply:{draft.apply();return true},cancel:draft.cancel),registration:registration)
        }.onChange(of:draft.choice){_ in if !managedByOwner {transaction?.notify()}}
    }
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
                        SettingsDraftCheckbox(title:"Use local branch color for current branch",identifier:"Settings.Colors1.UseLocal",value:$useLocal).frame(height:24)
                    }.padding(10)
                }
                SettingsDraftCheckbox(title:"Dark theme",identifier:"Settings.Colors1.DarkTheme",value:Binding(get:{appearance.choice == .dark},set:{appearance.choice=$0 ? .dark:.light})).frame(height:24)
                Text("Follow System is available on General. Saved colors use TortoiseGit’s conversion; dark status text is lightened when needed for macOS table backgrounds.").font(.caption).foregroundStyle(.secondary)
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
                        HStack {Text("Line width");SettingsDraftIntegerChoice(title:"Line width",range:1...10,value:Binding(get:{log.draft.lineWidth},set:log.setLineWidth)).frame(width:80,height:26)}
                        HStack {Text("Node size");SettingsDraftIntegerChoice(title:"Node size",range:1...30,value:Binding(get:{log.draft.nodeSize},set:log.setNodeSize)).frame(width:80,height:26)}
                        SettingsGraphPreview(palette:log.draft).frame(height:64).accessibilityIdentifier("Settings.Colors3.Preview")
                    }.padding(10)
                }
            }
            Spacer()
            HStack { Spacer(); StatusColorButton("Restore Default", action: restore) }
        }.padding(16)
        .groupBoxStyle(SourceSettingsGroupBoxStyle())
        .settingsParticipant(page.rawValue, page: page, value: log.draft, modified: { modified }, apply: { apply(); return true }, cancel: cancel)
        .onChange(of: status.draft) { _ in transaction?.notify() }
        .onChange(of: useLocal) { _ in transaction?.notify() }
        .onChange(of: appearance.choice) { _ in transaction?.notify() }
    }
    private func statusRow(_ role: StatusTextRole, _ title: String) -> some View {
        HStack {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            SettingsPaletteSample(rgb:status.draft.rgb(role),title:"file.txt",background:false,statusText:true).frame(width:80)
            NativeSettingsColorChoice(namespace:"StatusColors",value:SettingsColorValue.packed(status.draft.rgb(role)),automatic:SettingsColorValue.packed(role.rgb),label:title,identifier:role.rawValue,changed:{ status.set(role,rgb:SettingsColorValue.channels($0)) }).frame(width:152,height:26)
        }
    }
    private func logRow(_ role: LogColorRole, _ title: String) -> some View {
        HStack {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            if page != .colors3 {SettingsPaletteSample(rgb:log.draft.rgb(role),title:role == .filterMatch ? "match":"ref",background:role != .filterMatch).frame(width:80)}
            NativeSettingsColorChoice(namespace:"LogColors",value:SettingsColorValue.packed(log.draft.rgb(role)),automatic:SettingsColorValue.packed(role.rgb),label:title,identifier:role.rawValue,changed:{ log.set(role,rgb:SettingsColorValue.channels($0)) }).frame(width:152,height:26)
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
    /// Keep source RGB persistence/conversion independent of native text contrast.
    static func text(_ role: StatusTextRole, preferences: UserDefaults = .standard) -> NSColor {
        text(rgb:StatusColorPreferences.load(preferences).rgb(role))
    }
    static func text(rgb base:[Int])->NSColor {
        return NSColor(name: nil) { appearance in
            let mode = appearanceTraits(appearance)
            var channels = transform(base, dark: mode.dark, highContrast: mode.highContrast)
            if mode.dark {
                channels = StatusTextContrast.adapt(channels, backgrounds: StatusTextContrast.backgrounds(appearance), minimum: mode.highContrast ? 7 : 4.5)
            }
            return NSColor(srgbRed: CGFloat(channels[0]) / 255, green: CGFloat(channels[1]) / 255, blue: CGFloat(channels[2]) / 255, alpha: 1)
        }
    }
}

/// A native dark-table adaptation, applied only after the pinned source transform.
/// Mixing toward white retains hue and needs no changes to saved color values.
enum StatusTextContrast {
    static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    static func ratio(_ rgb: [Int], background: [Double]) -> Double {
        let foreground = luminance(rgb.map { Double($0) / 255 }), backdrop = luminance(background)
        return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
    }
    static func backgrounds(_ appearance: NSAppearance) -> [[Double]] {
        var result: [[Double]] = []
        appearance.performAsCurrentDrawingAppearance {
            let surface = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
            let backdrop = [Double(surface.redComponent), Double(surface.greenComponent), Double(surface.blueComponent)]
            for color in NSColor.alternatingContentBackgroundColors + [.controlBackgroundColor, .textBackgroundColor, .windowBackgroundColor] {
                if let value = color.usingColorSpace(.sRGB) {
                    let alpha = Double(value.alphaComponent)
                    let channels = [Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent)]
                    // AppKit's alternating-row tint can be translucent white.
                    // Contrast is against the composited row, not opaque white.
                    result.append(zip(channels, backdrop).map { $0 * alpha + $1 * (1 - alpha) })
                }
            }
        }
        return result
    }
    static func adapt(_ rgb: [Int], backgrounds: [[Double]], minimum: Double) -> [Int] {
        func passes(_ value: [Int]) -> Bool { backgrounds.allSatisfy { ratio(value, background: $0) >= minimum } }
        guard !passes(rgb) else { return rgb }
        func mixed(_ amount: Int) -> [Int] { rgb.map { ($0 * (255 - amount) + 255 * amount + 127) / 255 } }
        var low = 0, high = 255
        while low < high {
            let middle = (low + high) / 2
            if passes(mixed(middle)) { high = middle } else { low = middle + 1 }
        }
        return mixed(high)
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
        return statusTextRole.map { Color(nsColor: StatusTextPalette.text($0, preferences: preferences)) } ?? Color(nsColor: .labelColor)
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
        return statusTextRole.map { Color(nsColor: StatusTextPalette.text($0, preferences: preferences)) } ?? .primary
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
        return role.map { Color(nsColor: StatusTextPalette.text($0, preferences: preferences)) } ?? Color(nsColor: .labelColor)
    }
}

extension LFSFileResult {
    /// Source LFS file notifications are neutral; ReportError uses Conflict.
    var resultTextColor: Color { resultTextColor(preferences: .standard) }
    func resultTextColor(preferences: UserDefaults) -> Color { success ? .primary : Color(nsColor: StatusTextPalette.text(.conflict, preferences: preferences)) }
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
                        Text(role.title).frame(maxWidth:.infinity,alignment:.leading)
                        NativeSettingsColorChoice(namespace:"StatusColors",value:SettingsColorValue.packed(model.draft.rgb(role)),automatic:SettingsColorValue.packed(role.rgb),label:role.title,identifier:role.rawValue,changed:{ model.set(role,rgb:SettingsColorValue.channels($0)) }).frame(width:152,height:26)
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
