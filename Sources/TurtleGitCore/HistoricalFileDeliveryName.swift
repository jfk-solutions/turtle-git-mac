// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A proposed output leaf is distinct from its original Git tree path. Only
/// the user-selected destination supplies filesystem authority.
public enum HistoricalFileDeliveryName {
    public static func leaf(for content: ComparisonFileContent) throws -> String {
        if !content.path.utf8.contains(0) {
            let leaf = (content.path as NSString).lastPathComponent
            guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.utf8.contains(47) else {
                throw RevisionComparisonFailure.selection
            }
            return leaf
        }
        let path = try RepositoryBrowserGitPath(key:content.path)
        guard !path.isRepresentable, !path.rawData.isEmpty, let oid=content.objectID,
              [40,64].contains(oid.utf8.count), oid.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { throw RevisionComparisonFailure.selection }
        let leaf=path.rawData.split(separator:47).last.map {Data($0)} ?? Data()
        var suffix=""
        if let dot=leaf.lastIndex(of:46) {
            let ext=leaf[leaf.index(after:dot)...]
            if (1...16).contains(ext.count),ext.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }) {suffix="."+String(decoding:ext,as:UTF8.self)}
        }
        return "Git-blob-"+oid+suffix
    }
}
