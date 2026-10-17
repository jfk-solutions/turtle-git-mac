import Foundation
import Darwin

public struct GitChangelists: Codable, Equatable, Sendable {
    public static let ignored = "ignore-on-commit"
    public var exactAssignments: [GitReferenceName: GitReferenceName]
    public init(assignments: [String: String] = [:]) {
        exactAssignments = Dictionary(uniqueKeysWithValues: assignments.map { (GitReferenceName($0.key), GitReferenceName($0.value)) })
    }
    public init(exactAssignments: [GitReferenceName: GitReferenceName]) { self.exactAssignments = exactAssignments }
    /// Compatibility projection for old callers. New file/name consumers must
    /// use exactAssignments/name(for:); Swift String keys can merge Git names.
    public var assignments: [String: String] {
        Dictionary(exactAssignments.map { ($0.key.rawValue, $0.value.rawValue) }, uniquingKeysWith: { _, last in last })
    }
    public var nameIdentities: [GitReferenceName] {
        Set(exactAssignments.values).sorted { $0.rawValue.utf16.lexicographicallyPrecedes($1.rawValue.utf16) }
    }
    public var names: [String] { nameIdentities.map(\.rawValue) }
    public func name(for path: String) -> String? { exactAssignments[GitReferenceName(path)]?.rawValue }
    public func ignores(_ path: String) -> Bool { exactAssignments[GitReferenceName(path)] == GitReferenceName(Self.ignored) }
    public init(from decoder: Decoder) throws {
        self = try ChangelistDocument(from: decoder).lists()
    }
    public func encode(to encoder: Encoder) throws { try ChangelistDocument(self).encode(to: encoder) }
}

/// Arrays preserve byte-distinct JSON names across Foundation versions; JSON
/// object keys decoded into Swift dictionaries would normalize their identity.
private struct ChangelistDocument: Codable {
    struct Row: Codable { let path: String; let name: String }
    let version: Int
    let assignments: [Row]
    init(_ lists: GitChangelists) {
        version = 2
        assignments = lists.exactAssignments.keys.sorted { $0.rawValue.utf16.lexicographicallyPrecedes($1.rawValue.utf16) }.map {
            Row(path: $0.rawValue, name: lists.exactAssignments[$0]!.rawValue)
        }
    }
    func lists() throws -> GitChangelists {
        guard version == 2 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Unsupported changelist file version.") }
        var result: [GitReferenceName: GitReferenceName] = [:]
        for row in assignments {
            guard result.updateValue(GitReferenceName(row.name), forKey: GitReferenceName(row.path)) == nil else {
                throw GitFailure(arguments: ["changelist"], code: 1, message: "The changelist file contains a duplicate path.")
            }
        }
        return GitChangelists(exactAssignments: result)
    }
}

extension GitRepository {
    public func changelists(cancellation: OperationCancellation? = nil) throws -> GitChangelists {
        try cancellation?.check()
        return try readChangelists(at: changelistLocation("turtlegit-changelists.json", cancellation: cancellation), cancellation: cancellation)
    }
    /// Mutations reload under a worktree-local lock, preserving other processes'
    /// assignments. JSON retains Unicode and literal newline filenames.
    public func assignChangelist(paths: [String], name: String?, cancellation: OperationCancellation? = nil) throws -> GitChangelists {
        try cancellation?.check()
        guard !paths.isEmpty, name.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true else {
            throw GitFailure(arguments: ["changelist"], code: 1, message: "Select paths and enter a nonempty changelist name.")
        }
        for path in paths { try cancellation?.check(); _ = try restoreLocation(path) }
        return try mutateChangelists(cancellation: cancellation) { lists in
            for path in Set(paths.map { GitReferenceName($0) }) { lists.exactAssignments[path] = name.map { GitReferenceName($0) } }
        }
    }
    /// Match upstream's successful-commit pruning: retain unchecked/restored
    /// paths within the shown directory scope, and leave outside assignments alone.
    /// A file-only commit scope does not prune changelists.
    public func pruneChangelists(retaining: Set<String>, scope: [String] = []) throws -> GitChangelists {
        try pruneChangelists(retainingPathNames: Set(retaining.map { GitReferenceName($0) }), scope: scope)
    }
    public func pruneChangelists(retainingPathNames: Set<GitReferenceName>, scope: [String] = [], cancellation: OperationCancellation? = nil) throws -> GitChangelists {
        try cancellation?.check()
        var directories: [String] = []
        for path in scope {
            try cancellation?.check()
            let url = try restoreLocation(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return try changelists(cancellation: cancellation) }
            directories.append(path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
        return try mutateChangelists(cancellation: cancellation) { lists in
            lists.exactAssignments = lists.exactAssignments.filter { path, _ in
                retainingPathNames.contains(path) || (!directories.isEmpty && !directories.contains {
                    GitReferenceName.equal(path.rawValue, $0) || path.rawValue.utf8.starts(with: ($0 + "/").utf8)
                })
            }
        }
    }
    private func changelistLocation(_ name: String, cancellation: OperationCancellation? = nil) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    private func regularChangelistData(_ url: URL) throws -> Data? {
        let manager = FileManager.default
        do {
            let attrs = try manager.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw GitFailure(arguments: ["changelist"], code: 1, message: "The changelist file is not a regular file: " + url.path)
            }
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }
    private func readChangelists(at url: URL, cancellation: OperationCancellation? = nil) throws -> GitChangelists {
        let lists: GitChangelists
        if let data = try regularChangelistData(url) {
            struct Header: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).version
            if version == 2 { lists = try JSONDecoder().decode(ChangelistDocument.self, from: data).lists() }
            else if version == 1 {
                // Keep legacy NSString keys while enumerating. Do not bridge this
                // object to [String: Any], which merges canonical path spellings.
                guard let document = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                      let mapping = document.object(forKey: "assignments") as? NSDictionary else {
                    throw GitFailure(arguments: ["changelist"], code: 1, message: "Invalid legacy changelist assignments.")
                }
                var exact: [GitReferenceName: GitReferenceName] = [:]
                for (path, name) in mapping {
                    guard let path = path as? String, let name = name as? String else {
                        throw GitFailure(arguments: ["changelist"], code: 1, message: "Invalid legacy changelist assignment.")
                    }
                    exact[GitReferenceName(path)] = GitReferenceName(name)
                }
                lists = GitChangelists(exactAssignments: exact)
            } else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Unsupported changelist file version.") }
        } else if let data = try regularChangelistData(changelistLocation("tgitchangelist", cancellation: cancellation)) {
            let text: String?
            if data.starts(with: [255, 254]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
            else if data.starts(with: [254, 255]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
            else { text = String(data: data, encoding: .utf8) }
            guard let text else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not decode the TortoiseGit changelist file as UTF-8 or BOM-marked UTF-16.") }
            var mapping: [GitReferenceName: GitReferenceName] = [:], name = GitChangelists.ignored
            for raw in (text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text).components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if line.hasPrefix("<"), line.hasSuffix(">") { name = String(line.dropFirst().dropLast()) }
                else { mapping[GitReferenceName(line)] = GitReferenceName(name) }
            }
            lists = GitChangelists(exactAssignments: mapping)
        } else { lists = GitChangelists() }
        for (path, name) in lists.exactAssignments {
            try cancellation?.check()
            _ = try restoreLocation(path.rawValue)
            guard !name.rawValue.isEmpty, !name.rawValue.contains("\0") else { throw GitFailure(arguments: ["changelist"], code: 1, message: "The changelist file contains an invalid name.") }
        }
        return lists
    }
    private func mutateChangelists(cancellation: OperationCancellation? = nil, _ update: (inout GitChangelists) throws -> Void) throws -> GitChangelists {
        try cancellation?.check()
        let url = try changelistLocation("turtlegit-changelists.json", cancellation: cancellation), lock = URL(fileURLWithPath: url.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not lock the changelist file: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? FileManager.default.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var lists = try readChangelists(at: url, cancellation: cancellation)
        try update(&lists); try cancellation?.check()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try handle.write(contentsOf: encoder.encode(ChangelistDocument(lists))); try handle.close()
        try cancellation?.check()
        guard Darwin.rename(lock.path, url.path) == 0 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not save the changelist file: " + String(cString: strerror(errno))) }
        ownsLock = false
        return lists
    }
}
