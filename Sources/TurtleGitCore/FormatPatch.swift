import Foundation
import Darwin

/// The three mutually exclusive Version choices in TortoiseGit's Format Patch dialog.
public enum FormatPatchSelection: Equatable, Sendable {
    case since(String)
    case number(Int)
    case range(from: String, to: String)
}

/// FormatPatchCommand startrev/endrev and GitLogListAction ID_CREATE_PATCH.
/// A single selected revision means Since (export commits after that revision).
/// Multiple selections include the oldest selected revision via its first parent.
public struct FormatPatchPreset: Equatable, Sendable {
    public let selection: FormatPatchSelection
    public let from: String
    public let to: String
    public init?(startRevision: String?, endRevision: String? = nil) {
        guard let start = startRevision, !start.isEmpty else { return nil }
        if let end = endRevision, !end.isEmpty {
            selection = .range(from: start, to: end); from = start; to = end
        } else {
            selection = .since(start); from = start + "~1"; to = start
        }
    }
    public static func logSelection(orderedHashes: [String], selected: Set<String>, oldestFirst: Bool = false, hasHiddenRows: Bool = false) -> FormatPatchPreset? {
        let rows = orderedHashes.indices.filter { selected.contains(orderedHashes[$0]) }
        guard !rows.isEmpty, rows.count == selected.count else { return nil }
        if rows.count == 1 { return FormatPatchPreset(startRevision: orderedHashes[rows[0]]) }
        guard rows.count <= 2 || (!hasHiddenRows && rows.last! - rows.first! + 1 == rows.count) else { return nil }
        let oldest = orderedHashes[oldestFirst ? rows.first! : rows.last!]
        let newest = orderedHashes[oldestFirst ? rows.last! : rows.first!]
        return FormatPatchPreset(startRevision: oldest + "~1", endRevision: newest)
    }
}

public enum FormatPatchFailure: LocalizedError {
    case selection, outputDirectory, output
    public var errorDescription: String? {
        switch self {
        case .selection: return "Choose a revision or a commit count between 1 and 2147483647."
        case .outputDirectory: return "Choose an output directory outside Git metadata."
        case .output: return "Git completed Format Patch but its exported file list could not be verified. Any files already written remain in the output directory."
        }
    }
}

/// Settlement of the actual format-patch subprocess, before native patch-file
/// discovery and Send Mail. Validation reads do not emit a command completion.
public struct FormatPatchCommandCompletion:Sendable {
    public let success:Bool,cancelled:Bool
    public let exitCode:Int32?
    public let finished:Date
    public let elapsed:TimeInterval
    public init(success:Bool,cancelled:Bool,exitCode:Int32?,elapsed:TimeInterval,finished:Date=Date()) {
        self.success=success;self.cancelled=cancelled;self.exitCode=exitCode;self.elapsed=max(0,elapsed);self.finished=finished
    }
}

/// Verified filenames come from the complete subprocess stdout, independently
/// of the bounded diagnostic log. A failed or cancelled export has no receipt.
public struct FormatPatchExport:Sendable {
    public let result:GitResult
    public let files:[URL]
    private struct DirectoryIdentity:Equatable {
        let device:Int64,inode:UInt64
        static func read(_ path:String)->Self? {
            var info=stat()
            guard lstat(path,&info)==0,info.st_mode & S_IFMT==S_IFDIR else{return nil}
            return .init(device:Int64(info.st_dev),inode:UInt64(info.st_ino))
        }
    }
    public static func exportedFiles(stdout:Data,in folder:URL)throws->[URL] {
        guard folder.isFileURL,!folder.path.utf8.contains(0) else{throw FormatPatchFailure.outputDirectory}
        guard !stdout.isEmpty else{return []}
        let destination=folder.standardizedFileURL.resolvingSymlinksInPath(),directory=destination.path
        guard let approved=DirectoryIdentity.read(directory) else{throw FormatPatchFailure.output}
        // macOS Git may precompose directory arguments. Admit only canonical
        // spellings which independently identify the same approved directory;
        // the filename suffix is always kept byte-for-byte as Git reported it.
        var prefixes=[(path:String,bytes:Data)](),seenPrefixes=Set<Data>()
        for candidate in [directory,directory.precomposedStringWithCanonicalMapping,directory.decomposedStringWithCanonicalMapping] {
            let bytes=Data((candidate+(candidate.hasSuffix("/") ? "":"/")).utf8)
            guard seenPrefixes.insert(bytes).inserted,DirectoryIdentity.read(candidate)==approved else{continue}
            prefixes.append((candidate,bytes))
        }
        var cursor=stdout.startIndex,files=[URL](),seen=Set<Data>()
        while cursor<stdout.endIndex {
            guard let prefix=prefixes.first(where:{stdout[cursor...].starts(with:$0.bytes)}),DirectoryIdentity.read(prefix.path)==approved else{throw FormatPatchFailure.output}
            let start=cursor+prefix.bytes.count
            guard let end=stdout[start...].firstIndex(of:10) else{throw FormatPatchFailure.output}
            let bytes=Data(stdout[start..<end])
            guard !bytes.isEmpty,!bytes.contains(0),!bytes.contains(47),bytes != Data([46]),bytes != Data([46,46]),
                  let name=String(data:bytes,encoding:.utf8),seen.insert(bytes).inserted else{throw FormatPatchFailure.output}
            let file=FileTransferPaths.fileURL(prefix.path+(prefix.path.hasSuffix("/") ? "":"/")+name)
            guard let attributes=try? FileManager.default.attributesOfItem(atPath:file.path),attributes[.type] as? FileAttributeType == .typeRegular else{throw FormatPatchFailure.output}
            files.append(file);cursor=end+1
        }
        guard DirectoryIdentity.read(directory)==approved,prefixes.allSatisfy({DirectoryIdentity.read($0.path)==approved}) else{throw FormatPatchFailure.output}
        return files
    }

}

extension GitRepository {
    /// Adapted from FormatPatchCommand.cpp, GPL-2.0-or-later. Preserve Git's
    /// numbering, naming, configuration, binary patches and empty-range behavior.
    /// Existing patch files can be replaced, just as in the upstream command.
    public func formatPatch(selection: FormatPatchSelection, to folder: URL, noPrefix: Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                            onCommand:(@Sendable(GitCommandInvocation)->Void)?=nil,onCommandFinished:(@Sendable(FormatPatchCommandCompletion)->Void)?=nil) throws -> GitResult {
        try cancellation?.check()
        func valid(_ revision: String) -> Bool { !revision.isEmpty && !revision.contains("\0") }
        var capturedFetchHead:String?
        func endpoint(_ revision:String)throws->String {
            guard valid(revision) else{throw FormatPatchFailure.selection}
            guard revision=="FETCH_HEAD" else{return revision}
            if let capturedFetchHead {return capturedFetchHead}
            // FixBranchName selects the sole for-merge record, never Git's
            // potentially not-for-merge first record. Capture once per export.
            var data=try run(["rev-parse","--git-path","FETCH_HEAD"],cancellation:cancellation).stdout
            if data.last==10 {data.removeLast()}
            guard let path=String(data:data,encoding:.utf8),!path.utf8.contains(0) else{throw FormatPatchFailure.selection}
            let location=path.hasPrefix("/") ? FileTransferPaths.fileURL(path):FileTransferPaths.fileURL(root.path+"/"+path)
            let records=try Data(contentsOf:location).split(separator:10).compactMap {record->Data? in
                let fields=record.split(separator:9,omittingEmptySubsequences:false)
                guard fields.count>=3,fields[1].isEmpty else{return nil}
                return Data(fields[0])
            }
            guard records.count==1,let selected=String(data:records[0],encoding:.utf8),GitLocalReferenceProtocol.validOID(selected) else{throw FormatPatchFailure.selection}
            capturedFetchHead=selected;return selected
        }
        let version:[String]
        switch selection {
        case .since(let revision):version=["--end-of-options",try endpoint(revision)]
        case .number(let count):
            guard count>=1,count<=Int(Int32.max) else{throw FormatPatchFailure.selection};version=["-\(count)"]
        case .range(let from,let to):version=["--end-of-options",try endpoint(from)+".."+endpoint(to)]
        }
        let destination = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.isFileURL,
              !destination.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw FormatPatchFailure.outputDirectory }
        // Bare repositories and linked worktrees can store metadata outside a
        // directory named .git. Never allow an export into either admin root.
        for option in ["--absolute-git-dir", "--git-common-dir"] {
            var data = try run(["rev-parse", option], cancellation: cancellation).stdout
            if data.last == 10 { data.removeLast() }
            let path = String(decoding: data, as: UTF8.self)
            let metadata = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
            guard !RepositoryAccessLease.pathIsContained(destination, by: metadata) else { throw FormatPatchFailure.outputDirectory }
        }
        let command=["format-patch"] + (noPrefix ? ["--no-prefix"] : []) + ["-o", destination.path] + version + ["--"]
        try cancellation?.check()
        onCommand?(commandInvocation(command))
        let started=ProcessInfo.processInfo.systemUptime
        do {
            let result=try run(command,cancellation:cancellation,onOutput:onOutput)
            onCommandFinished?(.init(success:true,cancelled:false,exitCode:result.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
            return result
        }catch {
            let killed=error as? GitCommandCancellationFailure
            onCommandFinished?(.init(success:false,cancelled:cancellation?.isCancelled == true || killed != nil || error is OperationCancellationFailure || error is CancellationError,
                exitCode:killed?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            throw error
        }
    }
    /// Source-default export used by direct completion→mail handoffs. No
    /// composer is opened until Git settles successfully and every exact
    /// reported filename is verified; partial failed exports remain on disk.
    public func formatPatchFiles(selection:FormatPatchSelection,to folder:URL,noPrefix:Bool=false,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,
                                 onCommand:(@Sendable(GitCommandInvocation)->Void)?=nil,onCommandFinished:(@Sendable(FormatPatchCommandCompletion)->Void)?=nil)throws->FormatPatchExport {
        let result=try formatPatch(selection:selection,to:folder,noPrefix:noPrefix,cancellation:cancellation,onOutput:onOutput,onCommand:onCommand,onCommandFinished:onCommandFinished)
        try cancellation?.check()
        let files=try FormatPatchExport.exportedFiles(stdout:result.stdout,in:folder)
        try cancellation?.check();return .init(result:result,files:files)
    }

}

extension FormatPatchPreset {
    /// RefLog selects events by selector, not by hash. Preserve source row
    /// continuity rules even when several events point at the same commit.
    public static func referenceLogSelection(entries: [ReferenceLogEntry], selected: Set<String>) -> Self? {
        let rows = entries.indices.filter { selected.contains(entries[$0].id) }
        guard !rows.isEmpty, rows.count == selected.count else { return nil }
        if rows.count == 1 { return Self(startRevision: entries[rows[0]].hash) }
        guard rows.count <= 2 || rows.last! - rows.first! + 1 == rows.count else { return nil }
        return Self(startRevision: entries[rows.last!].hash + "~1", endRevision: entries[rows.first!].hash)
    }
}
