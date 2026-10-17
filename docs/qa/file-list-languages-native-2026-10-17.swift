import AppKit
import TurtleGitCore

struct FileListLanguagesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func descendants(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap {descendants($0)}}
    @MainActor static func wait(_ window:NSWindow?,line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"File-list language wait at \(line)")
    }
    @MainActor static func probe(_ window:NSWindow)->CommitFileInteraction.Probe? {
        descendants(window.contentView).compactMap {$0 as? CommitFileInteraction.Probe}.first
    }
    @MainActor static func checkColumns(_ window:NSWindow,aliases:[String:StatusListColumn] = [:]) async throws {
        try await wait(window) {probe(window)?.enabled==true}
        let adapter=probe(window)!;adapter.configureColumns()
        guard let table=descendants(window.contentView).compactMap({$0 as? NSTableView}).first(where:{$0.tableColumns.count==adapter.nativeColumns.count+adapter.leadingColumnCount}) else {throw Failure(description:"Missing file table")}
        for (index,column) in table.tableColumns.enumerated() {
            guard let expected=FileListLabels.column(named:column.title) ?? aliases.first(where:{NSLocalizedString($0.key,comment:"")==column.title})?.value,adapter.nativeColumns.contains(expected) else {continue}
            try require(adapter.columnDefinition(atNativeIndex:index)==expected,"Localized header retargeted column: \(column.title)")
        }
        let menu=adapter.columnMenu()
        guard let status=menu.items.first(where:{$0.tag==StatusListColumn.allCases.firstIndex(of:.status) && !$0.isSeparatorItem}) else {throw Failure(description:"Missing semantic status column menu")}
        try require(status.title==FileListLabels.caption("Status") && status.isEnabled,"Column menu did not localize")
        let before=adapter.visibleColumns.contains(.status)
        try require(NSApp.sendAction(status.action!,to:status.target,from:status),"Column toggle not dispatched")
        try await wait(window) {probe(window)?.visibleColumns.contains(.status) == !before}
        let restore=adapter.columnMenu().items.first {$0.tag==StatusListColumn.allCases.firstIndex(of:.status) && !$0.isSeparatorItem}!
        try require(NSApp.sendAction(restore.action!,to:restore.target,from:restore),"Column restore not dispatched")
        try await wait(window) {probe(window)?.visibleColumns.contains(.status)==before}
    }
    @MainActor static func checkGroups(_ window:NSWindow) async throws {
        try await wait(window) {
            let titles=descendants(window.contentView).compactMap {$0 as? FileListGroupHeaders}.flatMap { $0.headings.map(\.title) }
            return titles.contains(FileListLabels.groupTitle(.modified)) && titles.contains(FileListLabels.groupTitle(.unversioned)) && titles.contains("Modified Files")
        }
        let titles=descendants(window.contentView).compactMap {$0 as? FileListGroupHeaders}.flatMap {$0.headings.map(\.title)}
        if Bundle.main.preferredLocalizations.first=="en" {try require(titles.filter {$0=="Modified Files"}.count==2,"English builtin/changelist groups lost their separate slots")}
    }
    @MainActor static func checkCommitSelection(_ owner:CommitWindowController) async throws {
        let window=owner.window!,model=owner.model,main=NSMenu(title:"Private language commands"),windows=NSMenu(title:"Semantic window owner")
        let previous=NSApp.windowsMenu;NSApp.windowsMenu=windows;defer {NSApp.windowsMenu=previous}
        let windowItem=NSMenuItem(title:"Independent window label",action:nil,keyEquivalent:"");windowItem.submenu=windows;main.addItem(windowItem)
        let commands=owner.commandMenu!,previousMenu=commands.applicationMenu,previousKey=commands.keyWindow
        commands.applicationMenu={main};commands.keyWindow={window};commands.install()
        defer {commands.remove();commands.applicationMenu=previousMenu;commands.keyWindow=previousKey}
        guard let root=main.items.first(where:{$0.identifier?.rawValue=="TurtleGit.Commit.Commands"}),let menu=root.submenu else {throw Failure(description:"Missing localized Commit menu")}
        try require(main.index(of:root)<main.index(of:windowItem) && root.title==NSLocalizedString("Commit",comment:""),"Localized root lost semantic Window placement")
        guard let check=menu.items.first(where:{$0.title==NSLocalizedString("Check files",comment:"")})?.submenu else {throw Failure(description:"Missing translated Check files group")}
        for key in ["All","None"] {
            let shift=NSEvent.modifierFlags.contains(.shift),checking=key == "None" ? shift:!shift
            guard let item=check.items.first(where:{$0.title==NSLocalizedString(key,comment:"")}) else {throw Failure(description:"Missing translated selection action")}
            try require(commands.validateMenuItem(item) && item.image != nil,"Selection caption lost action/icon availability")
            try require(NSApp.sendAction(item.action!,to:item.target,from:item),"Translated selection action did not dispatch")
            try await wait(window) {model.checkedPathsForCommit.count == (checking ? model.visibleEntries.count:0)}
        }
        model.check({$0.path=="Modified"},checking:true)
        try await wait(window) {model.checkedPathsForCommit.count==1}
        let one=FileListLabels.selectionSummary(checked:model.checkedPathsForCommit.count,shown:model.visibleEntries.count)
        try require(!one.contains("{") && one.contains("1") && one.contains("3"),"Selected-file count fields missing")
        model.checkAll(false)
    }
    @MainActor static func verify() async throws {
        let locale=CommandLine.arguments[1]
        try require(Bundle.main.preferredLocalizations.first==locale,"Wrong process locale")
        if locale=="de" {
            try require(FileListLabels.caption("Renamed")=="umbenannt" && FileListLabels.caption("Untracked")=="unversioniert","Reviewed source aliases missing")
            try require(FileListLabels.caption("Modified (staged)")=="Verändert (vorgemerkt)","Composed staged caption missing")
        }
        for name in ["Modified Files","Not Versioned Files","cafe\u{301}","café","ignore-on-commit"] {
            try require(FileListLabels.groupTitle(.changelist(name)).utf8.elementsEqual(name.utf8),"Localized a user changelist")
        }
        if locale != "en" {try require(FileListLabels.groupTitle(.modified) != StatusListGroup.modified.title,"Builtin group bypassed source catalog")}
        for (checked,shown) in [(0,0),(1,1),(1,3),(3,1),(3,3)] {
            let caption=FileListLabels.selectionSummary(checked:checked,shown:shown)
            try require(!caption.contains("{") && caption.contains(String(checked)) && caption.contains(String(shown)),"Selection summary field loss")
        }
        for count in [0,1,3] {try require(!FileListLabels.stagingSummary(staged:2,unstaged:count).contains("{"),"Staging summary field loss")}
        for untouched in ["cafe\u{301}/Modified", "refs/heads/Status", "Modified (staged) suffix", "server %s diagnostic"] {
            try require(FileListLabels.caption(untouched).utf8.elementsEqual(untouched.utf8),"Unknown caption changed")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitFileLanguages-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.FileLanguages."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard.withUniqueName()
        defer {NSApp.windows.forEach {$0.close()};board.releaseGlobally();prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        prefs.set(true,forKey:"AddBeforeCommit")
        let repo=GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/git"))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Language QA"),("user.email","language@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        for name in ["Modified","old"] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["Modified","old"]);_=try await repo.commit(message:"source")
        try Data("changed\n".utf8).write(to:root.appendingPathComponent("Modified"))
        _=try await repo.run(["mv","--","old","Renamed"])
        try Data("new\n".utf8).write(to:root.appendingPathComponent("Untracked"))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout,config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let status=StatusWindowController(repository:repo,access:nil,defaults:prefs),statusWindow=status.window!
        statusWindow.alphaValue=0;statusWindow.orderFront(nil);status.model.reload()
        try await wait(statusWindow) {!status.model.busy && status.model.visibleFiles.count==3}
        status.model.changelists=GitChangelists(assignments:["Modified":"Modified Files"])
        try await checkGroups(statusWindow)
        for row in status.model.tableRows.compactMap(\.contents) {
            try require(status.model.columnText(row,.path)==StatusListClipboard.displayedPath(row.file.entry),"Translated a working path")
            try require(status.model.columnText(row,.status)==FileListLabels.caption(status.model.showsStagedStatus ? row.status:row.file.status),"Working status cell bypassed catalog")
        }
        let packet=status.model.clipboardText(GitPathSet(["Modified"]),copy:.pathsAndStatus)
        try require(packet.contains("\nModified\t"+FileListLabels.caption("Modified")),"Working clipboard changed path or lost translated status")
        try await checkColumns(statusWindow)
        let footer=descendants(statusWindow.contentView).compactMap {$0 as? NSTextField}.first {$0.accessibilityLabel()==NSLocalizedString("Working Tree statistics",comment:"")}!
        try await wait(statusWindow) {footer.stringValue==status.model.summary && footer.toolTip==status.model.nativeSummary}
        try require(!footer.isEditable && footer.isSelectable && !footer.stringValue.contains("{"),"Localized footer lost fields or readonly selection")
        if locale=="de" {try require(footer.stringValue.hasPrefix("Zeilen:") && footer.toolTip?.contains("Dateien angezeigt")==true,"Footer/tooltip bypassed translated count template")}
        if locale=="fr" {try require(footer.stringValue.hasPrefix("lignes :"),"French footer bypassed count template")}
        if locale=="de" {try await LanguageFamilyVerification.capture(statusWindow,name:"working-file-groups")}
        status.close()
        let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs),commitWindow=commit.window!
        commitWindow.alphaValue=0;commitWindow.orderFront(nil);commit.model.reload()
        try await wait(commitWindow) {!commit.model.busy && commit.model.visibleEntries.count==3 && probe(commitWindow)?.enabled==true}
        guard let modified=commit.model.visibleEntries.first(where:{$0.path=="Modified"}) else {throw Failure(description:"Missing literal Modified path")}
        try require(probe(commitWindow)!.columnText(modified,.status)==FileListLabels.caption("Modified"),"Commit displayed cell bypassed catalog")
        try require(probe(commitWindow)!.columnText(modified,.path)=="Modified","Commit translated literal path")
        commit.model.changelists=GitChangelists(assignments:["Modified":"Modified Files"])
        try await checkGroups(commitWindow)
        try await checkColumns(commitWindow)
        try await checkCommitSelection(commit)
        if locale=="de" {try await LanguageFamilyVerification.capture(commitWindow,name:"commit-file-groups")}
        commit.close()
        let comparison=RevisionComparisonWindowController(repository:repo,access:nil,from:.revision("HEAD"),to:.workingTree,preferences:prefs),comparisonWindow=comparison.window!
        comparison.model.clipboard=board;comparisonWindow.alphaValue=0;comparisonWindow.orderFront(nil);comparison.model.load()
        try await wait(comparisonWindow) {!comparison.model.busy && !comparison.model.visibleFiles.isEmpty && probe(comparisonWindow)?.enabled==true}
        let file=comparison.model.visibleFiles.first {$0.path=="Modified"}!
        try require(comparison.model.fileText(file,column:.status)==FileListLabels.caption(file.status),"Comparison cell bypassed catalog")
        comparison.model.copyColumn([file.id],column:.status)
        try require(board.string(forType:.string)==FileListLabels.caption(file.status),"Comparison column clipboard bypassed catalog")
        comparison.model.copyPaths([file.id],extended:true)
        try require(board.string(forType:.string)?.hasPrefix("Modified\t\t"+FileListLabels.caption(file.status))==true,"Comparison extended clipboard translated a path or lost status")
        try await checkColumns(comparisonWindow,aliases:["File":.path,"Action":.status]);comparison.close()
        let add=AddWindowController(repository:repo,access:nil,defaults:prefs),addWindow=add.window!
        addWindow.alphaValue=0;addWindow.orderFront(nil);add.model.reload()
        try await wait(addWindow) {!add.model.busy && !add.model.entries.isEmpty && descendants(addWindow.contentView).contains {$0 is NSTableView}}
        let table=descendants(addWindow.contentView).compactMap {$0 as? NSTableView}.first!
        try require(table.tableColumns.first(where:{$0.identifier.rawValue=="date"})?.title==NSLocalizedString("Modification date",comment:""),"Add native header bypassed catalog")
        try require(table.tableColumns.first(where:{$0.identifier.rawValue=="path"})?.title==FileListLabels.caption("Path"),"Add path header bypassed catalog")
        add.close()
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"Display/columns mutated Git index/config")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head,"Display mutated HEAD")
        print("PASS language file lists \(locale): actual Working Tree/Commit/Comparison cells and column identity/toggles, source aliases, staged composition, literal paths, private clipboard, native Add headers and HEAD/index/config preservation; localized builtin groups/literal changelists, named counters, translated selection menu/icon/actions and semantic Window placement; owned windows closed")
    }
}
