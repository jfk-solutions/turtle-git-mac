import Foundation

/// Read-only Properties values, following GitRev's first-newline message split.
public struct GitBlameRevisionProperties: Sendable {
    public let subject: String
    public let body: String
    public let authorDate: String
    public let committerDate: String
    public init(entry: LogEntry, timeZone: TimeZone = .current) {
        if let newline = entry.message.firstIndex(of: "\n") {
            subject = String(entry.message[..<newline])
            body = String(entry.message[entry.message.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            subject = entry.message.isEmpty ? entry.subject : entry.message
            body = ""
        }
        let parser = ISO8601DateFormatter()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func date(_ raw: String) -> String {
            parser.date(from: raw).map(formatter.string(from:)) ?? raw
        }
        authorDate = date(entry.date); committerDate = date(entry.committerDate)
    }
}

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
