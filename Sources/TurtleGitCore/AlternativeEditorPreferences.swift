import Foundation

/// The upstream Notepad/Custom choice, adapted to native macOS application bundles.
public struct AlternativeEditorPreferences: Equatable, Sendable {
    public var custom: Bool
    public var applicationPath: String
    public var bookmark: Data?
    public init(custom: Bool = false, applicationPath: String = "", bookmark: Data? = nil) {
        self.custom = custom; self.applicationPath = applicationPath; self.bookmark = bookmark
    }
    public var customApplication: URL? {
        guard custom, !applicationPath.isEmpty else { return nil }
        return URL(fileURLWithPath: applicationPath, isDirectory: true)
    }
    public var valid: Bool {
        !custom || applicationPath.isEmpty || (applicationPath.hasPrefix("/") && !applicationPath.contains("\0") &&
            (applicationPath as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame)
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(custom: defaults.bool(forKey: "TurtleGit.AlternativeEditor.Custom"),
             applicationPath: defaults.string(forKey: "TurtleGit.AlternativeEditor.Application") ?? "",
             bookmark: defaults.data(forKey: "TurtleGit.AlternativeEditor.Bookmark"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(custom, forKey: "TurtleGit.AlternativeEditor.Custom")
        defaults.set(applicationPath, forKey: "TurtleGit.AlternativeEditor.Application")
        defaults.set(bookmark, forKey: "TurtleGit.AlternativeEditor.Bookmark")
    }
}
