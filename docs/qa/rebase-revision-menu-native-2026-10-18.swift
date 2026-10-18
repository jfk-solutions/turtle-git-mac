// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RebaseRevisionMenuVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2200 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Rebase revision menu did not settle at \(line)")
    }
    static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    static func click(_ item:NSMenuItem) throws {guard let action=item.action else {throw Failure(description:"Missing action "+item.title)};_ = NSApp.sendAction(action,to:item.target,from:item)}
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","Revision Menu QA"),("user.email","menu@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        func commit(_ path:String) async throws {try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:path)}
        try await commit("base")
        _ = try await repo.run(["switch","-c","upstream"]);try await commit("upstream")
        _ = try await repo.run(["switch","-c","side","main"]);try await commit("side")
        _ = try await repo.run(["switch","-c","topic","main"]);try await commit("first");try await commit("second")
        _ = try await repo.run(["merge","--no-ff","--no-edit","side"])
        let merge=try await repo.rebaseCommit("HEAD"),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let domain="TurtleGit.RebaseRevisionMenu.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:domain)!
        defer {prefs.removePersistentDomain(forName:domain)}
        prefs.set(true,forKey:"DiffByDoubleClickInLog")
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        model.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3])
        model.load(upstream:"refs/heads/upstream",preserveMerges:true)
        var table:RebaseReplayNativeTable?
        try await wait {table=views(window.contentView!).compactMap{$0 as? RebaseReplayNativeTable}.first;return !model.busy && !model.loadingPlan && table?.numberOfRows==4 && RebaseWindowModel.activePreparationReads==0}
        let native=table!,coordinator=native.owner!
        func select(_ ids:Set<String>) async throws {
            model.selection=ids
            try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0 && model.revisionMenuAvailable && Set(native.selectedRowIndexes.map{model.entries[$0].id})==ids}
        }
        func popup()->NSMenu {coordinator.menu(ids:model.selection,alternate:false)}
        func actions(_ menu:NSMenu)->[String] {menu.items.prefix(while:{!$0.isSeparatorItem}).map(\.title)}
        let oldest=model.entries.last!.id,ordinary=model.entries.first{$0.commit.parents.count==1 && $0.id != oldest}!.id
        try await select([ordinary]);try require(actions(popup())==["Pick","Squash","Edit","Skip"],"Source action insertion order missing")
        try await select([oldest]);try require(actions(popup())==["Pick","Edit","Skip"],"Oldest row exposed Squash")
        try await select([ordinary,oldest]);try require(actions(popup())==["Pick","Edit","Skip"],"Selection containing oldest exposed Squash")
        try await select([merge.hash]);try require(actions(popup())==["Pick","Edit","Skip"],"Ordinary merge exposed Squash")
        model.options.isCherryPick=true;try require(actions(popup())==["Pick","Squash","Edit","Skip"],"Cherry Pick merge lost source exception");model.options.isCherryPick=false
        var pairs:[(ComparisonRevision,ComparisonRevision,Bool)]=[]
        model.revisionMenuLog.onCompare={pairs.append(($0,$1,ComparisonToolInvocation.alternate ?? false))}
        let menu=coordinator.menu(ids:model.selection,alternate:true)
        let parents=menu.item(withTitle:"Compare with previous revision")!.submenu!
        try require(parents.items.count==2 && parents.items[0].attributedTitle != nil,"Merge parents/default emphasis missing")
        try click(parents.items[1]);try require(pairs.count==1 && pairs[0].0 == .revision(merge.parents[1]) && pairs[0].1 == .revision(merge.hash) && pairs[0].2,"Parent comparison lost captured canonical target/Shift")
        try click(parents.items[0]);try require(pairs.count==1,"Second parent reused consumed popup")
        var patches:[Data]=[],alternates:[Bool]=[]
        model.revisionMenuLog.onUnifiedDiff={bytes,alternate in patches.append(bytes);alternates.append(alternate)}
        let modes:[LogRevisionDiffMode]=[.allParents,.combined,.extraMergeChanges,.parent(1),.parent(2)]
        var opened = 0
        for (number,mode) in modes.enumerated() {
            let unified=coordinator.menu(ids:model.selection,alternate:true).item(withTitle:"Unified diff with")!.submenu!
            try require(unified.items.count==5,"Unified merge mode family incomplete")
            try click(unified.items[number]);try await wait {!model.revisionMenuLog.busy}
            let expected=try await repo.revisionDiffData(merge,mode:mode)
            if mode == .extraMergeChanges, String(decoding:expected,as:UTF8.self).split(separator:"\n").count <= 1 {
                try require(patches.count==opened && model.revisionMenuLog.navigationNotice=="No extra changes after merge.","Clean remerge did not preserve no-extra-changes result")
            } else {
                opened += 1
                try require(patches.count==opened && patches.last==expected && alternates.last==true,"Unified mode \(number) mismatch: received \(patches.count), expected opens \(opened), actual bytes \(patches.last?.count ?? -1), expected bytes \(expected.count), alternate \(String(describing:alternates.last)), error \(model.revisionMenuLog.error ?? "none")")
            }
        }
        try await select([ordinary]);let stale=popup().item(withTitle:"Edit")!;let previous=model.options.force
        model.options.force = !previous;model.options.force=previous;try click(stale)
        try require(model.entries.first{$0.id==ordinary}?.action == .pick,"Option away/return revived popup")
        let away=popup().item(withTitle:"Edit")!;try await select([oldest]);try await select([ordinary]);try click(away)
        try require(model.entries.first{$0.id==ordinary}?.action == .pick,"Selection away/return revived popup")
        let edit=popup().item(withTitle:"Edit")!;try click(edit);try click(edit)
        try require(model.entries.first{$0.id==ordinary}?.action == .edit,"Native Edit did not update exact occurrence")
        model.setAction(.pick,ids:[ordinary])
        var shown=0
        native.presentContextMenu={ [weak native] menu,point,view in if let native, !menu.items.isEmpty && view === native && native.visibleRect.contains(point) {shown += 1}}
        try require(native.accessibilityPerformShowMenu() && shown==1,"AX selected-row popup missing")
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:121)!
        native.keyDown(with:event);try require(shown==2,"Shift F10 did not open selected-row popup")
        let before=pairs.count
        try require(coordinator.performDefaultComparison(),"Default compare refused eligible selection")
        try require(pairs.count==before+1,"Default comparison not dispatched")
        prefs.set(false,forKey:"DiffByDoubleClickInLog");try require(!coordinator.performDefaultComparison(),"Default comparison ignored preference")
        prefs.set(false,forKey:"ShowAppContextMenuIcons")
        func hasImages(_ menu:NSMenu)->Bool {menu.items.contains{$0.image != nil || ($0.submenu.map(hasImages) ?? false)}}
        try require(!hasImages(popup()),"Nested menu ignored private icon preference")
        let held=popup().item(withTitle:"Edit")!;model.revisionMenuLog.confirmingQuit=true;try click(held)
        try require(model.entries.first{$0.id==ordinary}?.action == .pick,"Quit accepted captured menu");model.revisionMenuLog.confirmingQuit=false
        // Current/completed occurrence gates survive even a malformed choosing draft.
        var draft=model.plan!;let row=draft.entries.firstIndex{$0.id==ordinary}!
        draft.entries[row].progress = .current;model.plan=draft
        try require(!popup().items.contains{$0.title=="Pick" || $0.title=="Skip" || $0.title=="Edit" || $0.title=="Squash"},"Current row exposed draft actions")
        model.setAction(.skip,ids:[ordinary]);try require(model.entries.first{$0.id==ordinary}?.action == .pick,"Current row action changed")
        draft.entries[row].progress = .completed;model.plan=draft;try require(model.revisionActionChoices([ordinary]).isEmpty,"Completed row exposed actions")
        draft.entries[row].progress = .pending;model.plan=draft
        let retired=popup().item(withTitle:"Edit")!;owner.close();try click(retired)
        try await wait {RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activePreparationReads==0}
        try require(model.retired && model.entries.first{$0.id==ordinary}?.action == .pick,"Retired popup changed plan")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Menu changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Menu changed index")
        print("PASS: source Rebase revision actions, current/done/oldest/merge gates, parent and all unified modes, private icons/default preference, AX/Shift F10 and one-use/stale/Quit/retired menus; HEAD/index preserved")
    }
}
