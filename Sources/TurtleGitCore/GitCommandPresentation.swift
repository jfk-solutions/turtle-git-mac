// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Captured native equivalents of CProgressDlg/SyncDlg presentation preferences.
/// ProgressDlgLinesLimit has no runtime reader in the pinned source.
public struct GitCommandPresentation: Sendable, Equatable {
    public let fetchVerbose: Bool
    public let animateActivity: Bool
    public let outputLimit: Int
    public init(defaults: UserDefaults = .standard) {
        fetchVerbose = (defaults.object(forKey: "FetchVerbose") as? NSNumber)?.boolValue ?? true
        animateActivity = (defaults.object(forKey: "DownloadAnimation") as? NSNumber)?.boolValue ?? true
        let kib = (defaults.object(forKey: "GitOutputLimitinKiB") as? NSNumber).map { Int(Int32(bitPattern: $0.uint32Value)) } ?? 2048
        outputLimit = max(16, min(kib, 100 * 1024)) * 1024
    }
}
