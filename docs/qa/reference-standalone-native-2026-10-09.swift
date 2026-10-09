import AppKit
import TurtleGitCore

@main struct StandaloneReferenceVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool,_ message: String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func find(_ view: NSView) -> NSTableView? {
        if let table=view as? NSTableView,table.accessibilityLabel()=="References" {return table};for child in view.subviews {if let result=find(child){return result}};return nil
    }
    @MainActor static func wait(_ windows:[NSWindow]=[],_ ready:()->Bool) async throws {
        for _ in 0..<2000 {windows.forEach{$0.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Timeout")
    }
    @MainActor static func main() async { do {try await verify()} catch {fputs("Standalone reference QA failed: \(error)\n",stderr);exit(1)} }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        let suite="TurtleGit.ReferenceStandalone.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);prefs.synchronize()}
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Standalone QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["branch","left"]);_ = try await repo.run(["commit","--allow-empty","-m","right"]);_ = try await repo.run(["branch","right"])
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines);_ = try await repo.run(["update-ref","refs/misc/tree",tree])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config")),file=try Data(contentsOf:root.appendingPathComponent("file"))
        var closes=0,logs:[String]=[],browses:[String]=[],copies:[String]=[]
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"HEAD",preferences:prefs,picking:false){_ in closes += 1};defer {owner.close()}
        owner.model.onLogRange={logs.append($0.expression)};owner.model.onLog={logs.append($0)};owner.model.onBrowse={browses.append($0)};owner.model.copyReferences={copies.append($0)}
        owner.model.load();try await wait([owner.window!]){!owner.model.busy && owner.model.snapshot != nil}
        owner.model.setFolder("refs");try await wait([owner.window!]){find(owner.window!.contentView!) != nil}
        guard let table=find(owner.window!.contentView!),let menu=table.menu else {throw Failure(message:"Actual native table/menu absent")}
        try require(table.allowsMultipleSelection && owner.model.canFinish,"Standalone selection/empty close gate")
        func row(_ name:String) throws -> Int {guard let index=owner.model.rows.firstIndex(where:{$0.reference.name==GitReferenceName(name)}) else {throw Failure(message:"Missing row "+name)};return index}
        func refreshMenu(){menu.delegate?.menuNeedsUpdate?(menu)}
        func invoke(_ title:String) throws {
            refreshMenu();guard let entry=menu.items.first(where:{$0.title==title}),let action=entry.action else {throw Failure(message:"Missing menu "+title)}
            try require(entry.isEnabled && entry.image != nil,"Menu enablement/artwork")
            try require(NSApplication.shared.sendAction(action,to:entry.target,from:entry),"Native action dispatch")
        }
        table.selectRowIndexes(IndexSet(integer:try row("refs/heads/left")),byExtendingSelection:false)
        table.selectRowIndexes(IndexSet(integer:try row("refs/heads/right")),byExtendingSelection:true)
        try require(owner.model.selection.count==2 && owner.model.lastSelected=="refs/heads/right" && owner.model.chosen==nil,"Native multiple selection/last-selected identity")
        try invoke("Show log of left..right");try invoke("Show log of left...right")
        try require(logs==["refs/heads/left..refs/heads/right","refs/heads/left...refs/heads/right"],"Canonical source range order")
        var options=HistoryOptions();options.revisionRange=owner.model.range!.history();let actual=try await repo.history(options:options);try require(actual.count==1 && actual.first?.subject=="right","Actual history range query")
        try invoke("Copy reference names");try require(copies.last=="refs/heads/left\nrefs/heads/right","Copy displayed canonical order")
        refreshMenu();try require(!menu.items.contains{$0.title=="Select" || $0.title=="Rename" || $0.title=="Delete branch"},"Multi selection leaked single-ref action")
        owner.model.descending=true;try await wait([owner.window!]){table.selectedRowIndexes.count==2 && (table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSTableCellView)?.textField?.stringValue==owner.model.rows.first?.name}
        try require(owner.model.range?.revision()==logs[0],"Sort changed range orientation")
        table.selectRowIndexes(IndexSet(integer:try row("refs/heads/right")),byExtendingSelection:false)
        table.selectRowIndexes(IndexSet(integer:try row("refs/heads/left")),byExtendingSelection:true)
        try invoke("Show log of right..left");try require(logs.last=="refs/heads/right..refs/heads/left","Reverse last-selected range")
        owner.model.query="left";owner.model.refilter();try await wait([owner.window!]){table.selectedRowIndexes.count==1}
        try require(owner.model.chosen?.name=="refs/heads/left","Filter retained visible selection")
        owner.model.query="";owner.model.refilter();try await wait([owner.window!]){table.numberOfRows==owner.model.rows.count}
        table.selectRowIndexes(IndexSet(integer:try row("refs/heads/right")),byExtendingSelection:false)
        refreshMenu();try require(!menu.items.contains{$0.title=="Select"},"Standalone offered picker Select")
        owner.model.activateSelection();try require(logs.last=="refs/heads/right" && closes==0 && !owner.model.closed,"Standalone double-click closed browser")
        table.selectRowIndexes(IndexSet(integer:try row("refs/misc/tree")),byExtendingSelection:false);owner.model.activateSelection();try require(browses==["refs/misc/tree"],"Tree double-click did not browse")
        owner.model.hasChild=true;let count=logs.count;owner.model.logRange(symmetric:false);owner.model.accept();try require(closes==0 && logs.count==count && !owner.windowShouldClose(owner.window!),"Owned child escaped gates");owner.model.hasChild=false
        let picker=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/main",preferences:prefs){_ in};defer {picker.close()}
        picker.model.load();try await wait([picker.window!]){!picker.model.busy && picker.model.snapshot != nil}
        try require(find(picker.window!.contentView!)?.allowsMultipleSelection==false,"Existing chooser became multiple")
        picker.model.select(["refs/heads/left","refs/heads/right"],last:"refs/heads/right");try require(picker.model.selection.count==1,"Chooser accepted multiple refs");picker.close()
        owner.model.selected=nil;try require(owner.model.canFinish,"Standalone cannot close empty selection");owner.model.accept();try require(closes==1 && owner.model.closed,"Standalone normal close did not complete once");owner.model.accept();try require(closes==1,"Duplicate completion")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head==after && index==Data(contentsOf:root.appendingPathComponent(".git/index")) && config==Data(contentsOf:root.appendingPathComponent(".git/config")) && file==Data(contentsOf:root.appendingPathComponent("file")),"Read-only browser changed repository")
        try require(NSApplication.shared.windows.allSatisfy{!$0.isVisible},"Displayed QA windows")
        print("PASS standalone multi-selection/range order/log queries/copy/filter/sort/double-click/empty-close/child gates and unchanged single-selection chooser")
    }
}
