import Foundation

public struct ComparisonFileContent: Sendable {
    public let path: String
    public let revision: ComparisonRevision
    public let bytes: Data
    public let mode: String?
    public let permissions: Int?
    init(path: String, revision: ComparisonRevision, bytes: Data, mode: String?, permissions: Int? = nil) {
        self.path = path; self.revision = revision; self.bytes = bytes; self.mode = mode; self.permissions = permissions
    }
    public var text: String? {
        if bytes.starts(with: [0xff, 0xfe]) { return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) }
        guard !bytes.contains(0) else { return nil }
        return String(data: bytes.starts(with: [0xef, 0xbb, 0xbf]) ? bytes.dropFirst(3) : bytes, encoding: .utf8)
    }
}
public struct FileComparisonDocument: Sendable {
    public let base: ComparisonFileContent
    public let destination: ComparisonFileContent
}
/// A private, read-only regular-file copy for opening a historical blob in an
/// external application. A symlink blob is copied as target text, never followed.
public struct HistoricalFilePreview: Sendable {
    public let directory: URL
    public let file: URL
    private init(directory: URL, file: URL) { self.directory = directory; self.file = file }
    public static func create(_ content: ComparisonFileContent) throws -> HistoricalFilePreview {
        guard case .revision(let hash) = content.revision, [40, 64].contains(hash.count),
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              ["100644", "100755", "120000"].contains(content.mode ?? "") else { throw RevisionComparisonFailure.selection }
        let name = (content.path as NSString).lastPathComponent as NSString
        guard name.length > 0, ![".", ".."].contains(name as String), !content.path.utf8.contains(0) else { throw RevisionComparisonFailure.selection }
        let ext = name.pathExtension
        let filename = name.deletingPathExtension + "-" + hash.prefix(7) + (ext.isEmpty ? "" : "." + ext)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("TurtleGitHistoricalPreview-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent(filename)
            try content.bytes.write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            return HistoricalFilePreview(directory: directory, file: file)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}
public struct FileComparisonRow: Sendable {
    public let base: MergeSourceCell
    public let destination: MergeSourceCell
    public var changed: Bool { base.state != .normal || destination.state != .normal }
}
/// Display alignment keeps original line numbers and line-ending differences.
/// Source bytes remain in FileComparisonDocument; gaps never replace file data.
public struct FileComparisonAlignment: Sendable {
    public let rows: [FileComparisonRow]
    public let differences: [Range<Int>]
    public init(base: String, destination: String) {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            let pieces = text.components(separatedBy: "\n")
            return pieces.dropLast().map { $0 + "\n" } + (pieces.last!.isEmpty ? [] : [pieces.last!])
        }
        let a = lines(base), b = lines(destination)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a, by: { $0.utf8.elementsEqual($1.utf8) }) {
            switch change { case .remove(let i, _, _): removed.insert(i); case .insert(let i, _, _): inserted.insert(i) }
        }
        var output: [FileComparisonRow] = [], groups: [Range<Int>] = [], i = 0, j = 0
        func cell(_ lines: [String], _ index: Int, _ state: MergeSourceState) -> MergeSourceCell {
            MergeSourceCell(text: lines[index], lineNumber: index + 1, state: state)
        }
        let gap = MergeSourceCell(text: "", lineNumber: nil, state: .empty)
        while i < a.count || j < b.count {
            if removed.contains(i) || inserted.contains(j) {
                let ai = i, bj = j, start = output.count
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                for offset in 0..<max(i - ai, j - bj) {
                    output.append(FileComparisonRow(base: ai + offset < i ? cell(a, ai + offset, .removed) : gap,
                                                    destination: bj + offset < j ? cell(b, bj + offset, .added) : gap))
                }
                groups.append(start..<output.count)
            } else {
                output.append(FileComparisonRow(base: cell(a, i, .normal), destination: cell(b, j, .normal))); i += 1; j += 1
            }
        }
        rows = output; differences = groups
    }
}
extension GitRepository {
    /// Status-list Compare two files uses each working path independently,
    /// falling back to the same pinned HEAD for files deleted from disk.
    public func workingFilePairComparison(paths: [String]) throws -> RevisionComparisonSnapshot {
        guard paths.count == 2, paths[0] != paths[1] else { throw RevisionComparisonFailure.selection }
        var head: ComparisonRevision?
        func side(_ path: String) throws -> ComparisonRevision {
            let location = try restoreLocation(path)
            do {
                let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw RevisionComparisonFailure.selection }
                return .workingTree
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                if let head { return head }
                let hash = try run(["rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines)
                let pinned = ComparisonRevision.revision(hash); head = pinned
                return pinned
            }
        }
        let from = try side(paths[0]), to = try side(paths[1])
        let file = CommitFile(path: paths[1], oldPath: paths[0], action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: from, to: to, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
        // Reject missing historical paths, directories and gitlinks before opening.
        _ = try comparisonFile(snapshot, path: paths[1])
        return snapshot
    }
    /// Compare two selected historical paths in list order. Deleted sides use
    /// the selected commit's first parent, matching upstream CompareTwoFiles.
    public func historicalFilePairComparison(revision: String, files: [CommitFile]) throws -> RevisionComparisonSnapshot {
        guard files.count == 2, files[0].path != files[1].path, files.allSatisfy({ !$0.isSubmodule }) else { throw RevisionComparisonFailure.selection }
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        var parent = hash
        if files.contains(where: { $0.action.hasPrefix("D") }) {
            parent = try run(["rev-parse", "--verify", hash + "^1^{commit}"]).text.trimmingCharacters(in: .newlines)
        }
        let from: ComparisonRevision = .revision(files[0].action.hasPrefix("D") ? parent : hash)
        let to: ComparisonRevision = .revision(files[1].action.hasPrefix("D") ? parent : hash)
        let file = CommitFile(path: files[1].path, oldPath: files[0].path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: from, to: to, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
        _ = try comparisonFile(snapshot, path: file.path)
        return snapshot
    }
    /// Compare arbitrary historical paths, including the same path at different
    /// revisions. Both ends are pinned before any file content is read.
    public func historicalPathComparison(fromRevision: String, fromPath: String, toRevision: String, toPath: String) throws -> RevisionComparisonSnapshot {
        guard !fromPath.isEmpty, !toPath.isEmpty, !fromPath.contains("\0"), !toPath.contains("\0") else { throw RevisionComparisonFailure.selection }
        let fromHash = try run(["rev-parse", "--verify", "--end-of-options", fromRevision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let toHash = try run(["rev-parse", "--verify", "--end-of-options", toRevision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let file = CommitFile(path: toPath, oldPath: fromPath, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: .revision(fromHash), to: .revision(toHash), fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
        _ = try comparisonFile(snapshot, path: toPath)
        return snapshot
    }
    /// Read exact bytes from a pinned commit for Save As; no checkout or index write.
    public func historicalFile(revision: String, path: String) throws -> ComparisonFileContent {
        let snapshot = try revisionFileComparison(from: .emptyTree, to: .revision(revision), paths: [path])
        guard snapshot.files.contains(where: { $0.path == path && !$0.isSubmodule }) else { throw RevisionComparisonFailure.selection }
        return try comparisonFile(snapshot, path: path).destination
    }
    public func comparisonFile(_ snapshot: RevisionComparisonSnapshot, path: String) throws -> FileComparisonDocument {
        guard snapshot.root == root, let file = snapshot.files.first(where: { $0.path == path }), !file.isSubmodule else { throw RevisionComparisonFailure.selection }
        func read(_ revision: ComparisonRevision, _ path: String, absent: Bool) throws -> ComparisonFileContent {
            if absent || revision == .emptyTree { return ComparisonFileContent(path: path, revision: revision, bytes: Data(), mode: nil) }
            if revision == .workingTree {
                let location = try restoreLocation(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    return ComparisonFileContent(path: path, revision: revision, bytes: Data(try FileManager.default.destinationOfSymbolicLink(atPath: location.path).utf8), mode: "120000")
                }
                guard type == .typeRegular else { throw RevisionComparisonFailure.selection }
                let executable = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                return ComparisonFileContent(path: path, revision: revision, bytes: try Data(contentsOf: location), mode: executable & 0o111 == 0 ? "100644" : "100755", permissions: executable)
            }
            guard case .revision(let hash) = revision else { throw RevisionComparisonFailure.range }
            // Literal, NUL-delimited tree lookup handles colons, tabs and newlines.
            let records = try run(["ls-tree", "-z", hash, "--", path]).stdout.split(separator: 0)
            for record in records {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, header[1] == "blob" else { throw RevisionComparisonFailure.selection }
                return ComparisonFileContent(path: path, revision: revision, bytes: try run(["cat-file", "blob", String(header[2])]).stdout, mode: String(header[0]))
            }
            throw RevisionComparisonFailure.selection
        }
        return FileComparisonDocument(base: try read(snapshot.from, file.oldPath ?? path, absent: file.action.hasPrefix("A")),
                                      destination: try read(snapshot.to, path, absent: file.action.hasPrefix("D")))
    }
}


/// Compare selected working files independently of repository discovery.
/// The app must retain and validate access leases for both locations.
public struct WorkingFileComparison: Sendable {
    public let base: URL
    public let destination: URL
    public init(base: URL, destination: URL) throws {
        guard [base, destination].allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { throw RevisionComparisonFailure.selection }
        self.base = base.standardizedFileURL; self.destination = destination.standardizedFileURL
    }
    public var snapshot: RevisionComparisonSnapshot {
        let file = CommitFile(path: destination.path, oldPath: base.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        return RevisionComparisonSnapshot(root: destination.deletingLastPathComponent(), from: .workingTree, to: .workingTree, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
    }
    public static func workingContent(at url: URL) throws -> ComparisonFileContent {
        guard url.isFileURL, !url.path.contains("\0") else { throw RevisionComparisonFailure.selection }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw RevisionComparisonFailure.selection }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        let bytes = type == .typeSymbolicLink ? Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8) : try Data(contentsOf: url)
        let mode = type == .typeSymbolicLink ? "120000" : (permissions ?? 0) & 0o111 != 0 ? "100755" : "100644"
        return ComparisonFileContent(path: url.path, revision: .workingTree, bytes: bytes, mode: mode, permissions: permissions)
    }
    public func read() throws -> FileComparisonDocument {
        return FileComparisonDocument(base: try Self.workingContent(at: base), destination: try Self.workingContent(at: destination))
    }
    public func save(_ document: FileComparisonDocument, base editingBase: Bool, text: String) throws -> FileComparisonDocument {
        guard document.base.path == base.path, document.destination.path == destination.path else { throw RevisionComparisonFailure.selection }
        let original = editingBase ? document.base : document.destination
        let saved = try FileComparisonEditing.saveWorkingContent(at: editingBase ? base : destination, original: original, text: text)
        return FileComparisonDocument(base: editingBase ? saved : document.base, destination: editingBase ? document.destination : saved)
    }
}


public struct HistoricalWorkingFileComparison: Sendable {
    public let workingFile: URL
    public let snapshot: RevisionComparisonSnapshot
    public let path: String
    public func saveBase(_ document: FileComparisonDocument, text: String) throws -> FileComparisonDocument {
        guard document.base.path == workingFile.path, document.destination.path == path,
              document.destination.revision == snapshot.to else { throw RevisionComparisonFailure.selection }
        let saved = try FileComparisonEditing.saveWorkingContent(at: workingFile, original: document.base, text: text)
        return FileComparisonDocument(base: saved, destination: document.destination)
    }
}
extension GitRepository {
    public func historicalWorkingFileComparison(revision: String, path: String, workingFile: URL) throws -> HistoricalWorkingFileComparison {
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        _ = try historicalFile(revision: hash, path: path)
        let url = workingFile.standardizedFileURL
        _ = try WorkingFileComparison.workingContent(at: url)
        let file = CommitFile(path: path, oldPath: url.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: .workingTree, to: .revision(hash), fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
        return HistoricalWorkingFileComparison(workingFile: url, snapshot: snapshot, path: path)
    }
    public func comparisonFile(_ comparison: HistoricalWorkingFileComparison) throws -> FileComparisonDocument {
        guard comparison.snapshot.root == root, case .revision(let hash) = comparison.snapshot.to else { throw RevisionComparisonFailure.selection }
        return FileComparisonDocument(base: try WorkingFileComparison.workingContent(at: comparison.workingFile), destination: try historicalFile(revision: hash, path: comparison.path))
    }
}
