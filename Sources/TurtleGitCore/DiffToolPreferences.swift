// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum DiffToolFailure: LocalizedError {
    case application, arguments, association
    public var errorDescription: String? {
        switch self {
        case .application: return "Choose an application bundle or executable file using its full path."
        case .arguments: return "The arguments contain an unfinished quote, escape or NUL character."
        case .association: return "Use a unique file extension (such as .swift) or filename without folder separators."
        }
    }
}
public enum BuiltInDiffTool: String, Codable, CaseIterable, Sendable {
    case zipInventory, binaryReport, mathematicaNotebook, wordDocument, excelWorkbook, excelWorkbookFast, libreOfficeDocument, powerPointPresentation
    public var title: String {
        switch self {
        case .zipInventory: return "ZIP archive inventory"
        case .binaryReport: return "Binary file comparison"
        case .mathematicaNotebook: return "Mathematica notebook comparison"
        case .wordDocument: return "Microsoft Word document comparison"
        case .powerPointPresentation: return "Microsoft PowerPoint presentation comparison"
        case .excelWorkbook: return "Microsoft Excel workbook comparison"
        case .excelWorkbookFast: return "Microsoft Excel workbook comparison (fast)"
        case .libreOfficeDocument: return "LibreOffice document comparison"
        }
    }
    public var extensions: [String] {
        switch self {
        case .zipInventory: return [".zip"]
        case .binaryReport: return [".dll", ".exe", ".dylib"]
        case .mathematicaNotebook: return [".nb"]
        case .wordDocument: return [".doc", ".docx", ".docm", ".dot", ".dotx"]
        case .powerPointPresentation: return [".ppt", ".pptx", ".pptm"]
        case .excelWorkbook: return [".xls", ".xlsx", ".xlsm", ".xlsb", ".xlam"]
        case .excelWorkbookFast: return []
        case .libreOfficeDocument: return [".odt", ".ods", ".sxw"]
        }
    }
}
public struct DiffToolProgram: Codable, Equatable, Sendable {
    public var enabled = false
    public var applicationPath = ""
    public var arguments = "%base %mine"
    public var bookmark: Data?
    public var builtIn: BuiltInDiffTool?
    public init() {}
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.applicationPath.utf8.elementsEqual(rhs.applicationPath.utf8) &&
        lhs.arguments.utf8.elementsEqual(rhs.arguments.utf8) && lhs.bookmark == rhs.bookmark && lhs.builtIn == rhs.builtIn
    }
    public var displayName: String { builtIn?.title ?? applicationPath }
    public var isApplicationBundle: Bool { (applicationPath as NSString).pathExtension.lowercased() == "app" }
    public var valid: Bool {
        !enabled || builtIn != nil || (applicationPath.hasPrefix("/") && !applicationPath.contains("\0") &&
            (isApplicationBundle || bookmark != nil || FileManager.default.isExecutableFile(atPath: applicationPath) &&
                (try? URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) &&
            (try? Self.argumentTokens(arguments)) != nil)
    }
    /// Parse before substitution: filenames and titles always remain one argument.
    /// No shell expansion, command substitution or environment evaluation occurs.
    public static func argumentTokens(_ text: String) throws -> [String] {
        guard !text.contains("\0") else { throw DiffToolFailure.arguments }
        var tokens: [String] = [], token = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { token.append(character); escaped = false; started = true; continue }
            if character == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
                started = true
            } else if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace {
                if started { tokens.append(token); token = ""; started = false }
            } else { token.append(character); started = true }
        }
        guard !escaped, quote == nil else { throw DiffToolFailure.arguments }
        if started { tokens.append(token) }; return tokens
    }
    public func expandedArguments(values: [String: String], files: [String] = ["base", "mine"]) throws -> [String] {
        var tokens = try Self.argumentTokens(arguments)
        if !files.contains(where: { arguments.contains("%" + $0) }) { tokens += files.map { "%" + $0 } }
        return tokens.map { token in
            // Single pass prevents placeholder-looking file names being expanded again.
            var output = "", index = token.startIndex
            let keys = values.keys.sorted { $0.count > $1.count }
            while index < token.endIndex {
                if token[index] == "%", let key = keys.first(where: { token[index...].hasPrefix("%" + $0) }) {
                    output += values[key]!; index = token.index(index, offsetBy: key.count + 1)
                } else { output.append(token[index]); index = token.index(after: index) }
            }
            return output
        }
    }
}
public struct DiffToolAssociation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var pattern = ""
    public var program = DiffToolProgram()
    public init() { program.enabled = true }
    public static func normalized(_ pattern: String) -> String {
        String(pattern.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "*" })).lowercased()
    }
    /// Source lowercases association keys, without merging Unicode spellings.
    public static func identity(_ pattern: String) -> Data { Data(normalized(pattern).utf8) }
    public var patternIdentity: Data { Self.identity(pattern) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.pattern.utf8.elementsEqual(rhs.pattern.utf8) && lhs.program == rhs.program
    }
    public var normalizedPattern: String { Self.normalized(pattern) }
    public var valid: Bool { !normalizedPattern.isEmpty && !normalizedPattern.contains("/") && !normalizedPattern.contains("\0") && program.valid }
}
/// PickDiffTool followed by StartExtDiff's alternate-tool inversion. Image is
/// an explicit viewer choice; content sniffing must not undo a Merge selection.
public enum DiffToolSelection: Equatable, Sendable {
    case merge, image, program(DiffToolProgram)
    public static let imageExtensions = ["jpg", "jpeg", "bmp", "gif", "png", "ico", "tif", "tiff", "dib", "emf", "wmf", "cur", "webp", "svg", "svgz"]
}
public struct DiffToolPreferences: Codable, Equatable, Sendable {
    public var program = DiffToolProgram()
    public var associations: [DiffToolAssociation] = []
    public init() {}
    public var valid: Bool { program.valid && associations.allSatisfy(\.valid) && Set(associations.map(\.patternIdentity)).count == associations.count }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "TurtleGit.DiffTools") else { var value = Self(); value.restoreBundledAssociations(); return value }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw DiffToolFailure.association }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.DiffTools")
    }
    /// SetupDiffScripts(force): replace only extensions for shipped adapters;
    /// retain unrelated user associations and an existing row identity.
    public mutating func restoreBundledAssociations() {
        for tool in BuiltInDiffTool.allCases {
            for pattern in tool.extensions {
                var value = associations.first { $0.patternIdentity == DiffToolAssociation.identity(pattern) } ?? DiffToolAssociation()
                value.pattern = pattern; value.program = DiffToolProgram(); value.program.enabled = true; value.program.builtIn = tool
                associations.removeAll { $0.patternIdentity == DiffToolAssociation.identity(pattern) }; associations.append(value)
            }
        }
    }
    /// AppUtils::PickDiffTool: destination filename, base filename, destination extension.
    public func selection(base: String, destination: String, alternate: Bool = false) throws -> DiffToolSelection {
        let filename = HistoricalGitPath.filename(destination)?.lowercased()
        let baseName = HistoricalGitPath.filename(base)?.lowercased()
        let ext = HistoricalGitPath.fileExtension(destination).lowercased()
        let candidates = [filename, baseName].compactMap { $0 } + (ext.isEmpty ? [] : ["." + ext])
        let association = candidates.compactMap { name in associations.first { $0.patternIdentity == Data(name.utf8) } }.first
        // Source built-in image comparison precedes the default text diff tool.
        if association == nil, DiffToolSelection.imageExtensions.contains(ext) { return alternate ? .merge : .image }
        let found = association?.program ?? program
        guard found.enabled != alternate, found.builtIn != nil || !found.applicationPath.isEmpty else { return .merge }
        var result = found; result.enabled = true
        guard result.valid else { throw DiffToolFailure.application }
        return .program(result)
    }
    public func selected(base: String, destination: String, alternate: Bool = false) throws -> DiffToolProgram? {
        if case .program(let program) = try selection(base: base, destination: destination, alternate: alternate) { return program }; return nil
    }
}

public struct MergeToolPreferences: Codable, Equatable, Sendable {
    public var program: DiffToolProgram
    public var associations: [DiffToolAssociation] = []
    public var blockWhileMerging = false
    public var trustExitCode = false
    public init() { var value = DiffToolProgram(); value.arguments = "%base %theirs %mine %merged"; program = value }
    public var supportsTrustedExit: Bool {
        (program.enabled && program.builtIn == nil && !program.isApplicationBundle) || associations.contains { $0.program.enabled && $0.program.builtIn == nil && !$0.program.isApplicationBundle }
    }
    public static func supports(_ tool: BuiltInDiffTool?) -> Bool { tool == nil || tool == .wordDocument || tool == .libreOfficeDocument }
    public var valid: Bool { Self.supports(program.builtIn) && associations.allSatisfy { Self.supports($0.program.builtIn) } && program.valid && associations.allSatisfy(\.valid) && Set(associations.map(\.patternIdentity)).count == associations.count }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "TurtleGit.MergeTools") else { var value=Self(); value.restoreBundledAssociations(); return value }
        guard let value = try? JSONDecoder().decode(Self.self, from:data) else { return Self() }
        return value
    }
    public mutating func restoreBundledAssociations() {
        for (pattern, tool) in [(".doc", BuiltInDiffTool.wordDocument), (".docx", .wordDocument), (".docm", .wordDocument), (".odt", .libreOfficeDocument), (".ods", .libreOfficeDocument), (".sxw", .libreOfficeDocument)] {
            var value=associations.first { $0.patternIdentity == DiffToolAssociation.identity(pattern) } ?? DiffToolAssociation()
            value.pattern=pattern; value.program=DiffToolProgram(); value.program.enabled=true; value.program.builtIn = tool
            associations.removeAll { $0.patternIdentity == DiffToolAssociation.identity(pattern) }; associations.append(value)
        }
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw DiffToolFailure.association }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.MergeTools")
    }
    public func selected(path: String, alternate: Bool = false) throws -> DiffToolProgram? {
        let name = HistoricalGitPath.filename(path)?.lowercased(), ext = HistoricalGitPath.fileExtension(path).lowercased()
        let keys = name.map { ["." + $0] } ?? []
        let candidates = keys + (ext.isEmpty ? [] : ["." + ext])
        let found = candidates.compactMap { key in associations.first { $0.patternIdentity == Data(key.utf8) } }.first?.program ?? program
        guard found.enabled != alternate, found.builtIn != nil || !found.applicationPath.isEmpty else { return nil }
        var result = found; result.enabled = true
        guard result.valid, Self.supports(result.builtIn) else { throw DiffToolFailure.application }; return result
    }
}
public struct ExternalMergeInputs: Sendable {
    public let entry: ConflictEntry
    public let base: Data, mine: Data, theirs: Data
    public let result: URL
    public var conflictTitles: ConflictTitles? = nil
}
extension GitRepository {
    public func externalMergeInputs(path: String, identityOptions: ConflictIdentityOptions = .init(), cancellation: OperationCancellation? = nil) throws -> ExternalMergeInputs {
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { $0.path == path }), !entry.isSubmodule, !entry.isDeleteModify,
              entry.stages.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else { throw TextConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        let rebase = try conflictIsRebase(cancellation: cancellation)
        func bytes(_ stage: Int) throws -> Data {
            guard let object = entry.stages.first(where: { $0.number == stage })?.object else { return Data() }
            return try run(["cat-file", "blob", object], cancellation: cancellation).stdout
        }
        let result = root.appendingPathComponent(path)
        _ = try conflictWorkingSnapshot(result)
        var input = try ExternalMergeInputs(entry: entry, base: bytes(1), mine: bytes(rebase ? 3 : 2), theirs: bytes(rebase ? 2 : 3), result: result)
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        guard try conflictIsRebase(cancellation: cancellation) == rebase else { throw ResolveFailure.stale }
        input.conflictTitles = try conflictTitles(rebase: rebase, options: identityOptions, cancellation: cancellation)
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        guard try conflictIsRebase(cancellation: cancellation) == rebase else { throw ResolveFailure.stale }
        try cancellation?.check(); return input
    }
}

extension GitRepository {
    /// Revalidate immediately before launching a tool. Private side files may
    /// already have been prepared while the real result stays in this repository.
    public func validateExternalMergeInputs(_ input: ExternalMergeInputs, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard input.result.standardizedFileURL.path == root.appendingPathComponent(input.entry.path).standardizedFileURL.path else { throw ResolveFailure.outsideWorkingTree }
        try validateConflicts([input.entry], using: .current, cancellation: cancellation)
        _ = try conflictWorkingSnapshot(input.result)
        try cancellation?.check()
    }
}
