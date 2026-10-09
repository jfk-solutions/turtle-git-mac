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
        let styled = "雪 🐢\nfatal: failure\nerror: problem\nwarning: caution\n fatal: ordinary\nWARNING: ordinary\nhttps://example.invalid/path. user@example.invalid\n"
        text.present(styled,completed:true)
        guard let storage = text.textStorage else { throw Failure(message:"Missing attributed progress storage") }
        let styledValue = styled as NSString
        func attribute(_ key: NSAttributedString.Key, _ match: String) -> Any? { storage.attribute(key,at:styledValue.range(of:match).location,effectiveRange:nil) }
        for prefix in ["fatal: ","error: ","warning: "] {
            try require((attribute(.font,prefix) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true,"Source warning/error prefix not bold")
        }
        try require((attribute(.font,"failure") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false,"Source styled entire error line instead of prefix")
        try require((attribute(.font," fatal:") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false && (attribute(.font,"WARNING:") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false,"Source case/line-start gate differs")
        func rgb(_ color: NSColor?, _ appearance: NSAppearance.Name) throws -> [CGFloat] {
            var result: [CGFloat] = []
            NSAppearance(named:appearance)!.performAsCurrentDrawingAppearance { if let resolved = color?.usingColorSpace(.sRGB) { result = [resolved.redComponent,resolved.greenComponent,resolved.blueComponent] } }
            try require(result.count == 3,"Unable to resolve progress color"); return result
        }
        let errorColor = attribute(.foregroundColor,"fatal: ") as? NSColor, warningColor = attribute(.foregroundColor,"warning: ") as? NSColor
        let lightError = try rgb(errorColor,.aqua), darkError = try rgb(errorColor,.darkAqua), lightWarning = try rgb(warningColor,.aqua), darkWarning = try rgb(warningColor,.darkAqua)
        try require(abs(lightError[0]-1)<0.001 && lightError[1]<0.001 && abs(darkError[0]-207.0/255)<0.001 && abs(darkError[1]-47.0/255)<0.001,"Source error theme colors differ")
        try require(abs(lightWarning[0]-160.0/255)<0.001 && abs(darkWarning[0]-185.0/255)<0.001 && darkWarning[2]<0.001,"Source warning theme colors differ")
        try require((attribute(.link,"https://example.invalid/path") as? URL)?.absoluteString == "https://example.invalid/path" && (attribute(.link,"user@example.invalid") as? URL)?.absoluteString == "mailto:user@example.invalid","Source URL/email ranges/targets differ")
        var opened: [URL] = []; text.openLink = { opened.append($0); return true }
        let link = URL(string:"https://example.invalid/path")!
        try require(text.textView(text,clickedOnLink:link,at:0) && opened == [link],"Native link click handoff missing")
        prefs.set(false,forKey:"StyleGitOutput"); text.present(styled,completed:true)
        try require((attribute(.font,"fatal: ") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false && attribute(.link,"https://example.invalid/path") != nil,"StyleGitOutput did not gate warning prefixes independently from links")
        text.present(styled,completed:false); try require(attribute(.link,"https://example.invalid/path") == nil,"Source applied completion-only links during stream")
        prefs.removeObject(forKey:"StyleGitOutput")
        prefs.set(false,forKey:"ShowGitexeTimings")
        let plain = SubmoduleProgressCompletion(success:true,cancelled:false,exitCode:0,elapsed:0.123,finished:Date(timeIntervalSince1970:0),preferences:prefs)
        try require(plain.currentWork == "Success" && plain.text == "\nSuccess\n","Disabled timing completion differs")
        prefs.removeObject(forKey:"ShowGitexeTimings")
        let timed = SubmoduleProgressCompletion(success:false,cancelled:false,exitCode:7,elapsed:0.123,finished:Date(timeIntervalSince1970:0),preferences:prefs)
        try require(timed.text.contains("git did not exit cleanly (exit code 7) (123 ms @ ") && timed.text.hasSuffix("\n"),"Default timing/exit footer differs")
        prefs.set(false,forKey:"StyleGitOutput")
        var terminalText = "plain\n"; let terminalRange = timed.append(to:&terminalText)
        text.present(terminalText,completed:true,completionRange:terminalRange,success:false)
        let terminalColor = storage.attribute(.foregroundColor,at:terminalRange.location+2,effectiveRange:nil) as? NSColor
        try require(try rgb(terminalColor,.aqua)[0]>0.99,"Failure footer not red when warning styling is independent")
        var successText = "plain\n"; let successRange = plain.append(to:&successText)
        text.present(successText,completed:true,completionRange:successRange,success:true)
        if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            let successColor = storage.attribute(.foregroundColor,at:successRange.location+1,effectiveRange:nil) as? NSColor
            try require(try rgb(successColor,.aqua)[2]>0.99 && rgb(successColor,.darkAqua)[1]>0.69,"Success footer theme color missing")
        }
        prefs.set(false,forKey:"UseSystemLocaleForDates")
        let fixed = SubmoduleProgressCompletion(success:true,cancelled:false,exitCode:0,elapsed:1,finished:Date(timeIntervalSince1970:0),preferences:prefs)
        try require(fixed.text.range(of:#"Success \(1000 ms @ \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\)"#,options:.regularExpression) != nil,"Fixed-format completion ignored locale preference")
        prefs.set(16,forKey:"GitOutputLimitinKiB")
        var bounded = GitProgressOutputState(preferences:prefs); let parser = GitCliOutputParser(limit:bounded.limit)
        var batch = parser.processPending(); batch.data = Data(repeating:65,count:12*1024)
        bounded.consume(batch,parser:parser); batch.data = Data(repeating:66,count:12*1024); bounded.consume(batch,parser:parser)
        try require(bounded.output.utf8.count < 17*1024 && bounded.currentWork.contains("truncated") && bounded.percentage == nil,"Cumulative streamed batches exceeded display bound")
        let stopped = bounded.output; bounded.consume(batch,parser:parser); try require(bounded.output == stopped,"Truncated state resumed appending")
        bounded.reset(); batch.data = Data(repeating:65,count:16*1024-2); bounded.consume(batch,parser:parser)
        batch.data = Data("雪tail".utf8); bounded.consume(batch,parser:parser)
        try require(bounded.output.utf8.count < 17*1024 && !bounded.output.contains("�"),"Bound split a valid Unicode scalar")
        bounded.reset(); batch.data = Data("Receiving objects: 42%\n".utf8); bounded.consume(batch,parser:parser)
        try require(bounded.percentage == 42 && bounded.currentWork == "Receiving objects","Reset stopped accepting fresh progress")
        let progress = SubmoduleProgressNativeWindow(contentRect:.zero,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        progress.isReleasedWhenClosed = false; defer { progress.close() }; var escapes = 0; progress.escapeAction = { escapes += 1 }
        guard let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:progress.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { throw Failure(message:"Missing Escape fixture") }
        try require(progress.performKeyEquivalent(with:escape) && escapes == 1,"Native progress Escape dispatch missing")
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Output receiver displayed UI")
        print("PASS actual native progress log: source copy menu/order/icons/selectors/preference, private Unicode Copy/Copy All, preserved selection/viewport, tail scrolling, truncated range, native appearance colors/log font, source prefix styling/link targets/private click handoff, timing/footer colors, locale choice, cumulative UTF-8 output limit/reset and Escape route. No displayed keyboard/appearance or signed acceptance.")
    }
}
