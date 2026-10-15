// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum GitPropertyState: Int, Sendable { case off, on, mixed }
public struct GitPropertyDraft: Equatable, Sendable {
    public var assumeUnchanged: GitPropertyState = .off
    public var skipWorktree: GitPropertyState = .off
    public var executable: GitPropertyState = .off
    public var symlink: GitPropertyState = .off
    public init() {}
}
public struct GitPropertyIndexEntry: Equatable, Sendable {
    public let path: String, pathBytes: Data, mode: String, object: String
    public let stage: Int
    public let assumeUnchanged: Bool, skipWorktree: Bool
}
public struct GitPropertyCommit: Equatable, Sendable {
    public let hash: String, subject: String, author: String
    public let authorDate: Date
}
public struct GitPropertySnapshot: Sendable {
    public let root: URL, paths: [String]
    public let branch: String, trackedBranch: String, trackedURL: String
    public let head: GitPropertyCommit?, lastModified: GitPropertyCommit?
    public let autoCRLF: String, safeCRLF: String, userName: String, userEmail: String
    public let entries: [GitPropertyIndexEntry]
    let index: URL, indexBytes: Data?, hashLength: Int
    public var allVersioned: Bool { !paths.isEmpty && entries.count == paths.count }
    public var hasSubmodule: Bool { entries.contains { $0.mode == "160000" } }
    public var draft: GitPropertyDraft {
        func state(_ values: [Bool]) -> GitPropertyState { values.allSatisfy({ $0 }) ? .on : values.allSatisfy({ !$0 }) ? .off : .mixed }
        var result = GitPropertyDraft()
        if !allVersioned { return result }
        result.assumeUnchanged = state(entries.map(\.assumeUnchanged)); result.skipWorktree = state(entries.map(\.skipWorktree))
        result.executable = state(entries.map { (UInt32($0.mode,radix:8) ?? 0) & 0o111 != 0 }); result.symlink = state(entries.map { $0.mode == "120000" })
        return result
    }
}
public enum GitPropertyFailure: LocalizedError {
    case selection, stale, indexFormat, mode, history
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select paths belonging to this repository. Index properties require versioned entries."
        case .stale: return "The Git index changed. Refresh Git Properties before applying these fields."
        case .indexFormat: return "The Git index is corrupt or has an unsupported format. No property changes were written."
        case .mode: return "Executable and Symlink cannot both be enabled."
        case .history: return "Git returned incomplete property history. Refresh Git Properties."
        }
    }
}
/// The input expressions are already full object IDs plus one literal path.
/// Never infer absence from arbitrary output or decode binary object contents.
enum GitPropertyObjectBatch {
    static func parse(_ data: Data, expressions: [String]) throws -> [String?] {
        if expressions.isEmpty { guard data.isEmpty else { throw GitPropertyFailure.history }; return [] }
        let rows = data.split(separator: 10, omittingEmptySubsequences: false)
        guard rows.count == expressions.count + 1, rows.last?.isEmpty == true else { throw GitPropertyFailure.history }
        return try zip(expressions, rows).map { expression, row in
            guard let colon = expression.firstIndex(of: ":"), HistoryMetadataProtocol.objectID(String(expression[..<colon])), !expression.contains("\n"), !expression.contains("\r"), !expression.contains("\0") else { throw GitPropertyFailure.history }
            let value = String(decoding: row, as: UTF8.self)
            if value.utf8.count == expression[..<colon].utf8.count && HistoryMetadataProtocol.objectID(value) { return value }
            if value.hasSuffix(" submodule") {
                let object = String(value.dropLast(" submodule".count))
                guard object.utf8.count == expression[..<colon].utf8.count && HistoryMetadataProtocol.objectID(object) else { throw GitPropertyFailure.history }
                return object
            }
            guard Data(row) == Data((expression + " missing").utf8) else { throw GitPropertyFailure.history }
            return nil
        }
    }
}

extension GitRepository {
    private func propertyIndexLocation(cancellation: OperationCancellation?) throws -> URL {
        var bytes = try run(["rev-parse","--git-path","index"],cancellation:cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding:bytes,as:UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath:path) : root.appendingPathComponent(path)
    }
    private func propertyEntries(cancellation: OperationCancellation? = nil) throws -> [GitPropertyIndexEntry] {
        var entries: [GitPropertyIndexEntry] = []
        for row in try run(["ls-files","-v","--stage","-z"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout.split(separator:0) {
            guard let tab = row.firstIndex(of:9) else { throw GitPropertyFailure.indexFormat }
            let fields = String(decoding:row[..<tab],as:UTF8.self).split(separator:" "), bytes = Data(row[row.index(after:tab)...])
            guard fields.count == 4, let stage = Int(fields[3]), let tag = fields[0].utf8.first else { throw GitPropertyFailure.indexFormat }
            guard let path = String(data:bytes,encoding:.utf8) else { continue } // preserve unselected byte paths in the index
            entries.append(GitPropertyIndexEntry(path:path,pathBytes:bytes,mode:String(fields[1]),object:String(fields[2]),stage:stage,assumeUnchanged:tag >= 97 && tag <= 122,skipWorktree:tag == 83 || tag == 115))
        }
        return entries
    }
    private func propertyCommit(_ hash: String, cancellation: OperationCancellation?) throws -> GitPropertyCommit {
        let fields = try run(["show","-s","--no-show-signature","--encoding=UTF-8","--format=%H%x00%B%x00%an%x00%at",hash,"--"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout.split(separator:0,omittingEmptySubsequences:false)
        guard fields.count == 4, let time = TimeInterval(String(decoding:fields[3],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw GitPropertyFailure.indexFormat }
        return GitPropertyCommit(hash:String(decoding:fields[0],as:UTF8.self),subject:String(decoding:fields[1],as:UTF8.self).split(separator:"\n").first.map(String.init) ?? "",author:String(decoding:fields[2],as:UTF8.self),authorDate:Date(timeIntervalSince1970:time))
    }
    /// Upstream follows the parent(s) sharing the selected path's object and
    /// excludes differing parent histories. Mode-only changes are not content
    /// changes; renames are not followed. A missing path at HEAD is blank.
    private func propertyLastCommit(head: String, path: String, cancellation: OperationCancellation?) throws -> GitPropertyCommit? {
        func scalarObject(_ hash:String) throws -> String? {
            let bytes = try run(["ls-tree","--full-tree","-z",hash,"--",path],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout
            for row in bytes.split(separator:0) {
                guard let tab = row.firstIndex(of:9), Data(row[row.index(after:tab)...]) == Data(path.utf8) else { continue }
                return String(decoding:row[..<tab],as:UTF8.self).split(separator:" ").last.map(String.init)
            }
            return nil
        }
        let walk = try run(["rev-list","--parents",head,"--"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).text.split(separator:"\n").map { $0.split(separator:" ").map(String.init) }
        guard !walk.isEmpty, walk.allSatisfy({ !$0.isEmpty && $0.allSatisfy(HistoryMetadataProtocol.objectID) }), Set(walk.compactMap { $0.first }).count == walk.count else { throw GitPropertyFailure.history }
        let parents = Dictionary(uniqueKeysWithValues:walk.map { ($0[0],Array($0.dropFirst())) })
        let ordered = walk.compactMap { $0.first }, positions = Dictionary(uniqueKeysWithValues: walk.enumerated().compactMap { index, row in row.first.map { ($0, index) } })
        var objects: [String: String] = [:]
        func object(_ hash: String) throws -> String? {
            try cancellation?.check()
            if let value = objects[hash] { return value.isEmpty ? nil : value }
            // Legacy Git's batch protocol uses LF output. Keep exact newline/CR
            // paths on the scalar -z reader, rather than quote or rewrite them.
            guard !path.contains("\n"), !path.contains("\r"), let start = positions[hash] else {
                let value = try scalarObject(hash); objects[hash] = value ?? ""; return value
            }
            let batch = ordered[start..<min(start + 64, ordered.count)].filter { objects[$0] == nil }
            let expressions = batch.map { $0 + ":" + path }
            let bytes = try run(["cat-file", "--batch-check=%(objectname)", "--buffer"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation, input: Data((expressions.joined(separator: "\n") + "\n").utf8)).stdout
            let values = try GitPropertyObjectBatch.parse(bytes, expressions: expressions)
            for (commit, value) in zip(batch, values) {
                // Missing expressions on older Git still use ls-tree so an
                // unavailable object cannot erase an existing tree entry's OID.
                objects[commit] = try value ?? scalarObject(commit) ?? ""
            }
            guard let value = objects[hash] else { throw GitPropertyFailure.history }
            return value.isEmpty ? nil : value
        }
        var hidden = Set<String>(), last: String?
        func hide(_ hash:String) { var todo = [hash]; while let next = todo.popLast() { if hidden.insert(next).inserted { todo.append(contentsOf:parents[next] ?? []) } } }
        for row in walk where !row.isEmpty && !hidden.contains(row[0]) {
            try cancellation?.check(); last = row[0]
            guard let current = try object(row[0]) else { return nil }
            var changed = true
            for parent in row.dropFirst() {
                if try object(parent) == current { changed = false } else { hide(parent) }
            }
            if changed { return try propertyCommit(row[0],cancellation:cancellation) }
        }
        return try last.map { try propertyCommit($0,cancellation:cancellation) }
    }
    public func gitProperties(paths supplied: [String], cancellation: OperationCancellation? = nil) throws -> GitPropertySnapshot {
        var seen = Set<Data>(); let paths = (supplied.isEmpty ? ["."] : supplied).filter { seen.insert(Data($0.utf8)).inserted }
        guard paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator:"/").contains("..") && !$0.split(separator:"/").contains(".git") }) else { throw GitPropertyFailure.selection }
        let index = try propertyIndexLocation(cancellation:cancellation), original = try? Data(contentsOf:index)
        let hashLength = try run(["rev-parse","--show-object-format"],cancellation:cancellation).text.trimmingCharacters(in:.newlines) == "sha256" ? 32 : 20
        func config(_ key:String) throws -> String {
            let result = try run(["config","--get",key],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],successfulExitCodes:0...1,cancellation:cancellation)
            var bytes = result.stdout; if bytes.last == 10 { bytes.removeLast() }; return String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let symbolic = try run(["symbolic-ref","--quiet","--short","HEAD"],successfulExitCodes:0...1,cancellation:cancellation)
        let branch = symbolic.exitCode == 0 ? symbolic.text.trimmingCharacters(in:.newlines) : "detached HEAD"
        let headResult = try run(["rev-parse","--verify","--quiet","HEAD^{commit}"],successfulExitCodes:0...1,cancellation:cancellation)
        let hash = headResult.exitCode == 0 ? headResult.text.trimmingCharacters(in:.newlines) : nil
        var trackedBranch = "", trackedURL = ""
        if symbolic.exitCode == 0, hash != nil {
            let fields = try run(["for-each-ref","--format=%(upstream)%00%(upstream:remotename)","refs/heads/" + branch],cancellation:cancellation).stdout.split(separator:0,omittingEmptySubsequences:false)
            if fields.count == 2 {
                trackedBranch = String(decoding:fields[0],as:UTF8.self)
                for prefix in ["refs/remotes/","refs/heads/"] where trackedBranch.hasPrefix(prefix) { trackedBranch = String(trackedBranch.dropFirst(prefix.count)); break }
                let remote = String(decoding:fields[1],as:UTF8.self).trimmingCharacters(in:.newlines)
                if !remote.isEmpty && remote != "." { trackedURL = try config("remote." + remote + ".url") }
            }
        }
        let bare = try run(["rev-parse","--is-bare-repository"],cancellation:cancellation).text.trimmingCharacters(in:.newlines) == "true"
        let all: [GitPropertyIndexEntry]
        if bare { all = [] }
        else if let original {
            do { all = try GitPropertyIndex(original,hashLength:hashLength).propertyEntries() }
            catch GitPropertyIndexMaterialization.split { all = try propertyEntries(cancellation:cancellation) }
        } else { all = try propertyEntries(cancellation:cancellation) }
        var entries: [GitPropertyIndexEntry] = []
        for path in paths { if let entry = all.first(where:{ $0.pathBytes == Data(path.utf8) }) { entries.append(entry) } }
        let head = try hash.map { try propertyCommit($0,cancellation:cancellation) }
        let last = paths.count == 1 && entries.count == 1 ? try hash.flatMap { try propertyLastCommit(head:$0,path:paths[0],cancellation:cancellation) } : nil
        let auto = try config("core.autocrlf"), safe = try config("core.safecrlf"), name = try config("user.name"), email = try config("user.email")
        guard (try? Data(contentsOf:index)) == original else { throw GitPropertyFailure.stale }
        return GitPropertySnapshot(root:root,paths:paths,branch:branch,trackedBranch:trackedBranch,trackedURL:trackedURL,head:head,lastModified:last,autoCRLF:auto.isEmpty ? "false" : auto,safeCRLF:safe.isEmpty ? "false" : safe,userName:name,userEmail:email,entries:entries,index:index,indexBytes:original,hashLength:hashLength)
    }
    @discardableResult public func applyGitProperties(_ draft: GitPropertyDraft, snapshot: GitPropertySnapshot, cancellation: OperationCancellation? = nil) throws -> GitPropertySnapshot {
        try cancellation?.check()
        guard snapshot.root == root, snapshot.allVersioned, let expected = snapshot.indexBytes else { throw GitPropertyFailure.selection }
        let location = try propertyIndexLocation(cancellation:cancellation)
        guard location.standardizedFileURL == snapshot.index.standardizedFileURL else { throw GitPropertyFailure.stale }
        let lock = URL(fileURLWithPath:location.path + ".lock")
        let fd = Darwin.open(lock.path,O_WRONLY | O_CREAT | O_EXCL,0o600)
        guard fd >= 0 else { throw GitFailure(arguments:["update-index"],code:1,message:"Could not lock the Git index: " + String(cString:strerror(errno))) }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        let nested = URL(fileURLWithPath:lock.path + ".lock"); var ownsNested = false
        defer { try? handle.close(); try? FileManager.default.removeItem(at:lock); if ownsNested { try? FileManager.default.removeItem(at:nested) } }
        guard try Data(contentsOf:location) == expected else { throw GitPropertyFailure.stale }
        try handle.write(contentsOf:expected); try handle.close()
        var index: GitPropertyIndex
        do { index = try GitPropertyIndex(expected,hashLength:snapshot.hashLength) }
        catch GitPropertyIndexMaterialization.split {
            guard !FileManager.default.fileExists(atPath:nested.path) else { throw GitPropertyFailure.stale }
            ownsNested = true
            _ = try run(["update-index","--no-split-index"],environmentOverrides:["GIT_INDEX_FILE":lock.path,"GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation)
            index = try GitPropertyIndex(Data(contentsOf:lock),hashLength:snapshot.hashLength)
        }
        try index.apply(draft,selected:snapshot.entries)
        let bytes = index.encoded()
        try cancellation?.check()
        guard try Data(contentsOf:location) == expected else { throw GitPropertyFailure.stale }
        let output = try FileHandle(forWritingTo:lock); try output.truncate(atOffset:0); try output.write(contentsOf:bytes); try output.synchronize(); try output.close()
        let permissions = try FileManager.default.attributesOfItem(atPath:location.path)[.posixPermissions]
        if let permissions { try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:lock.path) }
        try cancellation?.check()
        guard Darwin.rename(lock.path,location.path) == 0 else { throw GitFailure(arguments:["update-index"],code:1,message:"Could not replace the Git index: " + String(cString:strerror(errno))) }
        let all = index.propertyEntries()
        let entries = snapshot.entries.compactMap { old in all.first { $0.pathBytes == old.pathBytes && $0.stage == old.stage } }
        return GitPropertySnapshot(root:snapshot.root,paths:snapshot.paths,branch:snapshot.branch,trackedBranch:snapshot.trackedBranch,trackedURL:snapshot.trackedURL,head:snapshot.head,lastModified:snapshot.lastModified,autoCRLF:snapshot.autoCRLF,safeCRLF:snapshot.safeCRLF,userName:snapshot.userName,userEmail:snapshot.userEmail,entries:entries,index:location,indexBytes:bytes,hashLength:snapshot.hashLength)
    }
}
