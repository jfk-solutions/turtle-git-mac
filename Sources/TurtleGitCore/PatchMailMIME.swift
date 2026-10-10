// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct PatchMailSender: Equatable, Sendable {
    public let name: String
    public let email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
}

extension GitRepository {
    /// Captures CSendMail's GetUserName/GetUserEmail precedence. The sender is
    /// the current Git author identity, independently of authors in patch files.
    public func patchMailSender(environmentOverrides: [String: String] = [:],
                                cancellation: OperationCancellation? = nil) throws -> PatchMailSender {
        let token = cancellation ?? OperationCancellation()
        try token.check()
        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, override in override }
        func value(_ key: String) throws -> String {
            let result = try run(["config", "--includes", "--null", "--get", key],
                                 environmentOverrides: environmentOverrides,
                                 successfulExitCodes: 0...1, cancellation: token)
            if result.exitCode == 1 { return "" }
            guard result.stdout.last == 0,
                  let value = String(data: result.stdout.dropLast(), encoding: .utf8) else {
                throw PatchMailMIMEFailure.identityConfiguration
            }
            return value
        }
        func identity(_ variable: String, _ author: String, _ user: String) throws -> String {
            if let supplied = environment[variable], !supplied.isEmpty { return supplied }
            let configured = try value(author)
            return configured.isEmpty ? try value(user) : configured
        }
        let name = try identity("GIT_AUTHOR_NAME", "author.name", "user.name")
        let email = try identity("GIT_AUTHOR_EMAIL", "author.email", "user.email")
        try token.check()
        return PatchMailSender(name: name, email: email)
    }
}

public enum PatchMailBodyCharset: String, Sendable {
    case utf8 = "UTF-8", latin1 = "ISO-8859-1"
}

public struct PatchMailMailbox: Equatable, Sendable {
    public let name: String
    public let address: String
}

public enum PatchMailMIMEFailure: LocalizedError {
    case header, mailbox, charset, identityConfiguration
    public var errorDescription: String? {
        switch self {
        case .header: return "A mail header contains invalid characters or is too long."
        case .mailbox: return "Use an email address or Name <email address> for each recipient. International email addresses are not yet supported."
        case .charset: return "The patch body is not UTF-8. Choose its character encoding before composing mail."
        case .identityConfiguration: return "Git returned invalid sender identity configuration."
        }
    }
}

/// Serializes captured preparation results; never rereads files or sends mail.
/// SMTP framing (including dot stuffing) belongs to the future transport.
public enum PatchMailMIME {
    public static func data(message: PatchMailMessage, sender: PatchMailSender,
                            date: Date = Date(), identifier: UUID = UUID(),
                            bodyCharset: PatchMailBodyCharset = .utf8) throws -> Data {
        guard date.timeIntervalSince1970.isFinite else { throw PatchMailMIMEFailure.header }
        if bodyCharset == .utf8 && String(data: message.body, encoding: .utf8) == nil {
            throw PatchMailMIMEFailure.charset
        }
        try singleLine(sender.name)
        let from = try mailbox(name: sender.name, address: sender.email)
        let to = try message.to.map(recipient), cc = try message.cc.map(recipient)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var output = "Date: \(formatter.string(from: date))\r\nFrom: \(from)\r\n"
        if !to.isEmpty { output += "To: " + to.joined(separator: ",\r\n ") + "\r\n" }
        if !cc.isEmpty { output += "Cc: " + cc.joined(separator: ",\r\n ") + "\r\n" }
        output += "Subject: \(try subject(message.subject))\r\n"
        output += "Message-ID: <\(identifier.uuidString.lowercased())@turtlegit.invalid>\r\n"
        output += "X-Mailer: TurtleGit for Mac\r\nMIME-Version: 1.0\r\n"
        let bodyHeader = "Content-Type: text/plain; charset=\(bodyCharset.rawValue)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        if message.attachments.isEmpty {
            output += bodyHeader + base64(message.body)
        } else {
            // '_' cannot appear in any of our Base64 payloads.
            let boundary = "TurtleGit_" + identifier.uuidString
            output += "Content-Type: multipart/mixed;\r\n boundary=\"\(boundary)\"\r\n\r\n"
            output += "--\(boundary)\r\n" + bodyHeader + base64(message.body) + "\r\n"
            for attachment in message.attachments {
                output += "--\(boundary)\r\nContent-Type: application/octet-stream\r\n"
                output += "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment;\r\n"
                output += filename(attachment.file.lastPathComponent) + "\r\n\r\n"
                output += base64(attachment.bytes) + "\r\n"
            }
            output += "--\(boundary)--\r\n"
        }
        // Enforce RFC message line limits, including user-supplied ASCII headers.
        guard output.components(separatedBy: "\r\n").allSatisfy({ $0.utf8.count <= 998 }) else {
            throw PatchMailMIMEFailure.header
        }
        var field: [String] = []
        func checkEncodedField() throws {
            if field.contains(where: { $0.contains("=?") }) && field.contains(where: { $0.utf8.count > 76 }) {
                throw PatchMailMIMEFailure.header
            }
        }
        for line in output.components(separatedBy: "\r\n") {
            if line.isEmpty { try checkEncodedField(); break }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                try checkEncodedField(); field = []
            }
            field.append(line)
        }
        return Data(output.utf8)
    }

    private static func singleLine(_ value: String) throws {
        guard value.utf8.allSatisfy({ ($0 >= 32 && $0 != 127) || $0 == 9 }) else {
            throw PatchMailMIMEFailure.header
        }
    }

    private static func subject(_ value: String) throws -> String {
        try singleLine(value)
        // Preserve opaque Git encoded words, as the pinned parser does. Encode
        // ordinary long/Unicode subjects into independently valid short words.
        if value.utf8.allSatisfy({ $0 < 128 }) && (value.utf8.count <= 70 || value.contains("=?")) {
            if value.contains("=?") && value.utf8.count > 67 {
                var result = "", column = 9, pending = "", word = ""
                func appendWord() throws {
                    guard !word.isEmpty else { return }
                    if column + pending.utf8.count + word.utf8.count > 76 {
                        guard word.utf8.count <= 75 else { throw PatchMailMIMEFailure.header }
                        if pending.isEmpty { pending = " " }
                        result += "\r\n"; column = 0
                    }
                    result += pending + word
                    column += pending.utf8.count + word.utf8.count
                    pending = ""; word = ""
                }
                for character in value {
                    if character == " " || character == "\t" {
                        try appendWord(); pending.append(character)
                    } else { word.append(character) }
                }
                try appendWord(); result += pending
                return result
            }
            return value
        }
        return encodedWords(value)
    }

    private static func encodedWords(_ value: String) -> String {
        var chunks: [Data] = [], current = Data()
        // Split on Unicode scalar boundaries, never inside a UTF-8 sequence.
        for scalar in value.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if current.count + bytes.count > 39 { chunks.append(current); current = Data() }
            current.append(bytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?" + $0.base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    private static func recipient(_ value: String) throws -> String {
        let parsed = try mailboxComponents(value)
        return try mailbox(name: parsed.name, address: parsed.address)
    }

    /// Parsed, validated mailbox fields for native client recipient records.
    public static func mailboxComponents(_ value: String) throws -> PatchMailMailbox {
        try singleLine(value)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") {
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
                // Unescape a quoted display name without dropping literal slashes.
                var decoded = "", escaped = false
                for character in name {
                    if escaped { decoded.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else { decoded.append(character) }
                }
                guard !escaped else { throw PatchMailMIMEFailure.mailbox }
                name = decoded
            }
            let address = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            _ = try mailbox(name: name, address: address)
            return PatchMailMailbox(name: name, address: address)
        }
        _ = try mailbox(name: "", address: trimmed)
        return PatchMailMailbox(name: "", address: trimmed)
    }

    /// Returns a validated SMTP envelope mailbox, omitting its display name.
    /// Header To/CC rendering remains independent of the envelope recipients.
    public static func envelopeAddress(_ value: String) throws -> String {
        try mailboxComponents(value).address
    }

    private static func mailbox(name: String, address: String) throws -> String {
        try singleLine(address)
        // Dot atoms, quoted local parts and ASCII domain literals. No groups,
        // comments, address lists or SMTPUTF8 are silently coerced into a mailbox.
        let pattern = #"^(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[^"\\\x00-\x1f\x7f]|\\[\x20-\x7e])+")@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\[[A-Za-z0-9:.]+\])$"#
        guard address.utf8.allSatisfy({ $0 < 128 }), address.utf8.count <= 254,
              address.range(of: pattern, options: .regularExpression) != nil else {
            throw PatchMailMIMEFailure.mailbox
        }
        return name.isEmpty ? address : encodedWords(name) + "\r\n <" + address + ">"
    }

    private static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
    }

    private static func filename(_ value: String) -> String {
        // RFC 2231 continuations, split only between complete percent triplets.
        let tokens = value.utf8.map { String(format: "%%%02X", $0) }
        var chunks: [String] = []
        for offset in stride(from: 0, to: tokens.count, by: 15) {
            chunks.append(tokens[offset..<min(offset + 15, tokens.count)].joined())
        }
        if chunks.isEmpty { chunks = ["patch"] }
        if chunks.count == 1 { return " filename*=UTF-8''" + chunks[0] }
        return chunks.enumerated().map { index, chunk in
            " filename*\(index)*=" + (index == 0 ? "UTF-8''" : "") + chunk
        }.joined(separator: ";\r\n")
    }
}
