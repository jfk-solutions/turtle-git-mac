// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// A proposed output leaf is distinct from its original Git tree path. Only
/// the user-selected destination supplies filesystem authority.
public enum HistoricalFileDeliveryName {
    /// Synchronous promise naming cannot depend on an object lookup. Preserve
    /// ordinary leaves; raw paths get their own full byte-identity digest, even
    /// when different Git names point at the same blob. This is a proposed safe
    /// output name, never an original working-tree pathname.
    public static func transferLeaf(path key:String)throws->String {
        let path=try RepositoryBrowserGitPath(key:key)
        guard !path.rawData.isEmpty else{throw RevisionComparisonFailure.selection}
        if let text=path.utf8 {
            guard RepositoryBrowserListing.validPath(text,allowRoot:false),
                  !text.split(separator:"/").contains(where:{String($0).caseInsensitiveCompare(".git") == .orderedSame}) else {throw RevisionComparisonFailure.selection}
            return String(text.split(separator:"/").last!)
        }
        guard !path.rawData.split(separator:47).contains(where:{component in
            component.map{($0>=65 && $0<=90) ? $0+32:$0} == Array(".git".utf8)
        }) else{throw RevisionComparisonFailure.selection}
        let leaf=Data(path.rawData.split(separator:47).last!)
        var suffix=""
        if let dot=leaf.lastIndex(of:46) {
            let ext=leaf[leaf.index(after:dot)...]
            if (1...16).contains(ext.count),ext.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)}) {
                suffix="."+String(decoding:ext,as:UTF8.self)
            }
        }
        let digest=SHA256.hash(data:path.rawData).map{String(format:"%02x",$0)}.joined()
        return "Git-path-"+digest+suffix
    }
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
