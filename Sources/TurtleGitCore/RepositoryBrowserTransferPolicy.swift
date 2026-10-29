// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RepositoryBrowserTransferFailure: LocalizedError {
    case unrepresentablePath(String)
    case incompleteInventory
    public var errorDescription: String? {
        switch self {
        case .unrepresentablePath(let display):
            return "This historical path cannot be delivered as a native filename: " + display + ". View its stored blob or copy its object ID instead."
        case .incompleteInventory:
            return "The complete historical folder inventory is required before transferring this selection."
        }
    }
}

/// Git may contain names that cannot be represented by a native String path.
/// Display escaping is never a replacement filename or a command argument.
public enum RepositoryBrowserTransferPolicy {
    public static func validateDirectory(_ key:String) throws {
        let path=try RepositoryBrowserGitPath(key:key)
        guard path.isRepresentable else {throw RepositoryBrowserTransferFailure.unrepresentablePath(path.display)}
    }
    public static func validate(_ snapshot:RepositoryBrowserSnapshot,entries:[RepositoryBrowserEntry]) throws {
        guard snapshot.isDirectoryRepresentable else {
            throw RepositoryBrowserTransferFailure.unrepresentablePath(snapshot.displayDirectory)
        }
        for entry in entries where !entry.isPathRepresentable {
            throw RepositoryBrowserTransferFailure.unrepresentablePath(entry.displayPath)
        }
    }
    /// Historical files are independently delivered under safe proposed leaves;
    /// a raw containing directory is not itself materialized by this admission.
    public static func validateHistoricalFiles(_ snapshot:RepositoryBrowserSnapshot,entries:[RepositoryBrowserEntry])throws {
        for entry in entries {
            guard let object=snapshot.objectID,[40,64].contains(object.utf8.count),object.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
                  snapshot.entries.contains(entry),[.file,.executable,.symlink].contains(entry.kind) else {throw RepositoryBrowserFailure.selection}
            _ = try HistoricalFileDeliveryName.transferLeaf(path:entry.path)
        }
    }
    /// Inventory can cover the entire root. A raw name in an unrelated folder
    /// must not prevent delivery of a valid selected sibling file or folder.
    public static func validateSelection(_ snapshot:RepositoryBrowserSnapshot,selected:[RepositoryBrowserEntry],inventory:[RepositoryBrowserEntry]?) throws {
        let files=selected.filter{[.file,.executable,.symlink].contains($0.kind)}
        try validateHistoricalFiles(snapshot,entries:files)
        // Directory/gitlink delivery keeps the literal-name contract. A safe
        // sibling file cannot silently rename an unsupported folder descendant.
        let literal=selected.filter{![.file,.executable,.symlink].contains($0.kind)}
        if !literal.isEmpty {try validate(snapshot,entries:literal)}
        let directories=selected.filter{$0.kind == .directory}
        guard !directories.isEmpty else{return}
        guard let inventory else{throw RepositoryBrowserTransferFailure.incompleteInventory}
        for directory in directories {
            let prefix=directory.rawPath+Data([47])
            try validate(snapshot,entries:inventory.filter{$0.rawPath.starts(with:prefix)})
        }
    }
}
