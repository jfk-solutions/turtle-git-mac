import AppKit
import SwiftUI
@testable import TurtleGitCore

@main struct StatusColorsVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let suite = "TurtleGit.StatusColors.QA." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let reference = try JSONDecoder().decode([String:[String:[Int]]].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let appearances: [(String,NSAppearance.Name)] = [("light",.aqua),("dark",.darkAqua),("highContrastDark",.accessibilityHighContrastDarkAqua),("highContrastLight",.accessibilityHighContrastAqua)]
        for role in StatusTextRole.allCases {
            let dynamic = StatusTextPalette.native(role, preferences: preferences)
            for (mode,name) in appearances {
                let expected = reference[role.rawValue]![mode == "highContrastLight" ? "light" : mode]!
                precondition(StatusTextPalette.rgb(role, dark: mode == "dark" || mode == "highContrastDark", highContrast: mode == "highContrastDark") == expected, "C++ RGB mismatch: \(role) \(mode)")
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let color = dynamic.usingColorSpace(.sRGB)!
                    let channels = [color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0 * 255).rounded()) }
                    let nativeExpected = reference[role.rawValue]![mode == "dark" || mode == "highContrastDark" ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? "highContrastDark" : "dark") : "light"]!
                    precondition(channels == nativeExpected, "AppKit dynamic color mismatch: \(role) \(mode) \(channels) vs \(expected)")
                }
            }
        }
        for role in LogColorRole.allCases {
            for (mode,_) in appearances {
                precondition(StatusTextPalette.transform(role.rgb, dark: mode == "dark" || mode == "highContrastDark", highContrast: mode == "highContrastDark") == reference[role.rawValue.lowercased()]![mode == "highContrastLight" ? "light" : mode]!)
            }
            let dynamic = LogPalette.native(role, preferences: preferences)
            for (mode,name) in appearances {
                let expected = reference[role.rawValue.lowercased()]![mode == "dark" || mode == "highContrastDark" ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? "highContrastDark" : "dark") : "light"]!
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let value = dynamic.usingColorSpace(.sRGB)!
                    let rgb = [value.redComponent,value.greenComponent,value.blueComponent].map { Int(($0 * 255).rounded()) }
                    precondition(rgb == expected, "Log role RGB \(role) \(mode): \(rgb) expected \(expected)")
                    let text = LogPalette.foreground(background: value)
                    precondition(text == (rgb[0]*30 + rgb[1]*59 + rgb[2]*11 <= 12800 ? NSColor.white : NSColor.black))
                }
            }
        }
        for (name,role) in [("refs/heads/main",LogColorRole.localBranch),("refs/remotes/origin/main",.remoteBranch),("refs/tags/v1",.tag),("refs/stash",.stash),("refs/bisect/good-abc",.bisectGood),("refs/bisect/skip-abc",.bisectSkip),("refs/bisect/bad",.bisectBad),("refs/bisect/goodness",.otherRef),("refs/notes/commits",.noteNode),("refs/custom/value",.otherRef)] {
            precondition(LogColorRole.reference(RevisionReference(name: name)) == role)
        }
        var current = RevisionReference(name: "refs/heads/main"); current.isCurrent = true
        precondition(LogColorRole.reference(current) == .currentBranch)
        precondition(LogColorRole.reference(RevisionReference(name: "refs/bisect/old-abc"), goodTerm: "old", badTerm: "new") == .bisectGood)
        precondition(LogColorRole.reference(RevisionReference(name: "refs/bisect/new"), goodTerm: "old", badTerm: "new") == .bisectBad)
        precondition(LogColorRole.reference(RevisionReference(name: "refs/bisect/newer"), goodTerm: "old", badTerm: "new") == .otherRef)
        for index in 0..<24 {
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                let value = LogPalette.lane(index, preferences: preferences).usingColorSpace(.sRGB)!
                precondition([value.redComponent,value.greenComponent,value.blueComponent].map { Int(($0 * 255).rounded()) } == LogColorRole.lanes[index % 8].rgb)
            }
        }
        preferences.set(0x010203, forKey: "Colors.Stash")
        preferences.set(0x040506, forKey: "Colors.Modified")
        let logSettings = LogColorSettingsModel(preferences: preferences)
        precondition(!logSettings.changed && logSettings.draft.lineWidth == 2 && logSettings.draft.nodeSize == 10)
        logSettings.set(.tag, rgb: [3,127,249]); logSettings.setLineWidth(5); logSettings.setNodeSize(20)
        precondition(logSettings.changed && preferences.object(forKey: "Colors.Tag") == nil)
        logSettings.cancel(); precondition(!logSettings.changed && logSettings.draft.rgb(.tag) == LogColorRole.tag.rgb)
        logSettings.set(.tag, rgb: [3,127,249]); logSettings.setLineWidth(5); logSettings.setNodeSize(20); logSettings.apply()
        precondition(preferences.integer(forKey: "Colors.Tag") == 0x037ff9 && preferences.integer(forKey: LogColorPreferences.lineWidthKey) == 5 && preferences.integer(forKey: LogColorPreferences.nodeSizeKey) == 20)
        let loaded = LogColorSettingsModel(preferences: preferences)
        precondition(loaded.draft.rgb(.tag) == [3,127,249] && loaded.draft.lineWidth == 5 && loaded.draft.nodeSize == 20)
        loaded.restoreDefaults(); precondition(loaded.changed && preferences.integer(forKey: "Colors.Tag") == 0x037ff9)
        loaded.cancel(); precondition(!loaded.changed && loaded.draft.nodeSize == 20)
        loaded.restoreDefaults(); loaded.apply()
        precondition(preferences.integer(forKey: "Colors.Stash") == 0x010203 && preferences.integer(forKey: "Colors.Modified") == 0x040506)
        preferences.removeObject(forKey: "Colors.Modified")
        for invalid: Any in [true,-1,0x1000000,1.5,"123"] {
            preferences.set(invalid, forKey: "Colors.Tag")
            precondition(LogColorPreferences.load(preferences).rgb(.tag) == LogColorRole.tag.rgb)
        }
        preferences.removeObject(forKey: "Colors.Tag")
        for invalid: Any in [true,0,31,1.5,"2"] {
            preferences.set(invalid, forKey: LogColorPreferences.nodeSizeKey)
            precondition(LogColorPreferences.load(preferences).nodeSize == 10)
        }
        preferences.removeObject(forKey: LogColorPreferences.nodeSizeKey)
        let cases: [(String,StatusTextRole?)] = [("UU",.conflict),("AU",.conflict),("DD",.conflict),("AA",.conflict),(" M",.modified),("T ",.modified),("AM",.modified),("RM",.modified),("DM",.modified),("A ",.added),("C ",.added),("AD",.added),("D ",.deleted),("RD",.deleted),("R ",.renamed),("??",nil),("!!",nil),("  ",nil)]
        for (status,expected) in cases {
            let renamed = status.contains("R") || status.contains("C")
            let bytes = Data((status + " path\0" + (renamed ? "old\0" : "")).utf8)
            let entry = StatusEntry.parse(bytes)[0]
            precondition(entry.statusTextRole == expected, "Combined status role mismatch: \(status)")
            precondition(entry.statusTextColor(selected: true) == Color.primary)
        }
        for (action,expected) in [("U",StatusTextRole.conflict),("M",.modified),("T",.modified),("A",.added),("C100",.added),("D",.deleted),("K",.deleted),("R087",.renamed)] {
            let file = CommitFile(path: "file", oldPath: nil, action: action, added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
            precondition(file.statusTextRole == expected)
            precondition(file.statusTextColor(selected: true, gray: true, preferences: preferences) == .primary)
            precondition(file.statusTextColor(gray: true, preferences: preferences) == .secondary)
            let color = NSColor(file.statusTextColor(preferences: preferences)).usingColorSpace(.sRGB)!
            precondition([color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0 * 255).rounded()) } == reference[expected.rawValue]!["light"]!, "CommitFile RGB \(action): \(color) expected \(reference[expected.rawValue]!["light"]!)")
        }
        for action in ["?","!","", "X"] {
            let file = CommitFile(path: "file", oldPath: nil, action: action, added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
            precondition(file.statusTextRole == nil && file.statusTextColor(preferences: preferences) == .primary)
        }
        let success = LFSFileResult(path: "file", success: true, output: "Locked")
        let failure = LFSFileResult(path: "file", success: false, output: "Error")
        precondition(success.resultTextColor(preferences: preferences) == Color.primary)
        for (_,name) in appearances {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let color = NSColor(failure.resultTextColor(preferences: preferences)).usingColorSpace(.sRGB)!
                precondition([color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0 * 255).rounded()) } == reference["conflict"]!["light"]!)
            }
        }
        for (name,rgb) in [("black",[0,0,0]),("white",[255,255,255]),("custom",[3,127,249]),("bright",[250,240,230])] {
            for (mode,_) in appearances {
                precondition(StatusTextPalette.transform(rgb, dark: mode == "dark" || mode == "highContrastDark", highContrast: mode == "highContrastDark") == reference[name]![mode == "highContrastLight" ? "light" : mode]!)
            }
        }
        preferences.set(777, forKey: "Colors.OtherRef")
        preferences.set("dark", forKey: "appearance")
        let model = StatusColorSettingsModel(preferences: preferences)
        let updates = StatusColorUpdates.shared
        let accessibilityRevision = updates.revision
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        precondition(updates.revision == accessibilityRevision + 1)
        let revision = updates.revision
        precondition(!model.changed && preferences.object(forKey: "Colors.Modified") == nil)
        model.set(.modified, rgb: [3,127,249])
        precondition(model.changed && preferences.object(forKey: "Colors.Modified") == nil)
        model.cancel(); precondition(!model.changed && model.draft.rgb(.modified) == StatusTextRole.modified.rgb)
        model.setColor(.modified, color: Color(.sRGB, red: 3.0/255, green: 127.0/255, blue: 249.0/255, opacity: 0.25))
        precondition(model.draft.rgb(.modified) == [3,127,249])
        model.apply()
        precondition(!model.changed && preferences.integer(forKey: "Colors.Modified") == 0x037ff9)
        precondition(preferences.integer(forKey: "Colors.PropertyChanged") == 0x037ff9 && updates.revision == revision + 1)
        let reopened = StatusColorSettingsModel(preferences: preferences)
        precondition(reopened.draft.rgb(.modified) == [3,127,249] && !reopened.changed)
        let custom = StatusTextPalette.native(.modified, preferences: preferences)
        for (mode,name) in appearances {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = custom.usingColorSpace(.sRGB)!
                precondition([c.redComponent,c.greenComponent,c.blueComponent].map { Int(($0 * 255).rounded()) } == reference["custom"]![mode == "dark" || mode == "highContrastDark" ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? "highContrastDark" : "dark") : "light"]!)
            }
        }
        reopened.restoreDefaults(); precondition(reopened.changed && preferences.integer(forKey: "Colors.Modified") == 0x037ff9)
        reopened.cancel(); precondition(reopened.draft.rgb(.modified) == [3,127,249])
        reopened.automatic(.modified); reopened.apply()
        precondition(StatusColorPreferences.load(preferences).rgb(.modified) == StatusTextRole.modified.rgb)
        reopened.set(.added, rgb: [0,0,0]); reopened.set(.deleted, rgb: [255,255,255]); reopened.apply()
        reopened.restoreDefaults(); reopened.apply()
        for role in StatusTextRole.allCases { precondition(StatusColorPreferences.load(preferences).rgb(role) == role.rgb) }
        precondition(preferences.integer(forKey: "Colors.OtherRef") == 777 && preferences.string(forKey: "appearance") == "dark")
        let unchanged = updates.revision; reopened.apply(); precondition(updates.revision == unchanged)
        let invalidValues: [Any] = [true,-1,0x1000000,1.5,"1234"]
        for invalid in invalidValues {
            preferences.set(invalid, forKey: "Colors.Modified")
            precondition(StatusColorPreferences.load(preferences).rgb(.modified) == StatusTextRole.modified.rgb)
        }
        preferences.removeObject(forKey: "Colors.Modified")
        let beforeInvalid = reopened.draft
        reopened.set(.added, rgb: [-1,0,0]); reopened.set(.added, rgb: [1,2])
        precondition(reopened.draft == beforeInvalid)
        // Actual native settings content and action controls, without opening
        // a shared color panel or changing the main application preferences.
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 580,height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatusColorsSettings(model: reopened))
        window.contentView!.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        window.setContentSize(NSSize(width: 580,height: 400))
        window.contentView!.layoutSubtreeIfNeeded()
        defer { window.close() }
        for _ in 0..<1000 {
            if descendants(window.contentView!).compactMap({ $0 as? NSButton }).contains(where: { $0.title == "Apply" }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
        let apply = buttons.first { $0.title == "Apply" }!
        let restore = buttons.first { $0.title == "Restore Defaults" }!
        let cancel = buttons.first { $0.title == "Cancel" }!
        precondition(buttons.filter { $0.title == "Default" }.count == 6)
        precondition(!apply.isEnabled && !cancel.isEnabled)
        let wells = descendants(window.contentView!).compactMap { $0 as? NSColorWell }
        precondition(wells.count == 6)
        wells[0].color = NSColor(srgbRed: 3.0/255, green: 127.0/255, blue: 249.0/255, alpha: 1)
        precondition(wells[0].action != nil)
        precondition(NSApplication.shared.sendAction(wells[0].action!, to: wells[0].target, from: wells[0]))
        precondition(reopened.draft.rgb(.added) == [3,127,249])
        for _ in 0..<1000 {
            if apply.isEnabled && cancel.isEnabled { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancel.performClick(nil)
        precondition(reopened.draft.rgb(.added) == StatusTextRole.added.rgb && !reopened.changed)
        wells[0].color = NSColor(srgbRed: 3.0/255, green: 127.0/255, blue: 249.0/255, alpha: 1)
        _ = NSApplication.shared.sendAction(wells[0].action!, to: wells[0].target, from: wells[0])
        for _ in 0..<1000 {
            if apply.isEnabled { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        apply.performClick(nil)
        precondition(StatusColorPreferences.load(preferences).rgb(.added) == [3,127,249])
        buttons.first(where: { $0.title == "Default" })!.performClick(nil)
        precondition(reopened.draft.rgb(.added) == StatusTextRole.added.rgb && StatusColorPreferences.load(preferences).rgb(.added) == [3,127,249])
        restore.performClick(nil)
        precondition(reopened.draft.rgb(.added) == StatusTextRole.added.rgb && StatusColorPreferences.load(preferences).rgb(.added) == [3,127,249])
        window.close()
        precondition(Set(StatusTextRole.allCases.map { StatusTextPalette.rgb($0, dark: false).description }).count == 6)
        print("PASS: six status and eighteen Log roles match independently compiled upstream C++ light/dark/high-contrast numeric functions; native dynamic Aqua/Dark and named accessibility appearances follow the actual system Increase Contrast flag; mixed index/worktree priority, conflict precedence, rename/copy distinctions, neutral normal/unversioned/ignored roles and semantic selected text, neutral LFS success and Conflict LFS error verified. Custom RGB/black/white/clamp reference checks, private preference Apply/Cancel/default/reopening/validation/alias/notification, preserved unrelated preferences and native settings action targets pass. Log draft/Apply/Cancel/Restore/preserved noneditable preferences, eight-color cycling and custom/default bisect term boundaries pass. Injected accessibility notification invalidates the observer; actual system setting toggle, shared color-panel and pixel/physical visual acceptance not claimed.")
    }
}
