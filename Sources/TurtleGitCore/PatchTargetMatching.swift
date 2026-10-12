// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// CPatch::CheckPatchPath: current directory, ancestors, immediate children,
/// then ancestor directory matches for patches consisting of newly added files.
public enum PatchTargetMatching {
    public static func suggestion(start: URL, paths: [Data], boundary: URL? = nil, cancellation: OperationCancellation? = nil) -> URL? {
        guard !paths.isEmpty, start.isFileURL else { return nil }
        let manager = FileManager.default, threshold = paths.count / 3
        let names = paths.compactMap { bytes -> String? in
            guard let name = String(data: bytes, encoding: .utf8), !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"),
                  !name.components(separatedBy: "/").contains(where: { $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { return nil }
            return name
        }
        let start = start.standardizedFileURL
        func allowed(_ directory: URL) -> Bool {
            guard cancellation?.isCancelled != true else { return false }
            return boundary.map { RepositoryAccessLease.pathIsContained(directory, by: $0) } ?? true
        }
        func matches(_ directory: URL, parentsOnly: Bool = false) -> Bool {
            guard allowed(directory) else { return false }
            let count = names.filter { name in
                let file = directory.appendingPathComponent(name).standardizedFileURL
                let location = parentsOnly ? file.deletingLastPathComponent() : file
                guard RepositoryAccessLease.pathIsContained(location, by: directory) else { return false }
                return (try? manager.attributesOfItem(atPath: location.path)) != nil
            }.count
            return count > threshold
        }
        guard allowed(start) else { return nil }
        if matches(start) { return nil }
        var ancestors: [URL] = [], cursor = start
        while cursor.path != "/" {
            cursor = cursor.deletingLastPathComponent()
            guard allowed(cursor) else { break }
            ancestors.append(cursor)
            if matches(cursor) { return cursor }
        }
        // Enumeration is deliberately one level, as in CDirFileEnum. Sorting
        // gives macOS a repeatable choice when several subfolders match.
        let children = (try? manager.contentsOfDirectory(at: start, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for directory in children.sorted(by: { $0.path < $1.path }) {
            guard directory.lastPathComponent.caseInsensitiveCompare(".git") != .orderedSame,
                  let facts = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  facts.isDirectory == true, facts.isSymbolicLink != true else { continue }
            let candidate = start.appendingPathComponent(directory.lastPathComponent).standardizedFileURL
            if matches(candidate) { return candidate }
        }
        return ancestors.first { matches($0, parentsOnly: true) }
    }
    /// Upstream removes Git's a/ and b/ prefixes, but leaves plain patch paths.
    public static func initialStripCount(_ bytes: Data) -> Int {
        for line in bytes.split(separator: 10) {
            if line.starts(with: Data("diff --git a/".utf8)) || line.starts(with: Data("diff --git \"a/".utf8)) { return 1 }
            if line.starts(with: Data("@@".utf8)) { break }
            guard line.starts(with: Data("--- ".utf8)) || line.starts(with: Data("+++ ".utf8)) else { continue }
            let path = line.dropFirst(4)
            if path.starts(with: Data("a/".utf8)) || path.starts(with: Data("b/".utf8)) || path.starts(with: Data("\"a/".utf8)) || path.starts(with: Data("\"b/".utf8)) { return 1 }
        }
        return 0
    }
}

extension GitRepository {
    /// Reverse statistics identify the preimage of renames without interpreting
    /// human-readable quoted paths. This query does not apply any patch.
    public func patchTargetPaths(_ bytes: Data, stripCount: Int, cancellation: OperationCancellation? = nil) throws -> [Data] {
        guard stripCount >= 0 else { throw WorkingTreePatchFailure.stripCount }
        return try withPatchTarget(bytes, directoryMode: true, isGitWorkingTree: false, cancellation: cancellation) { file, execute in
            try WorkingTreePatchReview.parseFiles(execute(["apply", "-p\(stripCount)", "--reverse", "--numstat", "-z", "--", file.path]).stdout).reversed().map(\.pathBytes)
        }
    }
}
