// SPDX-License-Identifier: GPL-2.0-or-later
// Native GitDataObject file-list drags. A transfer belongs to its receiver,
// independently of the repository window which originally displayed the row.
import AppKit
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
