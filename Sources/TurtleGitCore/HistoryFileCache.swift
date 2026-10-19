// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit
import Darwin

/// Native persistent equivalent of CLogCache's completed diff-file records.
/// Ref labels, notes, walk order and working-tree state never enter this cache.
public struct HistoryFileCache: Sendable {
    public let root: URL
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurtleGit/HistoryFiles-v1", isDirectory: true)
    }
    public init(root: URL = Self.defaultRoot) { self.root = root }
    // Serialize this process's readers, atomic publishers and Saved Data clear.
    // Each operation pins the directory descriptor, so a renamed cache root
    // cannot redirect a later file operation through a replacement symlink.
    private static let lock = NSLock()
    private static let recordLimit = 8 * 1024 * 1024
    private static func isRecord(_ name: String) -> Bool {
        name.hasSuffix(".json") && name.utf8.count == 69 && name.dropLast(5).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
    private func withRoot<T>(create: Bool, missing: () -> T, body: (Int32) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if !create && errno == ENOENT { return missing() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(directory) }
        if create && fchmod(directory, 0o700) != 0 { throw POSIXError(.EACCES) }
        return try body(directory)
    }
    private func records(in directory: Int32) throws -> [(name: String, date: Int, bytes: Int64)] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw POSIXError(.EIO) }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw POSIXError(.EIO) }
        defer { closedir(stream) }
        var result: [(String, Int, Int64)] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard Self.isRecord(name) else { continue }
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG {
                result.append((name, info.st_mtimespec.tv_sec, info.st_size))
            }
        }
        return result
    }
    public func savedRecordCount() throws -> Int {
        try withRoot(create: false, missing: { 0 }) { try records(in: $0).count }
    }
    /// Remove only regular records in our hash namespace, keeping foreign data,
    /// symlinks, directories and the cache root itself intact.
    public func clearSavedRecords() throws {
        try withRoot(create: false, missing: {}) { directory in
            for record in try records(in: directory) {
                if unlinkat(directory, record.name, 0) != 0 && errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
    struct Record: Codable {
        let key: String
        let context: String
        let attributes: String
        let files: [CommitFile]
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ values: [String]) -> String { digest((try? JSONEncoder().encode(values)) ?? Data()) }
    func url(_ key: String) -> URL { root.appendingPathComponent(key + ".json") }
    /// Bounded regular-file reads. Cancellation is checked for every chunk;
    /// neither an oversized file nor a FIFO can stall an optional cache lookup.
    static func readFile(_ path: String, directory: Int32 = AT_FDCWD, limit: Int = 64 * 1024 * 1024,
                         noFollow: Bool = false, cancellation: OperationCancellation?) throws -> Data {
        try cancellation?.check()
        let descriptor = openat(directory, path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (noFollow ? O_NOFOLLOW : 0))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw POSIXError(.EFBIG) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            guard count <= limit - data.count else { throw POSIXError(.EFBIG) }
            data.append(contentsOf: buffer.prefix(count))
        }
        try cancellation?.check(); return data
    }
    func read(_ key: String, cancellation: OperationCancellation? = nil) -> Record? {
        guard Self.isRecord(key + ".json") else { return nil }
        return try? withRoot(create: false, missing: { nil }) { directory in
            let bytes = try Self.readFile(key + ".json", directory: directory, limit: Self.recordLimit,
                                          noFollow: true, cancellation: cancellation)
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            return record.key == key ? record : nil
        }
    }
    func write(_ record: Record, cancellation: OperationCancellation? = nil) {
        guard Self.isRecord(record.key + ".json") else { return }
        do {
            try cancellation?.check()
            let data = try JSONEncoder().encode(record)
            guard data.count <= Self.recordLimit else { return }
            try withRoot(create: true, missing: {}) { directory in
                let temporary = ".record-" + UUID().uuidString
                let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { close(descriptor); unlinkat(directory, temporary, 0) }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        try cancellation?.check()
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw POSIXError(.EIO) }
                        offset += count
                    }
                }
                try cancellation?.check()
                guard renameat(directory, temporary, directory, record.key + ".json") == 0 else { throw POSIXError(.EIO) }
                let entries = try records(in: directory).sorted { $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date }
                // Saturation also handles maliciously large sparse records.
                var bytes = entries.reduce(Int64(0)) { total, next in
                    total > Int64.max - next.bytes ? Int64.max : total + next.bytes
                }, count = entries.count
                for item in entries {
                    try cancellation?.check()
                    if count <= 1024 && bytes <= 128 * 1024 * 1024 { break }
                    if unlinkat(directory, item.name, 0) == 0 { count -= 1; bytes -= item.bytes }
                }
            }
        } catch { /* Optional cache failure must not change a Git read's result. */ }
    }
    public func clear() throws { try clearSavedRecords() }
}

extension GitRepository {
    /// Hash the inputs which can change the interpretation of a commit's trees.
    /// Attributes are fingerprinted using the cached paths on lookup and the new
    /// paths after a miss, including every parent directory and renamed source.
    func historyFileCacheContext(_ entry: LogEntry, cancellation: OperationCancellation?,backend:GitLibGit2Configuration? = nil) throws -> (key: String, context: String, infoAttributes: URL, globalAttributes: URL) {
        let hashes = [entry.hash] + (entry.parents.first.map { [$0] } ?? [])
        guard hashes.allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw RevisionComparisonFailure.range }
        func metadataPath(_ name: String) throws -> URL {
            var bytes = try run(["rev-parse", "--path-format=absolute", "--git-path", name], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard let path = String(data: bytes, encoding: .utf8), !path.isEmpty, !bytes.contains(0) else { throw RevisionComparisonFailure.range }
            return URL(fileURLWithPath: path)
        }
        let info = try metadataPath("info/attributes"), index = try metadataPath("index")
        let trees = try run(["rev-parse", "--revs-only", "--end-of-options"] + hashes.map { $0 + "^{tree}" }, cancellation: cancellation).text.split(separator: "\n").map(String.init)
        guard trees.count == hashes.count, trees.allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw RevisionComparisonFailure.range }
        let config = try run(["config", "--includes", "--null", "--list"], cancellation: cancellation).stdout
        // Git's default attributes file is XDG_CONFIG_HOME/git/attributes.
        var configuredBytes = try run(["config", "--path", "--null", "--get", "core.attributesfile"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        if configuredBytes.last == 0 { configuredBytes.removeLast() }
        guard let configured = String(data: configuredBytes, encoding: .utf8), !configuredBytes.contains(0) else { throw RevisionComparisonFailure.range }
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let global = configured.isEmpty ? xdg.appendingPathComponent("git/attributes") : (configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : root.appendingPathComponent(configured))
        let selected=backend ?? libgit2Configuration ?? .load()
        let helper=try selected.executor(for:.logListDiff)
        let engineURL=helper ?? executable
        let engine = try FileManager.default.attributesOfItem(atPath: engineURL.path)
        let engineIdentity=(helper == nil ? "git:":"libgit2-history15:")+engineURL.path
        let key = HistoryFileCache.digest([root.resolvingSymlinksInPath().path, executable.path,engineIdentity] + hashes)
        let indexDigest: String
        do { indexDigest = HistoryFileCache.digest(try HistoryFileCache.readFile(index.path, cancellation: cancellation)) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { indexDigest = "absent" }
        let diffEnvironment = ["GIT_DIFF_OPTS", "GIT_ATTR_SOURCE", "GIT_ATTR_NOSYSTEM"].map { $0 + "=" + (environment[$0] ?? "") }
        let context = HistoryFileCache.digest(trees + [engineIdentity,"diff-detection-v1=" + diffDetection.historyArguments.joined(separator: ","), HistoryFileCache.digest(config), indexDigest, String(describing: engine[.modificationDate]), String(describing: engine[.size])] + diffEnvironment)
        return (key, context, info, global)
    }
    func historyFileAttributesFingerprint(_ files: [CommitFile], info: URL, global: URL, cancellation: OperationCancellation?) throws -> String {
        var paths: [Data: URL] = [:]
        for path in [root.appendingPathComponent(".gitattributes"), info, global] { paths[Data(path.path.utf8)] = path }
        for file in files {
            for path in [file.path] + (file.oldPath.map { [$0] } ?? []) {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw RevisionComparisonFailure.range }
                var directory = root.appendingPathComponent(path).deletingLastPathComponent()
                while directory != root && directory.path.hasPrefix(root.path + "/") {
                    let path = directory.appendingPathComponent(".gitattributes"); paths[Data(path.path.utf8)] = path; directory.deleteLastPathComponent()
                }
            }
        }
        var fingerprints: [String] = []
        for key in paths.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let path = paths[key]!
            try cancellation?.check()
            fingerprints.append(path.path)
            do { fingerprints.append(HistoryFileCache.digest(try HistoryFileCache.readFile(path.path, cancellation: cancellation))) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { fingerprints.append("absent") }
        }
        return HistoryFileCache.digest(fingerprints)
    }
}
