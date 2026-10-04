import Foundation

/// FileDiffDlg sorts text literally and uses the path to break other column ties.
public struct ComparisonFileSortKey: Comparable, Sendable {
    private let text: [UInt16]?
    private let number: Int?
    private let path: [UInt16]
    init(text: String, path: String) { self.text = Array(text.utf16); number = nil; self.path = Array(path.utf16) }
    init(number: Int, path: String) { text = nil; self.number = number; self.path = Array(path.utf16) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.number != nil) != (rhs.number != nil) { return lhs.number != nil }
        if let a = lhs.number, let b = rhs.number, a != b { return a < b }
        if let a = lhs.text, let b = rhs.text, a != b { return a.lexicographicallyPrecedes(b) }
        return lhs.path.lexicographicallyPrecedes(rhs.path)
    }
}
extension CommitFile {
    public var fileExtension: String { isSubmodule ? "" : (path as NSString).pathExtension }
    public var sortPath: ComparisonFileSortKey { ComparisonFileSortKey(text: path, path: path) }
    public var sortExtension: ComparisonFileSortKey { ComparisonFileSortKey(text: fileExtension, path: path) }
    public var sortAction: ComparisonFileSortKey {
        let value: Int
        switch action.first { case "A": value = 1; case "M", "T": value = 2; case "R": value = 4; case "D": value = 8; case "U": value = 16; case "C": value = 64; default: value = 0 }
        return ComparisonFileSortKey(number: value, path: path)
    }
    public var sortAdded: ComparisonFileSortKey { ComparisonFileSortKey(number: added ?? 0, path: path) }
    public var sortRemoved: ComparisonFileSortKey { ComparisonFileSortKey(number: removed ?? 0, path: path) }
    public var addedText: String { added.map(String.init) ?? "–" }
    public var removedText: String { removed.map(String.init) ?? "–" }
}
public enum ComparisonFileList {
    public static func clipboard(_ files: [CommitFile], extended: Bool) -> String {
        files.map { file in
            extended ? [file.path, file.fileExtension, file.status, file.addedText, file.removedText].joined(separator: "\t") : file.path + "\t"
        }.map { $0 + "\n" }.joined()
    }
    public static func savedList(_ files: [CommitFile], from: ComparisonRevision, to: ComparisonRevision) -> String {
        "Changed files between \(from.label) and \(to.label)\n" + files.map { $0.path + "\n" }.joined()
    }
}
