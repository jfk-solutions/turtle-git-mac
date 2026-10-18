// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Cached eligibility only. Finder does not run Git or authorize source access.
public enum FinderTransferContext {
    /// Source-only entry for selected Finder items. Unknown/unversioned sources
    /// can be copied into a working tree; cached repository roots are excluded.
    /// Reading this projection performs no Git operation or authorization.
    public static func sourceRequest(selection: [URL], snapshot: FinderSnapshot?, settings: FinderMenuSettings) -> FinderRequest? {
        guard settings.clipboardTransfers, !selection.isEmpty, selection.count <= 256 else { return nil }
        let sources = FinderRequest.normalizedSelection(selection)
        guard !sources.isEmpty, sources.allSatisfy({ url in
            guard url.isFileURL, url.path != "/", !url.path.contains("\0"),
                  !url.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType,
                  [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else { return false }
            if let root = snapshot?.repositoryRoot(for: url) {
                guard snapshot?.isRepositoryRoot(url, root: root) != true, snapshot?.repositories[root]?.bare != true else { return false }
            }
            return true
        }) else { return nil }
        let request = FinderRequest(action: .transferFiles, paths: sources)
        return request.url == nil ? nil : request
    }
    public static func requests(destination: URL?, sources: [URL], snapshot: FinderSnapshot?, settings: FinderMenuSettings) -> [FinderRequest] {
        guard settings.clipboardTransfers, let destination, let snapshot,
              destination.isFileURL, !destination.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let root = snapshot.repositoryRoot(for: destination), snapshot.repositories[root]?.bare == false,
              !sources.isEmpty, sources.allSatisfy({ $0.isFileURL && !$0.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) }) else { return [] }
        let copy = FinderRequest(action: .pasteCopy, paths: [destination], sources: sources)
        guard copy.url != nil else { return [] }
        var result = [copy]
        if sources.allSatisfy({ source in
            let sourceRoot = snapshot.fileOperationOwner(for: source)
            return sourceRoot.map({GitReferenceName.equal($0,root)}) == true && snapshot.canRename([source]) && (try? FileManager.default.attributesOfItem(atPath: source.path)) != nil
        }) {
            let move = FinderRequest(action: .pasteMove, paths: [destination], sources: sources)
            if move.url != nil { result.append(move) }
        }
        return result
    }
}
