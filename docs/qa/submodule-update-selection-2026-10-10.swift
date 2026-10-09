import AppKit
import TurtleGitCore

@main struct SubmoduleUpdateSelectionReceiver {
    @MainActor static func require(_ condition:Bool,_ message:String) throws {
        if !condition { throw NSError(domain:"SubmoduleUpdateSelectionQA",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    @MainActor static func main() {
        do { try check() }
        catch { FileHandle.standardError.write(Data(("Submodule selection QA failed: "+error.localizedDescription+"\n").utf8)); exit(1) }
    }
    @MainActor static func check() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let suite = "turtlegit-submodule-update-selection-"+UUID().uuidString
        guard let preferences = UserDefaults(suiteName:suite) else { throw NSError(domain:"QA",code:1) }
        defer { preferences.removePersistentDomain(forName:suite); preferences.synchronize() }
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let model = SubmoduleUpdateWindowModel(repository:GitRepository(root:root),access:nil,scope:[],selected:[],preferences:preferences)
        defer { model.invalidate() }
        let long = String(repeating:"long-directory/",count:50)+"雪\nmodule"
        let paths = ["first","second",long]; model.paths = paths
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:160),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let scroll = SubmoduleUpdatePathScroll(frame:NSRect(x:0,y:0,width:320,height:160)); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let table = SubmoduleUpdatePathTable(frame:.zero); scroll.documentView = table; window.contentView = scroll
        table.selectionChanged = { model.setSelectedPaths($0) }; table.configure(paths:paths,selection:[]); scroll.tile()
        func click(_ row:Int,_ count:Int = 1) throws {
            let rect = table.rect(ofRow:row), point = table.convert(NSPoint(x:rect.minX+8,y:rect.midY),to:nil)
            guard let event = NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:count,pressure:1) else { throw NSError(domain:"QA",code:1) }
            table.mouseDown(with:event)
        }
        func key(_ code:UInt16) throws {
            guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:code == 49 ? " " : "",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code) else { throw NSError(domain:"QA",code:1) }
            table.keyDown(with:event)
        }
        try click(0); try click(1)
        try require(model.selection == Set(paths.prefix(2)),"Ordinary clicks retain multiple paths")
        try click(0,2); try require(model.selection == ["second"],"Click/double-click count toggles only its row")
        try key(125); try require(model.selection == ["second"] && table.focusedRow == 1,"Down moves focus independently")
        try key(126); try require(model.selection == ["second"] && table.focusedRow == 0,"Navigation retains selections")
        try key(49); try require(model.selection == ["first","second"],"Space toggles focused row")
        model.selectAll(); table.configure(paths:paths,selection:model.selection)
        try require(model.selection.isEmpty && table.selectedRowIndexes.isEmpty,"Mixed select-all clears")
        model.selectAll(); table.configure(paths:paths,selection:model.selection)
        try require(table.selectedRowIndexes.count == 3,"Empty select-all selects every path")
        try require(scroll.hasHorizontalScroller && table.tableColumns[0].width > scroll.contentSize.width,"Long paths scroll horizontally")
        guard let cell = table.tableView(table,viewFor:table.tableColumns[0],row:2) as? NSTextField else { throw NSError(domain:"QA",code:1) }
        let measured = (cell.stringValue as NSString).size(withAttributes:[.font:cell.font!]).width
        try require(table.tableColumns[0].width >= measured,"Full path column is not capped")
        table.configure(paths:["first"],selection:["first"])
        scroll.setFrameSize(NSSize(width:950,height:160)); scroll.tile()
        try require(abs(table.frame.width-scroll.contentSize.width) < 1,"Short paths fill resized viewport")
        table.configure(paths:paths,selection:model.selection)
        try require(cell.toolTip == long && cell.stringValue.contains("↵"),"Literal newline path remains intact with readable display")
        table.interactionEnabled = false; try click(0); try key(49)
        try require(model.selection == Set(paths),"Disabled list ignores mouse/keyboard input")
        table.interactionEnabled = true; model.busy = true; model.setSelectedPaths([])
        try require(model.selection == Set(paths),"Busy model fences stale selection callbacks"); model.busy = false
        var submitted:[String] = []; model.onSubmit = { selected,_ in submitted = selected }
        model.apply(); model.apply(); model.setSelectedPaths([])
        try require(submitted == paths && model.selection == Set(paths),"Acceptance captures literal paths once and fences later edits")
        preferences.removePersistentDomain(forName:suite)
        try require(preferences.persistentDomain(forName:suite)?.isEmpty != false,"Private preference domain cleared")
        print("Submodule Update native list: ordinary row toggles, keyboard focus/Space, all-selection, horizontal paths, disabled/busy fencing and literal single submission passed; unordered window only.")
    }
}
