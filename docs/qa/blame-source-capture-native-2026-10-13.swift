import AppKit

@main struct BlameSourceCapture {
    @MainActor static func main() async { await BlameSourceEditorVerification.main() }
}
