import AppKit
import SwiftUI
import TurtleGitCore

@main struct StatusColorsVerification {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let reference = try JSONDecoder().decode([String:[String:[Int]]].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let appearances: [(String,NSAppearance.Name)] = [("light",.aqua),("dark",.darkAqua),("highContrastDark",.accessibilityHighContrastDarkAqua),("highContrastLight",.accessibilityHighContrastAqua)]
        for role in StatusTextRole.allCases {
            let dynamic = StatusTextPalette.native(role)
            for (mode,name) in appearances {
                let expected = reference[role.rawValue]![mode == "highContrastLight" ? "light" : mode]!
                precondition(StatusTextPalette.rgb(role, dark: mode == "dark" || mode == "highContrastDark", highContrast: mode == "highContrastDark") == expected, "C++ RGB mismatch: \(role) \(mode)")
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let color = dynamic.usingColorSpace(.sRGB)!
                    let channels = [color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0 * 255).rounded()) }
                    precondition(channels == expected, "AppKit dynamic color mismatch: \(role) \(mode) \(channels) vs \(expected)")
                }
            }
        }
        let cases: [(String,StatusTextRole?)] = [("UU",.conflict),("AU",.conflict),("DD",.conflict),("AA",.conflict),(" M",.modified),("T ",.modified),("AM",.modified),("RM",.modified),("DM",.modified),("A ",.added),("C ",.added),("AD",.added),("D ",.deleted),("RD",.deleted),("R ",.renamed),("??",nil),("!!",nil),("  ",nil)]
        for (status,expected) in cases {
            let renamed = status.contains("R") || status.contains("C")
            let bytes = Data((status + " path\0" + (renamed ? "old\0" : "")).utf8)
            let entry = StatusEntry.parse(bytes)[0]
            precondition(entry.statusTextRole == expected, "Combined status role mismatch: \(status)")
            precondition(entry.statusTextColor(selected: true) == Color.primary)
        }
        let success = LFSFileResult(path: "file", success: true, output: "Locked")
        let failure = LFSFileResult(path: "file", success: false, output: "Error")
        precondition(success.resultTextColor == Color.primary)
        for (_,name) in appearances {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let color = NSColor(failure.resultTextColor).usingColorSpace(.sRGB)!
                precondition([color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0 * 255).rounded()) } == reference["conflict"]!["light"]!)
            }
        }
        precondition(Set(StatusTextRole.allCases.map { StatusTextPalette.rgb($0, dark: false).description }).count == 6)
        print("PASS: six pinned default RGB roles and native dynamic Aqua/Dark Aqua/high-contrast light+dark resolutions match independently compiled upstream C++ functions; mixed index/worktree priority, conflict precedence, rename/copy distinctions, neutral normal/unversioned/ignored roles and semantic selected text, neutral LFS success and Conflict LFS error verified. No pixel/physical visual acceptance claimed.")
    }
}
