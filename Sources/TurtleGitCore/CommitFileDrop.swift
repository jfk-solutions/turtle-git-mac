// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct CommitDroppedItem: Sendable {
    public let path: String
    public let directory: Bool
    public let added: Bool
    public let error: String?
}

extension GitRepository {
    /// CommitDlg::OnFileDropped: same repository only, ordinary add without -f,
    /// separate items and continued failures. Never copies or moves disk items.
    public func addDroppedCommitFiles(_ urls: [URL], cancellation: OperationCancellation? = nil) throws -> [CommitDroppedItem] {
        try cancellation?.check()
        guard try !isBare(cancellation: cancellation) else { throw WorkingFileRestoreFailure.location }
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<Data>(), results: [CommitDroppedItem] = []
        for url in urls {
            try cancellation?.check()
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", !url.path.contains("\0") else { continue }
            let local = url.standardizedFileURL
            let isRoot = local.path.utf8.elementsEqual(root.path.utf8) || local.path.utf8.elementsEqual(physicalRoot.path.utf8)
            // Resolve parents, never a leaf link: Git adds that link's own bytes.
            let parent = local.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let location = isRoot ? physicalRoot : parent.appendingPathComponent(local.lastPathComponent)
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
            let path = components.isEmpty ? "." : components.joined(separator: "/")
            guard seen.insert(Data(path.utf8)).inserted else { continue }
            let added = try run(["add", "--", path], successfulExitCodes: 0...128, cancellation: cancellation)
            results.append(CommitDroppedItem(path: path, directory: directory, added: added.exitCode == 0,
                error: added.exitCode == 0 ? nil : String(added.text.prefix(4096))))
        }
        return results
    }
}
