// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public struct MergeRegexFilter: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var expression: String
    public var replacement: String
    public var id: String { Data(MergeRegexFilters.nameKey(name)).base64EncodedString() }
    public static func == (a: Self, b: Self) -> Bool {
        a.name.utf8.elementsEqual(b.name.utf8) && a.expression.utf8.elementsEqual(b.expression.utf8) && a.replacement.utf8.elementsEqual(b.replacement.utf8)
    }
    public init(name: String, expression: String, replacement: String) {
        self.name = name; self.expression = expression; self.replacement = replacement
    }
}

/// Named sections correspond to upstream regexfilters.ini. Selection is local
/// to a comparison window; only the definitions are persisted.
public enum MergeRegexFilters {
    private static let key = "TurtleGitMerge.RegexFilters"
    /// SimpleIni's default comparator folds ASCII only. Unicode spellings and
    /// canonically equivalent names remain distinct sections.
    public static func nameKey(_ name: String) -> [UInt8] { name.utf8.map { (65...90).contains($0) ? $0+32 : $0 } }
    public static func sameName(_ a: String?, _ b: String?) -> Bool {
        switch (a,b) { case (nil,nil): return true; case let (a?,b?): return nameKey(a)==nameKey(b); default: return false }
    }
    public static var shipped: [MergeRegexFilter] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: RegexFilterResources.self)
        #endif
        guard let url = bundle.url(forResource: "RegexFilter", withExtension: "ini"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? decodeINI(data)) ?? []
    }
    public static func load(defaults: UserDefaults = .standard) -> [MergeRegexFilter] {
        if defaults.object(forKey: key) == nil { return shipped }
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([MergeRegexFilter].self, from: data) else { return [] }
        return values
    }
    public static func save(_ values: [MergeRegexFilter], defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }
    /// SimpleIni section names are case-insensitive. Renaming onto an existing
    /// name replaces that section rather than creating a duplicate menu entry.
    public static func updating(_ values: [MergeRegexFilter], oldName: String?, filter: MergeRegexFilter) -> [MergeRegexFilter] {
        var result = values.filter { value in
            !(oldName.map { sameName(value.name, $0) } ?? false)
        }
        if let index = result.firstIndex(where: { sameName($0.name, filter.name) }) { result[index] = filter }
        else { result.append(filter) }
        return result
    }
    public static func validate(_ filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws {
        _ = try transformed([], filter: filter, executable: executable, cancellation: cancellation)
    }
    /// Runs off the UI thread. Framing preserves empty lines, embedded NUL,
    /// surrogate units and replacements that contain newlines without treating
    /// the output as a rewritten file. It is only an alignment key.
    public static func transformed(_ lines: [String], filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        var units: [UInt16] = []
        for line in lines {
            let value = Array(line.utf16)
            guard value.count <= Int(UInt32.max) else { throw MergeRegexFailure.invalidOutput }
            units += [UInt16(truncatingIfNeeded: value.count), UInt16(truncatingIfNeeded: value.count >> 16)] + value
        }
        let bytes: Data
        do { bytes = try IssueRegexRuntime.capture(message: "", check: filter.expression, extract: filter.replacement, executable: executable,
            mode: ["--merge-replace"], messageUnits: units, cancellation: cancellation) }
        catch IssueRegexFailure.runtimeMissing { throw MergeRegexFailure.runtimeMissing }
        catch IssueRegexFailure.timedOut { throw MergeRegexFailure.timedOut }
        catch IssueRegexFailure.failed(let detail) { throw MergeRegexFailure.expression(detail) }
        try cancellation?.check()
        guard bytes.count % 2 == 0 else { throw MergeRegexFailure.invalidOutput }
        let raw = [UInt8](bytes)
        let output = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
        var offset = 0, result: [String] = []
        while offset < output.count {
            guard output.count - offset >= 2 else { throw MergeRegexFailure.invalidOutput }
            let count = Int(output[offset]) | Int(output[offset + 1]) << 16; offset += 2
            guard count <= output.count - offset else { throw MergeRegexFailure.invalidOutput }
            let value = String(decoding: output[offset..<offset + count], as: UTF16.self)
            guard Array(value.utf16).elementsEqual(output[offset..<offset + count]) else { throw MergeRegexFailure.invalidOutput }
            result.append(value); offset += count
        }
        guard result.count == lines.count else { throw MergeRegexFailure.invalidOutput }
        return result
    }
    public static func lines(_ text: String) -> [String] {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).map { source.substring(with: $0) }
    }
    public static func alignment(base: String, destination: String, filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> FileComparisonAlignment {
        let a = lines(base), b = lines(destination)
        // LineRegex receives content without the original EOL. Retain endings
        // in comparison keys so this option doesn't also ignore EOL changes.
        let all = a + b
        let values = try transformed(all.map(MergeLineEndings.droppingFinalEnding), filter: filter, executable: executable, cancellation: cancellation)
        let keys = zip(all, values).map { original, filtered -> String in
            let content = MergeLineEndings.droppingFinalEnding(original)
            let suffix = (original as NSString).substring(from: (content as NSString).length)
            return filtered + suffix
        }
        return FileComparisonAlignment(base: base, destination: destination, baseKeys: Array(keys.prefix(a.count)), destinationKeys: Array(keys.dropFirst(a.count)))
    }
}
public enum MergeRegexFailure: LocalizedError {
    case runtimeMissing, timedOut, expression(String), invalidOutput
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The comparison regex helper is missing. Rebuild TurtleGit with its matching runtime."
        case .timedOut: return "Filtering took too long. Check the regular expression."
        case .expression(let detail): return "Could not apply the regex filter. " + detail
        case .invalidOutput: return "The regex helper returned invalid comparison data."
        }
    }
}

private final class RegexFilterResources: NSObject {}

public enum MergeRegexFileFailure: LocalizedError {
    case file, size, syntax(Int), encoding, exportValue(String), count
    public var errorDescription: String? {
        switch self {
        case .file: return "Choose a regular readable filter INI file."
        case .size: return "The filter file exceeds the 1 MiB limit."
        case .syntax(let line): return "Invalid filter INI syntax at line \(line)."
        case .encoding: return "Use UTF-8 or a Unicode file with a byte-order mark; NUL characters are not supported."
        case .exportValue(let name): return "Filter ‘\(name)’ cannot be represented in TortoiseGit's single-line INI format. Remove line breaks, surrounding whitespace or section delimiters before exporting."
        case .count: return "A filter file can contain at most 256 named filters."
        }
    }
}
extension MergeRegexFilters {
    public static let maximumFileBytes = 1_048_576
    /// The pinned caller uses SimpleIni's default single-line, last-key-wins
    /// mode. Backslashes, dollar replacements, quotes and inline #/; are literal.
    public static func decodeINI(_ bytes: Data) throws -> [MergeRegexFilter] {
        guard bytes.count <= maximumFileBytes else { throw MergeRegexFileFailure.size }
        let text: String?
        if bytes.starts(with:[0xff,0xfe]) { text=String(data:bytes.dropFirst(2),encoding:.utf16LittleEndian) }
        else if bytes.starts(with:[0xfe,0xff]) { text=String(data:bytes.dropFirst(2),encoding:.utf16BigEndian) }
        else { text=String(data:bytes.starts(with:[0xef,0xbb,0xbf]) ? bytes.dropFirst(3):bytes,encoding:.utf8) }
        guard let text, !text.utf8.contains(0) else { throw MergeRegexFileFailure.encoding }
        func trim(_ text: String) -> String { text.trimmingCharacters(in:CharacterSet(charactersIn:" \t")) }
        var values=[MergeRegexFilter](), section: Int?
        let lines=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").components(separatedBy:"\n")
        for (offset,raw) in lines.enumerated() {
            let line=trim(raw)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw MergeRegexFileFailure.syntax(offset+1) }
                let name=trim(String(line.dropFirst().dropLast()))
                guard !name.isEmpty, !name.contains("[") && !name.contains("]") else { throw MergeRegexFileFailure.syntax(offset+1) }
                if let found=values.firstIndex(where:{sameName($0.name,name)}) { section=found }
                else {
                    guard values.count<256 else { throw MergeRegexFileFailure.count }
                    values.append(.init(name:name,expression:"",replacement:""));section=values.count-1
                }
            } else {
                guard let separator=line.firstIndex(of:"=") else { throw MergeRegexFileFailure.syntax(offset+1) }
                guard let section else { continue } // Global keys are not filter sections.
                let key=String(decoding:nameKey(trim(String(line[..<separator]))),as:UTF8.self)
                let value=trim(String(line[line.index(after:separator)...]))
                if key=="regex" { values[section].expression=value }
                else if key=="replace" { values[section].replacement=value }
            }
        }
        return values
    }
    public static func encodeINI(_ values: [MergeRegexFilter]) throws -> Data {
        guard values.count<=256 else { throw MergeRegexFileFailure.count }
        var text="# TurtleGit for Mac / TortoiseGitMerge regex filters\r\n", names=Set<Data>()
        for value in values {
            let fields=[value.name,value.expression,value.replacement]
            guard !value.name.isEmpty, !value.name.contains("[") && !value.name.contains("]"),
                  names.insert(Data(nameKey(value.name))).inserted,
                  fields.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.utf8.contains(0) }) else { throw MergeRegexFileFailure.exportValue(value.name) }
            // Trimming is significant in SimpleIni; refuse lossy round trips.
            guard fields.allSatisfy({ $0.utf8.elementsEqual($0.trimmingCharacters(in:CharacterSet(charactersIn:" \t")).utf8) }) else { throw MergeRegexFileFailure.exportValue(value.name) }
            text += "\r\n["+value.name+"]\r\nregex="+value.expression+"\r\nreplace="+value.replacement+"\r\n"
        }
        let data=Data([0xef,0xbb,0xbf])+Data(text.utf8)
        guard data.count<=maximumFileBytes else { throw MergeRegexFileFailure.size };return data
    }
    public static func readINI(_ url: URL, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [MergeRegexFilter] {
        try cancellation?.check()
        guard url.isFileURL else { throw MergeRegexFileFailure.file }
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard descriptor>=0 else { throw MergeRegexFileFailure.file }
        let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer { try? file.close() }
        var info=stat()
        guard fstat(descriptor,&info)==0,info.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG) else { throw MergeRegexFileFailure.file }
        guard info.st_size<=maximumFileBytes else { throw MergeRegexFileFailure.size }
        let values=try decodeINI(file.read(upToCount:maximumFileBytes+1) ?? Data())
        for value in values { try cancellation?.check();try validate(value,executable:executable,cancellation:cancellation) }
        try cancellation?.check();return values
    }
    public static func writeINI(_ data: Data, to url: URL, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard url.isFileURL,data.count<=maximumFileBytes else { throw MergeRegexFileFailure.file }
        try data.write(to:url,options:.atomic)
    }
}
