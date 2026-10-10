import XCTest
@testable import TurtleGitCore

private func directMX(_ name: String) throws -> SMTPMXRecord {
    var bytes = Data([0, 0])
    for label in name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
    bytes.append(0); return try SMTPMXRecord.decode(bytes)
}
private actor DirectProbe {
    enum Mode { case retry, uncertain, cancel, nullMX, noMX }
    let mode: Mode, original: PatchMailMessage
    var hosts: [String] = [], ids: [UUID] = [], recipients: [[String]] = [], lookups: [String] = []
    var zAttempts = 0
    init(_ mode: Mode, _ original: PatchMailMessage) { self.mode = mode; self.original = original }
    func resolve(_ domain: String) throws -> [SMTPMXRecord] {
        lookups.append(domain)
        if domain == "z.invalid" {
            if mode == .nullMX { return [try SMTPMXRecord.decode(Data([0, 0, 0]))] }
            if mode == .noMX { return [] }
            return [try directMX("z-mx1"), try directMX("z-mx2")]
        }
        return [try directMX("a-mx")]
    }
    func submit(_ message: PatchMailMessage, _ server: SMTPServer, _ envelope: [String], _ identifier: UUID, _ token: OperationCancellation) throws -> SMTPReceipt {
        XCTAssertEqual(message, original); XCTAssertEqual(server.port, 25); XCTAssertEqual(server.encryption, .none)
        hosts.append(server.host); recipients.append(envelope); ids.append(identifier)
        if server.host.hasPrefix("z-") {
            zAttempts += 1
            if mode == .uncertain { throw SMTPFailure.transfer(code: 56, response: 0, possiblySubmitted: true) }
            if mode == .retry && zAttempts <= 2 { throw SMTPFailure.transfer(code: 7, response: 0, possiblySubmitted: false) }
        }
        if mode == .cancel { token.cancel() }
        return SMTPReceipt(response: 250)
    }
    func snapshot() -> ([String], [UUID], [[String]], [String]) { (hosts, ids, recipients, lookups) }
}
final class PatchMailDirectTests: XCTestCase {
    let sender = PatchMailSender(name: "Direct 雪", email: "sender@example.invalid")
    func message() throws -> PatchMailMessage {
        var options = PatchMailOptions(); options.to = "Zulu <z@z.invalid>;Alpha <a@a.invalid>"; options.cc = "copy@a.invalid"
        let patch = try SerialPatch(file: URL(fileURLWithPath: "/direct.patch"), bytes: Data("Subject: Direct\n\nbody 雪\n".utf8))
        return try XCTUnwrap(PatchMailPreparation.messages(patches: [patch], options: options).first)
    }
    private func send(_ message: PatchMailMessage, _ probe: DirectProbe, token: OperationCancellation = OperationCancellation()) async throws -> [SMTPReceipt] {
        try await PatchMailSMTP.sendDirectSeries(messages: [message], sender: sender, cancellation: token,
            resolver: { domain, _ in try await probe.resolve(domain) },
            transport: { message, _, server, recipients, _, identifier, token, _ in
                try await probe.submit(message, server, recipients, identifier, token)
            }, wait: { try $0.check() })
    }
    func testSourceDomainOrderAndToCCEnvelopeGrouping() throws {
        let groups = try PatchMailSMTP.recipientDomains(for: message())
        XCTAssertEqual(groups.map(\.domain), ["a.invalid", "z.invalid"])
        XCTAssertEqual(groups.map(\.recipients), [["a@a.invalid", "copy@a.invalid"], ["z@z.invalid"]])
        let quoted = PatchMailMessage(to: ["\"a@b\"@z.invalid"], cc: [], subject: "quoted", body: Data(), attachments: [])
        XCTAssertEqual(try PatchMailSMTP.recipientDomains(for: quoted).first?.domain, "z.invalid")
    }
    func testFailoverAndRetryResumeOnlyUnacceptedDomainsWithStableMessageIdentity() async throws {
        let message = try message(), probe = DirectProbe(.retry, message)
        let result = try await send(message, probe)
        XCTAssertEqual(result.count, 1)
        let state = await probe.snapshot()
        XCTAssertEqual(state.0, ["a-mx", "z-mx1", "z-mx2", "z-mx1"])
        XCTAssertEqual(state.3, ["a.invalid", "z.invalid", "z.invalid"])
        XCTAssertEqual(Set(state.1).count, 1)
        XCTAssertEqual(state.2, [["a@a.invalid", "copy@a.invalid"], ["z@z.invalid"], ["z@z.invalid"], ["z@z.invalid"]])
    }
    func testUncertaintyCancellationAndNullMXKeepPartialDomainAcceptance() async throws {
        for mode in [DirectProbe.Mode.uncertain, .cancel, .nullMX, .noMX] {
            let message = try message(), probe = DirectProbe(mode, message), token = OperationCancellation()
            do { _ = try await send(message, probe, token: token); XCTFail("Failure accepted") }
            catch let series as SMTPSeriesFailure {
                XCTAssertEqual(series.index, 0); XCTAssertEqual(series.accepted.count, 0)
                XCTAssertEqual(series.attempts, mode == .noMX ? 3 : 1)
                let failure = try XCTUnwrap(series.cause as? SMTPDirectFailure)
                XCTAssertEqual(failure.domain, "z.invalid"); XCTAssertEqual(failure.acceptedDomains, ["a.invalid"])
                XCTAssertTrue(failure.hasDelivery)
            }
            let state = await probe.snapshot()
            XCTAssertEqual(state.0, mode == .uncertain ? ["a-mx", "z-mx1"] : ["a-mx"])
            if mode == .noMX { XCTAssertEqual(state.3.filter { $0 == "z.invalid" }.count, 3) }
        }
    }
    func testInvalidLaterMessagePreventsAllLookupsAndSubmission() async throws {
        let message = try message(), probe = DirectProbe(.retry, message)
        let invalid = PatchMailMessage(to: message.to, cc: message.cc, subject: "bad\r\nheader", body: message.body, attachments: [])
        do {
            _ = try await PatchMailSMTP.sendDirectSeries(messages: [message, invalid], sender: sender, cancellation: OperationCancellation(),
                resolver: { domain, _ in try await probe.resolve(domain) },
                transport: { message, _, server, recipients, _, identifier, token, _ in try await probe.submit(message, server, recipients, identifier, token) }, wait: { _ in })
            XCTFail("Invalid later message accepted")
        } catch is PatchMailMIMEFailure { }
        let state = await probe.snapshot(); XCTAssertTrue(state.0.isEmpty); XCTAssertTrue(state.3.isEmpty)
    }
}
