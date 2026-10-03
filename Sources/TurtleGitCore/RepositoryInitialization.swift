import Foundation

public enum InitializationWarning: Hashable, Sendable {
    case specialFolder, nonemptyBare
}
public enum InitializationFailure: LocalizedError {
    case destination, confirmationRequired(Set<InitializationWarning>)
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose a local repository folder."
        case .confirmationRequired: return "Review the destination warnings before creating this repository. The folder may have changed since it was selected."
        }
    }
}
public enum RepositoryInitialization {
    public static func defaultsToBare(_ folder: URL) -> Bool { folder.lastPathComponent.hasSuffix(".git") }
    public static func warnings(for folder: URL, bare: Bool, specialFolders: [URL]? = nil) throws -> Set<InitializationWarning> {
        guard folder.isFileURL, !folder.path.contains("\0") else { throw InitializationFailure.destination }
        var result: Set<InitializationWarning> = []
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let special = specialFolders ?? ([manager.homeDirectoryForCurrentUser]
            + manager.urls(for: .desktopDirectory, in: .userDomainMask)
            + manager.urls(for: .documentDirectory, in: .userDomainMask)
            + ["/", "/System", "/Library", "/Applications", "/Volumes", "/usr", "/bin", "/sbin"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        if special.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path }) {
            result.insert(.specialFolder)
        }
        if specialFolders == nil, let volume = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume,
           volume.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path { result.insert(.specialFolder) }
        var directory: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &directory) {
            guard directory.boolValue else { throw InitializationFailure.destination }
            if bare {
                if !(try manager.contentsOfDirectory(atPath: folder.path)).isEmpty { result.insert(.nonemptyBare) }
            }
        }
        return result
    }
}
extension GitRepository {
    public func initialize(at destination: URL, bare: Bool, confirmedWarnings: Set<InitializationWarning> = []) throws -> String {
        let warnings = try RepositoryInitialization.warnings(for: destination, bare: bare)
        guard warnings.isSubset(of: confirmedWarnings) else { throw InitializationFailure.confirmationRequired(warnings.subtracting(confirmedWarnings)) }
        // Let Git honor init.defaultBranch and GIT_TEMPLATE_DIR. Do not impose main
        // or delete existing contents when creating/reinitializing a repository.
        return try run(["init"] + (bare ? ["--bare"] : []) + ["--", destination.standardizedFileURL.path]).text
    }
}
