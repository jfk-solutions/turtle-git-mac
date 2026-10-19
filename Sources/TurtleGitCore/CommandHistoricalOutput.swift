// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// A command's bytes stay private until its native owner accepts publication.
/// Directory-relative publication keeps a renamed parent from redirecting output.
public final class PreparedCommandFile: @unchecked Sendable {
    private let lock = NSLock()
    private var parent: Int32
    private var temporary: String?
    private let destination: String
    private init(parent: Int32, temporary: String, destination: String) {
        self.parent = parent; self.temporary = temporary; self.destination = destination
    }
    public static func prepare(_ bytes: Data, to file: URL, cancellation: OperationCancellation) throws -> PreparedCommandFile {
        try cancellation.check()
        let name = file.lastPathComponent
        guard file.isFileURL, file.path.hasPrefix("/"), !name.isEmpty, name != "/", name != ".", name != "..", !name.contains("\0") else {
            throw PrimaryCommandInvocation.Failure("Choose a regular output filename.")
        }
        let directory = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = ".turtlegit-command-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { let failure = errno; Darwin.close(directory); throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let prepared = PreparedCommandFile(parent: directory, temporary: temporary, destination: name)
        do {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try cancellation.check()
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(65536, buffer.count - offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
            try cancellation.check()
            return prepared
        } catch { prepared.discard(); throw error }
    }
    /// Call at the owner's final serialized acceptance boundary. Once this
    /// atomic rename starts, publication has been accepted and cannot be undone.
    public func publish(cancellation: OperationCancellation) throws {
        lock.lock(); defer { lock.unlock() }
        try cancellation.check()
        guard parent >= 0, let temporary else { throw PrimaryCommandInvocation.Failure("This output has already been published or discarded.") }
        guard renameat(parent, temporary, parent, destination) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.temporary = nil; Darwin.close(parent); parent = -1
    }
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        guard parent >= 0 else { return }
        if let temporary { unlinkat(parent, temporary, 0) }
        temporary = nil; Darwin.close(parent); parent = -1
    }
    deinit { discard() }
}

extension GitRepository {
    /// CatCommand's blob and GetOneFile routes, with Git's filters and an exact
    /// tree lookup. Resolve mutable names once before reading or running filters.
    public func commandHistoricalFile(revision: String, path: String, cancellation: OperationCancellation, backend: GitLibGit2Configuration? = nil) throws -> Data {
        let backend = backend ?? libgit2Configuration ?? .load()
        try cancellation.check()
        guard !revision.isEmpty, !revision.hasPrefix("-"), !revision.contains("\0") else { throw RevisionComparisonFailure.range }
        if path != "." { _ = try RemovalRequest(paths: [path], keepLocal: true) }
        let object = try run(["rev-parse", "--verify", "--end-of-options", revision], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard (object.count == 40 || object.count == 64), object.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw RevisionComparisonFailure.range }
        let executor = try backend.executor(for: .getOneFile)
        if executor == nil {
            let kind = try run(["cat-file", "-t", object], cancellation: cancellation).text
            // CatCommand's disabled-backend nonblob route is Git show (commit
            // metadata and patch), unlike GetOneFile's raw-file fallback.
            let arguments = kind == "blob\n" ? ["cat-file", "-p", "--", object] : ["-c", "core.precomposeunicode=false", "show", "--end-of-options", object, "--", path]
            return try run(arguments, cancellation: cancellation).stdout
        }
        let peeled = try run(["rev-parse", "--verify", "--end-of-options", object + "^{}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let kind = try run(["cat-file", "-t", peeled], cancellation: cancellation).text
        let blob: String
        if kind == "blob\n" { blob = peeled }
        else {
            guard kind == "commit\n" || kind == "tree\n", path != "." else { throw RevisionComparisonFailure.selection }
            let records = try run(["-c", "core.precomposeunicode=false", "ls-tree", "--full-tree", "-z", peeled, "--", path], cancellation: cancellation).stdout.split(separator: 0)
            guard let entry = records.first(where: { record in
                guard let tab = record.firstIndex(of: 9) else { return false }
                return record[record.index(after: tab)...].elementsEqual(path.utf8)
            }), let tab = entry.firstIndex(of: 9) else { throw RevisionComparisonFailure.selection }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, fields[1] == "blob" else { throw RevisionComparisonFailure.selection }
            blob = String(fields[2])
        }
        return try run(["-c", "core.precomposeunicode=false", "cat-file", "--filters", "--path=" + path, blob], cancellation: cancellation, executorOverride: executor).stdout
    }
}
