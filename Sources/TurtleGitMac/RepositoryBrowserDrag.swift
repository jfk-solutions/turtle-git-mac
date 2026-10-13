// Replaces RepositoryBrowser.cpp/GitDataObject.cpp historical drag data with native item providers.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit; 2003-2014 TortoiseSVN.
import AppKit
import SwiftUI
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
            if let directory { current = try await repository.browseRepositoryDirectory(snapshot, directory: directory, cancellation: cancellation) }
            else { current = snapshot }
            let export = try await repository.exportRepositoryBrowser(current, entry: entry, cancellation: cancellation)
            RepositoryBrowserExportFiles.retain(export)
            completion(export.item, false, nil); progress.completedUnitCount = 1
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
        Task { @MainActor [self] in
            RepositoryBrowserExportFiles.activeLoads += 1
            defer { RepositoryBrowserExportFiles.activeLoads -= 1;withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let listing: RepositoryBrowserSnapshot
                if let directory { listing = try await repository.browseRepositoryDirectory(snapshot,directory:directory) } else { listing = snapshot }
                let export=try await repository.exportRepositoryBrowser(listing,entry:entry)
                defer { export.discard() }
                let staging=url.deletingLastPathComponent().appendingPathComponent(".turtlegit-promise-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:staging) }
                try FileManager.default.copyItem(at:export.item,to:staging)
                try FileManager.default.moveItem(at:staging,to:url)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}

/// Tree and root rows use AppKit's promised-file drag surface, like the list.
@MainActor struct RepositoryFolderDragButton: NSViewRepresentable {
    @ObservedObject var model: RepositoryBrowserWindowModel
    let path: String
    let name: String
    func makeNSView(context: Context) -> RepositoryFolderNativeButton { RepositoryFolderNativeButton() }
    func updateNSView(_ button: RepositoryFolderNativeButton, context: Context) {
        button.model=model; button.path=path; button.title=name
        button.isEnabled=model.canUseMenu
        button.layer?.backgroundColor=(model.snapshot?.directory == path ? NSColor.controlAccentColor.withAlphaComponent(0.2) : NSColor.clear).cgColor
    }
}
@MainActor final class RepositoryFolderNativeButton: NSButton, NSDraggingSource {
    weak var model: RepositoryBrowserWindowModel?
    var path=""
    override init(frame: NSRect) {
        super.init(frame:frame); isBordered=false; alignment = .left; imagePosition = .imageLeft
        image=NSWorkspace.shared.icon(for:.folder); imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize:12); cell?.lineBreakMode = .byTruncatingTail
        wantsLayer=true; layer?.cornerRadius=3; target=self; action=#selector(openFolder)
        setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func openFolder() { model?.openFolder(path) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let owner=window, let model, let target=model.menuTarget() else { return }
        let start=convert(event.locationInWindow,from:nil)
        highlight(true); defer { highlight(false) }
        while self.window === owner && model.acceptsMenu(target) {
            guard let next=owner.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown],until:Date().addingTimeInterval(0.1),inMode:.eventTracking,dequeue:true) else { continue }
            if next.type == .keyDown { if next.keyCode == 53 { return }; continue }
            if next.type == .leftMouseUp { if bounds.contains(convert(next.locationInWindow,from:nil)) { performClick(nil) }; return }
            let point=convert(next.locationInWindow,from:nil)
            guard hypot(point.x-start.x,point.y-start.y) >= 4, let promise=model.folderPromise(path) else { continue }
            let item=NSDraggingItem(pasteboardWriter:promise)
            let preview=NSImage(size:bounds.size)
            if let bitmap=bitmapImageRepForCachingDisplay(in:bounds) { cacheDisplay(in:bounds,to:bitmap); preview.addRepresentation(bitmap) }
            item.setDraggingFrame(bounds,contents:preview)
            beginDraggingSession(with:[item],event:next,source:self); return
        }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
}
