// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum GitLibGit2Operation: UInt32, Sendable {
    case clone = 1, fetch = 2, commitUpdateIndex = 3, diff = 4, reset = 5, revert = 6, deleteTagBranch = 8, getOneFile = 9, add = 10, push = 11, logListDiff = 15, branchContains = 16, forEachRef = 18
    public var mask: UInt32 { 1 << rawValue }
}
public enum GitLibGit2Failure: LocalizedError {
    case runtimeMissing
    public var errorDescription: String? { "The requested libgit2 runtime is unavailable. Install a build containing the libgit2 helper." }
}
/// Capture once for an accepted operation before asynchronous preparation.
/// Source Git.h stores command indices (Clone1/Fetch2/Add10), rather than bit masks.
public struct GitLibGit2Configuration: Sendable {
    public static let defaultMask: UInt32 = 0x66780
    public let enabled: Bool
    public let mask: UInt32
    public let helperURL: URL?
    public init(enabled: Bool = true, mask: UInt32 = Self.defaultMask, helperURL: URL? = nil) {
        self.enabled = enabled; self.mask = mask; self.helperURL = helperURL
    }
    public static func load(from defaults: UserDefaults = .standard, helperURL: URL? = nil) -> Self {
        .init(enabled: (defaults.object(forKey: "UseLibgit2") as? NSNumber)?.boolValue ?? true,
              mask: (defaults.object(forKey: "UseLibgit2_mask") as? NSNumber)?.uint32Value ?? defaultMask, helperURL: helperURL)
    }
    public func requests(_ operation: GitLibGit2Operation) -> Bool { enabled && mask & operation.mask != 0 }
    public func executor(for operation: GitLibGit2Operation, bundle: Bundle = .main) throws -> URL? {
        guard requests(operation) else { return nil }
        if let helperURL {
            guard helperURL.isFileURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw GitLibGit2Failure.runtimeMissing }
            return helperURL
        }
        let packaged = bundle.bundleURL.appendingPathComponent("Contents/Helpers/LibGit2/bin/turtlegit-libgit2")
        if FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        #if DEBUG
        if !GitRuntime.isAppStoreBuild {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let development = root.appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
            if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        }
        #endif
        throw GitLibGit2Failure.runtimeMissing
    }
}

/// A native prompt holds this file lock through its UI and export retirement.
/// Cancellation publishes the marker first, then obtains the lock before the
/// ordinary process-group interruption. A newly starting prompt sees the marker
/// and cannot open another question between readiness and group termination.
final class GitRemotePromptCancellation {
    let lockURL: URL, cancelURL: URL, filterLockURL: URL
    private let descriptor: Int32
    private let filterDescriptor: Int32
    private var exclusive = false
    init(directory: URL) throws {
        lockURL = directory.appendingPathComponent("remote-prompt.lock")
        cancelURL = directory.appendingPathComponent("remote-prompt.cancel")
        filterLockURL = directory.appendingPathComponent("filter-worker.lock")
        let prompt = open(lockURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard prompt >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let filter = open(filterLockURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard filter >= 0 else { let code = errno; close(prompt); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        descriptor = prompt; filterDescriptor = filter
    }
    var environment: [String: String] {
        ["TURTLEGIT_REMOTE_PROMPT_LOCK": lockURL.path, "TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE": cancelURL.path,
         "TURTLEGIT_LIBGIT2_FILTER_LOCK": filterLockURL.path]
    }
    func cancellationReady() -> Bool {
        let marker = open(cancelURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if marker >= 0 { close(marker) }
        else if errno != EEXIST { return false }
        if exclusive { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        guard flock(filterDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            // A draining filter may itself be retiring an askpass child. Never
            // keep its prompt lock while waiting for the separate worker lock.
            flock(descriptor, LOCK_UN); return false
        }
        exclusive = true; return true
    }
    deinit {
        if exclusive { flock(filterDescriptor, LOCK_UN); flock(descriptor, LOCK_UN) }
        close(filterDescriptor); close(descriptor)
    }
}

/// Bounded source-application lifetime only. No persistent filename or defaults.
final class GitRemoteCertificateAcceptanceCache: @unchecked Sendable {
    static let shared = GitRemoteCertificateAcceptanceCache()
    private let lock = NSLock()
    private var entries: [GitRemoteCertificateAcceptance] = []
    func snapshot() -> [GitRemoteCertificateAcceptance] { lock.lock(); defer { lock.unlock() }; return entries }
    func merge(_ values: [GitRemoteCertificateAcceptance]) {
        lock.lock(); defer { lock.unlock() }
        for value in values {
            guard (try? value.validate()) != nil else { continue }
            entries.removeAll { $0.key == value.key }; entries.append(value)
            if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        }
    }
}

/// One real helper invocation's private exchange; the original open inode and
/// strict framing are checked after exit before any new acceptance is imported.
final class GitRemoteCertificateAcceptanceExchange {
    let url: URL
    private let descriptor: Int32
    private let inode: ino_t, device: dev_t
    private let cache: GitRemoteCertificateAcceptanceCache
    private let seed: Data
    init(directory: URL, cache: GitRemoteCertificateAcceptanceCache = .shared) throws {
        let file = directory.appendingPathComponent("remote-certificate-acceptances.jsonl")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var transferred = false; defer { if !transferred { close(fd) } }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var initial = Data(); for value in cache.snapshot() { initial.append(try value.encodedLine()) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: initial)
        self.cache = cache; url = file; descriptor = fd; inode = info.st_ino; device = info.st_dev; seed = initial
        transferred = true
    }
    var environment: [String: String] { ["TURTLEGIT_LIBGIT2_CERTIFICATE_ACCEPTANCES": url.path] }
    func consume(cancelled: Bool) {
        guard !cancelled else { return }
        var info = stat(), pathInfo = stat()
        guard fstat(descriptor, &info) == 0, lstat(url.path, &pathInfo) == 0,
              info.st_ino == inode, info.st_dev == device, pathInfo.st_ino == inode, pathInfo.st_dev == device,
              (info.st_mode & S_IFMT) == S_IFREG, (pathInfo.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= GitRemoteCertificateAcceptance.maximumBytes else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.read(upToCount: GitRemoteCertificateAcceptance.maximumBytes + 1),
              data.starts(with:seed), (try? GitRemoteCertificateAcceptance.decode(data)) != nil,
              let values = try? GitRemoteCertificateAcceptance.decode(Data(data.dropFirst(seed.count))) else { return }
        cache.merge(values)
    }
    deinit { close(descriptor) }
}

// Source RemoteProgressCommand and CloneProgressCommand receipts. These travel
// only over our helper's private stdout result channel, never remote sideband.
public enum GitTransferReferenceChange:String,Sendable,Codable {
    case same,new,deleted,forward,rewind,newerTime,olderTime,sameTime,unclassified
}
public struct GitTransferReferenceUpdate:Sendable,Equatable {
    public let repositoryPath:String,reference:String,oldHash:String,newHash:String
    public let change:GitTransferReferenceChange
    public let count:UInt64?
    public init(repositoryPath:String,reference:String,oldHash:String,newHash:String,change:GitTransferReferenceChange,count:UInt64?) {self.repositoryPath=repositoryPath;self.reference=reference;self.oldHash=oldHash;self.newHash=newHash;self.change=change;self.count=count}
    public static func ==(a:Self,b:Self)->Bool {a.repositoryPath.utf8.elementsEqual(b.repositoryPath.utf8) && a.reference.utf8.elementsEqual(b.reference.utf8) && a.oldHash==b.oldHash && a.newHash==b.newHash && a.change==b.change && a.count==b.count}
}
public struct GitTransferCheckout:Sendable,Equatable {
    public let repositoryPath:String,path:String
    public let completed:UInt64,total:UInt64
    public init(repositoryPath:String,path:String,completed:UInt64,total:UInt64) {self.repositoryPath=repositoryPath;self.path=path;self.completed=completed;self.total=total}
    public static func ==(a:Self,b:Self)->Bool {a.repositoryPath.utf8.elementsEqual(b.repositoryPath.utf8) && a.path.utf8.elementsEqual(b.path.utf8) && a.completed==b.completed && a.total==b.total}
}
public struct GitTransferNotificationIssue:Sendable,Equatable {
    public let message:String
    public let commandSucceeded:Bool
    public init(message:String,commandSucceeded:Bool){self.message=message;self.commandSucceeded=commandSucceeded}
}
public enum GitTransferNotification:Sendable,Equatable {
    case reference(GitTransferReferenceUpdate),checkout(GitTransferCheckout)
    /// Generated locally after the command settles; never accepted from wire.
    case issue(GitTransferNotificationIssue)
}
enum GitTransferNotificationFailure:Error,LocalizedError {
    case framing,budget,payload
    var errorDescription:String? {"Transfer result notifications could not be read completely. Git may already have updated references or checked out files; inspect the completed operation before retrying."}
}
/// Exact versioned, newline-framed base64 JSON. The decoder is deliberately
/// separate from CLI output and accepts no generic log/diagnostic message type.
final class GitTransferNotificationDecoder {
    static let prefix=Data("TurtleGit Transfer v1:".utf8)
    static let maximumFrame=2*1024*1024,maximumBytes=64*1024*1024,maximumEvents=100_000
    private var pending=Data(),bytes=0,events=0
    func append(_ data:Data,deliver:(GitTransferNotification)->Void)throws {
        guard data.count<=Self.maximumBytes-bytes else{throw GitTransferNotificationFailure.budget};bytes+=data.count
        pending.append(data)
        while let newline=pending.firstIndex(of:10) {
            let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
            guard line.count<=Self.maximumFrame,events<Self.maximumEvents else{throw GitTransferNotificationFailure.budget}
            guard line.starts(with:Self.prefix),let payload=Data(base64Encoded:line.dropFirst(Self.prefix.count)),payload.base64EncodedData()==Data(line.dropFirst(Self.prefix.count)) else{throw GitTransferNotificationFailure.framing}
            let event=try Self.decode(payload);events+=1;deliver(event)
        }
        guard pending.count<=Self.maximumFrame else{throw GitTransferNotificationFailure.budget}
    }
    func finish()throws {guard pending.isEmpty else{throw GitTransferNotificationFailure.framing}}
    private struct Wire:Decodable {
        let kind:String,repositoryPath:String
        let reference:String?,oldHash:String?,newHash:String?,change:GitTransferReferenceChange?,count:UInt64?
        let path:String?,completed:UInt64?,total:UInt64?
    }
    static func validPath(_ path:String,empty:Bool=false)->Bool {
        if path.isEmpty{return empty}
        return path.utf8.count<=1_048_576 && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator:"/",omittingEmptySubsequences:false).contains{$0.isEmpty || $0=="." || $0==".." || $0.caseInsensitiveCompare(".git") == .orderedSame}
    }
    private static func validReference(_ reference:String)->Bool {
        guard reference.hasPrefix("refs/"),reference.utf8.count<=1_048_576,!reference.hasSuffix("."),!reference.contains(".."),!reference.contains("@{"),!reference.utf8.contains(where:{$0<=32 || $0==127 || "~^:?*[\\".utf8.contains($0)}) else{return false}
        return !reference.split(separator:"/",omittingEmptySubsequences:false).contains{$0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock")}
    }
    private static func decode(_ data:Data)throws->GitTransferNotification {
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let wire=try? JSONDecoder().decode(Wire.self,from:data),validPath(wire.repositoryPath,empty:true) else{throw GitTransferNotificationFailure.payload}
        let base:Set<String>=["kind","repositoryPath"]
        if wire.kind=="reference" {
            guard Set(object.keys).isSubset(of:base.union(["reference","oldHash","newHash","change","count"])),
                  let reference=wire.reference,validReference(reference),
                  let old=wire.oldHash,let new=wire.newHash,[40,64].contains(old.count),new.count==old.count,
                  old.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),new.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),let change=wire.change else{throw GitTransferNotificationFailure.payload}
            let oldZero=old.allSatisfy{$0=="0"},newZero=new.allSatisfy{$0=="0"}
            guard object.keys.contains("count")==([.forward,.rewind].contains(change)) else{throw GitTransferNotificationFailure.payload}
            switch change {
            case .forward,.rewind:guard !oldZero,!newZero,old != new,let count=wire.count,count>0 else{throw GitTransferNotificationFailure.payload}
            case .same:guard !oldZero,old==new,wire.count==nil else{throw GitTransferNotificationFailure.payload}
            case .new:guard oldZero,!newZero,wire.count==nil else{throw GitTransferNotificationFailure.payload}
            case .deleted:guard !oldZero,newZero,wire.count==nil else{throw GitTransferNotificationFailure.payload}
            case .newerTime,.olderTime,.sameTime:guard !oldZero,!newZero,old != new,wire.count==nil else{throw GitTransferNotificationFailure.payload}
            case .unclassified:guard wire.count==nil else{throw GitTransferNotificationFailure.payload}
            }
            return .reference(.init(repositoryPath:wire.repositoryPath,reference:reference,oldHash:old,newHash:new,change:change,count:wire.count))
        }
        guard wire.kind=="checkout",Set(object.keys)==base.union(["path","completed","total"]),let path=wire.path,validPath(path),let completed=wire.completed,let total=wire.total,total>0,completed<=total else{throw GitTransferNotificationFailure.payload}
        return .checkout(.init(repositoryPath:wire.repositoryPath,path:path,completed:completed,total:total))
    }
}
/// A malformed metadata record must not turn a completed Git mutation into an
/// apparent rollback. Stop decoding, keep earlier valid receipts, and report a
/// fixed local issue once after the real command has settled.
final class GitTransferNotificationReceiver:@unchecked Sendable {
    private let lock=NSLock(),decoder=GitTransferNotificationDecoder()
    private let callback:(@Sendable(GitTransferNotification)->Void)?
    private let cancellation:OperationCancellation
    private var failed=false,finished=false
    init(cancellation:OperationCancellation,callback:(@Sendable(GitTransferNotification)->Void)?) {self.cancellation=cancellation;self.callback=callback}
    func consume(_ chunk:GitOutputChunk) {
        guard case .stdout=chunk.stream,!chunk.data.isEmpty else{return}
        lock.lock();defer{lock.unlock()};guard !failed,!finished else{return}
        do {try decoder.append(chunk.data) {event in if !cancellation.isCancelled {callback?(event)}}} catch {failed=true}
    }
    func finish(commandSucceeded:Bool) {
        lock.lock();defer{lock.unlock()};guard !finished else{return};finished=true
        if !failed {do{try decoder.finish()}catch{if !cancellation.isCancelled {failed=true}}}
        if failed,!cancellation.isCancelled {callback?(.issue(.init(message:GitTransferNotificationFailure.framing.localizedDescription,commandSucceeded:commandSucceeded)))}
    }
}

extension GitRepository {
    /// The stdout result channel is private only when a captured libgit2
    /// executor was selected. CLI stdout/diagnostics keep their original route.
    func transferArguments(_ arguments:[String],executor:URL?,requested:Bool)->[String] {executor != nil && requested ? ["--turtlegit-transfer-notifications"]+arguments:arguments}
    func runTransfer(_ arguments:[String],environment:[String:String],literalPathspecs:Bool=true,cancellation:OperationCancellation,onOutput:(@Sendable(GitOutputChunk)->Void)?,executor:URL?,onNotification:(@Sendable(GitTransferNotification)->Void)?)throws->GitResult {
        guard let executor,onNotification != nil else{return try run(arguments,environmentOverrides:environment,literalPathspecs:literalPathspecs,cancellation:cancellation,onOutput:onOutput,executorOverride:executor)}
        let receiver=GitTransferNotificationReceiver(cancellation:cancellation,callback:onNotification)
        var succeeded=false;defer{receiver.finish(commandSucceeded:succeeded)}
        do {
            let result=try run(transferArguments(arguments,executor:executor,requested:true),environmentOverrides:environment,literalPathspecs:literalPathspecs,cancellation:cancellation,retainStandardOutput:false,consumeOutput:{receiver.consume($0)},onOutput:{chunk in if case .stderr=chunk.stream {onOutput?(chunk)}},executorOverride:executor)
            succeeded=result.exitCode==0;return result
        } catch let error as GitFailure {throw GitFailure(arguments:arguments,code:error.code,message:error.message,outputWasDelivered:error.outputWasDelivered,standardError:error.standardError)}
    }
}
