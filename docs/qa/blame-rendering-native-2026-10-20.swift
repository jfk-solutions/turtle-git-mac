import AppKit
import TurtleGitCore

/// Large real annotation input plus observable native work receipts. These checks
/// assert what was rebuilt and what was painted, never a machine-speed threshold.
enum BlameRenderingVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func verify(root: URL, git: URL) async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw Failure(description: message) }
        }
        func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw Failure(description: "Timed out: " + message)
        }
        // Give coalesced updates an opportunity for no-op/retirement assertions.
        // Paint-producing transitions below wait for observable native receipts
        // or actual attributes; elapsed time alone never establishes readiness.
        func settle() async throws { for _ in 0..<8 { await Task.yield(); try await Task.sleep(nanoseconds: 10_000_000) } }
        let directory=root.appendingPathComponent("blame-rendering",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repo=GitRepository(root:directory,executable:git)
        _ = try await repo.run(["init"])
        _ = try await repo.run(["config","user.name","Alice"])
        _ = try await repo.run(["config","user.email","alice@example.invalid"])
        let file=directory.appendingPathComponent("large.swift")
        var lines=(0..<3000).map { "let line\($0) = \"Unicode 雪🦎 and a long source segment for horizontal/wrapped layout \(String(repeating:"x",count:80))\"" }
        func saveCommit(_ message:String) async throws {
            try (lines.joined(separator:"\n")+"\n").write(to:file,atomically:true,encoding:.utf8)
            _ = try await repo.run(["add","--","large.swift"]);_ = try await repo.run(["commit","-m",message])
        }
        try await saveCommit("Original Alice")
        for row in 0..<500 { lines[row] += " // Alice revision two" }
        try await saveCommit("Another Alice revision")
        _ = try await repo.run(["config","user.name","Bob"]);_ = try await repo.run(["config","user.email","bob@example.invalid"])
        for row in 1000..<1500 { lines[row] += " // Bob" }
        try await saveCommit("Bob revision")
        _ = try await repo.run(["config","user.name","Cara"]);_ = try await repo.run(["config","user.email","cara@example.invalid"])
        for row in 2000..<2500 { lines[row] += " // Cara" }
        try await saveCommit("Cara revision")
        let original=try Data(contentsOf:file),index=try Data(contentsOf:directory.appendingPathComponent(".git/index")),head=(try await repo.run(["rev-parse","HEAD"])).text
        let suite="TurtleGit.BlameRendering."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer")
        prefs.set(true,forKey:"Blame.ShowDate");prefs.set(false,forKey:"UseSystemLocaleForDates")
        var owner:BlameWindowController?
        var syntaxReply:CheckedContinuation<BlameSyntaxResult,Error>?,syntaxToken:OperationCancellation?
        func cleanup() async {
            owner?.close()
            syntaxReply?.resume(throwing:OperationCancellationFailure.cancelled);syntaxReply=nil
            for _ in 0..<1500 { if BlameWindowModel.activeSyntaxRequests==0 && BlameWindowModel.activeHistoryOperations==0 { break };try? await Task.sleep(nanoseconds:10_000_000) }
            prefs.removePersistentDomain(forName:suite)
        }
        do {
            let controller=BlameWindowController(repository:repo,access:nil,path:"large.swift",revision:"HEAD",preferences:prefs)
            owner=controller;let model=controller.model,window=controller.window!
            window.appearance=NSAppearance(named:.aqua);window.alphaValue=0;window.setFrameOrigin(NSPoint(x:-12000,y:-12000));window.setContentSize(NSSize(width:1300,height:800));window.orderFront(nil)
            controller.commandKeyWindow={window}
            func editorView()->NSTextView? { views(window.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"} }
            try await wait("large native annotation") {!model.busy && editorView()?.string==String(data:original,encoding:.utf8)}
            try await settle()
            let editor=editorView()!,scroll=editor.enclosingScrollView!
            guard let painter=views(window.contentView).compactMap({$0 as? any BlameRenderWorkProviding}).first else {throw Failure(description:"Missing real native rendering receipt")}
            func offset(_ row:Int)->Int { (0..<row).reduce(0){$0+(lines[$1] as NSString).length+1} }
            func color(_ row:Int)->NSColor? {editor.textStorage?.attribute(.foregroundColor,at:offset(row),effectiveRange:nil) as? NSColor}
            let chosen=NSRange(location:offset(120)+4,length:17)
            editor.setSelectedRange(chosen);try await settle()
            let origin=NSPoint(x:120,y:2200);scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView);try await settle()
            let preservedOrigin=scroll.contentView.bounds.origin,base=painter.renderWork,baseBackground=painter.renderedRowBackground(0)
            func highlightState() -> String {
                "history=\(model.historyVersion), hover=\(String(describing:model.hoveredLine)), hoverHash=\(String(describing:model.hoverLine?.hash)), selected=\(model.selectedLogHashes.sorted()), selectedAuthor=\(String(describing:model.selectedHistoryEntry?.author)), sticky=\(String(describing:model.highlightedHash)), row0kind=\(model.highlightKind(model.lines[0]))"
            }
            let baseState=highlightState()
            model.hoveredLine=1
            try await wait("first revision hover paint receipt") {painter.renderWork.highlightRowsPainted>base.highlightRowsPainted}
            let hovered=painter.renderWork
            try require(hovered.documentRebuilds==base.documentRebuilds && hovered.baseStylePasses==base.baseStylePasses && hovered.geometryRebuilds==base.geometryRebuilds && hovered.attributionReloads==base.attributionReloads,"Hover rebuilt the document, complete styles, glyph geometry or attribution rows")
            try require(hovered.foregroundRowsStyled==base.foregroundRowsStyled && painter.renderedRowBackground(0) != baseBackground,"Hover failed to paint revision background or rewrote source attributes; before=\(base), after=\(hovered), beforeColor=\(String(describing:baseBackground?.usingColorSpace(.sRGB))), afterColor=\(String(describing:painter.renderedRowBackground(0)?.usingColorSpace(.sRGB))), beforeState={\(baseState)}, afterState={\(highlightState())}")
            try require(editor.selectedRange()==chosen && scroll.contentView.bounds.origin==preservedOrigin,"Hover changed exact UTF-16 selection or scrolled source")
            model.hoveredLine=2;try await settle()
            try require(painter.renderWork==hovered,"Moving within the same revision/author performed redundant row/style/layout work")
            model.hoveredLine=501
            try await wait("cross-revision hover paint receipt") {painter.renderWork.highlightRowsPainted>hovered.highlightRowsPainted}
            let nextHover=painter.renderWork
            try require(nextHover.highlightRowsPainted-hovered.highlightRowsPainted<model.lines.count && nextHover.geometryRebuilds==hovered.geometryRebuilds,"Same-author hover unnecessarily repainted the complete document or reflowed")
            model.hoveredLine=nil
            try await wait("hover clear paint receipt") {painter.renderWork.highlightRowsPainted>nextHover.highlightRowsPainted}
            let beforeSelection=painter.renderWork
            model.selectedLogHashes=[model.lines[1000].hash]
            try await wait("selected revision foreground") {color(1000)==NSColor.alternateSelectedControlTextColor && color(2000)==NSColor.labelColor}
            try require(color(1000)==NSColor.alternateSelectedControlTextColor && color(2000)==NSColor.labelColor,"Selected author foreground did not match actual native source styling")
            try require(painter.renderWork.documentRebuilds==beforeSelection.documentRebuilds && painter.renderWork.baseStylePasses==beforeSelection.baseStylePasses && painter.renderWork.geometryRebuilds==beforeSelection.geometryRebuilds,"Selecting a revision rebuilt complete text/styles/geometry")
            try require(editor.selectedRange()==chosen && scroll.contentView.bounds.origin==preservedOrigin,"Revision highlight discarded source selection/viewport")
            model.selectedLogHashes=[]
            try await wait("cleared revision foreground") {color(1000)==NSColor.labelColor}
            try require(color(1000)==NSColor.labelColor,"Clearing selection did not restore underlying source foreground")
            let beforeWrap=painter.renderWork
            model.setWrapLongLines(true)
            try await wait("wrapped source geometry receipt") {painter.renderWork.geometryRebuilds>beforeWrap.geometryRebuilds}
            try require(painter.renderWork.geometryRebuilds>beforeWrap.geometryRebuilds && editor.selectedRange()==chosen,"Wrapping did not invalidate real geometry or retain UTF-16 selection")
            let wrapped=painter.renderWork
            model.hoveredLine=2001
            try await wait("wrapped hover paint receipt") {painter.renderWork.highlightRowsPainted>wrapped.highlightRowsPainted}
            try require(painter.renderWork.documentRebuilds==wrapped.documentRebuilds && painter.renderWork.geometryRebuilds==wrapped.geometryRebuilds && painter.renderWork.baseStylePasses==wrapped.baseStylePasses,"Wrapped hover invalidated document/geometry/base styles")
            model.hoveredLine=nil;try await settle()
            // Use the production protocol decoder with a deterministic private
            // helper. No public API or installed lexer mutation is required.
            let helperDirectory=directory.appendingPathComponent("native-lexer",isDirectory:true)
            try FileManager.default.createDirectory(at:helperDirectory,withIntermediateDirectories:true)
            let helper=helperDirectory.appendingPathComponent("lexer")
            let script="#!/bin/sh\nbytes=$(/usr/bin/wc -c < \"$3\")\nbytes=$((bytes))\nprintf 'lexilla\\t1\\nname\\ttest\\nrange\\t0\\t%s\\t1\\n' \"$bytes\"\n"
            try script.write(to:helper,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            let configuration: [String:Any] = ["extensions":["swift"],"lexer":"test","wordlists":[:],"styles":["1":["foreground":[200,10,30],"background":[230,240,250],"bold":true,"font":"Menlo","eolFilled":true]]]
            let manifest: [String:Any] = ["version":1,"configurations":[configuration],"no_extension":configuration]
            try JSONSerialization.data(withJSONObject:manifest).write(to:helperDirectory.appendingPathComponent("BlameLexers.json"))
            let syntaxText=editor.string
            let styled=try await Task.detached {try BlameSyntax.highlight(syntaxText,filename:"large.swift",executable:helper)}.value
            model.syntaxOperation={_,_,_,_,token in syntaxToken=token;return try await withCheckedThrowingContinuation {syntaxReply=$0}}
            model.setSyntaxEnabled(true)
            try await wait("owned syntax request") {syntaxReply != nil && model.syntaxWorking}
            try await settle();let beforeSyntax=painter.renderWork
            syntaxReply?.resume(returning:styled);syntaxReply=nil
            try await wait("styled native source") {!model.syntaxWorking && BlameWindowModel.activeSyntaxRequests==0}
            try await settle()
            let afterSyntax=painter.renderWork,eol=NSAttributedString.Key("TurtleGitBlameEOLFill")
            let syntaxColor=color(1000)?.usingColorSpace(.sRGB)
            try require(abs((syntaxColor?.redComponent ?? 0)-200.0/255)<0.01 && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil) != nil,"Completed syntax result did not paint actual foreground/EOL styles")
            let font=editor.textStorage?.attribute(.font,at:offset(1000),effectiveRange:nil) as? NSFont
            try require(font.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)}==true && afterSyntax.geometryRebuilds==beforeSyntax.geometryRebuilds+1,"Syntax font completion did not invalidate native geometry exactly once")
            model.selectedLogHashes=[model.lines[1000].hash]
            try await wait("selected syntax foreground/EOL override") {color(1000)==NSColor.alternateSelectedControlTextColor && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil)==nil}
            try require(color(1000)==NSColor.alternateSelectedControlTextColor && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil)==nil,"Selected revision failed to override syntax foreground/EOL fill")
            model.selectedLogHashes=[]
            try await wait("restored syntax foreground/EOL") {color(1000)==NSColor(srgbRed:200.0/255,green:10.0/255,blue:30.0/255,alpha:1) && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil) != nil}
            try require(color(1000)==NSColor(srgbRed:200.0/255,green:10.0/255,blue:30.0/255,alpha:1) && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil) != nil,"Clearing revision selection failed to restore cached syntax foreground/EOL fill")
            // Same historical bytes can receive a new history list (for
            // example a filtering/attribution option drops the selected hash).
            // Exercise the actual install/selection-intersection boundary: old
            // selected colors must be restored without rebuilding syntax/fonts.
            let installed=model.snapshot!,fullHistory=model.historyEntries,selectedHash=model.lines[1000].hash
            model.selectedLogHashes=[selectedHash]
            try await wait("same-byte history selected foreground") {color(1000)==NSColor.alternateSelectedControlTextColor}
            try require(color(1000)==NSColor.alternateSelectedControlTextColor,"Same-byte history fixture did not first select its real revision")
            let beforeHistory=painter.renderWork
            model.install(installed,history:fullHistory.filter{$0.hash != selectedHash},options:GitBlameOptions())
            try await wait("same-byte history restored syntax foreground/EOL") {model.selectedLogHashes.isEmpty && color(1000)==NSColor(srgbRed:200.0/255,green:10.0/255,blue:30.0/255,alpha:1) && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil) != nil}
            try require(model.selectedLogHashes.isEmpty && color(1000)==NSColor(srgbRed:200.0/255,green:10.0/255,blue:30.0/255,alpha:1) && editor.textStorage?.attribute(eol,at:offset(1000),effectiveRange:nil) != nil,"Same-byte history replacement retained stale selected foreground/EOL styling")
            try require(painter.renderWork.documentRebuilds==beforeHistory.documentRebuilds && painter.renderWork.baseStylePasses==beforeHistory.baseStylePasses && painter.renderWork.geometryRebuilds==beforeHistory.geometryRebuilds,"Same-byte history replacement unnecessarily rebuilt source, syntax/fonts or glyph geometry")
            let beforeRestoredHistory=painter.renderWork.attributionReloads
            model.install(installed,history:fullHistory,options:GitBlameOptions())
            try await wait("restored full history attribution receipt") {painter.renderWork.attributionReloads>beforeRestoredHistory}
            let beforeStyledHover=painter.renderWork
            model.hoveredLine=1001
            try await wait("styled hover paint receipt") {painter.renderWork.highlightRowsPainted>beforeStyledHover.highlightRowsPainted}
            try require(painter.renderWork.baseStylePasses==beforeStyledHover.baseStylePasses && painter.renderWork.geometryRebuilds==beforeStyledHover.geometryRebuilds && painter.renderWork.foregroundRowsStyled==beforeStyledHover.foregroundRowsStyled,"Styled hover reapplied complete syntax/font attributes or geometry")
            model.hoveredLine=nil;model.setMargin(.date,visible:true);try await settle()
            let sample=model.lines[0].date,iso=ISO8601DateFormatter().string(from:sample),absoluteNow=Date()
            try require(model.attributionDate(sample,now:absoluteNow)==HistoryDateSettings.load(defaults:prefs).format(iso,now:absoluteNow),"Attribution ignored configured invariant date formatting")
            prefs.set(true,forKey:"RelativeTimes");model.applyPreferences();try await settle()
            let relativeNow=Date()
            try require(model.attributionDate(sample,now:relativeNow)==HistoryDateSettings.load(defaults:prefs).format(iso,now:relativeNow),"Attribution ignored relative date preferences")
            let secondsSample=relativeNow.addingTimeInterval(-15),later=relativeNow.addingTimeInterval(2)
            try require(model.attributionDate(secondsSample,now:relativeNow) != model.attributionDate(secondsSample,now:later),"Relative-second attribution remained stale inside one minute")
            let finalFile=try Data(contentsOf:file),finalIndex=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
            let finalHead=(try await repo.run(["rev-parse","HEAD"])).text
            try require(finalFile==original && finalIndex==index,"Read-only rendering changed working file/index")
            try require(finalHead==head,"Read-only rendering changed HEAD")
            model.setSyntaxEnabled(false);try await settle()
            lines[0] += " // reloaded same count"
            try await saveCommit("Native reload same count")
            let beforeReload=painter.renderWork
            model.reload()
            try await wait("same-count annotation reload") {!model.busy && model.lines.count==3000 && editor.string==lines.joined(separator:"\n")+"\n"}
            try await settle()
            try require(painter.renderWork.documentRebuilds>beforeReload.documentRebuilds && painter.renderWork.attributionReloads>beforeReload.attributionReloads,"Same-count changed historical bytes reused stale document/attribution state")
            lines.append("let newlyAppended = 3001")
            try await saveCommit("Native reload new count")
            model.reload()
            try await wait("new-count annotation reload") {!model.busy && model.lines.count==3001 && editor.string==lines.joined(separator:"\n")+"\n"}
            try await settle()
            let lastBackground=painter.renderedRowBackground(3000),beforeNewHover=painter.renderWork
            model.hoveredLine=3001
            try await wait("appended-origin hover paint receipt") {painter.renderWork.highlightRowsPainted>beforeNewHover.highlightRowsPainted}
            try require(painter.renderedRowBackground(3000) != lastBackground && painter.renderWork.documentRebuilds==beforeNewHover.documentRebuilds,"Reloaded annotation indexes omitted the appended origin or rebuilt on hover")
            model.setSyntaxEnabled(true)
            try await wait("retirement syntax read") {syntaxReply != nil && model.syntaxWorking}
            controller.close()
            try require(syntaxToken?.isCancelled==true && model.retired && !editor.isSelectable,"Owner retirement did not cancel the active syntax receipt and retire its native source")
            let retired=painter.renderWork
            syntaxReply?.resume(returning:styled);syntaxReply=nil
            await cleanup();model.hoveredLine=1;try await settle()
            try require(painter.renderWork==retired,"Retired native renderer accepted a late syntax or published update; before=\(retired), after=\(painter.renderWork), retired=\(model.retired), selectable=\(editor.isSelectable)")
            print("PASS: 3000-line Blame retained source/selection/viewport and changed only affected paint, with cached geometry/date preferences")
        } catch {await cleanup();throw error}
    }
}
