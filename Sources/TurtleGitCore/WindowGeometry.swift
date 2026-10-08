import Foundation

public struct SavedWindowGeometry: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var valid: Bool { [x, y, width, height].allSatisfy { $0.isFinite } && width > 0 && height > 0 }
    public func fitted(to screen: Self, minimumWidth: Double, minimumHeight: Double) -> Self {
        let width = min(screen.width, max(width, minimumWidth)), height = min(screen.height, max(height, minimumHeight))
        return Self(x: min(max(x, screen.x), screen.x + screen.width - width),
                    y: min(max(y, screen.y), screen.y + screen.height - height), width: width, height: height)
    }
}
public struct WindowGeometryStore {
    public static let prefix = "TurtleGit.DialogGeometry."
    public static let legacyNames = ["AddDialog", "AddProgress", "CreateWorktreeDialog", "ExportDialog", "FileDiffDialog", "FormatPatchDialog", "IgnoreDialog", "RenameDialog", "RequestPullDialog", "ResetDialog", "ResolveDialog", "RevertDialog", "RevertProgressDialog", "StatisticsDialog", "SubmoduleDiffDialog", "SubmoduleUpdateDialog", "TurtleGit.RepositoryBrowser", "TurtleGit.SubmoduleConflict", "TurtleGit.TextConflict", "TurtleGit.TwoFileDiff", "WorktreeList"]
    private let preferences: UserDefaults
    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    public func load(_ identifier: String, legacyName: String? = nil) -> SavedWindowGeometry? {
        if let data = preferences.data(forKey: Self.prefix + identifier), let frame = try? JSONDecoder().decode(SavedWindowGeometry.self, from: data), frame.valid { return frame }
        guard let legacyName, Self.legacyNames.contains(legacyName), let text = preferences.string(forKey: "NSWindow Frame " + legacyName) else { return nil }
        let values = text.split(whereSeparator: { $0.isWhitespace }).prefix(4).compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        let frame = SavedWindowGeometry(x: values[0], y: values[1], width: values[2], height: values[3])
        return frame.valid ? frame : nil
    }
    public func save(_ frame: SavedWindowGeometry, identifier: String) {
        guard frame.valid, let data = try? JSONEncoder().encode(frame) else { return }
        preferences.set(data, forKey: Self.prefix + identifier)
    }
    public static func owns(_ key: String) -> Bool { key.hasPrefix(prefix) || legacyNames.contains(where: { key == "NSWindow Frame " + $0 }) }
}
