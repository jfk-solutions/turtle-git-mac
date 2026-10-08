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
    @AppStorage("LogFontName") private var name = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var size = MessageEditorFont.defaultSize
    @State private var draftSize = String(MessageEditorFont.defaultSize)
    private var validSize: Int? { Int(draftSize).flatMap { (1...1000).contains($0) ? $0 : nil } }
    var body: some View {
        GroupBox("Font for log messages") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    NativeFixedFontChoice(value: $name).frame(height: 24)
                    NativeFontSizeChoice(value: $draftSize).frame(width: 75, height: 24)
                }
                Text("Applies to Commit, Merge, Log messages and Rebase messages/progress.").font(.caption).foregroundStyle(.secondary)
                if validSize == nil { Text("Enter a font size from 1 to 1000 points.").font(.caption).foregroundStyle(.red) }
            }.padding(8)
        }.onAppear { draftSize = String(size) }
        .onChange(of: draftSize) { _ in if let value = validSize { size = value } }
        .onChange(of: size) { draftSize = String($0) }
    }
}
