import Foundation
import Darwin

public struct GitChangelists: Codable, Equatable, Sendable {
    public static let ignored = "ignore-on-commit"
    public var assignments: [String: String]
    public init(assignments: [String: String] = [:]) { self.assignments = assignments }
    public var names: [String] { Set(assignments.values).sorted() }
    public func ignores(_ path: String) -> Bool { assignments[path] == Self.ignored }
}

private struct ChangelistDocument: Codable {
    var version = 1
    let assignments: [String: String]
}

extension GitRepository {
    public func changelists(cancellation: OperationCancellation? = nil) throws -> GitChangelists {
        try cancellation?.check()
        return try readChangelists(at: changelistLocation("turtlegit-changelists.json", cancellation: cancellation), cancellation: cancellation)
    }
    /// Mutations reload under a worktree-local lock, preserving other processes'
    /// assignments. JSON retains Unicode and literal newline filenames.
    public func assignChangelist(paths: [String], name: String?) throws -> GitChangelists {
        guard !paths.isEmpty, name.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true else {
            throw GitFailure(arguments: ["changelist"], code: 1, message: "Select paths and enter a nonempty changelist name.")
        }
        for path in paths { _ = try restoreLocation(path) }
        return try mutateChangelists { lists in
            for path in Set(paths) { lists.assignments[path] = name }
        }
    }
    /// Match upstream's successful-commit pruning: retain unchecked/restored
    /// paths within the shown directory scope, and leave outside assignments alone.
    /// A file-only commit scope does not prune changelists.
    public func pruneChangelists(retaining: Set<String>, scope: [String] = []) throws -> GitChangelists {
        var directories: [String] = []
        for path in scope {
            let url = try restoreLocation(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return try changelists() }
            directories.append(path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
        return try mutateChangelists { lists in
            lists.assignments = lists.assignments.filter { path, _ in
                retaining.contains(path) || (!directories.isEmpty && !directories.contains { path == $0 || path.hasPrefix($0 + "/") })
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
            let document = try JSONDecoder().decode(ChangelistDocument.self, from: data)
            guard document.version == 1 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Unsupported changelist file version.") }
            lists = GitChangelists(assignments: document.assignments)
        } else if let data = try regularChangelistData(changelistLocation("tgitchangelist", cancellation: cancellation)) {
            let text: String?
            if data.starts(with: [255, 254]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
            else if data.starts(with: [254, 255]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
            else { text = String(data: data, encoding: .utf8) }
            guard let text else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not decode the TortoiseGit changelist file as UTF-8 or BOM-marked UTF-16.") }
            var mapping: [String: String] = [:], name = GitChangelists.ignored
            for raw in (text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text).components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if line.hasPrefix("<"), line.hasSuffix(">") { name = String(line.dropFirst().dropLast()) }
                else { mapping[line] = name }
            }
            lists = GitChangelists(assignments: mapping)
        } else { lists = GitChangelists() }
        for (path, name) in lists.assignments {
            _ = try restoreLocation(path)
            guard !name.isEmpty, !name.contains("\0") else { throw GitFailure(arguments: ["changelist"], code: 1, message: "The changelist file contains an invalid name.") }
        }
        return lists
    }
    private func mutateChangelists(_ update: (inout GitChangelists) throws -> Void) throws -> GitChangelists {
        let url = try changelistLocation("turtlegit-changelists.json"), lock = URL(fileURLWithPath: url.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not lock the changelist file: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? FileManager.default.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var lists = try readChangelists(at: url)
        try update(&lists)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try handle.write(contentsOf: encoder.encode(ChangelistDocument(assignments: lists.assignments))); try handle.close()
        guard Darwin.rename(lock.path, url.path) == 0 else { throw GitFailure(arguments: ["changelist"], code: 1, message: "Could not save the changelist file: " + String(cString: strerror(errno))) }
        ownsLock = false
        return lists
    }
}
