// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import TurtleGitSMTP

public enum SMTPEncryption: Int32, Sendable { case none = 0, startTLS = 1, tls = 2 }
public struct SMTPServer: Sendable {
    public var host: String
    public var port: Int
    public var encryption: SMTPEncryption
    public var connectTimeoutMilliseconds = 30_000
    public var timeoutMilliseconds = 60_000
    /// Optional private CA file, retaining peer and hostname verification.
    /// The caller must retain its sandbox file grant throughout submission.
    public var trustedCertificates: URL?
    public init(host: String, port: Int, encryption: SMTPEncryption) {
        self.host = host; self.port = port; self.encryption = encryption
    }
}
public struct SMTPAuthentication: Sendable {
    public let login: String
    public let password: String
    public init(login: String, password: String) { self.login = login; self.password = password }
}
public struct SMTPUploadProgress: Sendable {
    public let uploaded: UInt64
    public let total: UInt64
}
public struct SMTPReceipt: Sendable {
    public let response: Int
}
public enum SMTPFailure: LocalizedError {
    case configuration, recipients, authentication
    case transfer(code: Int32, response: Int, possiblySubmitted: Bool)
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Use a server hostname, TCP port from 1 to 65535 and positive SMTP timeouts."
        case .recipients: return "Enter at least one To or CC address."
        case .authentication: return "SMTP credentials require a login and cannot contain NUL."
        case let .transfer(code, response, possiblySubmitted):
            return "SMTP submission failed (transport \(code), response \(response))." + (possiblySubmitted ? " The server may have accepted this message; verify before retrying." : "")
        }
    }
}
private final class SMTPProgressContext {
    let token: OperationCancellation
    let progress: (@Sendable (SMTPUploadProgress) -> Void)?
    init(_ token: OperationCancellation, _ progress: (@Sendable (SMTPUploadProgress) -> Void)?) { self.token = token; self.progress = progress }
}
private let smtpProgress: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int32 = { opaque, uploaded, total in
    guard let opaque else { return 1 }
    let context = Unmanaged<SMTPProgressContext>.fromOpaque(opaque).takeUnretainedValue()
    if context.token.isCancelled { return 1 }
    context.progress?(SMTPUploadProgress(uploaded: uploaded, total: total)); return 0
}
/// One configured-server submission. No queue or automatic retries. All inputs
/// and MIME bytes are captured; work runs outside the main actor. No transcript
/// or secrets are logged, and ambient proxy/netrc configuration is not used.
public enum PatchMailSMTP {
    public static func send(message: PatchMailMessage, sender: PatchMailSender, server: SMTPServer,
                            authentication: SMTPAuthentication? = nil, bodyCharset: PatchMailBodyCharset = .utf8,
                            date: Date = Date(), identifier: UUID = UUID(),
                            cancellation: OperationCancellation? = nil,
                            onProgress: (@Sendable (SMTPUploadProgress) -> Void)? = nil) async throws -> SMTPReceipt {
        let token = cancellation ?? OperationCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                try submit(message: message, sender: sender, server: server, authentication: authentication,
                           bodyCharset: bodyCharset, date: date, identifier: identifier, token: token, progress: onProgress)
            }.value
        }, onCancel: { token.cancel() })
    }
    /// Validates configuration without opening a connection or querying credentials.
    public static func validate(server: SMTPServer, authentication: SMTPAuthentication? = nil) throws {
        let host = server.host
        let domain = !host.isEmpty && host.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
        let ipv6 = host.contains(":") && host.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 }
        guard domain || ipv6, (1...65535).contains(server.port),
              (1...Int(Int32.max)).contains(server.connectTimeoutMilliseconds),
              (1...Int(Int32.max)).contains(server.timeoutMilliseconds),
              server.trustedCertificates == nil || (server.trustedCertificates!.isFileURL && !server.trustedCertificates!.path.utf8.contains(0)) else { throw SMTPFailure.configuration }
        if let authentication {
            guard !authentication.login.isEmpty, !authentication.login.utf8.contains(0), !authentication.password.utf8.contains(0) else { throw SMTPFailure.authentication }
        }
    }
    private static func submit(message: PatchMailMessage, sender: PatchMailSender, server: SMTPServer,
                               authentication: SMTPAuthentication?, bodyCharset: PatchMailBodyCharset,
                               date: Date, identifier: UUID, token: OperationCancellation, progress: (@Sendable (SMTPUploadProgress) -> Void)?) throws -> SMTPReceipt {
        try token.check()
        try validate(server: server, authentication: authentication)
        let host = server.host, ipv6 = host.contains(":")
        let recipients = try (message.to + message.cc).map { try PatchMailMIME.envelopeAddress($0) }
        guard !recipients.isEmpty else { throw SMTPFailure.recipients }
        let bytes = try PatchMailMIME.data(message: message, sender: sender, date: date, identifier: identifier, bodyCharset: bodyCharset)
        // MIME validation enforces a bare sender address; don't infer it from a
        // patch author or render display-name header words into the envelope.
        let from = try PatchMailMIME.envelopeAddress(sender.email)
        try token.check()
        let url = "\(server.encryption == .tls ? "smtps" : "smtp")://\(ipv6 ? "[" + host + "]" : host):\(server.port)"
        let allocated = recipients.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { throw SMTPFailure.transfer(code: 27, response: 0, possiblySubmitted: false) }
        let pointers = allocated.map { $0.map { UnsafePointer($0) } }
        let context = SMTPProgressContext(token, progress)
        var response = 0, possiblySubmitted: Int32 = 0
        let code = withExtendedLifetime(context) { url.withCString { url in from.withCString { sender in
            (authentication?.login ?? "").withCString { login in (authentication?.password ?? "").withCString { password in
                (server.trustedCertificates?.path ?? "").withCString { ca in
                    pointers.withUnsafeBufferPointer { addresses in bytes.withUnsafeBytes { payload in
                        tg_smtp_send(url, server.encryption.rawValue, sender, addresses.baseAddress, addresses.count,
                                     payload.bindMemory(to: UInt8.self).baseAddress, payload.count,
                                     authentication == nil ? nil : login, authentication == nil ? nil : password,
                                     server.trustedCertificates == nil ? nil : ca,
                                     server.connectTimeoutMilliseconds, server.timeoutMilliseconds,
                                     smtpProgress, Unmanaged.passUnretained(context).toOpaque(), &response, &possiblySubmitted)
                    } }
                }
            } }
        } } }
        if code == 0 { return SMTPReceipt(response: response) }
        // A cancellation before DATA cannot conceal message acceptance. After
        // the complete upload, retain uncertainty rather than suggesting retry.
        if token.isCancelled && possiblySubmitted == 0 { throw OperationCancellationFailure.cancelled }
        throw SMTPFailure.transfer(code: code, response: response, possiblySubmitted: possiblySubmitted != 0)
    }
}

public enum SMTPSeriesProgress: Sendable {
    case sending(index: Int, total: Int, attempt: Int)
    case upload(index: Int, progress: SMTPUploadProgress)
    case retry(index: Int, nextAttempt: Int)
    case accepted(index: Int, response: Int)
}
/// Retains acceptance before the failed item, so a UI can report partial delivery
/// without silently resending already accepted messages.
public struct SMTPSeriesFailure: LocalizedError {
    public let index: Int
    public let attempts: Int
    public let accepted: [SMTPReceipt]
    public let cause: Error
    public var errorDescription: String? { cause.localizedDescription }
}
extension PatchMailSMTP {
    /// Source-style ordered submission: up to three attempts per message, with
    /// two seconds between failures. A lost final acknowledgement never retries:
    /// the server may already have accepted that message.
    public static func sendSeries(messages: [PatchMailMessage], sender: PatchMailSender, server: SMTPServer,
                                  authentication: SMTPAuthentication? = nil, bodyCharset: PatchMailBodyCharset = .utf8,
                                  cancellation: OperationCancellation? = nil,
                                  onProgress: (@Sendable (SMTPSeriesProgress) -> Void)? = nil) async throws -> [SMTPReceipt] {
        let token = cancellation ?? OperationCancellation()
        return try await withTaskCancellationHandler(operation: {
            try token.check()
            let stamps = messages.map { _ in (Date(), UUID()) }
            // Reject malformed later messages before any earlier message leaves.
            for (index, message) in messages.enumerated() {
                try token.check()
                guard !(message.to + message.cc).isEmpty else { throw SMTPFailure.recipients }
                _ = try (message.to + message.cc).map { try PatchMailMIME.envelopeAddress($0) }
                _ = try PatchMailMIME.data(message: message, sender: sender, date: stamps[index].0,
                                           identifier: stamps[index].1, bodyCharset: bodyCharset)
            }
            return try await runSeries(count: messages.count, cancellation: token, onProgress: onProgress, wait: {
                // Cooperative token cancellation also interrupts retry delay.
                for _ in 0..<100 { try token.check(); try await Task.sleep(nanoseconds: 20_000_000) }
                try token.check()
            }, submit: { index, progress in
                try await send(message: messages[index], sender: sender, server: server, authentication: authentication,
                               bodyCharset: bodyCharset, date: stamps[index].0, identifier: stamps[index].1,
                               cancellation: token, onProgress: progress)
            })
        }, onCancel: { token.cancel() })
    }
    static func runSeries(count: Int, cancellation: OperationCancellation,
                          onProgress: (@Sendable (SMTPSeriesProgress) -> Void)?,
                          wait: @Sendable () async throws -> Void,
                          submit: @Sendable (Int, @escaping @Sendable (SMTPUploadProgress) -> Void) async throws -> SMTPReceipt) async throws -> [SMTPReceipt] {
        var accepted: [SMTPReceipt] = []
        for index in 0..<count {
            for attempt in 1...3 {
                do {
                    try cancellation.check(); try Task.checkCancellation()
                    onProgress?(.sending(index: index, total: count, attempt: attempt))
                    let receipt = try await submit(index, { onProgress?(.upload(index: index, progress: $0)) })
                    accepted.append(receipt)
                    onProgress?(.accepted(index: index, response: receipt.response))
                    break
                } catch {
                    let retry: Bool
                    if case SMTPFailure.transfer(_, _, let uncertain) = error {
                        retry = !uncertain && !cancellation.isCancelled && !Task.isCancelled && attempt < 3
                    } else { retry = false }
                    guard retry else { throw SMTPSeriesFailure(index: index, attempts: attempt, accepted: accepted, cause: error) }
                    onProgress?(.retry(index: index, nextAttempt: attempt + 1))
                    do { try await wait(); try cancellation.check(); try Task.checkCancellation() }
                    catch { throw SMTPSeriesFailure(index: index, attempts: attempt, accepted: accepted, cause: error) }
                }
            }
        }
        return accepted
    }
}
