// Replaces RepositoryBrowser.cpp/GitDataObject.cpp historical drag data with native item providers.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit; 2003-2014 TortoiseSVN.
import AppKit
import TurtleGitCore
import UniformTypeIdentifiers

@MainActor enum RepositoryBrowserExportFiles {
    static var activeLoads = 0
    private static var exports: [URL: RepositoryBrowserExport] = [:]
    static func retain(_ export: RepositoryBrowserExport) { exports[export.directory] = export }
    static func discardAll() { for export in exports.values { export.discard() }; exports.removeAll() }
}

@MainActor enum RepositoryBrowserDrag {
    static func provider(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?, name: String, folder: Bool) -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = name
        let type = folder ? UTType.folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let payload = RepositoryBrowserDragPayload(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let cancellation = OperationCancellation(), progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { cancellation.cancel() }
            Task { await payload.load(completion: completion, progress: progress, cancellation: cancellation) }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.entry = entry; self.directory = directory
    }
    func load(completion: @escaping (URL?, Bool, Error?) -> Void, progress: Progress, cancellation: OperationCancellation) async {
        RepositoryBrowserExportFiles.activeLoads += 1
        defer { RepositoryBrowserExportFiles.activeLoads -= 1; withExtendedLifetime(access) {} }
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let current: RepositoryBrowserSnapshot
            if let directory { current = try await repository.browseRepositoryDirectory(snapshot, directory: directory) }
            else { current = snapshot }
            let export = try await repository.exportRepositoryBrowser(current, entry: entry, cancellation: cancellation)
            RepositoryBrowserExportFiles.retain(export)
            completion(export.item, false, nil); progress.completedUnitCount = 1
        } catch { completion(nil, false, error) }
    }
}
