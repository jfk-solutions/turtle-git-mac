import AppKit
import TurtleGitCore

@main struct MessageSpellingVerification {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let editor = ProjectMessageTextView(frame: .init(x: 0, y: 0, width: 500, height: 200))
        editor.isEditable = true
        var settings = ProjectDialogSettings(); settings.language = .init(value: "1033", inherit: false)
        editor.applyProjectSettings(settings)
        precondition(editor.isContinuousSpellCheckingEnabled && !editor.isAutomaticSpellingCorrectionEnabled && !editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticTextReplacementEnabled)
        var languages: [String?] = []
        editor.spellingDictionary = { word, language in languages.append(language); return !["camel", "Case"].contains(word) }
        editor.string = "🐢 Widget.zzz camelCase 42xxx https://example.invalid/zzzz misspelt"
        editor.setSpellingCandidates(["Widget.zzz"])
        func spelling(_ word: String) -> NSTextCheckingResult { .spellCheckingResult(range: (editor.string as NSString).range(of: word)) }
        let retained = editor.filteredSpellingResults([spelling("zzz"),spelling("camelCase"),spelling("42xxx"),spelling("example"),spelling("misspelt")])
        precondition(retained.count == 1 && retained[0].range == (editor.string as NSString).range(of: "misspelt"))
        precondition(!languages.isEmpty && languages.allSatisfy { $0 == "en_US" })
        editor.setSpellingCandidates([])
        precondition(editor.filteredSpellingResults([spelling("zzz")]).count == 1)
        let grammar = NSTextCheckingResult.grammarCheckingResult(range: .init(location: 0, length: 2), details: [])
        settings.language = .init(value: "-1", inherit: false); editor.applyProjectSettings(settings)
        precondition(!editor.isContinuousSpellCheckingEnabled && editor.filteredSpellingResults([spelling("misspelt"),grammar]).count == 1)
        settings.language = .init(value: "0", inherit: false); editor.applyProjectSettings(settings)
        editor.isEditable = false; precondition(editor.filteredSpellingResults([spelling("misspelt")]).isEmpty)
        precondition(editor.filteredSpellingResults([.spellCheckingResult(range: .init(location: 10000, length: 2))]).isEmpty)
        precondition(!NSApp.windows.contains { $0.isVisible })
        print("PASS native message spelling: project language, source filename/numeric/camel-case/URL filtering, candidate replacement, disabled/read-only/range fences, grammar retention and no automatic rewriting")
    }
}
