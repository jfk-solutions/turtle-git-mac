import AppKit
import TurtleGitCore

@main struct GitAskpassVerification {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var answers: [String?] = []
        let secret = GitAskpassWindowController(prompt: GitAskpassPrompt("Password for 'https://fixture.invalid': ")) { answers.append($0) }
        defer { secret.close() }
        precondition(secret.field is NSSecureTextField && secret.window?.initialFirstResponder === secret.field)
        precondition(secret.accept.keyEquivalent == "\r" && secret.cancel.keyEquivalent == "\u{1b}")
        secret.field.stringValue = "fixture-only response"; secret.submit(); secret.submit(); secret.abort()
        precondition(answers.count == 1 && answers[0] == "fixture-only response" && secret.field.stringValue.isEmpty && !secret.field.isEnabled)
        let name = GitAskpassWindowController(prompt: GitAskpassPrompt("Username for 'https://fixture.invalid': ")) { answers.append($0) }
        defer { name.close() }
        precondition(!(name.field is NSSecureTextField))
        name.field.stringValue = "fixture-user"; name.abort(); name.submit()
        precondition(answers.count == 2 && answers[1] == nil && name.field.stringValue.isEmpty)
        let forced = GitAskpassWindowController(prompt: GitAskpassPrompt("Token: ")) { answers.append($0) }
        defer { forced.close() }
        forced.field.stringValue = "discarded"; forced.close(); forced.submit()
        precondition(answers.count == 3 && answers[2] == nil && forced.field.stringValue.isEmpty)
        let invalid = GitAskpassWindowController(prompt: GitAskpassPrompt("Password: ")) { answers.append($0) }
        defer { invalid.close() }
        invalid.field.stringValue = "invalid\nresponse"; invalid.submit()
        precondition(!invalid.finished && answers.count == 3); invalid.abort()
        var hostAnswers: [String?] = []
        let host = GitAskpassWindowController(prompt: GitAskpassPrompt("Are you sure you want to continue connecting (yes/no/[fingerprint])?", ssh: true)) { hostAnswers.append($0) }
        defer { host.close() }
        precondition(!(host.field is NSSecureTextField) && host.accept.title == "Continue")
        // AppKit assigns Return to the default button; the window handles Escape independently.
        precondition(host.accept.keyEquivalent.isEmpty && host.window?.defaultButtonCell === host.cancel.cell && host.window?.initialFirstResponder === host.cancel)
        host.submit(); host.abort(); precondition(hostAnswers.count == 1 && hostAnswers[0] == "yes")
        let fingerprint = GitAskpassWindowController(prompt: GitAskpassPrompt("Please type 'yes', 'no' or the fingerprint: ", ssh: true)) { hostAnswers.append($0) }
        defer { fingerprint.close() }
        fingerprint.field.stringValue = "SHA256:fixture"; fingerprint.submit()
        precondition(hostAnswers.last! == "SHA256:fixture")
        let permission = GitAskpassWindowController(prompt: GitAskpassPrompt("Allow key use?", ssh: true, hint: "confirm")) { hostAnswers.append($0) }
        defer { permission.close() }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: permission.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        precondition(permission.window!.performKeyEquivalent(with: escape) && permission.finished && hostAnswers.last! == nil)
        let notice = GitAskpassWindowController(prompt: GitAskpassPrompt("Touch your security key", ssh: true, hint: "none")) { hostAnswers.append($0) }
        defer { notice.close() }
        precondition(notice.field.superview == nil && notice.accept.isHidden && notice.window?.defaultButtonCell === notice.cancel.cell)
        notice.submit(); precondition(!notice.finished); notice.close(); precondition(hostAnswers.last! == nil)
        let sshPassword = GitAskpassWindowController(prompt: GitAskpassPrompt("Password:", ssh: true)) { hostAnswers.append($0) }
        defer { sshPassword.close() }
        sshPassword.field.stringValue = String(repeating: "雪", count: 342); sshPassword.submit(); precondition(!sshPassword.finished)
        sshPassword.field.stringValue = String(repeating: "雪", count: 341); sshPassword.submit(); precondition(hostAnswers.last!!.utf8.count == 1023)
        precondition(!NSApp.windows.contains { $0.isVisible })
        print("PASS Git askpass native masking/plain username, Return/Escape, one-shot replies, field clearing and forced/invalid response fences")
    }
}
