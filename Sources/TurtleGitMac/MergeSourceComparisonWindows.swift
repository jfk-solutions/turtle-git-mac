import AppKit
import TurtleGitCore

/// DiffLeftToBase / DiffRightToBase open an independent comparison of captured
/// source stages. Private read-only copies never redirect writes to a Git stage.
@MainActor enum MergeSourceComparisonWindows {
    private static var windows: [UUID: (FileComparisonWindowController, URL)] = [:]
    @discardableResult static func open(base: Data, side: Data, name: String, sideName: String, preferences: UserDefaults,
        baseEncoding:ComparisonTextEncoding?=nil,sideEncoding:ComparisonTextEncoding?=nil,baseTitle:String?=nil,sideTitle:String?=nil,sourceWindow:NSWindow?=nil,
        configure:((FileComparisonWindowController)->Void)?=nil) throws -> FileComparisonWindowController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSourceCompare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var prepared:FileComparisonWindowController?
        do {
            let filename = (name as NSString).lastPathComponent
            let left = folder.appendingPathComponent("Base-" + filename), right = folder.appendingPathComponent(sideName + "-" + filename)
            try base.write(to: left, options: .atomic); try side.write(to: right, options: .atomic)
            for file in [left, right] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path) }
            let grants = [RepositoryAccessLease(url: folder)]
            // Store builds retain their container folder; source bytes are
            // captured from the already authorized document, not reread outside it.
            // Construction can materialize SwiftUI and accept an initial load.
            // Configure source labels/codecs/read-only ownership before that load.
            let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left, destination: right), permissions: grants, preferences: preferences, deferInitialLoad:true)
            prepared=controller
            controller.model.configureSourceComparisonTitles(base:baseTitle ?? "Base",side:sideTitle ?? sideName)
            controller.model.configureInputEncodings(base:baseEncoding,destination:sideEncoding)
            try controller.model.retainSourceSnapshotDirectory(folder)
            controller.model.useInternalMergeViewer()
            if let sourceWindow {controller.window?.alphaValue=sourceWindow.alphaValue;controller.window?.appearance=sourceWindow.effectiveAppearance}
            let id = UUID(); windows[id] = (controller, folder)
            controller.onClosed = { windows.removeValue(forKey: id); try? FileManager.default.removeItem(at: folder) }
            configure?(controller)
            if !controller.model.inputEncodingOwnerRetired {controller.showWindow(nil); controller.model.beginTransferredDocument()}
            return controller
        } catch {
            // A failed pre-load setup still owns a native host and observers.
            // No input read has started while the deferred flag is retained.
            prepared?.close()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
