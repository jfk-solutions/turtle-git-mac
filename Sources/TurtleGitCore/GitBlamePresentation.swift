import Foundation

public struct GitBlamePresentation: Equatable, Sendable {
    public var fontName = "Menlo"
    public var fontSize = 10
    public var tabSize = 4
    public var recentColor: UInt32 = 0xffff50
    public var oldColor: UInt32 = 0xffffff
    public var darkRecentColor: UInt32 = 0x505000
    public var darkOldColor: UInt32 = 0x202020
    public init() {}
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        var result = Self()
        let prefix = "TurtleGitBlame."
        if let name = defaults.string(forKey: prefix + "FontName"), !name.isEmpty { result.fontName = name }
        func size(_ key: String, fallback: Int) -> Int {
            defaults.string(forKey: prefix + key).flatMap(Int.init).map { min(1000, max(1, $0)) } ?? fallback
        }
        func color(_ key: String, fallback: UInt32) -> UInt32 {
            guard let value = defaults.string(forKey: prefix + key).flatMap(UInt32.init), value <= 0xffffff else { return fallback }
            return value
        }
        result.fontSize = size("FontSize", fallback: 10); result.tabSize = size("TabSize", fallback: 4)
        result.recentColor = color("RecentColor", fallback: result.recentColor); result.oldColor = color("OldColor", fallback: result.oldColor)
        result.darkRecentColor = color("DarkRecentColor", fallback: result.darkRecentColor); result.darkOldColor = color("DarkOldColor", fallback: result.darkOldColor)
        return result
    }
    public func save(to defaults: UserDefaults = .standard) {
        let prefix = "TurtleGitBlame."
        defaults.set(fontName.isEmpty ? "Menlo" : fontName, forKey: prefix + "FontName")
        defaults.set(String(min(1000, max(1, fontSize))), forKey: prefix + "FontSize")
        defaults.set(String(min(1000, max(1, tabSize))), forKey: prefix + "TabSize")
        for (key, value) in [("RecentColor", recentColor), ("OldColor", oldColor), ("DarkRecentColor", darkRecentColor), ("DarkOldColor", darkOldColor)] {
            defaults.set(String(value & 0xffffff), forKey: prefix + key)
        }
    }
    public func ageColor(rank: Int?, historyCount: Int, dark: Bool, enabled: Bool) -> UInt32 {
        let old = dark ? darkOldColor : oldColor, recent = dark ? darkRecentColor : recentColor
        var slider = 0
        if enabled, let rank, historyCount >= 0 { slider = min(100, max(0, (historyCount - rank) * 100 / (historyCount + 1))) }
        func component(_ shift: Int) -> UInt32 {
            let old = Int((old >> shift) & 255), recent = Int((recent >> shift) & 255)
            return UInt32((recent * slider + old * (100 - slider)) / 100) << shift
        }
        return component(16) | component(8) | component(0)
    }
}
