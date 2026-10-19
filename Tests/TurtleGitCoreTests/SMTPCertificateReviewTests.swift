// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private actor SMTPReviewRecorder {
    private(set) var challenges: [SMTPCertificateChallenge] = []
    private(set) var beforeDelivery = true
    private(set) var token: OperationCancellation?
    private var answer: CheckedContinuation<Bool, Never>?
    func review(_ challenge: SMTPCertificateChallenge, _ token: OperationCancellation, root: URL, hold: Bool, accept: Bool) async -> Bool {
        challenges.append(challenge); self.token = token
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("state.json")),
           let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            beforeDelivery = beforeDelivery && state["auth"] as? Int == 0 && state["data"] as? Int == 0
        } else { beforeDelivery = false }
        if hold { return await withCheckedContinuation { answer = $0 } }
        return accept
    }
    func release(_ value: Bool) { let reply = answer; answer = nil; reply?.resume(returning: value) }
}

final class SMTPCertificateReviewTests: XCTestCase {
    private var sender: PatchMailSender { .init(name: "Private certificate fixture", email: "sender@example.invalid") }
    private var message: PatchMailMessage {
        .init(to: ["to@example.invalid"], cc: ["cc@example.invalid"], subject: "TLS certificate review 雪", body: Data(".\r\n..dot\r\nbody 雪\r\n".utf8), attachments: [])
    }
    @MainActor private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1500 { if await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Private SMTP fixture did not reach expected owned state"); throw SMTPFailure.configuration
    }
    @MainActor private func fixture(_ mode: String, encryption: SMTPEncryption, port: Int = 0, certificates: URL? = nil,
                                    _ body: (URL, SMTPServer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-SMTP-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        if let certificates {
            for name in ["cert.pem", "key.pem"] { try FileManager.default.copyItem(at: certificates.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
        } else {
            let configuration = "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
            try Data(configuration.utf8).write(to: root.appendingPathComponent("openssl.cnf"))
            let certificate = Process(); certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            certificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", root.appendingPathComponent("openssl.cnf").path, "-keyout", root.appendingPathComponent("key.pem").path, "-out", root.appendingPathComponent("cert.pem").path]
            certificate.standardOutput = FileHandle.nullDevice; certificate.standardError = FileHandle.nullDevice
            try certificate.run(); certificate.waitUntilExit(); XCTAssertEqual(certificate.terminationStatus, 0)
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try XCTUnwrap(Bundle.module.url(forResource: "smtp_server", withExtension: "py")).path, root.path, mode, "15", String(port)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) || !process.isRunning }
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ready.json"))) as? [String: Int])
        var server = SMTPServer(host: "localhost", port: try XCTUnwrap(ready["port"]), encryption: encryption)
        server.connectTimeoutMilliseconds = 3000; server.timeoutMilliseconds = 6000
        try await body(root, server)
    }
    @MainActor private func result(_ root: URL) async throws -> [String: Any] {
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("result.json"))) as? [String: Any])
    }
    private func der(_ root: URL) throws -> Data {
        let text = try String(contentsOf: root.appendingPathComponent("cert.pem"), encoding: .utf8)
        let value = text.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "").replacingOccurrences(of: "-----END CERTIFICATE-----", with: "").filter { !$0.isWhitespace }
        return try XCTUnwrap(Data(base64Encoded: value))
    }

    @MainActor func testSameConnectionReviewPrecedesCredentialsAndPreservesMIMEForTLSAndSTARTTLS() async throws {
        for (mode, encryption) in [("normal", SMTPEncryption.none), ("auth-required", .none), ("auth-required", .startTLS), ("implicit-auth", .tls)] {
            try await fixture(mode, encryption: encryption) { root, server in
                let recorder = SMTPReviewRecorder(), stamp = Date(timeIntervalSince1970: 1_600_000_000), identifier = UUID()
                let receipt = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                    authentication: mode == "normal" ? nil : .init(login: "fixture-user", password: "fixture-password"),
                    date: stamp, identifier: identifier, reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: true) })
                XCTAssertEqual(receipt.response, 250)
                let challenges = await recorder.challenges, before = await recorder.beforeDelivery
                XCTAssertTrue(before); XCTAssertEqual(challenges.count, mode == "normal" ? 0 : 1)
                if let challenge = challenges.first {
                    XCTAssertEqual(challenge.host, "localhost"); XCTAssertEqual(challenge.port, server.port)
                    XCTAssertEqual(challenge.certificateDER, try self.der(root)); XCTAssertFalse(challenge.validationError.isEmpty)
                }
                let state = try await self.result(root)
                XCTAssertEqual(state["accepted"] as? Int, 1); XCTAssertEqual(state["data"] as? Int, 1)
                XCTAssertEqual(state["auth"] as? Int, mode == "normal" ? 0 : 1)
                if mode == "auth-required" { XCTAssertEqual(state["ehlo"] as? Int, 2) }
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("message.eml")), try PatchMailMIME.data(message: self.message, sender: self.sender, date: stamp, identifier: identifier))
            }
        }
    }

    @MainActor func testRejectedPeerAndMissingSTARTTLSNeverReachAUTHOrDATAAndPrivateCAStillValidatesHost() async throws {
        for (mode, encryption) in [("implicit-auth", SMTPEncryption.tls), ("auth-required", .startTLS), ("no-starttls", .startTLS)] {
            try await fixture(mode, encryption: encryption) { root, server in
                let recorder = SMTPReviewRecorder()
                do {
                    if mode == "implicit-auth" {
                        _ = try await PatchMailSMTP.sendSeries(messages: [self.message], sender: self.sender, server: server,
                            authentication: .init(login: "fixture-user", password: "fixture-password"),
                            reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) })
                    } else {
                        _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                            authentication: .init(login: "fixture-user", password: "fixture-password"),
                            reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) })
                    }
                    XCTFail("Rejected/absent TLS was accepted")
                } catch SMTPFailure.transfer(_, _, let uncertain) { XCTAssertFalse(uncertain) }
                catch let failure as SMTPSeriesFailure {
                    XCTAssertEqual(failure.attempts, 1); XCTAssertTrue(failure.accepted.isEmpty)
                    guard case SMTPFailure.transfer(60, _, false) = failure.cause else { XCTFail("Certificate rejection lost definite no-retry failure"); return }
                }
                let state = try await self.result(root)
                XCTAssertEqual(state["auth"] as? Int, 0); XCTAssertEqual(state["data"] as? Int, 0)
            }
        }
        try await fixture("implicit-auth", encryption: .tls) { root, original in
            var server = original; server.trustedCertificates = root.appendingPathComponent("cert.pem")
            let recorder = SMTPReviewRecorder()
            _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                authentication: .init(login: "fixture-user", password: "fixture-password"),
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) })
            let challenges = await recorder.challenges; XCTAssertTrue(challenges.isEmpty)
        }
        try await fixture("implicit-auth", encryption: .tls) { root, original in
            var server = original; server.host = "127.0.0.1"; server.trustedCertificates = root.appendingPathComponent("cert.pem")
            let recorder = SMTPReviewRecorder()
            do {
                _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                    reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) })
                XCTFail("Private CA bypassed hostname validation")
            } catch SMTPFailure.transfer {}
            let challenges = await recorder.challenges; XCTAssertEqual(challenges.first?.host, "127.0.0.1")
            let state = try await self.result(root); XCTAssertEqual(state["data"] as? Int, 0)
        }
    }

    @MainActor func testHeldReviewPausesDeadlineAndCancellationRetainsActualCallbackUntilDrain() async throws {
        try await fixture("implicit-auth", encryption: .tls) { root, original in
            var server = original; server.connectTimeoutMilliseconds = 2000; server.timeoutMilliseconds = 2500
            let recorder = SMTPReviewRecorder(), token = OperationCancellation(), message = self.message, sender = self.sender
            var finished = false
            let operation = Task { defer { finished = true }; return try await PatchMailSMTP.send(message: message, sender: sender, server: server, cancellation: token,
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: true, accept: true) }) }
            do {
                try await self.wait { await recorder.challenges.count == 1 }
                try await Task.sleep(nanoseconds: 2_700_000_000)
                let reviewToken = await recorder.token; XCTAssertFalse(try XCTUnwrap(reviewToken).isCancelled)
                token.cancel(); try await self.wait { reviewToken?.isCancelled == true }
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(finished, "Canceled worker returned before the actual held review callback")
                let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any])
                XCTAssertEqual(state["auth"] as? Int, 0); XCTAssertEqual(state["data"] as? Int, 0)
                await recorder.release(true)
            } catch {
                token.cancel(); await recorder.release(false); _ = await operation.result; throw error
            }
            do { _ = try await operation.value; XCTFail("Late review acceptance survived cancellation") }
            catch is OperationCancellationFailure {}
        }
    }

    @MainActor func testExactAuthorityCacheRechecksChangedPeerHostAndPortAndLostFinalReplyIsUncertain() async throws {
        let cache = SMTPCertificateAcceptanceCache(), preserved = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-SMTP-cert-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: preserved) }
        var port = 0
        try await fixture("implicit-auth", encryption: .tls) { root, server in
            port = server.port
            for name in ["cert.pem", "key.pem"] { try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: preserved.appendingPathComponent(name)) }
            _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                authentication: .init(login: "fixture-user", password: "fixture-password"), reviewCertificate: { _, _ in true }, certificateApprovals: cache)
            _ = try await self.result(root)
        }
        try await fixture("implicit-auth", encryption: .tls, port: port, certificates: preserved) { root, server in
            let recorder = SMTPReviewRecorder()
            _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                authentication: .init(login: "fixture-user", password: "fixture-password"),
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) }, certificateApprovals: cache)
            let challenges = await recorder.challenges; XCTAssertTrue(challenges.isEmpty)
            _ = try await self.result(root)
        }
        // Same port/certificate, distinct configured host must ask again.
        try await fixture("implicit-auth", encryption: .tls, port: port, certificates: preserved) { root, original in
            var server = original; server.host = "127.0.0.1"
            let recorder = SMTPReviewRecorder()
            do { _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) }, certificateApprovals: cache); XCTFail("Another hostname inherited acceptance") }
            catch SMTPFailure.transfer {}
            let challenges = await recorder.challenges; XCTAssertEqual(challenges.count, 1); _ = try await self.result(root)
        }
        // Same configured host/port with a new private key/certificate also asks.
        try await fixture("implicit-auth", encryption: .tls, port: port) { root, server in
            let recorder = SMTPReviewRecorder()
            do { _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: false) }, certificateApprovals: cache); XCTFail("Changed certificate inherited acceptance") }
            catch SMTPFailure.transfer {}
            let challenges = await recorder.challenges; XCTAssertEqual(challenges.count, 1); _ = try await self.result(root)
        }
        try await fixture("implicit-drop-final", encryption: .tls, certificates: preserved) { root, server in
            let recorder = SMTPReviewRecorder()
            do { _ = try await PatchMailSMTP.sendSeries(messages: [self.message], sender: self.sender, server: server,
                authentication: .init(login: "fixture-user", password: "fixture-password"),
                reviewCertificate: { await recorder.review($0, $1, root: root, hold: false, accept: true) }, certificateApprovals: cache); XCTFail("Lost final acknowledgement accepted") }
            catch let failure as SMTPSeriesFailure {
                XCTAssertEqual(failure.attempts, 1); XCTAssertTrue(failure.accepted.isEmpty)
                guard case SMTPFailure.transfer(_, _, true) = failure.cause else { XCTFail("Lost final reply became retryable"); return }
            }
            let challenges = await recorder.challenges; XCTAssertEqual(challenges.count, 1, "Another port inherited acceptance")
            let state = try await self.result(root); XCTAssertEqual(state["data"] as? Int, 1); XCTAssertEqual(state["accepted"] as? Int, 0)
        }
    }
}
