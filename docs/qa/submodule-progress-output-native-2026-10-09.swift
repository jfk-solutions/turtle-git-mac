import AppKit
import TurtleGitCore

@main struct SubmoduleProgressOutputReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) }
    }
    @MainActor static func run() throws {
        let domain = "TurtleGit.SubmoduleProgressOutput.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:domain)!
        defer { prefs.removePersistentDomain(forName:domain) }
        let clipboard = NSPasteboard(name:NSPasteboard.Name(domain)); defer { clipboard.releaseGlobally() }
        prefs.set("Menlo",forKey:"LogFontName"); prefs.set(13,forKey:"LogFontSize")
        let scroll = SubmoduleProgressTextView.scrollView(preferences:prefs,clipboard:clipboard)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; defer { window.close() }
        scroll.frame = NSRect(x:0,y:0,width:600,height:240)
        guard let text = scroll.documentView as? SubmoduleProgressTextView else { throw Failure(message:"Wrong progress log class") }
        try require(!text.isEditable && text.isSelectable && text.font?.pointSize == 13,"Read-only/font defaults mismatch")
        let output = (0..<300).map { "line \($0) 雪 🐢" }.joined(separator:"\n") + "\n"
        text.present(output); scroll.layoutSubtreeIfNeeded()
        let range = (output as NSString).range(of:"雪 🐢")
        text.setSelectedRange(range)
        let menu = text.outputMenu()
        try require(menu.items.map(\.title) == ["Copy","","Copy all information to clipboard"] && menu.items[1].isSeparatorItem,"Source copy menu order mismatch")
        try require(menu.items[0].target === text && menu.items[2].target === text && menu.items[0].isEnabled,"Menu targets/selection state missing")
        try require(menu.items[0].image != nil && menu.items[2].image != nil && menu.items[0].image?.isTemplate == false,"Original copy artwork missing")
        try require(menu.items[0].action == #selector(SubmoduleProgressTextView.copySelection(_:)) && menu.items[2].action == #selector(SubmoduleProgressTextView.copyAllInformation(_:)),"Copy selectors differ")
        text.copy(nil); try require(clipboard.string(forType:.string) == "雪 🐢","Unicode selection copy failed")
        let selection = text.selectedRange(), origin = scroll.contentView.bounds.origin
        text.copyAllInformation(nil)
        try require(clipboard.string(forType:.string) == output && text.selectedRange() == selection && scroll.contentView.bounds.origin == origin,"Copy All changed selection/viewport")
        text.present(output + "appended tail\n"); scroll.layoutSubtreeIfNeeded()
        try require(text.selectedRange() == selection && scroll.contentView.bounds.origin.y > 0,"Live output lost selection or did not follow tail")
        let bottom = max(0,text.bounds.height-scroll.contentView.bounds.height)
        try require(abs(scroll.contentView.bounds.origin.y-bottom) < 2,"Progress log did not scroll to latest output")
        text.present("short\n"); try require(text.selectedRange().location <= (text.string as NSString).length,"Shortened/truncated log retained invalid range")
        text.setSelectedRange(NSRange(location:0,length:0)); try require(!text.outputMenu().items[0].isEnabled && text.outputMenu().items[2].isEnabled,"Empty-selection Copy gate differs")
        prefs.set(false,forKey:"ShowAppContextMenuIcons"); try require(text.outputMenu().items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil },"Menu icon preference ignored")
        prefs.set(true,forKey:"ShowAppContextMenuIcons"); try require(text.outputMenu().items[2].image != nil,"Menu icons did not recover")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            text.appearance = NSAppearance(named:appearance)
            try require(text.textColor == .textColor && text.backgroundColor == .textBackgroundColor,"Output discarded native appearance colors")
        }
        let progress = SubmoduleProgressNativeWindow(contentRect:.zero,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        progress.isReleasedWhenClosed = false; defer { progress.close() }; var escapes = 0; progress.escapeAction = { escapes += 1 }
        guard let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:progress.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { throw Failure(message:"Missing Escape fixture") }
        try require(progress.performKeyEquivalent(with:escape) && escapes == 1,"Native progress Escape dispatch missing")
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Output receiver displayed UI")
        print("PASS actual native progress log: source copy menu/order/icons/selectors/preference, private Unicode Copy/Copy All, preserved selection/viewport, tail scrolling, truncated range, native appearance colors/log font and Escape route. No displayed keyboard/appearance or signed acceptance.")
    }
}
