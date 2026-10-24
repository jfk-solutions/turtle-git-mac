// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

public enum FinderStatusCollectionFailure: LocalizedError {
    case output
    public var errorDescription:String? { "The Finder status engine returned invalid or incomplete metadata." }
}
/// Strict private metadata channel; never interpret Git/server diagnostics as
/// statuses. No partial collection is published after a framing/budget failure.
enum FinderStatusProtocol {
    static let prefix=Data("TurtleGit Finder v1:".utf8)
    static func decode(_ data:Data,root:URL,policy:FinderStatusPolicy,cancellation:OperationCancellation?=nil) throws -> FinderOverlayCollection {
        guard data.count<=64*1024*1024,data.last==10 else {throw FinderStatusCollectionFailure.output}
        var entries:GitPathMap<FileState>=[:],flags:GitPathMap<FinderIndexFlags>=[:],effective:Bool?,ended=false,count=0
        let states:[FileState]=[.normal,.modified,.added,.deleted,.untracked,.ignored,.conflicted]
        func bool(_ o:[String:Any],_ key:String)throws->Bool {guard let n=o[key] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FinderStatusCollectionFailure.output};return n.boolValue}
        for line in data.split(separator:10,omittingEmptySubsequences:false).dropLast() {
            try cancellation?.check()
            guard !ended,line.count<=2*1024*1024,line.starts(with:prefix),let payload=Data(base64Encoded:Data(line.dropFirst(prefix.count))),payload.base64EncodedData()==Data(line.dropFirst(prefix.count)),let o=try JSONSerialization.jsonObject(with:payload) as? [String:Any],let kind=o["kind"] as? String else {throw FinderStatusCollectionFailure.output}
            switch kind {
            case "header":
                guard effective==nil,count==0,Set(o.keys)==["kind","caseSensitive"] else{throw FinderStatusCollectionFailure.output};effective=try bool(o,"caseSensitive")
                guard !policy.caseSensitive || effective==true else{throw FinderStatusCollectionFailure.output}
            case "entry":
                guard effective != nil,count<200000,Set(o.keys)==["kind","path","state","skipWorktree","assumeUnchanged"],let path=o["path"] as? String,path.utf8.count<=1024*1024,!path.isEmpty,!path.hasPrefix("/"),!path.utf8.contains(0),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".." || $0.lowercased()==".git"}),let number=o["state"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue==Double(number.intValue),states.indices.contains(number.intValue) else {throw FinderStatusCollectionFailure.output}
                let absolute=root.path+"/"+path,skip=try bool(o,"skipWorktree"),assume=try bool(o,"assumeUnchanged")
                if let previous=entries[absolute] {guard previous==states[number.intValue],(flags[absolute] ?? .init()) == FinderIndexFlags(skipWorktree:skip,assumeUnchanged:assume) else{throw FinderStatusCollectionFailure.output}}
                entries[absolute]=states[number.intValue]
                if skip || assume {flags[absolute] = .init(skipWorktree:skip,assumeUnchanged:assume)}
                count+=1
            case "end":
                guard effective != nil,Set(o.keys)==["kind","count"],let total=o["count"] as? NSNumber,CFGetTypeID(total) != CFBooleanGetTypeID(),total.doubleValue==Double(count) else{throw FinderStatusCollectionFailure.output};ended=true
            default:throw FinderStatusCollectionFailure.output
            }
        }
        guard ended,let effective else{throw FinderStatusCollectionFailure.output}
        // The Shell cache excludes grandchildren from a folder's ordinary
        // rollup; conflicts are checked recursively before that source loop.
        let files=entries
        let priority:[FileState:Int]=[.normal:0,.ignored:0,.untracked:0,.added:1,.deleted:1,.modified:1,.conflicted:2]
        for (path,state) in files {
            try cancellation?.check()
            var parent=(path as NSString).deletingLastPathComponent,first=true
            while FinderSnapshot.contains(parent,root:root.path) {
                if entries[parent]==nil {entries[parent] = .normal}
                if (first || policy.cacheMode != .shell || state == .conflicted),priority[state,default:0]>priority[entries[parent] ?? .normal,default:0] {entries[parent] = state == .conflicted ? .conflicted:.modified}
                if GitReferenceName.equal(parent,root.path){break}
                parent=(parent as NSString).deletingLastPathComponent;first=false
            }
        }
        entries[root.path]=entries[root.path] ?? .normal
        return .init(entries:entries,indexFlags:flags,caseSensitive:effective,policy:policy)
    }
}
extension GitRepository {
    public func collectFinderOverlay(policy:FinderStatusPolicy,cancellation:OperationCancellation?=nil) async throws -> FinderOverlayCollection {
        try cancellation?.check()
        if policy.cacheMode == .none {return .init(entries:[root.path:.normal],indexFlags:[:],caseSensitive:policy.caseSensitive,policy:policy)}
        let helper=try (libgit2Configuration ?? .load()).runtimeExecutor()
        let request=try JSONSerialization.data(withJSONObject:["version":1,"full":policy.cacheMode == .standard,"caseSensitive":policy.caseSensitive,"contentCheckLimitKiB":policy.contentCheckLimitKiB],options:[.sortedKeys])
        var bytes=Data()
        _ = try run(["turtlegit-finder-status"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation,input:request,retainStandardOutput:false,consumeOutput:{chunk in
            if case .stdout=chunk.stream {guard chunk.data.count<=64*1024*1024-bytes.count else{throw FinderStatusCollectionFailure.output};bytes.append(chunk.data)}
        },executorOverride:helper)
        return try FinderStatusProtocol.decode(bytes,root:root,policy:policy,cancellation:cancellation)
    }
}
