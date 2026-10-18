// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// A displayed local input, never the separate merged/output target. Expected
/// bytes belong to the accepted read; observation does not authorize a write.
public struct MergeExternalSource: Sendable {
    public let id: String
    public let url: URL
    public let expectedBytes: Data
    public let expectedMissing: Bool
    public let expectedPermissions: Int?
    public init(id: String, url: URL, expectedBytes: Data, expectedMissing: Bool = false, expectedPermissions: Int? = nil) {
        self.id = id; self.url = url; self.expectedBytes = expectedBytes
        self.expectedMissing = expectedMissing; self.expectedPermissions = expectedPermissions
    }
}

public struct MergeExternalSourceObservation: Equatable, Sendable {
    fileprivate let device: UInt64, inode: UInt64, size: Int64
    fileprivate let birthSeconds: Int64, birthNanoseconds: Int64
    fileprivate let writeSeconds: Int64, writeNanoseconds: Int64
    fileprivate let mode: UInt32
    fileprivate init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev)); inode = UInt64(value.st_ino); size = value.st_size
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        writeSeconds = Int64(value.st_mtimespec.tv_sec); writeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        mode = UInt32(value.st_mode)
    }
    fileprivate static func read(_ url: URL) -> Self? {
        guard url.isFileURL, !url.path.contains("\0") else { return nil }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return Self(info)
    }
}

public struct MergeExternalSourceProbe: Sendable {
    public let observations: [String: MergeExternalSourceObservation]
    public let changed: Set<String>
    public init(observations: [String: MergeExternalSourceObservation], changed: Set<String>) {
        self.observations = observations; self.changed = changed
    }
}

public enum MergeExternalSources {
    /// Source CWorkingFile compares existing inputs' size/creation/write times.
    /// Inode/type/permissions additionally distinguish native atomic replacements.
    /// Missing inputs and failed attribute queries do not trigger this warning,
    /// as in the source. An existing input whose bytes cannot be verified is a
    /// change; save validators remain independent of either observation.
    public static func probe(_ sources: [MergeExternalSource], previous: [String: MergeExternalSourceObservation], cancellation: OperationCancellation) throws -> MergeExternalSourceProbe {
        var observations = previous, changed = Set<String>()
        for source in sources {
            try cancellation.check()
            guard let first = MergeExternalSourceObservation.read(source.url) else { continue }
            if let old = previous[source.id] {
                observations[source.id] = first
                if old != first { changed.insert(source.id) }
                continue
            }
            let supportedType = [UInt32(S_IFREG), UInt32(S_IFLNK)].contains(first.mode & UInt32(S_IFMT))
            if source.expectedMissing || first.size != source.expectedBytes.count || !supportedType ||
                source.expectedPermissions.map({ UInt32($0) != first.mode & 0o7777 }) == true {
                observations[source.id] = first; changed.insert(source.id); continue
            }
            // Pair the first attributes with the actual accepted bytes. A write
            // between document load and observer installation must not be lost.
            do {
                let current = try WorkingFileComparison.workingContent(at: source.url)
                try cancellation.check()
                guard let second = MergeExternalSourceObservation.read(source.url) else { continue }
                observations[source.id] = second
                if first != second || source.expectedMissing || current.bytes != source.expectedBytes ||
                    source.expectedPermissions.map({ $0 != current.permissions }) == true { changed.insert(source.id) }
            } catch {
                try cancellation.check()
                // Metadata still available means an existing source could no
                // longer be verified, rather than a missing/attribute-error case.
                if let current = MergeExternalSourceObservation.read(source.url) {
                    observations[source.id] = current; changed.insert(source.id)
                }
            }
        }
        try cancellation.check()
        return MergeExternalSourceProbe(observations: observations, changed: changed)
    }
}
