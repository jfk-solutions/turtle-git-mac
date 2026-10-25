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
    /// Inventory can cover the entire root. A raw name in an unrelated folder
    /// must not prevent delivery of a valid selected sibling file or folder.
    public static func validateSelection(_ snapshot:RepositoryBrowserSnapshot,selected:[RepositoryBrowserEntry],inventory:[RepositoryBrowserEntry]?) throws {
        try validate(snapshot,entries:selected)
        let directories=selected.filter{$0.kind == .directory}
        guard !directories.isEmpty else{return}
        guard let inventory else{throw RepositoryBrowserTransferFailure.incompleteInventory}
        for directory in directories {
            let prefix=directory.rawPath+Data([47])
            try validate(snapshot,entries:inventory.filter{$0.rawPath.starts(with:prefix)})
        }
    }
}
