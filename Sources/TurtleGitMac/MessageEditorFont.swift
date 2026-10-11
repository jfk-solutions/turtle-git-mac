// Adapts TortoiseGit's LogFontName/LogFontSize preferences (see NOTICE).
import AppKit
import SwiftUI

@MainActor enum MessageEditorFont {
    static let defaultName = "Menlo"
    static let defaultSize = 9
    static func resolve(name: String, size: Int) -> NSFont {
        let points = CGFloat((1...1000).contains(size) ? size : defaultSize)
        return NSFont(name: name, size: points)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: points)
            ?? NSFont(name: defaultName, size: points)
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
    }
}

struct MessageEditorFontSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var name = UserDefaults.standard.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName
    @State private var draftSize = String((UserDefaults.standard.object(forKey: "LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize)
    @State private var savedName = UserDefaults.standard.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName
    @State private var savedSize = String((UserDefaults.standard.object(forKey: "LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize)
    private var validSize: Int? { Int(draftSize).flatMap { (1...1000).contains($0) ? $0 : nil } }
    var body: some View {
        GroupBox("Font for log messages") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    NativeFixedFontChoice(value: $name).frame(height: 24)
                    NativeFontSizeChoice(value: $draftSize).frame(width: 75, height: 24)
                }
                Text("Applies to Commit, Merge, Log messages, branch descriptions and Rebase messages/progress.").font(.caption).foregroundStyle(.secondary)
                if validSize == nil { Text("Enter a font size from 1 to 1000 points.").font(.caption).foregroundStyle(.red) }
            }.padding(8)
        }
        .onChange(of: draftSize) { _ in if transaction == nil { apply() }; transaction?.notify() }
        .onChange(of: name) { _ in if transaction == nil { apply() }; transaction?.notify() }
        .settingsParticipant("dialogs.font", page: .dialogs, value: draftSize,
            modified: { name != savedName || draftSize != savedSize },
            validate: { validSize == nil ? "Enter a font size from 1 to 1000 points." : nil },
            apply: { apply(); return validSize != nil }, cancel: { name = savedName; draftSize = savedSize })
    }
    private func apply() {
        guard let size = validSize else { return }
        UserDefaults.standard.set(name, forKey: "LogFontName"); UserDefaults.standard.set(size, forKey: "LogFontSize")
        savedName = name; savedSize = draftSize
    }

}

/// Shared status/FileDiff list font, enabled independently of revision-list fonts.
private struct FileListFontModifier: ViewModifier {
    @AppStorage("LogFontForFileListCtrl") private var enabled = false
    @AppStorage("LogFontName") private var name = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var size = MessageEditorFont.defaultSize
    func body(content: Content) -> some View {
        content.font(enabled ? Font(MessageEditorFont.resolve(name: name, size: size)) : nil)
    }
}
extension View {
    func fileListFont() -> some View { modifier(FileListFontModifier()) }
}
