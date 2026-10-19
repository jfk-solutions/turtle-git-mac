// Native adaptation of TortoiseGit RepositoryBrowser.cpp tree/list workflows.
// Copyright (C) 2009-2026 - TortoiseGit; 2003-2013 - TortoiseSVN. GPL-2.0-or-later.
import Foundation
import Darwin

/// Git path identity is UTF-8 byte identity, not Swift's canonical String equality.
public enum RepositoryBrowserPathIdentity {
    public static func equal(_ a:String,_ b:String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    public static func id(_ path:String) -> String { Data(path.utf8).base64EncodedString() }
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
    public var id: String { RepositoryBrowserPathIdentity.id(path) }
    public static func ==(a:Self,b:Self)->Bool {
        RepositoryBrowserPathIdentity.equal(a.path,b.path) && RepositoryBrowserPathIdentity.equal(a.name,b.name)
            && a.mode == b.mode && a.objectID == b.objectID && a.size == b.size
    }
    public var kind: Kind {
        switch mode { case "040000": return .directory; case "100755": return .executable; case "120000": return .symlink; case "160000": return .submodule; default: return .file }
    }
    public var fileExtension: String { kind == .directory || kind == .submodule ? "" : name.lastIndex(of: ".").map { String(name[$0...]) } ?? "" }
    public var sizeSort: Int64 { size ?? 0 }
}
public struct RepositoryBrowserSnapshot: Sendable {
    public let root: URL
    public let revision: String
    public let objectID: String?
    public let treeID: String?
    public let directory: String
    public let bare: Bool
    public let entries: [RepositoryBrowserEntry]
}
public enum RepositoryBrowserFailure: LocalizedError {
    case revision, directory, output, selection
    case normalizationCollision(String)
    public var errorDescription: String? {
        switch self {
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
    static func validPath(_ path: String, allowRoot: Bool) -> Bool {
        if path.isEmpty { return allowRoot }
        return !path.hasPrefix("/") && !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func parse(_ bytes: Data, directory: String) throws -> [RepositoryBrowserEntry] {
        guard bytes.isEmpty || bytes.last == 0 else { throw RepositoryBrowserFailure.output }
        return try bytes.split(separator: 0).map { record in
            guard let tab = record.firstIndex(of: 9), let name = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8),
                  validPath(name, allowRoot: false), !name.contains("/") else { throw RepositoryBrowserFailure.output }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(whereSeparator: { $0 == " " })
            guard fields.count == 4, ["040000", "100644", "100755", "120000", "160000"].contains(String(fields[0])),
                  [40, 64].contains(fields[2].count), fields[2].allSatisfy(\.isHexDigit) else { throw RepositoryBrowserFailure.output }
            let mode = String(fields[0]), size = Int64(fields[3])
            guard (mode == "040000" && fields[1] == "tree" || mode == "160000" && fields[1] == "commit") && fields[3] == "-" ||
                  (["100644", "100755", "120000"].contains(mode) && fields[1] == "blob" && size != nil && size! >= 0) else { throw RepositoryBrowserFailure.output }
            return RepositoryBrowserEntry(path: directory.isEmpty ? name : directory + "/" + name, name: name, mode: mode, objectID: String(fields[2]), size: size)
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
    public func browseRepository(revision: String = "HEAD", directory: String = "", cancellation: OperationCancellation? = nil) throws -> RepositoryBrowserSnapshot {
        try cancellation?.check()
        guard RepositoryBrowserListing.validPath(directory, allowRoot: true) else { throw RepositoryBrowserFailure.directory }
        guard !revision.isEmpty, !revision.utf8.contains(0) else { throw RepositoryBrowserFailure.revision }
        let bare = try isBare(cancellation: cancellation)
        if revision == "HEAD", try run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 1 {
            // An unborn symbolic HEAD has an empty browser, not an invalid-revision alert.
            let ref = try run(["symbolic-ref", "--quiet", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard try run(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 1 else { throw RepositoryBrowserFailure.revision }
            return RepositoryBrowserSnapshot(root: root, revision: revision, objectID: nil, treeID: nil, directory: "", bare: bare, entries: [])
        }
        let object = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let tree: String
        do { tree = try run(["rev-parse", "--verify", "--end-of-options", object + "^{tree}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        catch { try cancellation?.check(); throw RepositoryBrowserFailure.revision }
        return try browseRepositoryTree(revision: revision, objectID: object, treeID: tree, directory: directory, bare: bare, cancellation: cancellation)
    }
    public func browseRepositoryDirectory(_ snapshot: RepositoryBrowserSnapshot, directory: String, cancellation: OperationCancellation? = nil) throws -> RepositoryBrowserSnapshot {
        try cancellation?.check()
        guard snapshot.root == root, RepositoryBrowserListing.validPath(directory, allowRoot: true),
              let tree = snapshot.treeID, let object = snapshot.objectID else { throw RepositoryBrowserFailure.directory }
        return try browseRepositoryTree(revision: snapshot.revision, objectID: object, treeID: tree, directory: directory, bare: snapshot.bare, cancellation: cancellation)
    }
    private func browseRepositoryTree(revision: String, objectID: String, treeID: String, directory: String, bare: Bool, cancellation: OperationCancellation?) throws -> RepositoryBrowserSnapshot {
        try cancellation?.check()
        let subtree: String
        do {
            subtree = directory.isEmpty ? treeID : try run(["-c", "core.precomposeUnicode=false", "rev-parse", "--verify", "--end-of-options", treeID + ":" + directory], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard try run(["cat-file", "-t", subtree], cancellation: cancellation).text == "tree\n" else { throw RepositoryBrowserFailure.directory }
        } catch { try cancellation?.check(); throw RepositoryBrowserFailure.directory }
        let entries = try RepositoryBrowserListing.parse(run(["ls-tree", "-z", "-l", subtree, "--"], cancellation: cancellation).stdout, directory: directory)
        return RepositoryBrowserSnapshot(root: root, revision: revision, objectID: objectID, treeID: treeID, directory: directory, bare: bare, entries: entries)
    }
    /// Export a displayed item, or the displayed directory when entry is nil.
    /// Adapts RepositoryBrowser.cpp RecursivelyAdd and GitDataObject.cpp historical
    /// file contents (GPL-2.0-or-later). Gitlinks are skipped; symlinks are text.
    /// Copyright (C) 2016-2019, 2021-2023, 2025 TortoiseGit; 2007-2014 TortoiseSVN.
    public func exportRepositoryBrowser(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry? = nil, cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws -> RepositoryBrowserExport {
        let backend = backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        guard snapshot.root == root, snapshot.objectID != nil,
              entry.map({ snapshot.entries.contains($0) && $0.kind != .submodule }) ?? true else { throw RepositoryBrowserFailure.selection }
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
    public func repositoryBrowserSubmodule(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil) throws -> SubmoduleComparison {
        try cancellation?.check()
        guard snapshot.root == root, !snapshot.bare, snapshot.entries.contains(entry),
              entry.kind == .submodule, let object = snapshot.objectID else { throw RepositoryBrowserFailure.selection }
        try validateRepositoryBrowserWorkingPath(snapshot,entry:entry,cancellation:cancellation)
        let result = try submoduleComparison(path: entry.path, from: object, to: object, cancellation: cancellation)
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
              RepositoryBrowserListing.validPath(entry.path, allowRoot: false),
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
            return ComparisonFileContent(path: entry.path + ".txt", revision: .revision(object), bytes: Data(("Subproject commit " + entry.objectID).utf8), mode: "100644")
        }
        return ComparisonFileContent(path: entry.path, revision: .revision(object), bytes: try run(["cat-file", "blob", entry.objectID], cancellation: cancellation).stdout, mode: entry.mode)
    }
    public func materializedRepositoryBrowserFile(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, cancellation: OperationCancellation? = nil,
                                                  backend: GitLibGit2Configuration? = nil) throws -> ComparisonFileContent {
        let backend = backend ?? libgit2Configuration ?? .load()
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
