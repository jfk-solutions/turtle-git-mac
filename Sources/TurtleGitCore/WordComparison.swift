// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts the modern Word branch of contrib/diff-scripts/diff-doc.js.
import Foundation

public enum WordComparisonFailure: LocalizedError, Sendable {
    case application, absent
    case automation(Int, String, possiblyOpened: Bool)
    public var possiblyOpened: Bool {
        if case .automation(_, _, let value) = self { return value }; return false
    }
    public var errorDescription: String? {
        switch self {
        case .application: return "Microsoft Word is required for this comparison. Install Word or choose another diff tool in Settings."
        case .absent: return "Word comparison requires two existing document files."
        case .automation(let code, let message, _):
            if code == -1743 { return "Allow TurtleGit to control Microsoft Word in macOS System Settings → Privacy & Security → Automation, then retry the comparison." }
            return "Word could not create the comparison (\(code)): " + message
        }
    }
}
public struct WordComparisonPreview: Sendable {
    public let directory: URL
    public let base: URL
    public let destination: URL
    public static func prepare(_ document: FileComparisonDocument, in root: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        guard !document.base.isDeleted, !document.destination.isDeleted else { throw WordComparisonFailure.absent }
        let manager = FileManager.default, directory = root.appendingPathComponent("TurtleGitWordDiff-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        do {
            func copy(_ content: ComparisonFileContent, side: String) throws -> URL {
                try cancellation.check()
                let folder = directory.appendingPathComponent(side, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
                let name = (content.path as NSString).lastPathComponent
                let target = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? side + ".docx" : name)
                try content.bytes.write(to: target, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions:0o444], ofItemAtPath:target.path)
                try cancellation.check(); return target
            }
            let base = try copy(document.base, side:"base"), destination = try copy(document.destination, side:"new")
            try cancellation.check(); return Self(directory:directory, base:base, destination:destination)
        } catch { try? manager.removeItem(at:directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at:directory) }
}
