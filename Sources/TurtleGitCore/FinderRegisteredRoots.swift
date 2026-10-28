// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// Durable command-discovery hints for explicitly watched repositories. This
/// catalog is neither a status snapshot nor a sandbox/metadata permission grant.
/// No consumer may derive badges, tracked-file state or filesystem authority.
public struct FinderRegisteredRoots: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case unknown, workingTree, bare }
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let root: String
        public let kind: Kind
        public init(id: UUID, root: String, kind: Kind = .unknown) { self.id = id; self.root = root; self.kind = kind }
    }
    public enum Failure: LocalizedError {
        case invalidCatalog, sourceChanged, lockTimeout
        public var errorDescription: String? {
            switch self {
            case .invalidCatalog: return "The registered repository menu context is invalid."
            case .sourceChanged: return "Watched repositories changed while updating their Finder menu context. Retry the update."
            case .lockTimeout: return "Another registered repository menu update did not finish. Retry the update."
            }
        }
    }
    public static let maximumEntries = 4096
    public static let maximumBytes = 2 * 1024 * 1024
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("registered-roots.json") }
    public let entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }
    private enum CodingKeys: String, CodingKey { case version, entries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw Failure.invalidCatalog }
        entries = try values.decode([Entry].self, forKey: .entries)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(entries, forKey: .entries)
    }
    private func validate() throws {
        guard entries.count <= Self.maximumEntries else { throw Failure.invalidCatalog }
        var ids = Set<UUID>(), roots = Set<GitReferenceName>()
        for entry in entries {
            guard ids.insert(entry.id).inserted, roots.insert(GitReferenceName(entry.root)).inserted,
                  entry.root.hasPrefix("/"), entry.root != "/", !entry.root.utf8.contains(0), entry.root.utf8.count <= 16384,
                  !entry.root.split(separator: "/").contains(where: { $0 == ".git" }),
                  GitReferenceName.equal(FileTransferPaths.lexicalPath(entry.root), entry.root) else { throw Failure.invalidCatalog }
        }
    }
    /// Lexical lookup only. Dispatch must reacquire a real retained bookmark and
    /// discover the current repository before executing any requested action.
    public func root(for path: URL) -> Entry? {
        guard path.isFileURL else { return nil }
        do { try validate() } catch { return nil }
        let requested = FileTransferPaths.lexicalPath(path.path)
        return entries.filter { entry in
            GitReferenceName.equal(requested, entry.root) || requested.utf8.starts(with: (entry.root == "/" ? "/" : entry.root + "/").utf8)
        }.max { $0.root.utf8.count < $1.root.utf8.count }
    }
    public static func read(from url: URL? = sharedURL) throws -> Self {
        guard let url else { return Self() }
        guard let (data, _) = try readFile(url, limit: maximumBytes) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    private struct FileIdentity: Equatable {
        let device: UInt64, inode: UInt64, size: Int64
        let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
        init(_ info: stat) {
            device = UInt64(UInt32(bitPattern: info.st_dev)); inode = UInt64(info.st_ino); size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
    private static func identity(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw Failure.invalidCatalog }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidCatalog }
        return FileIdentity(info)
    }
    private static func readFile(_ url: URL, limit: Int) throws -> (Data, FileIdentity)? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw Failure.invalidCatalog }
        defer { Darwin.close(descriptor) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else { throw Failure.invalidCatalog }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        data.reserveCapacity(Int(before.st_size))
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw Failure.invalidCatalog }
            if count == 0 { break }
            guard count <= limit - data.count else { throw Failure.invalidCatalog }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &after) == 0, FileIdentity(before) == FileIdentity(after),
              try identity(url) == FileIdentity(after) else { throw Failure.sourceChanged }
        return (data, FileIdentity(after))
    }
    /// Read current watch policy without resolving any bookmark or exporting
    /// private bookmark bytes. Used only by the native archive owner.
    public static func readWatchRoots(from watchArchive: URL) throws -> Self {
        for _ in 0..<3 {
            do {
                let source = try readFile(watchArchive, limit: 32 * 1024 * 1024)
                let records = try source.map { try JSONDecoder().decode([SavedRepository].self, from: $0.0) } ?? []
                guard records.count <= maximumEntries else { throw Failure.invalidCatalog }
                let value = Self(entries: records.map { Entry(id: $0.id, root: $0.lastKnownPath) })
                try value.validate()
                return value
            } catch Failure.sourceChanged { continue }
        }
        throw Failure.sourceChanged
    }
    public static let localChangeNotification = "org.turtlegit.macos.registeredRootsChangedLocally"
    /// The latest private archive, never a publisher's cached in-memory rows,
    /// owns this projection. Independent managers/processes serialize here.
    /// Hints select only kind metadata for an exact current (watch ID, root).
    @discardableResult public static func publish(watchArchive: URL, kindHints: [Entry], to url: URL,
                                                  cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        guard kindHints.count <= maximumEntries else { throw Failure.invalidCatalog }
        try FileManager.default.createDirectory(at: watchArchive.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(watchArchive.path + ".registered-context.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.invalidCatalog }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidCatalog }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            try cancellation?.check()
            guard failure == EWOULDBLOCK || failure == EINTR else { throw Failure.invalidCatalog }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.lockTimeout }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        var changed = false
        for _ in 0..<3 {
            try cancellation?.check()
            do {
                let source = try readFile(watchArchive, limit: 32 * 1024 * 1024)
                let records = try source.map { try JSONDecoder().decode([SavedRepository].self, from: $0.0) } ?? []
                guard records.count <= maximumEntries else { throw Failure.invalidCatalog }
                let previous = (try? read(from: url)) ?? FinderRegisteredRoots()
                let hintsByID = Dictionary(grouping: kindHints, by: \.id)
                let previousByID = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
                let entries = records.map { record -> Entry in
                    let hint = hintsByID[record.id]?.first { GitReferenceName.equal($0.root, record.lastKnownPath) && $0.kind != .unknown }
                    let old = previousByID[record.id].flatMap { GitReferenceName.equal($0.root, record.lastKnownPath) ? $0 : nil }
                    return Entry(id: record.id, root: record.lastKnownPath, kind: hint?.kind ?? old?.kind ?? .unknown)
                }.sorted { $0.id.uuidString < $1.id.uuidString }
                let current = FinderRegisteredRoots(entries: entries)
                try current.validate(); try cancellation?.check()
                guard try identity(watchArchive) == source?.1 else { continue }
                changed = try current.write(to: url, cancellation: cancellation) || changed
                // A concurrent private archive writer does not hold this menu
                // lock. Repair its projection before releasing a late publisher.
                if try identity(watchArchive) == source?.1 { return changed }
            } catch Failure.sourceChanged { continue }
        }
        throw Failure.sourceChanged
    }
    @discardableResult public func write(to url: URL? = FinderRegisteredRoots.sharedURL, cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check(); try validate()
        guard let url else { return false }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.invalidCatalog }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidCatalog }
            if let current = try? Self.read(from: url), current == self { return false }
        } else if errno != ENOENT { throw Failure.invalidCatalog }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cancellation?.check()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
