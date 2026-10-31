import AppKit
import Darwin
import TurtleGitCore

@main struct BlameCommandFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func require(_ value:Bool,_ message:String)throws {if !value {print("Blame command assertion: "+message);fflush(stdout);throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<1000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame command readiness at line \(line)")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_BLAME_COMMAND_CAPTURE"] == nil ? .prohibited:.accessory)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Command Fixture"),("user.email","commands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("literal 雪.swift"),bytes=Data("alpha\nneedle 雪🦎\nother\nneedle last\n".utf8)
        try bytes.write(to:file);try await repo.stage([file.lastPathComponent]);_ = try await repo.commit(message:"Blame commands")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BlameCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");defer{prefs.removePersistentDomain(forName:suite)}
        let owner=BlameWindowController(repository:repo,access:nil,path:file.lastPathComponent,revision:"HEAD",preferences:prefs),model=owner.model,window=owner.window!
        defer{owner.close()};window.alphaValue=0;window.ignoresMouseEvents=true;window.orderFront(nil)
        var focused:NSWindow?=window;owner.commandKeyWindow={focused}
        let context=BlameMenuContext(keyWindow:{focused})
        try await wait {!model.busy && !model.syntaxWorking && model.lines.count==4 && views(window.contentView).contains{($0 as? NSTextView)?.accessibilityLabel()=="Blame source text"}}
        let source=views(window.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"}!
        window.makeFirstResponder(source)
        func event(_ key:UInt16,_ flags:NSEvent.ModifierFlags=[],_ text:String="",in host:NSWindow?=nil)->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:(host ?? window).windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:key)!
        }
        model.goToLine(1);model.find="needle"
        try require(window.performKeyEquivalent(with:event(99,.function,"\u{F706}")) && model.selection==2,"Source F3 not dispatched")
        source.keyDown(with:event(99,.function,"\u{F706}"));try require(model.selection==4,"Direct source F3 not dispatched")
        try require(window.performKeyEquivalent(with:event(99,[.shift,.function],"\u{F706}")) && model.selection==2,"Shift-F3 not previous")
        // A native manual caret move immediately after Find is newer intent
        // than any queued source projection from that accepted Find result.
        try require(window.performKeyEquivalent(with:event(99,.function,"\u{F706}")) && model.selection==4,"Immediate repeated F3 lost its accepted source caret")
        let manualCaret=NSRange(location:(source.string as NSString).range(of:"other").location,length:0)
        source.setSelectedRange(manualCaret)
        try require(source.selectedRange()==manualCaret && model.sourceSearchCaretRow?()==2,"Native manual source caret did not replace accepted Find intent")
        await Task.yield()
        try require(source.selectedRange()==manualCaret && model.sourceSearchCaretRow?()==2,"Deferred Find projection overwrote newer manual source intent")
        try require(window.performKeyEquivalent(with:event(99,.function,"\u{F706}")) && model.selection==4,"Find did not resume from newer manual source caret")
        try require(window.performKeyEquivalent(with:event(99,[.shift,.function],"\u{F706}")) && model.selection==2,"Rapid direction reversal lost native source-caret ownership")
        model.busy=true;try require(window.performKeyEquivalent(with:event(99)) && model.selection==2,"Disabled F3 fell through");model.busy=false
        let foreign=NSWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false);foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.ignoresMouseEvents=true;defer{foreign.close()}
        focused=foreign;try require(!BlameWindowController.routeCommandKey(event(99),from:window) && model.selection==2,"Background viewer received source command");focused=window
        // Source Ctrl-G opens an owned native sheet; macOS Command-G remains Find Next.
        try require(window.performKeyEquivalent(with:event(5,.control,"g")),"Source Go To shortcut absent")
        try await wait {owner.goToWindow?.window?.sheetParent === window}
        let invalid=owner.goToWindow!;context.refresh();try require(!context.available && !owner.commandsAvailable && !model.canFind,"Sheet left main-menu commands enabled")
        try require(invalid.line.stringValue=="0","Source Go To default changed")
        if let captures=ProcessInfo.processInfo.environment["TURTLEGIT_BLAME_COMMAND_CAPTURE"] {
            window.alphaValue=1
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);invalid.window?.appearance=window.appearance
                window.orderFront(nil);invalid.window?.orderFront(nil)
                try await Task.sleep(nanoseconds:350_000_000)
                let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments=["-x","-o","-l",String(window.windowNumber),URL(fileURLWithPath:captures).appendingPathComponent("blame-go-to-"+name+".png").path]
                try capture.run();capture.waitUntilExit();try require(capture.terminationStatus==0,"Owned Go To capture failed")
            }
            window.alphaValue=0
        }
        invalid.line.stringValue="-1";invalid.accept();try require(owner.goToWindow === invalid && !invalid.validation.stringValue.isEmpty && model.selection==2,"Invalid Go To was accepted")
        invalid.line.stringValue=String(GitBlameNavigation.maximumGoToLine+1);invalid.accept();try require(owner.goToWindow === invalid,"Go To range exceeded")
        invalid.line.stringValue="4";invalid.ok.performClick(nil)
        try await wait {owner.goToWindow==nil && window.attachedSheet==nil && model.selection==4}
        try require(invalid.retired && window.firstResponder === source,"Go To did not retire/restore source focus")
        let afterAccepted=model.selection;invalid.line.stringValue="1";invalid.accept();try require(model.selection==afterAccepted,"Retired Go To moved source")
        context.perform(.goTo);try await wait {owner.goToWindow != nil};let cancelled=owner.goToWindow!;cancelled.line.stringValue="1";cancelled.cancel()
        try await wait {owner.goToWindow==nil && window.attachedSheet==nil};try require(model.selection==4 && cancelled.retired,"Cancel navigated or retained sheet")
        context.perform(.goTo);try await wait {owner.goToWindow != nil};let zero=owner.goToWindow!;zero.line.stringValue="0";zero.accept()
        try await wait {owner.goToWindow==nil && window.attachedSheet==nil};try require(model.selection==4,"Source zero Go To must not move")
        try require(window.performKeyEquivalent(with:event(37,.command,"l")),"Native Go To shortcut absent")
        try await wait {owner.goToWindow != nil};owner.goToWindow!.line.stringValue="40000000";owner.goToWindow!.accept()
        try await wait {owner.goToWindow==nil && window.attachedSheet==nil};try require(model.selection==4,"Source end clamp changed")
        let ordinaryGoTo=owner.presentGoToLine
        var heldGoToReply:((NSApplication.ModalResponse)->Void)?,heldGoToEnd:(()->Void)?
        defer {owner.presentGoToLine=ordinaryGoTo;heldGoToEnd?();heldGoToEnd=nil;heldGoToReply=nil}
        owner.presentGoToLine={ controller,parent,reply in
            heldGoToReply=reply
            controller.endSheet={parent,sheet,response in heldGoToEnd={parent.endSheet(sheet,returnCode:response)}}
            parent.beginSheet(controller.window!,completionHandler:{_ in})
        }
        context.perform(.goTo);try await wait{owner.goToWindow?.window?.sheetParent === window}
        let earlyGoTo=owner.goToWindow!,beforeEarlyGoTo=model.selection
        earlyGoTo.line.stringValue="2";earlyGoTo.ok.performClick(nil)
        try require(earlyGoTo.requested==2 && heldGoToEnd != nil,"Actual Go To OK did not capture held native acceptance")
        heldGoToReply?(.OK);heldGoToReply?(.cancel)
        try require(owner.goToWindow === earlyGoTo && earlyGoTo.window?.sheetParent === window && window.attachedSheet === earlyGoTo.window && owner.navigationWorkPending && BlameWindowController.activeNavigationOperations>0 && model.selection==beforeEarlyGoTo && !model.canFind,"Early/duplicate Go To answer escaped exact native sheet ownership")
        heldGoToEnd?();heldGoToEnd=nil
        try await wait{owner.goToWindow==nil && window.attachedSheet==nil && model.selection==2 && (source.string as NSString).substring(with:source.selectedRange())=="needle 雪🦎"}
        try require(earlyGoTo.retired && !owner.navigationWorkPending && BlameWindowController.activeNavigationOperations==0 && model.sourceSearchCaretRow?()==1,"Accepted Go To lost actual source-caret handoff or navigation drain")
        heldGoToReply?(.OK);heldGoToReply=nil;earlyGoTo.line.stringValue="1";earlyGoTo.accept()
        try require(model.selection==2,"Late accepted Go To callback retargeted native selection")
        owner.presentGoToLine=ordinaryGoTo
        model.find="needle";model.findLine(previous:false)
        try await wait{model.selection==2 && (source.string as NSString).substring(with:source.selectedRange())=="needle 雪🦎\n"}
        model.findLine(previous:false)
        try await wait{model.selection==4 && (source.string as NSString).substring(with:source.selectedRange())=="needle last\n"}
        try require(model.sourceSearchCaretRow?()==4,"Accepted terminal Find lost native active-end caret")
        model.findLine(previous:false)
        try await wait{model.selection==2 && (source.string as NSString).substring(with:source.selectedRange())=="needle 雪🦎\n"}
        try require(!model.navigationMessage.contains("Wrapped"),"Terminal source Find normalization invented a traversal wrap")
        // Source Find uses selected text, stays modeless and reuses its draft.
        source.setSelectedRange((source.string as NSString).range(of:"needle"))
        try require(window.performKeyEquivalent(with:event(3,.control,"f")),"Source Find shortcut absent")
        try await wait {owner.findWindow?.window?.isVisible==true}
        let find=owner.findWindow!;try require(find.draft.text=="needle" && window.attachedSheet==nil,"Find prefill/modeless state")
        model.onFind?();try require(owner.findWindow === find,"Find duplicated its panel")
        let beforeModal=model.selection,beforeModalRange=source.selectedRange()
        context.perform(.goTo);try await wait {owner.goToWindow != nil}
        find.search();try require(model.selection==beforeModal && !model.canFind,"Modeless Find escaped modal Go To ownership")
        owner.goToWindow!.cancel();try await wait {owner.goToWindow==nil && model.canFind}
        find.search();try await wait{model.selection==2 && (source.string as NSString).substring(with:source.selectedRange())=="needle 雪🦎\n"}
        try require(source.selectedRange() != beforeModalRange,"Find did not resume inclusive current-row selection after modal cancellation")
        find.close();model.goToLine(4)
        // Both menu directions and native F6 reach existing source/Log panes.
        focused=window;window.makeFirstResponder(source)
        try require(window.performKeyEquivalent(with:event(97,.function,"\u{F709}")),"F6 absent")
        try await wait {window.firstResponder is BlameHistoryNativeTable}
        try require(window.performKeyEquivalent(with:event(97,[.shift,.function],"\u{F709}")),"Shift-F6 absent")
        try await wait {window.firstResponder === source}
        model.showLog=false;context.perform(.nextPane);try require(window.firstResponder === source && !model.showLog,"F6 reopened hidden Log")
        model.showLog=true;model.setPaneAutoHidden(.log,true);context.perform(.nextPane)
        try require(window.firstResponder === source && model.paneAutoHidden(.log),"F6 reopened auto-hidden Log")
        model.setPaneAutoHidden(.log,false);model.tabPane(.log,joined:true);model.selectPaneTab(.properties)
        window.makeFirstResponder(source);context.perform(.nextPane)
        try await wait {model.paneLayout.activeTab == .log && window.firstResponder is BlameHistoryNativeTable}
        context.perform(.previousPane);try await wait {window.firstResponder === source}
        model.setPanePlacement(.log,.floating)
        try await wait {owner.floatingPaneWindow(.log) != nil}
        context.perform(.nextPane)
        let floating=owner.floatingPaneWindow(.log)!
        try await wait {floating.firstResponder is BlameHistoryNativeTable}
        focused=floating
        try require(floating.performKeyEquivalent(with:event(97,.function,"\u{F709}",in:floating)),"Floating pane did not route F6")
        try await wait {window.firstResponder === source}
        focused=floating
        try require(floating.performKeyEquivalent(with:event(53,[],"\u{1b}",in:floating)),"Floating Escape absent")
        try await wait {owner.floatingPaneWindow(.log)==nil}
        try require(!model.retired && !model.showLog,"Floating Escape closed its document")
        focused=window
        try require(window.performKeyEquivalent(with:event(5,.command,"g")) && model.selection==2,"Command-G did not remain Find Next")
        context.perform(.goTo);try await wait {owner.goToWindow != nil};let abandoned=owner.goToWindow!
        var closed=0;owner.onClosed={closed+=1}
        owner.close()
        try require(model.retired && closed==0 && owner.navigationWorkPending && BlameWindowController.activeNavigationOperations>0,"Root closure released its accepted Go To ownership before native drain")
        try await wait{abandoned.retired && abandoned.window?.sheetParent==nil && owner.goToWindow==nil && !owner.navigationWorkPending && BlameWindowController.activeNavigationOperations==0 && closed==1}
        abandoned.line.stringValue="1";abandoned.accept();context.perform(.nextPane)
        try require(!BlameWindowController.routeCommandKey(event(99),from:window),"Retired owner accepted a key")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==bytes,"Command family changed Git or source bytes")
        print("PASS: Blame command family source F3/Shift-F3/Control-F/G and native Command-G/L, busy/background/retired refusal, owned Go To validation/Cancel/zero/clamp/forced close, modeless Find prefill/reuse, source/Log/tab/floating F6 routing and exact Git/index/source preservation; owned windows closed")
    }
}
