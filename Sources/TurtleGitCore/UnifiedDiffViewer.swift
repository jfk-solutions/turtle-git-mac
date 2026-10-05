import Foundation

public enum UnifiedDiffViewerChoice: Equatable, Sendable {
    case builtin, external(URL)
}
public enum UnifiedDiffViewerFailure: LocalizedError {
    case application
    public var errorDescription: String? { "Choose a macOS application in Settings → Unified Diff Viewer." }
}

/// AppUtils::StartUnifiedDiffViewer inverts enabled/disabled external selection
/// for Shift. A saved disabled viewer remains available for that alternate use.
public struct UnifiedDiffViewerPreferences: Equatable, Sendable {
    public var enabled: Bool
    public var applicationPath: String
    public var bookmark: Data?
    public init(enabled: Bool = false, applicationPath: String = "", bookmark: Data? = nil) {
        self.enabled = enabled; self.applicationPath = applicationPath; self.bookmark = bookmark
    }
    private var applicationValid: Bool {
        applicationPath.hasPrefix("/") && !applicationPath.contains("\0") && (applicationPath as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
    public var valid: Bool { !enabled || applicationValid }
    public func choice(alternate: Bool = false) throws -> UnifiedDiffViewerChoice {
        guard !applicationPath.isEmpty, enabled != alternate else { return .builtin }
        guard applicationValid else { throw UnifiedDiffViewerFailure.application }
        return .external(URL(fileURLWithPath: applicationPath, isDirectory: true))
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "TurtleGit.UnifiedDiffViewer.Enabled"),
             applicationPath: defaults.string(forKey: "TurtleGit.UnifiedDiffViewer.Application") ?? "",
             bookmark: defaults.data(forKey: "TurtleGit.UnifiedDiffViewer.Bookmark"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "TurtleGit.UnifiedDiffViewer.Enabled")
        defaults.set(applicationPath, forKey: "TurtleGit.UnifiedDiffViewer.Application")
        defaults.set(bookmark, forKey: "TurtleGit.UnifiedDiffViewer.Bookmark")
    }
}

/// An exact byte copy for external viewers, kept until application termination.
/// It never overwrites a repository file or an earlier preview.
public struct UnifiedDiffPreview: Sendable {
    public let directory: URL
    public let file: URL
    public static func create(_ bytes: Data) throws -> Self {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("TurtleGitUnifiedDiffPreview-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("diff.patch")
            try bytes.write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            return Self(directory: directory, file: file)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}
