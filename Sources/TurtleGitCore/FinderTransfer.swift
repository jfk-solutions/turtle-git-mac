// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Cached eligibility only. Finder does not run Git or authorize source access.
public enum FinderTransferContext {
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
            let sourceRoot = snapshot.repositories[source.path]?.submoduleParentRoot ?? snapshot.repositoryRoot(for: source)
            return sourceRoot == root && snapshot.canRename([source]) && (try? FileManager.default.attributesOfItem(atPath: source.path)) != nil
        }) {
            let move = FinderRequest(action: .pasteMove, paths: [destination], sources: sources)
            if move.url != nil { result.append(move) }
        }
        return result
    }
}
