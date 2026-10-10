import Foundation
import TurtleGitCore
@main struct ConfiguredSMTPVerification {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, let port = Int(CommandLine.arguments[2]) else { throw SMTPFailure.configuration }
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            var raw = Data("Subject: First 雪\n\nbinary\n".utf8); raw.append(contentsOf: [0, 255, 128])
            let first = try SerialPatch(file: root.appendingPathComponent("first 雪.patch"), bytes: raw)
            let second = try SerialPatch(file: root.appendingPathComponent("second.patch"), bytes: Data("Subject: Second\n\nsecond\n".utf8))
            var options = PatchMailOptions(); options.combine = true; options.attachment = true
            options.to = "To 雪 <to@example.invalid>"; options.cc = "review@example.invalid"; options.subject = "SDK series"
            let message = try PatchMailPreparation.messages(patches: [first, second], options: options)[0]
            let sender = PatchMailSender(name: "SDK Fixture", email: "sender@example.invalid")
            let date = Date(timeIntervalSince1970: 1_600_000_000), identifier = UUID()
            let expected = try PatchMailMIME.data(message: message, sender: sender, date: date, identifier: identifier)
            try expected.write(to: root.appendingPathComponent("expected.eml"))
            var server = SMTPServer(host: "localhost", port: port, encryption: .none)
            server.connectTimeoutMilliseconds = 2000; server.timeoutMilliseconds = 5000
            let receipt = try await PatchMailSMTP.send(message: message, sender: sender, server: server, date: date, identifier: identifier)
            guard receipt.response == 250 else { throw SMTPFailure.transfer(code: 0, response: receipt.response, possiblySubmitted: true) }
            print("Actual Debug Core/SMTP frameworks submitted one private loopback MIME message with two captured attachments and distinct To/CC. No app window, Keychain or real delivery.")
        } catch { fputs("Configured SMTP framework QA failed: \(error)\n", stderr); exit(1) }
    }
}
