// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import Security

public struct SMTPCertificateChallenge: Sendable {
    public let host: String
    public let port: Int
    public let certificateDER: Data
    public let validationError: String
    public let validationErrorCode: Int
    public init(host: String, port: Int, certificateDER: Data, validationError: String, validationErrorCode: Int) {
        self.host = host; self.port = port; self.certificateDER = certificateDER
        self.validationError = validationError; self.validationErrorCode = validationErrorCode
    }
}
public typealias SMTPCertificateReview = @Sendable (SMTPCertificateChallenge, OperationCancellation) async -> Bool

/// An explicitly owned workflow cache. No Keychain or global trust is changed.
/// Every connection still evaluates its actual peer before an exact exception.
public final class SMTPCertificateAcceptanceCache: @unchecked Sendable {
    private struct Key: Hashable { let host: GitReferenceName; let port: Int; let der: Data }
    private let lock = NSLock()
    private var entries: [Key] = []
    public init() {}
    fileprivate func contains(_ challenge: SMTPCertificateChallenge) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains(Key(host: GitReferenceName(challenge.host), port: challenge.port, der: challenge.certificateDER))
    }
    fileprivate func accept(_ challenge: SMTPCertificateChallenge) {
        guard challenge.certificateDER.count <= 1_048_576 else { return }
        lock.lock(); defer { lock.unlock() }
        let key = Key(host: GitReferenceName(challenge.host), port: challenge.port, der: challenge.certificateDER)
        entries.removeAll { $0 == key }; entries.append(key)
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
    }
}

/// Network.framework supplies TLS 1.2/1.3 and its actual connection's SecTrust.
/// STARTTLS is installed above a not-yet-ready public protocol framer, never on
/// a separate probe connection. The synchronous worker owns all callbacks until
/// the connection and any interactive review have actually drained.
enum SMTPCertificateTransport {
    static func send(payload: Data, sender: String, recipients: [String], server: SMTPServer,
                     authentication: SMTPAuthentication?, token: OperationCancellation,
                     progress: (@Sendable (SMTPUploadProgress) -> Void)?, review: @escaping SMTPCertificateReview,
                     approvals: SMTPCertificateAcceptanceCache?) throws -> SMTPReceipt {
        let state = SMTPNetworkState(server: server, token: token, review: review, approvals: approvals)
        let tls = state.tlsOptions()
        let parameters = NWParameters(tls: server.encryption == .tls ? tls : nil, tcp: NWProtocolTCP.Options())
        if server.encryption != .tls {
            let framer = NWProtocolFramer.Options(definition: SMTPStartTLSFramer.definition)
            framer["session"] = state; parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: NWEndpoint.Port(rawValue: UInt16(server.port))!, using: parameters)
        state.attach(connection)
        defer { state.drain() }
        try state.awaitReady()
        if server.encryption == .tls { try state.expect(220) }
        if server.encryption == .tls || state.upgraded {
            try state.write(Data("EHLO localhost\r\n".utf8)); state.capabilities = try state.reply(expected: [250, 500, 502, 504])
            if state.response != 250 { try state.command("HELO localhost", expected: [250]); state.capabilities = [] }
        }
        if let authentication {
            let loginSupported = state.capabilities.contains { line in
                let fields = line.uppercased().split(whereSeparator: { $0 == " " || $0 == "=" })
                return fields.first == "AUTH" && fields.dropFirst().contains("LOGIN")
            }
            guard loginSupported else { throw state.failure(67) }
            try state.command("AUTH LOGIN", expected: [334])
            try state.command(Data(authentication.login.utf8).base64EncodedString(), expected: [334])
            try state.command(Data(authentication.password.utf8).base64EncodedString(), expected: [235])
        }
        try state.command("MAIL FROM:<" + sender + ">", expected: [250])
        for recipient in recipients { try state.command("RCPT TO:<" + recipient + ">", expected: [250, 251]) }
        try state.command("DATA", expected: [354])
        var buffer = Data(), lineStart = true
        buffer.reserveCapacity(65_538)
        for (index, byte) in payload.enumerated() {
            if lineStart && byte == 46 { buffer.append(46) }
            buffer.append(byte); lineStart = byte == 10
            if buffer.count >= 65_536 || index == payload.count - 1 {
                // As with curl's read callback, handing off the entire MIME
                // payload makes a lost final reply potentially submitted.
                if index == payload.count - 1 { state.possiblySubmitted = true }
                try state.write(buffer); buffer.removeAll(keepingCapacity: true)
                progress?(SMTPUploadProgress(uploaded: UInt64(index + 1), total: UInt64(payload.count)))
            }
        }
        try state.write(Data((payload.suffix(2) == Data([13, 10]) ? ".\r\n" : "\r\n.\r\n").utf8))
        try state.expect(250)
        // Acceptance is final. A failed QUIT cannot turn it into a retry.
        let response = state.response
        try? state.command("QUIT", expected: [221])
        return SMTPReceipt(response: response)
    }
}

private final class SMTPNetworkState: @unchecked Sendable {
    let server: SMTPServer, token: OperationCancellation
    let review: SMTPCertificateReview
    let approvals: SMTPCertificateAcceptanceCache?
    let queue = DispatchQueue(label: "TurtleGit.SMTP.connection")
    private let lock = NSLock(), changed = DispatchSemaphore(value: 0), reviews = DispatchGroup()
    private var connection: NWConnection?
    private var ready = false, ended = false, failed = false, trustRejected = false
    private var reviewing = false, reviewStart: UInt64 = 0, reviewElapsed: UInt64 = 0
    private let reviewToken = OperationCancellation()
    private let started = DispatchTime.now().uptimeNanoseconds
    var upgraded = false, capabilities: [String] = [], response = 0, possiblySubmitted = false
    private var input = Data()
    init(server: SMTPServer, token: OperationCancellation, review: @escaping SMTPCertificateReview, approvals: SMTPCertificateAcceptanceCache?) {
        self.server = server; self.token = token; self.review = review; self.approvals = approvals
    }
    func failure(_ code: Int32) -> SMTPFailure { .transfer(code: code, response: response, possiblySubmitted: possiblySubmitted) }
    func attach(_ value: NWConnection) {
        connection = value
        value.stateUpdateHandler = { [self] state in
            lock.lock()
            switch state {
            case .ready: ready = true
            case .failed: failed = true; reviewToken.cancel()
            case .cancelled: ended = true; reviewToken.cancel()
            default: break
            }
            lock.unlock(); changed.signal()
        }
        value.start(queue: queue)
    }
    private func check(connecting: Bool = false) throws {
        try token.check()
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let paused = reviewElapsed + (reviewing ? now - reviewStart : 0)
        let elapsed = now - started - min(now - started, paused), failed = self.failed, trustRejected = self.trustRejected
        lock.unlock()
        // A rejected verify completion may leave Network.framework waiting
        // rather than emitting .failed promptly. The explicit decision itself
        // is terminal; don't turn it into a timeout and retry the rejected peer.
        guard !trustRejected else { throw failure(60) }
        guard !failed else { throw failure(56) }
        guard elapsed / 1_000_000 < UInt64(server.timeoutMilliseconds),
              !connecting || elapsed / 1_000_000 < UInt64(server.connectTimeoutMilliseconds) else { throw failure(28) }
    }
    func awaitReady() throws {
        while true {
            try check(connecting: true)
            lock.lock(); let ready = self.ready, ended = self.ended; lock.unlock()
            if ready { return }; if ended { throw failure(7) }
            _ = changed.wait(timeout: .now() + 0.025)
        }
    }
    func drain() {
        reviewToken.cancel(); connection?.cancel()
        while true {
            lock.lock(); let done = ended; lock.unlock()
            if done { break }; _ = changed.wait(timeout: .now() + 0.025)
        }
        queue.sync {}
        // A UI may be detaching an inspector/export after cancellation. Retain
        // its callback/worker ownership; cancellation is not fabricated drain.
        reviews.wait()
        connection?.stateUpdateHandler = nil; connection = nil
    }
    func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        server.host.withCString { sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, $0) }
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { [self] _, peer, complete in
            reviews.enter()
            Task.detached { [self] in
                var accept = false
                defer {
                    if !accept, !token.isCancelled, !reviewToken.isCancelled { rejectPeer() }
                    complete(accept); reviews.leave()
                }
                guard !token.isCancelled, !reviewToken.isCancelled else { return }
                let trust = sec_trust_copy_ref(peer).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, server.host as CFString))
                // Don't perform implicit AIA/OCSP network requests outside this
                // owned connection. Missing chain data reaches explicit review.
                SecTrustSetNetworkFetchAllowed(trust, false)
                if let file = server.trustedCertificates {
                    guard let anchors = try? Self.anchors(file), !anchors.isEmpty,
                          SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                          SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else { return }
                }
                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) { accept = !token.isCancelled && !reviewToken.isCancelled; return }
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return }
                let der = SecCertificateCopyData(leaf) as Data
                guard !der.isEmpty, der.count <= 1_048_576 else { return }
                let challenge = SMTPCertificateChallenge(host: server.host, port: server.port, certificateDER: der,
                    validationError: error.map { CFErrorCopyDescription($0) as String } ?? "The SMTP server certificate could not be validated.",
                    validationErrorCode: error.map { CFErrorGetCode($0) } ?? Int(errSecNotTrusted))
                guard !token.isCancelled, !reviewToken.isCancelled else { return }
                if approvals?.contains(challenge) == true { accept = true; return }
                beginReview()
                let answer = await review(challenge, reviewToken)
                endReview()
                guard answer, !token.isCancelled, !reviewToken.isCancelled else { return }
                approvals?.accept(challenge); accept = true
            }
        }, queue)
        return options
    }
    private func rejectPeer() {
        lock.lock(); trustRejected = true; lock.unlock(); changed.signal()
    }
    private func beginReview() {
        lock.lock(); reviewing = true; reviewStart = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }
    private func endReview() {
        lock.lock(); reviewElapsed += DispatchTime.now().uptimeNanoseconds - reviewStart; reviewing = false; lock.unlock()
    }
    private static func anchors(_ file: URL) throws -> [SecCertificate] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= 16_777_216 else { return [] }
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) { return [certificate] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let sections = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        var certificates: [SecCertificate] = []
        for section in sections {
            guard certificates.count < 256, let end = section.range(of: "-----END CERTIFICATE-----"),
                  let der = Data(base64Encoded: section[..<end.lowerBound].filter { !$0.isWhitespace }),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return [] }
            certificates.append(certificate)
        }
        return certificates
    }
    func write(_ data: Data) throws {
        try check()
        let result = SMTPNetworkResult<Void>()
        connection!.send(content: data, completion: .contentProcessed { error in result.complete(error == nil ? .success(()) : .failure(error!)) })
        try wait(result)
    }
    private func wait<T>(_ result: SMTPNetworkResult<T>) throws -> T {
        while true {
            try check()
            if let value = result.value() {
                do { return try value.get() } catch { throw failure(56) }
            }
            _ = changed.wait(timeout: .now() + 0.01)
        }
    }
    private func line() throws -> String {
        while true {
            if let end = input.firstIndex(of: 10) {
                guard end < 4096, end > input.startIndex, input[input.index(before: end)] == 13,
                      let line = String(data: input[..<input.index(before: end)], encoding: .ascii) else { throw failure(8) }
                input.removeSubrange(...end); return line
            }
            guard input.count < 4096 else { throw failure(8) }
            let result = SMTPNetworkResult<Data>()
            connection!.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let error { result.complete(.failure(error)) }
                else if let data, !data.isEmpty { result.complete(.success(data)) }
                else { result.complete(.failure(SMTPFailure.transfer(code: 56, response: 0, possiblySubmitted: false))) }
            }
            input.append(try wait(result))
        }
    }
    func reply(expected: [Int]) throws -> [String] {
        var code: Int?, lines: [String] = []
        repeat {
            let line = try line(), bytes = Array(line.utf8)
            guard lines.count < 100, bytes.count >= 3, bytes.prefix(3).allSatisfy({ (48...57).contains($0) }),
                  let value = Int(String(decoding: bytes.prefix(3), as: UTF8.self)), code == nil || code == value,
                  bytes.count == 3 || bytes[3] == 32 || bytes[3] == 45 else { throw failure(8) }
            code = value; response = value
            lines.append(bytes.count > 4 ? String(decoding: bytes.dropFirst(4), as: UTF8.self) : "")
            if bytes.count == 3 || bytes[3] != 45 { break }
        } while true
        guard expected.contains(response) else { throw failure(response == 535 ? 67 : 8) }
        return lines
    }
    func expect(_ value: Int) throws { _ = try reply(expected: [value]) }
    func command(_ command: String, expected: [Int]) throws {
        try write(Data((command + "\r\n").utf8)); _ = try reply(expected: expected)
    }
}

private final class SMTPNetworkResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func complete(_ value: Result<Value, Error>) { lock.lock(); result = value; lock.unlock() }
    func value() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Only the unauthenticated bootstrap is in the framer. It never sees a login,
/// message or recipient. TLS is added before readiness on the existing socket.
private final class SMTPStartTLSFramer: NWProtocolFramerImplementation {
    static let label = "TurtleGit SMTP STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: SMTPStartTLSFramer.self)
    private let state: SMTPNetworkState?
    private var phase = 0, lines: [String] = [], replyCode: Int?
    required init(framer: NWProtocolFramer.Instance) { state = framer.options["session"] as? SMTPNetworkState }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard let state else { framer.markFailed(error: .posix(.EINVAL)); return 0 }
        if phase == 3 { framer.passThroughInput(); return 0 }
        while phase != 3 {
            var line: String?, invalid = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 4096) { buffer, complete in
                guard let buffer else { invalid = complete; return 0 }
                let bytes = buffer.bindMemory(to: UInt8.self)
                guard let end = bytes.firstIndex(of: 10) else { invalid = bytes.count >= 4096 || complete; return 0 }
                guard end > 0, bytes[end - 1] == 13 else { invalid = true; return end + 1 }
                line = String(bytes: bytes[..<(end - 1)], encoding: .ascii); invalid = line == nil; return end + 1
            }
            if invalid { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            guard parsed, let line else { return 1 }
            let bytes = Array(line.utf8)
            guard lines.count < 100, bytes.count >= 3, bytes.prefix(3).allSatisfy({ (48...57).contains($0) }), let code = Int(String(decoding: bytes.prefix(3), as: UTF8.self)),
                  replyCode == nil || replyCode == code, bytes.count == 3 || bytes[3] == 32 || bytes[3] == 45 else { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            replyCode = code; lines.append(bytes.count > 4 ? String(decoding: bytes.dropFirst(4), as: UTF8.self) : "")
            if bytes.count > 3 && bytes[3] == 45 { continue }
            if phase == 1 && [500, 502, 504].contains(code) {
                replyCode = nil; lines.removeAll(); phase = 4
                framer.writeOutput(data: Data("HELO localhost\r\n".utf8)); continue
            }
            guard code == (phase == 1 || phase == 4 ? 250 : 220) else { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            replyCode = nil
            if phase == 0 {
                lines.removeAll(); phase = 1; framer.writeOutput(data: Data("EHLO localhost\r\n".utf8))
            } else if phase == 1 || phase == 4 {
                state.capabilities = phase == 4 ? [] : lines; lines.removeAll()
                if state.capabilities.contains(where: { $0.uppercased() == "STARTTLS" }) {
                    phase = 2; framer.writeOutput(data: Data("STARTTLS\r\n".utf8))
                } else if state.server.encryption == .startTLS { framer.markFailed(error: .posix(.EPROTONOSUPPORT)); return 0 }
                else { phase = 3; framer.passThroughInput(); framer.passThroughOutput(); framer.markReady() }
            } else {
                do { try framer.prependApplicationProtocol(options: state.tlsOptions()) }
                catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
                state.upgraded = true; phase = 3; framer.passThroughInput(); framer.passThroughOutput(); framer.markReady()
            }
        }
        return 0
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        do { try framer.writeOutputNoCopy(length: messageLength) } catch { framer.markFailed(error: .posix(.EIO)) }
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
