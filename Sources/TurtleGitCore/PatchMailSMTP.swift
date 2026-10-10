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
    public init(response: Int) { self.response = response }
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
                            envelopeRecipients: [String]? = nil,
                            onProgress: (@Sendable (SMTPUploadProgress) -> Void)? = nil) async throws -> SMTPReceipt {
        let token = cancellation ?? OperationCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                try submit(message: message, sender: sender, server: server, authentication: authentication,
                           bodyCharset: bodyCharset, date: date, identifier: identifier, envelopeRecipients: envelopeRecipients, token: token, progress: onProgress)
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
                               date: Date, identifier: UUID, envelopeRecipients: [String]?, token: OperationCancellation, progress: (@Sendable (SMTPUploadProgress) -> Void)?) throws -> SMTPReceipt {
        try token.check()
        try validate(server: server, authentication: authentication)
        let host = server.host, ipv6 = host.contains(":")
        let originalRecipients = try (message.to + message.cc).map { try PatchMailMIME.envelopeAddress($0) }
        let recipients = try envelopeRecipients?.map { try PatchMailMIME.envelopeAddress($0) } ?? originalRecipients
        guard !recipients.isEmpty, recipients.allSatisfy({ originalRecipients.contains($0) }) else { throw SMTPFailure.recipients }
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
    public init(index: Int, attempts: Int, accepted: [SMTPReceipt], cause: Error) {
        self.index = index; self.attempts = attempts; self.accepted = accepted; self.cause = cause
    }
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
                    } else if let direct = error as? SMTPDirectFailure {
                        retry = direct.retryable && !cancellation.isCancelled && !Task.isCancelled && attempt < 3
                    } else { retry = false }
                    guard retry else { throw SMTPSeriesFailure(index: index, attempts: attempt, accepted: accepted, cause: error) }
                    onProgress?(.retry(index: index, nextAttempt: attempt + 1))
                    let errorBeforeWait = error
                    do { try await wait(); try cancellation.check(); try Task.checkCancellation() }
                    catch {
                        // A cancelled retry wait must retain any partial direct delivery.
                        let cause: Error
                        if let direct = errorBeforeWait as? SMTPDirectFailure {
                            cause = SMTPDirectFailure(domain: direct.domain, acceptedDomains: direct.acceptedDomains, cause: error)
                        } else { cause = error }
                        throw SMTPSeriesFailure(index: index, attempts: attempt, accepted: accepted, cause: cause)
                    }
                }
            }
        }
        return accepted
    }
}

/// System DNS-SD MX records for direct delivery. Response order is preserved;
/// a root exchange is an explicit null MX, never a usable SMTP hostname.
public struct SMTPMXRecord: Equatable, Sendable {
    public let preference: UInt16
    public let hostname: String
    public var isNull: Bool { hostname == "." }
    private init(_ record: TGSMTPMXRecord) {
        preference = record.preference
        hostname = withUnsafeBytes(of: record.hostname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }
    static func decode(_ data: Data) throws -> Self {
        var record = TGSMTPMXRecord()
        let code = data.withUnsafeBytes { tg_smtp_decode_mx($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &record) }
        guard code == 0 else { throw SMTPMXFailure.query(code) }
        return Self(record)
    }
    fileprivate static func result(_ record: TGSMTPMXRecord) -> Self { Self(record) }
}
public enum SMTPMXFailure: LocalizedError {
    case domain, query(Int32)
    public var errorDescription: String? {
        switch self {
        case .domain: return "Use a valid ASCII mail domain and a positive MX lookup timeout."
        case .query(let code): return code == -70002 ? "The mail-domain MX lookup timed out." : "The mail-domain MX lookup failed (\(code))."
        }
    }
}
private final class MXCancellationContext {
    let token: OperationCancellation
    init(_ token: OperationCancellation) { self.token = token }
}
private let mxCancellation: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int32 = { opaque, _, _ in
    guard let opaque else { return 1 }
    return Unmanaged<MXCancellationContext>.fromOpaque(opaque).takeUnretainedValue().token.isCancelled ? 1 : 0
}
public enum SMTPMXResolver {
    /// Read-only DNS query on a worker. The owned DNSServiceRef is deallocated
    /// on completion, error, timeout or cancellation; no credential lookup/send.
    public static func lookup(domain: String, timeoutMilliseconds: Int = 30_000,
                              cancellation: OperationCancellation? = nil) async throws -> [SMTPMXRecord] {
        let token = cancellation ?? OperationCancellation()
        return try await withTaskCancellationHandler(operation: {
            try token.check(); try Task.checkCancellation()
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard !domain.isEmpty, domain.utf8.count <= 253, !labels.isEmpty,
                  labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                  }}), (1...Int(Int32.max)).contains(timeoutMilliseconds) else { throw SMTPMXFailure.domain }
            return try await Task.detached {
                try token.check()
                let context = MXCancellationContext(token)
                var records = Array(repeating: TGSMTPMXRecord(), count: 128), count = 0
                let code = withExtendedLifetime(context) { domain.withCString { name in records.withUnsafeMutableBufferPointer {
                    tg_smtp_lookup_mx(name, timeoutMilliseconds, mxCancellation,
                        Unmanaged.passUnretained(context).toOpaque(), $0.baseAddress, $0.count, &count)
                } } }
                try token.check()
                guard code == 0 else { throw SMTPMXFailure.query(code) }
                return records.prefix(count).map(SMTPMXRecord.result)
            }.value
        }, onCancel: { token.cancel() })
    }
}


public struct SMTPRecipientDomain: Equatable, Sendable {
    public let domain: String
    public let recipients: [String]
}
public enum SMTPDirectRouteFailure: LocalizedError {
    case noMX(String), nullMX(String)
    public var errorDescription: String? {
        switch self {
        case .noMX(let domain): return "No usable MX exchange was returned for " + domain + "."
        case .nullMX(let domain): return "The domain " + domain + " publishes a null MX and does not accept mail."
        }
    }
}
/// Tracks accepted recipient domains inside a failed message, in addition to the
/// whole-message prefix in SMTPSeriesFailure. An ambiguous upload never fails over.
public struct SMTPDirectFailure: LocalizedError {
    public let domain: String
    public let acceptedDomains: [String]
    public let cause: Error
    public var hasDelivery: Bool {
        if !acceptedDomains.isEmpty { return true }
        if case SMTPFailure.transfer(_, _, true) = cause { return true }
        return false
    }
    fileprivate var retryable: Bool {
        if case SMTPFailure.transfer(_, _, let uncertain) = cause { return !uncertain }
        if case SMTPMXFailure.query = cause { return true }
        if case SMTPDirectRouteFailure.noMX = cause { return true }
        return false
    }
    public var errorDescription: String? {
        let partial = acceptedDomains.isEmpty ? "" : " Already accepted by: " + acceptedDomains.joined(separator: ", ") + "."
        return "Direct delivery to " + domain + " failed: " + cause.localizedDescription + partial
    }
}
extension PatchMailSMTP {
    typealias MXLookup = @Sendable (String, OperationCancellation) async throws -> [SMTPMXRecord]
    typealias DirectTransport = @Sendable (PatchMailMessage, PatchMailSender, SMTPServer, [String], Date, UUID, OperationCancellation, @escaping @Sendable (SMTPUploadProgress) -> Void) async throws -> SMTPReceipt
    public static func recipientDomains(for message: PatchMailMessage) throws -> [SMTPRecipientDomain] {
        var groups: [String: [String]] = [:]
        for value in message.to + message.cc {
            let recipient = try PatchMailMIME.envelopeAddress(value)
            guard let separator = recipient.lastIndex(of: "@") else { throw PatchMailMIMEFailure.mailbox }
            let domain = String(recipient[recipient.index(after: separator)...])
            groups[domain, default: []].append(recipient)
        }
        guard !groups.isEmpty else { throw SMTPFailure.recipients }
        return groups.keys.sorted().map { SMTPRecipientDomain(domain: $0, recipients: groups[$0]!) }
    }
    public static func sendDirectSeries(messages: [PatchMailMessage], sender: PatchMailSender,
                                        cancellation: OperationCancellation? = nil,
                                        onProgress: (@Sendable (SMTPSeriesProgress) -> Void)? = nil) async throws -> [SMTPReceipt] {
        try await sendDirectSeries(messages: messages, sender: sender, cancellation: cancellation ?? OperationCancellation(),
            onProgress: onProgress, resolver: { try await SMTPMXResolver.lookup(domain: $0, cancellation: $1) },
            transport: { message, sender, server, recipients, date, identifier, token, progress in
                try await send(message: message, sender: sender, server: server, date: date, identifier: identifier,
                               cancellation: token, envelopeRecipients: recipients, onProgress: progress)
            }, wait: { token in
                for _ in 0..<100 { try token.check(); try await Task.sleep(nanoseconds: 20_000_000) }
            })
    }
    static func sendDirectSeries(messages: [PatchMailMessage], sender: PatchMailSender, cancellation: OperationCancellation,
                                 onProgress: (@Sendable (SMTPSeriesProgress) -> Void)? = nil, resolver: @escaping MXLookup,
                                 transport: @escaping DirectTransport, wait: @escaping @Sendable (OperationCancellation) async throws -> Void) async throws -> [SMTPReceipt] {
        try await withTaskCancellationHandler(operation: {
            try cancellation.check(); try Task.checkCancellation()
            let stamps = messages.map { _ in (Date(), UUID()) }
            var plans: [[SMTPRecipientDomain]] = []
            // Capture/validate the entire series before the first lookup/submission.
            for (index, message) in messages.enumerated() {
                try cancellation.check()
                plans.append(try recipientDomains(for: message))
                _ = try PatchMailMIME.data(message: message, sender: sender, date: stamps[index].0, identifier: stamps[index].1)
            }
            let state = DirectSMTPState(messages: messages, sender: sender, plans: plans, stamps: stamps,
                                        token: cancellation, resolver: resolver, transport: transport)
            return try await runSeries(count: messages.count, cancellation: cancellation, onProgress: onProgress,
                                       wait: { try await wait(cancellation) }, submit: { try await state.submit($0, progress: $1) })
        }, onCancel: { cancellation.cancel() })
    }
}
private actor DirectSMTPState {
    let messages: [PatchMailMessage], sender: PatchMailSender, plans: [[SMTPRecipientDomain]], stamps: [(Date, UUID)]
    let token: OperationCancellation, resolver: PatchMailSMTP.MXLookup, transport: PatchMailSMTP.DirectTransport
    var completed: [[String]], responses: [Int]
    init(messages: [PatchMailMessage], sender: PatchMailSender, plans: [[SMTPRecipientDomain]], stamps: [(Date, UUID)],
         token: OperationCancellation, resolver: @escaping PatchMailSMTP.MXLookup, transport: @escaping PatchMailSMTP.DirectTransport) {
        self.messages = messages; self.sender = sender; self.plans = plans; self.stamps = stamps; self.token = token
        self.resolver = resolver; self.transport = transport
        completed = Array(repeating: [], count: messages.count); responses = Array(repeating: 250, count: messages.count)
    }
    func submit(_ index: Int, progress: @escaping @Sendable (SMTPUploadProgress) -> Void) async throws -> SMTPReceipt {
        var firstFailure: (domain: String, cause: Error)?
        for group in plans[index] where !completed[index].contains(group.domain) {
            do {
                try token.check(); try Task.checkCancellation()
                let records = try await resolver(group.domain, token)
                try token.check(); try Task.checkCancellation()
                let hosts = records.filter { !$0.isNull }
                if hosts.isEmpty {
                    if records.contains(where: \.isNull) { throw SMTPDirectRouteFailure.nullMX(group.domain) }
                    throw SMTPDirectRouteFailure.noMX(group.domain)
                }
                var receipt: SMTPReceipt?, lastError: Error = SMTPDirectRouteFailure.noMX(group.domain)
                for record in hosts {
                    try token.check(); try Task.checkCancellation()
                    do {
                        let server = SMTPServer(host: record.hostname, port: 25, encryption: .none)
                        try PatchMailSMTP.validate(server: server)
                        receipt = try await transport(messages[index], sender, server, group.recipients,
                                                      stamps[index].0, stamps[index].1, token, progress)
                        break
                    } catch {
                        if case SMTPFailure.transfer(_, _, let uncertain) = error {
                            if uncertain { throw error }
                            lastError = error
                        } else { throw error }
                    }
                }
                guard let receipt else { throw lastError }
                completed[index].append(group.domain); responses[index] = receipt.response
            } catch {
                // Like SendSpeedEmail, a definite failure does not prevent later
                // domains from receiving this message. Cancellation or uncertain
                // acknowledgement stops immediately instead of risking duplication.
                let failure = SMTPDirectFailure(domain: group.domain, acceptedDomains: completed[index], cause: error)
                if token.isCancelled || Task.isCancelled { throw failure }
                if case SMTPFailure.transfer(_, _, true) = error { throw failure }
                if firstFailure == nil { firstFailure = (group.domain, error) }
            }
        }
        if let failure = firstFailure {
            throw SMTPDirectFailure(domain: failure.domain, acceptedDomains: completed[index], cause: failure.cause)
        }
        return SMTPReceipt(response: responses[index])
    }
}
