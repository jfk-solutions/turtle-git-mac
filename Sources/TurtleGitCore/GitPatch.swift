import Foundation

public struct GitPatch: Sendable {
    public struct Hunk: Sendable {
        public let header: Int
        public let range: Range<Int>
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let suffix: String
    }
    public struct File: Sendable {
        public let header: [String]
        public let hunks: [Hunk]
        public var supportsPartialChanges: Bool {
            !header.contains { line in
                ["new file mode", "deleted file mode", "old mode", "new mode", "rename from", "rename to", "copy from", "copy to", "GIT binary patch", "Binary files"].contains { line.hasPrefix($0) }
            } && !hunks.isEmpty
        }
    }
    public let text: String
    public let lines: [String]
    public let files: [File]
    public init(text: String) {
        self.text = text
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
        let expression = try! NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(.*)$"#)
        var files: [File] = [], header: [String] = [], hunks: [Hunk] = []
        var pending: (Int, Int, Int, Int, Int, String)?
        func finishHunk(_ end: Int) {
            if let value = pending { hunks.append(Hunk(header: value.0, range: value.0 + 1..<end, oldStart: value.1, oldCount: value.2, newStart: value.3, newCount: value.4, suffix: value.5)) }
            pending = nil
        }
        func finishFile(_ end: Int) {
            finishHunk(end)
            if !header.isEmpty { files.append(File(header: header, hunks: hunks)) }
            header = []; hunks = []
        }
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff --git ") { finishFile(index); header.append(line); continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = expression.firstMatch(in: line, range: range) {
                finishHunk(index)
                func field(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
                pending = (index, Int(field(1)!)!, Int(field(2) ?? "1")!, Int(field(3)!)!, Int(field(4) ?? "1")!, field(5) ?? "")
            } else if pending == nil { header.append(line) }
        }
        finishFile(lines.count); self.files = files
    }
    public func changedLine(_ index: Int) -> Bool {
        guard lines.indices.contains(index), files.flatMap(\.hunks).contains(where: { $0.range.contains(index) }) else { return false }
        return lines[index].hasPrefix("+") || lines[index].hasPrefix("-")
    }
    public func selectedPatch(lines selected: Set<Int>, entireHunks: Bool, reverse: Bool) throws -> String {
        var result: [String] = []
        for file in files {
            let picked = file.hunks.filter { selected.contains($0.header) || $0.range.contains(where: { selected.contains($0) }) }
            guard !picked.isEmpty else { continue }
            guard file.supportsPartialChanges else { throw PatchFailure.unsupportedFile }
            var output: [String] = [], delta = 0
            for hunk in picked {
                var body: [String] = [], previousKept = false, changes = 0
                for index in hunk.range {
                    let line = self.lines[index]
                    if line.hasPrefix("\\ No newline") {
                        if previousKept { body.append(line) }; continue
                    }
                    let include = entireHunks || selected.contains(index)
                    previousKept = false
                    if line.hasPrefix("+") {
                        if include { body.append(line); changes += 1; previousKept = true }
                        else if reverse { body.append(" " + line.dropFirst()); previousKept = true }
                    } else if line.hasPrefix("-") {
                        if include { body.append(line); changes += 1; previousKept = true }
                        else if !reverse { body.append(" " + line.dropFirst()); previousKept = true }
                    } else if line.hasPrefix(" ") { body.append(line); previousKept = true }
                }
                guard changes > 0 else { continue }
                let oldCount = body.filter { $0.hasPrefix(" ") || $0.hasPrefix("-") }.count
                let newCount = body.filter { $0.hasPrefix(" ") || $0.hasPrefix("+") }.count
                let base = reverse ? hunk.newStart + (hunk.newCount == 0 ? 1 : 0) : hunk.oldStart + (hunk.oldCount == 0 ? 1 : 0)
                let oldStart = (reverse ? base - delta : base) - (oldCount == 0 ? 1 : 0)
                let newStart = (reverse ? base : base + delta) - (newCount == 0 ? 1 : 0)
                output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + hunk.suffix)
                output += body; delta += newCount - oldCount
            }
            if !output.isEmpty { result += file.header + output }
        }
        guard !result.isEmpty else { throw PatchFailure.noChangesSelected }
        return result.joined(separator: "\n") + "\n"
    }
}

public enum PatchFailure: LocalizedError {
    case unsupportedFile, noChangesSelected, changed, encoding
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "Partial staging for new, deleted, renamed, binary or mode-changing files is not available yet. Use the file's staging checkbox."
        case .noChangesSelected: return "Select changed lines or a changed hunk first."
        case .changed: return "The diff has changed. Refresh the patch before applying the selection."
        case .encoding: return "This patch is not valid UTF-8. Use whole-file staging until this encoding is supported."
        }
    }
}

extension GitRepository {
    public func workingTreePatch(paths: [String], base: String? = nil) throws -> GitPatch {
        guard let text = String(data: try workingTreePatchData(paths: paths, base: base), encoding: .utf8) else { throw PatchFailure.encoding }
        return GitPatch(text: text)
    }
    public func workingTreePatchData(paths: [String], base: String? = nil) throws -> Data {
        let head = (try? run(["rev-parse", "--verify", "HEAD"])) != nil
        let comparison = base.map { [$0] } ?? (head ? ["HEAD"] : ["--cached"])
        let args = ["diff", "--no-ext-diff", "--no-color", "--no-textconv", "--unified=3", "-M"] + comparison + ["--"] + paths
        return try run(args).stdout
    }
    public func patch(paths: [String], staged: Bool, base: String? = nil) throws -> GitPatch {
        guard let text = String(data: try patchData(paths: paths, staged: staged, base: base), encoding: .utf8) else { throw PatchFailure.encoding }
        return GitPatch(text: text)
    }
    /// Unified viewers receive original bytes; partial staging still requires UTF-8.
    public func patchData(paths: [String], staged: Bool, base: String? = nil) throws -> Data {
        let args = ["diff", "--no-ext-diff", "--no-color", "--no-textconv", "--unified=3"] + (staged ? ["--cached"] + (base.map { [$0] } ?? []) : []) + ["--"] + paths
        return try run(args).stdout
    }
    public func applyPatchSelection(_ document: GitPatch, paths: [String], staged: Bool, lines: Set<Int>, entireHunks: Bool, base: String? = nil) throws {
        guard try patch(paths: paths, staged: staged, base: base).text == document.text else { throw PatchFailure.changed }
        let text = try document.selectedPatch(lines: lines, entireHunks: entireHunks, reverse: staged)
        let url = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let args = ["apply", "--cached", "--unidiff-zero"] + (staged ? ["--reverse"] : [])
        _ = try run(args + ["--check", url.path])
        _ = try run(args + [url.path])
    }
}

/// A byte-preserving review of a patch against the current working tree.
/// Applying it changes files, without staging them or creating a commit.
public struct WorkingTreePatchReview: Sendable {
    public struct File: Sendable, Identifiable {
        public let id: Int
        /// Raw filesystem path bytes from Git's NUL-delimited output.
        public let pathBytes: Data
        public var path: String { String(decoding: pathBytes, as: UTF8.self) }
        public let additions: Int?
        public let deletions: Int?
        public var isBinary: Bool { additions == nil && deletions == nil }
    }
    public let files: [File]
    public let document: UnifiedDiffDocument
    public let statistics: String
    public let summary: String
    public let validationError: String?
    public var canApply: Bool { validationError == nil }
    fileprivate let repositoryRoot: URL
    fileprivate let reversed: Bool
    fileprivate let stripCount: Int
}

public enum WorkingTreePatchFailure: LocalizedError {
    case stripCount, review, metadata
    public var errorDescription: String? {
        switch self {
        case .stripCount: return "The patch path strip count must be nonnegative."
        case .review: return "Review an applicable patch in this repository before applying it."
        case .metadata: return "Git returned incomplete patch file statistics."
        }
    }
}

extension GitRepository {
    public func reviewWorkingTreePatch(_ bytes: Data, reversed: Bool = false, stripCount: Int = 1) throws -> WorkingTreePatchReview {
        guard stripCount >= 0 else { throw WorkingTreePatchFailure.stripCount }
        return try withWorkingTreePatch(bytes) { file in
            let arguments = ["apply", "-p\(stripCount)"] + (reversed ? ["--reverse"] : [])
            let statistics = try run(arguments + ["--stat", "--", file.path]).text
            let summary = try run(arguments + ["--summary", "--", file.path]).text
            let files = try WorkingTreePatchReview.parseFiles(run(arguments + ["--numstat", "-z", "--", file.path]).stdout)
            var failure: String?
            do { _ = try run(arguments + ["--check", "--", file.path]) }
            catch let error as GitFailure { failure = error.localizedDescription }
            return WorkingTreePatchReview(files: files, document: UnifiedDiffDocument(bytes: bytes), statistics: statistics, summary: summary, validationError: failure, repositoryRoot: root, reversed: reversed, stripCount: stripCount)
        }
    }
    public func applyWorkingTreePatch(_ review: WorkingTreePatchReview) throws -> String {
        guard review.repositoryRoot == root, review.canApply else { throw WorkingTreePatchFailure.review }
        return try withWorkingTreePatch(review.document.bytes) { file in
            let arguments = ["apply", "-p\(review.stripCount)"] + (review.reversed ? ["--reverse"] : [])
            // Revalidate against current files, then let Git validate again when
            // applying. No --index/--cached/--reject or unsafe-path override.
            _ = try run(arguments + ["--check", "--", file.path])
            return try run(arguments + ["--", file.path]).text
        }
    }
    private func withWorkingTreePatch<T>(_ bytes: Data, _ operation: (URL) throws -> T) throws -> T {
        let file = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-review-patch-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: file) }
        return try operation(file)
    }
}


extension WorkingTreePatchReview {
    static func parseFiles(_ bytes: Data) throws -> [File] {
        guard bytes.isEmpty || bytes.last == 0 else { throw WorkingTreePatchFailure.metadata }
        return try bytes.split(separator: 0).enumerated().map { index, record in
            // Only the first two tabs are field separators. Every remaining byte
            // belongs to the path, including tabs/newlines and non-UTF-8 bytes.
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty else { throw WorkingTreePatchFailure.metadata }
            let added = String(decoding: fields[0], as: UTF8.self), deleted = String(decoding: fields[1], as: UTF8.self)
            let additions = Int(added), deletions = Int(deleted)
            guard (added == "-" && deleted == "-") || (additions.map { $0 >= 0 } == true && deletions.map { $0 >= 0 } == true) else { throw WorkingTreePatchFailure.metadata }
            return File(id: index, pathBytes: Data(fields[2]), additions: additions, deletions: deletions)
        }
    }
}
