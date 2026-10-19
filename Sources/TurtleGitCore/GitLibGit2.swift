// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum GitLibGit2Operation: UInt32, Sendable {
    case clone = 1, fetch = 2, commitUpdateIndex = 3, getOneFile = 9, add = 10, push = 11
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
