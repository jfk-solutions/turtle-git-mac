import Foundation

public struct MergeEditorPreferences: Equatable, Sendable {
    public var tabWidth: Int
    public var useSpaces: Bool
    public var smartTab: Bool
    public init(tabWidth: Int = 4, useSpaces: Bool = false, smartTab: Bool = false) {
        self.tabWidth = min(1000, max(1, tabWidth)); self.useSpaces = useSpaces; self.smartTab = smartTab
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(tabWidth: defaults.object(forKey: "TurtleGitMerge.TabSize") == nil ? 4 : defaults.integer(forKey: "TurtleGitMerge.TabSize"),
             useSpaces: defaults.bool(forKey: "TurtleGitMerge.UseSpaces"), smartTab: defaults.bool(forKey: "TurtleGitMerge.SmartTab"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(min(1000, max(1, tabWidth)), forKey: "TurtleGitMerge.TabSize")
        defaults.set(useSpaces, forKey: "TurtleGitMerge.UseSpaces")
        defaults.set(smartTab, forKey: "TurtleGitMerge.SmartTab")
    }
}
