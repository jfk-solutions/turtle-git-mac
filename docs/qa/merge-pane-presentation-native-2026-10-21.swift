// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergePanePresentationVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?,line:Int = #line,_ ready:()->Bool)async throws{
        for _ in 0..<2000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Pane presentation timeout at \(line)")
    }
    static func editors(_ owner:FileComparisonWindowController)->[NSTextView]{views(owner.window?.contentView).compactMap{$0 as? NSTextView}.filter{$0 is MergeFindProviding}}
    static func headers(_ owner:FileComparisonWindowController)->[MergePaneHeaderView]{views(owner.window?.contentView).compactMap{$0 as? MergePaneHeaderView}}
    static func settled(_ owner:FileComparisonWindowController)async throws{
        func ready()->Bool {
            let model=owner.model,panes=editors(owner)
            guard !model.busy,!model.filtering,!model.lineWrapping.isGeometryPending,model.alignment != nil,panes.count==(model.onePaneActive ? 1:2),!model.initialNavigationPending,model.alignmentSelections.isEmpty,model.selectionRequest==nil else{return false}
            return panes.allSatisfy {view in
                guard let pane=view as? MergeFindProviding,let scroll=view.enclosingScrollView else{return false}
                let base=pane.mergeFindPaneID==1,cells=model.displayCells(base:base)
                let expected=cells.map(\.displayText).joined(separator:"\n")+(cells.isEmpty ? "":"\n")
                return model.ownsViewport(scroll,base:base) && model.ownsEditor(scroll,base:base) && view.string.utf8.elementsEqual(expected.utf8)
            }
        }
        // A visible outgoing pane can coexist briefly with its newly registered
        // replacement. Wait for actual model ownership and its display projection.
        try await wait(owner.window,ready)
        await Task.yield()
        try await wait(owner.window,ready)
    }
    static func marked(_ window:NSWindow?,labels:[String],counts:[Int],actual:()->[MergePaneMarkCount])async throws {
        let suffix=zip(labels,counts).filter{$0.1>0}.map{"\($0.0): \($0.1)"}.joined(separator:" | ")
        do{try await wait(window){
            guard actual().map(\.label)==labels,actual().map(\.count)==counts,let field=views(window?.contentView).compactMap({$0 as? NSTextField}).first(where:{$0.identifier?.rawValue=="Merge.Status.MarkedWords" && $0.window === window}) else{return false}
            return suffix.isEmpty ? field.stringValue.isEmpty:field.stringValue.hasSuffix(suffix)
        }}catch{
            let fields=views(window?.contentView).compactMap{$0 as? NSTextField}.filter{$0.identifier?.rawValue.hasPrefix("Merge.Status.")==true}.map{"\($0.identifier!.rawValue)=\(String(reflecting:$0.stringValue)) attached=\($0.window === window) hidden=\($0.isHiddenOrHasHiddenAncestor)"}
            print("Marked status diagnostic expected=\(labels)/\(counts) model=\(actual()) fields=\(fields)");throw error
        }
    }
    /// Independent ASCII fixture oracle over actual native display fragments,
    /// including offscreen rows. Whole token matching is re-evaluated at each
    /// fragment boundary; hidden folds do not become an occurrence counter.
    static func fragmentCount(_ word:String,in view:NSTextView)->Int {
        guard let layout=view.layoutManager,let container=view.textContainer,let storage=view.textStorage else{return -1}
        layout.ensureLayout(for:container);let text=view.string as NSString
        var total=0,markers=Set<Int>()
        layout.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:layout.numberOfGlyphs)){_,_,_,glyphs,_ in
            let range=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            guard range.length>0,range.location<text.length,NSMaxRange(range)<=text.length,storage.attribute(.mergeFoldHidden,at:range.location,effectiveRange:nil)==nil else{return}
            let fragment:String
            if storage.attribute(.mergeFoldMarker,at:range.location,effectiveRange:nil) != nil {
                let row=text.lineRange(for:NSRange(location:range.location,length:0));guard markers.insert(row.location).inserted else{return};fragment=text.substring(with:row)
            }else{fragment=text.substring(with:range)}
            if fragment.split(whereSeparator:{$0==" " || $0=="\t" || $0=="\r" || $0=="\n"}).contains(Substring(word)){total += 1}
        }
        return total
    }
    static func projectedMarks(window:NSWindow,panes:()->[NSTextView],actual:()->[MergePaneMarkCount],labels:[String],unwrappedCounts:[Int]?=nil,longWordCounts:[Int]?=nil,wrap:(Bool)->Void,collapse:(Bool)->Void,settle:()async throws->Void)async throws {
        func mark(_ word:String){for pane in panes(){(pane as! MergeFindProviding).mergeFindHighlights.mark(word,in:pane)}}
        let original=panes().map(\.string),word=String(repeating:"q",count:400)
        let baseline=unwrappedCounts ?? Array(repeating:50,count:labels.count),longBaseline=longWordCounts ?? Array(repeating:1,count:labels.count)
        var phase="initial unwrapped"
        do {
        wrap(false);collapse(false);try await settle();mark("alpha")
        try await marked(window,labels:labels,counts:baseline,actual:actual)
        try require(zip(panes(),baseline).allSatisfy{($0 as! MergeFindProviding).mergeFindHighlights.markedRanges.count==$1*2},"Screen-row status lost independent occurrence painting")
        phase="scroll invariant"
        for pane in panes(){if let scroll=pane.enclosingScrollView{scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,pane.bounds.height-scroll.contentSize.height)));scroll.reflectScrolledClipView(scroll.contentView)}}
        try await marked(window,labels:labels,counts:baseline,actual:actual)
        phase="folded"
        let beforeFold=panes().map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds}
        collapse(true);try await settle()
        try await wait(window){panes().map{fragmentCount("alpha",in:$0)}.allSatisfy{$0>0 && $0<50}}
        try await marked(window,labels:labels,counts:panes().map{fragmentCount("alpha",in:$0)},actual:actual)
        try require(zip(panes().map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds},beforeFold).allSatisfy{$0>$1},"Fold changed native geometry without rebuilding screen-row status")
        phase="expanded long word"
        collapse(false);try await settle();mark(word)
        try await marked(window,labels:labels,counts:longBaseline,actual:actual)
        try require(zip(panes(),longBaseline).allSatisfy{($0 as! MergeFindProviding).mergeFindHighlights.markedRanges.count==$1},"Long word occurrence painting changed")
        phase="narrow wrapped long word"
        window.setContentSize(.init(width:900,height:720));wrap(true);try await settle()
        try await wait(window){panes().allSatisfy{$0.textContainer?.widthTracksTextView==true && fragmentCount(word,in:$0)==0}}
        try await marked(window,labels:labels,counts:Array(repeating:0,count:labels.count),actual:actual)
        phase="narrow wrapped alpha"
        mark("alpha");let narrow=panes().map{fragmentCount("alpha",in:$0)}
        try await marked(window,labels:labels,counts:narrow,actual:actual)
        phase="wide resize"
        let beforeResize=panes().map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds}
        window.setContentSize(.init(width:1800,height:720));try await settle()
        try await wait(window){panes().map{fragmentCount("alpha",in:$0)} != narrow}
        try await marked(window,labels:labels,counts:panes().map{fragmentCount("alpha",in:$0)},actual:actual)
        try require(zip(panes().map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds},beforeResize).allSatisfy{$0>$1},"Resize changed fragments without rebuilding screen-row status")
        phase="final unwrapped"
        wrap(false);try await settle()
        try await marked(window,labels:labels,counts:baseline,actual:actual)
        try require(panes().map(\.string)==original,"Wrapping/folding/resize changed native source bytes")
        }catch {
            let details=panes().map{view -> String in
                let target=view as! MergeFindProviding
                let logical=view.string.split(separator:"\n",omittingEmptySubsequences:false).filter{$0.split(separator:" ").contains("alpha")}.count
                var fragments=0
                if let layout=view.layoutManager,let container=view.textContainer {layout.ensureLayout(for:container);layout.enumerateLineFragments(forGlyphRange:.init(location:0,length:layout.numberOfGlyphs)){_,_,_,_,_ in fragments += 1}}
                return "pane=\(target.mergeFindPaneID) id=\(ObjectIdentifier(view)) attached=\(view.window === window) textLength=\(view.string.utf16.count) logicalAlphaRows=\(logical) painted=\(target.mergeFindHighlights.markedRanges.count) findLines=\(target.mergeFindLines.count) nativeFragments=\(fragments) alphaFragments=\(fragmentCount("alpha",in:view)) widthTracks=\(view.textContainer?.widthTracksTextView == true) container=\(String(describing:view.textContainer?.containerSize)) lineBreak=\(String(describing:view.textContainer?.lineBreakMode)) frame=\(view.frame) font=\(String(describing:view.font))"
            }
            print("Marked projection phase diagnostic phase=\(phase) model=\(actual()) panes=\(details)");throw error
        }
    }
    static func markedFixture(_ changed:Bool)->String {
        (0..<50).map{row in
            if row==25{return "alpha alpha "+String(repeating:"q",count:400)+(changed ? " changed":"")}
            return "alpha "+String(repeating:"padding ",count:10)+"alpha"
        }.joined(separator:"\n")+"\n"
    }
    static func two(root:URL,git:URL)async throws {
        _ = git // This family decodes private external files; no Git process required.
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let left=root.appendingPathComponent("left literal\n"+String(repeating:"long",count:20)+".txt"),right=root.appendingPathComponent("right literal.txt")
        let leftBytes=Data("\talpha 😀 alpha beta\nalpha beta\n".utf8),rightBytes=Data("\talpha 😀 alpha beta\nchanged alpha beta\n".utf8)
        try leftBytes.write(to:left);try rightBytes.write(to:right)
        let suite="TurtleGit.MergePanePresentation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"TurtleGitMerge.UseUTF8")
        var palette=MergeColorPreferences();palette.light[.removed] = .init(0xffffff,0x123456);palette.light[.added] = .init(0xffffff,0x654321)
        palette.dark[.removed] = .init(0xffffff,0x18304a);palette.dark[.added] = .init(0xffffff,0x4a3018);try palette.save(to:prefs)
        var owners:[FileComparisonWindowController]=[]
        func own()throws->FileComparisonWindowController{
            let controller=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
            controller.model.commentProfileURL=root.appendingPathComponent("unused-profiles")
            owners.append(controller);controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-20000,y:-20000));controller.window?.orderFront(nil);controller.model.load();return controller
        }
        func clean()async{
            for owner in owners{owner.close()}
            for _ in 0..<1500{if owners.allSatisfy({!$0.model.hasPendingEditorChoice && !$0.model.busy && !$0.model.filtering}) && FileListComparisonSession.activeOperations==0{return};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do{
            let owner=try own(),model=owner.model;try await settled(owner)
            guard let window=owner.window,let base=editors(owner).first(where:{($0 as? MergeFindProviding)?.mergeFindPaneID==1}),let mine=editors(owner).first(where:{($0 as? MergeFindProviding)?.mergeFindPaneID==2}) else{throw Failure(description:"Actual private Compare panes missing")}
            try await wait(window){headers(owner).count==2}
            try require(headers(owner).contains{$0.titleField.toolTip?.contains(left.path)==true && $0.titleField.stringValue.contains("↵")},"Literal full path tooltip or single-line display substitution lost")
            try require(headers(owner).allSatisfy{$0.titleField.frame.width<window.frame.width && $0.titleField.frame.height <= $0.frame.height},"Long header expanded/overflowed source pane")
            window.appearance=NSAppearance(named:.aqua)
            try await wait(window){headers(owner).allSatisfy{$0.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua}}
            for header in headers(owner){
                let width=Int(ceil(header.bounds.width)),height=Int(ceil(header.bounds.height))
                guard width>8,height>8,let space=CGColorSpace(name:CGColorSpace.sRGB),let canvas=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let pixels=canvas.data?.assumingMemoryBound(to:UInt8.self) else{throw Failure(description:"Explicit sRGB native drawing context unavailable")}
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current=NSGraphicsContext(cgContext:canvas,flipped:false)
                header.effectiveAppearance.performAsCurrentDrawingAppearance{header.draw(header.bounds)}
                NSGraphicsContext.restoreGraphicsState()
                let expected:UInt32=header.titleField.toolTip?.contains(left.path)==true ? 0x123456:0x654321
                let offset=(4*width+4)*4,actual=[Int(pixels[offset]),Int(pixels[offset+1]),Int(pixels[offset+2])]
                try require(zip(actual,[Int((expected>>16)&255),Int((expected>>8)&255),Int(expected&255)]).allSatisfy{abs($0-$1)<=1},"Source Removed/Added header ignored private palette: expected \(String(expected,radix:16)), actual \(actual)")
            }
            // Hit-test the center of the actual title, then deliver its native
            // mouse event to the hit view. AX press alone misses child controls
            // consuming clicks before the header receives mouseDown.
            _ = window.makeFirstResponder(mine)
            guard let titleHeader=headers(owner).first(where:{$0.titleField.toolTip?.contains(left.path)==true}) else{throw Failure(description:"Actual left header missing")}
            let center=NSPoint(x:titleHeader.titleField.bounds.midX,y:titleHeader.titleField.bounds.midY)
            let hitPoint=titleHeader.titleField.convert(center,to:titleHeader.superview)
            guard let hit=titleHeader.hitTest(hitPoint),hit === titleHeader else{throw Failure(description:"Central title consumed native pane-focus click")}
            let location=titleHeader.titleField.convert(center,to:nil)
            guard let event=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1) else{throw Failure(description:"Native title click event unavailable")}
            hit.mouseDown(with:event)
            try require(window.firstResponder === base,"Actual title-center mouseDown did not focus its editor")
            base.setSelectedRange(NSRange(location:10,length:0));model.refreshPaneStatus()
            try require(model.focusedPresentationPane==true && model.paneStatusColumn==11,"Focused UTF16 column incorrectly expanded tab or scalar-counted emoji")
            model.setWrapLines(true);try await wait(window){model.wrapLines};model.refreshPaneStatus()
            try require(model.paneStatusColumn==11,"Wrapping changed logical source column")
            (base as! MergeFindProviding).mergeFindHighlights.mark("alpha",in:base);(mine as! MergeFindProviding).mergeFindHighlights.mark("alpha",in:mine)
            try await marked(window,labels:["L","R"],counts:[2,2],actual:{model.paneStatusMarked})
            try require([base,mine].allSatisfy{($0 as! MergeFindProviding).mergeFindHighlights.markedRanges.count==3},"Same-row alpha occurrence painting changed")
            // Alpha paints three occurrences; both words occupy two screen rows here.
            (base as! MergeFindProviding).mergeFindHighlights.mark("beta",in:base);(mine as! MergeFindProviding).mergeFindHighlights.mark("beta",in:mine)
            try await marked(window,labels:["L","R"],counts:[2,2],actual:{model.paneStatusMarked})
            base.isHidden=true;model.refreshPaneStatus()
            try await marked(window,labels:["L","R"],counts:[0,2],actual:{model.paneStatusMarked})
            base.isHidden=false;model.refreshPaneStatus()
            try await marked(window,labels:["L","R"],counts:[2,2],actual:{model.paneStatusMarked})
            let statusBuilds=[base,mine].map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds}
            _=window.makeFirstResponder(base);base.setSelectedRange(.init(location:1,length:0));model.refreshPaneStatus()
            try await wait(window){model.paneStatusColumn==2}
            try await marked(window,labels:["L","R"],counts:[2,2],actual:{model.paneStatusMarked})
            try require([base,mine].map{($0 as! MergeFindProviding).mergeFindHighlights.screenRowStatusBuilds}==statusBuilds,"Caret-only column update rebuilt screen-row projection")
            let counts=views(window.contentView).compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue=="Merge.Status.MarkedWords"}
            try require(counts?.stringValue.contains("L: 2 | R: 2")==true,"Actual status fields lost source role/count order")
            try require((counts?.superview?.frame.height ?? 100)<40,"Status indicators expanded the source single-line footer")
            _ = window.makeFirstResponder(mine);model.editingEnabled=true
            try require(model.canTransfer(toBase:false),"Private destination did not enable editing")
            try await wait(window){mine.isEditable && model.canTransfer(toBase:false)}
            mine.insertText("edited ",replacementRange:NSRange(location:0,length:0));try await settled(owner)
            try await wait(window){headers(owner).contains{$0.titleField.stringValue.hasPrefix("* ")}}
            try require(model.paneModified(base:false) && !model.paneModified(base:true),"Header dirty marker did not follow actual edited pane")
            try await MergePatchCapture.save(window,"compare-pane-status")
            let retained=model.panePresentationAction(base:true)
            model.confirmingQuit=true;model.confirmingQuit=false
            try require(!retained(),"Retired Compare activation falsely reported success")
            try require(window.firstResponder === mine,"Retained pane activation revived after Quit")
            // Palette role remains a displayed-position property when sides swap.
            let leftBefore=model.document?.base.path,rightBefore=model.document?.destination.path
            model.presentProjectionQuestion={alert,_,answer in
                guard let index=alert.buttons.firstIndex(where:{$0.title=="Don’t Save"}) else{return}
                answer(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+index))
            }
            model.switchSides();try await settled(owner)
            try require(model.document?.base.path==rightBefore && model.document?.destination.path==leftBefore,"Actual side switch fixture failed")
            try require(!model.paneModified(base:true) && !model.paneModified(base:false),"Discard-and-swap retained stale modified header")
            let oldHeaders=headers(owner)
            model.switchPaneMode(true);try await settled(owner)
            try await wait(window){headers(owner).count==1}
            let oneView=editors(owner)[0];_ = window.makeFirstResponder(oneView);model.editingEnabled=true
            try await wait(window){oneView.isEditable && model.canTransfer(toBase:false)}
            oneView.insertText("combined ",replacementRange:NSRange(location:0,length:0));try await settled(owner)
            try await wait(window){headers(owner)[0].titleField.stringValue.hasPrefix("* ")}
            (oneView as! MergeFindProviding).mergeFindHighlights.mark("beta",in:oneView)
            try await marked(window,labels:["L"],counts:[fragmentCount("beta",in:oneView)],actual:{model.paneStatusMarked})
            try await MergePatchCapture.save(window,"compare-one-pane-status")
            for header in oldHeaders{_ = header.accessibilityPerformPress()}
            try require(window.firstResponder === oneView,"Dismantled header retargeted a replacement pane")
            model.setStatusBarVisible(false);try await wait(window){!views(window.contentView).contains{$0.identifier?.rawValue=="Merge.Status.Column"}}
            model.setStatusBarVisible(true);try await wait(window){views(window.contentView).contains{$0.identifier?.rawValue=="Merge.Status.Column"}}
            try await marked(window,labels:["L"],counts:[fragmentCount("beta",in:oneView)],actual:{model.paneStatusMarked})
            // No Save command is issued: model editing/headers leave original bytes.
            try require(try Data(contentsOf:left)==leftBytes && Data(contentsOf:right)==rightBytes,"Pane presentation saved private input unexpectedly")
            let finalHeaders=headers(owner);owner.close()
            for header in finalHeaders{try require(!header.accessibilityPerformPress(),"Closed header accepted activation")}
            prefs.set(false,forKey:"TurtleGitMerge.OnePane")
            let read=try own();try await settled(read);read.model.configureMergeToolReadOnly(true);try await settled(read)
            guard let readView=editors(read).first else{throw Failure(description:"Readonly actual pane missing")}
            try await wait(read.window){!readView.isEditable && !read.model.canTransfer(toBase:true) && !read.model.canTransfer(toBase:false)}
            let focused=read.window?.makeFirstResponder(readView);readView.setSelectedRange(NSRange(location:2,length:0));read.model.refreshPaneStatus()
            print("Readonly presentation diagnostic: focus=\(String(describing:focused)) actual=\(read.window?.firstResponder === readView) attached=\(readView.window === read.window) selection=\(readView.selectedRange()) column=\(read.model.paneStatusColumn) direct=\(MergePanePresentation.column(in:readView)) role=\((readView as! MergeFindProviding).mergeFindPaneID) one=\(read.model.onePaneActive) prefix=\(String(reflecting:String(readView.string.prefix(45))))")
            (readView as! MergeFindProviding).mergeFindHighlights.mark("beta",in:readView)
            try await wait(read.window){read.model.paneStatusMarked.contains{$0.count==2}}
            var reportedReadonlyMismatch=false
            try await wait(read.window){
                let valid=read.model.paneStatusColumn==3
                if !valid && !reportedReadonlyMismatch {
                    reportedReadonlyMismatch=true
                    let scroll=readView.enclosingScrollView
                    let current=editors(read).map {view -> String in
                        let role=(view as? MergeFindProviding)?.mergeFindPaneID ?? -1,base=role==1
                        let owned=view.enclosingScrollView.map{read.model.ownsViewport($0,base:base) && read.model.ownsEditor($0,base:base)} ?? false
                        return "id=\(ObjectIdentifier(view)) role=\(role) owned=\(owned) selected=\(view.selectedRange()) column=\(MergePanePresentation.column(in:view)) focus=\(read.window?.firstResponder === view)"
                    }
                    print("Readonly postmark diagnostic: savedView=\(ObjectIdentifier(readView)) attached=\(readView.window === read.window) owner=\(scroll.map{read.model.ownsViewport($0,base:true)} ?? false) selection=\(readView.selectedRange()) direct=\(MergePanePresentation.column(in:readView)) status=\(read.model.paneStatusColumn) focusedRole=\(String(describing:read.model.focusedPresentationPane)) alignment=\(read.model.alignmentGeneration) initial=\(read.model.initialNavigationPending) selectionRequest=\(String(describing:read.model.selectionRequest)) alignmentSelections=\(read.model.alignmentSelections.count) current=\(current)")
                }
                return valid
            }
            try require(!read.model.canTransfer(toBase:true) && !read.model.canTransfer(toBase:false),"Readonly policy allowed editing")
            let untouched=read.model.draftText(base:false);readView.insertText("forbidden",replacementRange:NSRange(location:0,length:0))
            try require(read.model.draftText(base:false)==untouched && !read.model.dirty,"Readonly pane status allowed a document mutation")
            let markedLeft=root.appendingPathComponent("marked-left.txt"),markedRight=root.appendingPathComponent("marked-right.txt")
            try Data(markedFixture(false).utf8).write(to:markedLeft);try Data(markedFixture(true).utf8).write(to:markedRight)
            let projected=FileComparisonWindowController(comparison:try WorkingFileComparison(base:markedLeft,destination:markedRight),permissions:[],preferences:prefs)
            owners.append(projected);projected.model.commentProfileURL=root.appendingPathComponent("unused-marked-profiles");projected.window?.alphaValue=0;projected.showWindow(nil);projected.model.load();try await settled(projected)
            guard let projectedWindow=projected.window else{throw Failure(description:"Marked Compare window missing")}
            try await projectedMarks(window:projectedWindow,panes:{editors(projected).sorted{($0 as! MergeFindProviding).mergeFindPaneID<($1 as! MergeFindProviding).mergeFindPaneID}},actual:{projected.model.paneStatusMarked},labels:["L","R"],wrap:projected.model.setWrapLines,collapse:projected.model.setCollapsed,settle:{try await settled(projected)})
            await clean()
        }catch{await clean();throw error}
        print("PASS Compare pane identity/status: literal bounded headers, source palette/focus/dirty roles, UTF16 caret, actual marked counts, swaps/one-pane/status visibility and retired activation")
    }
}
