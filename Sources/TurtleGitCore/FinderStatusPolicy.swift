// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Captured separately from the authoritative application status read. Shell
/// and Shell Extended deliberately use the pinned lightweight index algorithm.
public struct FinderStatusPolicy: Codable, Equatable, Sendable {
    public var cacheMode: FinderOverlayCacheMode
    public var caseSensitive: Bool
    public var contentCheckLimitKiB: UInt32
    public var blockStatus: Bool
    public init(cacheMode: FinderOverlayCacheMode = .standard, caseSensitive: Bool = true, contentCheckLimitKiB: UInt32 = 10240, blockStatus: Bool = false) {
        self.cacheMode=cacheMode; self.caseSensitive=caseSensitive; self.contentCheckLimitKiB=contentCheckLimitKiB; self.blockStatus=blockStatus
    }
    public init(settings: FinderOverlaySettings, preferences: FinderStatusPolicyPreferences) {
        self.init(cacheMode:settings.cacheMode,caseSensitive:preferences.caseSensitive,contentCheckLimitKiB:preferences.contentCheckLimitKiB,blockStatus:preferences.blockStatus)
    }
    public static func read(from statusURL: URL? = FinderIntegration.snapshotURL) throws -> Self {
        let settingsURL=statusURL?.deletingLastPathComponent().appendingPathComponent("overlay-settings.json")
        return try Self(settings:FinderOverlaySettings.readChecked(from:settingsURL),preferences:FinderStatusPolicyPreferences.read(from:statusURL))
    }
    public var identity: String { "finder-status-v1/\(cacheMode.rawValue)/\(caseSensitive ? 1:0)/\(contentCheckLimitKiB)/\(blockStatus ? 1:0)" }
}
public struct FinderOverlayCollection: Sendable {
    /// Absolute literal paths, including the source-mode-specific folder rollup.
    public let entries: GitPathMap<FileState>
    public let indexFlags: GitPathMap<FinderIndexFlags>
    public let caseSensitive: Bool
    public let policy: FinderStatusPolicy
    public init(entries:GitPathMap<FileState>,indexFlags:GitPathMap<FinderIndexFlags>,caseSensitive:Bool,policy:FinderStatusPolicy) {
        self.entries=entries;self.indexFlags=indexFlags;self.caseSensitive=caseSensitive;self.policy=policy
    }
}
