import AppKit
import Darwin
import TurtleGitCore

/// The macOS counterpart of SetupBareRepoIcon. Git has already succeeded before
/// this runs; Finder decoration failures are warnings, never a failed Git result.
@MainActor final class BareRepositoryResultSetup {
    private(set) static var activeOperations = 0
    private(set) var pendingOperations = 0
    private var receipts: [String: Task<String?, Never>] = [:]

    var prepare: (URL, OperationCancellation) async throws -> Void = { _, token in try token.check() }
    var hasExistingIcon: (URL) throws -> Bool = BareRepositoryResultSetup.existingIcon
    var loadIcon: () -> NSImage? = { MenuIcon.turtle.image(size: 512) }
    var setIcon: (NSImage, URL) -> Bool = { image, folder in
        NSWorkspace.shared.setIcon(image, forFile: folder.path, options: [])
    }

    func apply(repository: GitRepository, destination: URL, access: RepositoryAccessLease,
               verifiedBare: Bool, cancellation: OperationCancellation) async -> String? {
        guard verifiedBare else { return nil }
        let folder = destination.standardizedFileURL
        do {
            try cancellation.check()
            guard repository.root.standardizedFileURL.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
                  access.contains(folder), !GitRuntime.isAppStoreBuild || access.hasSecurityScope else {
                throw RepositoryAccessFailure.repositoryRootOutsidePermission(folder.path)
            }
            let identity = try Self.identity(folder)
            let key = folder.path + "\0" + identity
            if let receipt = receipts[key] { return await receipt.value }
            let receipt = Task<String?, Never> { @MainActor [self, access] in
                pendingOperations += 1; Self.activeOperations += 1
                defer {
                    pendingOperations -= 1; Self.activeOperations -= 1
                    withExtendedLifetime(access) {}
                }
                do {
                    try await prepare(folder, cancellation)
                    try cancellation.check()
                    guard access.contains(folder), try Self.identity(folder) == identity else {
                        throw RepositoryAccessFailure.repositoryRootOutsidePermission(folder.path)
                    }
                    // Check immediately before mutation, including after an owned
                    // asynchronous preparation. Another owner may have set an icon.
                    if try hasExistingIcon(folder) { return nil }
                    guard let icon = loadIcon() else { throw SetupFailure.missingArtwork }
                    try cancellation.check()
                    guard setIcon(icon, folder) else { throw SetupFailure.iconRejected }
                    // A successful native receipt remains successful if Cancel
                    // arrives after the synchronous NSWorkspace mutation.
                    return nil
                } catch { return Self.warning(folder, error) }
            }
            receipts[key] = receipt
            return await receipt.value
        } catch { return Self.warning(folder, error) }
    }

    private static func warning(_ folder: URL, _ error: Error) -> String {
        "The bare Git repository was created successfully, but its TurtleGit folder icon could not be set at “\(folder.path)”: \(error.localizedDescription) You can set a custom icon later using Finder’s Get Info window."
    }

    private enum SetupFailure: LocalizedError {
        case missingArtwork, iconRejected, invalidFolder
        var errorDescription: String? {
            switch self {
            case .missingArtwork: return "The bundled TurtleGit icon is unavailable."
            case .iconRejected: return "Finder rejected the custom icon. Check the folder’s write permission and file system support."
            case .invalidFolder: return "The destination folder was replaced or is a symbolic link."
            }
        }
    }

    private static func identity(_ folder: URL) throws -> String {
        var value = stat()
        guard lstat(folder.path, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw SetupFailure.invalidFolder }
        return String(value.st_dev) + ":" + String(value.st_ino)
    }

    private static func existingIcon(_ folder: URL) throws -> Bool {
        // Preserve custom icons even if their flag/resource file is incomplete.
        // Desktop.ini is also the upstream "already configured" sentinel; do not
        // replace an existing Windows folder decoration on shared repositories.
        for name in ["Icon\r", "Desktop.ini"] {
            var value = stat()
            let result = lstat(folder.appendingPathComponent(name).path, &value)
            if result == 0 { return true }
            guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let size = bytes.withUnsafeMutableBytes {
            getxattr(folder.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        if size < 0 {
            guard errno == ENOATTR else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return false
        }
        // FinderInfo's big-endian flags are at byte 8; kHasCustomIcon=0x0400.
        // NSWorkspace changes its own metadata; we never rewrite these bytes.
        return size >= 10 && bytes[8] & 0x04 != 0
    }
}
