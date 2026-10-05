// Native adaptation of TortoiseGit RepositoryBrowser.cpp tree/list workflows.
// Copyright (C) 2009-2026 - TortoiseGit; 2003-2013 - TortoiseSVN. GPL-2.0-or-later.
import Foundation

public struct RepositoryBrowserEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case directory, file, executable, symlink, submodule }
    public let path: String
    public let name: String
    public let mode: String
    public let objectID: String
    public let size: Int64?
    public var id: String { path }
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
    public var errorDescription: String? {
        switch self {
        case .revision: return "Choose a revision containing a commit or tree."
        case .directory: return "The selected directory does not exist at this revision."
        case .output: return "Git returned an invalid repository tree."
        case .selection: return "Choose a file from the displayed repository revision."
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
    public func browseRepository(revision: String = "HEAD", directory: String = "") throws -> RepositoryBrowserSnapshot {
        guard RepositoryBrowserListing.validPath(directory, allowRoot: true) else { throw RepositoryBrowserFailure.directory }
        guard !revision.isEmpty, !revision.utf8.contains(0) else { throw RepositoryBrowserFailure.revision }
        let bare = try isBare()
        if revision == "HEAD", try run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1).exitCode == 1 {
            // An unborn symbolic HEAD has an empty browser, not an invalid-revision alert.
            let ref = try run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
            guard try run(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1).exitCode == 1 else { throw RepositoryBrowserFailure.revision }
            return RepositoryBrowserSnapshot(root: root, revision: revision, objectID: nil, treeID: nil, directory: "", bare: bare, entries: [])
        }
        let object = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{}"]).text.trimmingCharacters(in: .newlines)
        let tree: String
        do { tree = try run(["rev-parse", "--verify", "--end-of-options", object + "^{tree}"]).text.trimmingCharacters(in: .newlines) }
        catch { throw RepositoryBrowserFailure.revision }
        return try browseRepositoryTree(revision: revision, objectID: object, treeID: tree, directory: directory, bare: bare)
    }
    public func browseRepositoryDirectory(_ snapshot: RepositoryBrowserSnapshot, directory: String) throws -> RepositoryBrowserSnapshot {
        guard snapshot.root == root, RepositoryBrowserListing.validPath(directory, allowRoot: true),
              let tree = snapshot.treeID, let object = snapshot.objectID else { throw RepositoryBrowserFailure.directory }
        return try browseRepositoryTree(revision: snapshot.revision, objectID: object, treeID: tree, directory: directory, bare: snapshot.bare)
    }
    private func browseRepositoryTree(revision: String, objectID: String, treeID: String, directory: String, bare: Bool) throws -> RepositoryBrowserSnapshot {
        let subtree: String
        do {
            subtree = directory.isEmpty ? treeID : try run(["rev-parse", "--verify", "--end-of-options", treeID + ":" + directory]).text.trimmingCharacters(in: .newlines)
            guard try run(["cat-file", "-t", subtree]).text == "tree\n" else { throw RepositoryBrowserFailure.directory }
        } catch { throw RepositoryBrowserFailure.directory }
        let entries = try RepositoryBrowserListing.parse(run(["ls-tree", "-z", "-l", subtree, "--"]).stdout, directory: directory)
        return RepositoryBrowserSnapshot(root: root, revision: revision, objectID: objectID, treeID: treeID, directory: directory, bare: bare, entries: entries)
    }
    public func repositoryBrowserFile(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry) throws -> ComparisonFileContent {
        guard snapshot.root == root, snapshot.entries.contains(entry), entry.kind != .directory, let object = snapshot.objectID else { throw RepositoryBrowserFailure.selection }
        if entry.kind == .submodule {
            return ComparisonFileContent(path: entry.path + ".txt", revision: .revision(object), bytes: Data(("Subproject commit " + entry.objectID).utf8), mode: "100644")
        }
        return ComparisonFileContent(path: entry.path, revision: .revision(object), bytes: try run(["cat-file", "blob", entry.objectID]).stdout, mode: entry.mode)
    }
}
