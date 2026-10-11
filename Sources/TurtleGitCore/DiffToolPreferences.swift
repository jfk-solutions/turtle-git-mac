// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum DiffToolFailure: LocalizedError {
    case application, arguments, association
    public var errorDescription: String? {
        switch self {
        case .application: return "Choose a diff application using its full .app path."
        case .arguments: return "The arguments contain an unfinished quote, escape or NUL character."
        case .association: return "Use a unique file extension (such as .swift) or filename without folder separators."
        }
    }
}
public struct DiffToolProgram: Codable, Equatable, Sendable {
    public var enabled = false
    public var applicationPath = ""
    public var arguments = "%base %mine"
    public var bookmark: Data?
    public init() {}
    public var valid: Bool {
        !enabled || (applicationPath.hasPrefix("/") && !applicationPath.contains("\0") && (applicationPath as NSString).pathExtension.lowercased() == "app" && (try? Self.argumentTokens(arguments)) != nil)
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
    public func expandedArguments(values: [String: String]) throws -> [String] {
        var tokens = try Self.argumentTokens(arguments)
        if !arguments.contains("%base") && !arguments.contains("%mine") { tokens += ["%base", "%mine"] }
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
    public var normalizedPattern: String { Self.normalized(pattern) }
    public var valid: Bool { !normalizedPattern.isEmpty && !normalizedPattern.contains("/") && !normalizedPattern.contains("\0") && program.valid }
}
public struct DiffToolPreferences: Codable, Equatable, Sendable {
    public var program = DiffToolProgram()
    public var associations: [DiffToolAssociation] = []
    public init() {}
    public var valid: Bool { program.valid && associations.allSatisfy(\.valid) && Set(associations.map(\.normalizedPattern)).count == associations.count }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "TurtleGit.DiffTools"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw DiffToolFailure.association }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.DiffTools")
    }
    /// AppUtils::PickDiffTool: destination filename, base filename, destination extension.
    public func selected(base: String, destination: String, alternate: Bool = false) throws -> DiffToolProgram? {
        let filename = (destination as NSString).lastPathComponent.lowercased()
        let baseName = (base as NSString).lastPathComponent.lowercased()
        let ext = (filename as NSString).pathExtension
        let candidates = [filename, baseName] + (ext.isEmpty ? [] : ["." + ext])
        let association = candidates.compactMap { name in associations.first { $0.normalizedPattern == name } }.first
        // Source built-in image comparison precedes the default text diff tool.
        if association == nil, ["jpg", "jpeg", "bmp", "gif", "png", "ico", "tif", "tiff", "dib", "emf", "cur", "webp", "svg", "svgz"].contains(ext) { return nil }
        let found = association?.program ?? program
        guard found.enabled != alternate, !found.applicationPath.isEmpty else { return nil }
        var result = found; result.enabled = true
        guard result.valid else { throw DiffToolFailure.application }
        return result
    }
}
