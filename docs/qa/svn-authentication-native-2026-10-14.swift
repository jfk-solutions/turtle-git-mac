import AppKit
import TurtleGitCore

@main struct SVNAuthenticationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func main() async { do { try await verify() } catch { fputs("SVN authentication native failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let realm = "<https://fixture.invalid> private realm", request = GitSVNAuthenticationPrompt(kind: .credentials, realm: realm, username: "default", maySave: true)
        var replies: [GitSVNAuthenticationResponse?] = []
        let credentials = GitSVNPromptWindowController(prompt: request) { replies.append($0) }; defer { credentials.close() }
        credentials.window?.contentView?.layoutSubtreeIfNeeded(); credentials.username.stringValue = "fixture-name"; credentials.password.stringValue = "fixture-response"; credentials.save.state = .on; credentials.submit(); credentials.submit()
        try require(replies.count == 1 && replies[0]?.username == "fixture-name" && replies[0]?.password == "fixture-response" && replies[0]?.save == true && credentials.password.stringValue.isEmpty, "Combined credentials/one-shot/secret clearing failed")
        let trust = GitSVNAuthenticationPrompt(kind: .trust, realm: realm, maySave: true, failures: 0x40000008, hostname: "fixture.invalid", validFrom: "from", validUntil: "until", issuer: "fixture issuer", fingerprint: "AA:BB")
        var decisions: [GitSVNAuthenticationResponse.Decision] = []
        for action in [0,1,2] {
            let window = GitSVNPromptWindowController(prompt: trust) { if let d = $0?.decision { decisions.append(d) } }; defer { window.close() }; window.window?.contentView?.layoutSubtreeIfNeeded()
            try require((window.window?.defaultButtonCell?.title ?? "") == "Reject", "Certificate default was affirmative")
            if action == 0 { window.abort() } else if action == 1 { window.trustTemporary() } else { window.trustPermanent() }
        }
        try require(decisions == [.reject,.temporary,.permanent], "Certificate actions differ")
        let noSave = GitSVNAuthenticationPrompt(kind: .trust, realm: realm, maySave: false, failures: 8, hostname: "fixture.invalid", issuer: "issuer", fingerprint: "AA")
        var denied = 0; let limited = GitSVNPromptWindowController(prompt: noSave) { _ in denied += 1 }; limited.trustPermanent(); try require(denied == 0, "Permanent trust bypassed callback policy"); limited.close(); try require(denied == 1, "Forced trust close did not reject once")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), folder = root.appendingPathComponent("certificates"), file = root.appendingPathComponent("fixture.p12"), bytes = Data([0,255,1,2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try bytes.write(to: file)
        var copied: String?; let certificate = GitSVNPromptWindowController(prompt: GitSVNAuthenticationPrompt(kind: .clientCertificate, realm: realm)) { copied = $0?.file }; certificate.certificateDirectory = folder; certificate.acceptCertificate(file)
        guard let copied else { throw Failure(description: "Certificate selection callback absent") }
        try require(Data(contentsOf: URL(fileURLWithPath: copied)) == bytes && Data(contentsOf: file) == bytes && certificate.finished, "Certificate copy lost source/owned data")
        var cancelled = 0; let password = GitSVNPromptWindowController(prompt: GitSVNAuthenticationPrompt(kind: .secret, realm: realm)) { answer in if answer == nil { cancelled += 1 } }; password.password.stringValue = "not published"; password.close(); try require(cancelled == 1 && password.password.stringValue.isEmpty, "Password forced close leaked response or secret field")
        print("PASS native SVN prompts: combined/secure fields and save flag, once-only response and secret clearing, default Reject/temporary/permanent policy, forced rejection, private certificate copy/source preservation and password cancellation. Owned windows closed.")
    }
}
