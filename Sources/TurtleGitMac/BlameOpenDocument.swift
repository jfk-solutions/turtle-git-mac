import AppKit
import Darwin
import TurtleGitCore

struct BlameRecentDocument:Codable,Identifiable {
    let id:UUID
    let bookmark:Data
    let rootComponents:[String]
    let path:String
    let lastKnownFile:String
}
/// Four source-style recent files. Grants remain in app-private storage.
@MainActor final class BlameRecentDocuments:ObservableObject {
    @Published private(set) var entries:[BlameRecentDocument]=[]
    private let url:URL
    let provider:any RepositoryBookmarkProvider
    init(url:URL,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws {
        self.url=url;self.provider=provider
        if FileManager.default.fileExists(atPath:url.path) {
            entries=try JSONDecoder().decode([BlameRecentDocument].self,from:Data(contentsOf:url))
            guard entries.count<=4,Set(entries.map(\.id)).count==entries.count,entries.allSatisfy({ valid($0) }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        }
    }
    static func production() throws -> BlameRecentDocuments {
        try BlameRecentDocuments(url:RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("blame-files.json"))
    }
    private func valid(_ value:BlameRecentDocument)->Bool {
        !value.bookmark.isEmpty && value.bookmark.count<=1_048_576 && !value.path.isEmpty && !value.path.hasPrefix("/") && !value.path.contains("\0") && (value.rootComponents+value.path.components(separatedBy:"/")).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }
    }
    func remember(root:URL,path:String,lease:RepositoryAccessLease,replacing id:UUID? = nil) throws {
        guard lease.contains(root),RepositoryAccessLease.pathIsContained(root.appendingPathComponent(path),by:root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let scope=lease.url.standardizedFileURL.resolvingSymlinksInPath().path,repository=root.standardizedFileURL.resolvingSymlinksInPath().path
        let suffix=scope==repository ? "" : String(repository.dropFirst(scope=="/" ? 1 : scope.count+1))
        let file=root.appendingPathComponent(path).standardizedFileURL.path
        let record=BlameRecentDocument(id:id ?? entries.first { $0.lastKnownFile==file }?.id ?? UUID(),bookmark:try provider.create(for:lease.url),rootComponents:suffix.isEmpty ? [] : suffix.components(separatedBy:"/"),path:path,lastKnownFile:file)
        guard valid(record) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let updated=Array(([record]+entries.filter { $0.id != record.id && $0.lastKnownFile != file }).prefix(4))
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".blame-files-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard FileManager.default.createFile(atPath:temporary.path,contents:try JSONEncoder().encode(updated),attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard Darwin.rename(temporary.path,url.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) };entries=updated
    }
    func acquire(_ entry:BlameRecentDocument,requireScope:Bool) throws -> (URL,URL,RepositoryAccessLease) {
        guard valid(entry) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let resolved=try provider.resolve(entry.bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
        if requireScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
        let root=entry.rootComponents.reduce(lease.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
        let file=root.appendingPathComponent(entry.path)
        guard lease.contains(root),RepositoryAccessLease.pathIsContained(file,by:root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return (root,file,lease)
    }
}
struct BlameOpenedDocument {
    let repository:GitRepository
    let access:RepositoryAccessLease
    let snapshot:GitBlameSnapshot
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
    private var generation=0
    init(requireScope:Bool = GitRuntime.isAppStoreBuild,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),factory:@escaping (URL)->GitRepository) {
        self.requireScope=requireScope;self.provider=provider;self.factory=factory
    }
    var isReading:Bool { token != nil }
    func cancel() { generation += 1;token?.cancel() }
    func prepare(file:URL,scope:RepositoryAccessLease?,options:GitBlameOptions,regexExecutable:URL? = nil) async throws -> BlameOpenedDocument {
        guard token==nil else { throw FinderCacheServiceFailure.transitioning }
        let request=OperationCancellation();token=request;let identity=generation
        Self.activeReads += 1;defer { token=nil;Self.activeReads -= 1 }
        guard file.isFileURL else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let lease:RepositoryAccessLease
        if let scope { lease=scope }
        else {
            guard !requireScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
            lease=RepositoryAccessLease(url:file.deletingLastPathComponent(),provider:provider)
        }
        guard !requireScope || lease.hasSecurityScope,lease.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let attributes=try file.resourceValues(forKeys:[.isRegularFileKey]);guard attributes.isRegularFile==true else { throw GitBlameFailure.unsupported }
        let discovered=try await factory(file.deletingLastPathComponent()).discoverRoot(cancellation:request)
        let root=discovered.standardizedFileURL.resolvingSymlinksInPath()
        // An unsigned directory-derived scope can be widened only in the
        // unsandboxed development route; sandboxed callers must pick the root.
        let retained:RepositoryAccessLease
        if lease.contains(root) { retained=lease }
        else { guard !requireScope else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path) };retained=RepositoryAccessLease(url:root,provider:provider) }
        guard RepositoryAccessLease.pathIsContained(file,by:root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let path=String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path=="/" ? 1 : root.path.count+1))
        let repository=factory(root)
        let snapshot=try await repository.blame(path:path,revision:"HEAD",options:options,cancellation:request)
        let details=try await repository.blameHistoryDetails(snapshot,options:options,cancellation:request,regexExecutable:regexExecutable)
        let history=details.entries
        guard identity==generation,!request.isCancelled else { throw OperationCancellationFailure.cancelled }
        return BlameOpenedDocument(repository:repository,access:retained,snapshot:snapshot,history:history,details:details,options:options)
    }
}

import SwiftUI
struct BlameRecentFileMenu:View {
    @ObservedObject var store:BlameRecentDocuments
    let open:(BlameRecentDocument)->Void
    var body:some View {
        Menu("Recent Files") {
            ForEach(store.entries) { entry in Button { open(entry) } label: { CommandLabel(title:entry.lastKnownFile.replacingOccurrences(of:"\n",with:" ↵ ").replacingOccurrences(of:"\t",with:" ⇥ "),icon:.open) } }
            if store.entries.isEmpty { Text("No recent files") }
        }
    }
}
