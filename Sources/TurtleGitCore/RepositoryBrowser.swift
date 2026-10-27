// Native adaptation of TortoiseGit RepositoryBrowser.cpp tree/list workflows.
// Copyright (C) 2009-2026 - TortoiseGit; 2003-2013 - TortoiseSVN. GPL-2.0-or-later.
import Foundation
import Darwin

/// Git path identity is UTF-8 byte identity, not Swift's canonical String equality.
public enum RepositoryBrowserPathIdentity {
    public static func equal(_ a:String,_ b:String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    public static func id(_ path:String) -> String { ((try? RepositoryBrowserGitPath(key:path).rawData) ?? Data(path.utf8)).base64EncodedString() }
}
public struct RepositoryBrowserPathMap<Value:Sendable>: Sendable, ExpressibleByDictionaryLiteral {
    public typealias Key = String
    private var storage: [Data:(path:String,value:Value)] = [:]
    public init() {}
    public init(dictionaryLiteral elements:(String,Value)...) { for (path,value) in elements { self[path]=value } }
    public subscript(_ path:String) -> Value? {
        get { storage[Data(path.utf8)]?.value }
        set { if let newValue {storage[Data(path.utf8)]=(path,newValue)} else {storage.removeValue(forKey:Data(path.utf8))} }
    }
    public var keys:[String] { storage.values.map(\.path) }
    public var values:[Value] { storage.values.map(\.value) }
    public var count:Int { storage.count }
    public func mapValues<Other:Sendable>(_ transform:(Value)throws->Other) rethrows -> RepositoryBrowserPathMap<Other> {
        var result=RepositoryBrowserPathMap<Other>();for item in storage.values {result[item.path]=try transform(item.value)};return result
    }
    public func filter(_ predicate:((key:String,value:Value))throws->Bool) rethrows -> Self {
        var result=Self();for item in storage.values {if try predicate((item.path,item.value)) {result[item.path]=item.value}};return result
    }
}
extension RepositoryBrowserPathMap: Equatable where Value:Equatable {
    public static func ==(a:Self,b:Self)->Bool {
        a.storage.count == b.storage.count && a.storage.allSatisfy { key,item in b.storage[key]?.value == item.value }
    }
}
public struct RepositoryBrowserPathSet: Sendable, ExpressibleByArrayLiteral {
    private var storage:[Data:String]=[:]
    public init() {}
    public init<S:Sequence>(_ paths:S) where S.Element==String {for path in paths {insert(path)}}
    public init(arrayLiteral elements:String...) {self.init(elements)}
    public mutating func insert(_ path:String) {storage[Data(path.utf8)]=path}
    public mutating func remove(_ path:String) {storage.removeValue(forKey:Data(path.utf8))}
    public mutating func formUnion<S:Sequence>(_ paths:S) where S.Element==String {for path in paths {insert(path)}}
    public func contains(_ path:String)->Bool {storage[Data(path.utf8)] != nil}
    public func isSuperset<S:Sequence>(of paths:S)->Bool where S.Element==String {paths.allSatisfy(contains)}
    public func sorted(by predicate:(String,String)throws->Bool) rethrows -> [String] {try storage.values.sorted(by:predicate)}
    public func intersection<S:Sequence>(_ paths:S)->Self where S.Element==String {
        let other=Self(paths);return Self(storage.values.filter {other.contains($0)})
    }
}

/// An app-owned drag copy; callers retain it until the receiver finishes reading.
public struct RepositoryBrowserExport: Sendable {
    public let directory: URL
    public let item: URL
    public let fileCount: Int
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}


public struct RepositoryBrowserEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case directory, file, executable, symlink, submodule }
    public let path: String
    public let name: String
    public let mode: String
    public let objectID: String
    public let size: Int64?
    public init(path:String,name:String,mode:String,objectID:String,size:Int64?) {
        self.path=path;self.name=name;self.mode=mode;self.objectID=objectID;self.size=size
    }
    public var rawPath:Data {(try? RepositoryBrowserGitPath(key:path).rawData) ?? Data(path.utf8)}
    public var rawName:Data {rawPath.split(separator:47).last.map{Data($0)} ?? Data()}
    public var displayPath:String {RepositoryBrowserGitPath.display(key:path)}
    public var displayName:String {name}
    public var isPathRepresentable:Bool {(try? RepositoryBrowserGitPath(key:path).isRepresentable) == true}
    public var parentPathKey:String {(try? RepositoryBrowserGitPath(key:path).parentKey) ?? ""}
    public var id: String { RepositoryBrowserPathIdentity.id(path) }
    public static func ==(a:Self,b:Self)->Bool {
        RepositoryBrowserPathIdentity.equal(a.path,b.path) && RepositoryBrowserPathIdentity.equal(a.name,b.name)
            && a.mode == b.mode && a.objectID == b.objectID && a.size == b.size
    }
    public var kind: Kind {
        switch mode { case "040000": return .directory; case "100755": return .executable; case "120000": return .symlink; case "160000": return .submodule; default: return .file }
    }
    public var fileExtension: String { kind == .directory || kind == .submodule ? "" : name.lastIndex(of: ".").map { String(name[$0...]) } ?? "" }
    public var storedBlobFilename:String {
        // Never decode replacement characters into a filesystem identity. Keep
        // a useful extension only when its original bytes are plain ASCII.
        var suffix=""
        if let dot=rawName.lastIndex(of:46) {
            let ext=rawName[rawName.index(after:dot)...]
            if (1...16).contains(ext.count),ext.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) {
                suffix="."+String(decoding:ext,as:UTF8.self)
            }
        }
        // Entry identity is checked by storedRepositoryBrowserBlob before this
        // proposal is used; constrain public presentation of malformed OIDs too.
        let oid=objectID.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) && [40,64].contains(objectID.utf8.count) ? objectID : "invalid"
        return "Git-blob-"+oid+suffix
    }
    public var sizeSort: Int64 { size ?? 0 }
}
public struct RepositoryBrowserSnapshot: Sendable {
    public let root: URL
    public let revision: String
    public let objectID: String?
    public let treeID: String?
    public let directory: String
    public var displayDirectory:String {RepositoryBrowserGitPath.display(key:directory)}
    public var isDirectoryRepresentable:Bool {(try? RepositoryBrowserGitPath(key:directory).isRepresentable) == true}
    public let bare: Bool
    public let entries: [RepositoryBrowserEntry]
    public let acceptedBackend:GitLibGit2Configuration?
    public init(root:URL,revision:String,objectID:String?,treeID:String?,directory:String,bare:Bool,entries:[RepositoryBrowserEntry],acceptedBackend:GitLibGit2Configuration?=nil) {
        self.root=root;self.revision=revision;self.objectID=objectID;self.treeID=treeID;self.directory=directory;self.bare=bare;self.entries=entries;self.acceptedBackend=acceptedBackend
    }
}
public enum RepositoryBrowserFailure: LocalizedError {
    case revision, directory, output, selection, transferLimit
    case normalizationCollision(String)
    public var errorDescription: String? {
        switch self {
        case .transferLimit: return "The repository transfer exceeds the supported inventory limit."
        case .revision: return "Choose a revision containing a commit or tree."
        case .directory: return "The selected directory does not exist at this revision."
        case .output: return "Git returned an invalid repository tree."
        case .selection: return "Choose a file from the displayed repository revision."
        case .normalizationCollision(let path): return "The Git path “\(path)” conflicts with another working-folder or tracked path on this filesystem. This action cannot safely keep those paths separate."
        }
    }
}
public enum RepositoryBrowserSort: Sendable { case name, fileExtension, size }
public enum RepositoryBrowserListing {
    public static func sorted(_ entries: [RepositoryBrowserEntry], by column: RepositoryBrowserSort = .name, descending: Bool = false) -> [RepositoryBrowserEntry] {
        func compare(_ lhs: String, _ rhs: String) -> ComparisonResult { lhs.compare(rhs, options: [.numeric, .caseInsensitive]) }
        return entries.sorted { a, b in
            if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
            var order: ComparisonResult = .orderedSame
            if column == .name { order = compare(a.name, b.name) }
            if order == .orderedSame && column != .size { order = a.fileExtension.compare(b.fileExtension, options: .caseInsensitive) }
            // Upstream's extension tie compares the right name with itself,
            // then falls through to size and finally the name.
            if order == .orderedSame && a.sizeSort != b.sizeSort { order = a.sizeSort < b.sizeSort ? .orderedAscending : .orderedDescending }
            if order == .orderedSame { order = compare(a.name, b.name) }
            if order == .orderedSame { order = a.path.compare(b.path, options: .literal) }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }
    // Shared filesystem/pathspec consumers require a real UTF-8 path, not an
    // opaque browser selection key. Keep this original admission boundary.
    static func validPath(_ path: String, allowRoot: Bool) -> Bool {
        guard !path.utf8.contains(0),let value=try? RepositoryBrowserGitPath(rawData:Data(path.utf8)) else{return false}
        return allowRoot || !value.rawData.isEmpty
    }
    static func validNamespaceKey(_ key:String,allowRoot:Bool)->Bool {
        guard let value=try? RepositoryBrowserGitPath(key:key) else{return false}
        return allowRoot || !value.rawData.isEmpty
    }
    static func parse(_ bytes: Data, directory: String, recursive:Bool=false) throws -> [RepositoryBrowserEntry] {
        guard let parent=try? RepositoryBrowserGitPath(key:directory) else {throw RepositoryBrowserFailure.output}
        if bytes.isEmpty {return []}
        guard bytes.last==0,bytes.first != 0 else{throw RepositoryBrowserFailure.output}
        var seen=Set<Data>()
        return try bytes.dropLast().split(separator:0,omittingEmptySubsequences:false).map {record in
            guard let tab=record.firstIndex(of:9) else{throw RepositoryBrowserFailure.output}
            let rawName=Data(record[record.index(after:tab)...])
            guard let relative=try? RepositoryBrowserGitPath(rawData:rawName),!rawName.isEmpty,
                  recursive || !rawName.contains(47),seen.insert(rawName).inserted,
                  let header=String(data:Data(record[..<tab]),encoding:.ascii) else{throw RepositoryBrowserFailure.output}
            let fields=header.split(whereSeparator:{$0==" "})
            guard fields.count==4,["040000","100644","100755","120000","160000"].contains(String(fields[0])),
                  [40,64].contains(fields[2].utf8.count),fields[2].utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{throw RepositoryBrowserFailure.output}
            let mode=String(fields[0]),size=Int64(fields[3])
            guard (mode=="040000" && fields[1]=="tree" || mode=="160000" && fields[1]=="commit") && fields[3]=="-" ||
                  (["100644","100755","120000"].contains(mode) && fields[1]=="blob" && size != nil && size!>=0) else{throw RepositoryBrowserFailure.output}
            var full=parent.rawData;if !full.isEmpty {full.append(47)};full.append(rawName)
            let path=try RepositoryBrowserGitPath(rawData:full)
            return RepositoryBrowserEntry(path:path.key,name:relative.lastComponentDisplay,mode:mode,objectID:String(fields[2]),size:size)
        }
    }

}
extension GitRepository {
    /// RepositoryBrowser::ReadTree labels an exact object ID with the first
    /// friendly reference (including the annotated-tag dereference suffix).
    /// Keep this display metadata separate from the immutable browser snapshot.
    public func repositoryBrowserRevisionLabel(_ snapshot:RepositoryBrowserSnapshot,cancellation:OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard snapshot.root == root else { throw RepositoryBrowserFailure.selection }
        guard let object=snapshot.objectID,snapshot.revision == object else { return snapshot.revision }
        let names=try historyReferenceObjects(cancellation:cancellation).compactMap { reference -> String? in
            guard reference.target == object else { return nil }
            return reference.name + (reference.peeled == nil ? "" : "^{}")
        }
        return names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.first ?? snapshot.revision
    }
    public func browseRepository(revision: String = "HEAD", directory: String = "", cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration?=nil) throws -> RepositoryBrowserSnapshot {
        try cancellation?.check()
        guard RepositoryBrowserListing.validNamespaceKey(directory, allowRoot: true) else { throw RepositoryBrowserFailure.directory }
        guard !revision.isEmpty, !revision.utf8.contains(0) else { throw RepositoryBrowserFailure.revision }
        let selected=backend ?? libgit2Configuration ?? .load()
        let initialReader=try repositoryBrowserReader(selected,initialization:true,cancellation:cancellation)
        // SHA-1 keeps the user's master policy for later source-selected marks;
        // SHA-256 records the declared CLI extension for every child receipt.
        let accepted=initialReader.enabled ? selected:GitLibGit2Configuration(enabled:false,mask:selected.mask,helperURL:selected.helperURL)
        let bare = try isBare(cancellation: cancellation)
        let resolved=try repositoryBrowserRevision(revision,initialization:true,cancellation:cancellation,backend:accepted)
        if resolved.unbornHead {return RepositoryBrowserSnapshot(root:root,revision:revision,objectID:nil,treeID:nil,directory:"",bare:bare,entries:[],acceptedBackend:accepted)}
        guard let object=resolved.objectID,let tree=resolved.treeID else{throw RepositoryBrowserFailure.revision}
        return try browseRepositoryTree(revision:revision,objectID:object,treeID:tree,directory:directory,bare:bare,cancellation:cancellation,backend:accepted)
    }

    public func browseRepositoryDirectory(_ snapshot: RepositoryBrowserSnapshot, directory: String, cancellation: OperationCancellation? = nil) throws -> RepositoryBrowserSnapshot {
        try cancellation?.check()
        guard snapshot.root == root, RepositoryBrowserListing.validNamespaceKey(directory, allowRoot: true),
              let tree = snapshot.treeID, let object = snapshot.objectID else { throw RepositoryBrowserFailure.directory }
        return try browseRepositoryTree(revision: snapshot.revision, objectID: object, treeID: tree, directory: directory, bare: snapshot.bare, cancellation: cancellation,backend:snapshot.acceptedBackend ?? libgit2Configuration ?? .load())
    }
    /// Bounded metadata only, pinned to the displayed tree rather than a mutable
    /// symbolic revision. Callers may lower the entry ceiling for their workflow.
    /// No file bytes, filters, child repository or working tree are consulted.
    public func repositoryBrowserTransferInventory(_ snapshot:RepositoryBrowserSnapshot,directory:String="",maximumEntries:Int=100_000,cancellation:OperationCancellation?=nil)throws->[RepositoryBrowserEntry] {
        try cancellation?.check()
        guard snapshot.root==root,let tree=snapshot.treeID,snapshot.objectID != nil,
              [40,64].contains(tree.utf8.count),tree.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}),
              RepositoryBrowserListing.validNamespaceKey(directory,allowRoot:true),maximumEntries>0,maximumEntries<=100_000 else{throw RepositoryBrowserFailure.selection}
        let selected=snapshot.acceptedBackend ?? libgit2Configuration ?? .load()
        let subtree=try repositoryBrowserDirectoryTree(treeID:tree,directory:directory,cancellation:cancellation,backend:selected)
        var bytes=Data(),records=0
        _=try run(["ls-tree","-r","-t","-l","-z",subtree,"--"],cancellation:cancellation,retainStandardOutput:false,consumeOutput:{chunk in
            guard case .stdout=chunk.stream else{return}
            guard chunk.data.count<=16_777_216-bytes.count else{throw RepositoryBrowserFailure.transferLimit}
            records += chunk.data.reduce(0){$0+($1==0 ? 1:0)}
            guard records<=maximumEntries else{throw RepositoryBrowserFailure.transferLimit}
            bytes.append(chunk.data)
        })
        try cancellation?.check()
        let entries=try RepositoryBrowserListing.parse(bytes,directory:directory,recursive:true)
        guard entries.allSatisfy({$0.rawPath.split(separator:47).count<=128}) else{throw RepositoryBrowserFailure.transferLimit}
        return entries
    }
    private func browseRepositoryTree(revision:String,objectID:String,treeID:String,directory:String,bare:Bool,cancellation:OperationCancellation?,backend:GitLibGit2Configuration)throws->RepositoryBrowserSnapshot {
        try cancellation?.check()
        let subtree=try repositoryBrowserDirectoryTree(treeID:treeID,directory:directory,cancellation:cancellation,backend:backend)
        let entries=try RepositoryBrowserListing.parse(run(["ls-tree","-z","-l",subtree,"--"],cancellation:cancellation).stdout,directory:directory)
        return RepositoryBrowserSnapshot(root:root,revision:revision,objectID:objectID,treeID:treeID,directory:directory,bare:bare,entries:entries,acceptedBackend:backend)
    }
    private func repositoryBrowserDirectoryTree(treeID:String,directory:String,cancellation:OperationCancellation?,backend:GitLibGit2Configuration)throws->String {
        guard [40,64].contains(treeID.utf8.count),treeID.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{throw RepositoryBrowserFailure.directory}
        let path=try RepositoryBrowserGitPath(key:directory)
        let reader=try repositoryBrowserReader(backend,initialization:true,cancellation:cancellation)
        if let utf8=path.utf8 {
            guard let subtree=try revisionLookup(utf8.isEmpty ? treeID:treeID+":"+utf8,requirement:.tree,cancellation:cancellation,backend:reader).objectID else{throw RepositoryBrowserFailure.directory}
            return subtree
        }
        // Only hexadecimal tree object IDs enter argv. Invalid name bytes are
        // compared against parsed tree entries in memory, never re-encoded.
        var tree=treeID
        for component in path.rawData.split(separator:47) {
            try cancellation?.check()
            let entries=try RepositoryBrowserListing.parse(run(["ls-tree","-z","-l",tree,"--"],cancellation:cancellation).stdout,directory:"")
            guard let entry=entries.first(where:{$0.rawName==Data(component)}),entry.kind == .directory else{throw RepositoryBrowserFailure.directory}
            tree=entry.objectID
        }
        return tree
    }
    /// Export a displayed item, or the displayed directory when entry is nil.
    /// Adapts RepositoryBrowser.cpp RecursivelyAdd and GitDataObject.cpp historical
    /// file contents (GPL-2.0-or-later). Gitlinks are skipped; symlinks are text.
    /// Copyright (C) 2016-2019, 2021-2023, 2025 TortoiseGit; 2007-2014 TortoiseSVN.
    public func exportRepositoryBrowser(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry? = nil, cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws -> RepositoryBrowserExport {
        let backend = backend ?? snapshot.acceptedBackend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        guard snapshot.root == root, snapshot.objectID != nil,
              entry.map({ snapshot.entries.contains($0) && $0.kind != .submodule }) ?? true else { throw RepositoryBrowserFailure.selection }
        try RepositoryBrowserTransferPolicy.validate(snapshot,entries:entry.map{[$0]} ?? [])
        if entry?.kind == .directory || entry == nil {
            let inventory=try repositoryBrowserTransferInventory(snapshot,directory:entry?.path ?? snapshot.directory,cancellation:cancellation)
            try RepositoryBrowserTransferPolicy.validate(snapshot,entries:inventory)
        }
        let manager = FileManager.default
        let container = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitBrowserExport-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var count = 0
        func writeFile(_ listing: RepositoryBrowserSnapshot, _ value: RepositoryBrowserEntry, to url: URL) throws {
            try cancellation?.check()
            let content = try materializedRepositoryBrowserFile(listing, entry: value, cancellation: cancellation, backend: backend)
            try cancellation?.check()
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.bytes.write(to: url, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: value.kind == .executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            count += 1
        }
        func writeDirectory(_ listing: RepositoryBrowserSnapshot, to url: URL) throws {
            try cancellation?.check()
            // Each Git directory must create its own native directory. Reusing
            // an existing directory silently merges Unicode/case aliases.
            try manager.createDirectory(at:url,withIntermediateDirectories:false)
            for value in listing.entries {
                try cancellation?.check()
                if value.kind == .submodule { continue }
                let destination = url.appendingPathComponent(value.name)
                if value.kind == .directory {
                    try writeDirectory(browseRepositoryDirectory(snapshot, directory: value.path, cancellation: cancellation), to: destination)
                } else { try writeFile(listing, value, to: destination) }
            }
        }
        do {
            let name = entry?.name ?? (snapshot.directory.isEmpty ? root.lastPathComponent : (snapshot.directory as NSString).lastPathComponent)
            guard RepositoryBrowserListing.validPath(name, allowRoot: false), !name.contains("/") else { throw RepositoryBrowserFailure.selection }
            let destination = container.appendingPathComponent(name)
            if let entry, entry.kind != .directory { try writeFile(snapshot, entry, to: destination) }
            else {
                let listing = try entry.map { try browseRepositoryDirectory(snapshot, directory: $0.path, cancellation: cancellation) } ?? snapshot
                try writeDirectory(listing, to: destination)
            }
            try cancellation?.check()
            guard count > 0 else { throw RepositoryBrowserFailure.selection }
            return RepositoryBrowserExport(directory: container, item: destination, fileCount: count)
        } catch { try? manager.removeItem(at: container); throw error }
    }
    public func validateRepositoryBrowserWorkingPath(_ snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry,cancellation:OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard snapshot.root == root, !snapshot.bare, snapshot.objectID != nil, snapshot.entries.contains(entry) else {throw RepositoryBrowserFailure.selection}
        try RepositoryBrowserTransferPolicy.validate(snapshot,entries:[entry])
        _ = try restoreLocation(entry.path)
        let components=entry.path.split(separator:"/").map(String.init)
        var target:[String]=[],prefix=""
        for component in components {prefix += (prefix.isEmpty ? "" : "/") + component;target.append(prefix)}
        let records=try run(["-c","core.precomposeUnicode=false","ls-files","--cached","-z","--"],cancellation:cancellation).stdout.split(separator:0)
        var indexed=RepositoryBrowserPathSet(),candidates=[RepositoryBrowserPathSet](repeating:RepositoryBrowserPathSet(),count:target.count)
        for record in records {
            try cancellation?.check()
            guard let path=String(data:Data(record),encoding:.utf8) else {continue}
            var prefix=""
            for (index,component) in path.split(separator:"/").enumerated() where index < target.count {
                prefix += (prefix.isEmpty ? "" : "/") + component
                indexed.insert(prefix)
                if !RepositoryBrowserPathIdentity.equal(prefix,target[index]),prefix.compare(target[index],options:.caseInsensitive) == .orderedSame {
                    candidates[index].insert(prefix)
                }
            }
        }
        func identity(_ path:String)throws->(dev_t,ino_t)? {
            try cancellation?.check()
            var info=stat()
            if path.withCString({lstat($0,&info)}) == 0 {return(info.st_dev,info.st_ino)}
            if errno == ENOENT || errno == ENOTDIR {return nil}
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        var listings:[Data:[String]]=[:]
        func names(_ parent:String)throws->[String] {
            try cancellation?.check()
            let key=Data(parent.utf8)
            if let cached=listings[key] {return cached}
            let values=try FileManager.default.contentsOfDirectory(atPath:parent)
            listings[key]=values;return values
        }
        func hasLiteralLeaf(_ relative:String)throws->Bool {
            let parts=relative.split(separator:"/")
            let parent=root.path + (parts.count > 1 ? "/" + parts.dropLast().joined(separator:"/"):"")
            guard try identity(parent) != nil else{return false}
            return try names(parent).contains {RepositoryBrowserPathIdentity.equal($0,String(parts.last!))}
        }
        for (index,relative) in target.enumerated() {
            try cancellation?.check()
            let location=root.path + "/" + relative
            guard let requested=try identity(location) else {break}
            // Consult actual lookup identity, rather than assuming all volumes
            // fold case/Unicode. Separate files on sensitive volumes are safe.
            for candidate in candidates[index].sorted(by:{$0.utf8.lexicographicallyPrecedes($1.utf8)}) {
                guard let other=try identity(root.path + "/" + candidate),requested.0 == other.0,requested.1 == other.1 else {continue}
                // Distinct directory entries may deliberately be hard links.
                if try hasLiteralLeaf(relative) && hasLiteralLeaf(candidate) {continue}
                throw RepositoryBrowserFailure.normalizationCollision(entry.path)
            }
            let parent=root.path + (index > 0 ? "/" + target[index-1]:"")
            let siblings=try names(parent),name=components[index]
            if siblings.contains(where:{RepositoryBrowserPathIdentity.equal($0,name)}) {continue}
            for sibling in siblings {
                try cancellation?.check()
                guard let other=try identity(parent + "/" + sibling),requested.0 == other.0,requested.1 == other.1 else {continue}
                // macOS may expose NFD disk spelling for an indexed NFC name.
                // Only its exact indexed scope can authorize that spelling;
                // an untracked/ignored or differently cased alias cannot.
                if indexed.contains(relative),sibling == name {continue}
                throw RepositoryBrowserFailure.normalizationCollision(entry.path)
            }
        }
        try cancellation?.check()
    }
    /// Resolve the child checkout at the gitlink displayed by this pinned tree.
    /// Availability may be false; this never initializes or fetches a submodule.
    public func repositoryBrowserSubmodule(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil) async throws -> SubmoduleComparison {
        try cancellation?.check()
        guard snapshot.root == root, !snapshot.bare, snapshot.entries.contains(entry),
              entry.kind == .submodule, let object = snapshot.objectID else { throw RepositoryBrowserFailure.selection }
        try validateRepositoryBrowserWorkingPath(snapshot,entry:entry,cancellation:cancellation)
        let result = try await submoduleComparison(path: entry.path, from: object, to: object, cancellation: cancellation,backend:snapshot.acceptedBackend)
        guard result.from.revision == entry.objectID else { throw RepositoryBrowserFailure.selection }
        return result
    }
    /// Restore one displayed ordinary file to the pinned browser revision,
    /// updating both index and working tree like RepositoryBrowser.cpp checkout.
    /// The caller sequences files and decides Continue/Cancel after each error.
    public func revertRepositoryBrowserFile(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard snapshot.root == root, !snapshot.bare, try !isBare(cancellation: cancellation),
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind),
              let object = snapshot.objectID, [40, 64].contains(object.count), object.allSatisfy(\.isHexDigit) else { throw RepositoryBrowserFailure.selection }
        try validateRepositoryBrowserWorkingPath(snapshot,entry:entry,cancellation:cancellation)
        _ = try restoreLocation(entry.path)
        // This is a pinned hexadecimal object ID, never a command-line option.
        // Older supported Git versions do not accept checkout --end-of-options.
        _ = try run(["-c", "core.precomposeUnicode=false", "checkout", object, "--", entry.path], cancellation: cancellation)
    }
    public func repositoryBrowserFile(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil) throws -> ComparisonFileContent {
        try cancellation?.check()
        guard snapshot.root == root, snapshot.entries.contains(entry), entry.kind != .directory, let object = snapshot.objectID else { throw RepositoryBrowserFailure.selection }
        if entry.kind == .submodule {
            return ComparisonFileContent(path: entry.displayPath + ".txt", revision: .revision(object), bytes: Data(("Subproject commit " + entry.objectID).utf8), mode: "100644")
        }
        return ComparisonFileContent(path: entry.path, revision: .revision(object), bytes: try storedRepositoryBrowserBlob(snapshot,entry:entry,cancellation:cancellation), mode: entry.mode,objectID:entry.objectID)
    }
    /// Stored bytes only: no smudge filters, attributes, pathspecs or native
    /// filenames. The exact row/OID must belong to this pinned tree receipt.
    public func storedRepositoryBrowserBlob(_ snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry,cancellation:OperationCancellation?=nil)throws->Data {
        try cancellation?.check()
        guard snapshot.root==root,snapshot.objectID != nil,snapshot.entries.contains(entry),![.directory,.submodule].contains(entry.kind),
              [40,64].contains(entry.objectID.utf8.count),entry.objectID.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{throw RepositoryBrowserFailure.selection}
        return try run(["cat-file","blob",entry.objectID],cancellation:cancellation).stdout
    }
    /// Deliver the original object under an ASCII filename, independent of its
    /// Git pathname. This deliberately does not apply checkout/smudge filters.
    /// Callers retain the selected tree receipt for ownership; this filename is
    /// only a proposed destination or a leaf inside a private preview directory.
    public func storedRepositoryBrowserFile(_ snapshot:RepositoryBrowserSnapshot,entry:RepositoryBrowserEntry,cancellation:OperationCancellation?=nil)throws->ComparisonFileContent {
        guard let object=snapshot.objectID else{throw RepositoryBrowserFailure.selection}
        let bytes=try storedRepositoryBrowserBlob(snapshot,entry:entry,cancellation:cancellation)
        return ComparisonFileContent(path:entry.storedBlobFilename,revision:.revision(object),bytes:bytes,mode:entry.mode)
    }
    public func materializedRepositoryBrowserFile(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil,
                                                  backend: GitLibGit2Configuration? = nil) throws -> ComparisonFileContent {
        let backend = backend ?? snapshot.acceptedBackend ?? libgit2Configuration ?? .load()
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard snapshot.root == root, snapshot.entries.contains(entry), entry.kind != .directory, let object = snapshot.objectID else { throw RepositoryBrowserFailure.selection }
        if entry.kind == .submodule { return try repositoryBrowserFile(snapshot, entry: entry, cancellation: token) }
        return try materializedBlob(objectID: entry.objectID, path: entry.path, revision: object, mode: entry.mode, cancellation: token, backend: backend)
    }
}

/// Native persistence for RepositoryBrowser.cpp's three-column ColumnManager.
public struct RepositoryBrowserColumns: Equatable, Sendable {
    public static let names = ["name", "extension", "size"]
    public var visible: Set<String>
    public var order: [String]
    public var widths: [String:Double]
    public init(visible:Set<String> = Set(Self.names),order:[String] = Self.names,widths:[String:Double] = [:]) {
        self.visible=visible.intersection(Self.names).union(["name"])
        var seen=Set<String>();self.order=(order+Self.names).filter { Self.names.contains($0) && seen.insert($0).inserted }
        self.widths=widths.filter { Self.names.contains($0.key) && $0.value.isFinite && $0.value>=24 }.mapValues { min(10000,$0) }
    }
    public static func load(_ preferences:UserDefaults,key:String = "RepositoryBrowser.Columns") -> Self {
        guard preferences.integer(forKey:key+".Version")==6 else { return Self() }
        var widths:[String:Double]=[:]
        for (name,value) in preferences.dictionary(forKey:key+".Widths") ?? [:] { if let number=value as? NSNumber { widths[name]=number.doubleValue } }
        return Self(visible:Set(preferences.stringArray(forKey:key) ?? names),order:preferences.stringArray(forKey:key+".Order") ?? names,widths:widths)
    }
    public func save(_ preferences:UserDefaults,key:String = "RepositoryBrowser.Columns") {
        let normalized=Self(visible:visible,order:order,widths:widths)
        preferences.set(6,forKey:key+".Version");preferences.set(Self.names.filter { normalized.visible.contains($0) },forKey:key)
        preferences.set(normalized.order,forKey:key+".Order");preferences.set(normalized.widths,forKey:key+".Widths")
    }
}
