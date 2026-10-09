import AppKit
import TurtleGitCore

@main struct SSHKeyPassphraseReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            var responses: [String?] = []
            let accepted = SSHKeyPassphraseWindowController(keyName:"fixture-key") { responses.append($0) }; defer { accepted.close() }
            try require(accepted.passphrase.cell is NSSecureTextFieldCell && accepted.window?.initialFirstResponder === accepted.passphrase && accepted.accept.keyEquivalent == "\r" && accepted.cancel.keyEquivalent == "\u{1b}", "Secure field/default keyboard configuration")
            accepted.passphrase.stringValue = "fixture response"; accepted.submit(); accepted.submit(); accepted.abort()
            try require(responses.count == 1 && responses[0] == "fixture response" && accepted.finished && accepted.passphrase.stringValue.isEmpty && !accepted.accept.isEnabled, "Accepted response not one-shot/cleared")
            let cancelled = SSHKeyPassphraseWindowController(keyName:"fixture-key") { responses.append($0) }; defer { cancelled.close() }
            cancelled.passphrase.stringValue = "discarded fixture"; cancelled.abort(); cancelled.submit()
            try require(responses.count == 2 && responses[1] == nil && cancelled.passphrase.stringValue.isEmpty, "Cancel returned a credential")
            let forced = SSHKeyPassphraseWindowController(keyName:"fixture-key") { responses.append($0) }; defer { forced.close() }
            forced.passphrase.stringValue = "late fixture"; forced.close(); forced.submit()
            try require(responses.count == 3 && responses[2] == nil && forced.finished && forced.passphrase.stringValue.isEmpty, "Forced close/late OK escaped fence")
            try require(!NSApplication.shared.windows.contains { $0.isVisible }, "Receiver displayed a window")
            print("PASS hidden native SSH secure field, Return/Escape configuration, one-shot OK/Cancel, forced close and field clearing")
        } catch { fputs("SSH passphrase native check failed: \(error)\n",stderr); exit(1) }
    }
}
