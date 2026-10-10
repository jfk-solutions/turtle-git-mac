import Foundation

public enum ImageConflictSide: String, CaseIterable, Identifiable, Sendable {
    case mine = "Mine", base = "Base", theirs = "Theirs"
    public var id: String { rawValue }
}
public struct ImageConflictDocument {
    public let entry: ConflictEntry
    public let mineStage: Int
    public let theirsStage: Int
    public let contents: [ImageConflictSide: Data]
    public let workingContents: Data?
    public let permissions: Int
    public func image(_ side: ImageConflictSide) -> ComparisonImage? { contents[side].flatMap { ComparisonImage(bytes: $0) } }
}
public enum ImageConflictFailure: LocalizedError {
    case unavailable, changedWorkingFile, readOnly
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This conflict side has no image to select."
        case .changedWorkingFile: return "The working image or its permissions changed. Reload before selecting or marking it resolved."
        case .readOnly: return "The working image is read-only."
        }
    }
}
extension GitRepository {
    /// Image routing examines original stage bytes, independent of extensions.
    /// A missing base is allowed for add/add conflicts; selection stays unavailable.
    public func imageConflictDocument(path: String, cancellation: OperationCancellation? = nil) throws -> ImageConflictDocument? {
        try cancellation?.check()
        guard let entry = try conflicts(paths: [path]).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard !entry.isSubmodule, !entry.isDeleteModify,
              entry.stages.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else { return nil }
        try validateConflicts([entry], using: .current)
        let rebase = try conflictIsRebase(), mineStage = rebase ? 3 : 2, theirsStage = rebase ? 2 : 3
        var contents: [ImageConflictSide: Data] = [:]
        for (side, stage) in [(ImageConflictSide.mine, mineStage), (.base, 1), (.theirs, theirsStage)] {
            guard let object = entry.stages.first(where: { $0.number == stage })?.object else { continue }
            let bytes = try run(["cat-file", "blob", object], cancellation: cancellation).stdout
            guard ComparisonImage(bytes: bytes) != nil else { return nil }
            contents[side] = bytes
        }
        try cancellation?.check()
        guard contents[.mine] != nil, contents[.theirs] != nil else { return nil }
        let (working, permissions) = try conflictWorkingSnapshot(root.appendingPathComponent(path))
        return ImageConflictDocument(entry: entry, mineStage: mineStage, theirsStage: theirsStage, contents: contents,
                                     workingContents: working, permissions: permissions ?? (entry.stages.first { $0.number == mineStage }?.mode == "100755" ? 0o755 : 0o644))
    }
    private func validateImageWorkingFile(_ document: ImageConflictDocument) throws {
        try validateConflicts([document.entry], using: .current)
        let current: Data?, permissions: Int?
        do { (current, permissions) = try conflictWorkingSnapshot(root.appendingPathComponent(document.entry.path)) }
        catch TextConflictFailure.unsupported { throw ImageConflictFailure.changedWorkingFile }
        guard current == document.workingContents, permissions == nil || permissions == document.permissions else { throw ImageConflictFailure.changedWorkingFile }
    }
    /// Copy exact bytes first, leaving conflict stages intact until confirmation.
    public func selectImageConflict(_ document: ImageConflictDocument, side: ImageConflictSide, cancellation: OperationCancellation? = nil) throws -> ImageConflictDocument {
        try cancellation?.check()
        try validateImageWorkingFile(document)
        try cancellation?.check()
        guard let bytes = document.contents[side] else { throw ImageConflictFailure.unavailable }
        let location = root.appendingPathComponent(document.entry.path)
        if document.workingContents != nil && !FileManager.default.isWritableFile(atPath: location.path) { throw ImageConflictFailure.readOnly }
        try bytes.write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: document.permissions], ofItemAtPath: location.path)
        return ImageConflictDocument(entry: document.entry, mineStage: document.mineStage, theirsStage: document.theirsStage,
                                     contents: document.contents, workingContents: bytes, permissions: document.permissions)
    }
    public func markImageConflictResolved(_ document: ImageConflictDocument, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        try validateImageWorkingFile(document)
        try cancellation?.check()
        return try run(["add", "-f", "--", document.entry.path]).text
    }
}
