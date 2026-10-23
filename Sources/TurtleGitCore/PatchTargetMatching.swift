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
    public static func initialStripCount(_ bytes: Data, textEncodingPolicy: MergeTextEncodingPolicy = .init(preferUTF8: true), cancellation: OperationCancellation? = nil) -> Int {
        guard cancellation?.isCancelled != true else { return 0 }
        // Header punctuation is text, not byte-LF framing in a UTF-16/32 file.
        // Keep the original bytes for Git binary/opaque patches; the decoder
        // never serializes another patch or supplies changed filesystem bytes.
        let headerBytes: Data
        if bytes.count <= 64 * 1024 * 1024, let encoding = ComparisonTextEncoding.detectMerge(bytes, preferUTF8: textEncodingPolicy.preferUTF8, legacyEncoding: textEncodingPolicy.legacyEncoding),
           let text = encoding.decode(bytes), !text.contains("\0") {
            headerBytes = Data(text.utf8)
        } else { headerBytes = bytes }
        for line in headerBytes.split(separator: 10) {
            guard cancellation?.isCancelled != true else { return 0 }
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
    public func patchTargetPaths(_ bytes: Data, stripCount: Int, textEncodingPolicy: MergeTextEncodingPolicy = .init(preferUTF8: true), cancellation: OperationCancellation? = nil) throws -> [Data] {
        try cancellation?.check()
        guard stripCount >= 0 else { throw WorkingTreePatchFailure.stripCount }
        var decodedFailure: Error?
        // CheckPatchPath is a text-header query, independent of the eventual
        // application engine. Git numstat can preserve an ACP byte name or pick
        // the new header of a plain pair even in reverse; source paths are the
        // decoded literal preimages. Opaque/source-incompatible syntax retains
        // the original Git metadata reader below.
        if SourceTextPatch.recognizedTextEligibility(bytes: bytes, textEncodingPolicy: textEncodingPolicy) {
            do {
                let patch = try SourceTextPatch.parse(bytes: bytes, textEncodingPolicy: textEncodingPolicy, cancellation: cancellation).strippingPaths(stripCount)
                return try patch.files.compactMap { file in
                    try cancellation?.check()
                    return file.oldPathBytes ?? file.newPathBytes
                }
            } catch SourceTextPatchFailure.opaque { }
            catch { try cancellation?.check(); decodedFailure = error }
        }
        do {
            return try withPatchTarget(bytes, directoryMode: true, isGitWorkingTree: false, cancellation: cancellation) { file, execute in
                try WorkingTreePatchReview.parseFiles(execute(["apply", "-p\(stripCount)", "--reverse", "--numstat", "-z", "--", file.path]).stdout).reversed().map(\.pathBytes)
            }
        } catch {
            try cancellation?.check()
            throw decodedFailure ?? error
        }
    }
}
