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
        precondition(!NSApp.windows.contains { $0.isVisible })
        print("PASS Git askpass native masking/plain username, Return/Escape, one-shot replies, field clearing and forced/invalid response fences")
    }
}
