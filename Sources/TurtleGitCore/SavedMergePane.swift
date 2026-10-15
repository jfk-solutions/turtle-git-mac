import Foundation

/// A pane rebound by SaveFileTo. Its current file snapshot, rather than the
/// original repository/stage location, supplies subsequent Save and Reload.
public struct SavedMergePane: Sendable {
    public let url: URL
    public let content: ComparisonFileContent

    public init(url: URL, writtenBytes: Data, encoding: ComparisonTextEncoding?) throws {
        let location = url.standardizedFileURL
        let actual = try WorkingFileComparison.workingContent(at: location)
        guard actual.mode != "120000", actual.bytes == writtenBytes else { throw FileComparisonEditFailure.changed }
        self.url = location
        content = ComparisonFileContent(path: location.path, revision: .workingTree, bytes: actual.bytes,
            mode: actual.mode, permissions: actual.permissions, encoding: encoding ?? actual.encoding)
    }
    private init(url: URL, content: ComparisonFileContent) { self.url = url; self.content = content }
    public func recording(_ saved: ComparisonFileContent) throws -> Self {
        guard saved.path == url.path, saved.revision == .workingTree else { throw RevisionComparisonFailure.selection }
        return Self(url: url, content: saved)
    }
    public func read() throws -> ComparisonFileContent {
        do { return try WorkingFileComparison.workingContent(at: url) }
        catch let error as CocoaError where content.isDeleted && (error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile) { return content }
    }
    public func validate() throws {
        let actual = try read()
        guard actual.bytes == content.bytes, actual.mode == content.mode, actual.permissions == content.permissions,
              actual.isDeleted == content.isDeleted else { throw FileComparisonEditFailure.changed }
    }
    public func save(_ document: FileComparisonDocument, base: Bool, text: String, encoding: ComparisonTextEncoding?, options: MergeFileSaveOptions) throws -> FileComparisonDocument {
        let original = base ? document.base : document.destination
        guard original.path == url.path else { throw RevisionComparisonFailure.selection }
        let saved = try FileComparisonEditing.saveWorkingContent(at: url, original: original, text: text, encoding: encoding, options: options)
        return document.replacingPane(base: base, content: saved)
    }
}

extension FileComparisonDocument {
    public func replacingPane(base: Bool, content: ComparisonFileContent) -> Self {
        Self(base: base ? content : self.base, destination: base ? self.destination : content)
    }
}

extension FileComparisonDrafts {
    public mutating func didSaveAs(_ content: ComparisonFileContent, base: Bool) throws {
        guard content.revision == .workingTree, content.path.hasPrefix("/") else { throw RevisionComparisonFailure.selection }
        // Retain the displayed text, annotations and editing choice while making
        // the new file's bytes/encoding the clean baseline, as SaveFileTo does.
        rebindSavedPane(content, base: base)
    }
}
