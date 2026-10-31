import AppKit
import Darwin
import TurtleGitCore

struct MergeSourceBlocksVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition {print("Source block assertion: "+message);fflush(stdout); throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSourceBlocks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.SourceBlocks." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeComparisonOptions.exact.save(to:prefs)
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs")
        let original = "head 🐢\nold1\nold2\ntail\n", modified = "head 🐢\nnew1\nnew2\ntail\n"
        try Data(original.utf8).write(to:base); try Data(modified.utf8).write(to:mine); try Data(original.utf8).write(to:theirs)
        let owner = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs), model = owner.model
        defer { owner.close() }; model.chooseReload = { .discard }; owner.window!.alphaValue = 0; owner.window!.ignoresMouseEvents=true;owner.window!.orderFront(nil); model.load()
        var phase="initial native source rows"
        func wait(_ ready: () -> Bool,line:Int = #line) async throws {
            for _ in 0..<2000 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() && ThreePaneEngineVerification.textViews(owner.window?.contentView).compactMap { $0 as? MergeContextMenuProviding }.allSatisfy(\.mergeSourceRowsReady) { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Source block wait line=\(line) phase=\(phase) busy=\(model.busy) preparing=\(model.preparing) result=\(String(reflecting:model.result)) error=\(String(describing:model.error))")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && ThreePaneEngineVerification.textViews(owner.window?.contentView).filter { !$0.isFieldEditor }.count >= 3 }
        let views = ThreePaneEngineVerification.textViews(owner.window?.contentView), result = views.first { $0.isEditable }!, right = views.first { !$0.isEditable && $0.string.contains("new1") }!, left = views.first { !$0.isEditable && !$0.string.contains("new1") }!
        try await wait { result.string == model.resultDisplayText && right.string.contains("new1") }
        try require(model.error == nil && model.blocks.isEmpty && model.result == modified,"Nonconflicting merge load")
        let initial = model.resultPresentation
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func select(_ text: String, in view: NSTextView) throws {
            let range = (view.string as NSString).range(of:text)
            try require(range.location != NSNotFound,"Missing native source text " + text)
            (view as? MergeLineNavigationProviding)?.beginUserNavigation()
            model.clearNavigationBlockSelection(clearTextSelections:true)
            owner.window!.makeFirstResponder(view); view.setSelectedRange(range)
        }
        func entry(_ choice: MergeBlockChoice, in view: NSTextView) throws -> NSMenuItem {
            let menu = (view as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board)
            guard let item = menu.item(withTitle:choice.rawValue), item.isEnabled, item.image != nil else { throw Failure(description:"Missing enabled source choice " + choice.rawValue) }; return item
        }
        func invoke(_ item: NSMenuItem) throws { try require(NSApplication.shared.sendAction(item.action!,to:item.target,from:item),"Native block dispatch") }
        func undoInitial() async throws { model.undo(); try await wait { model.resultPresentation == initial && result.string == model.resultDisplayText } }
        let nativeMenu=NSMenu(title:"Private ordinary-row choice menu"),previousMenu=NSApp.mainMenu,commands=owner.editorCommandMenu!
        let previousMenuSource=commands.applicationMenu,previousKey=commands.keyWindow
        defer {commands.remove();commands.applicationMenu=previousMenuSource;commands.keyWindow=previousKey;NSApp.mainMenu=previousMenu;withExtendedLifetime(nativeMenu){}}
        NSApp.mainMenu=nativeMenu;commands.applicationMenu={nativeMenu};commands.keyWindow={owner.window};commands.install(in:nativeMenu)
        func command(_ choice:MergeBlockChoice)->MergeToolbarCommand {
            switch choice {case .mine:return .useMine;case .theirs:return .useTheirs;case .mineThenTheirs:return .mineThenTheirs;case .theirsThenMine:return .theirsThenMine}
        }
        func globalItem(_ choice:MergeBlockChoice)throws->NSMenuItem {
            let title=Bundle.main.localizedString(forKey:command(choice).title,value:command(choice).title,table:nil)
            func descendants(_ menu:NSMenu)->[NSMenuItem]{menu.items.flatMap{[$0]+($0.submenu.map(descendants) ?? [])}}
            guard let item=descendants(nativeMenu).first(where:{$0.title==title}),commands.validateMenuItem(item),item.image != nil else {throw Failure(description:"Ordinary-row global choice unavailable: "+title)}
            return item
        }
        func dispatch(_ choice:MergeBlockChoice,route:Int)throws {
            commands.refresh();owner.editorToolbar!.refresh()
            switch route {
            case 0:model.choose(choice) // The same action used by the native footer.
            case 1:try require(owner.editorToolbar!.commandState(command(choice))?.enabled==true,"Ordinary-row toolbar disabled");owner.editorToolbar!.perform(command(choice))
            case 2:try invoke(globalItem(choice))
            default:
                let scalar=choice == .mine || choice == .mineThenTheirs ? NSF10FunctionKey:NSF9FunctionKey
                let flags:NSEvent.ModifierFlags=choice == .mineThenTheirs || choice == .theirsThenMine ? [.control,.shift]:.control
                let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:String(UnicodeScalar(scalar)!),charactersIgnoringModifiers:String(UnicodeScalar(scalar)!),isARepeat:false,keyCode:0)!
                try require(commands.performKeyEquivalent(event),"Ordinary-row source shortcut not routed")
            }
        }
        // Global/footer/toolbar/key choices work without unresolved conflicts,
        // and a half-open selection ending at the next row excludes that row.
        for (route,choice) in MergeBlockChoice.allCases.enumerated() {
            phase="generic half-open row / route \(route) / \(choice.rawValue)";print(phase);fflush(stdout)
            try select("new1",in:right)
            let start=(right.string as NSString).range(of:"new1").location,next=(right.string as NSString).range(of:"new2").location
            right.setSelectedRange(NSRange(location:start,length:next-start))
            try dispatch(choice,route:route)
            let expected=choice == .theirs ? "head 🐢\nnew2\ntail\n":modified
            try await wait{model.result==expected && model.canUndo}
            try require(model.blocks.isEmpty && model.result.contains("new2\n"),"Half-open generic choice consumed following row")
            let chosen=model.resultPresentation
            model.undo();try await wait{model.resultPresentation==initial};model.redo();try await wait{model.resultPresentation==chosen};try await undoInitial()
        }
        for (route,choice) in [MergeBlockChoice.mineThenTheirs,.theirsThenMine].enumerated() {
            phase="ordinary common-row ordering / \(choice.rawValue)"
            try select("head 🐢",in:right);try dispatch(choice,route:route+1)
            try await wait{model.result=="head 🐢\n"+modified && model.canUndo};try await undoInitial()
        }
        phase="generic multiline boundary and exact Save bytes";print(phase);fflush(stdout)
        try select("new1",in:right)
        let multiStart=(right.string as NSString).range(of:"new1").location,multiEnd=(right.string as NSString).range(of:"tail").location
        right.setSelectedRange(NSRange(location:multiStart,length:multiEnd-multiStart));try dispatch(.theirs,route:2)
        try await wait{model.result=="head 🐢\ntail\n" && model.canUndo}
        let output=root.appendingPathComponent("generic-selected-result")
        model.chooseStandaloneOutput={_,_ in output};model.changeEncoding(.utf8);model.save(markResolved:false)
        try await wait{!model.busy}
        try require(model.error==nil && (try Data(contentsOf:output))==Data("head 🐢\ntail\n".utf8),"Generic multi-row Save bytes or trailing boundary changed")
        try await undoInitial()
        phase="explicit native Base selection refuses previous mapped source"
        try select("new1",in:right)
        model.showBase=true
        func basePane()->NSTextView? {
            ThreePaneEngineVerification.textViews(owner.window?.contentView).first{!$0.isFieldEditor && !$0.isEditable && ($0 as? MergeLineNavigationProviding)?.navigationCells==nil && $0.string==original}
        }
        try await wait{basePane() != nil && model.nativeEditorReady}
        let baseView=basePane()!,beforeBase=model.resultPresentation,beforeBaseUndo=model.canUndo,beforeBaseRedo=model.canRedo
        try select("old1",in:baseView);commands.refresh();owner.editorToolbar!.refresh()
        try require(!model.canChooseSourceBlock && model.currentSourceBlockCommand(choice:.theirs)==nil,"Explicit Base selection reused a previous mapped source choice")
        model.choose(.theirs);owner.editorToolbar!.perform(.useTheirs)
        try require(model.resultPresentation==beforeBase && model.canUndo==beforeBaseUndo && model.canRedo==beforeBaseRedo,"Unmapped Base choice changed result/history")
        try require(owner.window!.makeFirstResponder(nil),"Native Base focus did not release")
        try require(!model.canChooseSourceBlock && model.currentSourceBlockCommand(choice:.theirs)==nil,"Toolbar focus departure revived the mapped source behind Base selection")
        model.showBase=false
        try await wait{basePane()==nil && model.nativeEditorReady}
        try select("new1",in:right);let busyChoice=try globalItem(.theirs)
        model.busy=true;commands.refresh();owner.editorToolbar!.refresh();try invoke(busyChoice);model.choose(.theirs);owner.editorToolbar!.perform(.useTheirs)
        try require(!commands.validateMenuItem(busyChoice) && owner.editorToolbar!.commandState(.useTheirs)?.enabled==false && model.resultPresentation==initial,"Busy generic choices mutated ordinary rows")
        model.busy=false;commands.refresh()
        phase="retained original captured context/history/stale cases";print(phase);fflush(stdout)
        // Selecting one addition must leave its adjacent addition intact.
        for choice in MergeBlockChoice.allCases {
            try select("new1",in:right); let item = try entry(choice,in:right)
            try select("tail",in:right); try invoke(item)
            let expected = choice == .theirs ? "head 🐢\nnew2\ntail\n" : modified
            try await wait { model.result == expected && model.canUndo }
            try require(model.result.contains("new2\n") && model.dirty,"Neighbor addition overwritten or explicit choice lost modified state")
            try await undoInitial()
        }
        // The normal side of a removed Base row inserts at its zero-byte anchor.
        try select("old1",in:left); try invoke(entry(.theirs,in:left))
        try await wait { model.result == "head 🐢\nold1\nnew1\nnew2\ntail\n" }
        try require(model.resultPresentation.navigationMap.exactResultRange(sourceRows:0..<model.sourceComparison!.rows.count) != nil,"Insertion lost adjacent mappings")
        try await undoInitial()
        // Both ordering commands are available for ordinary common rows too.
        for choice in [MergeBlockChoice.mineThenTheirs,.theirsThenMine] {
            try select("head 🐢",in:right); try invoke(entry(choice,in:right))
            try await wait { model.result == "head 🐢\n" + modified }
            try await undoInitial()
        }
        // Result context commands resolve through exact source mappings as well.
        try select("new1",in:result); try invoke(entry(.theirs,in:result))
        try await wait { model.result == "head 🐢\nnew2\ntail\n" }
        try select("new1",in:right); try invoke(entry(.mine,in:right))
        try await wait { model.result == modified }
        model.undo(); try await wait { model.result == "head 🐢\nnew2\ntail\n" }; try await undoInitial()
        model.redo(); try await wait { model.result == "head 🐢\nnew2\ntail\n" }; try await undoInitial()
        // Captured choices cannot overwrite a later edit or run during a sheet.
        try select("new1",in:right); let stale = try entry(.theirs,in:right)
        result.insertText("typed ",replacementRange:NSRange(location:0,length:0))
        try await wait { model.result.hasPrefix("typed ") }; let edited = model.result; try invoke(stale); try require(model.result == edited,"Stale menu overwrote typing")
        try await undoInitial()
        try select("new1",in:right); let blocked = try entry(.theirs,in:right)
        model.confirmingQuit = true; try invoke(blocked); try require(model.resultPresentation == initial,"Quit gate failed"); model.confirmingQuit = false
        let rows = model.sourceComparison!.rows.firstIndex { $0.mine.displayText == "new1" }!
        let command = model.sourceBlockCommand(rows:rows..<(rows + 1),choice:.theirs)!
        model.load(); try await wait { !model.busy && !model.preparing }; model.performSourceBlock(command)
        try require(model.result == modified,"Reload revived a stale source command")
        owner.close(); model.performSourceBlock(command); try require(model.result == modified,"Closed source owner changed result")
        try require(try String(contentsOf:base,encoding:.utf8) == original && String(contentsOf:mine,encoding:.utf8) == modified && String(contentsOf:theirs,encoding:.utf8) == original,"Source block commands rewrote input files")
        print("PASS: ordinary/changed source and result block menus, captured selection, all four choices, exact removed-row insertion, neighboring rows, repeated alternatives, Undo/Redo mapping, stale edits/reload/Quit/closed gates and unchanged inputs; owned window closed")
    }
}
