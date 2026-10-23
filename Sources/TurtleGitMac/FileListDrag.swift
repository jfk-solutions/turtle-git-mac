// SPDX-License-Identifier: GPL-2.0-or-later
// Native GitDataObject file-list drags. A transfer belongs to its receiver,
// independently of the repository window which originally displayed the row.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers
import Darwin

/// Counts callback work before it queues a MainActor task. Keep the two sources
/// independently observable while sharing the same thread-safe ownership rule.
final class NativeFileTransferActivity:@unchecked Sendable {
    static let fileList=NativeFileTransferActivity(),browser=NativeFileTransferActivity()
    private let lock=NSLock()
    private var count=0
    var active:Int {lock.lock();defer{lock.unlock()};return count}
    private func begin(){lock.lock();count += 1;lock.unlock()}
    private func end(){lock.lock();count -= 1;lock.unlock()}
    final class Receipt:@unchecked Sendable {
        private let activity:NativeFileTransferActivity
        init(_ activity:NativeFileTransferActivity){self.activity=activity;activity.begin()}
        deinit{activity.end()}
    }
}

/// Only an owned staging directory is ever removed. Exclusive same-volume
/// rename publishes the completed item without overwriting receiver contents.
enum NativeFileTransferFiles {
    nonisolated static func writeExclusive(_ source:URL,to url:URL,cancellation:OperationCancellation?)throws {
        guard url.isFileURL else{throw RepositoryBrowserFailure.selection}
        try cancellation?.check()
        let scoped=url.startAccessingSecurityScopedResource()
        defer{if scoped{url.stopAccessingSecurityScopedResource()}}
        var coordinationError:NSError?,writeError:Error?
        NSFileCoordinator().coordinate(writingItemAt:url,options:[],error:&coordinationError){destination in
            var directory:URL?
            defer{if let directory{try? FileManager.default.removeItem(at:directory)}}
            do {
                try cancellation?.check()
                // A promised destination can carry file-scoped authority. Ask
                // Foundation for an owned same-volume replacement workspace
                // instead of assuming access to arbitrary sibling names.
                let replacement=try FileManager.default.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:destination,create:true)
                directory=replacement
                var parentInfo=stat(),replacementInfo=stat()
                guard stat(destination.deletingLastPathComponent().path,&parentInfo)==0,lstat(replacement.path,&replacementInfo)==0,
                      replacementInfo.st_mode & S_IFMT == S_IFDIR,parentInfo.st_dev==replacementInfo.st_dev else{throw RepositoryBrowserFailure.selection}
                try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:replacement.path)
                let staging=replacement.appendingPathComponent("item")
                try FileManager.default.copyItem(at:source,to:staging)
                try cancellation?.check()
                guard Darwin.renamex_np(staging.path,destination.path,UInt32(RENAME_EXCL))==0 else{
                    throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSFilePathErrorKey:destination.path])
                }
                // Publication is the completion boundary. A later Cancel must
                // not report a delivered item as an unperformed transfer.
            }catch{writeError=error}
        }
        if let writeError{throw writeError};if let coordinationError{throw coordinationError}
    }
}

final class NativeFileExportRetention:@unchecked Sendable {
    private let lock=NSLock()
    private var exports:[RepositoryBrowserExport]=[]
    func retain(_ value:RepositoryBrowserExport){lock.lock();exports.append(value);lock.unlock()}
    func discardAll(){lock.lock();let values=exports;exports=[];lock.unlock();for value in values{value.discard()}}
    deinit{discardAll()}
}
private final class FileListWeakExportRetention {
    weak var value:NativeFileExportRetention?
    init(_ value:NativeFileExportRetention){self.value=value}
}

@MainActor enum FileListDrag {
    static var activeLoads:Int {NativeFileTransferActivity.fileList.active}
    private static var owners:[FileListWeakExportRetention]=[]
    fileprivate static func retention()->NativeFileExportRetention {
        owners.removeAll{$0.value==nil};let value=NativeFileExportRetention();owners.append(.init(value));return value
    }
    static func discardAll(){guard activeLoads==0 else{return};for owner in owners{owner.value?.discardAll()};owners=[]}

    /// Plans and repository instances are captured at the gesture, not looked up
    /// again from a selection or current window when the receiver asks for data.
    static func provider(repository:GitRepository,access:RepositoryAccessLease?,plan:FileListDragPlan,itemAt index:Int)->NSItemProvider? {
        guard let payload=try? FileListDragPayload(repository:repository,access:access,plan:plan,itemAt:index) else{return nil}
        let provider=NSItemProvider();provider.suggestedName=payload.name
        let type=UTType(filenameExtension:(payload.name as NSString).pathExtension) ?? .data
        let working:Bool;if case .workingTree=plan.revision{working=true}else{working=false}
        if working {
            // The actual URL is an additional raw file-url representation; a
            // zero-revision drag is not silently converted to an index/temp copy.
            provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all){completion in
                let token=OperationCancellation(),progress=Progress(totalUnitCount:1),receipt=NativeFileTransferActivity.Receipt(.fileList)
                progress.cancellationHandler={token.cancel()}
                Task{@MainActor in
                    defer{withExtendedLifetime(receipt){}}
                    do{let url=try await payload.workingURL(cancellation:token);completion(Data(url.absoluteString.utf8),nil);progress.completedUnitCount=1}catch{completion(nil,error)}
                }
                return progress
            }
        }
        provider.registerFileRepresentation(forTypeIdentifier:type.identifier,fileOptions:working ? [.openInPlace]:[],visibility:.all){completion in
            let token=OperationCancellation(),progress=Progress(totalUnitCount:1),receipt=NativeFileTransferActivity.Receipt(.fileList)
            progress.cancellationHandler={token.cancel()}
            Task{@MainActor in await payload.load(completion:completion,progress:progress,cancellation:token);withExtendedLifetime(receipt){}}
            return progress
        }
        return provider
    }

    static func itemWriter(repository:GitRepository,access:RepositoryAccessLease?,plan:FileListDragPlan,itemAt index:Int)->NSPasteboardWriting? {
        guard let payload=try? FileListDragPayload(repository:repository,access:access,plan:plan,itemAt:index) else{return nil}
        if case .workingTree=plan.revision {
            guard let url=try? plan.validatedWorkingURL(itemAt:index) else{return nil}
            return FileListWorkingURLWriter(url:url,payload:payload)
        }
        return FileListFilePromise(payload:payload).provider()
    }
}

/// Keeps the non-Sendable originating lease on MainActor and alive even after
/// the view, its model and its window have all been retired.
@MainActor fileprivate final class FileListDragPayload {
    let repository:GitRepository,access:RepositoryAccessLease?,plan:FileListDragPlan,index:Int,name:String
    private let retention=FileListDrag.retention()
    init(repository:GitRepository,access:RepositoryAccessLease?,plan:FileListDragPlan,itemAt index:Int)throws {
        guard repository.root.path.utf8.elementsEqual(plan.root.path.utf8),plan.items.indices.contains(index) else{throw RevisionComparisonFailure.selection}
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}
        self.repository=repository;self.access=access;self.plan=plan;self.index=index;name=plan.items[index].name
    }
    func materialize(cancellation:OperationCancellation?)async throws->FileListDragMaterialization {
        defer{withExtendedLifetime(access){}}
        try cancellation?.check()
        return try await repository.materializeFileListDrag(plan,itemAt:index,cancellation:cancellation)
    }
    func workingURL(cancellation:OperationCancellation)async throws->URL {
        guard case .workingURL(let url)=try await materialize(cancellation:cancellation) else{throw RevisionComparisonFailure.selection}
        try cancellation.check();return url
    }
    func load(completion:@escaping(URL?,Bool,Error?)->Void,progress:Progress,cancellation:OperationCancellation)async {
        do {
            switch try await materialize(cancellation:cancellation) {
            case .workingURL(let url):try cancellation.check();completion(url,true,nil)
            case .historical(let export):
                guard !cancellation.isCancelled else{export.discard();throw OperationCancellationFailure.cancelled}
                retention.retain(export);completion(export.item,false,nil)
            }
            progress.completedUnitCount=1
        }catch{completion(nil,false,error)}
    }
    func write(to url:URL,cancellation:OperationCancellation?)async throws {
        let materialized=try await materialize(cancellation:cancellation)
        switch materialized {
        case .historical(let export):
            defer{export.discard();withExtendedLifetime(access){}}
            try await Task.detached(priority:.userInitiated){try NativeFileTransferFiles.writeExclusive(export.item,to:url,cancellation:cancellation)}.value
        case .workingURL:
            // Working rows publish their real URL and never promise a copy.
            throw RevisionComparisonFailure.selection
        }
    }
}

@MainActor private final class FileListWorkingURLWriter:NSObject,NSPasteboardWriting {
    private nonisolated let url:URL
    private let payload:FileListDragPayload
    init(url:URL,payload:FileListDragPayload){self.url=url;self.payload=payload}
    nonisolated func writableTypes(for pasteboard:NSPasteboard)->[NSPasteboard.PasteboardType]{[.fileURL]}
    nonisolated func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType)->Any?{type == .fileURL ? url.absoluteString:nil}
}

/// The promise owns this delegate through userInfo. Its callback is counted on
/// the caller's thread before queuing work; no owner-window predicate is used.
@MainActor final class FileListFilePromise:NSObject,NSFilePromiseProviderDelegate {
    private let payload:FileListDragPayload
    var name:String {payload.name}
    fileprivate init(payload:FileListDragPayload){self.payload=payload}
    convenience init(repository:GitRepository,access:RepositoryAccessLease?,plan:FileListDragPlan,itemAt index:Int)throws {
        guard case .revision=plan.revision else{throw RevisionComparisonFailure.selection}
        try self.init(payload:FileListDragPayload(repository:repository,access:access,plan:plan,itemAt:index))
    }
    func provider()->NSFilePromiseProvider {
        let type=UTType(filenameExtension:(name as NSString).pathExtension) ?? .data
        let provider=NSFilePromiseProvider(fileType:type.identifier,delegate:self);provider.userInfo=self;return provider
    }
    func filePromiseProvider(_ provider:NSFilePromiseProvider,fileNameForType fileType:String)->String{name}
    func operationQueue(for provider:NSFilePromiseProvider)->OperationQueue{.main}
    nonisolated func filePromiseProvider(_ provider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void){
        let receipt=NativeFileTransferActivity.Receipt(.fileList)
        Task{@MainActor [self] in
            defer{withExtendedLifetime(receipt){}}
            do{try await payload.write(to:url,cancellation:nil);completionHandler(nil)}catch{completionHandler(error)}
        }
    }
    func write(to url:URL,cancellation:OperationCancellation?=nil)async throws {
        let receipt=NativeFileTransferActivity.Receipt(.fileList)
        defer{withExtendedLifetime(receipt){}}
        try await payload.write(to:url,cancellation:cancellation)
    }
}

/// One accepted working-list gesture. Highlighted paths retain displayed order,
/// including rows which cannot offer file contents. Checked-operation membership
/// never participates in this value. Writers keep the original grant alive.
@MainActor final class WorkingFileListDrag {
    let paths:[String]
    let text:String
    let writers:[NSPasteboardWriting]
    let providers:[NSItemProvider]
    let fileURLs:[URL]
    private let access:RepositoryAccessLease?
    fileprivate init(paths:[String],urls:[URL],writers:[NSPasteboardWriting],providers:[NSItemProvider],access:RepositoryAccessLease?) {
        self.paths=paths;self.text=paths.joined(separator:"\r\n")+"\r\n";fileURLs=urls
        self.writers=writers;self.providers=providers;self.access=access
    }
    @discardableResult func write(to pasteboard:NSPasteboard)->Bool {
        pasteboard.clearContents();return pasteboard.writeObjects(writers)
    }
}

/// The marker names the originating owner, so another list can still accept a
/// real external/cross-owner transfer without recursing into its own source.
@MainActor extension FileListDrag {
    static func workingOriginType(_ origin:String)->NSPasteboard.PasteboardType {
        .init("org.turtlegit.working-file-list-origin."+origin.lowercased())
    }
    static func isOwnWorkingDrop(pasteboard:NSPasteboard,origin:String)->Bool {
        pasteboard.types?.contains(workingOriginType(origin)) == true
    }
    static func isOwnWorkingDrop(providers:[NSItemProvider],origin:String)->Bool {
        providers.contains{$0.hasItemConformingToTypeIdentifier(workingOriginType(origin).rawValue)}
    }
    static func workingSelection(repository:GitRepository,access:RepositoryAccessLease?,entries:[StatusEntry],directories:GitPathSet,backend:GitLibGit2Configuration,origin:String)->WorkingFileListDrag? {
        guard !entries.isEmpty,GitPathSet(entries.map(\.path)).count==entries.count else{return nil}
        // Validate every text path through the public transfer contract before
        // applying URL eligibility. Deleted and directory rows still supply text.
        let candidates=entries.map{CommitFile(path:$0.path,oldPath:$0.originalPath,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)}
        guard (try? FileListDragPlan(root:repository.root,revision:.workingTree,files:candidates,backend:backend)) != nil else{return nil}
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){return nil}
        let paths=entries.map(\.path),text=paths.joined(separator:"\r\n")+"\r\n",marker=workingOriginType(origin)
        let files=entries.map{CommitFile(path:$0.path,oldPath:$0.originalPath,action:$0.state == .deleted ? "D":"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:directories.contains($0.path))}
        guard let plan=try? FileListDragPlan(root:repository.root,revision:.workingTree,files:files,backend:backend) else{return nil}
        var urls:[URL]=[],raw:[NSPasteboardWriting]=[]
        for index in plan.items.indices {
            guard let url=try? plan.validatedWorkingURL(itemAt:index),let writer=itemWriter(repository:repository,access:access,plan:plan,itemAt:index) else{continue}
            urls.append(url);raw.append(writer)
        }
        var writers:[NSPasteboardWriting]=[],providers:[NSItemProvider]=[]
        for index in 0..<max(1,raw.count) {
            let writer=WorkingFileDragWriter(base:raw.indices.contains(index) ? raw[index]:nil,text:index==0 ? text:nil,marker:marker,access:access)
            writers.append(writer)
            let provider=NSItemProvider();provider.suggestedName=urls.indices.contains(index) ? urls[index].lastPathComponent:nil
            for type in writer.writableTypes(for:.general) {
                let data:Data
                if let value=writer.pasteboardPropertyList(forType:type) as? String{data=Data(value.utf8)}else{data=Data()}
                provider.registerDataRepresentation(forTypeIdentifier:type.rawValue,visibility:.all){[writer] completion in
                    completion(data,nil);withExtendedLifetime(writer){};return nil
                }
            }
            providers.append(provider)
        }
        return WorkingFileListDrag(paths:paths,urls:urls,writers:writers,providers:providers,access:access)
    }
}

@MainActor private final class WorkingFileDragWriter:NSObject,NSPasteboardWriting {
    private let base:NSPasteboardWriting?
    private nonisolated let text:String?,marker:NSPasteboard.PasteboardType,url:String?
    private let access:RepositoryAccessLease?
    init(base:NSPasteboardWriting?,text:String?,marker:NSPasteboard.PasteboardType,access:RepositoryAccessLease?) {
        self.base=base;self.text=text;self.marker=marker;self.access=access
        self.url=base?.pasteboardPropertyList(forType:.fileURL) as? String
    }
    nonisolated func writableTypes(for pasteboard:NSPasteboard)->[NSPasteboard.PasteboardType] {
        (url == nil ? []:[.fileURL])+(text == nil ? []:[.string])+[marker]
    }
    nonisolated func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType)->Any? {
        if type == .fileURL{return url};if type == .string{return text};if type == marker{return "1"};return nil
    }
}

/// One accepted selected-file transfer, independent of subsequent navigation
/// or owner retirement. The existing promise/URL writers retain the captured
/// repository grant and perform the shared bounded materialization operation.
@MainActor final class FileListSelectionDrag {
    let paths:[String],text:String,revision:ComparisonRevision
    let writers:[NSPasteboardWriting],providers:[NSItemProvider],textProvider:NSItemProvider
    let fileURLs:[URL]
    private let access:RepositoryAccessLease?
    init?(repository:GitRepository,access:RepositoryAccessLease?,files:[CommitFile],revision:ComparisonRevision,backend:GitLibGit2Configuration) {
        guard !files.isEmpty else{return nil}
        // Validate text-only occurrences as well, without duplicating the Core
        // path grammar or treating an excluded directory as a materialized file.
        let candidates=files.map{CommitFile(path:$0.path,oldPath:$0.oldPath,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)}
        // A synthetic empty comparison endpoint has paths to copy as text,
        // but no contents. Use the working plan only for its path validator;
        // its empty item set prevents any URL or alternate-revision fallback.
        let emptyEndpoint:Bool
        if case .emptyTree=revision {emptyEndpoint=true}else{emptyEndpoint=false}
        let validationRevision:ComparisonRevision=emptyEndpoint ? .workingTree:revision
        guard (try? FileListDragPlan(root:repository.root,revision:validationRevision,files:candidates,backend:backend)) != nil,
              let plan=try? FileListDragPlan(root:repository.root,revision:validationRevision,files:emptyEndpoint ? []:files,backend:backend) else{return nil}
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){return nil}
        self.paths=files.map(\.path);text=paths.joined(separator:"\r\n")+"\r\n";self.revision=revision;self.access=access
        let textWriter=FileListSelectionTextWriter(text:text,access:access)
        var writers:[NSPasteboardWriting]=[textWriter],providers:[NSItemProvider]=[],urls:[URL]=[]
        for index in plan.items.indices {
            if case .workingTree=revision {
                guard let url=try? plan.validatedWorkingURL(itemAt:index) else{continue}
                urls.append(url)
            }
            guard let writer=FileListDrag.itemWriter(repository:repository,access:access,plan:plan,itemAt:index),
                  let provider=FileListDrag.provider(repository:repository,access:access,plan:plan,itemAt:index) else{return nil}
            writers.append(writer);providers.append(provider)
        }
        self.writers=writers;self.providers=providers;fileURLs=urls
        let textProvider=NSItemProvider()
        textProvider.registerDataRepresentation(forTypeIdentifier:NSPasteboard.PasteboardType.string.rawValue,visibility:.all){[textWriter] completion in
            completion(Data(textWriter.text.utf8),nil);withExtendedLifetime(textWriter){};return nil
        }
        self.textProvider=textProvider
    }
    var operationMask:NSDragOperation {
        if case .workingTree=revision,!fileURLs.isEmpty{return [.copy,.move]}
        return .copy // Historical promises are receiver-owned copies.
    }
    @discardableResult func write(to pasteboard:NSPasteboard)->Bool {pasteboard.clearContents();return pasteboard.writeObjects(writers)}
}
@MainActor private final class FileListSelectionTextWriter:NSObject,NSPasteboardWriting {
    nonisolated let text:String
    private let access:RepositoryAccessLease?
    init(text:String,access:RepositoryAccessLease?){self.text=text;self.access=access}
    nonisolated func writableTypes(for pasteboard:NSPasteboard)->[NSPasteboard.PasteboardType]{[.string]}
    nonisolated func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType)->Any?{type == .string ? text:nil}
}

/// A model-free native table gesture adapter. The owner supplies a context nonce
/// and validates its own current highlighted rows when the threshold is crossed.
/// Accepted writers keep their original authority independently of these weak
/// owner callbacks, and the native session retains its source until completion.
@MainActor struct FileListDragInteraction:NSViewRepresentable {
    struct Row {
        let id:String
        let isFile:Bool
        init(id:String,isFile:Bool=true){self.id=id;self.isFile=isFile}
        var rawID:String{id}
    }
    let rows:[Row]
    let generation:()->UUID?
    let capture:([String])->FileListSelectionDrag?
    func makeNSView(context:Context)->Probe{Probe()}
    func updateNSView(_ view:Probe,context:Context){view.rows=rows;view.generation=generation;view.capture=capture}
    static func dismantleNSView(_ view:Probe,coordinator:()){view.retire()}
    final class Probe:NSView,NSDraggingSource {
        var rows:[Row]=[]
        var generation:(()->UUID?)?
        var capture:(([String])->FileListSelectionDrag?)?
        private var active=false,monitor:Any?,closeObserver:NSObjectProtocol?
        private struct Press {let point:NSPoint,row:Int,ids:[Data],generation:UUID}
        private var press:Press?
        private(set) var activeDrag:FileListSelectionDrag?
        private var sessionOwner:Probe?
        var nativeTable:NSTableView? {
            guard active,let content=window?.contentView else{return nil}
            let area=convert(bounds,to:nil)
            func find(_ view:NSView)->NSTableView? {
                if let table=view as? NSTableView,table.numberOfRows==rows.count,
                   area.intersects(table.convert(table.visibleRect,to:nil)){return table}
                return view.subviews.lazy.compactMap(find).first
            }
            return find(content)
        }
        func captureSelection()->FileListSelectionDrag? {
            guard active,generation?() != nil,let table=nativeTable,let window,
                  table.window===window,window.attachedSheet==nil,NSApp.modalWindow==nil else{return nil}
            let ids=table.selectedRowIndexes.compactMap{rows.indices.contains($0) && rows[$0].isFile ? rows[$0].id:nil}
            return capture?(ids)
        }
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        override func viewDidMoveToWindow(){
            super.viewDidMoveToWindow();retire();guard window != nil else{return};active=true
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.retire()}}
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown]){[weak self] event in
                guard let self else{return event};return self.observe(event)
            }
        }
        func retire(){
            active=false;press=nil
            if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}
            if let closeObserver{NotificationCenter.default.removeObserver(closeObserver);self.closeObserver=nil}
            // Closing/dismantling revokes new gestures. Only AppKit's terminal
            // callback releases a transfer which has already been accepted.
        }
        deinit{retire()}
        func observe(_ event:NSEvent)->NSEvent? {
            guard active,let window,event.window===window else{return event}
            if event.type == .rightMouseDown || event.type == .leftMouseUp {press=nil;return event}
            if event.type == .leftMouseDown {
                press=nil
                guard activeDrag==nil,event.clickCount==1,let table=nativeTable,
                      window.attachedSheet==nil,NSApp.modalWindow==nil,let stamp=generation?() else{return event}
                let point=table.convert(event.locationInWindow,from:nil),row=table.row(at:point)
                guard table.visibleRect.contains(point),rows.indices.contains(row),rows[row].isFile,table.column(at:point)>=0 else{return event}
                press=Press(point:event.locationInWindow,row:row,ids:rows.map{Data($0.id.utf8)},generation:stamp)
                return event // AppKit still handles native row/column selection.
            }
            guard event.type == .leftMouseDragged,let press,
                  press.ids==rows.map({Data($0.id.utf8)}),generation?()==press.generation,
                  hypot(event.locationInWindow.x-press.point.x,event.locationInWindow.y-press.point.y)>=4,
                  let table=nativeTable,table.selectedRowIndexes.contains(press.row),let drag=captureSelection() else{return event}
            self.press=nil;activeDrag=drag;sessionOwner=self
            let point=table.convert(event.locationInWindow,from:nil)
            let items=drag.writers.enumerated().map{index,writer in
                let item=NSDraggingItem(pasteboardWriter:writer)
                item.setDraggingFrame(NSRect(x:point.x+CGFloat(index)*3,y:point.y+CGFloat(index)*3,width:24,height:24),contents:MenuIcon.copy.image())
                return item
            }
            table.beginDraggingSession(with:items,event:event,source:self);return nil
        }
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation{activeDrag?.operationMask ?? []}
        func ignoreModifierKeys(for session:NSDraggingSession)->Bool{false}
        func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation){activeDrag=nil;sessionOwner=nil;press=nil}
    }
}
