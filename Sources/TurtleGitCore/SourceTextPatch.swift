// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum SourceTextPatchFailure: Error, LocalizedError, Equatable, Sendable {
    case encoding, opaque, unrecognized, limit
    case header(line: Int), hunk(line: Int), count(line: Int), marker(line: Int)
    case path, stripCount, duplicatePath
    public var errorDescription: String? {
        switch self {
        case .encoding: return "The patch cannot be decoded losslessly with the captured text encoding."
        case .opaque: return "This patch contains binary or special-file records; use the Git patch workflow."
        case .unrecognized: return "No unified text patch was found."
        case .limit: return "The text patch exceeds the supported parsing limits."
        case .header(let line): return "The patch file header is incomplete at line \(line)."
        case .hunk(let line): return "The patch hunk header is malformed at line \(line)."
        case .count(let line): return "The patch hunk line counts do not match at line \(line)."
        case .marker(let line): return "The patch contains an unknown hunk line marker at line \(line)."
        case .path: return "The patch contains an invalid file path."
        case .stripCount: return "The strip count removes the complete patch file path."
        case .duplicatePath: return "The patch repeats a file path too many times."
        }
    }
}

public struct SourceTextPatchLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, removed, added }
    /// Patch.cpp converts every terminated patch record to AutoLine. A warning
    /// record does not change the preceding line's ending.
    public enum Ending: Sendable, Equatable { case automatic, none }
    public let kind: Kind
    public let text: String
    public let ending: Ending
    public let originalEnding: MergeLineEnding?
    public let hadBOM: Bool
    public let sourceLine: Int
    public var hasExpandedKeywords: Bool {
        ["$LastChangedDate", "$Date", "$LastChangedRevision", "$Rev", "$LastChangedBy", "$Author", "$HeadURL", "$URL", "$Id"].contains { text.contains($0) }
    }
    fileprivate var reversed: Self {
        Self(kind: kind == .added ? .removed : kind == .removed ? .added : .context,
             text: text, ending: ending, originalEnding: originalEnding, hadBOM: hadBOM, sourceLine: sourceLine)
    }
}

public struct SourceTextPatchHunk: Sendable, Equatable {
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    public let lines: [SourceTextPatchLine]
    public let sourceLine: Int
    /// Backslash-prefixed warnings are retained for diagnostics, but are not
    /// application instructions in the pinned CPatch implementation.
    public let warnings: [String]
    public var reversed: Self {
        Self(oldStart: newStart, oldCount: newCount, newStart: oldStart, newCount: oldCount,
             lines: lines.map(\.reversed), sourceLine: sourceLine, warnings: warnings)
    }
}

public struct SourceTextPatchFile: Sendable, Equatable {
    public let id: Int
    public let rawOldPathBytes: Data?, rawNewPathBytes: Data?
    /// Source default paths remove a/ and b/. Explicit stripping uses raw paths.
    public let oldPathBytes: Data?, newPathBytes: Data?
    public let oldRevision: String?, newRevision: String?
    public let oldMode: String?, newMode: String?
    public let renameFromPathBytes: Data?, renameToPathBytes: Data?
    public let copyFromPathBytes: Data?, copyToPathBytes: Data?
    public let oldHasBOM: Bool?, newHasBOM: Bool?
    public let hunks: [SourceTextPatchHunk]
    public var pathBytes: Data { newPathBytes ?? oldPathBytes ?? Data() }
    public var reversed: Self {
        Self(id: id, rawOldPathBytes: rawNewPathBytes, rawNewPathBytes: rawOldPathBytes,
             oldPathBytes: newPathBytes, newPathBytes: oldPathBytes,
             oldRevision: newRevision, newRevision: oldRevision,
             oldMode: newMode, newMode: oldMode,
             renameFromPathBytes: renameToPathBytes, renameToPathBytes: renameFromPathBytes,
             copyFromPathBytes: copyToPathBytes, copyToPathBytes: copyFromPathBytes,
             oldHasBOM: newHasBOM, newHasBOM: oldHasBOM, hunks: hunks.map(\.reversed))
    }
    public func strippingPaths(_ count: Int) throws -> Self {
        guard count >= 0 else { throw SourceTextPatchFailure.stripCount }
        func strip(_ path: Data?) throws -> Data? {
            guard let path else { return nil }
            let parts = path.split(separator: 47, omittingEmptySubsequences: false)
            guard count < parts.count else { throw SourceTextPatchFailure.stripCount }
            let result = Data(parts.dropFirst(count).joined(separator: [UInt8(47)]))
            guard !result.isEmpty else { throw SourceTextPatchFailure.stripCount }
            return result
        }
        return Self(id: id, rawOldPathBytes: rawOldPathBytes, rawNewPathBytes: rawNewPathBytes,
                    oldPathBytes: try strip(rawOldPathBytes), newPathBytes: try strip(rawNewPathBytes),
                    oldRevision: oldRevision, newRevision: newRevision,
                    oldMode: oldMode, newMode: newMode,
                    renameFromPathBytes: renameFromPathBytes, renameToPathBytes: renameToPathBytes,
                    copyFromPathBytes: copyFromPathBytes, copyToPathBytes: copyToPathBytes,
                    oldHasBOM: oldHasBOM,
                    newHasBOM: newHasBOM, hunks: hunks)
    }
}

/// Immutable decoded syntax. No filesystem writes, target matching, transcoding
/// of opaque Git payloads, or permissive retry after an arbitrary Git error.
public struct SourceTextPatch: Sendable {
    public let originalBytes: Data
    public let sourceEncoding: ComparisonTextEncoding
    public let text: String
    public let files: [SourceTextPatchFile]
    public var document: UnifiedDiffDocument {
        UnifiedDiffDocument(bytes: originalBytes, sourceEncoding: sourceEncoding)
    }
    public var reversed: Self {
        Self(originalBytes: originalBytes, sourceEncoding: sourceEncoding, text: text, files: files.map(\.reversed))
    }
    public func strippingPaths(_ count: Int) throws -> Self {
        Self(originalBytes: originalBytes, sourceEncoding: sourceEncoding, text: text,
             files: try files.map { try $0.strippingPaths(count) })
    }
    public static func recognizedTextEligibility(bytes: Data,
        textEncodingPolicy: MergeTextEncodingPolicy = .init(preferUTF8: true)) -> Bool {
        guard let decoded = try? decode(bytes, policy: textEncodingPolicy), !opaque(decoded.text) else { return false }
        return decoded.text.components(separatedBy: .newlines).contains { $0.hasPrefix("--- ") }
    }
    public static func parse(bytes: Data,
        textEncodingPolicy: MergeTextEncodingPolicy = .init(preferUTF8: true),
        cancellation: OperationCancellation? = nil) throws -> Self {
        try cancellation?.check()
        let decoded = try decode(bytes, policy: textEncodingPolicy)
        guard !opaque(decoded.text) else { throw SourceTextPatchFailure.opaque }
        var parser = Parser(text: decoded.text, cancellation: cancellation)
        let files = try parser.parse()
        return Self(originalBytes: bytes, sourceEncoding: decoded.encoding, text: decoded.text, files: files)
    }
    private static func decode(_ bytes: Data, policy: MergeTextEncodingPolicy) throws -> (text: String, encoding: ComparisonTextEncoding) {
        guard bytes.count <= 64 * 1024 * 1024 else { throw SourceTextPatchFailure.limit }
        guard let encoding = ComparisonTextEncoding.detectMerge(bytes, preferUTF8: policy.preferUTF8, legacyEncoding: policy.legacyEncoding),
              let text = encoding.decode(bytes), !text.contains("\0") else { throw SourceTextPatchFailure.encoding }
        return (text, encoding)
    }
    private static func opaque(_ text: String) -> Bool {
        // A whole-document refusal prevents a text subset silently dropping
        // binary or special-file changes from the same patch.
        text.components(separatedBy: .newlines).contains { line in
            line == "GIT binary patch" || line.hasPrefix("Binary files ") || line.hasPrefix("Binary file ") ||
            line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") || line.hasPrefix("@@@") ||
            ((line.hasPrefix("old mode ") || line.hasPrefix("new mode ") || line.hasPrefix("new file mode ") ||
              line.hasPrefix("deleted file mode ") || line.hasPrefix("index ")) &&
             (line.hasSuffix("120000") || line.hasSuffix("160000")))
        }
    }

    private struct Record { let text: String; let ending: MergeLineEnding?; let number: Int }
    private struct Parser {
        let records: [Record]
        let cancellation: OperationCancellation?
        var index = 0
        init(text: String, cancellation: OperationCancellation?) {
            let source = text as NSString
            var records: [Record] = [], start = 0
            for boundary in MergeLineEndings.boundaries(in: text) {
                records.append(Record(text: source.substring(with: NSRange(location: start, length: boundary.range.location - start)),
                                      ending: boundary.style, number: records.count + 1))
                start = NSMaxRange(boundary.range)
            }
            // FileTextLines::Load adds a final NoEnding record for nonempty
            // input even when the decoded text ends exactly at an EOL. It may
            // complete an otherwise missing empty context line in a source hunk.
            records.append(Record(text: source.substring(from: start), ending: nil, number: records.count + 1))
            self.records = records; self.cancellation = cancellation
        }
        mutating func parse() throws -> [SourceTextPatchFile] {
            guard records.count <= 1_000_000 else { throw SourceTextPatchFailure.limit }
            var files: [SourceTextPatchFile] = [], oldRevision: String?, newRevision: String?
            var oldMode: String?, newMode: String?, renameFrom: Data?, renameTo: Data?, copyFrom: Data?, copyTo: Data?
            var pendingExtendedMetadata = false
            func regularMode(_ value: Substring) throws -> String {
                guard value == "100644" || value == "100755" else { throw SourceTextPatchFailure.opaque }
                return String(value)
            }
            while index < records.count {
                try cancellation?.check()
                let record = records[index], line = record.text
                if line.hasPrefix("diff ") {
                    guard !pendingExtendedMetadata else { throw SourceTextPatchFailure.opaque }
                    oldRevision = nil; newRevision = nil; oldMode = nil; newMode = nil
                    renameFrom = nil; renameTo = nil; copyFrom = nil; copyTo = nil
                    index += 1; continue
                }
                if line.hasPrefix("old mode ") { oldMode = try regularMode(line.dropFirst(9)); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("new mode ") { newMode = try regularMode(line.dropFirst(9)); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("new file mode ") { newMode = try regularMode(line.dropFirst(14)); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("deleted file mode ") { oldMode = try regularMode(line.dropFirst(18)); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("rename from ") { renameFrom = try path(String(line.dropFirst(12)), svnAnnotations: false); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("rename to ") { renameTo = try path(String(line.dropFirst(10)), svnAnnotations: false); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("copy from ") { copyFrom = try path(String(line.dropFirst(10)), svnAnnotations: false); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("copy to ") { copyTo = try path(String(line.dropFirst(8)), svnAnnotations: false); pendingExtendedMetadata = true; index += 1; continue }
                if line.hasPrefix("index ") {
                    let values = line.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
                    if let pair = values.first?.range(of: "..") {
                        oldRevision = String(values[0][..<pair.lowerBound]); newRevision = String(values[0][pair.upperBound...])
                    }
                    if values.count > 1 {
                        let mode = try regularMode(values[1])
                        if oldMode == nil { oldMode = mode }; if newMode == nil { newMode = mode }
                    }
                    index += 1; continue
                }
                guard line.hasPrefix("--- ") else {
                    if line.hasPrefix("@@") || line.hasPrefix("+++ ") { throw SourceTextPatchFailure.header(line: record.number) }
                    index += 1; continue // mail/SVN preamble and separators
                }
                let rawOld = try path(String(line.dropFirst(3)))
                index += 1
                guard index < records.count, records[index].text.hasPrefix("+++") else { throw SourceTextPatchFailure.header(line: record.number) }
                let rawNew = try path(String(records[index].text.dropFirst(3)))
                guard rawOld != nil || rawNew != nil else { throw SourceTextPatchFailure.path }
                index += 1
                var hunks: [SourceTextPatchHunk] = [], oldBOM: Bool?, newBOM: Bool?
                while index < records.count, records[index].text.hasPrefix("@@") {
                    guard hunks.count < 100_000 else { throw SourceTextPatchFailure.limit }
                    let hunk = try parseHunk()
                    if hunk.oldStart == 1, let first = hunk.lines.first(where: { $0.kind == .removed }) { oldBOM = first.hadBOM }
                    if hunk.newStart == 1, let first = hunk.lines.first(where: { $0.kind == .added }) { newBOM = first.hadBOM }
                    hunks.append(hunk)
                }
                guard !hunks.isEmpty else { throw SourceTextPatchFailure.hunk(line: record.number) }
                files.append(SourceTextPatchFile(id: files.count, rawOldPathBytes: rawOld, rawNewPathBytes: rawNew,
                    oldPathBytes: canonical(rawOld), newPathBytes: canonical(rawNew), oldRevision: oldRevision,
                    newRevision: newRevision, oldMode: oldMode, newMode: newMode,
                    renameFromPathBytes: renameFrom, renameToPathBytes: renameTo,
                    copyFromPathBytes: copyFrom, copyToPathBytes: copyTo,
                    oldHasBOM: oldBOM, newHasBOM: newBOM, hunks: hunks))
                oldRevision = nil; newRevision = nil
                oldMode = nil; newMode = nil; renameFrom = nil; renameTo = nil; copyFrom = nil; copyTo = nil
                pendingExtendedMetadata = false
            }
            guard !pendingExtendedMetadata else { throw SourceTextPatchFailure.opaque }
            guard !files.isEmpty else { throw SourceTextPatchFailure.unrecognized }
            // Pinned source allows a second occurrence and refuses the third.
            var seen: [Data: Int] = [:]
            for file in files {
                var paths = [Data]()
                if let old = file.oldPathBytes { paths.append(old) }
                if let new = file.newPathBytes, new != file.oldPathBytes { paths.append(new) }
                for path in paths {
                    guard seen[path, default: 0] <= 1 else { throw SourceTextPatchFailure.duplicatePath }
                    seen[path, default: 0] += 1
                }
            }
            return files
        }
        mutating func parseHunk() throws -> SourceTextPatchHunk {
            let header = records[index]
            let expression = try NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@(?:.*)$")
            let source = header.text as NSString
            guard let match = expression.firstMatch(in: header.text, range: NSRange(location: 0, length: source.length)) else { throw SourceTextPatchFailure.hunk(line: header.number) }
            func number(_ group: Int) throws -> Int? {
                let range = match.range(at: group)
                guard range.location != NSNotFound else { return nil }
                guard let value = Int(source.substring(with: range)), value <= 10_000_000 else { throw SourceTextPatchFailure.limit }
                return value
            }
            let oldNumber = try number(1)!, newNumber = try number(3)!
            let oldLength = try number(2), newLength = try number(4)
            let oldStart = oldLength == nil ? 0 : oldNumber, oldCount = oldLength ?? oldNumber
            let newStart = newLength == nil ? 1 : newNumber, newCount = newLength ?? newNumber
            index += 1
            var lines: [SourceTextPatchLine] = [], warnings: [String] = [], removed = 0, added = 0
            while removed != oldCount || added != newCount {
                try cancellation?.check()
                guard index < records.count else { throw SourceTextPatchFailure.count(line: header.number) }
                let record = records[index], marker = record.text.first ?? " "
                if marker == "\\" { warnings.append(record.text); index += 1; continue }
                let kind: SourceTextPatchLine.Kind
                switch marker {
                case " ": kind = .context; removed += 1; added += 1
                case "-": kind = .removed; removed += 1
                case "+": kind = .added; added += 1
                default: throw SourceTextPatchFailure.marker(line: record.number)
                }
                guard removed <= oldCount, added <= newCount else { throw SourceTextPatchFailure.count(line: record.number) }
                var payload = record.text.isEmpty ? "" : String(record.text.dropFirst())
                let bom = payload.first == "\u{feff}"
                if bom { payload.removeFirst() }
                lines.append(SourceTextPatchLine(kind: kind, text: payload, ending: record.ending == nil ? .none : .automatic,
                    originalEnding: record.ending, hadBOM: bom, sourceLine: record.number))
                index += 1
            }
            // The last no-newline warning follows count completion; retain it
            // without rewriting the completed record's source ending.
            while index < records.count, records[index].text.hasPrefix("\\") {
                warnings.append(records[index].text); index += 1
            }
            // An extra body line is malformed, rather than silently applying a
            // truncated prefix. Header and mail preamble are handled outside.
            if index < records.count {
                let next = records[index].text
                if (next.hasPrefix("+") && !next.hasPrefix("+++")) ||
                   (next.hasPrefix("-") && !next.hasPrefix("---") && next != "-- ") || next.hasPrefix(" ") {
                    throw SourceTextPatchFailure.count(line: records[index].number)
                }
            }
            return SourceTextPatchHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                                       lines: lines, sourceLine: header.number, warnings: warnings)
        }
        func canonical(_ path: Data?) -> Data? {
            guard let path else { return nil }
            if path.starts(with: [97, 47]) || path.starts(with: [98, 47]) { return Data(path.dropFirst(2)) }
            return path
        }
        func path(_ header: String, svnAnnotations: Bool = true) throws -> Data? {
            var value = header.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                // Preserve native Git filename bytes before source SVN suffix
                // handling: parentheses and escaped backslashes are filenames.
                var escaped = false, closing: String.Index?
                for cursor in value.indices.dropFirst() {
                    if escaped { escaped = false; continue }
                    if value[cursor] == "\\" { escaped = true; continue }
                    if value[cursor] == "\"" { closing = cursor; break }
                }
                guard let closing else { throw SourceTextPatchFailure.path }
                let suffix = value[value.index(after: closing)...]
                let annotation = suffix.trimmingCharacters(in: .whitespaces)
                let svnSuffix = svnAnnotations && suffix.first?.isWhitespace == true &&
                    (annotation.hasPrefix("(") || annotation.hasPrefix("（"))
                guard suffix.isEmpty || suffix.first == "\t" || suffix.allSatisfy({ $0 == " " }) || svnSuffix else { throw SourceTextPatchFailure.path }
                let bytes = try quoted(String(value[value.index(after: value.startIndex)..<closing]))
                guard !bytes.isEmpty, !bytes.contains(0) else { throw SourceTextPatchFailure.path }
                return bytes == Data("/dev/null".utf8) ? nil : bytes
            }
            // Source prefers the last ASCII '('; only then tries fullwidth.
            if svnAnnotations, let bracket = value.lastIndex(of: "(") ?? value.lastIndex(of: "（") {
                guard bracket != value.startIndex else { throw SourceTextPatchFailure.path }
                value = String(value[..<value.index(before: bracket)]).trimmingCharacters(in: .whitespaces)
            }
            if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
            var bytes = Data(value.utf8)
            if svnAnnotations { bytes = Data(bytes.map { $0 == 92 ? 47 : $0 }) }
            if bytes == Data("/dev/null".utf8) || bytes == Data("NUL".utf8) { return nil }
            guard !bytes.isEmpty, !bytes.contains(0) else { throw SourceTextPatchFailure.path }
            return bytes
        }
        func quoted(_ text: String) throws -> Data {
            let input = Array(text.utf8)
            var bytes = Data(), cursor = 0
            while cursor < input.count {
                let value = input[cursor]; cursor += 1
                guard value == 92 else { bytes.append(value); continue }
                guard cursor < input.count else { throw SourceTextPatchFailure.path }
                let escaped = input[cursor]; cursor += 1
                let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 92: 92, 34: 34]
                if let decoded = escapes[escaped] { bytes.append(decoded) }
                else if (48...55).contains(escaped) {
                    var number = Int(escaped - 48), count = 1
                    while cursor < input.count, count < 3, (48...55).contains(input[cursor]) {
                        number = number * 8 + Int(input[cursor] - 48); cursor += 1; count += 1
                    }
                    guard number <= 255 else { throw SourceTextPatchFailure.path }
                    bytes.append(UInt8(number))
                } else { throw SourceTextPatchFailure.path }
            }
            return bytes
        }
    }
}
