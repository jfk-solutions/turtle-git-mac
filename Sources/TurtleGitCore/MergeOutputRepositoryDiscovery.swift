// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum MergeOutputRepositoryDiscovery:Equatable,Sendable {
    case repository(URL)
    case noRepository
    case needsAuthority(URL)
}

extension RepositoryMetadataAccess {
    /// Unlike the legacy Settings lookup, nil/absence is not allowed to mean
    /// both 'no repository' and 'not permitted to inspect the next ancestor'.
    /// Use after a successful Save: only a complete authorized walk to '/' can
    /// prove that automatic Add has no repository in which to act.
    public static func discoverMergeOutputRepository(at location:URL,permissions:[RepositoryAccessLease],
        requireSecurityScope:Bool,cancellation:OperationCancellation?=nil)throws->MergeOutputRepositoryDiscovery {
        guard location.isFileURL,location.path.hasPrefix("/"),!location.path.contains("\0") else {throw RepositoryMetadataAccessFailure.invalid(location)}
        try cancellation?.check()
        let folders=permissions.flatMap{$0.permittedFolders(requireSecurityScope:requireSecurityScope)}
        guard !requireSecurityScope || folders.contains(where:{RepositoryAccessLease.pathIsContained(location,by:$0)}) else {
            return .needsAuthority(location.standardizedFileURL)
        }
        // Foundation standardization maps /private/var back to the /var alias.
        // Walk physical ancestors instead: otherwise the strict directory probe
        // reaches a symlink, or skips a real ancestor containing a Git marker.
        let canonical:URL=try location.withUnsafeFileSystemRepresentation {path in
            guard let path else {throw RepositoryMetadataAccessFailure.invalid(location)}
            guard let resolved=realpath(path,nil) else {
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSFilePathErrorKey:location.path])
            }
            defer {free(resolved)}
            return URL(fileURLWithPath:String(cString:resolved),isDirectory:true)
        }
        try cancellation?.check()
        let result=try discoverMergeOutputRepository(at:canonical,authorizedFolders:folders,
            requireSecurityScope:requireSecurityScope,cancellation:cancellation,inspect:mergeOutputItemType)
        switch result {
        case let .repository(root):return .repository(root.standardizedFileURL)
        case let .needsAuthority(folder):return .needsAuthority(folder.standardizedFileURL)
        case .noRepository:return .noRepository
        }
    }
    // Injected filesystem walker takes the physical location already resolved
    // by the public entry point. It follows exactly the production ancestor path.
    static func discoverMergeOutputRepository(at location:URL,authorizedFolders:[URL],requireSecurityScope:Bool,
        cancellation:OperationCancellation?=nil,inspect:(URL)throws->FileAttributeType?)throws->MergeOutputRepositoryDiscovery {
        guard location.isFileURL,location.path.hasPrefix("/"),!location.path.contains("\0") else {throw RepositoryMetadataAccessFailure.invalid(location)}
        func itemType(_ url:URL)throws->FileAttributeType? {
            try cancellation?.check()
            let result=try inspect(url)
            try cancellation?.check()
            return result
        }
        var cursor=location
        for _ in 0..<256 {
            try cancellation?.check()
            guard !requireSecurityScope || authorizedFolders.contains(where:{RepositoryAccessLease.pathIsContained(cursor,by:$0)}) else {
                return .needsAuthority(cursor)
            }
            // A missing/replaced ancestor is not proof of a plain folder, and
            // EACCES/EPERM/IO errors must never become a silent Add success.
            guard let type=try itemType(cursor),type == .typeDirectory else {
                throw RepositoryMetadataAccessFailure.invalid(cursor)
            }
            if try itemType(cursor.appendingPathComponent(".git")) != nil {return .repository(cursor)}
            if try itemType(cursor.appendingPathComponent("HEAD")) != nil,
               try itemType(cursor.appendingPathComponent("objects")) != nil {return .repository(cursor)}
            if cursor.path == "/" {return .noRepository}
            let parent=cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {throw RepositoryMetadataAccessFailure.invalid(cursor)}
            cursor=parent
        }
        throw RepositoryMetadataAccessFailure.tooManyDependencies
    }
    private static func mergeOutputItemType(_ url:URL)throws->FileAttributeType? {
        var status=stat()
        let result=url.withUnsafeFileSystemRepresentation {path->Int32 in
            guard let path else{errno=EINVAL;return -1}
            return lstat(path,&status)
        }
        if result != 0 {
            let code=errno
            if code == ENOENT {return nil}
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code),userInfo:[NSFilePathErrorKey:url.path])
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):return .typeDirectory
        case mode_t(S_IFLNK):return .typeSymbolicLink
        default:return .typeRegular
        }
    }
}
