// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietCommitPresentationOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-22000,y:-22000));quietCommitPresentationOrder(mode,relativeTo:number)
    }
    @objc func quietCommitPresentationSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-22000,y:-22000));quietCommitPresentationSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main struct CommitPresentationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ value:NSView?)->[NSView] {guard let value else{return []};return [value]+value.subviews.flatMap{views($0)}}
    static func wait(_ owner:CommitWindowController?,_ message:String,_ predicate:()->Bool)async throws {
        for _ in 0..<2000 {owner?.window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:message)
    }
    static func drained()->Bool {CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 && PatchWindowModel.activeOperations==0}
    static func ready(_ owner:CommitWindowController)async throws {
        let m=owner.model
        try await wait(owner,"Commit presentation did not settle: \(m.error ?? "none")") {!m.busy && !m.savingPreferences && !m.fileWorkPending && !m.stagingStateNeedsRefresh && m.commitIdentityPrepared && m.changelistsLoaded && !m.loadingAuthorIdentity && !m.loadingAuthorDate && !m.loadingAmendMessage && !m.mergeHintVisible && !m.stagingHintVisible && m.guiPatch?.busy != true}
        try require(m.error==nil,"Commit operation error: "+(m.error ?? "none"))
    }
    @MainActor final class Context {
        let root:URL,repository:GitRepository,preferences:UserDefaults,suite:String
        let partial="part 雪\t[*].txt",other="other.txt",new="-new 🦎.txt",deleted="gone.txt"
        var owners:[CommitWindowController]=[],menus:[NSMenu]=[]
        var base=Data(),staged=Data(),working=Data(),head=Data(),otherIndex=Data()
        init(root:URL,git:URL)throws {
            self.root=root;repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.CommitPresentation."+UUID().uuidString;preferences=try unwrap(UserDefaults(suiteName:suite),"No private preferences")
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","TurtleGit.Commit.GitGuiInterface","AddBeforeCommit","ShowAppContextMenuIcons"] {preferences.set(true,forKey:key)}
            for key in ["EnableGravatar","SelectFilesForCommit","UseLibgit2"] {preferences.set(false,forKey:key)}
        }
        func setup()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Presentation QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","true"),("bugtraq.label","Issue number:"),("bugtraq.message","Issue: %BUGID%")]{_=try await repository.run(["config",key,value])}
            base=Data((1...32).map{"base \($0)\n"}.joined().utf8)
            staged=Data(String(decoding:base,as:UTF8.self).replacingOccurrences(of:"base 2\n",with:"staged 2\n").utf8)
            working=Data(String(decoding:staged,as:UTF8.self).replacingOccurrences(of:"base 30\n",with:"working 30\n").utf8)
            for(path,bytes)in [(partial,base),(other,Data("other base\n".utf8)),(deleted,Data("separate deleted source\n".utf8))]{try bytes.write(to:root.appendingPathComponent(path))}
            try await repository.stage([partial,other,deleted]);_=try await repository.commit(message:"Presentation fixture")
            try staged.write(to:root.appendingPathComponent(partial));try await repository.stage([partial]);try working.write(to:root.appendingPathComponent(partial))
            try Data("other staged sentinel\n".utf8).write(to:root.appendingPathComponent(other));try await repository.stage([other])
            try Data("new literal file\n".utf8).write(to:root.appendingPathComponent(new));try FileManager.default.removeItem(at:root.appendingPathComponent(deleted))
            head=try await repository.run(["rev-parse","HEAD"]).stdout;otherIndex=try await repository.run(["show",":"+other]).stdout
        }
        func open()async throws->CommitWindowController {
            let owner=CommitWindowController(repository:repository,access:nil,defaults:preferences);owners.append(owner)
            owner.showWindow(nil);owner.model.reload(paths:["."]);try await ready(owner)
            let menu=NSMenu(title:"Private Commit menu");menus.append(menu)
            let router=try unwrap(owner.commandMenu,"Missing actual Commit command menu")
            router.applicationMenu={menu};router.keyWindow={ [weak owner] in owner?.window};router.install()
            return owner
        }
        func clean()async {
            for owner in owners {owner.model.message="";owner.close()}
            for _ in 0..<2000 {if drained() && owners.allSatisfy({!$0.model.fileWorkPending}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite)
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Presentation workflow changed HEAD")
            try require(try await repository.run(["show",":"+other]).stdout==otherIndex,"Selected staging changed unrelated index bytes")
            try require(try Data(contentsOf:root.appendingPathComponent(partial))==working,"Presentation workflow changed working bytes")
        }
    }
    static func items(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map{items($0)} ?? [])}}
    static func item(_ c:Context,_ owner:CommitWindowController,_ name:String)throws->NSMenuItem {
        owner.commandMenu?.install()
        return try unwrap(c.menus.flatMap{items($0)}.last{$0.identifier?.rawValue=="TurtleGit.Commit.Form."+name},"Missing actual Commit menu command "+name)
    }
    static func press(_ c:Context,_ owner:CommitWindowController,_ name:String)async throws {
        try await wait(owner,"Commit command not enabled: "+name){owner.commandMenu?.install();return (try? item(c,owner,name).isEnabled)==true}
        let value=try item(c,owner,name),action=try unwrap(value.action,"Menu command has no action")
        try require(NSApp.sendAction(action,to:value.target,from:value),"Actual menu dispatch failed")
    }
    static func field(_ owner:CommitWindowController,_ name:String)->NSTextField? {views(owner.window?.contentView).compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue==name && !$0.isHiddenOrHasHiddenAncestor}}
    static func edit(_ field:NSTextField,_ text:String)throws {
        try require(field.isEnabled && field.isEditable,"Native field is not editable: "+(field.identifier?.rawValue ?? "none"))
        field.stringValue=text;field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
    }
    static func key(_ owner:CommitWindowController,_ text:String,_ flags:NSEvent.ModifierFlags)throws->Bool {
        let window=try unwrap(owner.window,"No owned window")
        let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"No local key event")
        return window.performKeyEquivalent(with:event)
    }
    static func select(_ owner:CommitWindowController,_ paths:[String],staged:Bool)async throws {
        try await ready(owner)
        let m=owner.model,snapshot=m.guiFileListSnapshot(staged:staged),wanted=GitPathSet(paths)
        // Registration is the production weak probe; never recursively choose
        // the embedded patch table or a detached opposite-side table.
        m.selectGuiFiles(Set(paths),staged:staged)
        try await wait(owner,"GUI native table not registered"){owner.fileTable() != nil}
        let table=try unwrap(owner.fileTable(),"Missing exact active GUI table")
        try await wait(owner,"GUI rows did not render"){table.numberOfRows==snapshot.entries.count}
        let indexes=IndexSet(snapshot.entries.indices.filter{wanted.contains(snapshot.entries[$0].id)})
        try require(indexes.count==wanted.count,"Requested native paths are absent")
        table.deselectAll(nil);table.selectRowIndexes(indexes,byExtendingSelection:false)
        try await ready(owner)
        try require(m.guiStaged==staged && m.selection==wanted,"Native GUI selection did not retain exact selected paths")
        try require(m.guiPatch.map{!$0.busy && $0.staged==staged && GitPathSet($0.paths)==wanted}==true,"Selected native files have stale/wrong-side details")
        try require(table.tableColumns.map{$0.headerCell.stringValue}.contains("Path"),"Native file table has no Path header")
    }
    static func space(_ owner:CommitWindowController) throws {
        let window=try unwrap(owner.window,"No owned Space event window"),table=try unwrap(owner.fileTable(),"No active GUI file table")
        let probe=try unwrap(views(window.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.nativeTable === table},"Active GUI table lacks its actual interaction probe")
        try require(probe.keyboardCheckWithoutColumn && probe.leadingColumnCount==0,"GUI Space adapter still requires a Classic checkbox column")
        try require(window.makeFirstResponder(table),"GUI file table refused native focus")
        let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49),"No local Space event")
        // Observe is the production local-monitor entry point. No desktop
        // injection or direct staging callback substitutes for this key route.
        try require(probe.observe(event)==nil,"GUI native Space route was not consumed")
        try require(owner.model.busy,"GUI Space route did not admit selected-path work")
    }
    static func form(_ c:Context,_ owner:CommitWindowController)async throws {
        let m=owner.model
        try require(m.gitGuiInterface,"Fixture did not start in GUI mode")
        try await wait(owner,"GUI destination field missing"){field(owner,"Commit destination")?.stringValue=="main"}
        try await press(c,owner,"newBranch")
        try await wait(owner,"GUI new branch field missing"){field(owner,"Commit new branch")?.isEditable==true}
        try edit(try unwrap(field(owner,"Commit new branch"),"No branch control"),"topic/雪-native")
        try require(m.newBranch=="topic/雪-native","Native new-branch delegate did not update draft")
        try await press(c,owner,"author");try await ready(owner)
        try await wait(owner,"GUI author field not editable"){field(owner,"Commit author")?.isEditable==true}
        try edit(try unwrap(field(owner,"Commit author"),"No author control"),"Native Author <native@example.invalid>")
        try require(m.author=="Native Author <native@example.invalid>","Native author delegate did not update draft")
        try await press(c,owner,"authorDate");try await ready(owner)
        try await wait(owner,"GUI native author date/time controls missing"){views(owner.window?.contentView).compactMap{$0 as? NSDatePicker}.filter{$0.isEnabled}.count==2}
        let picker=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSDatePicker}.first{$0.identifier?.rawValue=="Commit author date"},"No date control")
        let previousDate=m.authorDate
        picker.dateValue=Date(timeIntervalSince1970:1_700_000_000)
        try require(NSApp.sendAction(try unwrap(picker.action,"No date action"),to:picker.target,from:picker),"Native date action failed")
        try require(m.authorDate != previousDate,"Native date action did not update the shared author date")
        let date=m.authorDate
        try await wait(owner,"GUI issue field missing"){field(owner,"Commit issue")?.isEditable==true}
        try edit(try unwrap(field(owner,"Commit issue"),"No issue control"),"12345")
        try require(m.issueID=="12345","Native issue field did not update draft")
        let editor=try unwrap(owner.messageEditor(),"No GUI native message editor")
        owner.window?.makeFirstResponder(editor);editor.setSelectedRange(NSRange(location:0,length:editor.string.utf16.count));editor.insertText("Private presentation draft 雪",replacementRange:editor.selectedRange())
        try require(m.message=="Private presentation draft 雪","Actual native message typing did not update draft")
        let author=m.author,branch=m.newBranch,message=m.message,issue=m.issueID
        for gui in [false,true] {
            let oldReceipt=m.formReceipt,oldBranch=field(owner,"Commit new branch"),oldAuthor=field(owner,"Commit author"),oldAuthorDelegate=field(owner,"Commit author")?.delegate
            m.setCommitInterface(gui);try await ready(owner)
            try await wait(owner,"Recreated native fields missing after layout switch"){field(owner,"Commit new branch") != nil && field(owner,"Commit author") != nil && field(owner,"Commit issue") != nil}
            try require(m.createBranch && m.setAuthor && m.setAuthorDate && m.newBranch==branch && m.author==author && m.authorDate==date && m.issueID==issue && m.message==message,"Switching Classic/GUI lost shared commit options/draft")
            try require(field(owner,"Commit new branch")?.stringValue==branch && field(owner,"Commit author")?.stringValue==author && field(owner,"Commit issue")?.stringValue==issue,"Native controls no longer match retained shared draft")
            try require(!m.acceptsFormReceipt(oldReceipt),"Presentation switch retained obsolete form authority")
            m.setFormOption(.author,value:false,receipt:oldReceipt);m.addSignOff(receipt:oldReceipt)
            try require(m.setAuthor && m.message==message,"Obsolete presentation receipt changed options/message")
            // Destination controls are intentionally shared outside the layout
            // conditional. A retained, attached field must remain editable.
            if let oldBranch,oldBranch === field(owner,"Commit new branch"),oldBranch.window === owner.window {
                try edit(oldBranch,"retained-layout-雪")
                try require(m.newBranch=="retained-layout-雪","Retained shared destination stopped accepting live edits")
                try edit(oldBranch,branch)
            }
            // Conditional metadata belongs to its actual native attachment,
            // not merely the layout that happened to create it.
            if let oldAuthor,oldAuthor !== field(owner,"Commit author") {
                oldAuthor.stringValue="Obsolete <old@example.invalid>"
                oldAuthorDelegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:oldAuthor))
                try require(m.author==author,"Detached metadata field delegate changed the retained draft")
            }
            try require(m.newBranch==branch && m.author==author && m.message==message,"Ownership probes did not restore the shared draft")
        }
        try require(c.preferences.bool(forKey:"TurtleGit.Commit.GitGuiInterface"),"GUI interface preference was not retained")
        // The real command router and local window shortcut remain active in GUI.
        for name in ["current","commit","recommit","push","author","authorDate","newBranch","focusFiles","signOff","all","none"] {try require(try item(c,owner,name).image != nil,"Actual GUI command lacks icon: "+name)}
        for name in ["staging","patch","partialStage","partialUnstage"] {try require(!c.menus.flatMap{items($0)}.contains{$0.identifier?.rawValue=="TurtleGit.Commit.Form."+name},"GUI exposes Classic-only command: "+name)}
        let checked=try ["newBranch","author","authorDate"].map{try item(c,owner,$0).state}
        try require(checked.allSatisfy{$0 == .on},"GUI Commit menu lost live checked option state")
        try require(try item(c,owner,"commit").isEnabled,"Valid GUI draft has no enabled Commit command")
        m.message="";owner.commandMenu?.install()
        let emptyCommit=try item(c,owner,"commit").isEnabled,emptyCurrent=try item(c,owner,"current").isEnabled
        try require(!emptyCommit && !emptyCurrent,"Empty GUI message left committing commands enabled")
        m.message=message;try await ready(owner)
        try await select(owner,[c.partial],staged:false)
        owner.window?.makeFirstResponder(nil)
        try require(try key(owner,"f",[.command,.option]),"GUI native file focus shortcut not handled")
        try await wait(owner,"GUI shortcut did not focus active file table"){owner.window?.firstResponder === owner.fileTable()}
        try require(try key(owner,"m",[.command,.option]),"GUI native message-focus shortcut not handled")
        try await wait(owner,"GUI message shortcut did not focus actual message editor"){owner.window?.firstResponder === owner.messageEditor()}
        let old=try item(c,owner,"newBranch"),branchState=m.createBranch
        m.confirmingQuit=true;owner.commandMenu?.install()
        if let action=old.action {_ = NSApp.sendAction(action,to:old.target,from:old)}
        try require(m.createBranch==branchState,"Stale GUI menu changed state while Quit owned form")
        m.confirmingQuit=false;try await ready(owner)
        try await select(owner,[c.partial],staged:false)
        try await geometry(owner)
    }
    static func geometry(_ owner:CommitWindowController)async throws {
        let window=try unwrap(owner.window,"No GUI geometry owner")
        for height in [680.0,760.0] {
            window.setContentSize(.init(width:900,height:height))
            func frames()->[(String,NSRect)] {
                guard let content=window.contentView else{return []}
                var controls=views(content).filter {view in
                    ["Commit new branch","Commit issue","Commit author","Commit author date","Commit author time"].contains(view.identifier?.rawValue ?? "")
                }
                let textScrolls=views(content).compactMap{$0 as? NSTextView}.filter{!$0.isFieldEditor}.compactMap{$0.enclosingScrollView}
                let tables=views(content).compactMap{$0 as? NSTableView}.filter{$0.headerView != nil}.compactMap{$0.enclosingScrollView}
                controls += textScrolls+tables
                return controls.filter{!$0.isHiddenOrHasHiddenAncestor}.map{($0.identifier?.rawValue ?? String(describing:type(of:$0)),$0.convert($0.bounds,to:content))}
            }
            try await wait(owner,"GUI metadata/message/preview escaped \(height)-point content: \(frames())") {
                guard let content=window.contentView else{return false}
                let current=frames()
                return current.count>=9 && current.allSatisfy{_,rect in rect.width>0 && rect.height>0 && rect.minX >= -1 && rect.minY >= -1 && rect.maxX<=content.bounds.width+1 && rect.maxY<=content.bounds.height+1}
            }
        }
    }
    static func files(_ c:Context,_ owner:CommitWindowController)async throws {
        let m=owner.model
        var logs:[String]=[],compares:[[String]]=[]
        m.onFileLog={logs.append($0)};m.onCompareTwoFiles={compares.append($0)}
        try await select(owner,[c.partial],staged:false)
        let working=m.guiFileListSnapshot(staged:false),captured=m.fileMenu([c.partial],orderedEntries:working.entries,gui:working)
        try require(captured.offersCompare && captured.offersRevert && captured.commands.contains(.log) && captured.commands.contains(.blame) && captured.commands.contains(.editor) && !captured.offersAdd,"Tracked GUI menu lost shared action family")
        let fresh=m.fileMenu([c.new],orderedEntries:working.entries,gui:working)
        try require(fresh.offersAdd && fresh.offersIgnore && !fresh.commands.contains(.log) && !fresh.commands.contains(.blame),"Untracked GUI menu eligibility is wrong")
        let removed=m.fileMenu([c.deleted],orderedEntries:working.entries,gui:working)
        try require(removed.offersRevert && !removed.commands.contains(.open) && !removed.commands.contains(.editor),"Deleted GUI menu offers invalid opening or omits restore")
        let pair=m.fileMenu([c.partial,c.new],orderedEntries:working.entries,gui:working)
        try require(pair.commands.contains(.compareTwo),"GUI multi-file menu omitted Compare Two")
        m.fileAction(.compareTwo,snapshot:pair);try require(compares.last.map{GitPathSet($0)==GitPathSet([c.partial,c.new])}==true,"Captured multi-file action used live selection instead of captured paths")
        m.fileAction(.log,snapshot:captured);try require(logs==[c.partial],"GUI captured Show log lost literal path")
        m.fileAction(.log,snapshot:fresh);try require(logs==[c.partial],"Untracked file accepted ineligible Show log")
        let refreshed=m.fileMenu([c.partial],orderedEntries:m.unstagedEntries,gui:m.guiFileListSnapshot(staged:false))
        m.reload();try await ready(owner);m.fileAction(.log,snapshot:refreshed)
        try require(logs==[c.partial],"Same-side refresh left a retained file menu live")
        let currentWorking=m.guiFileListSnapshot(staged:false),workingDiff=m.fileMenu([c.partial],orderedEntries:currentWorking.entries,gui:currentWorking)
        var diffs:[Data]=[];m.onUnifiedDiff={bytes,_ in diffs.append(bytes)}
        m.withFileMenu(workingDiff){m.diff(paths:[c.partial],staged:false)};try await ready(owner)
        try require(diffs.last.map{String(decoding:$0,as:UTF8.self).contains("working 30")}==true,"Captured unstaged View Patch used wrong side")
        try await select(owner,[c.partial],staged:true)
        let index=m.guiFileListSnapshot(staged:true),indexMenu=m.fileMenu([c.partial],orderedEntries:index.entries,gui:index)
        m.withFileMenu(indexMenu){m.diff(paths:[c.partial],staged:true)};try await ready(owner)
        try require(diffs.last.map{String(decoding:$0,as:UTF8.self).contains("staged 2") && !String(decoding:$0,as:UTF8.self).contains("working 30")}==true,"Captured staged View Patch used working side")
        try await select(owner,[c.partial],staged:false)
        let transfer=m.guiFileListSnapshot(staged:false)
        try require(m.canMoveGuiFiles([c.partial],snapshot:transfer),"Captured Stage action unavailable")
        m.activateGuiFiles([c.partial],snapshot:transfer);try require(m.busy,"Captured Stage action was not admitted");try await ready(owner)
        try require(try await c.repository.run(["show",":"+c.partial]).stdout==c.working,"Stage adapter did not stage exact literal file bytes")
        try require(m.guiStaged && m.selection==GitPathSet([c.partial]),"Stage completion lost destination selection")
        let before=logs.count;m.fileAction(.log,snapshot:captured)
        try require(logs.count==before,"Obsolete pre-stage GUI menu remained live after data changed")
        try await select(owner,[c.partial],staged:true)
        try space(owner);try await ready(owner)
        try require(try await c.repository.run(["show",":"+c.partial]).stdout==c.base,"Unstage adapter did not restore exact HEAD bytes")
        try require(!m.guiStaged && m.selection==GitPathSet([c.partial]) && m.guiPatch?.staged==false,"Unstage completion lost working-side details")
        let sideStale=m.fileMenu([c.partial],orderedEntries:m.unstagedEntries,gui:m.guiFileListSnapshot(staged:false))
        // The MM file's captured menu may refer to an inactive list without
        // changing selection. A subsequent real side switch must retire it.
        try await select(owner,[c.other],staged:true)
        m.fileAction(.log,snapshot:sideStale);try require(logs.count==before,"Captured GUI menu survived active-side selection change")
        try await select(owner,[c.partial],staged:false)
        try space(owner);try await ready(owner)
        try require(try await c.repository.run(["show",":"+c.partial]).stdout==c.working,"GUI Space Stage did not stage exact selected bytes")
        try await select(owner,[c.partial],staged:true);try space(owner);try await ready(owner)
        try require(try await c.repository.run(["show",":"+c.partial]).stdout==c.base,"GUI Space Unstage did not restore exact selected bytes")
        let original=m.fileColumns,remaining=original.order.filter{![StatusListColumn.path,.status].contains($0)}
        try require(m.saveGuiFileColumnLayout(order:[.status,.path],widths:[.path:417,.status:153]),"GUI native column-layout callback refused valid header layout")
        try await wait(owner,"GUI header layout did not reach native columns"){
            guard let table=owner.fileTable() else{return false}
            return table.tableColumns.map{$0.headerCell.stringValue}==["Status","Path"] && abs(table.tableColumns[1].width-417)<0.5
        }
        try require(m.fileColumns.order.filter{![StatusListColumn.path,.status].contains($0)}==remaining,"Two-column GUI header erased Classic report columns")
        try require(original.widths.allSatisfy{[StatusListColumn.path,.status].contains($0.key) || m.fileColumns.widths[$0.key]==$0.value},"GUI header changed unrelated Classic widths")
        let modeStale=m.fileMenu([c.partial],orderedEntries:m.unstagedEntries,gui:m.guiFileListSnapshot(staged:false))
        m.setCommitInterface(false);try await ready(owner);m.fileAction(.log,snapshot:modeStale)
        try require(m.fileColumns.widths[.path]==417 && m.fileColumns.widths[.status]==153,"Classic switch lost GUI header persistence")
        try require(logs.count==before,"GUI menu survived switching to Classic")
        let classic=m.fileMenu([c.partial]);m.fileAction(.log,snapshot:classic);try require(logs.count==before+1,"Shared Classic action stopped working after GUI switch")
        owner.close();m.fileAction(.log,snapshot:classic);try require(logs.count==before+1,"Retired owner accepted captured file action")
        try await c.preserved()
    }
    static func conflictFocus(_ c:Context)async throws {
        let path="conflict 雪.txt"
        let base=try await c.repository.run(["hash-object","-w","--stdin"],input:Data("base conflict\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let mine=try await c.repository.run(["hash-object","-w","--stdin"],input:Data("mine conflict\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let theirs=try await c.repository.run(["hash-object","-w","--stdin"],input:Data("theirs conflict\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let packet="100644 \(base) 1\t\(path)\0"+"100644 \(mine) 2\t\(path)\0"+"100644 \(theirs) 3\t\(path)\0"
        _=try await c.repository.run(["update-index","-z","--index-info"],input:Data(packet.utf8))
        try Data("<<<<<<< mine\nmine conflict\n=======\ntheirs conflict\n>>>>>>> theirs\n".utf8).write(to:c.root.appendingPathComponent(path))
        c.preferences.set(true,forKey:"TurtleGit.Commit.GitGuiInterface")
        let owner=try await c.open(),m=owner.model
        m.message="Private conflict focus draft"
        try await select(owner,[c.other],staged:true)
        var questions=0,questionPaths:[String]=[]
        m.confirmConflictedSelection={paths,_ in
            questions += 1;questionPaths=paths
            return (ignore:false,remember:false)
        }
        try await press(c,owner,"commit")
        try await ready(owner)
        try await wait(owner,"Declined conflict warning did not focus actual unstaged conflict row"){
            !m.guiStaged && !m.stagedDiff && m.selection==GitPathSet([path]) && owner.window?.firstResponder === m.fileListTable(key:"unstaged")
        }
        try require(questions==1 && GitPathSet(questionPaths)==GitPathSet([path]) && m.guiPatch.map{GitPathSet($0.paths)==GitPathSet([path]) && !$0.staged}==true,"Declined Commit did not show exact warning path/selected conflict details")
        let obsolete=try unwrap(owner.fileTable(),"No conflict focus table")
        m.onFocusConflictedFile("unstaged",path)
        m.setCommitInterface(false);try await ready(owner)
        try require(owner.window?.firstResponder !== obsolete,"Deferred GUI conflict focus survived presentation replacement")
        try await c.preserved()
        m.message="";owner.close()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietCommitPresentationOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietCommitPresentationSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let c=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {try await c.setup();let owner=try await c.open();try await form(c,owner);try await files(c,owner);try await conflictFocus(c);await c.clean()}
        catch {await c.clean();throw error}
        try require(drained() && c.owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Commit presentation owners/workers survived cleanup")
        print("PASS: Commit cross-presentation native fields, menu/shortcut routes, captured file actions, stage/unstage details, stale guards and drain")
    }
}
