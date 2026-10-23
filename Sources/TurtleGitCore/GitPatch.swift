import Foundation
import Darwin

public struct GitPatch: Sendable {
    public struct Hunk: Sendable {
        public let header: Int
        public let range: Range<Int>
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let suffix: String
        fileprivate let sourceSuffix: String
    }
    public struct File: Sendable {
        public let header: [String]
        fileprivate let sourceHeader: [String]
        public let hunks: [Hunk]
        public var hasSelectedTextMetadata: Bool {
            header.contains { $0.hasPrefix("rename from ") || $0.hasPrefix("old mode ") || $0.hasPrefix("new mode ") }
        }
        public var supportsPartialChanges: Bool {
            !header.contains { line in
                if ["copy from", "copy to", "GIT binary patch", "Binary files"].contains(where: { line.hasPrefix($0) }) { return true }
                if line.hasPrefix("index ") && (line.hasSuffix(" 120000") || line.hasSuffix(" 160000")) { return true }
                let changesMode = ["new file mode ", "deleted file mode ", "old mode ", "new mode "].contains { line.hasPrefix($0) }
                return changesMode && !line.hasSuffix("100644") && !line.hasSuffix("100755")
            } && !hunks.isEmpty
        }
    }
    public let bytes: Data
    public let text: String
    public let lines: [String]
    private let sourceLines: [String]
    public let files: [File]
    public let includesUntracked: Bool
    public let displayLegacyEncoding:ComparisonTextEncoding
    public init(text: String, includesUntracked: Bool = false,displayLegacyEncoding:ComparisonTextEncoding = .windows1252) {
        self.init(bytes:Data(text.utf8),includesUntracked:includesUntracked,displayLegacyEncoding:displayLegacyEncoding)
    }
    private static func carrier(_ bytes:Data)->String {
        String(String.UnicodeScalarView(bytes.map {UnicodeScalar($0)}))
    }
    private static func carrierBytes(_ value:String)->Data {
        // Every carrier scalar originated from one byte; generated patch syntax
        // is ASCII. Display decoding is deliberately outside this representation.
        Data(value.unicodeScalars.map {UInt8($0.value)})
    }
    private static func displayLine(_ value:String,legacy:ComparisonTextEncoding)->String {
        let bytes=carrierBytes(value)
        if let text=String(data:bytes,encoding:.utf8) {return text}
        if legacy == .windows1252 {return String(data:bytes,encoding:.windowsCP1252) ?? value}
        return legacy.decode(bytes) ?? value
    }
    public static func displayText(_ bytes:Data,displayLegacyEncoding:ComparisonTextEncoding = .windows1252)->String {
        carrier(bytes).components(separatedBy:"\n").map {displayLine($0,legacy:displayLegacyEncoding)}.joined(separator:"\n")
    }
    public init(bytes:Data,includesUntracked:Bool = false,displayLegacyEncoding:ComparisonTextEncoding = .windows1252) {
        self.bytes=bytes;self.includesUntracked=includesUntracked;self.displayLegacyEncoding=displayLegacyEncoding
        let source=Self.carrier(bytes)
        self.text=Self.displayText(bytes,displayLegacyEncoding:displayLegacyEncoding)
        var lines=source.components(separatedBy:"\n")
        if lines.last == "" {lines.removeLast()}
        self.sourceLines=lines;self.lines=lines.map {Self.displayLine($0,legacy:displayLegacyEncoding)}
        let expression = try! NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@([\s\S]*)\z"#)
        var files: [File] = [], header: [String] = [], hunks: [Hunk] = []
        var pending: (Int, Int, Int, Int, Int, String)?
        func finishHunk(_ end: Int) {
            if let value = pending { hunks.append(Hunk(header: value.0, range: value.0 + 1..<end, oldStart: value.1, oldCount: value.2, newStart: value.3, newCount: value.4, suffix: Self.displayLine(value.5,legacy:displayLegacyEncoding), sourceSuffix:value.5)) }
            pending = nil
        }
        func finishFile(_ end: Int) {
            finishHunk(end)
            if !header.isEmpty { files.append(File(header: header.map {Self.displayLine($0,legacy:displayLegacyEncoding)}, sourceHeader:header, hunks: hunks)) }
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
    /// Text is for display/copy. Apply and patch export use selectedPatchData.
    public func selectedPatch(lines selected:Set<Int>,entireHunks:Bool,reverse:Bool) throws -> String {
        try selectedSourcePatch(lines:selected,entireHunks:entireHunks,reverse:reverse).components(separatedBy:"\n").map {Self.displayLine($0,legacy:displayLegacyEncoding)}.joined(separator:"\n")
    }
    public func selectedPatchData(lines selected:Set<Int>,entireHunks:Bool,reverse:Bool) throws -> Data {
        Self.carrierBytes(try selectedSourcePatch(lines:selected,entireHunks:entireHunks,reverse:reverse))
    }
    private func selectedSourcePatch(lines selected: Set<Int>, entireHunks: Bool, reverse: Bool) throws -> String {
        var result: [String] = []
        for file in files {
            let picked = file.hunks.filter { selected.contains($0.header) || $0.range.contains(where: { selected.contains($0) }) }
            guard !picked.isEmpty else { continue }
            guard file.supportsPartialChanges else { throw PatchFailure.unsupportedFile }
            var output: [String] = [], delta = 0, selectedOldCount = 0, selectedNewCount = 0
            for hunk in picked {
                var body: [String] = [], previousKept = false, changes = 0
                for index in hunk.range {
                    let line = self.sourceLines[index]
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
                selectedOldCount += oldCount; selectedNewCount += newCount
                let base = reverse ? hunk.newStart + (hunk.newCount == 0 ? 1 : 0) : hunk.oldStart + (hunk.oldCount == 0 ? 1 : 0)
                let oldStart = (reverse ? base - delta : base) - (oldCount == 0 ? 1 : 0)
                let newStart = (reverse ? base : base + delta) - (newCount == 0 ? 1 : 0)
                output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + hunk.sourceSuffix)
                output += body; delta += newCount - oldCount
            }
            if !output.isEmpty {
                var header = file.sourceHeader
                // A partial removal of a new file leaves an ordinary indexed
                // file. Likewise, partial deletion must retain its destination.
                // Preserve Git's quoted/escaped path representation verbatim.
                func paired(_ line: String, from: String, to: String) -> String {
                    let name = String(line.dropFirst(4))
                    if name.hasPrefix("\"" + from) { return "\"" + to + name.dropFirst(from.count + 1) }
                    if name.hasPrefix(from) { return to + name.dropFirst(from.count) }
                    return name
                }
                if reverse, selectedOldCount > 0, header.contains(where: { $0.hasPrefix("new file mode ") }), let path = header.first(where: { $0.hasPrefix("+++ ") }) {
                    header.removeAll { $0.hasPrefix("new file mode ") || $0.hasPrefix("index ") }
                    header = header.map { $0 == "--- /dev/null" ? "--- " + paired(path, from: "b/", to: "a/") : $0 }
                } else if !reverse, selectedNewCount > 0, header.contains(where: { $0.hasPrefix("deleted file mode ") }), let path = header.first(where: { $0.hasPrefix("--- ") }) {
                    header.removeAll { $0.hasPrefix("deleted file mode ") || $0.hasPrefix("index ") }
                    header = header.map { $0 == "+++ /dev/null" ? "+++ " + paired(path, from: "a/", to: "b/") : $0 }
                }
                result += header + output
            }
        }
        guard !result.isEmpty else { throw PatchFailure.noChangesSelected }
        return result.joined(separator: "\n") + "\n"
    }
}

public enum PatchFailure: LocalizedError {
    case unsupportedFile, noChangesSelected, changed, encoding
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "Binary, symlink and copied files require whole-file staging. Metadata-only changes have no selectable text hunk."
        case .noChangesSelected: return "Select changed lines or a changed hunk first."
        case .changed: return "The diff has changed. Refresh the patch before applying the selection."
        case .encoding: return "This patch contains a path that cannot be represented safely."
        }
    }
}

extension GitRepository {
    public func workingTreePatch(paths: [String], base: String? = nil, cancellation: OperationCancellation? = nil) throws -> GitPatch {
        GitPatch(bytes:try workingTreePatchData(paths:paths,base:base,cancellation:cancellation))
    }
    public func workingTreePatchData(paths: [String], base: String? = nil, cancellation: OperationCancellation? = nil) throws -> Data {
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0
        let comparison = base.map { [$0] } ?? (head ? ["HEAD"] : ["--cached"])
        let args = ["diff", "--no-ext-diff", "--no-color", "--no-textconv", "--unified=3"] + diffDetection.comparisonArguments + comparison + ["--"] + paths
        return try run(args, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
    }
    public func patch(paths: [String], staged: Bool, base: String? = nil, cancellation: OperationCancellation? = nil, includeUntracked: Bool = false) throws -> GitPatch {
        GitPatch(bytes:try patchData(paths:paths,staged:staged,base:base,cancellation:cancellation,includeUntracked:includeUntracked),includesUntracked:includeUntracked && !staged)
    }
    /// All patch consumers retain original bytes independently of display decoding.
    public func patchData(paths: [String], staged: Bool, base: String? = nil, cancellation: OperationCancellation? = nil, includeUntracked: Bool = false) throws -> Data {
        let options = ["--no-ext-diff", "--no-color", "--no-textconv", "--unified=3", "--src-prefix=a/", "--dst-prefix=b/"]
        var args = ["diff"] + diffDetection.comparisonArguments
        args.append(contentsOf: options)
        if staged {
            args.append("--cached")
            if let base { args.append(base) }
        }
        args.append("--"); args.append(contentsOf: paths)
        var bytes = try run(args, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
        if includeUntracked && !staged && !paths.isEmpty {
            let names = try run(["ls-files", "--others", "--exclude-standard", "-z", "--"] + paths, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
            for raw in names.split(separator: 0) {
                try cancellation?.check()
                guard let path = String(data: raw, encoding: .utf8) else { throw PatchFailure.encoding }
                var untrackedArguments = ["diff", "--no-index"]
                untrackedArguments.append(contentsOf: options)
                untrackedArguments.append(contentsOf: ["--", "/dev/null", path])
                let addition: Data = try run(untrackedArguments, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
                bytes.append(addition)
            }
        }
        return bytes
    }
    public func applyPatchSelection(_ document: GitPatch, paths: [String], staged: Bool, lines: Set<Int>, entireHunks: Bool, base: String? = nil) throws {
        guard try patch(paths: paths, staged: staged, base: base, includeUntracked: document.includesUntracked).bytes == document.bytes else { throw PatchFailure.changed }
        let bytes = try document.selectedPatchData(lines: lines, entireHunks: entireHunks, reverse: staged)
        let url = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
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
    public let isGitWorkingTree: Bool
    public let textEncodingPolicy: MergeTextEncodingPolicy?
    fileprivate let decodedPatch: SourceTextPatch?
    fileprivate let decodedInputs: GitPathMap<ComparisonFileContent>?
    fileprivate let directoryMode: Bool
    fileprivate let repositoryRoot: URL
    fileprivate let reversed: Bool
    fileprivate let stripCount: Int
    fileprivate let includePatterns: [String]
}

public struct WorkingTreePatchFileResult: Sendable {
    public let pathBytes: Data
    public let success: Bool
    public let output: String
    public let requiresMerge: Bool
    /// The file was patched even when a later optional Git Add failed.
    public let addError:String?
    /// Git applied the patch; subsequent empty-result cleanup did not finish.
    public let postApplyError:String?
    public init(pathBytes:Data,success:Bool,output:String,requiresMerge:Bool = false,addError:String?=nil,postApplyError:String?=nil) {self.pathBytes = pathBytes;self.success = success;self.output = output;self.requiresMerge = requiresMerge;self.addError=addError;self.postApplyError=postApplyError}
}
public struct WorkingTreePatchBatchResult: Sendable {
    public let files: [WorkingTreePatchFileResult]
    public let cancelled: Bool
}

/// A current-file receipt, emitted before work; completedIndex counts only
/// settled distinct paths. Original fileIDs and exact path bytes are retained.
public struct WorkingTreePatchProgress:Sendable {
    public let fileID:Int,pathBytes:Data,completedIndex:Int,total:Int
    public init(fileID:Int,pathBytes:Data,completedIndex:Int,total:Int) {self.fileID=fileID;self.pathBytes=pathBytes;self.completedIndex=completedIndex;self.total=total}
}

extension GitRepository {
    /// FilePatchesDlg patches in list order, reports a failed file and continues.
    /// Whole checked-file application remains a separate, atomic Git operation.
    public func applyWorkingTreePatchBatch(_ review: WorkingTreePatchReview, fileIDs: Set<Int>, mergeConfiguration:SubversionMergeConfiguration? = nil,autoAddNewFiles:Bool=false,textEncodingPolicy:MergeTextEncodingPolicy? = nil, cancellation: OperationCancellation? = nil,
        onProgress:(@Sendable(WorkingTreePatchProgress)->Void)?=nil,onResult: (@Sendable (WorkingTreePatchFileResult) -> Void)? = nil) throws -> WorkingTreePatchBatchResult {
        guard review.repositoryRoot == root, !fileIDs.isEmpty,
              fileIDs.isSubset(of: Set(review.files.map(\.id))) else { throw WorkingTreePatchFailure.review }
        func matchingTextChange(_ review:WorkingTreePatchReview,file:WorkingTreePatchReview.File)->Bool {
            review.files.contains{$0.pathBytes==file.pathBytes && (($0.additions ?? 0)>0 || ($0.deletions ?? 0)>0)}
        }
        let total=Set(review.files.filter{fileIDs.contains($0.id)}.map(\.pathBytes)).count
        var advancingReview = review
        var seen = Set<Data>(), results: [WorkingTreePatchFileResult] = []
        for file in review.files where fileIDs.contains(file.id) && seen.insert(file.pathBytes).inserted {
            if cancellation?.isCancelled == true { return .init(files: results, cancelled: true) }
            onProgress?(.init(fileID:file.id,pathBytes:file.pathBytes,completedIndex:results.count,total:total))
            if cancellation?.isCancelled==true {return .init(files:results,cancelled:true)}
            // Multiple patch records for one path must be applied together.
            let ids = Set(review.files.filter { $0.pathBytes == file.pathBytes }.map(\.id))
            var result: WorkingTreePatchFileResult
            var acceptedOutputs: GitPathMap<ComparisonFileContent>?
            do {
                let selected = try reviewWorkingTreePatchFiles(advancingReview, fileIDs: ids, cancellation: cancellation)
                if let failure = selected.validationError {
                    if let mergeConfiguration {
                        let comparison = try compareWorkingTreePatchFile(advancingReview,fileID:file.id,textEncodingPolicy:textEncodingPolicy,cancellation:cancellation)
                        if comparison.recoveryKind != .text {
                            result = .init(pathBytes:file.pathBytes,success:false,output:"Preview this file to choose its current or patched state.\n" + failure,requiresMerge:true)
                            results.append(result);onResult?(result)
                            if cancellation?.isCancelled == true {return .init(files:results,cancelled:true)}
                            continue
                        }
                        let merged = try comparison.patchMergeDocument(engine:mergeConfiguration,cancellation:cancellation)
                        if MergeText.conflicts(in:merged.initialResult,document:merged).isEmpty && merged.mergeSources?.ignoredConflicts.isEmpty != false {
                            let saved = try saveWorkingTreePatchFile(comparison,text:merged.initialResult,encoding:merged.encoding,autoAddNewFiles:autoAddNewFiles,cancellation:cancellation)
                            if selected.decodedPatch != nil {
                                acceptedOutputs = comparison.outputs
                                acceptedOutputs?[saved.document.destination.path] = saved.document.destination
                            }
                            result = .init(pathBytes:file.pathBytes,success:true,output:"Merged patch with its recorded base.\n" + saved.output,addError:saved.addError,postApplyError:saved.postApplyError)
                        } else {result = .init(pathBytes:file.pathBytes,success:false,output:"The patch needs a three-way merge. Preview this file to resolve its conflicts.\n" + failure,requiresMerge:true)}
                    } else {result = .init(pathBytes: file.pathBytes, success: false, output: failure)}
                } else {
                    guard let path=String(data:file.pathBytes,encoding:.utf8) else{throw WorkingTreePatchFailure.pathEncoding}
                    let location=try workingTreePatchLocation(path)
                    let missing=(try? FileManager.default.attributesOfItem(atPath:location.path)) == nil
                    var output: String
                    var postApplyError: String?
                    if selected.decodedPatch != nil {
                        let comparison = try decodedWorkingTreePatchComparison(selected, fileID: nil, allowRecovery: false, cancellation: cancellation)
                        acceptedOutputs = comparison.outputs
                        let saved = try savePatchOutputs(comparison, outputs: comparison.outputs, autoAddNewFiles: false, message: "Applied decoded text patch.\n", cancellation: cancellation)
                        output = saved.output
                        postApplyError = saved.postApplyError
                    } else {
                        output = try applyWorkingTreePatch(selected, cancellation: cancellation)
                    }
                    // Source PatchSave deletes zero logical text records, even
                    // a BOM-only regular file; a terminated blank line is kept.
                    let changesText=matchingTextChange(review,file:file)
                    if postApplyError == nil,changesText,let content=try? WorkingFileComparison.workingContent(at:location),["100644","100755"].contains(content.mode ?? ""),content.text?.isEmpty == true {
                        do{try cancellation?.check();try FileManager.default.removeItem(at:location);acceptedOutputs?[path]=ComparisonFileContent(path:path,revision:.workingTree,bytes:Data(),mode:nil,isDeleted:true)}
                        catch{postApplyError=error.localizedDescription;output += "Patch applied; empty-result cleanup did not finish: \(error.localizedDescription)\n"}
                    }
                    var addError:String?
                    if postApplyError==nil,autoAddNewFiles,review.isGitWorkingTree,missing,let content=try? WorkingFileComparison.workingContent(at:location),content.mode != nil {
                        do{_=try stage([path],cancellation:cancellation);output += "Added \(path) to Git.\n"}
                        catch{addError=error.localizedDescription}
                    }
                    result = .init(pathBytes: file.pathBytes, success: true, output: output,addError:addError,postApplyError:postApplyError)
                }
            } catch {
                let needsFormat:Bool
                if case FileComparisonEditFailure.encoding = error {needsFormat=true} else {needsFormat=false}
                result = .init(pathBytes: file.pathBytes, success: false, output: error.localizedDescription,requiresMerge:needsFormat)
            }
            if result.success, result.postApplyError == nil, let acceptedOutputs {
                do { advancingReview = try recordingDecodedOutputs(acceptedOutputs, in: advancingReview, cancellation: cancellation) }
                catch { result = .init(pathBytes: result.pathBytes, success: true, output: result.output, addError: result.addError, postApplyError: result.postApplyError ?? error.localizedDescription) }
            }
            results.append(result); onResult?(result)
            if cancellation?.isCancelled == true { return .init(files: results, cancelled: true) }
        }
        return .init(files: results, cancelled: false)
    }
}

public enum WorkingTreePatchFailure: LocalizedError {
    case stripCount, review, metadata, selection, pathEncoding, symlinkTarget
    public var errorDescription: String? {
        switch self {
        case .stripCount: return "The patch path strip count must be nonnegative."
        case .review: return "Review an applicable patch against this target folder before applying it."
        case .metadata: return "Git returned incomplete patch file statistics."
        case .selection: return "Select complete files from this patch review before applying them."
        case .pathEncoding: return "Per-file application requires UTF-8 paths. The original patch can still be applied as a whole."
        case .symlinkTarget:return "This symbolic-link target cannot be represented as a macOS path."
        }
    }
}

extension GitRepository {
    public func reviewWorkingTreePatch(_ bytes: Data, reversed: Bool = false, stripCount: Int = 1, directoryMode: Bool = false, isGitWorkingTree: Bool = true, textEncodingPolicy: MergeTextEncodingPolicy? = nil, cancellation: OperationCancellation? = nil) throws -> WorkingTreePatchReview {
        try cancellation?.check()
        guard stripCount >= 0 else { throw WorkingTreePatchFailure.stripCount }
        let policy = textEncodingPolicy ?? .init(preferUTF8: true)
        var gitReview: WorkingTreePatchReview?, gitFailure: Error?
        do {
            let reviewed = try gitWorkingTreePatchReview(bytes, reversed: reversed, stripCount: stripCount, includePatterns: [], directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, textEncodingPolicy: textEncodingPolicy, cancellation: cancellation)
            if reviewed.canApply { return reviewed }
            gitReview = reviewed
        } catch { try cancellation?.check(); gitFailure = error }
        // A decoded source adapter is chosen only after the original Git path
        // rejects the patch. Binary/combined/special records stay on Git.
        if SourceTextPatch.recognizedTextEligibility(bytes: bytes, textEncodingPolicy: policy) {
            do {
                let parsed = try SourceTextPatch.parse(bytes: bytes, textEncodingPolicy: policy, cancellation: cancellation).strippingPaths(stripCount)
                let patch = reversed ? parsed.reversed : parsed
                return try decodedWorkingTreePatchReview(patch, reversed: reversed, stripCount: stripCount, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, policy: policy, cancellation: cancellation)
            } catch SourceTextPatchFailure.opaque { /* Preserve an opaque Git receipt/error. */ }
            catch {
                try cancellation?.check()
                // Git may accept standard syntax that pinned CPatch does not
                // (including omitted-count quirks). Keep its failed check and
                // recorded-base recovery instead of replacing that receipt.
                if let gitReview { return gitReview }
                throw error
            }
        }
        if let gitReview { return gitReview }
        throw gitFailure ?? WorkingTreePatchFailure.review
    }
    /// A failed whole-patch check does not prevent reviewing an applicable subset.
    public func reviewWorkingTreePatchFiles(_ review: WorkingTreePatchReview, fileIDs: Set<Int>, cancellation: OperationCancellation? = nil) throws -> WorkingTreePatchReview {
        try cancellation?.check()
        guard review.repositoryRoot == root else { throw WorkingTreePatchFailure.review }
        let selected = review.files.filter { fileIDs.contains($0.id) }
        guard !selected.isEmpty, selected.count == fileIDs.count else { throw WorkingTreePatchFailure.selection }
        let paths = Set(selected.map(\.pathBytes))
        // --include chooses a complete path, so every repeated record for that
        // path must be selected rather than silently applying unchecked records.
        guard review.files.filter({ paths.contains($0.pathBytes) }).count == selected.count else { throw WorkingTreePatchFailure.selection }
        if review.decodedPatch != nil {
            let candidate = WorkingTreePatchReview(files: selected, document: review.document, statistics: review.statistics, summary: review.summary, validationError: nil, isGitWorkingTree: review.isGitWorkingTree, textEncodingPolicy: review.textEncodingPolicy, decodedPatch: review.decodedPatch, decodedInputs: review.decodedInputs, directoryMode: review.directoryMode, repositoryRoot: review.repositoryRoot, reversed: review.reversed, stripCount: review.stripCount, includePatterns: [])
            var failure: String?
            do { _ = try decodedWorkingTreePatchComparison(candidate, fileID: nil, allowRecovery: false, cancellation: cancellation) }
            catch { try cancellation?.check(); failure = selected.map(\.path).joined(separator: ", ") + ": " + error.localizedDescription }
            return candidate.replacingValidationError(failure)
        }
        let patterns = try selected.map { file -> String in
            guard let path = String(data: file.pathBytes, encoding: .utf8) else { throw WorkingTreePatchFailure.pathEncoding }
            return String(decoding:path.utf8.flatMap {byte -> [UInt8] in [42,63,91,93,92].contains(byte) ? [92,byte]:[byte]},as:UTF8.self)
        }
        let filtered = try gitWorkingTreePatchReview(review.document.bytes, reversed: review.reversed, stripCount: review.stripCount, includePatterns: patterns, directoryMode: review.directoryMode, isGitWorkingTree: review.isGitWorkingTree, textEncodingPolicy: review.textEncodingPolicy, cancellation: cancellation)
        guard filtered.files.count == selected.count, Set(filtered.files.map(\.pathBytes)) == paths else { throw WorkingTreePatchFailure.selection }
        return filtered
    }
    private func gitWorkingTreePatchReview(_ bytes: Data, reversed: Bool, stripCount: Int, includePatterns: [String], directoryMode: Bool, isGitWorkingTree: Bool, textEncodingPolicy: MergeTextEncodingPolicy?, cancellation: OperationCancellation?) throws -> WorkingTreePatchReview {
        try cancellation?.check()
        guard stripCount >= 0 else { throw WorkingTreePatchFailure.stripCount }
        return try withPatchTarget(bytes, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, cancellation: cancellation) { file, execute in
            let arguments = ["apply", "-p\(stripCount)"] + (reversed ? ["--reverse"] : []) + includePatterns.map { "--include=" + $0 }
            let statistics = try execute(arguments + ["--stat", "--", file.path]).text
            let summary = try execute(arguments + ["--summary", "--", file.path]).text
            let files = try WorkingTreePatchReview.parseFiles(execute(arguments + ["--numstat", "-z", "--", file.path]).stdout)
            var failure: String?
            do { _ = try execute(arguments + ["--check", "--", file.path]) }
            catch let error as GitFailure { failure = error.localizedDescription }
            return WorkingTreePatchReview(files: files, document: UnifiedDiffDocument(bytes: bytes, displayLegacyEncoding: textEncodingPolicy?.legacyEncoding ?? .windows1252), statistics: statistics, summary: summary, validationError: failure, isGitWorkingTree: isGitWorkingTree, textEncodingPolicy: textEncodingPolicy, decodedPatch: nil, decodedInputs: nil, directoryMode: directoryMode, repositoryRoot: root, reversed: reversed, stripCount: stripCount, includePatterns: includePatterns)
        }
    }
    public func applyWorkingTreePatch(_ review: WorkingTreePatchReview, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard review.repositoryRoot == root, review.canApply else { throw WorkingTreePatchFailure.review }
        if review.decodedPatch != nil {
            let comparison = try decodedWorkingTreePatchComparison(review, fileID: nil, allowRecovery: false, cancellation: cancellation)
            return try savePatchOutputs(comparison, outputs: comparison.outputs, autoAddNewFiles: false, message: "Applied decoded text patch.\n", cancellation: cancellation).output
        }
        return try withPatchTarget(review.document.bytes, directoryMode: review.directoryMode, isGitWorkingTree: review.isGitWorkingTree, cancellation: cancellation) { file, execute in
            let arguments = ["apply", "-p\(review.stripCount)"] + (review.reversed ? ["--reverse"] : []) + review.includePatterns.map { "--include=" + $0 }
            // Revalidate against current files, then let Git validate again when
            // applying. No --index/--cached/--reject or unsafe-path override.
            _ = try execute(arguments + ["--check", "--", file.path])
            return try execute(arguments + ["--", file.path]).text
        }
    }
    /// Anchor single-patch paths to the chosen directory even when it is a
    /// nested Git folder. The disposable Git administration area never borrows
    /// or writes the real index, and is removed after each complete operation.
    func withPatchTarget<T>(_ bytes: Data, directoryMode: Bool, isGitWorkingTree: Bool, cancellation: OperationCancellation? = nil, _ operation: (URL, ([String]) throws -> GitResult) throws -> T) throws -> T {
        try withWorkingTreePatch(bytes) { file in
            if !directoryMode { return try operation(file, { try self.run(["-c","core.precomposeunicode=false"] + $0, cancellation: cancellation) }) }
            let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitPatchTarget-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let gitDirectory = temporary.appendingPathComponent(".git").path
            let environment = ["GIT_DIR": gitDirectory, "GIT_COMMON_DIR": gitDirectory, "GIT_WORK_TREE": root.path,
                "GIT_INDEX_FILE": gitDirectory + "/index", "GIT_OBJECT_DIRECTORY": gitDirectory + "/objects", "GIT_ALTERNATE_OBJECT_DIRECTORIES": ""]
            let location = ["-c","core.precomposeunicode=false","--git-dir=" + gitDirectory, "--work-tree=" + root.path]
            _ = try run(location + ["init", "--template=", "--object-format=sha1"], environmentOverrides: environment, cancellation: cancellation)
            var configuration: [String] = []
            for key in ["apply.whitespace", "apply.ignoreWhitespace", "core.whitespace"] {
                let value = try run(["config"] + (isGitWorkingTree ? [] : ["--global"]) + ["--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
                if value.exitCode == 0 { configuration += ["-c", key + "=" + value.text.trimmingCharacters(in: .newlines)] }
            }
            return try operation(file, { try self.run(location + configuration + $0, environmentOverrides: environment, cancellation: cancellation) })
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

/// Exact current and patched bytes. Temporary files are discarded before return.
public struct WorkingTreePatchFileComparison: Sendable {
    public let document: FileComparisonDocument
    public let fileID: Int
    fileprivate let review: WorkingTreePatchReview
    fileprivate let inputs: GitPathMap<ComparisonFileContent>
    fileprivate let outputs: GitPathMap<ComparisonFileContent>
    // Save As may write one of our input paths without applying the patch.
    // Keep the original inputs for new-file Add policy and historical panes;
    // only these measured owned writes replace subsequent stale-write guards.
    fileprivate var ownedWrites = GitPathMap<ComparisonFileContent>()
    public func recordingOwnedWrite(_ saved:SavedMergePane) -> Self {
        var next=self
        for (path,_) in inputs {
            let location=FileTransferPaths.fileURL(review.repositoryRoot.path+"/"+path).standardizedFileURL
            if GitReferenceName.equal(location.path,saved.url.path) {
                let content=saved.content
                next.ownedWrites[path]=ComparisonFileContent(path:path,revision:.workingTree,bytes:content.bytes,mode:content.mode,permissions:content.permissions,encoding:content.encoding,isDeleted:content.isDeleted)
            }
        }
        return next
    }
    fileprivate var currentInputs:GitPathMap<ComparisonFileContent> {
        var current=inputs
        for (path,content) in ownedWrites {current[path]=content}
        return current
    }
    /// Recorded version-control base used when the working file rejects the patch.
    public let recoveryBase: ComparisonFileContent?
    public let textEncodingPolicy:MergeTextEncodingPolicy?
    public var requiresMerge:Bool { recoveryBase != nil }
    public enum RecoveryKind:String,Sendable {case text,binary,symbolicLink,deletion}
    public var recoveryKind:RecoveryKind? {
        guard let recoveryBase else {return nil}
        let current = document.base,patched = document.destination
        if current.mode == nil || patched.mode == nil {return .deletion}
        if [recoveryBase.mode,current.mode,patched.mode].contains("120000") {return .symbolicLink}
        if recoveryBase.text == nil || current.text == nil || patched.text == nil {return .binary}
        return .text
    }
    public var editingDocument: FileComparisonDocument {
        let base = document.base
        return FileComparisonDocument(base: ComparisonFileContent(path: base.path, revision: .revision("Before patch"), bytes: base.bytes, mode: base.mode, permissions: base.permissions, encoding: base.encoding), destination: document.destination)
    }
    public var snapshot: RevisionComparisonSnapshot {
        let file = CommitFile(path: document.destination.path, oldPath: document.base.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        return RevisionComparisonSnapshot(root: review.repositoryRoot, from: .revision("Before patch"), to: .workingTree, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
    }
}

extension GitRepository {
    private func workingTreePatchLocation(_ path:String) throws ->URL {
        _ = try restoreLocation(path)
        return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(root.path + "/" + path))
    }
    public func compareWorkingTreePatchFile(_ review: WorkingTreePatchReview, fileID: Int,textEncodingPolicy:MergeTextEncodingPolicy? = nil, cancellation: OperationCancellation? = nil) throws -> WorkingTreePatchFileComparison {
        try cancellation?.check()
        guard review.repositoryRoot == root, review.includePatterns.isEmpty,
              let file = review.files.first(where: { $0.id == fileID }) else { throw WorkingTreePatchFailure.selection }
        if review.decodedPatch != nil {
            return try decodedWorkingTreePatchComparison(review, fileID: fileID, allowRecovery: true, cancellation: cancellation)
        }
        let textEncodingPolicy: MergeTextEncodingPolicy? = textEncodingPolicy ?? review.textEncodingPolicy
        let matching = review.files.filter { $0.pathBytes == file.pathBytes }
        let selected = try reviewWorkingTreePatchFiles(review, fileIDs: Set(matching.map(\.id)), cancellation: cancellation)
        // An initially applicable review cannot silently adopt later conflicts.
        // Refresh captures a new failing review before recorded-base recovery.
        guard !review.canApply || selected.canApply else {throw WorkingTreePatchFailure.review}
        return try withPatchTarget(review.document.bytes, directoryMode: review.directoryMode, isGitWorkingTree: review.isGitWorkingTree,cancellation:cancellation) { patch, execute in
            // Opposite-direction numstat names the preimage of each record,
            // including renames, without parsing human-readable quoted headers.
            // Git reverses record order as well as patch direction.
            let opposite = try Array(WorkingTreePatchReview.parseFiles(execute(["apply", "-p\(review.stripCount)"] + (review.reversed ? [] : ["--reverse"]) + ["--numstat", "-z", "--", patch.path]).stdout).reversed())
            guard opposite.count == review.files.count else { throw WorkingTreePatchFailure.metadata }
            func path(_ bytes: Data) throws -> String {
                guard let value = String(data: bytes, encoding: .utf8) else { throw WorkingTreePatchFailure.pathEncoding }
                _ = try workingTreePatchLocation(value)
                return value
            }
            let destination = try path(file.pathBytes), source = try path(opposite[file.id].pathBytes)
            let paths = try GitPathSet(matching.flatMap { record in [try path(record.pathBytes), try path(opposite[record.id].pathBytes)] }).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let manager = FileManager.default
            let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitPatchComparison-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: temporary) }
            func checkParents(_ location: URL, anchor: URL) throws {
                var parent = location.deletingLastPathComponent()
                while !GitReferenceName.equal(parent.path,anchor.path) {
                    guard parent.path.utf8.starts(with:(anchor.path + "/").utf8) else { throw WorkingFileRestoreFailure.location }
                    do {
                        let attributes = try manager.attributesOfItem(atPath: parent.path)
                        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw WorkingFileRestoreFailure.location }
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
                    parent.deleteLastPathComponent()
                }
            }
            func read(_ location: URL, path: String, anchor: URL) throws -> ComparisonFileContent {
                try checkParents(location, anchor: anchor)

                do { _ = try manager.attributesOfItem(atPath: location.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    return ComparisonFileContent(path: path, revision: .workingTree, bytes: Data(), mode: nil)
                }
                let value = try WorkingFileComparison.workingContent(at: location)
                let content=ComparisonFileContent(path:path,revision:.workingTree,bytes:value.bytes,mode:value.mode,permissions:value.permissions)
                return textEncodingPolicy?.applying(content) ?? content
            }
            var before: ComparisonFileContent?
            var inputs: GitPathMap<ComparisonFileContent> = [:]
            for name in paths {
                try cancellation?.check()
                let location = try workingTreePatchLocation(name), value = try read(location, path: name, anchor: root)
                inputs[name] = value
                if GitReferenceName.equal(name,source) { before = value }
                guard value.mode != nil else { continue }
                let copy = FileTransferPaths.fileURL(temporary.path + "/" + name)
                try checkParents(copy, anchor: temporary)
                try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                if value.mode == "120000" {
                    try manager.createSymbolicLink(atPath: copy.path, withDestinationPath: manager.destinationOfSymbolicLink(atPath: location.path))
                } else {
                    try value.bytes.write(to: copy, options: .withoutOverwriting)
                    try manager.setAttributes([.posixPermissions: value.permissions ?? 0o600], ofItemAtPath: copy.path)
                }
            }
            let gitDirectory = temporary.appendingPathComponent(".git").path
            let environment = ["GIT_DIR": gitDirectory, "GIT_COMMON_DIR": gitDirectory, "GIT_WORK_TREE": temporary.path, "GIT_INDEX_FILE": temporary.appendingPathComponent(".git/index").path]
            let location = ["-c","core.precomposeunicode=false","-C", temporary.path, "--git-dir=" + gitDirectory, "--work-tree=" + temporary.path]
            let format = review.isGitWorkingTree ? try run(["rev-parse", "--show-object-format"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) : "sha1"
            _ = try run(location + ["init", "--template=", "--object-format=" + format], environmentOverrides: environment, cancellation: cancellation)
            // Match repository-local apply policy, including whitespace fixing.
            var configuration: [String] = []
            for key in ["apply.whitespace", "apply.ignoreWhitespace", "core.whitespace"] {
                let value = try run(["config"] + (review.isGitWorkingTree ? [] : ["--global"]) + ["--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
                if value.exitCode == 0 { configuration += ["-c", key + "=" + value.text.trimmingCharacters(in: .newlines)] }
            }
            let arguments = location + configuration + ["apply", "-p\(review.stripCount)"] + (review.reversed ? ["--reverse"] : []) + selected.includePatterns.map { "--include=" + $0 }
            var recoveryBase:ComparisonFileContent?
            do {_ = try run(arguments + ["--check", "--", patch.path], environmentOverrides: environment, cancellation: cancellation)}
            catch let directFailure as GitFailure {
                // GitPatch::PatchFile retries against the blob named by the
                // index header, never HEAD or a guessed revision. All writes
                // here stay inside the disposable comparison workspace.
                guard review.isGitWorkingTree else {throw directFailure}
                let records = GitPatch(bytes:review.document.bytes).files
                guard records.count == review.files.count else {throw directFailure}
                for name in paths {
                    let copy = FileTransferPaths.fileURL(temporary.path + "/" + name)
                    try checkParents(copy,anchor:temporary)
                    if (try? manager.attributesOfItem(atPath:copy.path)) != nil {try manager.removeItem(at:copy)}
                }
                var seeded = GitPathSet()
                for record in matching {
                    try cancellation?.check()
                    let index = review.reversed ? records.count - 1 - record.id : record.id
                    guard records.indices.contains(index),let line = records[index].header.first(where:{$0.hasPrefix("index ")}) else {throw directFailure}
                    let fields = line.split(separator:" "),pair = fields.count > 1 ? fields[1].components(separatedBy:"..") : []
                    guard pair.count == 2 else {throw directFailure}
                    let object = pair[review.reversed ? 1 : 0]
                    guard (7...64).contains(object.utf8.count),object.utf8.allSatisfy({(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)}) else {throw directFailure}
                    let name = try path(opposite[record.id].pathBytes)
                    guard seeded.insert(name).inserted else {continue}
                    let modePrefixes = review.reversed ? ["new mode ","new file mode "] : ["old mode ","deleted file mode "]
                    let recordedMode = modePrefixes.lazy.compactMap {prefix in records[index].header.first(where:{$0.hasPrefix(prefix)}).map {String($0.dropFirst(prefix.count))}}.first
                    let mode = recordedMode ?? (fields.count > 2 ? String(fields[2]) : inputs[name]?.mode ?? "100644")
                    guard ["100644","100755","120000"].contains(mode) else {throw directFailure}
                    let baseBytes = object.allSatisfy({$0 == "0"}) ? Data() : try run(["cat-file","blob",object],environmentOverrides:["GIT_NO_LAZY_FETCH":"1"],cancellation:cancellation).stdout
                    let rawBase = ComparisonFileContent(path:name,revision:.revision(object),bytes:baseBytes,mode:mode,permissions:inputs[name]?.permissions ?? (mode == "100755" ? 0o755 : 0o644))
                    let base=textEncodingPolicy?.applying(rawBase) ?? rawBase
                    if GitReferenceName.equal(name,source) {recoveryBase = base}
                    if !object.allSatisfy({$0 == "0"}) {
                        let copy = FileTransferPaths.fileURL(temporary.path + "/" + name);try checkParents(copy,anchor:temporary)
                        try manager.createDirectory(at:copy.deletingLastPathComponent(),withIntermediateDirectories:true)
                        if mode == "120000" {
                            guard let target = String(data:baseBytes,encoding:.utf8),!target.contains("\0") else {throw WorkingTreePatchFailure.symlinkTarget}
                            try manager.createSymbolicLink(atPath:copy.path,withDestinationPath:target)
                        } else {
                            try baseBytes.write(to:copy,options:.withoutOverwriting)
                            try manager.setAttributes([.posixPermissions:base.permissions!],ofItemAtPath:copy.path)
                        }
                    }
                }
                guard recoveryBase != nil else {throw directFailure}
                _ = try run(arguments + ["--check","--",patch.path],environmentOverrides:environment,cancellation:cancellation)
            }
            _ = try run(arguments + ["--", patch.path], environmentOverrides: environment, cancellation: cancellation)
            guard let before else { throw WorkingTreePatchFailure.metadata }
            try cancellation?.check()
            let outputs = try GitPathMap(uniqueKeysWithValues: paths.map { ($0, try read(FileTransferPaths.fileURL(temporary.path + "/" + $0), path: $0, anchor: temporary)) })
            return WorkingTreePatchFileComparison(document: FileComparisonDocument(base: before, destination: outputs[destination]!), fileID: fileID, review: selected, inputs: inputs, outputs: outputs,recoveryBase:recoveryBase,textEncodingPolicy:textEncodingPolicy)
        }
    }
}


public enum WorkingTreePatchResolutionChoice:String,CaseIterable,Sendable {case current,patched}

public struct WorkingTreePatchSaveResult: Sendable {
    public let document: FileComparisonDocument
    public let output: String
    /// Saving succeeded even if the optional subsequent Add failed.
    public let addError: String?
    /// Bytes were published, but subsequent permission verification did not finish.
    public let postApplyError: String?
}

extension GitRepository {
    public func saveWorkingTreePatchFile(_ comparison: WorkingTreePatchFileComparison, text: String, encoding: ComparisonTextEncoding? = nil, autoAddNewFiles: Bool = true, options:MergeFileSaveOptions?=nil,cancellation: OperationCancellation? = nil) throws -> WorkingTreePatchSaveResult {
        try cancellation?.check()
        let destination = comparison.document.destination
        guard comparison.review.repositoryRoot == root, ["100644", "100755"].contains(destination.mode ?? "") else {throw FileComparisonEditFailure.unsupported}
        let bytes = try FileComparisonEditing.encoded(text,like:destination,encoding:encoding)
        var outputs = comparison.outputs
        // nil is automatic PatchSave; explicit FileSave carries the accepted
        // empty-file answer and captured Backup preference from the editor.
        if let options,options.emptyResult == .delete,!text.isEmpty {throw MergeFileSaveFailure.nonemptyDeletion}
        let deleting=text.isEmpty && (options?.emptyResult ?? .delete) == .delete
        outputs[destination.path] = ComparisonFileContent(path:destination.path,revision:.workingTree,bytes:deleting ? Data():bytes,mode:deleting ? nil:destination.mode,permissions:deleting ? nil:destination.permissions,encoding:encoding ?? destination.encoding,isDeleted:deleting)
        return try savePatchOutputs(comparison,outputs:outputs,autoAddNewFiles:autoAddNewFiles,backupOriginal:options?.backupOriginal ?? false,message:"Saved patched result.\n",cancellation:cancellation)
    }
    public func resolveWorkingTreePatchFile(_ comparison:WorkingTreePatchFileComparison,choice:WorkingTreePatchResolutionChoice,autoAddNewFiles:Bool = true,cancellation:OperationCancellation? = nil) throws -> WorkingTreePatchSaveResult {
        guard comparison.review.repositoryRoot == root,comparison.requiresMerge,comparison.recoveryKind != .text else {throw WorkingTreePatchFailure.review}
        let chosen = choice == .current ? comparison.inputs : comparison.outputs
        let outputs = chosen.mapValues {content in ComparisonFileContent(path:content.path,revision:.workingTree,bytes:content.bytes,mode:content.mode,permissions:content.permissions,encoding:content.encoding,isDeleted:content.mode == nil)}
        return try savePatchOutputs(comparison,outputs:outputs,autoAddNewFiles:choice == .patched && autoAddNewFiles,message:choice == .current ? "Kept current working files and paths.\n" : "Saved the selected patched file state.\n",cancellation:cancellation)
    }
    private func savePatchOutputs(_ comparison:WorkingTreePatchFileComparison,outputs:GitPathMap<ComparisonFileContent>,autoAddNewFiles:Bool,backupOriginal:Bool=false,message:String,cancellation:OperationCancellation?) throws -> WorkingTreePatchSaveResult {
        try cancellation?.check()
        guard comparison.review.repositoryRoot == root,let destination = outputs[comparison.document.destination.path] else {throw WorkingTreePatchFailure.review}
        let inputs=comparison.currentInputs
        func validateInputs() throws {
            for (path, expected) in inputs {
                try cancellation?.check()
                let location = try workingTreePatchLocation(path)
                var parent = location.deletingLastPathComponent()
                while !GitReferenceName.equal(parent.path,root.path) {
                    guard parent.path.utf8.starts(with:(root.path + "/").utf8) else { throw WorkingFileRestoreFailure.location }
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw WorkingFileRestoreFailure.location }
                    parent.deleteLastPathComponent()
                }
                let current: ComparisonFileContent
                do { current = try WorkingFileComparison.workingContent(at: location) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    guard expected.mode == nil else { throw FileComparisonEditFailure.changed }; continue
                }
                guard current.bytes == expected.bytes, current.mode == expected.mode, current.permissions == expected.permissions else { throw FileComparisonEditFailure.changed }
            }
        }
        try validateInputs()
        let manager = FileManager.default, temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitPatchSave-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let gitDirectory = temporary.appendingPathComponent(".git").path
        let environment = ["GIT_DIR": gitDirectory, "GIT_COMMON_DIR": gitDirectory, "GIT_WORK_TREE": temporary.path, "GIT_INDEX_FILE": gitDirectory + "/index", "GIT_OBJECT_DIRECTORY": gitDirectory + "/objects", "GIT_ALTERNATE_OBJECT_DIRECTORIES": ""]
        let location = ["-c","core.precomposeunicode=false","-C", temporary.path, "--git-dir=" + gitDirectory, "--work-tree=" + temporary.path]
        let format = comparison.review.isGitWorkingTree ? try run(["rev-parse", "--show-object-format"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) : "sha1"
        _ = try run(location + ["init", "--template=", "--object-format=" + format], environmentOverrides: environment, cancellation: cancellation)
        func tree(_ contents: GitPathMap<ComparisonFileContent>) throws -> String {
            _ = try run(location + ["read-tree", "--empty"], environmentOverrides: environment, cancellation: cancellation)
            for (path, content) in contents.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
                try cancellation?.check()
                guard let mode = content.mode else { continue }
                let payload = temporary.appendingPathComponent("payload")
                try content.bytes.write(to: payload, options: .atomic)
                let object = try run(location + ["hash-object", "-w", "--no-filters", "--", payload.path], environmentOverrides: environment, cancellation: cancellation).text.trimmingCharacters(in: .newlines)
                _ = try run(location + ["update-index", "--add", "--cacheinfo", mode + "," + object + "," + path], environmentOverrides: environment, cancellation: cancellation)
            }
            return try run(location + ["write-tree"], environmentOverrides: environment, cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        }
        let before = try tree(inputs), after = try tree(outputs)
        let patch = try run(location + ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", before, after], environmentOverrides: environment, cancellation: cancellation).stdout
        try validateInputs()
        let permissionRoot: Int32
        if comparison.review.decodedPatch != nil {
            permissionRoot = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard permissionRoot >= 0 else { throw FileComparisonEditFailure.changed }
        } else { permissionRoot = -1 }
        defer { if permissionRoot >= 0 { Darwin.close(permissionRoot) } }
        var output = message
        func backupDestination()throws {
            guard backupOriginal,let original=inputs[destination.path],["100644","100755"].contains(original.mode ?? "") else{return}
            let target=try workingTreePatchLocation(destination.path)
            try MergeWorkingFileSave.backup(at:target,original:original.bytes,permissions:original.permissions ?? 0o644,validate:validateInputs)
        }
        if !patch.isEmpty {
            output += try withPatchTarget(patch, directoryMode: comparison.review.directoryMode, isGitWorkingTree: comparison.review.isGitWorkingTree, cancellation: cancellation) { file, execute in
                // Save edited bytes exactly; repository whitespace-fix policy was
                // already reflected in the initial patched preview.
                let arguments = ["apply", "--whitespace=nowarn"]
                _ = try execute(arguments + ["--check", "--", file.path])
                try validateInputs()
                try backupDestination()
                try validateInputs()
                return try execute(arguments + ["--", file.path]).text
            }
        } else {try backupDestination()}
        var postApplyError: String?
        if permissionRoot >= 0 {
            do { try restoreDecodedPatchPermissions(rootDescriptor: permissionRoot, inputs: inputs, outputs: outputs, cancellation: cancellation) }
            catch {
                postApplyError = error.localizedDescription
                output += "Patch saved; permission verification did not finish: \(error.localizedDescription)\n"
            }
        }
        var addError: String?
        if postApplyError == nil, autoAddNewFiles, comparison.review.isGitWorkingTree, comparison.inputs[destination.path]?.mode == nil, destination.mode != nil {
            do { _ = try stage([destination.path], cancellation: cancellation); output += "Added \(destination.path) to Git.\n" }
            catch { addError = error.localizedDescription }
        }
        let savedDocument = FileComparisonDocument(base: comparison.editingDocument.base, destination: outputs[destination.path]!)
        return WorkingTreePatchSaveResult(document: savedDocument, output: output, addError: addError, postApplyError: postApplyError)
    }
}


public struct WorkingTreePatchFileInspection:Sendable {
    public enum State:String,Sendable {case ready,conflict,error}
    public let state:State
    public let diagnostic:String
}
extension GitRepository {
    /// Source FilePatchesDlg initializes every row from a dry-run result.
    public func inspectWorkingTreePatchFiles(_ review:WorkingTreePatchReview,excluding:Set<Data> = [],textEncodingPolicy:MergeTextEncodingPolicy? = nil,cancellation:OperationCancellation? = nil) throws -> [Data:WorkingTreePatchFileInspection] {
        try cancellation?.check()
        guard review.repositoryRoot == root,review.includePatterns.isEmpty else {throw WorkingTreePatchFailure.review}
        var result:[Data:WorkingTreePatchFileInspection] = [:]
        for file in review.files where result[file.pathBytes] == nil && !excluding.contains(file.pathBytes) {
            try cancellation?.check()
            if review.canApply {result[file.pathBytes] = .init(state:.ready,diagnostic:"");continue}
            try cancellation?.check()
            do {
                let comparison = try compareWorkingTreePatchFile(review,fileID:file.id,textEncodingPolicy:textEncodingPolicy,cancellation:cancellation)
                result[file.pathBytes] = .init(state:comparison.requiresMerge ? .conflict : .ready,diagnostic:comparison.requiresMerge ? (comparison.recoveryKind == .text ? "The current file differs from the patch base. Preview to merge the recorded base, current file and patched file." : "Preview to choose the current or patched file state.") : "")
            } catch {
                try cancellation?.check()
                result[file.pathBytes] = .init(state:.error,diagnostic:error.localizedDescription)
            }
        }
        return result
    }
}

// Decoded CPatch adapter. Original Git successes never enter this path; checked
// generated binary diffs remain the only filesystem publication mechanism.
private extension WorkingTreePatchReview {
    func replacingValidationError(_ failure: String?) -> Self {
        Self(files: files, document: document, statistics: statistics, summary: summary, validationError: failure,
             isGitWorkingTree: isGitWorkingTree, textEncodingPolicy: textEncodingPolicy,
             decodedPatch: decodedPatch, decodedInputs: decodedInputs, directoryMode: directoryMode,
             repositoryRoot: repositoryRoot, reversed: reversed, stripCount: stripCount, includePatterns: includePatterns)
    }
}

private extension GitRepository {
    func recordingDecodedOutputs(_ expected: GitPathMap<ComparisonFileContent>, in review: WorkingTreePatchReview, cancellation: OperationCancellation?) throws -> WorkingTreePatchReview {
        guard review.decodedPatch != nil, var recorded = review.decodedInputs else { return review }
        let policy = review.textEncodingPolicy ?? .init(preferUTF8: true)
        for (path, output) in expected {
            let actual = try decodedPatchInput(path, policy: policy, cancellation: cancellation)
            let exactPermissions = actual.permissions == output.permissions
            // Git creates absent paths under the inherited umask. Retain that
            // measured restricted receipt only for our newly created target;
            // existing paths keep the exact pre-write permission guard.
            let createdUnderMask = recorded[path]?.mode == nil && actual.mode != nil && actual.permissions.map { value in output.permissions.map { value & $0 == value } ?? false } == true
            guard actual.bytes == output.bytes, actual.mode == output.mode, exactPermissions || createdUnderMask else { throw FileComparisonEditFailure.changed }
            recorded[path] = actual
        }
        return WorkingTreePatchReview(files: review.files, document: review.document, statistics: review.statistics, summary: review.summary, validationError: review.validationError,
            isGitWorkingTree: review.isGitWorkingTree, textEncodingPolicy: review.textEncodingPolicy, decodedPatch: review.decodedPatch, decodedInputs: recorded,
            directoryMode: review.directoryMode, repositoryRoot: review.repositoryRoot, reversed: review.reversed, stripCount: review.stripCount, includePatterns: review.includePatterns)
    }
    func decodedPatchPath(_ bytes: Data) throws -> String {
        guard let path = String(data: bytes, encoding: .utf8) else { throw WorkingTreePatchFailure.pathEncoding }
        _ = try workingTreePatchLocation(path)
        return path
    }
    func decodedPatchInput(_ path: String, policy: MergeTextEncodingPolicy, cancellation: OperationCancellation?) throws -> ComparisonFileContent {
        try cancellation?.check()
        let location = try workingTreePatchLocation(path)
        var parent = location.deletingLastPathComponent()
        while !GitReferenceName.equal(parent.path, root.path) {
            guard parent.path.utf8.starts(with: (root.path + "/").utf8) else { throw WorkingFileRestoreFailure.location }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw WorkingFileRestoreFailure.location }
            parent.deleteLastPathComponent()
        }
        do {
            let value = try WorkingFileComparison.workingContent(at: location)
            guard ["100644", "100755"].contains(value.mode ?? "") else { throw SourceTextPatchFailure.opaque }
            return policy.applying(ComparisonFileContent(path: path, revision: .workingTree, bytes: value.bytes, mode: value.mode, permissions: value.permissions))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ComparisonFileContent(path: path, revision: .workingTree, bytes: Data(), mode: nil)
        }
    }
    func decodedWorkingTreePatchReview(_ patch: SourceTextPatch, reversed: Bool, stripCount: Int, directoryMode: Bool, isGitWorkingTree: Bool, policy: MergeTextEncodingPolicy, cancellation: OperationCancellation?) throws -> WorkingTreePatchReview {
        let files = patch.files.map { file in
            WorkingTreePatchReview.File(id: file.id, pathBytes: file.pathBytes,
                additions: file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count },
                deletions: file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count })
        }
        guard !files.isEmpty else { throw SourceTextPatchFailure.unrecognized }
        var inputs = GitPathMap<ComparisonFileContent>()
        for file in patch.files {
            try cancellation?.check()
            if reversed && file.copyFromPathBytes != nil { throw SourceTextPatchFailure.opaque }
            func agrees(_ role: Data?, _ raw: Data?) -> Bool {
                guard let role, let raw else { return false }
                return role == raw || ((raw.starts(with: [97,47]) || raw.starts(with: [98,47])) && role == Data(raw.dropFirst(2)))
            }
            let renaming = file.renameFromPathBytes != nil || file.renameToPathBytes != nil
            let copying = file.copyFromPathBytes != nil || file.copyToPathBytes != nil
            guard !(renaming && copying),
                  !renaming || (agrees(file.renameFromPathBytes, file.rawOldPathBytes) && agrees(file.renameToPathBytes, file.rawNewPathBytes)),
                  !copying || (agrees(file.copyFromPathBytes, file.rawOldPathBytes) && agrees(file.copyToPathBytes, file.rawNewPathBytes)) else { throw SourceTextPatchFailure.opaque }
            for bytes in [file.oldPathBytes, file.newPathBytes].compactMap({ $0 }) {
                let path = try decodedPatchPath(bytes)
                if inputs[path] == nil { inputs[path] = try decodedPatchInput(path, policy: policy, cancellation: cancellation) }
            }
        }
        let statistics = files.map { "\($0.path) | +\($0.additions ?? 0) -\($0.deletions ?? 0)" }.joined(separator: "\n")
        let candidate = WorkingTreePatchReview(files: files, document: patch.document, statistics: statistics, summary: "\(files.count) file(s) in decoded text patch.", validationError: nil,
            isGitWorkingTree: isGitWorkingTree, textEncodingPolicy: policy, decodedPatch: patch, decodedInputs: inputs,
            directoryMode: directoryMode, repositoryRoot: root, reversed: reversed, stripCount: stripCount, includePatterns: [])
        var failure: String?
        do { _ = try decodedWorkingTreePatchComparison(candidate, fileID: nil, allowRecovery: false, cancellation: cancellation) }
        catch { try cancellation?.check(); failure = error.localizedDescription }
        return candidate.replacingValidationError(failure)
    }
    func decodedWorkingTreePatchComparison(_ review: WorkingTreePatchReview, fileID: Int?, allowRecovery: Bool, cancellation: OperationCancellation?) throws -> WorkingTreePatchFileComparison {
        try cancellation?.check()
        guard review.repositoryRoot == root, let patch = review.decodedPatch else { throw WorkingTreePatchFailure.review }
        let policy = review.textEncodingPolicy ?? .init(preferUTF8: true)
        let wanted: [WorkingTreePatchReview.File]
        if let fileID {
            guard let selected = review.files.first(where: { $0.id == fileID }) else { throw WorkingTreePatchFailure.selection }
            wanted = review.files.filter { $0.pathBytes == selected.pathBytes }
        } else { wanted = review.files }
        let identifiers = Set(wanted.map(\.id)), records = patch.files.filter { identifiers.contains($0.id) }
        guard !records.isEmpty, records.count == wanted.count else { throw WorkingTreePatchFailure.selection }
        var inputs = GitPathMap<ComparisonFileContent>()
        for file in records {
            for bytes in [file.oldPathBytes, file.newPathBytes].compactMap({ $0 }) {
                try cancellation?.check()
                let path = try decodedPatchPath(bytes)
                guard inputs[path] == nil else { continue }
                let current = try decodedPatchInput(path, policy: policy, cancellation: cancellation)
                if let expected = review.decodedInputs?[path] {
                    guard current.bytes == expected.bytes, current.mode == expected.mode, current.permissions == expected.permissions else { throw FileComparisonEditFailure.changed }
                }
                inputs[path] = current
            }
        }
        var outputs = inputs, recoveryBase: ComparisonFileContent?
        let first = records[0], source = try decodedPatchPath(first.oldPathBytes ?? first.newPathBytes!), destination = try decodedPatchPath(first.newPathBytes ?? first.oldPathBytes!)
        for file in records {
            try cancellation?.check()
            guard !review.reversed || file.copyFromPathBytes == nil else { throw SourceTextPatchFailure.opaque }
            let beforePath = try decodedPatchPath(file.oldPathBytes ?? file.newPathBytes!)
            let afterPath = try decodedPatchPath(file.newPathBytes ?? file.oldPathBytes!)
            guard let before = outputs[beforePath], let after = outputs[afterPath] else { throw WorkingTreePatchFailure.metadata }
            let changingPath = !GitReferenceName.equal(beforePath, afterPath)
            if changingPath, after.mode != nil { throw FileComparisonEditFailure.changed }
            let input = before.mode == nil ? nil : before.bytes
            let application: SourceTextPatchApplication
            do {
                application = try SourceTextPatchApplication.simulate(file: file, input: input, textEncodingPolicy: policy, cancellation: cancellation)
            } catch {
                try cancellation?.check()
                // Only an actual index old..new object records a Git base.
                // SVN '(revision n)' annotations never populate this field.
                guard allowRecovery else { throw error }
                let bytes: Data, label: String
                if file.oldPathBytes == nil || file.oldRevision.map({ (7...64).contains($0.utf8.count) && $0.allSatisfy { $0 == "0" } }) == true {
                    bytes = Data(); label = file.oldRevision ?? "Patch addition"
                } else {
                    guard review.isGitWorkingTree, let object = file.oldRevision,
                          (7...64).contains(object.utf8.count), object.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw error }
                    bytes = try run(["cat-file", "blob", object], environmentOverrides: ["GIT_NO_LAZY_FETCH": "1"], cancellation: cancellation).stdout
                    label = object
                }
                application = try SourceTextPatchApplication.simulate(file: file, input: input, baseInput: bytes, textEncodingPolicy: policy, force: true, cancellation: cancellation)
                let base = ComparisonFileContent(path: beforePath, revision: .revision(label), bytes: bytes, mode: file.oldMode ?? before.mode ?? "100644", permissions: before.permissions ?? 0o644)
                recoveryBase = policy.applying(base)
            }
            if file.newPathBytes == nil {
                outputs[beforePath] = ComparisonFileContent(path: beforePath, revision: .workingTree, bytes: Data(), mode: nil, isDeleted: true)
            } else {
                let mode = file.newMode ?? before.mode ?? "100644"
                guard ["100644", "100755"].contains(mode) else { throw SourceTextPatchFailure.opaque }
                let permissions = mode == before.mode ? (before.permissions ?? 0o644) : (mode == "100755" ? 0o755 : 0o644)
                outputs[afterPath] = ComparisonFileContent(path: afterPath, revision: .workingTree, bytes: application.outputData, mode: mode, permissions: permissions, encoding: application.outputEncoding)
                if changingPath, file.copyFromPathBytes == nil {
                    outputs[beforePath] = ComparisonFileContent(path: beforePath, revision: .workingTree, bytes: Data(), mode: nil, isDeleted: true)
                }
            }
        }
        guard let before = inputs[source], let after = outputs[destination] else { throw WorkingTreePatchFailure.metadata }
        let selected = WorkingTreePatchReview(files: wanted, document: review.document, statistics: review.statistics, summary: review.summary, validationError: review.validationError,
            isGitWorkingTree: review.isGitWorkingTree, textEncodingPolicy: review.textEncodingPolicy, decodedPatch: patch, decodedInputs: review.decodedInputs,
            directoryMode: review.directoryMode, repositoryRoot: review.repositoryRoot, reversed: review.reversed, stripCount: review.stripCount, includePatterns: [])
        return WorkingTreePatchFileComparison(document: FileComparisonDocument(base: before, destination: after), fileID: fileID ?? wanted[0].id,
            review: selected, inputs: inputs, outputs: outputs, recoveryBase: recoveryBase, textEncodingPolicy: review.textEncodingPolicy)
    }
}

private extension GitRepository {
    /// Git's generated-diff publication recreates regular files with canonical
    /// executable permissions. CPatch saves retain an existing file's captured
    /// permissions. Restore only through a pinned root/parent/leaf descriptor,
    /// after verifying the exact expected owned bytes and Git mode.
    func restoreDecodedPatchPermissions(rootDescriptor: Int32, inputs: GitPathMap<ComparisonFileContent>, outputs: GitPathMap<ComparisonFileContent>, cancellation: OperationCancellation?) throws {
        for (path, output) in outputs {
            try cancellation?.check()
            guard let original = inputs[path], ["100644", "100755"].contains(original.mode ?? ""),
                  output.mode == original.mode, let desired = output.permissions else { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let leaf = parts.last, !leaf.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw WorkingFileRestoreFailure.location }
            var parent = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
            guard parent >= 0 else { throw FileComparisonEditFailure.changed }
            defer { Darwin.close(parent) }
            for component in parts.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw FileComparisonEditFailure.changed }
                Darwin.close(parent); parent = next
            }
            let descriptor = openat(parent, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw FileComparisonEditFailure.changed }
            defer { Darwin.close(descriptor) }
            var before = stat(), named = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  before.st_size == output.bytes.count,
                  (before.st_mode & 0o111 != 0 ? "100755" : "100644") == output.mode,
                  fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_dev == named.st_dev, before.st_ino == named.st_ino else { throw FileComparisonEditFailure.changed }
            var offset = 0, buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try cancellation?.check()
                let capacity = min(buffer.count, output.bytes.count - offset + 1)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, capacity) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0, count <= output.bytes.count - offset else { throw FileComparisonEditFailure.changed }
                if count == 0 { break }
                guard output.bytes.subdata(in: offset..<(offset + count)).elementsEqual(buffer.prefix(count)) else { throw FileComparisonEditFailure.changed }
                offset += count
            }
            var measured = stat()
            guard offset == output.bytes.count, fstat(descriptor, &measured) == 0,
                  measured.st_dev == before.st_dev, measured.st_ino == before.st_ino,
                  measured.st_size == before.st_size, measured.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  measured.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  measured.st_mode == before.st_mode,
                  fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  measured.st_dev == named.st_dev, measured.st_ino == named.st_ino else { throw FileComparisonEditFailure.changed }
            if Int(measured.st_mode & 0o7777) != desired {
                let canonical = output.mode == "100755" ? 0o755 : 0o644
                let actual = Int(measured.st_mode & 0o7777)
                guard measured.st_nlink == 1, actual & canonical == actual else { throw FileComparisonEditFailure.changed }
                try cancellation?.check()
                guard fchmod(descriptor, mode_t(desired)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var final = stat()
                guard fstat(descriptor, &final) == 0, final.st_dev == measured.st_dev, final.st_ino == measured.st_ino,
                      Int(final.st_mode & 0o7777) == desired, final.st_size == measured.st_size,
                      final.st_mtimespec.tv_sec == measured.st_mtimespec.tv_sec,
                      final.st_mtimespec.tv_nsec == measured.st_mtimespec.tv_nsec,
                      fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      final.st_dev == named.st_dev, final.st_ino == named.st_ino else { throw FileComparisonEditFailure.changed }
            }
        }
    }
}
