import Foundation

/// Read-only standalone image inputs. Empty sides and identical paths are valid.
public struct ImageFileComparison: Sendable {
    public let base: URL?
    public let destination: URL?
    public init(base: URL?, destination: URL?) throws {
        guard [base, destination].compactMap({ $0 }).allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { throw ImageFileComparisonFailure.localFileRequired }
        self.base = base?.standardizedFileURL; self.destination = destination?.standardizedFileURL
    }
    public var snapshot: RevisionComparisonSnapshot {
        let file = CommitFile(path: destination?.path ?? "", oldPath: base?.path, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        return RevisionComparisonSnapshot(root: (destination ?? base)?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"), from: .workingTree, to: .workingTree, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions())
    }
    public func read() throws -> FileComparisonDocument {
        func content(_ file: URL?) throws -> ComparisonFileContent {
            guard let file else { return ComparisonFileContent(path: "", revision: .workingTree, bytes: Data(), mode: nil) }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ImageFileComparisonFailure.localFileRequired }
            return ComparisonFileContent(path: file.path, revision: .workingTree, bytes: try Data(contentsOf: file), mode: "100644")
        }
        return FileComparisonDocument(base: try content(base), destination: try content(destination))
    }
}

public enum ImageFileComparisonFailure: LocalizedError {
    case localFileRequired, filePermissionRequired
    public var errorDescription: String? {
        switch self {
        case .localFileRequired: return "Choose a local image file."
        case .filePermissionRequired: return "Select the image file again to allow it to be read."
        }
    }
}
