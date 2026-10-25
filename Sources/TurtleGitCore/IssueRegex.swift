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
public enum IssueRegexSyntax:String,Sendable {
    case inactive,valid
    case invalidCheck="invalid-check",invalidExtraction="invalid-extraction"
}
/// Configured ProjectProperties expressions have caught compilation semantics,
/// distinct from strict expression editors and actual helper failures.
public struct IssueRegexSourceMatch:Sendable,Equatable {
    public let match:IssueRegexMatch
    public let syntax:IssueRegexSyntax
    public var hasMatch:Bool {match.hasMatch}
    public var ranges:[NSRange] {match.ranges}
    public func identifiers(in message:String)->[String] {match.identifiers(in:message)}
}
public enum IssueRegexRuntime {
    private final class FrameworkAnchor: NSObject {}
    public static func executable(bundle: Bundle = .main) throws -> URL {
        var resolved = bundle
        if bundle === Bundle.main, bundle.bundleURL.pathExtension != "app" {
            // Standalone native receivers load Core beside the built app. A
            // packaged application always resolves its own sealed helper.
            let framework = Bundle(for: FrameworkAnchor.self)
            let companion = framework.bundleURL.deletingLastPathComponent().appendingPathComponent("TurtleGitMac.app")
            resolved = Bundle(url: companion) ?? bundle
        }
        let file = resolved.bundleURL.appendingPathComponent("Contents/Helpers/IssueRegex/issue-regex")
        guard FileManager.default.isExecutableFile(atPath: file.path) else { throw IssueRegexFailure.runtimeMissing }
        return file
    }
    /// Uses C++ ECMAScript matching with Windows UTF-16 offsets. Call off the UI thread.
    public static func match(message: String, check: String, extract: String = "", executable: URL? = nil, bundle: Bundle = .main, cancellation: OperationCancellation? = nil, ignoreInvalidPattern: Bool = false) throws -> IssueRegexMatch {
        if ignoreInvalidPattern {return try sourceMatch(message:message,check:check,extract:extract,executable:executable,bundle:bundle,cancellation:cancellation).match}
        try cancellation?.check()
        guard !check.isEmpty else { return IssueRegexMatch(hasMatch: false, ranges: []) }
        let output = try capture(message: message, check: check, extract: extract, executable: executable, bundle: bundle, mode: [], cancellation: cancellation)
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
    /// A fresh configured-value snapshot follows AutoUpdateRegex's ordered
    /// assignments: an invalid extraction cannot undo a valid check expression.
    /// No process-global cache is shared between repositories or dialog owners.
    public static func sourceMatch(message:String,check:String,extract:String="",executable:URL?=nil,bundle:Bundle = .main,cancellation:OperationCancellation?=nil)throws->IssueRegexSourceMatch {
        try cancellation?.check()
        guard !check.isEmpty else{return .init(match:.init(hasMatch:false,ranges:[]),syntax:.inactive)}
        let output=try capture(message:message,check:check,extract:extract,executable:executable,bundle:bundle,mode:["--source-issue"],cancellation:cancellation)
        guard let text=String(data:output,encoding:.utf8),text.hasSuffix("\n") else{throw IssueRegexFailure.failed("Invalid configured issue output.")}
        var rows=text.components(separatedBy:"\n");rows.removeLast()
        guard rows.count>=3,rows[0]=="source\t1",rows[1].hasPrefix("syntax\t"),
              let syntax=IssueRegexSyntax(rawValue:String(rows[1].dropFirst(7))),rows[2]=="matched\t0" || rows[2]=="matched\t1" else{throw IssueRegexFailure.failed("Invalid configured issue output.")}
        let matched=rows[2]=="matched\t1",length=message.utf16.count
        var ranges=[NSRange]()
        for row in rows.dropFirst(3) {
            let fields=row.components(separatedBy:"\t")
            guard fields.count==2,fields.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy{(48...57).contains($0)}}),let start=Int(fields[0]),let count=Int(fields[1]),start>=0,count>=0,start<=length,count<=length-start else{throw IssueRegexFailure.failed("Invalid configured issue range.")}
            ranges.append(.init(location:start,length:count))
        }
        guard (matched || ranges.isEmpty),syntax == .valid || ranges.isEmpty,
              ![IssueRegexSyntax.inactive,.invalidCheck].contains(syntax) || !matched else{throw IssueRegexFailure.failed("Inconsistent configured issue output.")}
        return .init(match:.init(hasMatch:matched,ranges:ranges),syntax:syntax)
    }
    /// Validate the Log expression with the same ECMAScript engine as filtering,
    /// without reading history or confusing an invalid expression with no matches.
    public static func validateLogPattern(_ pattern: String, caseSensitive: Bool, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        let expression = pattern.hasPrefix("!") ? String(pattern.dropFirst()) : pattern
        guard !expression.isEmpty else { return true }
        let output = try capture(message: "", check: expression, extract: "", executable: executable,
            mode: [caseSensitive ? "--log-case" : "--log-insensitive"], messageUnits: [], cancellation: cancellation)
        try cancellation?.check()
        switch String(decoding: output, as: UTF8.self) {
        case "log\tactive\n": return true
        case "log\tinactive\n": return false
        default: throw HistoryRegexFailure.failed("Invalid Log validation output.")
        }
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
    static func logRanges(_ texts: [String], pattern: String, caseSensitive: Bool, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [[NSRange]] {
        try cancellation?.check()
        let expression = pattern.hasPrefix("!") ? String(pattern.dropFirst()) : pattern
        var units: [UInt16] = []
        for text in texts {
            try cancellation?.check()
            let value = Array(text.utf16)
            guard value.count <= Int(UInt32.max) else { throw HistoryRegexFailure.failed("Log cell is too large.") }
            units += [UInt16(truncatingIfNeeded: value.count), UInt16(truncatingIfNeeded: value.count >> 16)] + value
        }
        let output = try capture(message: "", check: expression, extract: "", executable: executable,
            mode: [caseSensitive ? "--log-ranges-case" : "--log-ranges-insensitive"], messageUnits: units, cancellation: cancellation)
        let rows = String(decoding: output, as: UTF8.self).split(separator: "\n")
        var result = Array(repeating: [NSRange](), count: texts.count)
        if rows == ["ranges\tinactive"] { return result }
        guard rows.first == "ranges\tactive" else { throw HistoryRegexFailure.failed("Invalid highlight output.") }
        for row in rows.dropFirst() {
            let values = row.split(separator: "\t").compactMap { Int($0) }
            guard values.count == 3, values[0] >= 0, values[0] < texts.count, values[1] >= 0, values[2] >= 0,
                  values[1] <= texts[values[0]].utf16.count, values[2] <= texts[values[0]].utf16.count - values[1] else { throw HistoryRegexFailure.failed("Invalid highlight range.") }
            result[values[0]].append(NSRange(location: values[1], length: values[2]))
        }
        return result.map(HistoryHighlighting.merge)
    }
    public static func batchIssueIDs(_ messages: [String], check: String, extract: String = "", executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [[String]] {
        var units: [UInt16] = []
        for message in messages {
            try cancellation?.check(); let value = Array(message.utf16)
            guard value.count <= Int(UInt32.max) else { throw IssueRegexFailure.failed("Log message is too large.") }
            units += [UInt16(truncatingIfNeeded:value.count), UInt16(truncatingIfNeeded:value.count >> 16)] + value
        }
        let output = try capture(message:"",check:check,extract:extract,executable:executable,mode:["--batch-issue-ids"],messageUnits:units,cancellation:cancellation)
        let rows = String(decoding:output,as:UTF8.self).split(separator:"\n")
        guard rows.first == "issues\t1" else { throw IssueRegexFailure.failed("Invalid batch issue output.") }
        var result = Array(repeating:[String](),count:messages.count)
        for row in rows.dropFirst() {
            let values = row.split(separator:"\t").compactMap { Int($0) }
            guard values.count == 3, messages.indices.contains(values[0]), values[1] >= 0, values[2] >= 0,
                  values[1] <= messages[values[0]].utf16.count, values[2] <= messages[values[0]].utf16.count - values[1] else { throw IssueRegexFailure.failed("Invalid batch issue range.") }
            result[values[0]].append((messages[values[0]] as NSString).substring(with:NSRange(location:values[1],length:values[2])))
        }
        return result
    }
    /// The original FindSVNRev patterns, processed in one owned helper batch.
    public static func svnRevisions(_ messages: [String], executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [String] {
        var units: [UInt16] = []
        for message in messages {
            try cancellation?.check()
            let value = Array(message.utf16)
            guard value.count <= Int(UInt32.max) else { throw IssueRegexFailure.failed("Log message is too large.") }
            units += [UInt16(truncatingIfNeeded: value.count), UInt16(truncatingIfNeeded: value.count >> 16)] + value
        }
        let output = try capture(message: "", check: "", extract: "", executable: executable, mode: ["--svn-revisions"], messageUnits: units, cancellation: cancellation)
        var rows = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
        guard rows.first == "svn\t1", rows.last == "", rows.count == messages.count + 2 else { throw IssueRegexFailure.failed("Invalid SVN revision output.") }
        rows.removeFirst(); rows.removeLast()
        guard rows.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { throw IssueRegexFailure.failed("Invalid SVN revision digits.") }
        return rows
    }
    static func capture(message: String, check: String, extract: String, executable: URL?, bundle: Bundle = .main, mode: [String] = [], messageUnits: [UInt16]? = nil, cancellation: OperationCancellation? = nil) throws -> Data {
        let parser = try executable ?? Self.executable(bundle: bundle)
        guard FileManager.default.isExecutableFile(atPath: parser.path) else { throw IssueRegexFailure.runtimeMissing }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitIssueRegex-" + UUID().uuidString)
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
