// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A Git tree namespace is bytes. An opaque key is a compatibility bridge for
/// existing selection/maps, never a display string, pathspec or native filename.
public struct RepositoryBrowserGitPath: Sendable, Hashable {
    private static let prefix = "\0TurtleGitBrowserPath:"
    public let rawData: Data
    public init(rawData:Data)throws {
        guard !rawData.contains(0),rawData.first != 47 else{throw RepositoryBrowserFailure.directory}
        if !rawData.isEmpty {
            let components=rawData.split(separator:47,omittingEmptySubsequences:false)
            guard components.allSatisfy({!$0.isEmpty && $0 != Data([46]) && $0 != Data([46,46])}) else{throw RepositoryBrowserFailure.directory}
        }
        self.rawData=rawData
    }
    public init(key:String)throws {
        if key.hasPrefix(Self.prefix) {
            let encoded=String(key.dropFirst(Self.prefix.count))
            guard let raw=Data(base64Encoded:encoded),raw.base64EncodedString()==encoded,String(data:raw,encoding:.utf8)==nil else{throw RepositoryBrowserFailure.directory}
            try self.init(rawData:raw)
        } else {try self.init(rawData:Data(key.utf8))}
    }
    public var utf8:String? {String(data:rawData,encoding:.utf8)}
    public var key:String {utf8 ?? Self.prefix+rawData.base64EncodedString()}
    public var isRepresentable:Bool {utf8 != nil}
    public var display:String {
        rawData.split(separator:47,omittingEmptySubsequences:false).map{Self.componentDisplay(Data($0))}.joined(separator:"/")
    }
    public var lastComponentDisplay:String {
        guard let component=rawData.split(separator:47).last else{return ""}
        return Self.componentDisplay(Data(component))
    }
    public var parentKey:String? {
        guard !rawData.isEmpty else{return nil}
        guard let slash=rawData.lastIndex(of:47) else{return ""}
        return (try? Self(rawData:Data(rawData[..<slash])))?.key
    }
    public var ancestorKeys:[String] {
        guard !rawData.isEmpty else{return []}
        var result=[String](),prefix=Data()
        for component in rawData.split(separator:47) {
            if !prefix.isEmpty {prefix.append(47)}
            prefix.append(contentsOf:component)
            if let path=try? Self(rawData:prefix) {result.append(path.key)}
        }
        return result
    }
    public static func display(key:String)->String {(try? Self(key:key).display) ?? "Invalid Git path"}
    public static func componentDisplay(_ raw:Data)->String {
        if let value=String(data:raw,encoding:.utf8) {return value}
        // The full byte suffix distinguishes different malformed names which
        // Windows' replacement decoding can merge into one CString map entry.
        let hex=raw.map{String(format:"%02X",$0)}.joined()
        return String(decoding:raw,as:UTF8.self)+" ⟦"+hex+"⟧"
    }
}
