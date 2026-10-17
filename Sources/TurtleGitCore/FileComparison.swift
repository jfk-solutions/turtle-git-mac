import Foundation

public struct ComparisonFileContent: Sendable {
    public let path: String
    public let revision: ComparisonRevision
    public let bytes: Data
    public let mode: String?
    public let permissions: Int?
    public let encoding: ComparisonTextEncoding?
    public let isDeleted: Bool
    init(path: String, revision: ComparisonRevision, bytes: Data, mode: String?, permissions: Int? = nil, encoding: ComparisonTextEncoding? = nil, isDeleted: Bool = false, detectEncoding:Bool = true) {
        self.isDeleted = isDeleted
        self.path = path; self.revision = revision; self.bytes = bytes; self.mode = mode; self.permissions = permissions
        self.encoding = encoding ?? (detectEncoding ? ComparisonTextEncoding.detect(bytes) : nil)
    }
    public func usingMergeEncoding(preferUTF8: Bool, legacyEncoding:ComparisonTextEncoding = .windows1252) -> Self {
        Self(path: path, revision: revision, bytes: bytes, mode: mode, permissions: permissions,
             encoding: ComparisonTextEncoding.detectMerge(bytes, preferUTF8: preferUTF8, legacyEncoding:legacyEncoding), isDeleted: isDeleted, detectEncoding:false)
    }
    public var text: String? { isDeleted ? "" : encoding?.decode(bytes) }
}
public struct FileComparisonDocument: Sendable {
    public func usingMergeEncoding(preferUTF8: Bool, legacyEncoding:ComparisonTextEncoding = .windows1252) -> Self {
        Self(base: base.usingMergeEncoding(preferUTF8: preferUTF8,legacyEncoding:legacyEncoding), destination: destination.usingMergeEncoding(preferUTF8: preferUTF8,legacyEncoding:legacyEncoding))
    }
    public let base: ComparisonFileContent
    public let destination: ComparisonFileContent
}
/// Source ID_COMPARETWOCOMMITCHANGES compares two first-parent format-patch streams.
public struct CommitChangeSetComparison: Sendable {
    public let snapshot: RevisionComparisonSnapshot
    public let document: FileComparisonDocument
}
extension GitRepository {
    public func commitChangeSets(first: String, second: String, cancellation: OperationCancellation? = nil) throws -> CommitChangeSetComparison {
        let token = cancellation ?? OperationCancellation()
        func content(_ revision: String) throws -> ComparisonFileContent {
            try token.check()
            let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)
            // Resolved hashes make this range literal; retain source merge/root behavior.
            let bytes = try run(["format-patch", "--stdout", hash + "~1.." + hash, "--"], cancellation: token).stdout
            return ComparisonFileContent(path: hash + ".patch", revision: .revision(hash), bytes: bytes, mode: "100644")
        }
        let a = try content(first), b = try content(second)
        try token.check()
        let file = CommitFile(path: b.path, oldPath: a.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: a.revision, to: b.revision, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), diffDetection: diffDetection)
        return CommitChangeSetComparison(snapshot: snapshot, document: FileComparisonDocument(base: a, destination: b))
    }
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
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitHistoricalPreview-" + UUID().uuidString, isDirectory: true)
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
    public var changed: Bool { [base.state, destination.state].contains { $0 != .normal && $0 != .filtered } }
}
/// Display alignment keeps original line numbers and line-ending differences.
/// Source bytes remain in FileComparisonDocument; gaps never replace file data.
public struct FileComparisonAlignment: Sendable {
    public let rows: [FileComparisonRow]
    public let differences: [Range<Int>]
    init(rows: [FileComparisonRow], differences: [Range<Int>]) { self.rows = rows; self.differences = differences }
    public init(base: String, destination: String, baseKeys: [String]? = nil, destinationKeys: [String]? = nil) {
        func lines(_ text: String) -> [String] {
            let source = text as NSString
            return MergeLineEndings.lineRanges(in: text).map { source.substring(with: $0) }
        }
        let a = lines(base), b = lines(destination)
        // Ignore invalid key shapes instead of risking source-line misalignment.
        let ak = baseKeys?.count == a.count ? baseKeys! : a
        let bk = destinationKeys?.count == b.count ? destinationKeys! : b
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in bk.difference(from: ak, by: { $0.utf8.elementsEqual($1.utf8) }) {
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
                let state: MergeSourceState = a[i].utf8.elementsEqual(b[j].utf8) ? .normal : .filtered
                output.append(FileComparisonRow(base: cell(a, i, state), destination: cell(b, j, state))); i += 1; j += 1
            }
        }
        rows = output; differences = groups
    }
}
extension GitRepository {
    /// Status-list Compare two files uses each working path independently,
    /// falling back to the same pinned HEAD for files deleted from disk.
    public func workingFilePairComparison(paths: [String], cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        guard paths.count == 2, !GitReferenceName.equal(paths[0],paths[1]) else { throw RevisionComparisonFailure.selection }
        var head: ComparisonRevision?
        func side(_ path: String) throws -> ComparisonRevision {
            let location = try restoreLocation(path)
            do {
                let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw RevisionComparisonFailure.selection }
                return .workingTree
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                if let head { return head }
                let hash = try read(["rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines)
                let pinned = ComparisonRevision.revision(hash); head = pinned
                return pinned
            }
        }
        let from = try side(paths[0]), to = try side(paths[1])
        let file = CommitFile(path: paths[1], oldPath: paths[0], action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: from, to: to, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), diffDetection: diffDetection)
        // Reject missing historical paths, directories and gitlinks before opening.
        _ = try comparisonFile(snapshot, path: paths[1], cancellation: cancellation)
        return snapshot
    }
    /// Compare two selected historical paths in list order. Deleted sides use
    /// the selected occurrence's parent, matching upstream CompareTwoFiles.
    public func historicalFilePairComparison(revision: String, files: [CommitFile], cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        guard files.count == 2, !GitReferenceName.equal(files[0].path, files[1].path), files.allSatisfy({ !$0.isSubmodule }) else { throw RevisionComparisonFailure.selection }
        let hash = try read(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        func side(_ file: CommitFile) throws -> ComparisonRevision {
            guard file.action.hasPrefix("D") else { return .revision(hash) }
            let index = file.parentIndex ?? 0
            guard index >= 0 else { throw RevisionComparisonFailure.selection }
            return .revision(try read(["rev-parse", "--verify", hash + "^\(index + 1)^{commit}"]).text.trimmingCharacters(in: .newlines))
        }
        let from = try side(files[0]), to = try side(files[1])
        let file = CommitFile(path: files[1].path, oldPath: files[0].path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: from, to: to, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), diffDetection: diffDetection)
        _ = try comparisonFile(snapshot, path: file.path, cancellation: cancellation)
        return snapshot
    }
    /// Compare arbitrary historical paths, including the same path at different
    /// revisions. Both ends are pinned before any file content is read.
    public func historicalPathComparison(fromRevision: String, fromPath: String, toRevision: String, toPath: String) throws -> RevisionComparisonSnapshot {
        try preparedPathComparison(from: .revision(fromRevision), fromPath: fromPath, to: .revision(toRevision), toPath: toPath)
    }
    /// Prepared comparisons may mix current disk files and historical blobs.
    /// Pin each historical side; working sides remain live and editable.
    public func preparedPathComparison(from: ComparisonRevision, fromPath: String, to: ComparisonRevision, toPath: String, cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()
        _ = try restoreLocation(fromPath); _ = try restoreLocation(toPath)
        if from == .workingTree || to == .workingTree { guard try !isBare(cancellation: cancellation) else { throw RevisionComparisonFailure.selection } }
        func pin(_ revision: ComparisonRevision) throws -> ComparisonRevision {
            if revision == .workingTree { return revision }
            guard case .revision(let name) = revision else { throw RevisionComparisonFailure.selection }
            return .revision(try comparisonObject(name, cancellation: cancellation))
        }
        let from = try pin(from), to = try pin(to)
        let file = CommitFile(path: toPath, oldPath: fromPath, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: from, to: to, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), diffDetection: diffDetection)
        _ = try comparisonFile(snapshot, path: toPath, cancellation: cancellation)
        return snapshot
    }
    /// Read exact bytes from a pinned commit or tree for Save As; no checkout or index write.
    public func historicalFile(revision: String, path: String, cancellation: OperationCancellation? = nil) throws -> ComparisonFileContent {
        try cancellation?.check()

        let snapshot = try revisionFileComparison(from: .emptyTree, to: .revision(revision), paths: [path], cancellation: cancellation)
        guard snapshot.files.contains(where: { GitReferenceName.equal($0.path,path) && !$0.isSubmodule }) else { throw RevisionComparisonFailure.selection }
        return try comparisonFile(snapshot, path: path, cancellation: cancellation).destination
    }
    public func comparisonFile(_ snapshot: RevisionComparisonSnapshot, path: String, replacements: [Bool: ComparisonFileContent] = [:], cancellation: OperationCancellation? = nil) throws -> FileComparisonDocument {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        guard snapshot.root == root, let file = snapshot.files.first(where: { GitReferenceName.equal($0.path,path) }), !file.isSubmodule else { throw RevisionComparisonFailure.selection }
        func content(_ revision: ComparisonRevision, _ path: String, absent: Bool) throws -> ComparisonFileContent {
            try cancellation?.check()
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
            let records = try read(["-c", "core.precomposeunicode=false", "ls-tree", "-z", hash, "--", path]).stdout.split(separator: 0)
            for record in records {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, header[1] == "blob" else { throw RevisionComparisonFailure.selection }
                return ComparisonFileContent(path: path, revision: revision, bytes: try read(["cat-file", "blob", String(header[2])]).stdout, mode: String(header[0]))
            }
            throw RevisionComparisonFailure.selection
        }
        return FileComparisonDocument(base: try replacements[true] ?? content(snapshot.from, file.oldPath ?? path, absent: file.action.hasPrefix("A")),
                                      destination: try replacements[false] ?? content(snapshot.to, path, absent: file.action.hasPrefix("D")))
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
    public func read(replacements: [Bool: ComparisonFileContent] = [:]) throws -> FileComparisonDocument {
        return FileComparisonDocument(base: try replacements[true] ?? Self.workingContent(at: base), destination: try replacements[false] ?? Self.workingContent(at: destination))
    }
    public func save(_ document: FileComparisonDocument, base editingBase: Bool, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> FileComparisonDocument {
        guard GitReferenceName.equal(document.base.path,base.path), GitReferenceName.equal(document.destination.path,destination.path) else { throw RevisionComparisonFailure.selection }
        let original = editingBase ? document.base : document.destination
        let saved = try FileComparisonEditing.saveWorkingContent(at: editingBase ? base : destination, original: original, text: text, encoding: encoding, options: options)
        return FileComparisonDocument(base: editingBase ? saved : document.base, destination: editingBase ? document.destination : saved)
    }
}


public struct HistoricalWorkingFileComparison: Sendable {
    public let workingFile: URL
    public let snapshot: RevisionComparisonSnapshot
    public let path: String
    public func saveBase(_ document: FileComparisonDocument, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> FileComparisonDocument {
        guard GitReferenceName.equal(document.base.path,workingFile.path), GitReferenceName.equal(document.destination.path,path),
              document.destination.revision == snapshot.to else { throw RevisionComparisonFailure.selection }
        let saved = try FileComparisonEditing.saveWorkingContent(at: workingFile, original: document.base, text: text, encoding: encoding, options: options)
        return FileComparisonDocument(base: saved, destination: document.destination)
    }
}
extension GitRepository {
    public func historicalWorkingFileComparison(revision: String, path: String, workingFile: URL, cancellation: OperationCancellation? = nil) throws -> HistoricalWorkingFileComparison {
        try cancellation?.check()
        let hash = try comparisonObject(revision, cancellation: cancellation)
        _ = try historicalFile(revision: hash, path: path, cancellation: cancellation)
        let url = workingFile.standardizedFileURL
        _ = try WorkingFileComparison.workingContent(at: url)
        let file = CommitFile(path: path, oldPath: url.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: .workingTree, to: .revision(hash), fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
        return HistoricalWorkingFileComparison(workingFile: url, snapshot: snapshot, path: path)
    }
    public func comparisonFile(_ comparison: HistoricalWorkingFileComparison, replacements: [Bool: ComparisonFileContent] = [:], cancellation: OperationCancellation? = nil) throws -> FileComparisonDocument {
        try cancellation?.check()
        guard comparison.snapshot.root == root, case .revision(let hash) = comparison.snapshot.to else { throw RevisionComparisonFailure.selection }
        return FileComparisonDocument(base: try replacements[true] ?? WorkingFileComparison.workingContent(at: comparison.workingFile), destination: try replacements[false] ?? historicalFile(revision: hash, path: comparison.path, cancellation: cancellation))
    }
}

/// TortoiseMerge's CreateUnifiedDiff uses Git's no-index diff, not the
/// whitespace-filtered display plan. Inputs retain their saved bytes and mode.
public enum MergeUnifiedPatch {
    public static func validatedContext(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (-1...1000).contains(value) else { return nil }
        return value
    }
    public static func contextLines(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: "TurtleGitMerge.ContextLines") != nil else { return -1 }
        let value = defaults.integer(forKey: "TurtleGitMerge.ContextLines")
        return (-1...1000).contains(value) ? value : -1
    }
    public static func create(base: ComparisonFileContent, destination: ComparisonFileContent,
                              baseLabel: String, destinationLabel: String, contextLines: Int = -1,
                              executable: URL, cancellation: OperationCancellation? = nil) async throws -> Data {
        guard (-1...1000).contains(contextLines), [baseLabel, destinationLabel].allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw RevisionComparisonFailure.selection }
        let token = cancellation ?? OperationCancellation(); try token.check()
        let folder = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMergePatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        func input(_ content: ComparisonFileContent, name: String) throws -> String {
            if content.isDeleted { return "/dev/null" }
            let file = folder.appendingPathComponent(name)
            if content.mode == "120000" {
                guard let target = String(data: content.bytes, encoding: .utf8), !target.contains("\0") else { throw RevisionComparisonFailure.selection }
                try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target)
            } else {
                try content.bytes.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: content.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: file.path)
            }
            return name
        }
        let left = try input(base, name: "before"), right = try input(destination, name: "after")
        let git = GitRepository(root: folder, executable: executable)
        var arguments = ["-c", "core.quotePath=true", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        if contextLines >= 0 { arguments.append("--unified=\(contextLines)") }
        arguments += ["--", left, right]
        let output = try await git.run(arguments, successfulExitCodes: 0...1, cancellation: token).stdout
        try token.check()
        // Header paths must not expose temporary storage. Rewrite only headers;
        // hunk bytes (including non-UTF-8 text) are never decoded or replaced.
        let old = quotedPath("a/" + (base.isDeleted ? destinationLabel : baseLabel))
        let new = quotedPath("b/" + (destination.isDeleted ? baseLabel : destinationLabel))
        var result = Data(), inHeader = true
        let lines = output.split(separator: 10, omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            var line = Data(raw)
            if line.starts(with: Data("diff --git ".utf8)) { line = Data("diff --git \(old) \(new)".utf8); inHeader = true }
            else if line.starts(with: Data("@@".utf8)) { inHeader = false }
            else if inHeader {
                if line == Data("--- a/before".utf8) || line == Data("--- a/after".utf8) { line = Data("--- \(old)".utf8) }
                else if line == Data("+++ b/after".utf8) || line == Data("+++ b/before".utf8) { line = Data("+++ \(new)".utf8) }
                else if line.starts(with: Data("Binary files ".utf8)) {
                    line = Data("Binary files \(base.isDeleted ? "/dev/null" : old) and \(destination.isDeleted ? "/dev/null" : new) differ".utf8)
                }
            }
            if index > 0 { result.append(10) }; result.append(line)
        }
        return result
    }
    /// Git C-style path quoting, including octal UTF-8 bytes.
    private static func quotedPath(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.contains(where: { $0 <= 32 || $0 >= 127 || $0 == 34 || $0 == 92 }) else { return path }
        return "\"" + bytes.map { byte -> String in
            switch byte {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 9: return "\\t"
            case 10: return "\\n"
            case 13: return "\\r"
            case 32...126: return String(UnicodeScalar(byte))
            default: return String(format: "\\%03o", Int(byte))
            }
        }.joined() + "\""
    }
}

/// DiffData's YourBaseBoth ordering: all removals in a changed region precede
/// all additions. Original source row IDs remain available for block actions.
public struct OnePaneFileComparison: Sendable {
    public struct Row: Sendable {
        public let cell: MergeSourceCell
        public let alignmentRow: Int
        public let base: Bool
    }
    public let rows: [Row]
    public let differences: [Range<Int>]
    init(retainedRows: [Row]) {
        rows = retainedRows
        var blocks: [Range<Int>] = [], start: Int?
        for index in 0...retainedRows.count {
            let changed = index < retainedRows.count && !retainedRows[index].cell.state.isUnchanged
            if changed, start == nil { start = index }
            if !changed, let first = start { blocks.append(first..<index); start = nil }
        }
        differences = blocks
    }
    public var cells: [MergeSourceCell] { rows.map(\.cell) }
    public init(alignment: FileComparisonAlignment, options: MergeComparisonOptions = .init()) {
        var output: [Row] = [], ranges: [Range<Int>] = [], index = 0
        func append(_ cell: MergeSourceCell, at index: Int, base: Bool, state: MergeSourceState? = nil, number: Int? = nil, hidden: Bool? = nil) {
            guard cell.lineNumber != nil else { return }
            // DiffData only installs the trailing NoEnding empty record in its
            // left/right views, after building the combined view. Edited empty
            // records are user content and remain eligible in retained layouts.
            guard !cell.text.isEmpty || cell.state == .edited else { return }
            output.append(Row(cell: MergeSourceCell(text: cell.text, lineNumber: base ? (state == .removedWhitespace ? number : nil) : cell.lineNumber, state: state ?? cell.state, hiddenByComparison: hidden ?? cell.hiddenByComparison), alignmentRow: index, base: base))
        }
        let starts = Dictionary(uniqueKeysWithValues: alignment.differences.map { ($0.lowerBound, $0) })
        while index < alignment.rows.count {
            if let range = starts[index] {
                let start = output.count
                for row in range { append(alignment.rows[row].base, at: row, base: true, state: .removed) }
                for row in range { append(alignment.rows[row].destination, at: row, base: false, state: .added) }
                if output.count > start { ranges.append(start..<output.count) }; index = range.upperBound
            } else {
                let row = alignment.rows[index]
                let payloadDiffers = !row.base.displayText.utf8.elementsEqual(row.destination.displayText.utf8)
                // DiffData::CompareWithIgnoreWS trims leading spaces/tabs
                // only for WhiteSpaces. AllWhiteSpaces always collapses here.
                func trimLeading(_ value: String) -> String { String(decoding:value.utf8.drop { $0 == 32 || $0 == 9 },as:UTF8.self) }
                let changedAfterLeadingTrim = !trimLeading(row.base.displayText).utf8.elementsEqual(trimLeading(row.destination.displayText).utf8)
                let split = payloadDiffers && (options.whitespace == .compare || options.whitespace == .ignoreChanges && changedAfterLeadingTrim)
                if split {
                    let hidden = options.whitespace != .compare
                    append(row.base, at: index, base: true, state: .removedWhitespace, number: row.destination.lineNumber, hidden: hidden)
                    append(row.destination, at: index, base: false, state: .addedWhitespace, hidden: hidden)
                } else {
                    // DiffData's common combined record uses Your payload but
                    // Base EOL, including NoEnding. Keep the two-pane originals
                    // intact; only this serialized combined record adopts it.
                    let baseEnding = (row.base.text as NSString).substring(from:row.base.displayText.utf16.count)
                    let cell = MergeSourceCell(text:row.destination.displayText + baseEnding,lineNumber:row.destination.lineNumber,state:.normal,hiddenByComparison:true)
                    append(cell, at:index, base:false)
                }
                index += 1
            }
        }
        rows = output; differences = ranges
    }
    /// BaseView::SaveFile excludes Removed but retains RemovedWhitespace.
    /// Save As serializes captured endings, not synthetic display separators.
    public var sourceSaveText: String { cells.filter { !$0.state.isRemoval && $0.state != .empty }.map(\.text).joined() }
    /// Removed lines remain display-only unless the user edits that line. Such
    /// edits retain its unselected payload, as the source Edited state does.
    public func editingSource(for ranges: [NSRange]) throws -> (text: String, ranges: [NSRange]) {
        let cells = self.cells, length = cells.reduce(0) { $0 + $1.displayText.utf16.count + 1 }
        guard ranges.allSatisfy({ $0.location >= 0 && $0.length >= 0 && $0.location <= length && $0.length <= length - $0.location }) else { throw FileComparisonEditFailure.range }
        var offsets: [Int] = [], offset = 0
        for cell in cells { offsets.append(offset); offset += cell.displayText.utf16.count + 1 }
        let touched = Set(rows.indices.filter { i in ranges.contains { range in
            let rowRange = NSRange(location: offsets[i], length: cells[i].displayText.utf16.count + 1)
            return range.length == 0 ? NSLocationInRange(range.location, rowRange) : NSIntersectionRange(range, rowRange).length > 0
        } })
        let included = rows.indices.filter { !rows[$0].base || rows[$0].cell.state == .removedWhitespace || touched.contains($0) }
        let style = MergeLineEndings.predominantStyle(in: rows.filter { !$0.base }.map { $0.cell.text }.joined())
        var source = "", sourceLength = 0, starts: [Int: Int] = [:]
        source.reserveCapacity(included.reduce(0) { $0 + cells[$1].text.utf8.count })
        for (position, index) in included.enumerated() {
            starts[index] = sourceLength; source += cells[index].text; sourceLength += cells[index].text.utf16.count
            if position < included.count - 1 && !MergeLineEndings.hasFinalEnding(cells[index].text) { source += style.rawValue; sourceLength += style.rawValue.utf16.count }
        }
        func map(_ position: Int) -> Int {
            for index in rows.indices where position < offsets[index] + cells[index].displayText.utf16.count + 1 {
                if let start = starts[index] { return start + min(position - offsets[index], cells[index].displayText.utf16.count) }
                return included.first(where: { $0 > index }).flatMap { starts[$0] } ?? sourceLength
            }
            return sourceLength
        }
        return (source, ranges.map { let start = map($0.location); return NSRange(location: start, length: max(0, map(NSMaxRange($0)) - start)) })
    }
    public func applying(_ replacement: String, ranges: [NSRange]) throws -> (text: String, caret: Int) {
        let edit = try editingSource(for: ranges)
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ NSMaxRange($0.0) <= $0.1.location }) else { throw FileComparisonEditFailure.range }
        guard !ranges.isEmpty else { return (edit.text, 0) }
        let style = MergeLineEndings.predominantStyle(in: edit.text), inserted = MergeLineEndings.converting(replacement, to: style)
        let value = NSMutableString(string: edit.text)
        for range in edit.ranges.reversed() { value.replaceCharacters(in: range, with: inserted) }
        let delta = edit.ranges.dropLast().reduce(0) { $0 + inserted.utf16.count - $1.length }
        return (value as String, edit.ranges.last!.location + delta + inserted.utf16.count)
    }
    public static func defaultEnabled(from defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: "TurtleGitMerge.OnePane") }
}

/// Captured file-history names, in the displayed newest-to-oldest Log order.
/// GitLogListAction walks each preceding row's rename before resolving a target.
public struct FollowedHistoryPaths: Sendable {
    public let originalPath: String
    public let paths: [String: String]
    public func path(at revision: ComparisonRevision) throws -> String {
        if revision == .workingTree || revision == .emptyTree { return originalPath }
        guard case .revision(let hash) = revision, let path = paths[hash] else { throw RevisionComparisonFailure.selection }
        return path
    }
}
extension GitRepository {
    public func followedHistoryPaths(path: String, entries: [LogEntry], through revisions: [String], cancellation: OperationCancellation? = nil) throws -> FollowedHistoryPaths {
        try cancellation?.check(); _ = try restoreLocation(path)
        let rows = entries.filter { !$0.hash.isEmpty }
        guard !revisions.isEmpty, let last = revisions.compactMap({ hash in rows.firstIndex { $0.hash == hash } }).max(),
              revisions.allSatisfy({ hash in rows.contains { $0.hash == hash } }), Set(rows.map(\.hash)).count == rows.count else { throw RevisionComparisonFailure.selection }
        let captured = Array(rows.prefix(last + 1))
        let changes = try revisionChanges(in: Array(captured.dropLast()), cancellation: cancellation)
        var current = path, names: [String: String] = [:]
        for entry in captured {
            try cancellation?.check(); names[entry.hash] = current
            if let rename = changes[entry.hash]?.first(where: { GitReferenceName.equal($0.path, current) && $0.oldPath != nil && ($0.action.hasPrefix("R") || $0.action.hasPrefix("C")) }), let old = rename.oldPath {
                _ = try restoreLocation(old); current = old
            }
        }
        return FollowedHistoryPaths(originalPath: path, paths: names)
    }
    /// A file history can compare different names even when a distant rename no
    /// longer meets similarity detection. Keep both endpoint names explicitly.
    public func followedHistoryComparison(path: String, entries: [LogEntry], from: ComparisonRevision, to: ComparisonRevision, parentOf: String? = nil, cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        let required = [from, to].compactMap { side -> String? in
            guard case .revision(let hash) = side, parentOf == nil || side != from else { return nil }
            if to == .workingTree, side == from, !entries.contains(where: { $0.hash == hash }) { return nil }
            return hash
        }
        let names: FollowedHistoryPaths
        if required.isEmpty, to == .workingTree { _ = try restoreLocation(path); names = FollowedHistoryPaths(originalPath: path, paths: [:]) }
        else { names = try followedHistoryPaths(path: path, entries: entries, through: required, cancellation: cancellation) }
        let toPath = try names.path(at: to)
        var fromPath = parentOf != nil ? toPath : required.isEmpty && to == .workingTree ? path : try names.path(at: from)
        func pin(_ side: ComparisonRevision) throws -> ComparisonRevision {
            if case .revision(let hash) = side { return .revision(try comparisonObject(hash, cancellation: cancellation)) }; return side
        }
        let old = try pin(from), new = try pin(to)
        if required.isEmpty, to == .workingTree, case .revision = old {
            let head = try comparisonObject("HEAD", cancellation: cancellation)
            guard old == .revision(head) else { throw RevisionComparisonFailure.selection }
        }
        if let parentOf {
            guard to == .revision(parentOf) else { throw RevisionComparisonFailure.selection }
            let comparison = try revisionComparison(from: old, to: new, cancellation: cancellation)
            if let file = comparison.files.first(where: { GitReferenceName.equal($0.path, toPath) }), let oldPath = file.oldPath { fromPath = oldPath }
        }
        func mode(_ side: ComparisonRevision, _ name: String) throws -> String? {
            try cancellation?.check(); let location = try restoreLocation(name)
            if side == .emptyTree { return nil }
            if side == .workingTree {
                guard try !isBare(cancellation: cancellation) else { throw RevisionComparisonFailure.selection }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
                    switch attributes[.type] as? FileAttributeType {
                    case .typeRegular: return "100644"
                    case .typeSymbolicLink: return "120000"
                    default: throw RevisionComparisonFailure.selection
                    }
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            }
            guard case .revision(let hash) = side else { throw RevisionComparisonFailure.range }
            let data = try run(["ls-tree", "-z", hash, "--", name], cancellation: cancellation).stdout
            for record in data.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(name.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, header[1] == "blob" else { throw RevisionComparisonFailure.selection }
                return String(header[0])
            }
            return nil
        }
        let a = try mode(old, fromPath), b = try mode(new, toPath)
        guard a != nil || b != nil else { throw RevisionComparisonFailure.selection }
        let file = CommitFile(path: toPath, oldPath: fromPath, action: a == nil ? "A" : b == nil ? "D" : "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        return RevisionComparisonSnapshot(root: root, from: old, to: new, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), scopePaths: [fromPath, toPath], diffDetection: diffDetection)
    }
}
