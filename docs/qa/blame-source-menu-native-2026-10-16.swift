import AppKit
import TurtleGitCore

@main struct BlameSourceMenuVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame source menu timeout at \(line)")
    }
    @MainActor static func invoke(_ item:NSMenuItem) throws {
        guard let action=item.action,item.isEnabled else {throw Failure(description:"Source menu command disabled: "+item.title)}
        _ = NSApp.sendAction(action,to:item.target,from:item)
    }
    @MainActor static func main() async {do{try await verify()}catch{fputs("Blame source menu failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Source Menu QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let old="old 雪\n.cpp",path="new 雪\n.cpp",base="base "+String(repeating:"stable context ",count:20)
        try Data((base+"\nsnow 雪🦎\nlast\n").utf8).write(to:root.appendingPathComponent(old));try await repo.stage([old]);_ = try await repo.commit(message:"first source")
        let first=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["mv","--",old,path]);try Data((base+"\nchanged 雪🦎\nlast\n").utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"second rename")
        let second=try await repo.rebaseCommit("HEAD")
        try Data((base+"\nchanged 雪🦎\nlast third\n").utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"third source")
        let third=try await repo.rebaseCommit("HEAD"),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:root.appendingPathComponent(path))
        let suite="TurtleGit.BlameSourceMenu."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons");defer{prefs.removePersistentDomain(forName:suite)}
        let owner=BlameWindowController(repository:repo,access:nil,path:path,revision:third.hash,options:GitBlameOptions(),preferences:prefs),model=owner.model
        defer{owner.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        try await wait {!model.busy && !model.syntaxWorking && model.lines.count==3 && views(owner.window?.contentView).contains{($0 as? NSTextView)?.accessibilityLabel()=="Blame source text"}}
        guard let editor=views(owner.window?.contentView).compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel()=="Blame source text"}),let gutter=views(owner.window?.contentView).compactMap({$0 as? NSTableView}).first(where:{$0.tableColumns.contains{$0.identifier.rawValue=="original"}}) else {throw Failure(description:"Native annotations missing")}
        try require(model.lines[1].hash==second.hash && model.lines[0].hash==first.hash,"Fixture attribution differs")
        var presented:[NSMenuItem]=[],presentations=0,anchor:NSPoint = .zero
        model.presentSourceMenu={menu,point,_ in presented=menu.items;presentations += 1;anchor=point;menu.delegate?.menuDidClose?(menu)}
        var copied="",logs:[(String,String)]=[],previous:(String,String,Int,GitBlameOptions)?,comparison:RevisionComparisonSnapshot?,alternate:Bool?,patch:Data?
        model.writeClipboard={copied=$0};model.onLog={logs.append(($0,$1))};model.onPrevious={previous=($0,$1,$2,$3)}
        model.onChanges={comparison=$0;alternate=ComparisonToolInvocation.capture};model.onHistoryUnified={data,_,_ in patch=data}
        func item(_ title:String) throws -> NSMenuItem {guard let value=presented.first(where:{$0.title==title}) else {throw Failure(description:"Source menu item missing: "+title)};return value}
        func openSource() async throws {
            let count=presentations;editor.setSelectedRange((editor.string as NSString).range(of:"雪🦎"))
            try require(editor.accessibilityPerformShowMenu(),"Source AX menu request refused")
            try await wait {presentations==count+1 && !model.loadingParents}
        }
        try await openSource()
        try require(presented.filter{!$0.isSeparatorItem}.map(\.title)==["Blame previous revision","Compare with previous revision","Show changes as unified diff","Show log","Copy SHA-1 to clipboard","Copy log to clipboard","Copy source line","Copy","Select All"],"Source menu groups/labels differ")
        try require(presented.filter{!$0.isSeparatorItem && $0.title != "Select All"}.allSatisfy{$0.image != nil} && anchor.y>0,"Source artwork/keyboard anchor missing")
        let log=try item("Show log"),hash=try item("Copy SHA-1 to clipboard"),line=try item("Copy source line"),selection=try item("Copy"),details=try item("Copy log to clipboard"),prior=try item("Blame previous revision"),compare=try item("Compare with previous revision"),unified=try item("Show changes as unified diff"),all=try item("Select All")
        editor.setSelectedRange(NSRange(location:0,length:4));model.selection=1
        try invoke(log);try require(logs.count==1 && logs[0].0==path && logs[0].1==second.hash,"Captured Log followed new selection")
        try invoke(log);try require(logs.count==1,"Source Log dispatched twice")
        try invoke(hash);try require(copied==second.hash,"Captured hash changed");copied="sentinel";try invoke(hash);try require(copied=="sentinel","Used source hash wrote again")
        try invoke(line);try require(copied==model.lines[1].source,"Captured source line changed")
        try invoke(selection);try require(copied=="雪🦎","Source Copy lost captured Unicode selection")
        try invoke(prior);try require(previous?.0==old && previous?.1==first.hash && previous?.2==2 && previous?.3==model.appliedOptions,"Previous Blame lost parent/rename/original line/options")
        try ComparisonToolInvocation.$alternate.withValue(true) {try invoke(compare)}
        try require(alternate==true && comparison?.files.first?.oldPath==old && comparison?.files.first?.path==path,"Captured comparison lost rename/Shift")
        try invoke(unified);try await wait {patch != nil && BlameWindowModel.activeHistoryOperations==0}
        try require(String(decoding:patch!,as:UTF8.self).contains("+changed 雪🦎") && !String(decoding:patch!,as:UTF8.self).contains("+last third"),"Unified read used later revision or unrelated changes")
        try invoke(details);try await wait {!model.copyingLog && BlameWindowModel.activeHistoryOperations==0}
        try require(copied.contains(second.hash) && copied.contains("second rename"),"Captured full log copy used another commit")
        try invoke(all);try require(editor.selectedRange().length==(editor.string as NSString).length,"Select All no longer reaches native editor")
        prefs.set(false,forKey:"ShowAppContextMenuIcons");let count=presentations;editor.setSelectedRange(NSRange(location:0,length:1))
        try require(editor.accessibilityPerformShowMenu(),"Root AX request refused");try await wait {presentations==count+1}
        try require(!presented.contains{$0.title=="Blame previous revision"} && presented.allSatisfy{$0.image==nil},"Root exclusion/private icon preference differs")
        prefs.set(true,forKey:"ShowAppContextMenuIcons")
        gutter.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:109)!
        let beforeKey=presentations;gutter.keyDown(with:key);try await wait {presentations==beforeKey+1};let thirdLog=try item("Show log");try invoke(thirdLog)
        try require(logs.last?.1==third.hash,"Gutter keyboard context used pointer/source selection")
        let beforeEditor=presentations;editor.keyDown(with:key);try await wait {presentations==beforeEditor+1}
        model.busy=true;try require(!editor.accessibilityPerformShowMenu() && !gutter.accessibilityPerformShowMenu(),"Busy annotation accepted keyboard/AX menu");model.busy=false
        try await openSource();let stale=try item("Show log"),target=model.sourceTarget(number:2)!
        let foreign=BlameWindowModel(repository:repo,access:nil,path:path,revision:third.hash,labelDefaults:prefs);defer{foreign.retire()};try require(!foreign.acceptsSource(target),"Foreign source target accepted")
        model.reload();try await wait {!model.busy && !model.syntaxWorking};let beforeStale=logs.count;try invoke(stale);try require(logs.count==beforeStale && !model.acceptsSource(target),"Reload revived source menu")
        try await openSource();let retired=try item("Copy SHA-1 to clipboard");copied="retired";owner.close();try invoke(retired)
        try require(copied=="retired" && !editor.accessibilityPerformShowMenu() && !gutter.accessibilityPerformShowMenu(),"Closed source accepted menu/clipboard")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent(path)))==bytes,"Source menu workflow changed repository")
        print("PASS: native Blame source captured Log/hash/source/UTF16 Copy/detail/parent/rename/alternate/unified actions, one-use items, source labels and private icons, gutter/editor Shift-F10 and AX routing, root/busy/foreign/reloaded/retired gates and unchanged HEAD/index/working bytes; owned windows closed")
    }
}
