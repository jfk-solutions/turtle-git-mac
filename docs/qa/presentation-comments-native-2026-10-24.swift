// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum PresentationCommentsVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(message:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Comment review timeout at \(line)")}
    static func package(modern:Bool,new:Bool)throws->PresentationPackage {
        var entries=try PresentationRevisionNativeVerification.package("Same shapes").entries
        let p="http://schemas.openxmlformats.org/presentationml/2006/main",a="http://schemas.openxmlformats.org/drawingml/2006/main",r="http://schemas.openxmlformats.org/officeDocument/2006/relationships",m="http://schemas.microsoft.com/office/powerpoint/2018/8/main"
        func put(_ name:String,_ text:String){entries[name]=Data(text.utf8)}
        func append(_ name:String,_ end:String,_ addition:String){put(name,String(data:entries[name]!,encoding:.utf8)!.replacingOccurrences(of:end,with:addition+end))}
        let author=modern ? "{00000000-0000-0000-0000-000000000001}":"0"
        let second=modern ? "{00000000-0000-0000-0000-000000000002}":"1"
        func identity(_ n:Int)->String{modern ? String(format:"{10000000-0000-0000-0000-%012d}",n):String(n)}
        func comment(_ n:Int,_ text:String,_ reply:Bool=false)->String {
            if modern {
                let tag=reply ? "reply":"cm",status=new && (n==1 || reply) ? "resolved":"active"
                let anchor=reply ? "":"<pc:sldMkLst xmlns:pc=\"http://schemas.microsoft.com/office/powerpoint/2013/main/command\"><pc:sldMk sldId=\"256\"/></pc:sldMkLst>"
                let nested=n==1 ? "<p188:replyLst>"+comment(2,new ? "New reply":"Base reply",true)+"</p188:replyLst>":""
                return "<p188:\(tag) id=\"\(identity(n))\" authorId=\"\(reply ? second:author)\" created=\"2026-10-24T10:00:00Z\" status=\"\(status)\">\(anchor)\(nested)<p188:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p188:txBody></p188:\(tag)>"
            }
            let threading=reply ? "<p:extLst><p:ext uri=\"{TURTLEGIT-THREAD-FIXTURE}\"><p15:threadingInfo xmlns:p15=\"http://schemas.microsoft.com/office/powerpoint/2012/main\" timeZoneBias=\"0\"><p15:parentCm authorId=\"0\" idx=\"1\"/></p15:threadingInfo></p:ext></p:extLst>":""
            return "<p:cm authorId=\"\(reply ? second:author)\" idx=\"\(n)\" dt=\"2026-10-24T10:00:00Z\"><p:pos x=\"10\" y=\"20\"/><p:text>\(text)</p:text>\(threading)</p:cm>"
        }
        let root=comment(1,new ? "New root":"Base root"),reply=modern ? "":comment(2,new ? "New reply":"Base reply",true)
        let comments=root+reply+comment(3,"Unchanged context")+comment(new ? 5:4,new ? "Added comment":"Deleted comment")
        let part=modern ? "ppt/comments/modern.xml":"ppt/comments/comment1.xml",authors=modern ? "ppt/authors.xml":"ppt/commentAuthors.xml"
        put(part,modern ? "<p188:cmLst xmlns:p188=\"\(m)\" xmlns:a=\"\(a)\">\(comments)</p188:cmLst>":"<p:cmLst xmlns:p=\"\(p)\">\(comments)</p:cmLst>")
        if modern {
            put(authors,"<p188:authorLst xmlns:p188=\"\(m)\"><p188:author id=\"\(author)\" name=\"Alice\" initials=\"A\" userId=\"alice@example.test\" providerId=\"AD\"/><p188:author id=\"\(second)\" name=\"Bob\" initials=\"B\" userId=\"bob@example.test\" providerId=\"AD\"/></p188:authorLst>")
            append("ppt/slides/slide1.xml","</p:sld>","<p:extLst><p:ext uri=\"{TURTLEGIT-COMMENT-FIXTURE}\"><p188:commentRel xmlns:p188=\"\(m)\" r:id=\"comments\"/></p:ext></p:extLst>")
        } else {put(authors,"<p:cmAuthorLst xmlns:p=\"\(p)\"><p:cmAuthor id=\"0\" name=\"Alice\" initials=\"A\" lastIdx=\"5\" clrIdx=\"0\"/><p:cmAuthor id=\"1\" name=\"Bob\" initials=\"B\" lastIdx=\"2\" clrIdx=\"1\"/></p:cmAuthorLst>")}
        let relationship=modern ? "http://schemas.microsoft.com/office/2018/10/relationships/":r+"/"
        append("ppt/slides/_rels/slide1.xml.rels","</Relationships>","<Relationship Id=\"comments\" Type=\"\(relationship)comments\" Target=\"../comments/\(modern ? "modern.xml":"comment1.xml")\"/>")
        append("ppt/_rels/presentation.xml.rels","</Relationships>","<Relationship Id=\"authors\" Type=\"\(relationship)\(modern ? "authors":"commentAuthors")\" Target=\"\(modern ? "authors.xml":"commentAuthors.xml")\"/>")
        let commentType=modern ? "application/vnd.ms-powerpoint.comments+xml":"application/vnd.openxmlformats-officedocument.presentationml.comments+xml",authorType=modern ? "application/vnd.ms-powerpoint.authors+xml":"application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"
        append("[Content_Types].xml","</Types>","<Override PartName=\"/\(part)\" ContentType=\"\(commentType)\"/><Override PartName=\"/\(authors)\" ContentType=\"\(authorType)\"/>")
        return try PresentationPackage(entries:entries)
    }
    final class Gate:@unchecked Sendable {
        private let lock=NSLock();private var started=false,released=false
        func enter(){lock.lock();started=true;lock.unlock()}
        func isStarted()->Bool{lock.lock();defer{lock.unlock()};return started}
        func release(){lock.lock();released=true;lock.unlock()}
        func isReleased()->Bool{lock.lock();defer{lock.unlock()};return released}
    }
    @MainActor final class Context {
        let root:URL,a:URL,b:URL,review:PresentationRevisionReview,document:FileComparisonDocument,suite:String,prefs:UserDefaults,originalA:Data,originalB:Data
        var owners:[PresentationComparisonWindowController]=[],gates:[Gate]=[]
        init(modern:Bool)throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            a=root.appendingPathComponent("base.pptx");b=root.appendingPathComponent("new.pptx")
            let base=try package(modern:modern,new:false),new=try package(modern:modern,new:true)
            review=try PresentationRevisionReview(base:base,destination:new);originalA=try base.encoded(cancellation:.init());originalB=try new.encoded(cancellation:.init());try originalA.write(to:a);try originalB.write(to:b)
            document=try WorkingFileComparison(base:a,destination:b).read();suite="TurtleGit.Comments."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"EnableGravatar")
        }
        func owner()throws->PresentationComparisonWindowController {
            let preview=try PresentationComparisonPreview.prepare(document,in:root,cancellation:.init())
            let owner=PresentationComparisonWindowController(preview:preview,manifest:.init(base:review.baseManifest,destination:review.destinationManifest),permissions:[],preferences:prefs,baseTitle:a.path,destinationTitle:b.path,protectedInputs:[a,b],initialReview:review)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.window?.orderFront(nil);owner.model.clipboard=NSPasteboard(name:.init("TurtleGit.Comments."+UUID().uuidString));owners.append(owner);return owner
        }
        func cleanup()async {
            gates.forEach{$0.release()};owners.forEach{$0.presentDiscard={_,_,reply in reply(true)};$0.close()}
            for _ in 0..<3000{if PresentationComparisonWindowModel.activeRequests==0 && owners.allSatisfy({$0.model.pending==0}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.window?.orderOut(nil);$0.model.clipboard.releaseGlobally()};prefs.removePersistentDomain(forName:suite)
        }
    }
    static func run(modern:Bool,_ body:(Context)async throws->Void)async throws {
        let c=try Context(modern:modern)
        do{try await body(c);try require(Data(contentsOf:c.a)==c.originalA && Data(contentsOf:c.b)==c.originalB,"Comment review changed either source");await c.cleanup();try require(PresentationComparisonWindowModel.activeRequests==0 && c.owners.allSatisfy{$0.model.pending==0},"Comment review left owned workers")}
        catch{await c.cleanup();throw error}
    }
    static func key(_ model:PresentationRevisionWindowModel,_ text:String,new:Bool=true)throws->String {
        guard let id=model.review?.commentChanges.first(where:{(new ? $0.value.destination:$0.value.base)?.text==text})?.key else{throw Failure(message:"Missing comment: "+text)};return id
    }
    static func review()async throws {
        for modern in [false,true] {try await run(modern:modern){c in
            let owner=try c.owner(),model=owner.model.revision;try await wait{owner.model.pending==0}
            try require(model.review?.baseComments.count==4 && model.review?.destinationComments.count==4,"Comment inventories incomplete")
            let root=try key(model,"New root"),reply=try key(model,"New reply"),unchanged=try key(model,"Unchanged context")
            try require(model.review?.destinationComments.contains{$0.author=="Bob" && $0.parentID != nil && $0.depth==1 && $0.isModern==modern}==true,"Thread author/parent/depth lost")
            try require(model.review?.destinationComments.allSatisfy{!$0.created.isEmpty && (!$0.anchor.isEmpty || $0.parentID != nil)}==true,"Comment dates/anchors missing")
            if modern {try require(model.review?.destinationComments.filter{$0.text=="New root" || $0.text=="New reply"}.allSatisfy{$0.status=="resolved"}==true,"Modern status lost")}
            model.reviewEntries = .comments;model.selection=root
            try require(model.visibleChanges.count==5 && model.selectedComment?.destination?.text=="New root" && owner.model.current?.base?.pageIndex==0,"Comments filter/slide selection incoherent")
            owner.model.changesOnly=true;try require(owner.model.visibleIndices==[0],"Comments-only slide vanished in Changes only")
            let first=model.commentRows[0].id;model.selection=first
            model.navigateComment(1);let next=model.selection;try require(next != first && model.selectedComment != nil,"Next comment did not select comment")
            model.navigateComment(-1);try require(model.selection==first,"Previous comment did not restore comment")
            model.selectCommentRecord(model.review!.commentChanges[reply]!.destination!.id,destination:true);try require(model.selection==reply,"Thread record selection did not select revision")
            model.deleteComment(root);try require(model.review?.commentIsDeleted(changeID:reply)==true && model.decisionLabel(reply)=="Deleted comment","Parent deletion did not cover reply")
            model.selection=reply;try require(!model.selectedCommentCanRestore,"Inherited deletion incorrectly restorable at reply")
            model.restoreComment(reply);try require(model.review?.commentIsDeleted(changeID:root)==true,"Reply restored its ancestor")
            model.undo();try require(model.review?.commentIsDeleted(changeID:root)==false && !model.isDirty,"Comment Undo failed")
            model.redo();try require(model.review?.commentIsDeleted(changeID:reply)==true,"Comment Redo failed");model.restoreComment(root)
            model.decideAll(accept:true);model.decide(changeID:reply,accept:false);model.deleteComment(unchanged)
            try require(model.canSave && model.decisionLabel(unchanged)=="Deleted comment","Unchanged context delete did not join review plan")
            owner.model.copyReview();try require(owner.model.clipboard.string(forType:.string)?.contains("Deleted comment")==true && owner.model.reviewText.contains("Base reply") && owner.model.reviewText.contains("Alice"),"Review report omitted comment decisions/context")
            var panels=0;let output=c.root.appendingPathComponent("mixed.pptx");owner.presentExport={_,_,reply in panels += 1;reply(.OK)};owner.selectedExportURL={_ in output};owner.chooseEditableExport()
            try await wait{owner.model.pending==0 && model.savedURL==output}
            let saved=try PresentationPackage.read(from:output,cancellation:.init()),inventory=try PresentationRevisionReview(base:saved,destination:saved).baseComments
            try require(Set(inventory.map(\.text))==Set(["New root","Base reply","Added comment"]),"Editable comment output chose wrong records: \(inventory.map(\.text))")
            try require(inventory.first{$0.text=="Base reply"}?.parentID != nil && !model.isDirty && panels==1,"Editable save lost thread/checkpoint")
            if modern {try require(inventory.first{$0.text=="New root"}?.status=="resolved" && inventory.first{$0.text=="Base reply"}?.status=="active","Mixed modern status lost")}
            if let path=ProcessInfo.processInfo.environment["TURTLEGIT_COMMENTS_OUTPUT_DIR"]{try Data(contentsOf:output).write(to:URL(fileURLWithPath:path).appendingPathComponent(modern ? "comments-modern.pptx":"comments-classic.pptx"),options:.atomic)}
            var renderedComments:[String]=[]
            model.renderResult={package,pdf,token in
                try token.check();let value=try PresentationPackage.read(from:package,cancellation:token),snapshot=try PresentationRevisionReview(base:value,destination:value,cancellation:token)
                renderedComments=snapshot.baseComments.map(\.text)
                var media=CGRect(x:0,y:0,width:640,height:360)
                guard let drawing=CGContext(pdf as CFURL,mediaBox:&media,nil) else{throw Failure(message:"Comment result PDF unavailable")}
                for _ in snapshot.baseManifest.slides {drawing.beginPDFPage(nil);drawing.setFillColor(CGColor(gray:0.9,alpha:1));drawing.fill(media);drawing.endPDFPage()};drawing.closePDF()
                return snapshot.baseManifest
            }
            model.previewResult();try await wait{owner.model.pending==0 && model.resultImages != nil}
            try require(Set(renderedComments)==Set(["New root","Base reply","Added comment"]) && model.resultIsCurrent,"Result adapter did not receive saved comment plan")
            model.restoreComment(unchanged);try require(!model.resultIsCurrent && model.isDirty,"Comment restoration left result marked current")
            model.undo();try require(model.resultIsCurrent && !model.isDirty,"Comment Undo failed to recover saved/rendered decision receipt")
            model.previewMode = .sources
            if modern {model.selection=root;try await capture(owner.window!)}
        }}
    }
    static func lifecycle()async throws {try await run(modern:true){c in
        let owner=try c.owner(),model=owner.model.revision;try await wait{owner.model.pending==0}
        var panels=0;owner.presentExport={_,_,reply in panels += 1;reply(.OK)};owner.chooseEditableExport();try require(panels==0 && !model.canSave,"Unresolved comments opened output panel")
        model.decideAll(accept:true);let unchanged=try key(model,"Unchanged context");model.deleteComment(unchanged);let before=model.review?.decisions
        let gate=Gate();c.gates.append(gate);model.write={data,url,token in gate.enter();while !gate.isReleased(){Thread.sleep(forTimeInterval:0.01)};try token.check();try data.write(to:url,options:.atomic)}
        let output=c.root.appendingPathComponent("cancelled.pptx"),task=Task{do{try await model.save(to:output)}catch{}}
        try await wait{gate.isStarted()};let selected=model.selection,entries=model.reviewEntries
        model.restoreComment(unchanged);model.deleteComment();model.undo();model.decideAll(accept:false);model.navigateComment(1);model.reviewEntries = .comments
        try require(model.review?.decisions==before && model.selection==selected && model.reviewEntries==entries,"Export let live controls change captured comment plan")
        model.cancel();try require(model.exporting && owner.model.pending>0,"Cancel released held comment writer early");gate.release();await task.value;try await wait{owner.model.pending==0}
        try require(!FileManager.default.fileExists(atPath:output.path) && model.savedURL==nil && model.review?.decisions==before && model.isDirty,"Cancelled comment export wrote/checkpointed changed plan")
        let closing=try c.owner(),closed=closing.model.revision,held=Gate();c.gates.append(held);closed.decideAll(accept:true);closed.deleteComment(try key(closed,"Unchanged context"))
        closed.write={data,url,token in held.enter();while !held.isReleased(){Thread.sleep(forTimeInterval:0.01)};try token.check();try data.write(to:url,options:.atomic)}
        let late=c.root.appendingPathComponent("closed.pptx"),saving=Task{do{try await closed.save(to:late)}catch{}}
        try await wait{held.isStarted()};closing.presentDiscard={_,_,reply in reply(true)};closing.close();try await wait{closing.model.retired}
        try require(closing.model.pending>0 && FileManager.default.fileExists(atPath:closing.model.preview.directory.path),"Retired comment export released private inputs before drain")
        held.release();await saving.value;try await wait{closing.model.pending==0 && !FileManager.default.fileExists(atPath:closing.model.preview.directory.path)}
        let frozen=closed.review?.decisions;closed.restoreComment();closed.deleteComment();closed.undo();try require(closed.review?.decisions==frozen && closed.savedURL==nil && !FileManager.default.fileExists(atPath:late.path),"Retired comment receiver accepted late work")
    }}
    static func capturesOnly()async throws {try await run(modern:true){c in
        let owner=try c.owner(),model=owner.model.revision;try await wait{owner.model.pending==0};model.reviewEntries = .comments;model.selection=try key(model,"New root");try await capture(owner.window!)
    }}
    static func capture(_ window:NSWindow)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_COMMENTS_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(message:"Owned comment capture requires macOS 14.4")}
        let original=window.appearance;window.alphaValue=1;window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil)
        defer{window.appearance=original;window.alphaValue=0;window.orderOut(nil)}
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:400_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(message:"Owned offscreen comments window unavailable")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(message:"Comment capture encoding failed")}
            try png.write(to:URL(fileURLWithPath:path).appendingPathComponent("presentation-comments-"+name+".png"),options:.atomic)
        }
    }
}
