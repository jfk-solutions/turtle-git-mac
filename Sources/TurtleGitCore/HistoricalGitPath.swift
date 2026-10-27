// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Explicit tree-namespace arguments. Ordinary history pathspecs retain their
/// existing syntax; opaque Browser keys are decoded only at selected endpoints.
enum HistoricalGitPath {
    static func argument(_ key:String) throws -> (caption:String,bytes:Data) {
        if key.utf8.contains(0) {
            let path=try RepositoryBrowserGitPath(key:key)
            return (path.display,path.rawData)
        }
        return (key,Data(key.utf8))
    }
    static func key(_ bytes:Data) -> String? { try? RepositoryBrowserGitPath(rawData:bytes).key }
}
