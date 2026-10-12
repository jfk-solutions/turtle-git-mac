// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct BlameSyntaxStyle: Codable, Sendable {
    public let foreground: [UInt8]?
    public let background: [UInt8]?
    public let bold: Bool?
}
public struct BlameSyntaxRange: Sendable {
    public let range: NSRange
    public let style: Int
}
public struct BlameSyntaxResult: Sendable {
    public let lexer: String?
    public let ranges: [BlameSyntaxRange]
    public let styles: [String: BlameSyntaxStyle]
}
public enum BlameSyntaxFailure: LocalizedError {
    case unavailable, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The bundled Lexilla syntax helper is unavailable."
        case .invalid(let detail): return "Syntax highlighting failed: " + detail
        }
    }
}
public enum BlameSyntax {
    public static func executable(bundle: Bundle = .main) -> URL? {
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Lexilla/lexilla")
        if FileManager.default.isExecutableFile(atPath:bundled.path) { return bundled }
        guard !GitRuntime.isAppStoreBuild else { return nil }
        if let override = ProcessInfo.processInfo.environment["TURTLEGIT_LEXILLA_HELPER"],
           FileManager.default.isExecutableFile(atPath:override) { return URL(fileURLWithPath:override) }
        let development = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/lexilla-runtime/Lexilla/lexilla")
        return FileManager.default.isExecutableFile(atPath:development.path) ? development : nil
    }
    private struct Configuration: Decodable {
        let extensions: [String], lexer: String, wordlists: [String:String], styles: [String:BlameSyntaxStyle]
    }
    private struct Manifest: Decodable { let version: Int, configurations: [Configuration], no_extension: Configuration }
    /// Off-main-thread, pinned Lexilla processing. Offsets are converted from
    /// UTF-8 bytes to validated AppKit UTF-16 boundaries before publication.
    public static func highlight(_ text: String, filename: String, tabSize: Int = 4, executable explicit: URL? = nil, cancellation: OperationCancellation? = nil) throws -> BlameSyntaxResult {
        try Task.checkCancellation(); try cancellation?.check()
        guard text.utf8.count <= 16 * 1024 * 1024, (1...1000).contains(tabSize), !text.contains("\0") else { throw BlameSyntaxFailure.invalid("Unsupported source size, tab width or NUL.") }
        guard let helper = explicit ?? executable() else { throw BlameSyntaxFailure.unavailable }
        let configuration: Manifest
        do { configuration = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:helper.deletingLastPathComponent().appendingPathComponent("BlameLexers.json"))) }
        catch { throw BlameSyntaxFailure.invalid("Lexer configuration is unavailable or invalid.") }
        guard configuration.version == 1 else { throw BlameSyntaxFailure.invalid("Unsupported configuration version.") }
        let position = filename.lastIndex(of:".")
        let selected: Configuration?
        if let position, position > filename.startIndex {
            // Preserve the source's case-sensitive extension comparison.
            selected = configuration.configurations.first { $0.extensions.contains(String(filename[filename.index(after:position)...])) }
        } else { selected = configuration.no_extension }
        guard let selected else { return BlameSyntaxResult(lexer:nil,ranges:[],styles:[:]) }
        let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitLexilla-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temporary) }
        let input = temporary.appendingPathComponent("source")
        try Data(text.utf8).write(to:input); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:input.path)
        var arguments = [selected.lexer,String(tabSize),input.path]
        for index in selected.wordlists.keys.sorted() {
            guard Int(index) != nil else { throw BlameSyntaxFailure.invalid("Invalid word-list index.") }
            let path = temporary.appendingPathComponent("words-" + index)
            try Data(selected.wordlists[index]!.utf8).write(to:path)
            arguments += [index,path.path]
        }
        let token = cancellation ?? OperationCancellation()
        let output: Data
        do { output = try BundledTextHelper.capture(executable:helper,arguments:arguments,cancellation:token) }
        catch is OperationCancellationFailure { throw OperationCancellationFailure.cancelled }
        catch BundledTextHelperFailure.failed(let detail) { throw BlameSyntaxFailure.invalid(detail.isEmpty ? "The lexer helper exited unsuccessfully." : detail) }
        catch BundledTextHelperFailure.timedOut { throw BlameSyntaxFailure.invalid("The lexer helper exceeded its time limit.") }
        catch { throw BlameSyntaxFailure.invalid(error.localizedDescription) }
        guard let report = String(data:output,encoding:.utf8) else { throw BlameSyntaxFailure.invalid("Invalid UTF-8 output.") }
        let records = report.split(separator:"\n")
        guard records.count >= 2, records[0] == "lexilla\t1", records[1] == "name\t" + selected.lexer else { throw BlameSyntaxFailure.invalid("Invalid lexer output header.") }
        let byteCount = text.utf8.count
        var boundaries = [Int](repeating:-1,count:byteCount + 1), byteOffset = 0, unitOffset = 0
        boundaries[0] = 0
        for scalar in text.unicodeScalars {
            byteOffset += scalar.utf8.count; unitOffset += scalar.utf16.count
            boundaries[byteOffset] = unitOffset
        }
        var ranges: [BlameSyntaxRange] = [], consumed = 0
        for record in records.dropFirst(2) {
            let fields = record.split(separator:"\t")
            guard fields.count == 4, fields[0] == "range", let start = Int(fields[1]), let length = Int(fields[2]), let style = Int(fields[3]),
                  start == consumed, length > 0, start <= byteCount, length <= byteCount - start,
                  (0...255).contains(style), boundaries[start] >= 0, boundaries[start + length] >= 0 else { throw BlameSyntaxFailure.invalid("Invalid style range or Unicode boundary.") }
            ranges.append(BlameSyntaxRange(range:NSRange(location:boundaries[start],length:boundaries[start + length] - boundaries[start]),style:style))
            consumed += length
        }
        guard consumed == byteCount else { throw BlameSyntaxFailure.invalid("Incomplete style output.") }
        try Task.checkCancellation(); try cancellation?.check()
        return BlameSyntaxResult(lexer:selected.lexer,ranges:ranges,styles:selected.styles)
    }
}
