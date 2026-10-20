// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// Source BlockStatus uses a global TortoiseGitProc mutex. A persistent Mac app
/// instead holds this advisory lease only while commands are active. The kernel
/// releases ownership on crash; stored PIDs and timestamp heuristics are unused.
public final class FinderStatusOperationLease: @unchecked Sendable {
    public static let notification = "org.turtlegit.macos.finderOperationChanged"
    public static var sharedDirectory: URL? { FinderIntegration.container?.appendingPathComponent("FinderStatusOperations", isDirectory: true) }
    private let lock = NSLock()
    private var descriptor: Int32
    private let notify: @Sendable () -> Void
    private init(descriptor: Int32, notify: @escaping @Sendable () -> Void) { self.descriptor=descriptor; self.notify=notify }
    public static func changed() { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(notification), object:nil) }

    /// Collectors and ordinary inspections must not block their own refreshes.
    /// Unknown commands/aliases conservatively count as command work. This is a
    /// scheduling fence, not an authorization decision about the Git invocation.
    public static func isCommandActivity(_ arguments:[String]) -> Bool {
        let identity=GitCommandIdentity(arguments)
        guard let command=identity.command else { return true }
        let reads:Set<String>=["rev-parse","status","ls-files","for-each-ref","ls-tree","log","show","diff","diff-files","diff-index","diff-tree","merge-base","cat-file","check-ignore","check-attr","show-ref","version","help","name-rev","describe","rev-list","count-objects","ls-remote","turtlegit-unified-diff","turtlegit-history-diff","turtlegit-single-commit","turtlegit-local-refs","turtlegit-ref-names","turtlegit-containing-refs","turtlegit-merge-base","turtlegit-check-clean","turtlegit-check-conflicts","turtlegit-conflict-info","turtlegit-finder-status"]
        if reads.contains(command) { return false }
        let tail=identity.arguments
        if command=="branch",tail.contains("--show-current") || tail.contains("--list") { return false }
        if command=="symbolic-ref",tail.filter({!$0.hasPrefix("-")}).count==1 { return false }
        if command=="config",tail.contains(where:{["--get","--get-all","--get-regexp","--get-urlmatch","--list","-l"].contains($0)}) { return false }
        if command=="worktree",tail.first=="list" { return false }
        if command=="submodule",tail.isEmpty || tail.first=="status" { return false }
        if command=="remote",tail.isEmpty || ["-v","get-url"].contains(tail.first ?? "") { return false }
        if command=="stash",["list","show"].contains(tail.first ?? "") { return false }
        return true
    }

    /// Root is accepted for call-site context; blocking is deliberately global,
    /// as in the source mutex. An unavailable unsigned App Group owns no lease.
    public static func begin(root: URL? = nil, directory: URL? = sharedDirectory,
                             cancellation: OperationCancellation? = nil,
                             notify: @escaping @Sendable () -> Void = { changed() }) throws -> FinderStatusOperationLease? {
        try cancellation?.check()
        guard let directory else { return nil }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent("commands.lock")
        let fd=open(file.path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==geteuid(),info.st_nlink==1 else {
            Darwin.close(fd); throw POSIXError(.EINVAL)
        }
        do {
            // A reader's EX probe is transient. Retry that race briefly without
            // waiting indefinitely behind an invalid external exclusive owner.
            var attempts=0
            while flock(fd,LOCK_SH|LOCK_NB) != 0 {
                let code=errno
                guard (code==EWOULDBLOCK || code==EAGAIN),attempts<7 else {throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)}
                try cancellation?.check();attempts+=1;usleep(1000)
            }
        } catch {Darwin.close(fd);throw error}
        let lease=FinderStatusOperationLease(descriptor:fd,notify:notify)
        do { try cancellation?.check() } catch { lease.end();throw error }
        notify();return lease
    }

    /// One nonblocking lock probe, including when several app instances own work.
    /// An invalid/unreadable existing fence fails closed instead of running a
    /// collector through an unknown owner. A missing fence has no active owner.
    public static func isBlocked(root: URL? = nil, directory: URL? = sharedDirectory) -> Bool {
        guard let directory else { return false }
        let fd=open(directory.appendingPathComponent("commands.lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else { return errno != ENOENT }
        defer { Darwin.close(fd) }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==geteuid(),info.st_nlink==1 else { return true }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else { return true }
        flock(fd,LOCK_UN);return false
    }
    public func end() {
        lock.lock()
        guard descriptor>=0 else { lock.unlock();return }
        let fd=descriptor;descriptor = -1
        flock(fd,LOCK_UN);Darwin.close(fd);lock.unlock()
        // Never unlink a shared advisory fence: doing so could create a second
        // inode while another process still owns the original file description.
        notify()
    }
    deinit { end() }
}
