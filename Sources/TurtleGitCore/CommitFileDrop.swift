// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct CommitDroppedItem: Sendable {
    public let path: String
    public let directory: Bool
    public let added: Bool
    public let error: String?
}

public struct WorkingFileDropItem: Sendable {
    public let path: String
    public let directory: Bool
}

extension GitRepository {
    /// Shared Add/Commit membership query. It does not stage or change disk items.
    public func resolveWorkingFileDrops(_ urls: [URL], cancellation: OperationCancellation? = nil) throws -> [WorkingFileDropItem] {
        try cancellation?.check()
        guard try !isBare(cancellation: cancellation) else { throw WorkingFileRestoreFailure.location }
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<Data>(), results: [WorkingFileDropItem] = []
        let index = try fileTransferIndex(cancellation:cancellation)
        for url in urls {
            try cancellation?.check()
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", !url.path.contains("\0") else { continue }
            let local = FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(url.path))
            let isRoot = local.path.utf8.elementsEqual(root.path.utf8) || local.path.utf8.elementsEqual(physicalRoot.path.utf8)
            // Resolve parents, never a leaf link: Git adds that link's own bytes.
            let parent = local.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let location = isRoot ? physicalRoot : FileTransferPaths.fileURL(parent.path + "/" + local.lastPathComponent)
            let rootParts = physicalRoot.pathComponents, parts = location.pathComponents
            guard parts.count >= rootParts.count, zip(rootParts, parts).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) }) else { continue }
            let components = Array(parts.dropFirst(rootParts.count))
            guard !components.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
                  let type = attributes[.type] as? FileAttributeType, [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else { continue }
            let directory = type == .typeDirectory
            let queryRoot = directory ? location : location.deletingLastPathComponent()
            guard let discovery = try? run(["-C", queryRoot.path, "rev-parse", "--show-toplevel"], cancellation: cancellation) else { try cancellation?.check(); continue }
            var bytes = discovery.stdout; if bytes.last == 10 { bytes.removeLast() }
            guard let discovered = String(data: bytes, encoding: .utf8),
                  URL(fileURLWithPath: discovered).resolvingSymlinksInPath().path.utf8.elementsEqual(physicalRoot.path.utf8) else { continue }
            var requested = components.joined(separator:"/")
            // Preserve logical Git components when parent resolution changed only
            // root aliases or Unicode spelling. A semantic symlink-parent change
            // continues to use its actual repository-relative destination.
            let localParts = local.path.split(separator:"/").map(String.init)
            for base in [root.path,physicalRoot.path] {
                let baseParts = base.split(separator:"/").map(String.init)
                guard localParts.count >= baseParts.count,zip(baseParts,localParts).allSatisfy({$0.0 == $0.1}) else{continue}
                let relative = Array(localParts.dropFirst(baseParts.count))
                let relativeParent = relative.dropLast().joined(separator:"/")
                let expectedParent = physicalRoot.path + (relativeParent.isEmpty ? "":"/"+relativeParent)
                if relative.isEmpty || expectedParent == parent.path {requested=relative.joined(separator:"/");break}
            }
            let path = requested.isEmpty ? "." : try index.resolvingForIndex(requested)
            guard seen.insert(Data(path.utf8)).inserted else { continue }
            results.append(WorkingFileDropItem(path: path, directory: directory))
        }
        return results
    }
    /// CommitDlg::OnFileDropped uses ordinary add without -f, one item at a time.
    public func addDroppedCommitFiles(_ urls: [URL], cancellation: OperationCancellation? = nil) throws -> [CommitDroppedItem] {
        let items = try resolveWorkingFileDrops(urls, cancellation: cancellation)
        var results: [CommitDroppedItem] = []
        for item in items {
            try cancellation?.check()
            let added:GitResult
            if item.directory, let paths = try droppedDirectoryAddPaths(item.path,cancellation:cancellation),!paths.isEmpty {
                added = try run(["add","--pathspec-from-file=-","--pathspec-file-nul"],successfulExitCodes:0...128,cancellation:cancellation,input:literalPathPacket(paths))
            } else {
                added = try run((item.directory ? []:["-c","core.precomposeunicode=false"]) + ["add","--",item.path],successfulExitCodes:0...128,cancellation:cancellation)
            }
            results.append(CommitDroppedItem(path: item.path, directory: item.directory, added: added.exitCode == 0,
                error: added.exitCode == 0 ? nil : String(added.text.prefix(4096))))
        }
        return results
    }

    /// Let Git exclude ignored files and stop at nested repositories. Expand
    /// directory requests into exact index names before Add walks the filesystem.
    private func droppedDirectoryAddPaths(_ scope:String,cancellation:OperationCancellation?) throws -> [String]? {
        let index = try fileTransferIndex(cancellation:cancellation)
        var result = GitPathSet(index.paths.filter {scope == "." || FileTransferPaths.contains($0,in:scope)})
        let data = try run(["-c","core.precomposeunicode=false","ls-files","--others","--exclude-standard","-z"],cancellation:cancellation).stdout
        let precompose = try run(["config","--bool","--get","core.precomposeunicode"],successfulExitCodes:0...1,cancellation:cancellation).text == "true\n"
        let scopeParts = scope == "." ? []:scope.split(separator:"/").map(String.init)
        for record in data.split(separator:0) {
            try cancellation?.check()
            guard let path=String(data:Data(record),encoding:.utf8) else{continue}
            let parts=path.split(separator:"/").map(String.init)
            if !scopeParts.isEmpty {
                guard parts.count >= scopeParts.count,zip(scopeParts,parts).allSatisfy({index.localEquivalent($0.0,$0.1)}) else{continue}
            }
            let prefix = scopeParts.isEmpty ? "":scopeParts.joined(separator:"/")+"/"
            let tail = parts.dropFirst(scopeParts.count).map {precompose ? $0.precomposedStringWithCanonicalMapping:$0}.joined(separator:"/")
            let candidate = try index.resolvingForIndex(prefix+tail)
            if !candidate.isEmpty {result.insert(candidate)}
        }
        return result.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)}
    }

}
