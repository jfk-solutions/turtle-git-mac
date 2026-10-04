import Foundation

public struct ComparisonFileContent: Sendable {
    public let path: String
    public let revision: ComparisonRevision
    public let bytes: Data
    public let mode: String?
    public var text: String? {
        if bytes.starts(with: [0xff, 0xfe]) { return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) }
        guard !bytes.contains(0) else { return nil }
        return String(data: bytes.starts(with: [0xef, 0xbb, 0xbf]) ? bytes.dropFirst(3) : bytes, encoding: .utf8)
    }
}
public struct FileComparisonDocument: Sendable {
    public let base: ComparisonFileContent
    public let destination: ComparisonFileContent
}
public struct FileComparisonRow: Sendable {
    public let base: MergeSourceCell
    public let destination: MergeSourceCell
    public var changed: Bool { base.state != .normal || destination.state != .normal }
}
/// Display alignment keeps original line numbers and line-ending differences.
/// Source bytes remain in FileComparisonDocument; gaps never replace file data.
public struct FileComparisonAlignment: Sendable {
    public let rows: [FileComparisonRow]
    public let differences: [Range<Int>]
    public init(base: String, destination: String) {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            let pieces = text.components(separatedBy: "\n")
            return pieces.dropLast().map { $0 + "\n" } + (pieces.last!.isEmpty ? [] : [pieces.last!])
        }
        let a = lines(base), b = lines(destination)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a, by: { $0.utf8.elementsEqual($1.utf8) }) {
            switch change { case .remove(let i, _, _): removed.insert(i); case .insert(let i, _, _): inserted.insert(i) }
        }
        var output: [FileComparisonRow] = [], groups: [Range<Int>] = [], i = 0, j = 0
        func cell(_ lines: [String], _ index: Int, _ state: MergeSourceState) -> MergeSourceCell {
            MergeSourceCell(text: lines[index], lineNumber: index + 1, state: state)
        }
        let gap = MergeSourceCell(text: "", lineNumber: nil, state: .empty)
        while i < a.count || j < b.count {
            if removed.contains(i) || inserted.contains(j) {
                let ai = i, bj = j, start = output.count
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                for offset in 0..<max(i - ai, j - bj) {
                    output.append(FileComparisonRow(base: ai + offset < i ? cell(a, ai + offset, .removed) : gap,
                                                    destination: bj + offset < j ? cell(b, bj + offset, .added) : gap))
                }
                groups.append(start..<output.count)
            } else {
                output.append(FileComparisonRow(base: cell(a, i, .normal), destination: cell(b, j, .normal))); i += 1; j += 1
            }
        }
        rows = output; differences = groups
    }
}
extension GitRepository {
    public func comparisonFile(_ snapshot: RevisionComparisonSnapshot, path: String) throws -> FileComparisonDocument {
        guard snapshot.root == root, let file = snapshot.files.first(where: { $0.path == path }), !file.isSubmodule else { throw RevisionComparisonFailure.selection }
        func read(_ revision: ComparisonRevision, _ path: String, absent: Bool) throws -> ComparisonFileContent {
            if absent || revision == .emptyTree { return ComparisonFileContent(path: path, revision: revision, bytes: Data(), mode: nil) }
            if revision == .workingTree {
                let location = try restoreLocation(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    return ComparisonFileContent(path: path, revision: revision, bytes: Data(try FileManager.default.destinationOfSymbolicLink(atPath: location.path).utf8), mode: "120000")
                }
                guard type == .typeRegular else { throw RevisionComparisonFailure.selection }
                let executable = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                return ComparisonFileContent(path: path, revision: revision, bytes: try Data(contentsOf: location), mode: executable & 0o111 == 0 ? "100644" : "100755")
            }
            guard case .revision(let hash) = revision else { throw RevisionComparisonFailure.range }
            // Literal, NUL-delimited tree lookup handles colons, tabs and newlines.
            let records = try run(["ls-tree", "-z", hash, "--", path]).stdout.split(separator: 0)
            for record in records {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, header[1] == "blob" else { throw RevisionComparisonFailure.selection }
                return ComparisonFileContent(path: path, revision: revision, bytes: try run(["cat-file", "blob", String(header[2])]).stdout, mode: String(header[0]))
            }
            throw RevisionComparisonFailure.selection
        }
        return FileComparisonDocument(base: try read(snapshot.from, file.oldPath ?? path, absent: file.action.hasPrefix("A")),
                                      destination: try read(snapshot.to, path, absent: file.action.hasPrefix("D")))
    }
}
