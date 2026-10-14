// Replaces RepositoryBrowser.cpp/GitDataObject.cpp historical drag data with native item providers.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit; 2003-2014 TortoiseSVN.
import AppKit
import TurtleGitCore
import UniformTypeIdentifiers
import Darwin

/// Count a request before dispatching it to the main actor. Quit must also see
/// work queued by an arbitrary NSItemProvider/NSFilePromise callback thread.
private final class RepositoryBrowserTransferActivity: @unchecked Sendable {
    static let shared = RepositoryBrowserTransferActivity()
    private let lock = NSLock()
    private var count = 0
    var active: Int { lock.lock(); defer { lock.unlock() }; return count }
    func begin() { lock.lock(); count += 1; lock.unlock() }
    func end() { lock.lock(); count -= 1; lock.unlock() }
}
private final class RepositoryBrowserTransferReceipt: @unchecked Sendable {
    init() { RepositoryBrowserTransferActivity.shared.begin() }
    deinit { RepositoryBrowserTransferActivity.shared.end() }
}

/// A provider owns its prepared exports. Releasing it cleans up those copies;
/// the global registry only permits explicit app-termination cleanup.
fileprivate final class RepositoryBrowserExportRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var exports: [RepositoryBrowserExport] = []
    func retain(_ export: RepositoryBrowserExport) { lock.lock(); exports.append(export); lock.unlock() }
    func discardAll() {
        lock.lock(); let items = exports; exports = []; lock.unlock()
        for item in items { item.discard() }
    }
    deinit { discardAll() }
}
private final class RepositoryBrowserWeakRetention {
    weak var value: RepositoryBrowserExportRetention?
    init(_ value: RepositoryBrowserExportRetention) { self.value = value }
}

@MainActor enum RepositoryBrowserExportFiles {
    static var activeLoads: Int { RepositoryBrowserTransferActivity.shared.active }
    private static var owners: [RepositoryBrowserWeakRetention] = []
    fileprivate static func owner() -> RepositoryBrowserExportRetention {
        owners.removeAll { $0.value == nil }
        let value = RepositoryBrowserExportRetention(); owners.append(RepositoryBrowserWeakRetention(value)); return value
    }
    static func discardAll() { for owner in owners { owner.value?.discardAll() }; owners.removeAll() }
}

@MainActor enum RepositoryBrowserDrag {
    static func provider(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?, name: String, folder: Bool) -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = name
        let type = folder ? UTType.folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let payload = RepositoryBrowserDragPayload(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let cancellation = OperationCancellation(), progress = Progress(totalUnitCount: 1)
            let receipt = RepositoryBrowserTransferReceipt()
            progress.cancellationHandler = { cancellation.cancel() }
            Task { await payload.load(completion: completion, progress: progress, cancellation: cancellation); withExtendedLifetime(receipt) {} }
            return progress
        }
        return provider
    }
}

/// The scope lease remains on the main actor; providers can request data from
/// arbitrary threads without transferring a non-Sendable lease between actors.
@MainActor private final class RepositoryBrowserDragPayload {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let snapshot: RepositoryBrowserSnapshot
    let entry: RepositoryBrowserEntry?
    let directory: String?
    private let retention = RepositoryBrowserExportFiles.owner()
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.entry = entry; self.directory = directory
    }
    func load(completion: @escaping (URL?, Bool, Error?) -> Void, progress: Progress, cancellation: OperationCancellation) async {
        defer { withExtendedLifetime(access) {} }
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let current: RepositoryBrowserSnapshot
            if let directory { current = try await repository.browseRepositoryDirectory(snapshot, directory: directory, cancellation: cancellation) }
            else { current = snapshot }
            let export = try await repository.exportRepositoryBrowser(current, entry: entry, cancellation: cancellation)
            guard !cancellation.isCancelled else { export.discard(); throw OperationCancellationFailure.cancelled }
            retention.retain(export)
            progress.totalUnitCount = Int64(export.fileCount)
            completion(export.item, false, nil); progress.completedUnitCount = progress.totalUnitCount
        } catch { completion(nil, false, error) }
    }
}

/// A native list drag promises one independently named historical item per row.
/// The provider retains its delegate; delivery intentionally survives owner close.
@MainActor final class RepositoryBrowserFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let repository:GitRepository
    let access:RepositoryAccessLease?
    let snapshot:RepositoryBrowserSnapshot
    let entry:RepositoryBrowserEntry?
    let directory:String?
    let name:String
    init(repository:GitRepository,access:RepositoryAccessLease?,snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry? = nil,directory:String? = nil) {
        self.repository=repository;self.access=access;self.snapshot=snapshot;self.entry=entry;self.directory=directory
        self.name=entry?.name ?? (directory.map { $0.isEmpty ? repository.root.lastPathComponent : ($0 as NSString).lastPathComponent } ?? repository.root.lastPathComponent)
    }
    func provider() -> NSFilePromiseProvider {
        let type=entry == nil || entry?.kind == .directory || directory != nil ? UTType.folder : UTType(filenameExtension:(name as NSString).pathExtension) ?? .data
        let provider=NSFilePromiseProvider(fileType:type.identifier,delegate:self);provider.userInfo=self;return provider
    }
    func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,fileNameForType fileType:String) -> String { name }
    func operationQueue(for filePromiseProvider:NSFilePromiseProvider) -> OperationQueue { .main }
    nonisolated func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping (Error?)->Void) {
        let receipt = RepositoryBrowserTransferReceipt()
        Task { @MainActor [self] in
            defer { withExtendedLifetime(receipt) {}; withExtendedLifetime(access) {} }
            do {
                try await write(to: url)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
    /// Shared by native delivery and controlled receiver checks. The destination
    /// is receiver-supplied, and an existing item must never be overwritten.
    func write(to url: URL, cancellation: OperationCancellation? = nil) async throws {
        guard url.isFileURL else { throw RepositoryBrowserFailure.selection }
        if cancellation?.isCancelled == true { throw OperationCancellationFailure.cancelled }
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
        let listing: RepositoryBrowserSnapshot
        if let directory { listing = try await repository.browseRepositoryDirectory(snapshot, directory: directory, cancellation: cancellation) } else { listing = snapshot }
        let export = try await repository.exportRepositoryBrowser(listing, entry: entry, cancellation: cancellation)
        defer { export.discard(); withExtendedLifetime(access) {} }
        let source = export.item
        try await Task.detached(priority: .userInitiated) {
            try Self.writeMaterialized(source, to: url, cancellation: cancellation)
        }.value
    }
    nonisolated private static func writeMaterialized(_ source: URL, to url: URL, cancellation: OperationCancellation?) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { destination in
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".turtlegit-promise-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                if cancellation?.isCancelled == true { throw OperationCancellationFailure.cancelled }
                try FileManager.default.copyItem(at: source, to: staging)
                if cancellation?.isCancelled == true { throw OperationCancellationFailure.cancelled }
                guard Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
                }
            } catch { writeError = error }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
    }
}
