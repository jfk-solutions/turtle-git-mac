import Foundation
import Darwin

/// Display-only facts; never reuse this read as a file mutation authority.
public struct CommitFileListSupplementary:Sendable {
    public let metadata:GitPathMap<StatusListMetadata>
    public let changelists:GitChangelists
    public let changelistNames:[GitReferenceName]
}

/// A single synchronous display read owns this memo. Exact UTF-8 keys retain
/// canonical-equivalent names. A later operation must recheck changed symlinks.
final class StatusListPathRead {
    let root:URL
    private var parents=GitPathMap<Bool>()
    init(root:URL){self.root=root}
    static func lexicalLocation(root:URL,path:String)throws->URL {
        guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\0"),
              !path.components(separatedBy:"/").contains(where:{$0==".." || $0.caseInsensitiveCompare(".git") == .orderedSame}) else {throw WorkingFileRestoreFailure.location}
        let location=root.appendingPathComponent(path).standardizedFileURL
        guard location.path.hasPrefix(root.path+"/") else {throw WorkingFileRestoreFailure.location}
        return location
    }
    func location(_ path:String,cancellation:OperationCancellation?)throws->URL {
        try cancellation?.check()
        let location=try Self.lexicalLocation(root:root,path:path),parent=location.deletingLastPathComponent()
        let contained:Bool
        if let saved=parents[parent.path] {contained=saved}
        else {contained=RepositoryAccessLease.pathIsContained(parent,by:root);parents[parent.path]=contained}
        try cancellation?.check()
        guard contained else {throw WorkingFileRestoreFailure.location}
        return location
    }
    func metadata(paths:[String],columns:Set<StatusListColumn>,cancellation:OperationCancellation?)throws->GitPathMap<StatusListMetadata> {
        try cancellation?.check()
        guard !columns.isDisjoint(with:[.fileExtension,.lastModified,.fileSize]) else {return [:]}
        var result=GitPathMap<StatusListMetadata>()
        for path in paths {
            try cancellation?.check()
            let location:URL?
            do {location=try self.location(path,cancellation:cancellation)}
            catch let error as OperationCancellationFailure {throw error}
            catch {location=nil}
            var stat=Darwin.stat()
            let valid=location.map {Darwin.lstat($0.path,&stat)==0} ?? false
            try cancellation?.check()
            let directory=valid && stat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            let modified:Date?=valid && columns.contains(.lastModified) ? Date(timeIntervalSince1970:Double(stat.st_mtimespec.tv_sec)+Double(stat.st_mtimespec.tv_nsec)/1_000_000_000):nil
            let size:Int64?=valid && columns.contains(.fileSize) ? Int64(stat.st_size):nil
            result[path]=StatusListMetadata(modificationDate:modified,size:size,isDirectory:directory)
        }
        try cancellation?.check();return result
    }
}

extension GitRepository {
    public func statusListMetadata(paths:[String],columns:Set<StatusListColumn>,cancellation:OperationCancellation?=nil)throws->GitPathMap<StatusListMetadata> {
        try StatusListPathRead(root:root).metadata(paths:paths,columns:columns,cancellation:cancellation)
    }
    public func commitFileListSupplementary(paths:[String],columns:Set<StatusListColumn>,cancellation:OperationCancellation?=nil)throws->CommitFileListSupplementary {
        try cancellation?.check()
        let read=StatusListPathRead(root:root)
        let metadata=try read.metadata(paths:paths,columns:columns,cancellation:cancellation)
        let lists=try changelistDisplay(paths:paths,pathRead:read,cancellation:cancellation)
        try cancellation?.check()
        return CommitFileListSupplementary(metadata:metadata,changelists:lists.changelists,changelistNames:lists.changelistNames)
    }
}
