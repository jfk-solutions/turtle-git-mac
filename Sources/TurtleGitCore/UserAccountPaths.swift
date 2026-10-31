// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// Locations belonging to the current account, rather than the app's sandbox
/// container or an inherited process HOME. This policy grants no file access.
public enum UserAccountPaths {
    /// Expand just the home prefix; preserve every byte of the filename tail.
    /// Named accounts retain Foundation's user lookup, independently of `home`.
    public static func expandingTilde(_ path: String, home: URL = homeDirectory) -> String {
        guard path.hasPrefix("~") else { return path }
        let prefix = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let user = String(prefix.dropFirst())
        guard let directory = user.isEmpty ? home.path : NSHomeDirectoryForUser(user) else { return path }
        return directory + String(path.dropFirst(prefix.count))
    }

    /// Account identity is stable for this app process. Swift's static-let
    /// initialization also coalesces concurrent Finder/menu/default consumers.
    public static let homeDirectory: URL = resolveAccountHome()

    private static func resolveAccountHome() -> URL {
        let maximum = 1024 * 1024
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var size = suggested > 0 ? min(maximum, max(1024, Int(suggested))) : 16 * 1024
        while true {
            var entry = passwd(), result: UnsafeMutablePointer<passwd>?
            var storage = [CChar](repeating: 0, count: size)
            let status = storage.withUnsafeMutableBufferPointer {
                getpwuid_r(getuid(), &entry, $0.baseAddress, $0.count, &result)
            }
            if status == 0, result != nil {
                // pw_dir points into storage, which must survive this copy.
                let account = entry.pw_dir.flatMap { String(validatingUTF8: $0) }
                return withExtendedLifetime(storage) {
                    resolveHome(accountHome: account, fallback: FileManager.default.homeDirectoryForCurrentUser)
                }
            }
            guard status == ERANGE, size < maximum else { break }
            size = min(maximum, size * 2)
        }
        return resolveHome(accountHome: nil, fallback: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Pure location selection, also usable when the account database is absent
    /// or returns invalid data. Neither candidate is opened or authorized.
    public static func resolveHome(accountHome: String?, fallback: URL) -> URL {
        if let path = accountHome, path.hasPrefix("/"), !path.contains("\0") {
            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if directory.path != "/" { return directory }
        }
        return URL(fileURLWithPath: fallback.path, isDirectory: true)
    }
}
