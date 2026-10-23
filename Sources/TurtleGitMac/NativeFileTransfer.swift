// SPDX-License-Identifier: GPL-2.0-or-later
// Shared receiver-owned transfer accounting, retention and exclusive publication.
import Foundation
import TurtleGitCore
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
