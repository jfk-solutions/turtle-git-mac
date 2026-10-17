import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct MessageHistorySourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"History source wait timed out")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        try require(window.frame.width>=600 && window.frame.height>=320,"History host collapsed")
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned history capture unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("message-history-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.HistorySource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let history=CommitMessageHistory(repositoryIdentity:"source",defaults:prefs)
        let a="Keep café spelling\r\n\r\nFix the selected files",b="Keep cafe\u{301} spelling\r\n\r\nFix the selected files",tail="A long commit message with\ta tab stop and enough detail to exercise horizontal scrolling: "+String(repeating:"review changes · ",count:12)
        for value in [tail,a,b] {history.add(value)}
        var replies=[String?]()
        let view=MessageHistoryPickerView(history:history) {replies.append($0)}
        let window=NSWindow(contentRect:.init(x:100,y:100,width:700,height:350),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Log History – TurtleGit";window.isReleasedWhenClosed=false;window.contentMinSize = .init(width:400,height:230);window.contentView=view
        defer {window.close()};window.alphaValue=0;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
        try require(window.firstResponder === view.table && view.table.numberOfRows==3,"Initial native list focus/rows")
        view.table.selectRowIndexes([0,1],byExtendingSelection:false)
        try require(view.model.selection==[0,1],"Native multi selection")
        try require(view.model.selectedMessage.utf8.elementsEqual((b+"\n\n"+a).utf8),"Selection order/raw message bytes")
        let stale=view.table.onReturn,staleDelete=view.table.onDelete
        view.table.selectRowIndexes([2],byExtendingSelection:false);view.table.selectRowIndexes([0,1],byExtendingSelection:false)
        stale();staleDelete();try require(replies.isEmpty && history.entries.count==3,"Selection ABA callback accepted")
        let foreign=MessageHistoryPickerModel(history:history).capture();view.invoke(.delete,context:foreign)
        try require(history.entries.count==3,"Foreign command accepted")
        try await capture(window)
        let original = view.model.capture()
        view.table.selectRowIndexes([0],byExtendingSelection:false)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51)!
        view.table.keyDown(with:event)
        try require(history.entries.count==2 && history.entries[0].utf8.elementsEqual(a.utf8),"Delete merged canonical peer")
        try require(view.table.selectedRowIndexes==[0] && view.model.selection==[0],"Delete successor selection")
        view.invoke(.accept,context:original);try require(replies.isEmpty,"Deleted snapshot accepted")
        try require(view.scroll.hasHorizontalScroller && view.table.tableColumns[0].width>view.scroll.contentSize.width,"Full message horizontal extent")
        view.table.selectRowIndexes([0,1],byExtendingSelection:false)
        let accept=view.table.onReturn;accept();accept()
        try require(replies.count==1 && replies[0]!.utf8.elementsEqual((a+"\n\n"+tail).utf8),"Ordered once-only acceptance")
        let retained=view.table.onDelete;window.close();retained();view.cancel.performClick(nil)
        try require(history.entries.count==2 && replies.count==1,"Closed picker mutated history or replied twice")
        // Empty OK and Cancel remain distinct, as in the source.
        let empty=CommitMessageHistory(repositoryIdentity:"empty",defaults:prefs)
        var emptyReplies=[String?]();let emptyView=MessageHistoryPickerView(history:empty) {emptyReplies.append($0)}
        let emptyWindow=NSWindow(contentRect:.init(x:0,y:0,width:400,height:230),styleMask:[.titled],backing:.buffered,defer:false)
        emptyWindow.isReleasedWhenClosed=false;emptyWindow.contentView=emptyView;defer {emptyWindow.close()}
        emptyView.ok.performClick(nil);try require(emptyReplies.count==1 && emptyReplies[0]=="","Empty OK was Cancel")
        let repo=GitRepository(root:root,executable:git);_=try await repo.run(["init","-b","main"])
        let merge=MergeWindowController(repository:repo,access:nil,preferences:prefs);defer {merge.close()}
        merge.window!.alphaValue=0;merge.window!.orderFront(nil)
        try await wait {!merge.model.busy}
        merge.model.messageHistory.add(a);merge.model.messageHistory.add(b)
        var inserted:String?
        merge.model.showMessageHistory {inserted=$0}
        try await wait {merge.window?.attachedSheet != nil}
        let child=merge.window!.attachedSheet!
        guard let native=child.contentView as? MessageHistoryPickerView else{throw Failure(description:"Merge did not use native history surface")}
        native.table.selectRowIndexes([0,1],byExtendingSelection:false);native.ok.performClick(nil)
        try await wait {merge.window?.attachedSheet==nil}
        try require(inserted?.utf8.elementsEqual((b+"\n\n"+a).utf8)==true,"Merge sheet payload")
        merge.model.showMessageHistory {_ in inserted="late"};try await wait {merge.window?.attachedSheet != nil}
        let held=merge.window!.attachedSheet!.contentView as! MessageHistoryPickerView,late=held.table.onReturn
        merge.close();late();try require(inserted != "late" && held.model.retired,"Merge close accepted late history result")
        print("PASS message history source: native full dialog/list/buttons, exact canonical peers, stale/foreign/ABA/closed commands, Delete successor, horizontal extent, ordered once-only/empty OK and production Merge sheet; owned windows closed")
    }
}
