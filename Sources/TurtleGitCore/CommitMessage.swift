import Foundation

public struct CommitMessageSeed: Sendable {
    public let template: String
    public let message: String
    public let warnings: [String]
}

/// Text retained by the dialog/history and text actually passed to Git differ
/// in upstream SaveCommitUnicodeFile: only outer trimming mutates the draft.
public struct CommitMessageFile: Equatable, Sendable {
    public let draft: String
    public let contents: String

    public static func format(_ message: String, stripComments: Bool = false, sanitize: Bool = true, commentPrefix: String = "#") -> Self {
        let draft = sanitize ? message.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n")) : message
        let prefix = commentPrefix.isEmpty ? "#" : commentPrefix
        guard !draft.isEmpty else { return Self(draft: draft, contents: "") }
        var lines = draft.components(separatedBy: "\n")
        if draft.hasSuffix("\n") { lines.removeLast() }
        var output = "", emptyLines = 0
        for raw in lines {
            // CStringUtils::StartsWith compares the original UTF-16 units, before
            // trimming the line. Leading indentation within later lines is retained.
            if stripComments && raw.utf16.starts(with: prefix.utf16) { continue }
            var line = raw
            while let last = line.unicodeScalars.last, last.value == 32 || last.value == 13 { line.unicodeScalars.removeLast() }
            if sanitize {
                if line.isEmpty { emptyLines += 1; continue }
                if emptyLines != 0 { output += "\n" }
                emptyLines = 0
            }
            output += line + "\n"
        }
        return Self(draft: draft, contents: output)
    }
}

extension GitRepository {
    public func prepareCommitMessageFile(_ message: String, stripComments: Bool = false, sanitize: Bool = true) throws -> CommitMessageFile {
        var prefix = "#"
        if stripComments {
            do { prefix = try run(["config", "--get", "core.commentchar"]).text.trimmingCharacters(in: .newlines) }
            catch let failure as GitFailure where failure.code == 1 { }
        }
        return CommitMessageFile.format(message, stripComments: stripComments, sanitize: sanitize, commentPrefix: prefix)
    }

    /// Mirrors upstream AppUtils' conflict hint detection and cleanup exemptions.
    public func rebaseMessageContainsConflictHints(_ message: String, stripComments: Bool = false) throws -> Bool {
        if stripComments { return false }
        func value(_ key: String) throws -> String {
            do { return try run(["config", "--get", key]).text.trimmingCharacters(in: .newlines) }
            catch let failure as GitFailure where failure.code == 1 { return "" }
        }
        if ["verbatim", "whitespace", "scissors"].contains(try value("core.cleanup")) { return false }
        let configured = try value("core.commentchar"), comment = configured.isEmpty ? "#" : configured
        guard let match = message.range(of: "\n" + comment + " Conflicts:\n" + comment + "\t") else { return false }
        return match.lowerBound > message.startIndex
    }
    /// Mirrors CommitDlg's GetCommitTemplate / LoadTextFile sequence without changing Git state.
    public func commitMessageSeed(includeOperationMessages: Bool = true) throws -> CommitMessageSeed {
        var template = "", warnings: [String] = []
        let configured: GitResult?
        do { configured = try run(["config", "--path", "--null", "--get", "commit.template"]) }
        catch let failure as GitFailure where failure.code == 1 { configured = nil }
        if let configured {
            var bytes = configured.stdout
            if bytes.last == 0 { bytes.removeLast() }
            let path = String(decoding: bytes, as: UTF8.self)
            if !path.isEmpty {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                do { template = try Self.readCommitMessage(url) }
                catch { warnings.append("Could not open and load commit.template file: \(url.path)\n\(error.localizedDescription)") }
            }
        }
        var message = template
        if includeOperationMessages {
            for name in ["SQUASH_MSG", "MERGE_MSG"] {
                var bytes = try run(["rev-parse", "--path-format=absolute", "--git-path", name]).stdout
                if bytes.last == 10 { bytes.removeLast() }
                let url = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
                if FileManager.default.fileExists(atPath: url.path) {
                    do { message = Self.normalizeCommitMessage(message + (try Self.readCommitMessage(url))) }
                    catch { warnings.append("Could not open and load \(name): \(url.path)\n\(error.localizedDescription)") }
                }
            }
        }
        return CommitMessageSeed(template: template, message: message, warnings: warnings)
    }

    private static func readCommitMessage(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitFailure(arguments: [], code: 1, message: "The commit message file is not valid UTF-8.")
        }
        return normalizeCommitMessage(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
    }

    private static func normalizeCommitMessage(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        while result.last == "\n" { result.removeLast() }
        return result + "\n"
    }
}
