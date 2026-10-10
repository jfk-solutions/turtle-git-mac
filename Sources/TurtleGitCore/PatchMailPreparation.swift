// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SendMailPatch.cpp and CSendMailCombineable; see NOTICE.
import Foundation

public struct PatchMailOptions: Equatable, Sendable {
    public var to = ""
    public var cc = ""
    public var subject = ""
    public var attachment = false
    public var combine = false
    public init() {}
}

/// Both URL and immutable bytes are retained. A future transport must send the
/// captured bytes rather than silently reread a changed selected file.
public struct PatchMailAttachment: Equatable, Sendable {
    public let file: URL
    public let bytes: Data
}

public struct PatchMailMessage: Equatable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let subject: String
    public let body: Data
    public let attachments: [PatchMailAttachment]
}

public enum PatchMailPreparationFailure: LocalizedError {
    case noPatches, header
    public var errorDescription: String? {
        switch self {
        case .noPatches: return "No patches were selected."
        case .header: return "Mail addresses and subject must be on a single line."
        }
    }
}

/// Message preparation only: no mail client, SMTP, network or sending occurs.
public enum PatchMailPreparation {
    /// MailMsg uses a path-keyed map: later duplicate paths replace earlier
    /// entries and the client receives UTF-16 lexical path order.
    public static func mailClientAttachments(_ attachments: [PatchMailAttachment]) -> [PatchMailAttachment] {
        var paths: [[UInt16]: PatchMailAttachment] = [:]
        for attachment in attachments { paths[Array(attachment.file.path.utf16)] = attachment }
        return paths.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { $0.value }
    }

    /// CSendMailCombineable sends ordinary documents, preserving their complete
    /// text rather than treating a blank line as a format-patch header boundary.
    public static func messages(documents files: [URL], options: PatchMailOptions) throws -> [PatchMailMessage] {
        guard !files.isEmpty else { throw PatchMailPreparationFailure.noPatches }
        guard [options.to, options.cc, options.subject].allSatisfy({ field in
            field.utf8.allSatisfy { $0 != 13 && $0 != 10 && $0 != 0 }
        }) else { throw PatchMailPreparationFailure.header }
        let captures = try files.map { file -> PatchMailAttachment in
            guard file.isFileURL, !file.path.contains("\0"),
                  let values = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size < Int(Int32.max),
                  let bytes = try? Data(contentsOf: file), bytes.count < Int(Int32.max) else { throw SerialPatchFailure.file(file) }
            return PatchMailAttachment(file: file, bytes: bytes)
        }
        func text(_ capture: PatchMailAttachment) throws -> Data {
            guard let value = String(data: capture.bytes, encoding: .utf8) else { throw PatchMailMIMEFailure.charset }
            let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            var lines = normalized.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return Data(lines.map { $0 + "\r\n" }.joined().utf8)
        }
        func addresses(_ value: String) -> [String] {
            value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let to = addresses(options.to), cc = addresses(options.cc)
        if options.combine {
            var body = Data()
            if !options.attachment {
                for capture in captures {
                    body.append(Data((capture.file.path + ":\n").utf8))
                    body.append(try text(capture)); body.append(10)
                }
            }
            return [PatchMailMessage(to: to, cc: cc, subject: options.subject, body: body,
                                     attachments: options.attachment ? captures : [])]
        }
        return try captures.map {
            PatchMailMessage(to: to, cc: cc, subject: options.subject,
                             body: options.attachment ? Data() : try text($0),
                             attachments: options.attachment ? [$0] : [])
        }
    }

    public static func messages(files: [URL], options: PatchMailOptions) throws -> [PatchMailMessage] {
        guard !files.isEmpty else { throw PatchMailPreparationFailure.noPatches }
        return try messages(patches: files.map { try SerialPatch(file: $0) }, options: options)
    }

    public static func messages(patches: [SerialPatch], options: PatchMailOptions) throws -> [PatchMailMessage] {
        guard !patches.isEmpty else { throw PatchMailPreparationFailure.noPatches }
        let fields = [options.to, options.cc] + (options.combine ? [options.subject] : patches.map(\.subject))
        guard fields.allSatisfy({ field in field.utf8.allSatisfy { byte in byte != 13 && byte != 10 && byte != 0 } }) else { throw PatchMailPreparationFailure.header }
        func addresses(_ value: String) -> [String] {
            value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let to = addresses(options.to), cc = addresses(options.cc)
        if options.combine {
            var body = Data(), attachments: [PatchMailAttachment] = []
            for patch in patches {
                if options.attachment {
                    attachments.append(PatchMailAttachment(file: patch.file, bytes: patch.bytes))
                    body.append(Data((patch.subject + "\r\n").utf8))
                } else {
                    guard patch.inlineBody != nil else { throw SerialPatchFailure.body(patch.file) }
                    // Upstream deliberately includes each complete original mail
                    // patch, not just its stripped single-message body.
                    body.append(patch.bytes)
                }
            }
            return [PatchMailMessage(to: to, cc: cc, subject: options.subject, body: body, attachments: attachments)]
        }
        return try patches.map { patch in
            let body: Data
            if options.attachment { body = Data() }
            else {
                guard let contents = patch.inlineBody else { throw SerialPatchFailure.body(patch.file) }
                body = contents
            }
            return PatchMailMessage(to: to, cc: cc, subject: patch.subject, body: body,
                attachments: options.attachment ? [PatchMailAttachment(file: patch.file, bytes: patch.bytes)] : [])
        }
    }
}
