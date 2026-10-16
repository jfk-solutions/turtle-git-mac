import AppKit
import TurtleGitCore

/// DiffLeftToBase / DiffRightToBase open an independent comparison of captured
/// source stages. Private read-only copies never redirect writes to a Git stage.
@MainActor enum MergeSourceComparisonWindows {
    private static var windows: [UUID: (FileComparisonWindowController, URL)] = [:]
    @discardableResult static func open(base: Data, side: Data, name: String, sideName: String, preferences: UserDefaults) throws -> FileComparisonWindowController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSourceCompare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let filename = (name as NSString).lastPathComponent
            let left = folder.appendingPathComponent("Base-" + filename), right = folder.appendingPathComponent(sideName + "-" + filename)
            try base.write(to: left, options: .atomic); try side.write(to: right, options: .atomic)
            for file in [left, right] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path) }
            let grants = [RepositoryAccessLease(url: folder)]
            // Store builds retain their container folder; source bytes are
            // captured from the already authorized document, not reread outside it.
            let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left, destination: right), permissions: grants, preferences: preferences)
            try controller.model.retainSourceSnapshotDirectory(folder)
            controller.model.useInternalMergeViewer()
            let id = UUID(); windows[id] = (controller, folder)
            controller.onClosed = { windows.removeValue(forKey: id); try? FileManager.default.removeItem(at: folder) }
            controller.showWindow(nil); controller.model.load()
            return controller
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
