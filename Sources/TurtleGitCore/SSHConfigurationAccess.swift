// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum SSHConfigurationKind:String,Codable,Hashable,Sendable {case file,directory}

/// A reviewed permission snapshot. Bookmarks are private, never Git arguments.
public struct SSHConfigurationGrant:Identifiable,Hashable,Sendable {
    public let configuredPath:String
    public let kind:SSHConfigurationKind
    fileprivate let bookmark:Data
    fileprivate let revision:UUID
    public var id:GitReferenceName {GitReferenceName(configuredPath)}
    public static func ==(lhs:Self,rhs:Self)->Bool {
        lhs.id==rhs.id && lhs.kind==rhs.kind && lhs.bookmark==rhs.bookmark && lhs.revision==rhs.revision
    }
    public func hash(into hasher:inout Hasher) {hasher.combine(id);hasher.combine(kind);hasher.combine(bookmark);hasher.combine(revision)}
}

public struct SSHConfigurationAccess:@unchecked Sendable {
    public let url:URL
    public let permission:RepositoryAccessLease
    public let grant:SSHConfigurationGrant
}

public enum SSHConfigurationAccessFailure:LocalizedError {
    case location,permission,changed,storage
    public var errorDescription:String? {
        switch self {
        case .location:return "Choose an existing regular SSH configuration file or folder. Symbolic links are not accepted."
        case .permission:return "SSH configuration access is unavailable. Authorize the file or folder again."
        case .changed:return "SSH configuration permissions changed. Refresh and try again."
        case .storage:return "Saved SSH configuration permissions are invalid."
        }
    }
}

/// Separate instances for one archive share the mutation lock. Provider calls
/// happen outside it, so a concurrent Forget is not blocked behind a prompt or
/// bookmark resolution. Final admission checks the captured record revisions.
private enum SSHConfigurationStoreLocks {
    static let mutex=NSLock()
    static var locks:[String:NSLock]=[:]
    static func lock(for url:URL)->NSLock {
        mutex.lock();defer{mutex.unlock()}
        let key=url.standardizedFileURL.path
        if let lock=locks[key] {return lock}
        let lock=NSLock();locks[key]=lock;return lock
    }
}

/// Only explicit user selections enter this store. It neither reads SSH/key
/// contents nor follows Includes, discovers home paths or creates permissions.
public final class SSHConfigurationAccessStore:@unchecked Sendable {
    private struct Record:Codable {
        let configuredPath:String
        let kind:SSHConfigurationKind
        var bookmark:Data
        var revision:UUID
        var grant:SSHConfigurationGrant {.init(configuredPath:configuredPath,kind:kind,bookmark:bookmark,revision:revision)}
    }
    public static let shared=SSHConfigurationAccessStore()
    public static var defaultStorageURL:URL {
        RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("ssh-configuration/grants.json")
    }
    public let storageURL:URL
    private let provider:any RepositoryBookmarkProvider
    private let lock:NSLock
    public init(storageURL:URL=SSHConfigurationAccessStore.defaultStorageURL,provider:any RepositoryBookmarkProvider=SystemRepositoryBookmarkProvider()) {
        self.storageURL=storageURL;self.provider=provider;lock=SSHConfigurationStoreLocks.lock(for:storageURL)
    }
    private func locked<T>(_ action:()throws->T)rethrows->T {lock.lock();defer{lock.unlock()};return try action()}
    private func read()throws->[Record] {
        guard FileManager.default.fileExists(atPath:storageURL.path) else{return []}
        let reader=try FileHandle(forReadingFrom:storageURL);defer{try? reader.close()}
        let bytes=try reader.read(upToCount:4*1024*1024+1) ?? Data()
        guard bytes.count<=4*1024*1024 else{throw SSHConfigurationAccessFailure.storage}
        let records=try JSONDecoder().decode([Record].self,from:bytes)
        var paths=Set<GitReferenceName>(),revisions=Set<UUID>()
        guard records.count<=4096 else{throw SSHConfigurationAccessFailure.storage}
        for record in records {
            guard record.configuredPath.hasPrefix("/"),!record.configuredPath.utf8.contains(0),!record.bookmark.isEmpty,
                  paths.insert(GitReferenceName(record.configuredPath)).inserted,revisions.insert(record.revision).inserted else{throw SSHConfigurationAccessFailure.storage}
        }
        return records
    }
    private func persist(_ records:[Record])throws {
        let folder=storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        let bytes=try JSONEncoder().encode(records)
        guard bytes.count<=4*1024*1024,records.count<=4096 else{throw SSHConfigurationAccessFailure.storage}
        let temporary=folder.appendingPathComponent("grant-"+UUID().uuidString)
        let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{try? FileManager.default.removeItem(at:temporary)}
        guard fchmod(fd,0o600)==0 else{let code=errno;Darwin.close(fd);throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))}
        let writer=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do {try writer.write(contentsOf:bytes);try writer.close()}
        catch {try? writer.close();throw error}
        guard rename(temporary.path,storageURL.path)==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
    /// Called only with the corresponding live lease. Final symlink roots are
    /// rejected rather than granting an implicitly resolved target.
    private func kind(of url:URL)throws->SSHConfigurationKind {
        guard url.isFileURL,url.path.hasPrefix("/"),!url.path.utf8.contains(0) else{throw SSHConfigurationAccessFailure.location}
        let type=try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType
        if type == .typeRegular {return .file}
        if type == .typeDirectory {return .directory}
        throw SSHConfigurationAccessFailure.location
    }
    /// Listing is metadata about grants, not their files: no resolution, scope
    /// start, filesystem traversal or stale-bookmark renewal occurs here.
    public func grants()throws->[SSHConfigurationGrant] {try locked{try read().map(\.grant)}}
    public func remember(_ url:URL,requireSecurityScope:Bool=GitRuntime.isAppStoreBuild)throws {
        let permission=RepositoryAccessLease(url:url,provider:provider)
        defer{withExtendedLifetime(permission){}}
        guard !requireSecurityScope || permission.hasSecurityScope else{throw SSHConfigurationAccessFailure.permission}
        let kind=try kind(of:url),bookmark=try provider.create(for:url)
        guard !bookmark.isEmpty else{throw SSHConfigurationAccessFailure.permission}
        let record=Record(configuredPath:url.path,kind:kind,bookmark:bookmark,revision:UUID())
        try locked {
            var records=try read();records.removeAll{GitReferenceName.equal($0.configuredPath,url.path)};records.append(record)
            try persist(records)
        }
    }
    public func acquireAll(requireSecurityScope:Bool=GitRuntime.isAppStoreBuild,cancellation:OperationCancellation?=nil)throws->[SSHConfigurationAccess] {
        try cancellation?.check()
        let captured=try grants()
        return try acquire(captured,requireSecurityScope:requireSecurityScope,cancellation:cancellation)
    }
    public func acquire(_ grant:SSHConfigurationGrant,requireSecurityScope:Bool=GitRuntime.isAppStoreBuild,cancellation:OperationCancellation?=nil)throws->SSHConfigurationAccess {
        let values=try acquire([grant],requireSecurityScope:requireSecurityScope,cancellation:cancellation)
        return values[0]
    }
    private func acquire(_ captured:[SSHConfigurationGrant],requireSecurityScope:Bool,cancellation:OperationCancellation?)throws->[SSHConfigurationAccess] {
        try cancellation?.check()
        // Do not resolve a stale caller snapshot even before the final fence.
        try locked {
            let current=try read()
            guard captured.allSatisfy({grant in current.contains{$0.grant==grant}}) else{throw SSHConfigurationAccessFailure.changed}
        }
        var result:[SSHConfigurationAccess]=[],renewals:[GitReferenceName:Data]=[:]
        for grant in captured {
            try cancellation?.check()
            let resolved:ResolvedBookmark
            do {resolved=try provider.resolve(grant.bookmark)}catch{throw SSHConfigurationAccessFailure.permission}
            try cancellation?.check()
            let permission=RepositoryAccessLease(url:resolved.url,provider:provider)
            defer{withExtendedLifetime(permission){}}
            guard !requireSecurityScope || permission.hasSecurityScope else{throw SSHConfigurationAccessFailure.permission}
            guard try kind(of:resolved.url)==grant.kind else{throw SSHConfigurationAccessFailure.changed}
            if resolved.stale {
                let bookmark=try provider.create(for:resolved.url)
                guard !bookmark.isEmpty else{throw SSHConfigurationAccessFailure.permission}
                renewals[grant.id]=bookmark
            }
            result.append(.init(url:resolved.url,permission:permission,grant:grant))
        }
        try cancellation?.check()
        try locked {
            var current=try read()
            guard captured.allSatisfy({grant in current.contains{$0.grant==grant}}) else{throw SSHConfigurationAccessFailure.changed}
            try cancellation?.check()
            if !renewals.isEmpty {
                for index in current.indices {
                    if let bookmark=renewals[current[index].grant.id] {current[index].bookmark=bookmark;current[index].revision=UUID()}
                }
                try persist(current)
                result=result.map {access in
                    let grant=current.first{$0.grant.id==access.grant.id}!.grant
                    return .init(url:access.url,permission:access.permission,grant:grant)
                }
            }
        }
        try cancellation?.check()
        return result
    }
    /// Snapshot removal is atomic and rejects reauthorized/renewed records,
    /// including forget/re-add ABA. Already delivered leases are unaffected.
    public func forget(_ snapshots:[SSHConfigurationGrant])throws {
        try locked {
            var current=try read();let ids=Set(snapshots.map(\.id))
            guard ids.count==snapshots.count,snapshots.allSatisfy({grant in current.contains{$0.grant==grant}}) else{throw SSHConfigurationAccessFailure.changed}
            current.removeAll{ids.contains($0.grant.id)}
            if !snapshots.isEmpty {try persist(current)}
        }
    }
}
