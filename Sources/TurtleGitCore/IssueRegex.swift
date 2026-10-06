import Foundation

public enum IssueRegexFailure: LocalizedError {
    case runtimeMissing, failed(String), timedOut
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled issue-matching helper is missing. Build the app with its IssueRegex runtime."
        case .failed(let message): return "Could not match issue IDs. " + message
        case .timedOut: return "Matching issue IDs took too long. Check the configured regular expression."
        }
    }
}
public enum HistoryRegexFailure: LocalizedError {
    case runtimeMissing, failed(String), timedOut
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The regular-expression matcher is missing. Rebuild TurtleGit with its matching runtime."
        case .failed(let detail): return "Could not filter history. " + detail
        case .timedOut: return "Filtering history took too long. Check the regular expression."
        }
    }
}
public struct IssueRegexMatch: Sendable, Equatable {
    public let hasMatch: Bool
    public let ranges: [NSRange]
    public func identifiers(in message: String) -> [String] {
        let text = message as NSString
        return ranges.map { text.substring(with: $0) }
    }
}
public enum IssueRegexRuntime {
    public static func executable(bundle: Bundle = .main) throws -> URL {
        let file = bundle.bundleURL.appendingPathComponent("Contents/Helpers/IssueRegex/issue-regex")
        guard FileManager.default.isExecutableFile(atPath: file.path) else { throw IssueRegexFailure.runtimeMissing }
        return file
    }
    /// Uses C++ ECMAScript matching with Windows UTF-16 offsets. Call off the UI thread.
    public static func match(message: String, check: String, extract: String = "", executable: URL? = nil, bundle: Bundle = .main) throws -> IssueRegexMatch {
        guard !check.isEmpty else { return IssueRegexMatch(hasMatch: false, ranges: []) }
        let output = try capture(message: message, check: check, extract: extract, executable: executable, bundle: bundle)
        guard let text = String(data: output, encoding: .utf8) else { throw IssueRegexFailure.failed("Invalid helper output.") }
        let rows = text.split(separator: "\n")
        guard let first = rows.first, first == "matched\t0" || first == "matched\t1" else { throw IssueRegexFailure.failed("Invalid helper output.") }
        var ranges: [NSRange] = []
        let length = message.utf16.count
        for row in rows.dropFirst() {
            let columns = row.split(separator: "\t")
            guard columns.count == 2, let location = Int(columns[0]), let size = Int(columns[1]), location >= 0, size >= 0,
                  location <= length, size <= length - location else { throw IssueRegexFailure.failed("Invalid issue range.") }
            ranges.append(NSRange(location: location, length: size))
        }
        return IssueRegexMatch(hasMatch: first == "matched\t1", ranges: ranges)
    }
    /// One compiled ECMAScript expression over length-framed UTF-16 records.
    /// Invalid/empty expressions reproduce upstream's inactive-filter behavior.
    static func logMatches(_ texts: [String], pattern: String, caseSensitive: Bool, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [Bool] {
        try cancellation?.check()
        let inverted = pattern.hasPrefix("!")
        let expression = inverted ? String(pattern.dropFirst()) : pattern
        var units: [UInt16] = []
        for text in texts {
            try cancellation?.check()
            let value = Array(text.utf16)
            guard value.count <= Int(UInt32.max) else { throw HistoryRegexFailure.failed("Log record is too large.") }
            units += [UInt16(truncatingIfNeeded: value.count), UInt16(truncatingIfNeeded: value.count >> 16)] + value
        }
        let bytes: Data
        do { bytes = try capture(message: "", check: expression, extract: "", executable: executable,
            mode: [caseSensitive ? "--log-case" : "--log-insensitive"], messageUnits: units, cancellation: cancellation) }
        catch IssueRegexFailure.runtimeMissing { throw HistoryRegexFailure.runtimeMissing }
        catch IssueRegexFailure.timedOut { throw HistoryRegexFailure.timedOut }
        catch IssueRegexFailure.failed(let detail) { throw HistoryRegexFailure.failed(detail) }
        try cancellation?.check()
        let rows = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        if rows == ["log\tinactive"] { return Array(repeating: !inverted, count: texts.count) }
        guard rows.first == "log\tactive", rows.count == texts.count + 1,
              rows.dropFirst().allSatisfy({ $0 == "0" || $0 == "1" }) else { throw HistoryRegexFailure.failed("Invalid log filter output.") }
        return rows.dropFirst().map { ($0 == "1") != inverted }
    }
    static func capture(message: String, check: String, extract: String, executable: URL?, bundle: Bundle = .main, mode: [String] = [], messageUnits: [UInt16]? = nil, cancellation: OperationCancellation? = nil) throws -> Data {
        let parser = try executable ?? Self.executable(bundle: bundle)
        guard FileManager.default.isExecutableFile(atPath: parser.path) else { throw IssueRegexFailure.runtimeMissing }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitIssueRegex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = [Array(check.utf16), Array(extract.utf16), messageUnits ?? Array(message.utf16)]
        let files = try inputs.enumerated().map { index, value -> URL in
            let file = directory.appendingPathComponent(String(index))
            try Data(value.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }).write(to: file)
            return file
        }
        let output: Data
        do { output = try BundledTextHelper.capture(executable: parser, arguments: files.map(\.path) + mode, cancellation: cancellation) }
        catch BundledTextHelperFailure.timedOut { throw IssueRegexFailure.timedOut }
        catch BundledTextHelperFailure.failed(let message) { throw IssueRegexFailure.failed(message) }
        return output
    }
}
