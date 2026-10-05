import Foundation

public enum UnifiedDiffLineStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case command, position, header, comment, added, removed, context
    public static var configurable: [Self] { allCases.filter { $0 != .context } }
    public var label: String { "Diff " + (self == .added || self == .removed ? rawValue + " lines" : rawValue) }
    /// Lexilla's pinned LexDiff line rules; combined patch variants use the
    /// added/removed palettes, as in TortoiseUDiff::SetTheme.
    public static func classify(_ line: String) -> Self {
        func numericPosition(_ offset: Int) -> Bool {
            guard !line.contains("/") else { return false }
            var bytes = Array(line.utf8.dropFirst(offset))
            while let first = bytes.first, first == 32 || (9...13).contains(first) { bytes.removeFirst() }
            if bytes.first == 43 || bytes.first == 45 { bytes.removeFirst() }
            return bytes.prefix(while: { (48...57).contains($0) }).contains { $0 != 48 }
        }
        if line.hasPrefix("diff ") || line.hasPrefix("Index: ") { return .command }
        if line.hasPrefix("---"), !line.hasPrefix("----") {
            if line.utf8.dropFirst(3).first == 13 || line.utf8.dropFirst(3).first == 10 || (line.hasPrefix("--- ") && numericPosition(4)) { return .position }
            return line.hasPrefix("--- ") ? .header : .removed
        }
        if line.hasPrefix("+++ ") { return numericPosition(4) ? .position : .header }
        if line.hasPrefix("====") || line.hasPrefix("? ") { return .header }
        if line.hasPrefix("***") { return line.hasPrefix("****") || (line.hasPrefix("*** ") && numericPosition(4)) ? .position : .header }
        if let first = line.utf8.first, first == 64 || (48...57).contains(first) { return .position }
        if line.hasPrefix("+") || line.hasPrefix(">") { return .added }
        if line.hasPrefix("-") || line.hasPrefix("<") { return .removed }
        if line.hasPrefix("!") || line.hasPrefix(" ") { return .context }
        return .comment
    }
}
public struct UnifiedDiffColors: Codable, Equatable, Sendable {
    public var foreground: UInt32
    public var background: UInt32
    public init(_ foreground: UInt32, _ background: UInt32) { self.foreground = foreground; self.background = background }
}
public struct UnifiedDiffAppearance: Codable, Equatable, Sendable {
    public var fontName = "Menlo"
    public var fontSize = 10
    public var tabSize = 4
    public var light: [UnifiedDiffLineStyle: UnifiedDiffColors] = [:]
    public var dark: [UnifiedDiffLineStyle: UnifiedDiffColors] = [:]
    public init() {}
    public func colors(_ style: UnifiedDiffLineStyle, dark isDark: Bool) -> UnifiedDiffColors {
        if let value = (isDark ? dark : light)[style], value.foreground <= 0xffffff, value.background <= 0xffffff { return value }
        let text: UInt32 = isDark ? 0xdddddd : 0x000000, background: UInt32 = isDark ? 0x202020 : 0xffffff
        switch style {
        case .command: return .init(isDark ? 0xc9e2f5 : 0x0a2436, background)
        case .position: return .init(isDark ? 0xff2020 : 0xff0000, background)
        case .header: return .init(isDark ? 0xc00000 : 0x800000, isDark ? 0x303000 : 0xffff80)
        case .comment: return .init(0x008000, background)
        case .added: return .init(text, isDark ? 0x104010 : 0xccffcc)
        case .removed: return .init(text, isDark ? 0x402020 : 0xffdddd)
        case .context: return .init(text, background)
        }
    }
    public mutating func restoreColors(dark isDark: Bool) { if isDark { dark = [:] } else { light = [:] } }
    private var sanitized: Self {
        var value = self
        if fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fontName.contains("\0") { value.fontName = "Menlo" }
        value.fontSize = min(1000, max(1, fontSize)); value.tabSize = min(1000, max(1, tabSize))
        value.light = light.filter { $0.value.foreground <= 0xffffff && $0.value.background <= 0xffffff }
        value.dark = dark.filter { $0.value.foreground <= 0xffffff && $0.value.background <= 0xffffff }
        return value
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let bytes = defaults.data(forKey: "TurtleGit.UnifiedDiffAppearance"), let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
        return value.sanitized
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(sanitized), forKey: "TurtleGit.UnifiedDiffAppearance")
    }
}
