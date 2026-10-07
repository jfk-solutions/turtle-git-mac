import Foundation
import CoreFoundation

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

/// Ordered aliases from UnicodeUtils::GetCPCode. Duplicate names retain the
/// first source entry; names absent from this table use source UTF-8 fallback.
public enum CommitMessageEncoding {
    public static let aliases: [(codePage: UInt32, name: String)] = [
        (37, "IBM037"),
        (437, "IBM437"),
        (500, "IBM500"),
        (708, "ASMO-708"),
        (709, "Arabic"),
        (710, "Arabic"),
        (720, "DOS-720"),
        (737, "ibm737"),
        (775, "ibm775"),
        (850, "ibm850"),
        (852, "ibm852"),
        (855, "IBM855"),
        (857, "ibm857"),
        (858, "IBM00858"),
        (860, "IBM860"),
        (861, "ibm861"),
        (862, "DOS-862"),
        (863, "IBM863"),
        (864, "IBM864"),
        (865, "IBM865"),
        (866, "cp866"),
        (869, "ibm869"),
        (870, "IBM870"),
        (874, "windows-874"),
        (875, "cp875"),
        (932, "shift_jis"),
        (936, "gb2312"),
        (949, "ks_c_5601-1987"),
        (949, "cp949"),
        (950, "big5"),
        (1026, "IBM1026"),
        (1047, "IBM01047"),
        (1140, "IBM01140"),
        (1141, "IBM01141"),
        (1142, "IBM01142"),
        (1143, "IBM01143"),
        (1144, "IBM01144"),
        (1145, "IBM01145"),
        (1146, "IBM01146"),
        (1147, "IBM01147"),
        (1148, "IBM01148"),
        (1149, "IBM01149"),
        (1200, "utf-16"),
        (1201, "unicodeFFFE"),
        (1250, "windows-1250"),
        (1251, "windows-1251"),
        (1251, "cp1251"),
        (1251, "cp-1251"),
        (1251, "cp_1251"),
        (1252, "windows-1252"),
        (1253, "windows-1253"),
        (1254, "windows-1254"),
        (1255, "windows-1255"),
        (1256, "windows-1256"),
        (1257, "windows-1257"),
        (1258, "windows-1258"),
        (1361, "Johab"),
        (10000, "macintosh"),
        (10001, "x-mac-japanese"),
        (10002, "x-mac-chinesetrad"),
        (10003, "x-mac-korean"),
        (10004, "x-mac-arabic"),
        (10005, "x-mac-hebrew"),
        (10006, "x-mac-greek"),
        (10007, "x-mac-cyrillic"),
        (10008, "x-mac-chinesesimp"),
        (10010, "x-mac-romanian"),
        (10017, "x-mac-ukrainian"),
        (10021, "x-mac-thai"),
        (10029, "x-mac-ce"),
        (10079, "x-mac-icelandic"),
        (10081, "x-mac-turkish"),
        (10082, "x-mac-croatian"),
        (12000, "utf-32"),
        (12001, "utf-32BE"),
        (20000, "x-Chinese_CNS"),
        (20001, "x-cp20001"),
        (20002, "x_Chinese-Eten"),
        (20003, "x-cp20003"),
        (20004, "x-cp20004"),
        (20005, "x-cp20005"),
        (20105, "x-IA5"),
        (20106, "x-IA5-German"),
        (20107, "x-IA5-Swedish"),
        (20108, "x-IA5-Norwegian"),
        (20127, "us-ascii"),
        (20261, "x-cp20261"),
        (20269, "x-cp20269"),
        (20273, "IBM273"),
        (20277, "IBM277"),
        (20278, "IBM278"),
        (20280, "IBM280"),
        (20284, "IBM284"),
        (20285, "IBM285"),
        (20290, "IBM290"),
        (20297, "IBM297"),
        (20420, "IBM420"),
        (20423, "IBM423"),
        (20424, "IBM424"),
        (20833, "x-EBCDIC-KoreanExtended"),
        (20838, "IBM-Thai"),
        (20866, "koi8-r"),
        (20871, "IBM871"),
        (20880, "IBM880"),
        (20905, "IBM905"),
        (20924, "IBM00924"),
        (20932, "EUC-JP"),
        (20936, "x-cp20936"),
        (20949, "x-cp20949"),
        (21025, "cp1025"),
        (21027, "21027"),
        (21866, "koi8-u"),
        (28591, "iso-8859-1"),
        (28592, "iso-8859-2"),
        (28593, "iso-8859-3"),
        (28594, "iso-8859-4"),
        (28595, "iso-8859-5"),
        (28596, "iso-8859-6"),
        (28597, "iso-8859-7"),
        (28598, "iso-8859-8"),
        (28599, "iso-8859-9"),
        (28603, "iso-8859-13"),
        (28605, "iso-8859-15"),
        (29001, "x-Europa"),
        (38598, "iso-8859-8-i"),
        (50220, "iso-2022-jp"),
        (50221, "csISO2022JP"),
        (50222, "iso-2022-jp"),
        (50225, "iso-2022-kr"),
        (50227, "x-cp50227"),
        (50229, "ISO"),
        (50930, "EBCDIC"),
        (50931, "EBCDIC"),
        (50933, "EBCDIC"),
        (50935, "EBCDIC"),
        (50936, "EBCDIC"),
        (50937, "EBCDIC"),
        (50939, "EBCDIC"),
        (51932, "euc-jp"),
        (51936, "EUC-CN"),
        (51949, "euc-kr"),
        (51950, "EUC"),
        (52936, "hz-gb-2312"),
        (54936, "GB18030"),
        (57002, "x-iscii-de"),
        (57003, "x-iscii-be"),
        (57004, "x-iscii-ta"),
        (57005, "x-iscii-te"),
        (57006, "x-iscii-as"),
        (57007, "x-iscii-or"),
        (57008, "x-iscii-ka"),
        (57009, "x-iscii-ma"),
        (57010, "x-iscii-gu"),
        (57011, "x-iscii-pa"),
        (65000, "utf-7"),
        (65001, "utf-8"),
    ]
    public static func codePage(_ name: String) -> UInt32 {
        aliases.first { $0.name.lowercased() == name.lowercased() }?.codePage ?? 65001
    }
    public static func decode(_ data: Data, name: String) throws -> String {
        let page = codePage(name)
        if page == 65001 { return String(decoding: data, as: UTF8.self) }
        let encoding = CFStringConvertWindowsCodepageToEncoding(page)
        guard encoding != kCFStringEncodingInvalidId, ![1200, 1201, 12000, 12001].contains(page),
              let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "Could not decode the commit message as “" + name + "”.")
        }
        return text
    }
    public static func encode(_ text: String, name: String) throws -> Data {
        let page = codePage(name)
        if page == 65001 { return Data(text.utf8) }
        let encoding = CFStringConvertWindowsCodepageToEncoding(page)
        guard encoding != kCFStringEncodingInvalidId, ![1200, 1201, 12000, 12001].contains(page) else {
            throw GitFailure(arguments: ["commit"], code: 1, message: "The commit encoding “" + name + "” (CP " + String(page) + ") is unavailable on macOS.")
        }
        // SaveCommitUnicodeFile converts each line independently, including LF.
        // CF uses ? for unmappable text, corresponding to source replacement.
        var data = Data(), lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            let value = (line + (index < lines.count - 1 || text.hasSuffix("\n") ? "\n" : "")) as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(value))
            var needed = 0
            let converted = CFStringGetBytes(value, range, encoding, 0x3f, false, nil, 0, &needed)
            guard converted == range.length else { throw GitFailure(arguments: ["commit"], code: 1, message: "Could not encode the commit message as “" + name + "”.") }
            var bytes = Data(count: needed), written = 0
            let completed = bytes.withUnsafeMutableBytes { buffer in
                CFStringGetBytes(value, range, encoding, 0x3f, false, buffer.bindMemory(to: UInt8.self).baseAddress, needed, &written)
            }
            guard completed == range.length, written == needed else { throw GitFailure(arguments: ["commit"], code: 1, message: "Could not encode the commit message as “" + name + "”.") }
            data.append(bytes)
        }
        return data
    }
}

struct EncodedCommitMessageFile {
    let directory: URL
    let url: URL
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

extension GitRepository {
    func commitMessageEncodingName() throws -> String {
        do { return try run(["config", "--get", "i18n.commitencoding"]).text.trimmingCharacters(in: .newlines) }
        catch let failure as GitFailure where failure.code == 1 { return "" }
    }
    public func encodedCommitMessage(_ message: String) throws -> Data {
        try CommitMessageEncoding.encode(message, name: commitMessageEncodingName())
    }
    public func decodedCommitMessage(_ data: Data) throws -> String {
        try CommitMessageEncoding.decode(data, name: commitMessageEncodingName())
    }
    func makeCommitMessageFile(_ message: String, appendFinalNewline: Bool = true) throws -> EncodedCommitMessageFile {
        let payload = !appendFinalNewline || message.hasSuffix("\n") ? message : message + "\n"
        let data = try encodedCommitMessage(payload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-message-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let result = EncodedCommitMessageFile(directory: directory, url: directory.appendingPathComponent("message"))
        guard FileManager.default.createFile(atPath: result.url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            result.remove(); throw GitFailure(arguments: ["commit"], code: 1, message: "Could not save the commit message file.")
        }
        return result
    }
}
