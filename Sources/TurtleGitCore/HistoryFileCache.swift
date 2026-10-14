// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// Native persistent equivalent of CLogCache's completed diff-file records.
/// Ref labels, notes, walk order and working-tree state never enter this cache.
public struct HistoryFileCache: Sendable {
    public let root: URL
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurtleGit/HistoryFiles-v1", isDirectory: true)
    }
    public init(root: URL = Self.defaultRoot) { self.root = root }
    /// Clear only this cache's record namespace; never remove the directory,
    /// follow symlinks, or touch repository files and other cache payloads.
    private func ownedRecordFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        try validRoot(create:false)
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { file in
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", stem.utf8.count == 64,
                  stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
            let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
            return attributes[.type] as? FileAttributeType == .typeRegular
        }
    }
    public func savedRecordCount() throws -> Int { try ownedRecordFiles().count }
    public func clearSavedRecords() throws {
        for file in try ownedRecordFiles() { try FileManager.default.removeItem(at:file) }
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
    private func validRoot(create: Bool) throws {
        let manager = FileManager.default
        if create && !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try manager.attributesOfItem(atPath: root.path)
        guard values[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadInvalidFileName) }
        if create { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    }
    func read(_ key: String) -> Record? {
        do {
            try validRoot(create: false)
            let file = url(key), attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1024 * 1024 else { return nil }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            return record.key == key ? record : nil
        } catch { return nil }
    }
    func write(_ record: Record) {
        do {
            try validRoot(create: true)
            let data = try JSONEncoder().encode(record)
            guard data.count <= 8 * 1024 * 1024 else { return }
            let file = url(record.key)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try trim()
        } catch { /* Optional cache failure must not change a Git read's result. */ }
    }
    private func trim() throws {
        let manager = FileManager.default
        let items = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        var records: [(URL, Date, Int)] = []
        for item in items where item.pathExtension == "json" {
            let value = try item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            if value.isRegularFile == true { records.append((item, value.contentModificationDate ?? .distantPast, value.fileSize ?? 0)) }
        }
        var bytes = records.reduce(0) { $0 + $1.2 }, count = records.count
        for item in records.sorted(by: { $0.1 < $1.1 }) {
            if count <= 1024 && bytes <= 128 * 1024 * 1024 { break }
            try manager.removeItem(at: item.0); count -= 1; bytes -= item.2
        }
    }
    public func clear() throws {
        if !FileManager.default.fileExists(atPath: root.path) { return }
        try validRoot(create: false)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            try FileManager.default.removeItem(at: file)
        }
    }
}

extension GitRepository {
    /// Hash the inputs which can change the interpretation of a commit's trees.
    /// Attributes are fingerprinted using the cached paths on lookup and the new
    /// paths after a miss, including every parent directory and renamed source.
    func historyFileCacheContext(_ entry: LogEntry, cancellation: OperationCancellation?) throws -> (key: String, context: String, infoAttributes: URL, globalAttributes: URL) {
        let hashes = [entry.hash] + (entry.parents.first.map { [$0] } ?? [])
        guard hashes.allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw RevisionComparisonFailure.range }
        let metadata = try run(["rev-parse", "--git-path", "info/attributes", "--git-path", "index", "--end-of-options"] + hashes.map { $0 + "^{tree}" }, cancellation: cancellation).text
        let lines = metadata.split(separator: "\n").map(String.init)
        guard lines.count == hashes.count + 2, lines.dropFirst(2).allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw RevisionComparisonFailure.range }
        let infoPath = lines.first!
        let info = infoPath.hasPrefix("/") ? URL(fileURLWithPath: infoPath) : root.appendingPathComponent(infoPath)
        let config = try run(["config", "--includes", "--null", "--list"], cancellation: cancellation).stdout
        // Git's default attributes file is XDG_CONFIG_HOME/git/attributes.
        let configured = try run(["config", "--path", "--get", "core.attributesfile"], successfulExitCodes: 0...1, cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let global = configured.isEmpty ? xdg.appendingPathComponent("git/attributes") : (configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : root.appendingPathComponent(configured))
        let engine = try FileManager.default.attributesOfItem(atPath: executable.path)
        let key = HistoryFileCache.digest([root.resolvingSymlinksInPath().path, executable.path] + hashes)
        let indexPath = lines[1]
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let indexDigest: String
        do { indexDigest = HistoryFileCache.digest(try Data(contentsOf: index)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { indexDigest = "absent" }
        let diffEnvironment = ["GIT_DIFF_OPTS", "GIT_ATTR_SOURCE", "GIT_ATTR_NOSYSTEM"].map { $0 + "=" + (environment[$0] ?? "") }
        let context = HistoryFileCache.digest(Array(lines.dropFirst(2)) + ["diff-detection-v1=" + diffDetection.historyArguments.joined(separator: ","), HistoryFileCache.digest(config), indexDigest, String(describing: engine[.modificationDate]), String(describing: engine[.size])] + diffEnvironment)
        return (key, context, info, global)
    }
    func historyFileAttributesFingerprint(_ files: [CommitFile], info: URL, global: URL, cancellation: OperationCancellation?) throws -> String {
        var paths = Set([root.appendingPathComponent(".gitattributes"), info, global])
        for file in files {
            for path in [file.path] + (file.oldPath.map { [$0] } ?? []) {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw RevisionComparisonFailure.range }
                var directory = root.appendingPathComponent(path).deletingLastPathComponent()
                while directory != root && directory.path.hasPrefix(root.path + "/") {
                    paths.insert(directory.appendingPathComponent(".gitattributes")); directory.deleteLastPathComponent()
                }
            }
        }
        var fingerprints: [String] = []
        for path in paths.sorted(by: { $0.path < $1.path }) {
            try cancellation?.check()
            fingerprints.append(path.path)
            do { fingerprints.append(HistoryFileCache.digest(try Data(contentsOf: path))) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { fingerprints.append("absent") }
        }
        return HistoryFileCache.digest(fingerprints)
    }
}
