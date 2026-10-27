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
    /// Association policy uses the exact leaf, never a replacement-character
    /// rendering or an escaped display caption as a different filename.
    static func filename(_ key:String) -> String? {
        guard key.utf8.contains(0) else { return (key as NSString).lastPathComponent }
        guard let path=try? RepositoryBrowserGitPath(key:key),
              let leaf=path.rawData.split(separator:47).last else {return nil}
        return String(data:Data(leaf),encoding:.utf8)
    }
    static func fileExtension(_ key:String) -> String {
        guard key.utf8.contains(0) else {return (key as NSString).pathExtension}
        guard let path=try? RepositoryBrowserGitPath(key:key),
              let leaf=path.rawData.split(separator:47).last,
              let dot=leaf.lastIndex(of:46),dot != leaf.startIndex else {return ""}
        return String(data:Data(leaf[leaf.index(after:dot)...]),encoding:.utf8) ?? ""
    }
    static func key(_ bytes:Data) -> String? { try? RepositoryBrowserGitPath(rawData:bytes).key }
}

extension GitRepository {
    /// Historical objects can name bytes that have no host filesystem spelling.
    /// Existing UTF-8 callers keep the original authority fence; a working side
    /// never admits an opaque namespace key, even if its counterpart is pinned.
    func validateComparisonPath(_ key:String,allowsRaw:Bool)throws {
        if key.utf8.contains(0),allowsRaw {
            guard !(try RepositoryBrowserGitPath(key:key)).rawData.isEmpty else {throw RevisionComparisonFailure.selection}
        } else {_ = try restoreLocation(key)}
    }
    func historicalTreeRecord(revision:String,path:String,cancellation:OperationCancellation?)throws->(oid:String,mode:String)? {
        let value=try RepositoryBrowserGitPath(key:path)
        guard !value.rawData.isEmpty else {throw RevisionComparisonFailure.selection}
        let args=["-c","core.precomposeunicode=false","ls-tree","--full-tree","-z",revision,"--",value.display]
        for record in try run(args,argumentBytes:[7:value.rawData],cancellation:cancellation).stdout.split(separator:0) {
            guard let tab=record.firstIndex(of:9),Data(record[record.index(after:tab)...])==value.rawData else {continue}
            let fields=String(decoding:record[..<tab],as:UTF8.self).split(separator:" ")
            guard fields.count==3,[40,64].contains(fields[2].utf8.count),fields[2].utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else {throw RevisionComparisonFailure.selection}
            let mode=String(fields[0]),type=String(fields[1])
            guard (["100644","100755","120000"].contains(mode) && type=="blob") || (mode=="040000" && type=="tree") || (mode=="160000" && type=="commit") else {throw RevisionComparisonFailure.selection}
            return (String(fields[2]),String(fields[0]))
        }
        return nil
    }
}
