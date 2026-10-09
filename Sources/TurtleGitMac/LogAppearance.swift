import AppKit
import SwiftUI
import TurtleGitCore
import CoreFoundation

/// CColors roles used by GitLogListBase. Packed preferences use native RRGGBB.
enum LogColorRole: String, CaseIterable {
    case currentBranch = "CurrentBranch", localBranch = "LocalBranch", remoteBranch = "RemoteBranch", tag = "Tag"
    case stash = "Stash", bisectGood = "BisectGood", bisectBad = "BisectBad", bisectSkip = "BisectSkip"
    case noteNode = "NoteNode", otherRef = "OtherRef", filterMatch = "FilterMatch"
    case branchLine1 = "BranchLine1", branchLine2 = "BranchLine2", branchLine3 = "BranchLine3", branchLine4 = "BranchLine4"
    case branchLine5 = "BranchLine5", branchLine6 = "BranchLine6", branchLine7 = "BranchLine7", branchLine8 = "BranchLine8"
    static let references: [Self] = [.currentBranch,.localBranch,.remoteBranch,.tag,.noteNode,.otherRef]
    static let matches: [Self] = [.filterMatch]
    static let lanes: [Self] = [.branchLine1,.branchLine2,.branchLine3,.branchLine4,.branchLine5,.branchLine6,.branchLine7,.branchLine8]
    var preferenceKey: String { "Colors." + rawValue }
    var title: String {
        switch self {
        case .filterMatch: return "Filter matches"
        case .currentBranch: return "Current branch"
        case .localBranch: return "Local branches"
        case .remoteBranch: return "Remote branches"
        case .tag: return "Tags"
        case .noteNode: return "Notes"
        case .otherRef: return "Other refs"
        default: return Self.lanes.firstIndex(of: self).map { "Branch line \($0 + 1)" } ?? rawValue
        }
    }
    var rgb: [Int] {
        switch self {
        case .currentBranch, .filterMatch: return [200,0,0]
        case .localBranch: return [0,195,0]
        case .remoteBranch: return [255,221,170]
        case .tag: return [255,255,0]
        case .stash, .branchLine5: return [128,128,128]
        case .bisectGood: return [0,100,200]
        case .bisectBad, .branchLine2: return [255,0,0]
        case .bisectSkip: return [192,192,192]
        case .noteNode: return [160,160,0]
        case .otherRef: return [224,224,224]
        case .branchLine1: return [0,0,0]
        case .branchLine3: return [0,255,0]
        case .branchLine4: return [0,0,255]
        case .branchLine6: return [128,128,0]
        case .branchLine7: return [0,128,128]
        case .branchLine8: return [128,0,128]
        }
    }
    static func reference(_ reference: RevisionReference, goodTerm: String = "good", badTerm: String = "bad") -> Self {
        let name = reference.name
        if name.utf8.starts(with: "refs/heads/".utf8) { return reference.isCurrent ? .currentBranch : .localBranch }
        if name.utf8.starts(with: "refs/remotes/".utf8) { return .remoteBranch }
        if name.utf8.starts(with: "refs/tags/".utf8) { return .tag }
        if name.utf8.starts(with: "refs/stash".utf8) { return .stash }
        let kind = reference.kind ?? HistoryReferenceLabel.shortName(name, terms: HistoryBisectTerms(good: goodTerm, bad: badTerm)).kind
        if kind == .bisectGood { return .bisectGood }
        if kind == .bisectSkip { return .bisectSkip }
        if kind == .bisectBad { return .bisectBad }
        if kind == .notes { return .noteNode }
        return .otherRef
    }
}

struct LogColorPreferences: Equatable {
    private var values: [LogColorRole: Int] = [:]
    var lineWidth = 2
    var nodeSize = 10
    static let lineWidthKey = "Graph.LogLineWidth", nodeSizeKey = "Graph.LogNodeSize"
    static func integer(_ preferences: UserDefaults, key: String, range: ClosedRange<Int>) -> Int? {
        guard let value = preferences.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), range.contains(value.intValue), value.doubleValue == Double(value.intValue) else { return nil }
        return value.intValue
    }
    static func load(_ preferences: UserDefaults) -> Self {
        var result = Self()
        for role in LogColorRole.allCases { result.values[role] = integer(preferences, key: role.preferenceKey, range: 0...0xffffff) }
        result.lineWidth = integer(preferences, key: lineWidthKey, range: 1...10) ?? 2
        result.nodeSize = integer(preferences, key: nodeSizeKey, range: 1...30) ?? 10
        return result
    }
    func rgb(_ role: LogColorRole) -> [Int] {
        guard let value = values[role] else { return role.rgb }
        return [(value >> 16) & 255,(value >> 8) & 255,value & 255]
    }
    mutating func set(_ role: LogColorRole, rgb: [Int]) {
        guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return }
        values[role] = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
    }
    func save(_ preferences: UserDefaults) {
        // Preserve non-editable Stash/Bisect and unrelated status roles.
        for role in LogColorRole.references + LogColorRole.matches + LogColorRole.lanes {
            let rgb = rgb(role); preferences.set(rgb[0] << 16 | rgb[1] << 8 | rgb[2], forKey: role.preferenceKey)
        }
        preferences.set(lineWidth, forKey: Self.lineWidthKey); preferences.set(nodeSize, forKey: Self.nodeSizeKey)
    }
}

enum LogPalette {
    static func native(_ role: LogColorRole, preferences: UserDefaults) -> NSColor {
        let rgb = LogColorPreferences.load(preferences).rgb(role)
        return NSColor(name: nil) { appearance in
            let mode = StatusTextPalette.appearanceTraits(appearance)
            let channels = StatusTextPalette.transform(rgb, dark: mode.dark, highContrast: mode.highContrast)
            return NSColor(srgbRed: CGFloat(channels[0])/255, green: CGFloat(channels[1])/255, blue: CGFloat(channels[2])/255, alpha: 1)
        }
    }
    static func foreground(background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.sRGB)!
        // Source DrawTagBranch's weighted dark-background threshold.
        let channels = [rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return channels[0]*30 + channels[1]*59 + channels[2]*11 <= 12800 ? .white : .black
    }
    static func lane(_ index: Int, preferences: UserDefaults) -> NSColor {
        native(LogColorRole.lanes[max(0,index) % LogColorRole.lanes.count], preferences: preferences)
    }
}

@MainActor final class LogColorSettingsModel: ObservableObject {
    private let preferences: UserDefaults
    @Published private(set) var draft: LogColorPreferences
    private var saved: LogColorPreferences
    var changed: Bool { draft != saved }
    init(preferences: UserDefaults = .standard) { self.preferences = preferences; let value = LogColorPreferences.load(preferences); draft = value; saved = value }
    func color(_ role: LogColorRole) -> Color { let c = draft.rgb(role); return Color(.sRGB, red: Double(c[0])/255, green: Double(c[1])/255, blue: Double(c[2])/255) }
    func set(_ role: LogColorRole, rgb: [Int]) { draft.set(role, rgb: rgb) }
    func setColor(_ role: LogColorRole, color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        set(role, rgb: [c.redComponent,c.greenComponent,c.blueComponent].map { min(255,max(0,Int(($0*255).rounded()))) })
    }
    func setLineWidth(_ width: Int) { guard (1...10).contains(width) else { return }; draft.lineWidth = width }
    func setNodeSize(_ size: Int) { guard (1...30).contains(size) else { return }; draft.nodeSize = size }
    func automatic(_ role: LogColorRole) { draft.set(role, rgb: role.rgb) }
    func restoreDefaults() { for role in LogColorRole.references + LogColorRole.matches + LogColorRole.lanes { automatic(role) }; draft.lineWidth = 2; draft.nodeSize = 10 }
    func cancel() { draft = saved }
    func apply() { guard changed else { return }; draft.save(preferences); saved = draft; NotificationCenter.default.post(name: .statusColorsChanged, object: nil) }
}

struct LogColorsSettings: View {
    @ObservedObject var model: LogColorSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Filter matches") { rows(LogColorRole.matches) }
            GroupBox("Reference labels") { rows(LogColorRole.references) }
            GroupBox("Log graph") {
                VStack {
                    rows(LogColorRole.lanes)
                    Picker("Line width", selection: Binding(get: { model.draft.lineWidth }, set: model.setLineWidth)) { ForEach(1...10, id: \.self) { Text(String($0)).tag($0) } }
                    Picker("Node size", selection: Binding(get: { model.draft.nodeSize }, set: model.setNodeSize)) { ForEach(1...30, id: \.self) { Text(String($0)).tag($0) } }
                }.padding(8)
            }
            HStack {
                StatusColorButton("Restore Defaults") { model.restoreDefaults() }
                Spacer()
                StatusColorButton("Cancel") { model.cancel() }.disabled(!model.changed)
                StatusColorButton("Apply") { model.apply() }.disabled(!model.changed)
            }
        }
    }
    private func rows(_ roles: [LogColorRole]) -> some View {
        VStack(spacing: 8) {
            ForEach(roles, id: \.self) { role in
                HStack {
                    ColorPicker(role.title, selection: Binding(get: { model.color(role) }, set: { model.setColor(role, color: $0) }), supportsOpacity: false)
                    StatusColorButton("Default") { model.automatic(role) }
                }
            }
        }.padding(8)
    }
}


/// Source DrawUpstream glyph, drawn independently of the shortened reference text.
enum LogUpstreamMarker {
    static func attachment(foreground: NSColor, font: NSFont, isHead: Bool) -> NSTextAttachment {
        let height = max(14, ceil(font.ascender - font.descender))
        let bold: CGFloat = isHead ? 2 : 1
        let image = NSImage(size: NSSize(width: 9, height: height), flipped: false) { rect in
            foreground.setStroke()
            let path = NSBezierPath(); path.lineWidth = bold
            // DrawUpstream's shaft and fork, adapted to AppKit's upward Y axis.
            path.move(to: NSPoint(x: 2 + bold, y: 3)); path.line(to: NSPoint(x: 2 + bold, y: rect.height - 3))
            path.move(to: NSPoint(x: 3, y: rect.height - 2)); path.line(to: NSPoint(x: 0, y: rect.height - 5))
            path.move(to: NSPoint(x: 2 + bold, y: rect.height - 2)); path.line(to: NSPoint(x: 6 + bold, y: rect.height - 5))
            path.move(to: NSPoint(x: 1, y: rect.height - 3 - bold)); path.line(to: NSPoint(x: 6 + bold, y: rect.height - 3 - bold))
            path.stroke(); return true
        }
        let attachment = NSTextAttachment(); attachment.image = image
        attachment.bounds = NSRect(x: 0, y: font.descender, width: 9, height: height)
        return attachment
    }
}
