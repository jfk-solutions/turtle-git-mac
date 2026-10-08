// Adapts SetSavedDataPage.cpp and GetTortoiseGitTempPath (GPL-2.0-or-later; see NOTICE).
import Foundation

public enum TurtleGitTemporaryStorage {
    public static var defaultRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTemporaryFiles", isDirectory: true) }
    public static var root: URL { get throws { let store = TemporaryFileStore(root: defaultRoot); try store.prepare(); return store.root } }
}
public struct TemporaryFileStore: Sendable {
    public let root: URL
    public init(root: URL = TurtleGitTemporaryStorage.defaultRoot) { self.root = root }
    private func validateRoot() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadInvalidFileName) }
    }
    public func prepare() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try validateRoot()
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func clear() throws -> Int {
        let manager = FileManager.default
        // A missing folder is already clear. Never follow a substituted root link.
        do { try validateRoot() }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return 0 }
        var previous = Int.max
        while true {
            let items = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for item in items { try? manager.removeItem(at: item) }
            let remaining = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count
            if remaining == 0 || remaining >= previous { return remaining }
            previous = remaining
        }
    }
}
