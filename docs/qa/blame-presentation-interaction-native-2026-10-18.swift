import AppKit
import TurtleGitCore

struct BlamePresentationInteractionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame presentation timeout at \(line): \(message)")
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Presentation Author"),("user.email","presentation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let path="presentation.swift",file=root.appendingPathComponent(path)
        var lines=(0..<90).map{"let line\($0) = \($0)"}
        lines[18]="let unicode = \""+String(repeating:"Unicode 雪🦎 wrapping text ",count:75)+"\""
        lines[79]=String(repeating:"wide source ",count:100)
        let initial=lines.joined(separator:"\n")+"\n"
        try Data(initial.utf8).write(to:file);try await repo.stage([path])
        _ = try await repo.commit(message:"Presentation baseline\n\nFull body first line\nBody detail with 雪🦎\n"+String(repeating:"bounded detail ",count:4000))
        let first=(try await repo.run(["rev-parse","HEAD"])).text.trimmingCharacters(in:.whitespacesAndNewlines)
        lines[4]="let changed = 42";let text=lines.joined(separator:"\n")+"\n",bytes=Data(text.utf8)
        try bytes.write(to:file);try await repo.stage([path])
        _ = try await repo.run(["config","user.name","Second Author"])
        _ = try await repo.commit(message:"Second presentation revision\n\nDistinct second body")
        let head=(try await repo.run(["rev-parse","HEAD"])).text.trimmingCharacters(in:.whitespacesAndNewlines),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BlamePresentation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer")
        prefs.set("13",forKey:"TurtleGitBlame.FontSize")
        let savedPresentation=GitBlamePresentation.load(from:prefs)
        var owner:BlameWindowController?,extraWindows:[NSWindow]=[]
        func cleanup()async {
            owner?.close();for extra in extraWindows {extra.close()}
            for _ in 0..<1800 {if BlameWindowModel.activeSyntaxRequests==0 && BlameWindowModel.activeHistoryOperations==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
        do {
            let controller=BlameWindowController(repository:repo,access:nil,path:path,revision:"HEAD",preferences:prefs);owner=controller
            let model=controller.model,window=controller.window!
            window.alphaValue=0;window.setContentSize(NSSize(width:1180,height:820));window.orderFront(nil)
            var focused:NSWindow?=window;controller.commandKeyWindow={focused}
            let context=BlameMenuContext(keyWindow:{focused})
            func source()->NSTextView? {views(window.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"}}
            func margin()->NSTableView? {views(window.contentView).compactMap{$0 as? NSTableView}.first{$0.tableColumns.contains{$0.identifier.rawValue=="original"}}}
            try await wait("native source and attribution") {!model.busy && !model.syntaxWorking && source()?.string==text && margin()?.numberOfRows==90}
            let editor=source()!,table=margin()!,scroll=editor.enclosingScrollView!
            window.makeFirstResponder(editor)
            func lineHeight()->CGFloat {(editor.textStorage?.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0}
            func rowRect(_ row:Int)->NSRect {
                let contents=editor.string as NSString,manager=editor.layoutManager!
                var offset=0
                for _ in 0..<row {offset=NSMaxRange(contents.lineRange(for:NSRange(location:offset,length:0)))}
                let range=contents.lineRange(for:NSRange(location:offset,length:0))
                let glyphs=manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
                let first=manager.lineFragmentRect(forGlyphAt:glyphs.location,effectiveRange:nil),last=manager.lineFragmentRect(forGlyphAt:NSMaxRange(glyphs)-1,effectiveRange:nil)
                return NSRect(x:first.minX,y:first.minY,width:first.width,height:last.maxY-first.minY)
            }
            func rowAtY(_ y:CGFloat)->Int? {(0..<lines.count).last{rowRect($0).minY<=y}}
            func event(_ key:UInt16,_ characters:String,_ flags:NSEvent.ModifierFlags = .command)->NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:key)!
            }
            func label(row:Int,column:String)->NSTextField? {
                guard let index=table.tableColumns.firstIndex(where:{$0.identifier.rawValue==column}) else{return nil}
                return views(table.view(atColumn:index,row:row,makeIfNecessary:true)).compactMap{$0 as? NSTextField}.first
            }
            let selected=(text as NSString).range(of:"Unicode 雪🦎"),baseSize=model.effectiveFontSize,baseLine=lineHeight(),baseRow=table.rect(ofRow:5).height,baseGutter=table.tableColumns.first{$0.identifier.rawValue=="line"}!.width
            try require(baseSize==13 && model.presentation.fontSize==13,"Blame ignored the actual owner private configured font size")
            editor.setSelectedRange(selected)
            context.perform(.zoomIn)
            try await wait("source+attribution zoom fonts") {abs(((editor.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize ?? 0)-CGFloat(model.effectiveFontSize))<0.1 && label(row:5,column:"revision")?.font?.pointSize==CGFloat(model.effectiveFontSize)}
            try require(model.effectiveFontSize>baseSize && editor.selectedRange()==selected && editor.string==text && !editor.isEditable,"Menu zoom changed source bytes/UTF16 selection or failed")
            try require(window.performKeyEquivalent(with:event(24,"+",[.command,.shift])),"Native Command-Plus was not dispatched")
            try await wait("native zoom rendered") {editor.font?.pointSize==CGFloat(model.effectiveFontSize) || (editor.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize==CGFloat(model.effectiveFontSize)}
            let plusLevel=model.zoomLevel
            try require(window.performKeyEquivalent(with:event(27,"-")) && model.zoomLevel==plusLevel-1,"Native Command-Minus did not zoom out")
            try require(window.performKeyEquivalent(with:event(29,"0")) && model.zoomLevel==0,"Native Actual Size did not reset configured font")
            try await wait("reset metrics") {abs(lineHeight()-baseLine)<0.1 && abs(table.rect(ofRow:5).height-baseRow)<0.1}
            try require(model.effectiveFontSize==13 && prefs.string(forKey:"TurtleGitBlame.FontSize")=="13" && GitBlamePresentation.load(from:prefs)==savedPresentation,"Zoom/reset persisted its transient offset or changed source presentation preferences")
            // Variable-height wrapped rows preserve logical row and pixel offset.
            model.setWrapLongLines(true)
            try await wait("wrapped row geometry") {!scroll.hasHorizontalScroller && rowRect(18).height>baseRow*3}
            let inset:CGFloat=31
            scroll.contentView.scroll(to:NSPoint(x:0,y:rowRect(18).minY+inset));scroll.reflectScrolledClipView(scroll.contentView)
            let logical=rowAtY(scroll.contentView.bounds.minY),within=scroll.contentView.bounds.minY-rowRect(18).minY
            for _ in 0..<8 {model.zoomIn()}
            try await wait("wrapped zoom anchor") {lineHeight()>baseLine && label(row:18,column:"revision")?.font?.pointSize==CGFloat(model.effectiveFontSize)}
            try require(rowAtY(scroll.contentView.bounds.minY)==logical && abs((scroll.contentView.bounds.minY-rowRect(18).minY)-within)<1.5 && editor.selectedRange()==selected,"Wrapped zoom lost logical/intra-row/UTF16 anchor")
            try require(abs(table.rect(ofRow:18).height-rowRect(18).height)<1 && abs(table.rect(ofRow:19).minY-rowRect(19).minY)<1,"Zoom desynchronized attribution/source line metrics")
            model.setWrapLongLines(false)
            try await wait("unwrapped horizontal view") {scroll.hasHorizontalScroller}
            scroll.contentView.scroll(to:NSPoint(x:60,y:rowRect(40).minY+3));scroll.reflectScrolledClipView(scroll.contentView)
            let horizontal=scroll.contentView.bounds.minX,top=rowAtY(scroll.contentView.bounds.minY)
            model.zoomIn();try await wait("horizontal zoom") {label(row:40,column:"revision")?.font?.pointSize==CGFloat(model.effectiveFontSize)}
            try require(abs(scroll.contentView.bounds.minX-horizontal)<1 && rowAtY(scroll.contentView.bounds.minY)==top && editor.selectedRange()==selected,"Unwrapped zoom lost horizontal/logical anchor or selection")
            // Native modified wheel events route through the actual source scroll.
            func wheel(_ delta:Int32,_ flags:CGEventFlags)->NSEvent {
                let value=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!
                value.flags=flags;return NSEvent(cgEvent:value)!
            }
            let beforeWheel=model.zoomLevel
            scroll.scrollWheel(with:wheel(1,.maskCommand))
            try require(model.zoomLevel != beforeWheel,"Command wheel failed to zoom actual source scroll")
            let afterWheel=model.zoomLevel
            table.enclosingScrollView!.scrollWheel(with:wheel(-1,.maskControl))
            try require(model.zoomLevel != afterWheel,"Control wheel failed on actual attribution scroll")
            let plainLevel=model.zoomLevel;scroll.scrollWheel(with:wheel(1,[]));try require(model.zoomLevel==plainLevel,"Unmodified scroll changed zoom")
            // Limits and disabled/background/retired ownership are enforced by
            // actual commands as well as public model operations.
            for _ in 0..<300 {model.zoomIn()};let upper=model.zoomLevel
            try require(!model.canZoomIn,"Zoom upper limit not bounded");model.zoomIn();try require(model.zoomLevel==upper,"Upper limit changed")
            try await wait("upper zoom gutter+row metrics") {label(row:5,column:"revision")?.font?.pointSize==CGFloat(model.effectiveFontSize) && table.tableColumns.first{$0.identifier.rawValue=="line"}!.width>baseGutter && table.rect(ofRow:5).height>baseRow}
            let boundedOrigin=scroll.contentView.bounds.origin
            scroll.scrollWheel(with:wheel(1,.maskCommand))
            try require(model.zoomLevel==upper && scroll.contentView.bounds.origin==boundedOrigin,"Bounded zoom wheel escaped into accidental source scroll")
            for _ in 0..<600 {model.zoomOut()};let lower=model.zoomLevel
            try require(!model.canZoomOut && model.effectiveFontSize>0,"Zoom lower limit not bounded");model.zoomOut();try require(model.zoomLevel==lower,"Lower limit changed")
            try await wait("lower zoom native floor") {label(row:5,column:"revision")?.font?.pointSize==CGFloat(model.effectiveFontSize) && lineHeight()>=8 && lineHeight()<baseLine && abs(table.rect(ofRow:5).height-lineHeight())<1}
            context.perform(.actualSize);try require(model.zoomLevel==0 && !model.canResetZoom,"Actual Size menu did not restore configured baseline")
            try require(model.effectiveFontSize==13 && prefs.string(forKey:"TurtleGitBlame.FontSize")=="13" && GitBlamePresentation.load(from:prefs)==savedPresentation,"Boundary zoom persisted into font/tab/color preferences")
            model.busy=true;let blocked=model.zoomLevel
            context.perform(.zoomIn);_ = window.performKeyEquivalent(with:event(24,"="));scroll.scrollWheel(with:wheel(1,.maskCommand));model.zoomOut()
            try require(model.zoomLevel==blocked,"Busy owner accepted zoom");model.busy=false
            model.confirmingQuit=true;model.zoomIn();try require(model.zoomLevel==blocked,"Deferred Quit accepted zoom");model.confirmingQuit=false
            let foreign=NSWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false);foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;extraWindows.append(foreign)
            focused=foreign;context.perform(.zoomIn);try require(model.zoomLevel==blocked,"Background owner accepted menu zoom");focused=window;foreign.close()
            // Tooltip ownership comes from each actual row, including commits
            // that are not selected and bodies excluded from short summaries.
            try await wait("rich revision metadata") {model.revisionToolTip(for:0)?.contains("Full body first line")==true && model.revisionToolTip(for:4)?.contains("Distinct second body")==true}
            let firstTip=model.revisionToolTip(for:0)!,secondTip=model.revisionToolTip(for:4)!
            try require(firstTip.contains(first) && firstTip.contains("Presentation Author") && firstTip.contains("presentation@example.invalid") && firstTip.contains("Body detail with 雪🦎") && secondTip.contains(head) && secondTip.contains("Second Author") && !secondTip.contains("Full body first line"),"Rich tooltips lost per-row hash/author/email/body identity")
            try require(firstTip.utf16.count<=8000 && model.revisionToolTip(for:-1)==nil && model.revisionToolTip(for:90)==nil,"Tooltip payload/invalid row unbounded")
            try await wait("native attribution tooltip") {label(row:4,column:"revision")?.toolTip==secondTip}
            guard let sourceTooltip=editor as? any BlameSourceTooltipProviding else {throw Failure(description:"Actual source NSTextView lacks production tooltip owner")}
            try require(sourceTooltip.revisionTooltip(at:NSPoint(x:20,y:rowRect(4).midY))==secondTip,"Source TextKit tooltip resolved a selected/visible row instead of hovered logical row")
            let beforeReloadHead=try await repo.run(["rev-parse","HEAD"])
            try require(beforeReloadHead.text.trimmingCharacters(in:.whitespacesAndNewlines)==head,"Zoom/tooltip interactions moved HEAD before intentional reload setup")
            // Change only this private repository's ref, preserving second-
            // commit index/work bytes. Reload continues to use real HEAD.
            let expectedReloadHead=first
            _ = try await repo.run(["update-ref","HEAD",expectedReloadHead,head])
            model.reload()
            try require(model.revisionToolTip(for:4)==nil,"Busy reload exposed stale prior-revision tooltip")
            try await wait("old revision tooltip refresh") {!model.busy && model.lines.count==90 && model.revisionToolTip(for:4)?.contains("Full body first line")==true}
            try require(model.revisionToolTip(for:4)?.contains("Distinct second body")==false,"Reload retained tooltip from prior row revision")
            try await wait("native reloaded attribution tooltip") {label(row:4,column:"revision")?.toolTip?.contains("Full body first line")==true}
            try require(sourceTooltip.revisionTooltip(at:NSPoint(x:20,y:rowRect(4).midY))?.contains("Distinct second body")==false,"Source tooltip retained old commit after reload")
            let retiredZoom=model.zoomLevel;controller.close();model.zoomIn();model.zoomOut();model.resetZoom()
            try require(model.retired && model.zoomLevel==retiredZoom && model.revisionToolTip(for:0)==nil,"Retired owner accepted zoom/tooltip")
            await cleanup()
            let finalHead=try await repo.run(["rev-parse","HEAD"]),finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(finalHead.text.trimmingCharacters(in:.whitespacesAndNewlines)==expectedReloadHead && finalIndex==index && (try Data(contentsOf:file))==bytes,"Presentation interactions mutated repository")
            try require(window.isVisible==false && window.attachedSheet==nil && BlameWindowModel.activeSyntaxRequests==0 && BlameWindowModel.activeHistoryOperations==0,"Owned presentation windows/workers survived cleanup")
            print("PASS: Blame zoom/rich tooltip native presentation interaction")
        }catch{await cleanup();throw error}
    }
}
