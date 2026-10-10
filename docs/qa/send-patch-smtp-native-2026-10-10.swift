import Foundation
@testable import TurtleGitCore
@main struct ConfiguredSMTPVerification {
    static func main() async {
        do {
            let cancelled = OperationCancellation(); cancelled.cancel()
            do {
                _ = try await SMTPMXResolver.lookup(domain: "example.invalid", cancellation: cancelled)
                throw SMTPMXFailure.query(-70001)
            } catch is OperationCancellationFailure { }
            if ProcessInfo.processInfo.environment["TURTLEGIT_MX_DNS_PROBE"] == "1" {
                let records = try await SMTPMXResolver.lookup(domain: "gmail.com", timeoutMilliseconds: 10_000)
                guard !records.isEmpty else { throw SMTPMXFailure.query(-70001) }
                print("Actual Debug Core/SMTP framework read-only system MX query returned \(records.count) records; no direct SMTP submission.")
            }
            guard CommandLine.arguments.count == 3, let port = Int(CommandLine.arguments[2]) else { throw SMTPFailure.configuration }
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            var raw = Data("Subject: First 雪\n\nbinary\n".utf8); raw.append(contentsOf: [0, 255, 128])
            let first = try SerialPatch(file: root.appendingPathComponent("first 雪.patch"), bytes: raw)
            let second = try SerialPatch(file: root.appendingPathComponent("second.patch"), bytes: Data("Subject: Second\n\nsecond\n".utf8))
            var options = PatchMailOptions(); options.combine = true; options.attachment = true
            options.to = "Unavailable <to@a.invalid>;To 雪 <to@example.invalid>"; options.cc = "review@example.invalid"; options.subject = "SDK series"
            let message = try PatchMailPreparation.messages(patches: [first, second], options: options)[0]
            let sender = PatchMailSender(name: "SDK Fixture", email: "sender@example.invalid")
            do {
                _ = try await PatchMailSMTP.sendDirectSeries(messages: [message], sender: sender, cancellation: OperationCancellation(),
                resolver: { domain, _ in
                    if domain == "a.invalid" { return [try SMTPMXRecord.decode(Data([0, 0, 0]))] }
                    guard domain == "example.invalid" else { throw SMTPMXFailure.domain }
                    return [try SMTPMXRecord.decode(Data([0, 0, 9] + Array("localhost".utf8) + [0]))]
                }, transport: { captured, sender, mxServer, envelope, stamp, identity, token, progress in
                    guard mxServer.port == 25, mxServer.host == "localhost" else { throw SMTPFailure.configuration }
                    var loopback = mxServer; loopback.port = port
                    loopback.connectTimeoutMilliseconds = 2000; loopback.timeoutMilliseconds = 5000
                    try PatchMailMIME.data(message: captured, sender: sender, date: stamp, identifier: identity).write(to: root.appendingPathComponent("expected.eml"))
                    return try await PatchMailSMTP.send(message: captured, sender: sender, server: loopback, date: stamp, identifier: identity,
                        cancellation: token, envelopeRecipients: envelope, onProgress: progress)
                }, wait: { _ in })
                throw SMTPFailure.configuration
            } catch let failure as SMTPSeriesFailure {
                guard failure.attempts == 1, failure.accepted.isEmpty,
                      let direct = failure.cause as? SMTPDirectFailure,
                      direct.domain == "a.invalid", direct.acceptedDomains == ["example.invalid"], direct.hasDelivery,
                      case SMTPDirectRouteFailure.nullMX("a.invalid") = direct.cause else { throw failure }
            }
            print("Actual Debug direct queue continued after an earlier null MX, submitted the later domain through private loopback SMTP with full To/CC/binary attachments, and reported its acceptance in the terminal failure. No app window, Keychain or public delivery.")
        } catch { fputs("Configured SMTP framework QA failed: \(error)\n", stderr); exit(1) }
    }
}
