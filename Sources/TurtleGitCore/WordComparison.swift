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
                let other=side=="base" ? document.destination:document.base
                let name=try ComparisonPreviewInputName.leaf(for:content,other:other,side:side,fallbackExtension:"docx")
                let target = folder.appendingPathComponent(name)
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

public enum WordMergeFailure: LocalizedError, Sendable {
    case application
    case automation(Int, String, possiblyOpened: Bool)
    public var possiblyOpened: Bool { if case .automation(_,_,let value) = self { return value }; return false }
    public var errorDescription: String? {
        switch self {
        case .application: return "Microsoft Word is required for document merging. Install Word or choose another merge tool in Settings."
        case .automation(let code,let message,_):
            if code == -1743 { return "Allow TurtleGit to control Microsoft Word in macOS System Settings → Privacy & Security → Automation, then retry the merge." }
            return "Word could not prepare the merge (\(code)): " + message
        }
    }
}
public struct WordMergePreview: Sendable {
    public let directory: URL
    public let base: URL
    public let theirs: URL
    public let mine: URL
    public let result: URL
    public static func prepare(_ input: ExternalMergeInputs, in root: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        guard !input.entry.path.utf8.contains(0) else {throw DiffToolFailure.arguments}
        let manager=FileManager.default,directory=root.appendingPathComponent("TurtleGitWordMerge-"+UUID().uuidString,isDirectory:true)
        try manager.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            func copy(_ bytes:Data,side:String) throws -> URL {
                try cancellation.check()
                let folder=directory.appendingPathComponent(side,isDirectory:true)
                try manager.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let name=HistoricalGitPath.filename(input.entry.path) ?? ""
                let file=folder.appendingPathComponent(side+"-"+(name.isEmpty || name == "." || name == ".." ? "document.docx" : name))
                try bytes.write(to:file,options:.withoutOverwriting)
                // Word's merge works with tracked revisions in private editable
                // documents. Repository stage blobs and working result stay intact.
                try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                try cancellation.check(); return file
            }
            let base=try copy(input.base,side:"base"),theirs=try copy(input.theirs,side:"theirs"),mine=try copy(input.mine,side:"mine")
            return Self(directory:directory,base:base,theirs:theirs,mine:mine,result:input.result)
        } catch { try? manager.removeItem(at:directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at:directory) }
}
