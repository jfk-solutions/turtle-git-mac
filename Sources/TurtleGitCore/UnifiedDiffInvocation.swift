import Foundation

public struct UnifiedDiffInvocation: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        case empty
        case file(URL)
        case standardInput
    }
    public let input: Input
    public let title: String?

    /// Recognition is separate so malformed explicit viewer requests still
    /// report their error in the viewer rather than opening the workspace.
    public static func recognizes(arguments: [String]) -> Bool {
        var explicit = false, index = 0
        while index < arguments.count {
            let value = arguments[index], lower = value.lowercased()
            if value == "--" { break }
            if lower == "--command" || lower.hasPrefix("--command=") || lower == "/command" || lower.hasPrefix("/command:") { return false }
            if value.hasPrefix("--unified-diff") || lower == "/p" || lower.hasPrefix("/patchfile:") || lower.hasPrefix("/title:") { explicit = true }
            if value == "--title" || value == "--patchfile" { index += 1 }
            index += 1
        }
        return explicit
    }

    public static func parse(arguments: [String], currentDirectory: String) throws -> Self? {
        // TortoiseProc and Merge retain their own command-line grammars.
        guard recognizes(arguments: arguments) else { return nil }
        guard (currentDirectory as NSString).isAbsolutePath,
              !currentDirectory.utf8.contains(0), !arguments.contains(where: { $0.utf8.contains(0) }) else { throw UnifiedDiffInvocationFailure.input }
        var input: Input?, title: String?, hasTitle = false, hasMarker = false, positional = false, index = 0
        func file(_ path: String) throws -> Input {
            guard !path.isEmpty else { throw UnifiedDiffInvocationFailure.input }
            // Foundation's filesystem standardization can decompose a literal
            // NFC filename on Darwin. Normalize only lexical path components;
            // use the shared URLComponents constructor to preserve UTF-8 bytes.
            let absolute = path.hasPrefix("/") ? path : currentDirectory + "/" + path
            return .file(FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(absolute)))
        }
        func assign(_ next: Input) throws {
            guard input == nil else { throw UnifiedDiffInvocationFailure.input }
            input = next
        }
        while index < arguments.count {
            let value = arguments[index], lower = value.lowercased()
            if positional { try assign(file(value)) }
            else if value == "--" { positional = true }
            else if value == "--unified-diff" {
                guard !hasMarker else { throw UnifiedDiffInvocationFailure.input }; hasMarker = true
            } else if value == "--stdin" || lower == "/p" { try assign(.standardInput) }
            else if value == "--patchfile" || value == "--title" {
                index += 1
                guard index < arguments.count else { throw UnifiedDiffInvocationFailure.input }
                if value == "--patchfile" { try assign(file(arguments[index])) }
                else { guard !hasTitle else { throw UnifiedDiffInvocationFailure.input }; title = arguments[index]; hasTitle = true }
            } else if value.hasPrefix("--patchfile=") { try assign(file(String(value.dropFirst(12)))) }
            else if lower.hasPrefix("/patchfile:") { try assign(file(String(value.dropFirst(11)))) }
            else if value.hasPrefix("--title=") || lower.hasPrefix("/title:") {
                guard !hasTitle else { throw UnifiedDiffInvocationFailure.input }
                title = String(value.dropFirst(value.hasPrefix("--title=") ? 8 : 7)); hasTitle = true
            } else if value.hasPrefix("-") || value.hasPrefix("/") && !value.hasPrefix("//") && !value.dropFirst().contains("/") {
                throw UnifiedDiffInvocationFailure.input
            } else { try assign(file(value)) }
            index += 1
        }
        return Self(input: input ?? .empty, title: title)
    }
}

public enum UnifiedDiffInvocationFailure: LocalizedError {
    case input
    public var errorDescription: String? { "Invalid Unified Diff arguments. Choose one input and at most one title." }
}
