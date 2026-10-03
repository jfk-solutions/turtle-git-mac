import AppKit
import SwiftUI
import TurtleGitCore

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Follow System" : rawValue.capitalized }
}

@MainActor final class AppAppearance: ObservableObject {
    @Published var choice: AppearanceChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "appearance"); apply() }
    }
    init() {
        choice = AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system
        #if DEBUG
        if Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true,
           let value = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationAppearance") as? String,
           let preset = AppearanceChoice(rawValue: value) { choice = preset }
        #endif
    }
    func apply() {
        NSApp.appearance = choice == .system ? nil : NSAppearance(named: choice == .dark ? .darkAqua : .aqua)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppAppearance
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text("Status colors, graph lanes and original command icons retain their colors in both appearances.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 390)
    }
}

extension FileState {
    /// Match upstream status roles while adapting contrast to the macOS appearance.
    var textColor: Color {
        switch self {
        case .modified: return Color(nsColor: .systemBlue)
        case .added: return Color(nsColor: .systemPurple)
        case .deleted: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.systemRed : NSColor(red: 0.65, green: 0.08, blue: 0.10, alpha: 1)
        })
        case .conflicted: return Color(nsColor: .systemRed)
        case .ignored: return Color(nsColor: .secondaryLabelColor)
        case .normal, .untracked: return Color(nsColor: .labelColor)
        }
    }
}
