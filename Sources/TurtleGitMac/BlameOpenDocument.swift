import AppKit
import Darwin
import TurtleGitCore

/// Blame reads the Git blob named by the leaf, including mode 120000's target
/// text. Only its parent is resolved for authorization; the target is never read.
enum BlameDocumentLocation {
    /// Working-file entry points require a real lexical leaf, but a symbolic
    /// link's target is never part of Blame's authority or attributed content.
    static func validateWorkingLeaf(_ file:URL,cancellation:OperationCancellation?=nil) throws {
        try cancellation?.check()
        guard file.isFileURL else {throw FinderServiceAuthorizationFailure.invalidRequest}
        var attributes=stat()
        guard file.withUnsafeFileSystemRepresentation({$0.map {Darwin.lstat($0,&attributes)} ?? -1})==0 else {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .ENOENT)
        }
        let kind=attributes.st_mode & mode_t(S_IFMT)
        guard kind==mode_t(S_IFREG) || kind==mode_t(S_IFLNK) else {throw GitBlameFailure.unsupported}
        try cancellation?.check()
    }
    static func lexicalFile(root:URL,path:String) throws -> URL {
        let components=path.components(separatedBy:"/")
        guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.caseInsensitiveCompare(".git") != .orderedSame }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let root=root.standardizedFileURL.resolvingSymlinksInPath()
        let file=root.appendingPathComponent(path).standardizedFileURL
        guard RepositoryAccessLease.pathIsContained(file.deletingLastPathComponent(),by:root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return file
    }
}

struct BlameRecentDocument:Codable,Identifiable {
    let id:UUID
    let bookmark:Data
    let rootComponents:[String]
    let path:String
    let lastKnownFile:String
    let relatedBookmarks:[Data]?
    init(id:UUID,bookmark:Data,rootComponents:[String],path:String,lastKnownFile:String,relatedBookmarks:[Data]? = nil) {
        self.id=id;self.bookmark=bookmark;self.rootComponents=rootComponents;self.path=path;self.lastKnownFile=lastKnownFile;self.relatedBookmarks=relatedBookmarks
    }
}
/// Four source-style recent files. Grants remain in app-private storage.
@MainActor final class BlameRecentDocuments:ObservableObject {
    private static let maximumArchiveBytes=8*1024*1024
    @Published private(set) var entries:[BlameRecentDocument]=[]
    private let url:URL
    let provider:any RepositoryBookmarkProvider
    init(url:URL,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws {
        self.url=url;self.provider=provider
        if FileManager.default.fileExists(atPath:url.path) {
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumArchiveBytes else {throw FinderServiceAuthorizationFailure.invalidRequest}
            let bytes=try Data(contentsOf:url)
            guard bytes.count<=Self.maximumArchiveBytes else {throw FinderServiceAuthorizationFailure.invalidRequest}
            entries=try JSONDecoder().decode([BlameRecentDocument].self,from:bytes)
            guard entries.count<=4,Set(entries.map(\.id)).count==entries.count,entries.allSatisfy({ valid($0) }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        }
    }
    static func production() throws -> BlameRecentDocuments {
        try BlameRecentDocuments(url:RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("blame-files.json"))
    }
    private func valid(_ value:BlameRecentDocument)->Bool {
        !value.bookmark.isEmpty && value.bookmark.count<=1_048_576 && (value.relatedBookmarks?.count ?? 0)<=64 && (value.relatedBookmarks ?? []).allSatisfy{!$0.isEmpty && $0.count<=1_048_576} && Set(value.relatedBookmarks ?? []).count==(value.relatedBookmarks?.count ?? 0) && !value.path.isEmpty && !value.path.hasPrefix("/") && !value.path.contains("\0") && (value.rootComponents+value.path.components(separatedBy:"/")).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }
    }
    func remember(root:URL,path:String,lease:RepositoryAccessLease,replacing id:UUID? = nil) throws {
        let location=try BlameDocumentLocation.lexicalFile(root:root,path:path)
        guard lease.contains(root),lease.contains(location.deletingLastPathComponent()) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let scope=lease.url.standardizedFileURL.resolvingSymlinksInPath().path,repository=root.standardizedFileURL.resolvingSymlinksInPath().path
        let suffix=scope==repository ? "" : String(repository.dropFirst(scope=="/" ? 1 : scope.count+1))
        let file=location.path
        let additional=lease.permittedFolders(requireSecurityScope:true).filter{!RepositoryAccessLease.pathIsContained($0,by:lease.url)}
        guard additional.count<=64 else {throw RepositoryMetadataAccessFailure.tooManyDependencies}
        // Resolve/create every bookmark before changing either archive or rows.
        let related=try additional.map{try provider.create(for:$0)}
        let record=BlameRecentDocument(id:id ?? entries.first { GitReferenceName.equal($0.lastKnownFile,file) }?.id ?? UUID(),bookmark:try provider.create(for:lease.url),rootComponents:suffix.isEmpty ? [] : suffix.components(separatedBy:"/"),path:path,lastKnownFile:file,relatedBookmarks:related.isEmpty ? nil:related)
        guard valid(record) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let updated=Array(([record]+entries.filter { $0.id != record.id && !GitReferenceName.equal($0.lastKnownFile,file) }).prefix(4))
        let bytes=try JSONEncoder().encode(updated)
        guard bytes.count<=Self.maximumArchiveBytes else {throw FinderServiceAuthorizationFailure.invalidRequest}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".blame-files-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard FileManager.default.createFile(atPath:temporary.path,contents:bytes,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard Darwin.rename(temporary.path,url.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) };entries=updated
    }
    func acquire(_ entry:BlameRecentDocument,requireScope:Bool,allowMetadataRepair:Bool = false) throws -> (URL,URL,RepositoryAccessLease) {
        guard valid(entry) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let resolved=try provider.resolve(entry.bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
        if requireScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
        let root=entry.rootComponents.reduce(lease.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
        let file=try BlameDocumentLocation.lexicalFile(root:root,path:entry.path)
        guard lease.contains(root),lease.contains(file.deletingLastPathComponent()) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        var related=[RepositoryAccessLease]()
        for bookmark in entry.relatedBookmarks ?? [] {
            // An unavailable auxiliary grant is repaired by the owned metadata
            // preflight before Git; it never widens the primary root boundary.
            let resolved:ResolvedBookmark
            do {resolved=try provider.resolve(bookmark)}
            catch {if allowMetadataRepair && requireScope {continue};throw error}
            let permission=RepositoryAccessLease(url:resolved.url,provider:provider)
            if requireScope && !permission.hasSecurityScope {
                guard allowMetadataRepair else {throw RepositoryAccessFailure.securityScopeUnavailable}
            } else {related.append(permission)}
        }
        return (root,file,lease.retainingRelatedScopes(related))
    }
}
struct BlameOpenedDocument {
    let repository:GitRepository
    let access:RepositoryAccessLease
    let snapshot:GitBlameSnapshot
    let annotationDocument:GitBlameDocument
    let decodingError:String?
    let history:[LogEntry]
    let details:GitBlameHistoryDetails
    let options:GitBlameOptions
}
@MainActor final class BlameDocumentOpener {
    private(set) static var activeReads=0
    private let requireScope:Bool
    private let provider:any RepositoryBookmarkProvider
    private let factory:(URL)->GitRepository
    private var token:OperationCancellation?
    private var choices:[UUID:Bool]=[:]
    private var generation=0
    init(requireScope:Bool = GitRuntime.isAppStoreBuild,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),factory:@escaping (URL)->GitRepository) {
        self.requireScope=requireScope;self.provider=provider;self.factory=factory
    }
    var isReading:Bool { token != nil || !choices.isEmpty }
    func retainChoice()->UUID {
        let id=UUID(),ownsCount=token==nil && !choices.values.contains(true)
        choices[id]=ownsCount;if ownsCount {Self.activeReads += 1};return id
    }
    func releaseChoice(_ id:UUID) {if let counted=choices.removeValue(forKey:id),counted {Self.activeReads -= 1}}
    func cancel() { generation += 1;token?.cancel() }
    func prepare(file:URL,scope:RepositoryAccessLease?,options:GitBlameOptions,regexExecutable:URL? = nil,
                 chooseMetadataFolder:((RepositoryMetadataAccessRequirement,OperationCancellation) async throws -> URL?)? = nil) async throws -> BlameOpenedDocument {
        guard token==nil,choices.isEmpty else { throw FinderCacheServiceFailure.transitioning }
        let request=OperationCancellation();token=request;let identity=generation
        Self.activeReads += 1;defer { token=nil;Self.activeReads -= 1 }
        guard file.isFileURL else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let lease:RepositoryAccessLease
        if let scope { lease=scope }
        else {
            guard !requireScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
            lease=RepositoryAccessLease(url:file.deletingLastPathComponent(),provider:provider)
        }
        guard !requireScope || lease.hasSecurityScope,lease.contains(file.deletingLastPathComponent()) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        try BlameDocumentLocation.validateWorkingLeaf(file,cancellation:request)
        var additional=[RepositoryAccessLease](),authorizedRoot:URL?
        if requireScope {
            // Inspect only authorized markers before starting Git. Linked
            // worktrees and alternates can otherwise fail during root discovery.
            let primaryFolders=lease.permittedFolders(requireSecurityScope:true),parent=file.deletingLastPathComponent()
            let hint=try await Task.detached {try RepositoryMetadataAccess.settingsRepository(at:parent,permissions:[lease],requireSecurityScope:true,cancellation:request)}.value
            guard let hint,lease.contains(hint) else {throw RepositoryAccessFailure.securityScopeUnavailable}
            authorizedRoot=hint
            for attempt in 0...64 {
                try request.check()
                let folders=primaryFolders+additional.flatMap{$0.permittedFolders(requireSecurityScope:true)}
                let requirement=try await Task.detached {try RepositoryMetadataAccess.next(at:hint,authorizedFolders:folders,cancellation:request)}.value
                try request.check()
                guard let requirement else {break}
                guard attempt<64 else {throw RepositoryMetadataAccessFailure.tooManyDependencies}
                guard let chooseMetadataFolder else {throw RepositoryAccessFailure.securityScopeUnavailable}
                guard let selected=try await chooseMetadataFolder(requirement,request) else {throw OperationCancellationFailure.cancelled}
                try request.check()
                let permission=RepositoryAccessLease(url:selected,provider:provider)
                guard permission.hasSecurityScope,permission.contains(requirement.folder) else {throw RepositoryAccessFailure.repositoryRootOutsidePermission(requirement.folder.path)}
                additional.append(permission)
            }
        }
        let discovered=try await factory(file.deletingLastPathComponent()).discoverRoot(cancellation:request)
        let root=discovered.standardizedFileURL.resolvingSymlinksInPath()
        guard !requireScope || root.path==authorizedRoot?.standardizedFileURL.resolvingSymlinksInPath().path else {throw RepositoryAccessFailure.securityScopeUnavailable}
        // An unsigned directory-derived scope can be widened only in the
        // unsandboxed development route; sandboxed callers must pick the root.
        let retained:RepositoryAccessLease
        if lease.contains(root) { retained=lease.retainingRelatedScopes(additional) }
        else { guard !requireScope else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path) };retained=RepositoryAccessLease(url:root,provider:provider) }
        let lexical=file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
        let prefix=root.path=="/" ? "/" : root.path+"/"
        guard lexical.path.hasPrefix(prefix) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let path=String(lexical.path.dropFirst(prefix.count))
        _ = try BlameDocumentLocation.lexicalFile(root:root,path:path)
        let repository=factory(root)
        let document=try await repository.blameDocument(path:path,revision:"HEAD",options:options,cancellation:request)
        let details=try await repository.blameHistoryDetails(document.annotationSnapshot,options:options,cancellation:request,regexExecutable:regexExecutable)
        let projection=try await Task.detached(priority:.userInitiated) { () throws -> (GitBlameSnapshot,String?) in
            do {return (try document.project(encoding:options.encoding,cancellation:request),nil)}
            catch GitBlameFailure.unsupported {return (document.annotationSnapshot,GitBlameFailure.unsupported.localizedDescription)}
        }.value
        let snapshot=projection.0
        let history=details.entries
        guard identity==generation,!request.isCancelled else { throw OperationCancellationFailure.cancelled }
        return BlameOpenedDocument(repository:repository,access:retained,snapshot:snapshot,annotationDocument:document,decodingError:projection.1,history:history,details:details,options:options)
    }
}

import SwiftUI
struct BlameRecentFileMenu:View {
    @ObservedObject var store:BlameRecentDocuments
    let open:(BlameRecentDocument)->Void
    var body:some View {
        Menu("Recent Files") {
            ForEach(store.entries) { entry in Button { open(entry) } label: { CommandLabel(title:entry.lastKnownFile.replacingOccurrences(of:"\n",with:" ↵ ").replacingOccurrences(of:"\t",with:" ⇥ "),icon:.open,localized:false) } }
            if store.entries.isEmpty { Text("No recent files") }
        }
    }
}
