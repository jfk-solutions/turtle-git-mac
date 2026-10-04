import Foundation

public enum GitBlamePreferences {
    private static let prefix = "TurtleGitBlame."
    public static func load(from defaults: UserDefaults = .standard) -> GitBlameOptions {
        var options = GitBlameOptions()
        options.ignoreWhitespace = defaults.bool(forKey: prefix + "IgnoreWhitespace")
        options.onlyFirstParent = defaults.bool(forKey: prefix + "OnlyFirstParent")
        options.detectionMode = defaults.string(forKey: prefix + "DetectMovedOrCopiedLines").flatMap(Int.init).flatMap(GitBlameDetectionMode.init(rawValue:)) ?? .disabled
        options.withinFileCharacters = defaults.string(forKey: prefix + "WithinFileCharacters").flatMap(UInt32.init) ?? 20
        options.betweenFileCharacters = defaults.string(forKey: prefix + "BetweenFileCharacters").flatMap(UInt32.init) ?? 40
        return options
    }
    public static func save(_ options: GitBlameOptions, to defaults: UserDefaults = .standard) {
        defaults.set(options.ignoreWhitespace, forKey: prefix + "IgnoreWhitespace")
        defaults.set(options.onlyFirstParent, forKey: prefix + "OnlyFirstParent")
        defaults.set(String(options.detectionMode.rawValue), forKey: prefix + "DetectMovedOrCopiedLines")
        defaults.set(String(options.withinFileCharacters), forKey: prefix + "WithinFileCharacters")
        defaults.set(String(options.betweenFileCharacters), forKey: prefix + "BetweenFileCharacters")
    }
    /// Load current defaults before each field edit so an older viewer cannot
    /// replace newer choices made by another viewer. Call from the UI actor.
    public static func update(in defaults: UserDefaults = .standard, _ edit: (inout GitBlameOptions) -> Void) {
        var options = load(from: defaults); edit(&options); save(options, to: defaults)
    }
}
