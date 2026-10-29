// Replaces RepositoryBrowser.cpp/GitDataObject.cpp historical drag data with native item providers.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit; 2003-2014 TortoiseSVN.
import AppKit
import TurtleGitCore
import UniformTypeIdentifiers
import Darwin

/// Count a request before dispatching it to the main actor. Quit must also see
/// work queued by an arbitrary NSItemProvider/NSFilePromise callback thread.
private typealias RepositoryBrowserTransferReceipt=NativeFileTransferActivity.Receipt

/// A provider owns its prepared exports. Releasing it cleans up those copies;
/// the global registry only permits explicit app-termination cleanup.
fileprivate typealias RepositoryBrowserExportRetention=NativeFileExportRetention
private final class RepositoryBrowserWeakRetention {
    weak var value: RepositoryBrowserExportRetention?
    init(_ value: RepositoryBrowserExportRetention) { self.value = value }
}

@MainActor enum RepositoryBrowserExportFiles {
    static var activeLoads: Int { NativeFileTransferActivity.browser.active }
    private static var owners: [RepositoryBrowserWeakRetention] = []
    fileprivate static func owner() -> RepositoryBrowserExportRetention {
        owners.removeAll { $0.value == nil }
        let value = RepositoryBrowserExportRetention(); owners.append(RepositoryBrowserWeakRetention(value)); return value
    }
    static func discardAll() { for owner in owners { owner.value?.discardAll() }; owners.removeAll() }
}

@MainActor enum RepositoryBrowserDrag {
    static func provider(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?, name: String, folder: Bool,backend:GitLibGit2Configuration? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        // A display label is not a delivery filename. Invalid direct callers
        // still receive a typed refusal from load, without advertising a key.
        let deliveryName=try? RepositoryBrowserDelivery.name(repository:repository,snapshot:snapshot,entry:entry,directory:directory)
        provider.suggestedName = deliveryName
        let type = folder ? UTType.folder : deliveryName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
        let payload = RepositoryBrowserDragPayload(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory,backend:backend)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let cancellation = OperationCancellation(), progress = Progress(totalUnitCount: 1)
            let receipt = RepositoryBrowserTransferReceipt(.browser)
            progress.cancellationHandler = { cancellation.cancel() }
            Task { await payload.load(completion: completion, progress: progress, cancellation: cancellation); withExtendedLifetime(receipt) {} }
            return progress
        }
        return provider
    }
}

/// The metadata name and eventual file delivery share the same admission rule.
/// Never derive a native path from an escaped label or an opaque selection key.
private enum RepositoryBrowserDelivery {
    static func name(repository:GitRepository,snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry?,directory:String?) throws -> String {
        if let entry,![.directory,.submodule].contains(entry.kind) {
            try RepositoryBrowserTransferPolicy.validateHistoricalFiles(snapshot,entries:[entry])
            return try HistoricalFileDeliveryName.transferLeaf(path:entry.path)
        }
        try RepositoryBrowserTransferPolicy.validate(snapshot,entries:entry.map{[$0]} ?? [])
        let key=directory ?? snapshot.directory
        try RepositoryBrowserTransferPolicy.validateDirectory(key)
        let path=try RepositoryBrowserGitPath(key:key)
        guard let value=path.utf8 else {throw RepositoryBrowserTransferFailure.unrepresentablePath(path.display)}
        return value.isEmpty ? repository.root.lastPathComponent : String(value.split(separator:"/").last!)
    }
    @MainActor static func export(repository:GitRepository,snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry?,cancellation:OperationCancellation?,backend:GitLibGit2Configuration)async throws->RepositoryBrowserExport {
        guard snapshot.root==repository.root else{throw RepositoryBrowserFailure.selection}
        if let entry,!entry.isPathRepresentable,![.directory,.submodule].contains(entry.kind),let revision=snapshot.objectID {
            try RepositoryBrowserTransferPolicy.validateHistoricalFiles(snapshot,entries:[entry])
            let file=CommitFile(path:entry.path,oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
            let plan=try FileListDragPlan(root:repository.root,revision:.revision(revision),files:[file],backend:backend)
            guard case .historical(let value)=try await repository.materializeFileListDrag(plan,itemAt:0,cancellation:cancellation) else{throw RepositoryBrowserFailure.selection}
            return value
        }
        return try await repository.exportRepositoryBrowser(snapshot,entry:entry,cancellation:cancellation,backend:backend)
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
    let backend:GitLibGit2Configuration
    private let retention = RepositoryBrowserExportFiles.owner()
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry?, directory: String?,backend:GitLibGit2Configuration? = nil) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.entry = entry; self.directory = directory;self.backend=backend ?? repository.libgit2Configuration ?? .load()
    }
    func load(completion: @escaping (URL?, Bool, Error?) -> Void, progress: Progress, cancellation: OperationCancellation) async {
        defer { withExtendedLifetime(access) {} }
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            _ = try RepositoryBrowserDelivery.name(repository:repository,snapshot:snapshot,entry:entry,directory:directory)
            let current: RepositoryBrowserSnapshot
            if let directory { current = try await repository.browseRepositoryDirectory(snapshot, directory: directory, cancellation: cancellation) }
            else { current = snapshot }
            let export = try await RepositoryBrowserDelivery.export(repository:repository,snapshot:current,entry:entry,cancellation:cancellation,backend:backend)
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
    let backend:GitLibGit2Configuration
    let name:String
    init(repository:GitRepository,access:RepositoryAccessLease?,snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry? = nil,directory:String? = nil,backend:GitLibGit2Configuration? = nil) {
        self.repository=repository;self.access=access;self.snapshot=snapshot;self.entry=entry;self.directory=directory;self.backend=backend ?? repository.libgit2Configuration ?? .load()
        self.name=(try? RepositoryBrowserDelivery.name(repository:repository,snapshot:snapshot,entry:entry,directory:directory)) ?? "historical-item"
    }
    func provider() -> NSFilePromiseProvider {
        let type=entry == nil || entry?.kind == .directory || directory != nil ? UTType.folder : UTType(filenameExtension:(name as NSString).pathExtension) ?? .data
        let provider=NSFilePromiseProvider(fileType:type.identifier,delegate:self);provider.userInfo=self;return provider
    }
    func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,fileNameForType fileType:String) -> String { name }
    func operationQueue(for filePromiseProvider:NSFilePromiseProvider) -> OperationQueue { .main }
    nonisolated func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping (Error?)->Void) {
        let receipt = RepositoryBrowserTransferReceipt(.browser)
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
        _ = try RepositoryBrowserDelivery.name(repository:repository,snapshot:snapshot,entry:entry,directory:directory)
        let listing: RepositoryBrowserSnapshot
        if let directory { listing = try await repository.browseRepositoryDirectory(snapshot, directory: directory, cancellation: cancellation) } else { listing = snapshot }
        let export = try await RepositoryBrowserDelivery.export(repository:repository,snapshot:listing,entry:entry,cancellation:cancellation,backend:backend)
        defer { export.discard(); withExtendedLifetime(access) {} }
        let source = export.item
        try await Task.detached(priority: .userInitiated) {
            try Self.writeMaterialized(source, to: url, cancellation: cancellation)
        }.value
    }
    nonisolated private static func writeMaterialized(_ source: URL, to url: URL, cancellation: OperationCancellation?) throws {
        try NativeFileTransferFiles.writeExclusive(source,to:url,cancellation:cancellation)
    }
}

/// Immutable source selection. Text follows the source's recursive leaf-path
/// list, while each real top-level item remains an independent native promise.
@MainActor final class RepositoryBrowserSelectionDrag {
    let paths:[String]
    let text:String
    let revision:String
    let treeID:String
    let names:[String]
    let promises:[RepositoryBrowserFilePromise]
    let writers:[NSPasteboardWriting]
    let providers:[NSItemProvider]
    let textProvider:NSItemProvider
    private let access:RepositoryAccessLease?
    init?(repository:GitRepository,access:RepositoryAccessLease?,snapshot:RepositoryBrowserSnapshot,selected:[RepositoryBrowserEntry],inventory:[RepositoryBrowserEntry]?,backend:GitLibGit2Configuration) {
        guard let revision=snapshot.objectID,let treeID=snapshot.treeID,!selected.isEmpty else{return nil}
        guard (try? RepositoryBrowserTransferPolicy.validateSelection(snapshot,selected:selected,inventory:inventory)) != nil else{return nil}
        var children:RepositoryBrowserPathMap<[RepositoryBrowserEntry]>=[:]
        if let inventory {
            for entry in inventory {
                let parent=entry.parentPathKey
                var values=children[parent] ?? [];values.append(entry);children[parent]=values
            }
        }
        var paths:[String]=[],textBytes=0
        func append(_ entry:RepositoryBrowserEntry) -> Bool {
            if entry.kind != .directory {textBytes += RepositoryBrowserGitPath.display(key:entry.path).utf8.count+2;guard paths.count<100_000,textBytes<=16_777_216 else{return false};paths.append(entry.path);return true}
            guard inventory != nil else{return false}
            // CShadowFilesTree uses an ordinal CString map for each directory.
            for child in (children[entry.path] ?? []).sorted(by:{$0.name.utf16.lexicographicallyPrecedes($1.name.utf16)}) {
                guard append(child) else{return false}
            }
            return true
        }
        for entry in selected {guard append(entry) else{return nil}}
        guard !paths.isEmpty else{return nil}
        self.paths=paths;self.text=paths.map{RepositoryBrowserGitPath.display(key:$0)+"\r\n"}.joined();self.revision=revision;self.treeID=treeID;self.access=access
        let real=selected.filter{$0.kind != .submodule}
        self.promises=real.map{RepositoryBrowserFilePromise(repository:repository,access:access,snapshot:snapshot,entry:$0.kind == .directory ? nil : $0,directory:$0.kind == .directory ? $0.path : nil,backend:backend)}
        self.names=promises.map(\.name)
        let textItem=RepositoryBrowserTextWriter(text:text,access:access)
        self.writers=[textItem]+promises.map{$0.provider()}
        let textProvider=NSItemProvider()
        textProvider.registerDataRepresentation(forTypeIdentifier:UTType.utf8PlainText.identifier,visibility:.all){completion in
            completion(Data(textItem.text.utf8),nil);withExtendedLifetime(textItem){};return nil
        }
        self.textProvider=textProvider
        self.providers=real.map{RepositoryBrowserDrag.provider(repository:repository,access:access,snapshot:snapshot,entry:$0.kind == .directory ? nil : $0,directory:$0.kind == .directory ? $0.path : nil,name:(try? RepositoryBrowserDelivery.name(repository:repository,snapshot:snapshot,entry:$0.kind == .directory ? nil:$0,directory:$0.kind == .directory ? $0.path:nil)) ?? "historical-item",folder:$0.kind == .directory,backend:backend)}
    }
    func write(to pasteboard:NSPasteboard)->Bool {pasteboard.clearContents();return pasteboard.writeObjects(writers)}
}

/// The pasteboard may ask for text after the originating window has retired.
@MainActor private final class RepositoryBrowserTextWriter:NSObject,NSPasteboardWriting {
    nonisolated let text:String
    let access:RepositoryAccessLease?
    init(text:String,access:RepositoryAccessLease?){self.text=text;self.access=access}
    nonisolated func writableTypes(for pasteboard:NSPasteboard)->[NSPasteboard.PasteboardType]{[.string]}
    nonisolated func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType)->Any?{type == .string ? text : nil}
}
