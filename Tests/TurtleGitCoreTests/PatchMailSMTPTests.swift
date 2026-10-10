import XCTest
@testable import TurtleGitCore

final class PatchMailSMTPTests: XCTestCase {
    private let sender = PatchMailSender(name: "Fixture 雪", email: "sender@example.invalid")
    private var message: PatchMailMessage {
        get throws {
            var options = PatchMailOptions(); options.to = "To 雪 <to@example.invalid>"; options.cc = "review@example.invalid"
            let patch = try SerialPatch(file: URL(fileURLWithPath: "/fixture.patch"), bytes: Data("Subject: test\n\n.\n..leading\nbody 雪\n".utf8))
            return try XCTUnwrap(PatchMailPreparation.messages(patches: [patch], options: options).first)
        }
    }
    private func withServer(_ mode: String, encryption: SMTPEncryption = .none,
                            _ body: (URL, SMTPServer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSMTP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
        try Data(config.utf8).write(to: root.appendingPathComponent("openssl.cnf"))
        let certificate = Process(); certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        certificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", root.appendingPathComponent("openssl.cnf").path, "-keyout", root.appendingPathComponent("key.pem").path, "-out", root.appendingPathComponent("cert.pem").path]
        certificate.standardOutput = FileHandle.nullDevice; certificate.standardError = FileHandle.nullDevice
        try certificate.run(); certificate.waitUntilExit(); XCTAssertEqual(certificate.terminationStatus, 0)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try XCTUnwrap(Bundle.module.url(forResource: "smtp_server", withExtension: "py")).path, root.path, mode]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = Date().addingTimeInterval(10)
        let ready = root.appendingPathComponent("ready.json")
        while !FileManager.default.fileExists(atPath: ready.path) && process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])
        var server = SMTPServer(host: "localhost", port: try XCTUnwrap(info["port"]), encryption: encryption)
        server.connectTimeoutMilliseconds = 2000; server.timeoutMilliseconds = 5000
        try await body(root, server)
    }
    private func result(_ root: URL) async throws -> [String: Any] {
        let file = root.appendingPathComponent("result.json"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    func testAllFourPreparedModesSubmitExactMIMEWithSeparateToCCEnvelope() async throws {
        for combine in [false, true] { for attachment in [false, true] {
            var options = PatchMailOptions(); options.to = "To 雪 <to@example.invalid>"; options.cc = "review@example.invalid"; options.combine = combine; options.attachment = attachment; options.subject = "Series 雪"
            let patch = try SerialPatch(file: URL(fileURLWithPath: "/fixture 雪.patch"), bytes: Data("Subject: patch\n\n.\n..leading\nbody 雪\n".utf8))
            let second = try SerialPatch(file: URL(fileURLWithPath: "/second.patch"), bytes: Data("Subject: second\n\nsecond body\n".utf8))
            for prepared in try PatchMailPreparation.messages(patches: [patch, second], options: options) {
            try await withServer("normal") { root, server in
                let date = Date(timeIntervalSince1970: 1_600_000_000), identifier = UUID()
                let expected = try PatchMailMIME.data(message: prepared, sender: self.sender, date: date, identifier: identifier)
                let receipt = try await PatchMailSMTP.send(message: prepared, sender: self.sender, server: server, date: date, identifier: identifier)
                XCTAssertEqual(receipt.response, 250)
                let state = try await self.result(root)
                XCTAssertEqual(state["accepted"] as? Int, 1)
                let envelope = try XCTUnwrap((state["mail"] as? [String])?.first)
                XCTAssertTrue(envelope == "MAIL FROM:<sender@example.invalid>" || envelope == "MAIL FROM:<sender@example.invalid> SIZE=\(expected.count)")
                XCTAssertEqual(state["recipients"] as? [String], ["RCPT TO:<to@example.invalid>", "RCPT TO:<review@example.invalid>"])
                let bytes = try Data(contentsOf: root.appendingPathComponent("message.eml"))
                let parsed = String(decoding: bytes, as: UTF8.self)
                XCTAssertTrue(parsed.contains("\r\nCc: review@example.invalid\r\n"))
                XCTAssertEqual(bytes, expected, "Wire MIME must match the captured serializer bytes exactly")
                let parts = try XCTUnwrap(state["parts"] as? [[String: Any]])
                XCTAssertEqual(parts.count, prepared.attachments.count + 1)
                XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(parts.first?["payload"] as? String)), prepared.body)
                for (part, attachment) in zip(parts.dropFirst(), prepared.attachments) {
                    XCTAssertEqual(part["filename"] as? String, attachment.file.lastPathComponent)
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(part["payload"] as? String)), attachment.bytes)
                }
            }
            }
        } }
    }
    func testTLSAndStartTLSAuthenticateUsingPrivateCAAndVerifyHostname() async throws {
        for encryption in [SMTPEncryption.none, .startTLS, .tls] {
            try await withServer(encryption == .tls ? "implicit-auth" : "auth-required", encryption: encryption) { root, original in
                var server = original; server.trustedCertificates = root.appendingPathComponent("cert.pem")
                let receipt = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server, authentication: SMTPAuthentication(login: "fixture-user", password: "fixture-password"))
                XCTAssertEqual(receipt.response, 250)
                let state = try await self.result(root)
                XCTAssertEqual(state["tls"] as? Bool, true); XCTAssertEqual(state["auth"] as? Int, 1); XCTAssertEqual(state["accepted"] as? Int, 1)
                if encryption != .tls { XCTAssertEqual(state["ehlo"] as? Int, 2) }
            }
        }
        try await withServer("implicit-auth", encryption: .tls) { root, original in
            var server = original; server.host = "127.0.0.1"; server.trustedCertificates = root.appendingPathComponent("cert.pem")
            do { _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server); XCTFail("Hostname mismatch accepted") }
            catch SMTPFailure.transfer { }
            let state = try await self.result(root); XCTAssertEqual(state["accepted"] as? Int, 0); XCTAssertEqual(state["auth"] as? Int, 0)
        }
    }
    func testRecipientAuthTLSRejectionsAndLostFinalReplyNeverAutoRetry() async throws {
        for mode in ["reject", "auth-reject", "no-starttls", "implicit-auth", "drop-final"] {
            let encryption: SMTPEncryption = mode == "implicit-auth" ? .tls : mode == "no-starttls" ? .startTLS : .none
            try await withServer(mode, encryption: encryption) { root, server in
                do { _ = try await PatchMailSMTP.send(message: self.message, sender: self.sender, server: server,
                        authentication: mode == "auth-reject" ? SMTPAuthentication(login: "fixture-user", password: "fixture-password") : nil); XCTFail("Failure accepted: \(mode)") }
                catch SMTPFailure.transfer(_, _, let uncertain) { XCTAssertEqual(uncertain, mode == "drop-final") }
                let state = try await self.result(root)
                XCTAssertEqual(state["accepted"] as? Int, 0)
                if mode != "drop-final" { XCTAssertEqual(state["data"] as? Int, 0) }
                if mode == "no-starttls" || mode == "implicit-auth" { XCTAssertEqual(state["auth"] as? Int, 0) }
            }
        }
    }
    func testValidationPrecancelAndTaskCancellationDuringStalledGreeting() async throws {
        let token = OperationCancellation(); token.cancel()
        do { _ = try await PatchMailSMTP.send(message: message, sender: sender, server: SMTPServer(host: "localhost", port: 25, encryption: .none), cancellation: token); XCTFail("Precancel accepted") }
        catch is OperationCancellationFailure { }
        for host in ["", "localhost/path", "user@localhost", "localhost\r\nEHLO evil", "localhost?query", "host%00"] {
            do { _ = try await PatchMailSMTP.send(message: message, sender: sender, server: SMTPServer(host: host, port: 0, encryption: .none)); XCTFail("Invalid server accepted") }
            catch SMTPFailure.configuration { }
        }
        try await withServer("stall") { root, server in
            let message = try self.message, sender = self.sender
            let task = Task { try await PatchMailSMTP.send(message: message, sender: sender, server: server) }
            try await Task.sleep(nanoseconds: 150_000_000); task.cancel()
            do { _ = try await task.value; XCTFail("Stalled send not cancelled") } catch is OperationCancellationFailure { }
            let state = try await self.result(root); XCTAssertEqual(state["data"] as? Int, 0)
        }
    }
}
