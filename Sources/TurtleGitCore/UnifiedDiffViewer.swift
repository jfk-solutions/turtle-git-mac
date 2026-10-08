import Foundation

/// A read-only patch may contain bytes that cannot be represented in the
/// display encoding. Saving uses the original data, never the display text.
public struct UnifiedDiffDocument: Sendable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    public var displayText: String {
        // Decode display text without changing the original bytes used by Save As
        // or external viewers. BOMs take precedence over the legacy fallback.
        let signatures: [([UInt8], String.Encoding, Int)] = [
            ([0xff, 0xfe, 0, 0], .utf32LittleEndian, 4), ([0, 0, 0xfe, 0xff], .utf32BigEndian, 4),
            ([0xff, 0xfe], .utf16LittleEndian, 2), ([0xfe, 0xff], .utf16BigEndian, 2),
            ([0xef, 0xbb, 0xbf], .utf8, 1)
        ]
        for (signature, encoding, width) in signatures where bytes.starts(with: signature) {
            if (bytes.count - signature.count) % width == 0, let text = String(data: bytes.dropFirst(signature.count), encoding: encoding) { return text }
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
    public func write(to url: URL) throws { try bytes.write(to: url, options: .atomic) }
}

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
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitUnifiedDiffPreview-" + UUID().uuidString, isDirectory: true)
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
