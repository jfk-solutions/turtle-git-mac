// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Pure, checked simulation of pinned TortoiseMerge Patch.cpp::PatchFile.
/// File ownership, path confinement, modes, symlinks, index actions and atomic
/// publication remain the caller's responsibility. This never mutates a file.
public struct SourceTextPatchApplication: Sendable {
    public enum Disposition: Sendable, Equatable { case applied, alreadyDeleted }
    public let file: SourceTextPatchFile
    public var beforePathBytes: Data? { file.oldPathBytes }
    public var afterPathBytes: Data? { file.newPathBytes }
    public var oldMode: String? { file.oldMode }
    public var newMode: String? { file.newMode }
    /// Rename/copy role metadata remains in the immutable file receipt; the
    /// checked multi-path writer must implement it, never infer it from text.
    public let originalInput: Data?
    public let outputData: Data
    public let outputEncoding: ComparisonTextEncoding
    public let text: String
    public let recordCount: Int
    public let removesFile: Bool
    public let disposition: Disposition
    /// A final empty NoEnding record is real source state even though it saves
    /// no bytes. Do not substitute text.isEmpty for source's zero-record test.
    public var hasZeroRecords: Bool { recordCount == 0 }

    public enum Failure: Error, LocalizedError, Equatable {
        case existingAddition, encoding, bounds, stale
        case mismatch(hunk: Int, line: Int, expected: String, actual: String?)
        public var errorDescription: String? {
            switch self {
            case .existingAddition: return "The added file already exists."
            case .encoding: return "The patch or target text cannot be represented without changing its encoding."
            case .bounds: return "The text patch exceeds the supported record or output bounds."
            case .stale: return "The file changed after its patch result was prepared. Refresh the preview before applying it."
            case .mismatch(let hunk, let line, _, _): return "The patch does not match the target file (hunk \(hunk + 1), record \(line + 1))."
            }
        }
    }
    /// Exact byte witness, including an absent target versus an empty file.
    /// The caller must additionally retain/recheck its filesystem receipt.
    public func validatedOutput(for actual: Data?, cancellation: OperationCancellation? = nil) throws -> Data {
        try cancellation?.check()
        guard actual == originalInput else { throw Failure.stale }
        return outputData
    }
    private struct Record { let text: String; let ending: MergeLineEnding? }
    private static let maximumBytes = 64 * 1024 * 1024
    private static let maximumRecords = 1_048_576
    private static let maximumShiftWork = 67_108_864
    private static func keyword(_ text: String) -> Bool {
        // HasExpandedKeyWords intentionally checks case-sensitive prefixes;
        // it does not parse a balanced '$...$' payload or compare the suffix.
        ["$LastChangedDate", "$Date", "$LastChangedRevision", "$Rev", "$LastChangedBy", "$Author", "$HeadURL", "$URL", "$Id"].contains { text.range(of: $0, options: .literal) != nil }
    }
    private static func records(_ text: String, cancellation: OperationCancellation?) throws -> [Record] {
        let input = text as NSString
        var values: [Record] = [], start = 0
        for boundary in MergeLineEndings.boundaries(in: text) {
            try cancellation?.check()
            guard values.count < maximumRecords else { throw Failure.bounds }
            values.append(.init(text: input.substring(with: NSRange(location: start, length: boundary.range.location - start)), ending: boundary.style))
            start = NSMaxRange(boundary.range)
        }
        guard values.count < maximumRecords else { throw Failure.bounds }
        // FileTextLines::Load adds a NoEnding record even after a final EOL.
        values.append(.init(text: input.substring(from: start), ending: nil))
        return values
    }
    public static func simulate(file: SourceTextPatchFile, input: Data?, baseInput: Data? = nil,
                                textEncodingPolicy: MergeTextEncodingPolicy = .init(preferUTF8: true), force: Bool = false,
                                cancellation: OperationCancellation? = nil) throws -> Self {
        try cancellation?.check()
        guard (input?.count ?? 0) <= maximumBytes, (baseInput?.count ?? 0) <= maximumBytes else { throw Failure.bounds }
        let added = file.oldPathBytes == nil, deleted = file.newPathBytes == nil
        guard !added || input == nil || force else { throw Failure.existingAddition }
        if deleted && input == nil {
            return Self(file: file, originalInput: nil, outputData: Data(), outputEncoding: textEncodingPolicy.legacyEncoding, text: "", recordCount: 0, removesFile: true, disposition: .alreadyDeleted)
        }
        // Source sBaseFile overrides the preimage. With old NUL and no explicit
        // base, even forced application starts from no records, not target text.
        let preimage = baseInput ?? (added ? nil : input)
        var encoding: ComparisonTextEncoding
        let originalText: String
        var values: [Record]
        if let preimage, !preimage.isEmpty {
            guard let detected = ComparisonTextEncoding.detectMerge(preimage, preferUTF8: textEncodingPolicy.preferUTF8, legacyEncoding: textEncodingPolicy.legacyEncoding),
                  let decoded = detected.decode(preimage) else { throw Failure.encoding }
            encoding = detected; originalText = decoded; values = try records(decoded, cancellation: cancellation)
        } else {
            // Missing and zero-byte preimages return before detection/final
            // NoEnding insertion in FileTextLines::Load. AUTOTYPE saves via
            // captured ACP, not via the patch container's Unicode encoding.
            encoding = textEncodingPolicy.legacyEncoding; originalText = ""; values = []
        }
        let automaticEnding = MergeLineEndings.predominantStyle(in: originalText, fallback: .crlf)
        var shiftWork = 0, comparisonWork = 0, outputUnits = originalText.utf16.count
        func equal(_ a: String, _ b: String) throws -> Bool {
            let work = a.utf8.count + b.utf8.count
            guard work <= 256 * 1024 * 1024 - comparisonWork else { throw Failure.bounds }
            comparisonWork += work
            return a.utf8.elementsEqual(b.utf8)
        }
        func chargeShift(_ count: Int) throws {
            guard count >= 0, count <= maximumShiftWork - shiftWork else { throw Failure.bounds }; shiftWork += count
        }
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            try cancellation?.check()
            var remove = hunk.oldStart, add = hunk.newStart
            guard remove >= 0, add >= 0, remove <= 10_000_000, add <= 10_000_000 else { throw Failure.bounds }
            for (lineIndex, line) in hunk.lines.enumerated() {
                try cancellation?.check()
                func mismatch(_ actual: String?) -> Failure { .mismatch(hunk: hunkIndex, line: lineIndex, expected: line.text, actual: actual) }
                switch line.kind {
                case .removed:
                    guard add <= values.count, !values.isEmpty else { throw mismatch(nil) }
                    if add == 0 { add = 1 }
                    guard add > 0, add <= values.count else { throw mismatch(nil) }
                    let actual = values[add - 1]
                    guard try equal(line.text, actual.text) || keyword(line.text) else { throw mismatch(actual.text) }
                    try chargeShift(values.count - add)
                    outputUnits -= actual.text.utf16.count + (actual.ending?.rawValue.utf16.count ?? 0)
                    values.remove(at: add - 1)
                case .added:
                    if add == 0 { add = 1 }
                    guard add > 0, add - 1 <= values.count, values.count < maximumRecords else { throw mismatch(nil) }
                    // Preserve PatchFile's exact lookahead: all later non-added
                    // records compare to this same insertion cursor. A successful
                    // comparison remains accepted even if a later one differs.
                    var insertOK = !(add < values.count)
                    for following in hunk.lines.dropFirst(lineIndex) {
                        try cancellation?.check(); try chargeShift(1)
                        if following.kind == .added { continue }
                        if values.count >= add, try equal(following.text, values[add - 1].text) { insertOK = true }
                        else { break }
                    }
                    guard insertOK else { throw mismatch(values.indices.contains(add - 1) ? values[add - 1].text : nil) }
                    let ending: MergeLineEnding? = line.ending == .automatic ? automaticEnding : nil
                    let units = line.text.utf16.count + (ending?.rawValue.utf16.count ?? 0)
                    guard units <= maximumBytes - outputUnits else { throw Failure.bounds }
                    try chargeShift(values.count - (add - 1)); outputUnits += units
                    values.insert(.init(text: line.text, ending: ending), at: add - 1)
                    add += 1
                case .context:
                    guard add <= values.count else { throw mismatch(nil) }
                    if add == 0 { add += 1 }; if remove == 0 { remove += 1 }
                    guard values.indices.contains(add - 1) else { throw mismatch(nil) }
                    let actual = values[add - 1].text
                    if try !equal(line.text, actual), !keyword(line.text), remove <= values.count,
                       try !equal(line.text, values[remove - 1].text) {
                        if add < values.count, try equal(line.text, values[add].text) { add += 1 }
                        else if add + 1 < values.count, try equal(line.text, values[add + 1].text) { add += 2 }
                        else if remove < values.count, try equal(line.text, values[remove].text) { remove += 1 }
                        else { throw mismatch(actual) }
                    }
                    add += 1; remove += 1
                }
            }
        }
        let emptyAddition = file.hunks.count == 1 && file.hunks[0].oldStart == 0 && file.hunks[0].oldCount == 0
        if (file.oldHasBOM == false || emptyAddition), file.newHasBOM == true, encoding != .utf8BOM { encoding = .utf8BOM }
        else if file.oldHasBOM == true, file.newHasBOM == false, encoding == .utf8BOM { encoding = .utf8 }
        var output = ""; output.reserveCapacity(outputUnits)
        for value in values { try cancellation?.check(); output += value.text; if let ending = value.ending { output += ending.rawValue } }
        let bytes: Data
        do { bytes = try encoding.encode(output) } catch { throw Failure.encoding }
        guard bytes.count <= maximumBytes else { throw Failure.bounds }
        try cancellation?.check()
        return Self(file: file, originalInput: input, outputData: bytes, outputEncoding: encoding, text: output, recordCount: values.count, removesFile: deleted, disposition: .applied)
    }
}
