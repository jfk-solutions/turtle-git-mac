import Foundation

public struct SavedRepository: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var lastKnownPath: String
    public var bookmark: Data
    public var lastOpened: Date
    public var additionalPermissions: [SavedFolderPermission]? = nil
}

public struct SavedFolderPermission: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    public var bookmark: Data
}

public struct ResolvedBookmark {
    public let url: URL
    public let stale: Bool
    public init(url: URL, stale: Bool) { self.url = url; self.stale = stale }
}

/// Injectable so persistence, renewal and scope lifetime can be tested without signing privileges.
public protocol RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemRepositoryBookmarkProvider: RepositoryBookmarkProvider {
    public init() {}
    public func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
    }
    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, stale: stale)
    }
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Keep alive for the entire repository session, including all child Git operations.
public final class RepositoryAccessLease {
    public let url: URL
    public let hasSecurityScope: Bool
    private let provider: any RepositoryBookmarkProvider
    private let ownsScope: Bool
    private let relatedScopes: [RepositoryAccessLease]
    public init(url: URL, provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) {
        self.url = url; self.provider = provider; ownsScope = true; relatedScopes = []
        hasSecurityScope = provider.startAccessing(url)
    }
    private init(primary: RepositoryAccessLease, related: [RepositoryAccessLease]) {
        url = primary.url; provider = primary.provider; hasSecurityScope = primary.hasSecurityScope
        ownsScope = false; relatedScopes = [primary] + related
    }
    /// Keep metadata/object-store grants alive with a session and its child windows.
    /// Containment remains the primary folder's boundary; this is lifetime ownership.
    public func retainingRelatedScopes(_ scopes: [RepositoryAccessLease]) -> RepositoryAccessLease {
        scopes.isEmpty ? self : RepositoryAccessLease(primary: self, related: scopes)
    }
    deinit { if ownsScope && hasSecurityScope { provider.stopAccessing(url) } }
    public func contains(_ candidate: URL) -> Bool {
        Self.pathIsContained(candidate, by: url)
    }
    /// A live file permission, including retained metadata grants. Keep separate
    /// from primary containment used to validate repository/action ownership.
    public func permits(_ candidate: URL) -> Bool {
        hasSecurityScope && contains(candidate) || relatedScopes.contains { $0.permits(candidate) }
    }
    /// Metadata discovery needs every retained live folder, while contains()
    /// deliberately keeps the original working-folder boundary.
    public func permittedFolders(requireSecurityScope:Bool = true)->[URL] {
        var result = !requireSecurityScope || hasSecurityScope ? [url]:[]
        for scope in relatedScopes {result += scope.permittedFolders(requireSecurityScope:requireSecurityScope)}
        var seen=Set<String>()
        return result.filter {seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted}
    }
    public static func pathIsContained(_ candidate: URL, by folder: URL) -> Bool {
        guard candidate.isFileURL, folder.isFileURL else { return false }
        guard let root = Self.canonicalPath(folder), let path = Self.canonicalPath(candidate) else { return false }
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    // Foundation's resolvingSymlinksInPath can leave an entire path unchanged when
    // its final component does not exist. Resolve each link even for a future file.
    private static func canonicalPath(_ url: URL) -> String? {
        var pending = url.path.components(separatedBy: "/")[...]
        var resolved: [String] = []
        var links = 0
        while let component = pending.popFirst() {
            if component.isEmpty || component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let path = "/" + (resolved + [component]).joined(separator: "/")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                links += 1
                guard links <= 40 else { return nil }
                if destination.hasPrefix("/") { resolved = [] }
                pending = (destination.components(separatedBy: "/") + Array(pending))[...]
            } else { resolved.append(component) }
        }
        return "/" + resolved.joined(separator: "/")
    }
}

public enum RepositoryAccessFailure: LocalizedError {
    case unknownRepository, securityScopeUnavailable
    case repositoryRootOutsidePermission(String)
    public var errorDescription: String? {
        switch self {
        case .unknownRepository: return "This saved repository is no longer available. Select its folder again."
        case .securityScopeUnavailable: return "The saved folder permission could not be renewed. Select the repository folder again."
        case .repositoryRootOutsidePermission(let path): return "Select the repository root folder to authorize it: " + path
        }
    }
}

/// Call from the application's main actor. Bookmarks stay in its private container, never the Finder cache.
public final class RepositoryAccessStore {
    public private(set) var repositories: [SavedRepository]
    public let storageURL: URL
    private let provider: any RepositoryBookmarkProvider
    public init(storageURL: URL, provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws {
        self.storageURL = storageURL; self.provider = provider
        if FileManager.default.fileExists(atPath: storageURL.path) {
            repositories = try JSONDecoder().decode([SavedRepository].self, from: Data(contentsOf: storageURL))
        } else { repositories = [] }
    }
    public static var defaultStorageURL: URL {
        #if DEBUG
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("org.turtlegit.macos.documentation-preview") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDocumentationPreview/" + identifier + "/repositories.json")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurtleGit", isDirectory: true).appendingPathComponent("repositories.json")
    }
    private func persist(_ updated: [SavedRepository]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        repositories = updated
    }
    @discardableResult public func remember(_ url: URL) throws -> SavedRepository {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let bookmark = try provider.create(for: url)
        let old = repositories.first { $0.lastKnownPath == path }
        let saved = SavedRepository(id: old?.id ?? UUID(), name: url.lastPathComponent, lastKnownPath: path,
                                    bookmark: bookmark, lastOpened: Date(), additionalPermissions: old?.additionalPermissions)
        let updated = [saved] + repositories.filter { $0.id != saved.id }
        try persist(updated)
        return saved
    }
    public func acquire(_ id: UUID, requireSecurityScope: Bool = false, updatingRecord:Bool = true, recordingOpen:Bool = true) throws -> RepositoryAccessLease {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { throw RepositoryAccessFailure.unknownRepository }
        let resolved = try provider.resolve(repositories[index].bookmark)
        let lease = RepositoryAccessLease(url: resolved.url, provider: provider)
        if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
        guard updatingRecord else { return lease }
        var updated = repositories
        if resolved.stale { updated[index].bookmark = try provider.create(for: resolved.url) }
        updated[index].lastKnownPath = resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
        updated[index].name = resolved.url.lastPathComponent
        if recordingOpen {
            updated[index].lastOpened = Date()
            let entry = updated.remove(at: index); updated.insert(entry, at: 0)
        }
        if updated != repositories { try persist(updated) }
        return lease
    }
    /// Renew one extra grant without requiring unrelated grants to resolve.
    public func acquirePermission(_ id:UUID, permission:UUID, requireSecurityScope:Bool = false) throws -> RepositoryAccessLease {
        guard let index=repositories.firstIndex(where:{ $0.id==id }),
              let offset=repositories[index].additionalPermissions?.firstIndex(where:{ $0.id==permission }),
              let saved=repositories[index].additionalPermissions?[offset] else { throw RepositoryAccessFailure.unknownRepository }
        let resolved=try provider.resolve(saved.bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
        guard !requireSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        var values=repositories
        if resolved.stale { values[index].additionalPermissions?[offset].bookmark=try provider.create(for:resolved.url) }
        values[index].additionalPermissions?[offset].path=resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
        if values != repositories { try persist(values) }
        return lease
    }
    @discardableResult public func replace(_ id:UUID,with url:URL) throws -> SavedRepository {
        guard repositories.contains(where:{ $0.id==id }) else { throw RepositoryAccessFailure.unknownRepository }
        let path=url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !repositories.contains(where:{ $0.id != id && $0.lastKnownPath==path }) else { throw GitConfigurationFailure.invalidValue }
        let value=SavedRepository(id:id,name:url.lastPathComponent,lastKnownPath:path,bookmark:try provider.create(for:url),lastOpened:Date(),additionalPermissions:repositories.first { $0.id==id }?.additionalPermissions)
        try persist([value]+repositories.filter { $0.id != id });return value
    }
    public func addPermission(_ id:UUID, url:URL, replacing permission:UUID? = nil) throws {
        guard let index=repositories.firstIndex(where:{ $0.id==id }) else { throw RepositoryAccessFailure.unknownRepository }
        let path=url.standardizedFileURL.resolvingSymlinksInPath().path
        var values=repositories, grants=values[index].additionalPermissions ?? []
        let existing=grants.first { permission == nil ? $0.path==path : $0.id==permission }
        if permission != nil && existing==nil { throw RepositoryAccessFailure.unknownRepository }
        let grant=SavedFolderPermission(id:existing?.id ?? UUID(),path:path,bookmark:try provider.create(for:url))
        guard existing != nil || grants.count<64 else { throw GitConfigurationFailure.invalidValue }
        grants.removeAll { $0.id==grant.id || $0.path==path };grants.append(grant)
        values[index].additionalPermissions=grants;try persist(values)
    }
    public func removePermission(_ id:UUID, permission:UUID) throws {
        guard let index=repositories.firstIndex(where:{ $0.id==id }) else { throw RepositoryAccessFailure.unknownRepository }
        var values=repositories;values[index].additionalPermissions?.removeAll { $0.id==permission };try persist(values)
    }
    public func acquireAdditionalPermissions(_ id:UUID, requireSecurityScope:Bool = false, skipUnavailable:Bool = false) throws -> [RepositoryAccessLease] {
        guard let index=repositories.firstIndex(where:{ $0.id==id }) else { throw RepositoryAccessFailure.unknownRepository }
        var values=repositories, grants=values[index].additionalPermissions ?? [], leases:[RepositoryAccessLease]=[]
        for offset in grants.indices {
            do {
                let resolved=try provider.resolve(grants[offset].bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
                guard !requireSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                if resolved.stale { grants[offset].bookmark=try provider.create(for:resolved.url) }
                grants[offset].path=resolved.url.standardizedFileURL.resolvingSymlinksInPath().path;leases.append(lease)
            } catch { if !skipUnavailable { throw error } }
        }
        if grants != (values[index].additionalPermissions ?? []) { values[index].additionalPermissions=grants;try persist(values) }
        return leases
    }
    public func forget(_ id: UUID) throws { try persist(repositories.filter { $0.id != id }) }
}

/// A bookmark remains app-private; Finder receives only WorkingComparisonMarkSnapshot.
/// Use on the app's main actor. Each operation reloads storage so an old token
/// cannot consume a newer mark, even when another store instance has changed it.
public final class WorkingComparisonMarkStore {
    private struct Record: Codable {
        var snapshot: WorkingComparisonMarkSnapshot
        var bookmark: Data
        var relativePath: String
    }
    private struct Envelope: Codable { var mark: Record? }
    public let storageURL: URL
    private let provider: any RepositoryBookmarkProvider
    public init(storageURL: URL, provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) {
        self.storageURL = storageURL; self.provider = provider
    }
    public static var defaultStorageURL: URL {
        RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("comparison-mark.json")
    }
    private func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        return try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: storageURL)).mark
    }
    private func persist(_ mark: Record?) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Envelope(mark: mark)).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
    public func snapshot() throws -> WorkingComparisonMarkSnapshot? { try read()?.snapshot }
    @discardableResult public func remember(file: URL, permission: RepositoryAccessLease, requireSecurityScope: Bool = false) throws -> WorkingComparisonMarkSnapshot {
        guard !requireSecurityScope || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let file = file.standardizedFileURL, grant = permission.url.standardizedFileURL
        guard file.isFileURL, !file.path.contains("\0"), permission.contains(file),
              file.path == grant.path || file.path.hasPrefix(grant.path == "/" ? "/" : grant.path + "/") else { throw RevisionComparisonFailure.selection }
        let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw RevisionComparisonFailure.selection }
        let relative = file.path == grant.path ? "" : String(file.path.dropFirst(grant.path == "/" ? 1 : grant.path.count + 1))
        let snapshot = WorkingComparisonMarkSnapshot(id: UUID(), path: file.path)
        try persist(Record(snapshot: snapshot, bookmark: try provider.create(for: grant), relativePath: relative))
        return snapshot
    }
    public func acquire(requireSecurityScope: Bool = false) throws -> WorkingComparisonAccess {
        guard var mark = try read() else { throw RepositoryAccessFailure.unknownRepository }
        let resolved = try provider.resolve(mark.bookmark)
        let lease = RepositoryAccessLease(url: resolved.url, provider: provider)
        guard !requireSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let path = mark.relativePath
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw RevisionComparisonFailure.selection }
        let file = path.isEmpty ? lease.url : lease.url.appendingPathComponent(path)
        guard lease.contains(file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw RevisionComparisonFailure.selection }
        if resolved.stale { mark.bookmark = try provider.create(for: resolved.url) }
        mark.snapshot.path = file.standardizedFileURL.path
        try persist(mark)
        return WorkingComparisonAccess(mark: mark.snapshot, file: file, permission: lease)
    }
    /// Call after the comparison handoff succeeds. A failed read/authorization
    /// leaves the mark available for retry; a newer mark survives an older use.
    @discardableResult public func consume(_ id: UUID) throws -> Bool {
        guard try read()?.snapshot.id == id else { return false }
        try persist(nil); return true
    }
    public func clear() throws { try persist(nil) }
}

public struct WorkingComparisonAccess {
    public let mark: WorkingComparisonMarkSnapshot
    public let file: URL
    public let permission: RepositoryAccessLease
}

/// A direct two-file comparison retains both grants independently of a repository.
public struct WorkingFilePairAccess {
    public let comparison: WorkingFileComparison
    public let permissions: [RepositoryAccessLease]
    public static func prepare(paths: [URL], requireSecurityScope: Bool,
                               acquire: (URL) throws -> RepositoryAccessLease?) throws -> Self? {
        guard paths.count == 2, paths[0].standardizedFileURL != paths[1].standardizedFileURL else {
            throw RevisionComparisonFailure.selection
        }
        let comparison = try WorkingFileComparison(base: paths[0], destination: paths[1])
        var permissions: [RepositoryAccessLease] = []
        for file in [comparison.base, comparison.destination] {
            guard let permission = try acquire(file) else { return nil }
            guard permission.contains(file), !requireSecurityScope || permission.hasSecurityScope else {
                throw RepositoryAccessFailure.securityScopeUnavailable
            }
            permissions.append(permission)
        }
        // Read only after both grants have been acquired and checked.
        _ = try comparison.read()
        return Self(comparison: comparison, permissions: permissions)
    }
}

public struct RepositoryMetadataAccessRequirement: Equatable, Sendable {
    public enum Kind: String, Sendable { case gitDirectory, commonDirectory, objectDirectory }
    public let folder: URL
    public let kind: Kind
    public var explanation: String {
        switch kind {
        case .gitDirectory: return "This working folder stores Git metadata in another folder."
        case .commonDirectory: return "This linked worktree shares Git metadata outside its working folder."
        case .objectDirectory: return "This repository reads Git objects from another folder."
        }
    }
}
public enum RepositoryMetadataAccessFailure: LocalizedError {
    case invalid(URL), tooManyDependencies
    public var errorDescription: String? {
        switch self {
        case .invalid(let file): return "Could not read a valid Git metadata path from " + file.path
        case .tooManyDependencies: return "This repository has too many linked metadata or object-store folders."
        }
    }
}
/// Discover permission needs before launching Git. Read only folders already
/// covered by live grants; each newly authorized folder reveals the next layer.
public enum RepositoryMetadataAccess {
    /// Settings can open globally without a configured Git executable. Find a
    /// repository marker first, using only folders available to the caller.
    public static func settingsRepository(at location: URL, permissions: [RepositoryAccessLease], requireSecurityScope: Bool, cancellation: OperationCancellation? = nil) throws -> URL? {
        let folders = permissions.flatMap { $0.permittedFolders(requireSecurityScope: requireSecurityScope) }
        var cursor = location.standardizedFileURL
        for _ in 0..<256 {
            try cancellation?.check()
            guard !requireSecurityScope || folders.contains(where: { RepositoryAccessLease.pathIsContained(cursor, by: $0) }) else { return nil }
            let manager = FileManager.default
            if (try? manager.attributesOfItem(atPath: cursor.appendingPathComponent(".git").path)) != nil ||
                manager.fileExists(atPath: cursor.appendingPathComponent("HEAD").path) && manager.fileExists(atPath: cursor.appendingPathComponent("objects").path) { return cursor }
            if cursor.path == "/" || cursor.path.isEmpty { return nil }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }; cursor = parent
        }
        throw RepositoryMetadataAccessFailure.tooManyDependencies
    }
    public static func next(at location: URL, permissions: [RepositoryAccessLease], requireSecurityScope: Bool = true, cancellation: OperationCancellation? = nil) throws -> RepositoryMetadataAccessRequirement? {
        try next(at: location, authorizedFolders: permissions.flatMap {$0.permittedFolders(requireSecurityScope:requireSecurityScope)}, cancellation: cancellation)
    }
    public static func next(at location: URL, authorizedFolders: [URL], cancellation: OperationCancellation? = nil) throws -> RepositoryMetadataAccessRequirement? {
        let manager = FileManager.default
        func allowed(_ url: URL) -> Bool { authorizedFolders.contains { RepositoryAccessLease.pathIsContained(url, by: $0) } }
        func read(_ file: URL) throws -> String? {
            try cancellation?.check()
            guard manager.fileExists(atPath: file.path) else { return nil }
            let attributes = try manager.attributesOfItem(atPath: file.resolvingSymlinksInPath().path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw RepositoryMetadataAccessFailure.invalid(file) }
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw RepositoryMetadataAccessFailure.invalid(file) }
            return text
        }
        func trimEOL(_ text: String) -> String { var bytes = Array(text.utf8); while bytes.last == 10 || bytes.last == 13 { bytes.removeLast() }; return String(decoding: bytes, as: UTF8.self) }
        func path(_ text: String, relativeTo base: URL, source: URL, trimLineEnding: Bool = true) throws -> URL {
            let value = trimLineEnding ? trimEOL(text) : text
            guard !value.isEmpty, !value.utf8.contains(0) else { throw RepositoryMetadataAccessFailure.invalid(source) }
            return (value.hasPrefix("/") ? URL(fileURLWithPath: value) : base.appendingPathComponent(value)).standardizedFileURL.resolvingSymlinksInPath()
        }
        func missingFileGrant(_ file: URL, kind: RepositoryMetadataAccessRequirement.Kind) -> RepositoryMetadataAccessRequirement? {
            allowed(file) ? nil : RepositoryMetadataAccessRequirement(folder: file.resolvingSymlinksInPath().deletingLastPathComponent(), kind: kind)
        }
        var cursor = location.standardizedFileURL, gitDirectory: URL?
        for _ in 0..<256 {
            try cancellation?.check()
            guard allowed(cursor) else { break }
            let marker = cursor.appendingPathComponent(".git")
            if let attributes = try? manager.attributesOfItem(atPath: marker.path) {
                let kind = attributes[.type] as? FileAttributeType
                if kind == .typeDirectory { gitDirectory = marker; break }
                if kind == .typeSymbolicLink {
                    let target = marker.resolvingSymlinksInPath()
                    if !allowed(target) { return RepositoryMetadataAccessRequirement(folder: target.deletingLastPathComponent(), kind: .gitDirectory) }
                    var directory: ObjCBool = false
                    if manager.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue { gitDirectory = target; break }
                }
                if let requirement = missingFileGrant(marker, kind: .gitDirectory) { return requirement }
                guard let text = try read(marker), text.hasPrefix("gitdir: ") else { throw RepositoryMetadataAccessFailure.invalid(marker) }
                gitDirectory = try path(String(text.dropFirst(8)), relativeTo: cursor, source: marker); break
            }
            if manager.fileExists(atPath: cursor.appendingPathComponent("HEAD").path), manager.fileExists(atPath: cursor.appendingPathComponent("objects").path) { gitDirectory = cursor; break }
            let parent = cursor.deletingLastPathComponent(); if parent.path == cursor.path { break }; cursor = parent
        }
        guard let gitDirectory else { return nil }
        if !allowed(gitDirectory) { return RepositoryMetadataAccessRequirement(folder: gitDirectory, kind: .gitDirectory) }
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        if let requirement = missingFileGrant(commonFile, kind: .commonDirectory) { return requirement }
        let common: URL
        if let text = try read(commonFile) { common = try path(text, relativeTo: gitDirectory, source: commonFile) }
        else { common = gitDirectory }
        if !allowed(common) { return RepositoryMetadataAccessRequirement(folder: common, kind: .commonDirectory) }
        var pending = [common.appendingPathComponent("objects")], visited = Set<String>()
        while !pending.isEmpty {
            try cancellation?.check()
            let objects = pending.removeFirst().standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(objects.path).inserted else { continue }
            guard visited.count <= 64 else { throw RepositoryMetadataAccessFailure.tooManyDependencies }
            if !allowed(objects) { return RepositoryMetadataAccessRequirement(folder: objects, kind: .objectDirectory) }
            let file = objects.appendingPathComponent("info/alternates")
            if let requirement = missingFileGrant(file, kind: .objectDirectory) { return requirement }
            guard let text = try read(file) else { continue }
            for raw in text.utf8.split(separator: 10, omittingEmptySubsequences: true) {
                let line = String(decoding: raw.last == 13 ? raw.dropLast() : raw, as: UTF8.self)
                if line.isEmpty { continue }
                let decoded = try decodeAlternate(line, source: file)
                pending.append(try path(decoded, relativeTo: objects, source: file, trimLineEnding: false))
            }
        }
        return nil
    }
    private static func decodeAlternate(_ line: String, source: URL) throws -> String {
        guard line.hasPrefix("\"") else { return line }
        let input = Array(line.utf8); var output: [UInt8] = [], index = 1
        while index < input.count {
            let byte = input[index]; index += 1
            if byte == 34 {
                guard index == input.count, let result = String(bytes: output, encoding: .utf8) else { throw RepositoryMetadataAccessFailure.invalid(source) }
                return result
            }
            if byte != 92 { output.append(byte); continue }
            guard index < input.count else { throw RepositoryMetadataAccessFailure.invalid(source) }
            let escape = input[index]; index += 1
            if (48...55).contains(escape) {
                var value = Int(escape - 48), count = 1
                while count < 3, index < input.count, (48...55).contains(input[index]) { value = value * 8 + Int(input[index] - 48); index += 1; count += 1 }
                guard value < 256 else { throw RepositoryMetadataAccessFailure.invalid(source) }; output.append(UInt8(value))
            } else {
                let escaped: [UInt8: UInt8] = [34:34,92:92,97:7,98:8,116:9,110:10,118:11,102:12,114:13]
                guard let value = escaped[escape] else { throw RepositoryMetadataAccessFailure.invalid(source) }; output.append(value)
            }
        }
        throw RepositoryMetadataAccessFailure.invalid(source)
    }
}
