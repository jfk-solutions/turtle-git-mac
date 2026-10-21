// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ImageIO
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func graphMetafileHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));graphMetafileHiddenOrder(place,relativeTo:number)
    }
}
actor GraphMetafileWriteGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var released=false
    private(set) var data:Data?,url:URL?,token:OperationCancellation?
    var entered:Bool {data != nil}
    var cancelled:Bool {token?.isCancelled==true}
    func write(_ data:Data,to url:URL,cancellation:OperationCancellation)async throws {
        self.data=data;self.url=url;token=cancellation
        if !released {await withCheckedContinuation{continuation=$0}}
        try await StatisticsGraphExport.write(data:data,to:url,cancellation:cancellation)
    }
    func finish(){released=true;continuation?.resume();continuation=nil}
}

@MainActor @main enum GraphMetafileFamilyVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    struct Record {let type:Int,offset:Int,size:Int}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(message:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(message:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Graph metafile timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {StatisticsWindowController.activeExports==0 && StatisticsWindowModel.activeOperations==0 && RevisionGraphWindowModel.activeOperations==0 && RevisionGraphWindowController.activeExportOperations==0}
    static func word(_ bytes:Data,_ offset:Int)->Int {Int((0..<4).reduce(UInt32(0)){$0|UInt32(bytes[offset+$1])<<($1*8)})}
    static func records(_ bytes:Data,size:CGSize)throws->[Record] {
        try require(bytes.count>=108 && word(bytes,0)==1 && word(bytes,4)==88 && word(bytes,40)==0x464d4520,"Not a real enhanced-metafile header")
        try require(word(bytes,48)==bytes.count && word(bytes,16)==Int(ceil(size.width)) && word(bytes,20)==Int(ceil(size.height)),"EMF header bounds/byte count drifted")
        var result:[Record]=[],offset=0
        while offset<bytes.count {
            try require(offset<=bytes.count-8,"Truncated EMF record header")
            let type=word(bytes,offset),length=word(bytes,offset+4)
            try require(length>=8 && length%4==0 && length<=bytes.count-offset,"Invalid EMF record framing")
            result.append(Record(type:type,offset:offset,size:length));offset+=length
        }
        try require(offset==bytes.count && result.count==word(bytes,52) && result.last?.type==14,"EMF EOF/count mismatch")
        try require(result.filter{$0.type==62}.count>4 && result.contains{$0.type==59} && result.contains{$0.type==67},"Graph was not painted as actual vector paths/clips")
        try require(!result.contains{[76,77,80,81,83,84,96,108].contains($0.type)},"Graph used whole-page transfer or unresolved text records")
        for record in result where record.type==114 {
            try require(record.size>=108,"Truncated color-label bitmap")
            let width=CGFloat(word(bytes,record.offset+32))/64,height=CGFloat(word(bytes,record.offset+36))/64
            try require(width>0 && height>0 && width*height<size.width*size.height/2,"Color-font fallback rasterized the whole graph")
        }
        return result
    }
    struct Pixels {
        let width:Int,height:Int,rgba:[UInt8]
        init(_ image:CGImage)throws {
            let width=image.width,height=image.height
            var storage=[UInt8](repeating:0,count:width*height*4)
            try storage.withUnsafeMutableBytes {buffer in
                guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure(message:"Pixel inspection unavailable")}
                context.interpolationQuality = .none;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            };self.width=width;self.height=height;rgba=storage
        }
        func sample(_ x:Int,_ y:Int)->[Int] {let offset=(y*width+x)*4;return (0..<4).map{Int(rgba[offset+$0])}}
        func count(_ color:[Int],inside rect:CGRect,tolerance:Int=3)->Int {
            let bounds=rect.integral.intersection(CGRect(x:0,y:0,width:width,height:height));guard !bounds.isNull else{return 0}
            var total=0
            for y in Int(bounds.minY)..<Int(bounds.maxY) {for x in Int(bounds.minX)..<Int(bounds.maxX) {let pixel=sample(x,y);if (0..<3).allSatisfy({abs(pixel[$0]-color[$0])<=tolerance}) && pixel[3]==255 {total+=1}}};return total
        }
    }
    static func png(_ data:Data)throws->CGImage {let source=try unwrap(CGImageSourceCreateWithData(data as CFData,nil),"Invalid native PNG");return try unwrap(CGImageSourceCreateImageAtIndex(source,0,nil),"Native PNG has no pixels")}
    static func decoded(_ bytes:Data,name:String)async throws->CGImage {
        // One real bundled conversion; retain thrown diagnostics instead of hiding
        // a timeout behind a nil ComparisonImage result or retrying the decoder.
        let svg=try await Task.detached(priority:.userInitiated){try MetafileImageDecoder.convert(bytes)}.value
        let converted=try unwrap(svg,"Decoder did not recognize EMF "+name)
        return try unwrap(ComparisonImage(bytes:converted)?.pixels,"Bundled helper SVG did not render "+name)
    }
    static func interiors(_ native:Pixels,_ decoded:Pixels,_ name:String)throws {
        try require(native.width==decoded.width && native.height==decoded.height,"Decoded canvas changed "+name)
        var checked=0,failures=0,first=""
        // Only opaque five-by-five flat interiors are witnesses. This avoids
        // comparing two renderers' edge antialiasing or font hinting policies.
        for y in stride(from:3,to:native.height-3,by:4) {for x in stride(from:3,to:native.width-3,by:4) {
            let expected=native.sample(x,y)
            guard expected[3]==255 else{continue}
            let uniform=(-2...2).allSatisfy{dy in (-2...2).allSatisfy{dx in let p=native.sample(x+dx,y+dy);return (0..<4).allSatisfy{abs(p[$0]-expected[$0])<=1}}}
            guard uniform else{continue};checked+=1
            let actual=decoded.sample(x,y)
            if !(0..<4).allSatisfy({abs(actual[$0]-expected[$0])<=3}) {failures+=1;if first.isEmpty{first="(\(x),\(y)) \(expected) vs \(actual)"}}
        }}
        try require(checked>100 && failures==0,"Flat graph interiors diverged \(name): \(failures)/\(checked), \(first)")
    }
    static func withAppearance<T>(_ appearance:NSAppearance,_ body:()throws->T)throws->T {
        var result:Result<T,Error>?
        appearance.performAsCurrentDrawingAppearance {result=Result{try body()}}
        return try result!.get()
    }
    static func nativeImage(size:CGSize,draw:()->Void)throws->CGImage {
        let width=Int(size.width),height=Int(size.height)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw Failure(message:"Native drawing unavailable")}
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true);draw()
        return try unwrap(context.makeImage(),"Native graph backing missing")
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.GraphMetafile."+UUID().uuidString,prefs:UserDefaults
        var owners:[NSWindowController]=[],gates:[GraphMetafileWriteGate]=[],entries:[LogEntry]=[],snapshot:[String:Data]=[:]
        var repo:GitRepository {GitRepository(root:base.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        var layout:URL {URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/graph-layout-runtime/GraphLayout/graph-layout")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set("Menlo",forKey:"LogFontName");DialogGeometry.install(preferences:prefs)}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Graph metafile QA"),("user.email","vector@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            let authors=["café","漢字","العربية","Turtle 🐢"]
            let schedule=[Int](repeating:0,count:7)+[Int](repeating:1,count:6)+[Int](repeating:2,count:2)+[3]
            for n in 0..<32 {
                try Data("line \(n)\n".utf8).write(to:repo.root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"])
                let date="2024-01-\(String(format:"%02d",1+n/16*7))T12:00:00Z"
                _=try await repo.run(["commit","-m","Vector \(n)"],environmentOverrides:["GIT_AUTHOR_NAME":authors[schedule[n%16]],"GIT_AUTHOR_EMAIL":"author@example.invalid","GIT_AUTHOR_DATE":date,"GIT_COMMITTER_DATE":date])
                if n==0 || n==5 {_=try await repo.run(["tag",n==0 ? "漢字" : "العربية"])}
            }
            _=try await repo.run(["branch","Turtle-🐢"]);_=try await repo.run(["update-ref","refs/remotes/origin/main","HEAD"]);_=try await repo.run(["tag","café"])
            entries=try await repo.history()
            for path in [".git/HEAD",".git/index",".git/config",".git/refs/heads/main","file.txt"] {snapshot[path]=try Data(contentsOf:repo.root.appendingPathComponent(path))}
        }
        func statistics()async throws->StatisticsWindowController {
            let owner=StatisticsWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),entries:entries,defaults:prefs);owners.append(owner);owner.window?.appearance=NSAppearance(named:.aqua);owner.showWindow(nil)
            owner.model.selectMetric(.commitsByDate);try await wait{owner.canSaveGraph && owner.model.graph != nil};return owner
        }
        func revision()async throws->RevisionGraphWindowController {
            let owner=RevisionGraphWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),preferences:prefs,layoutExecutable:layout,automaticallyLoad:false);owners.append(owner);owner.window?.appearance=NSAppearance(named:.aqua);owner.showWindow(nil);owner.model.load()
            try await wait{!owner.model.busy && owner.model.geometry != nil && !owner.hasPendingWork};try require(owner.model.error==nil,"Revision Graph load failed: "+(owner.model.error ?? "unknown"));return owner
        }
        func artifact(_ data:Data,name:String)throws {
            let folder=base.appendingPathComponent("artifacts",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try data.write(to:folder.appendingPathComponent(name))
        }
        func preserved()throws {for(path,bytes)in snapshot {try require(try Data(contentsOf:repo.root.appendingPathComponent(path))==bytes,"Graph export changed original Git state "+path)}}
        func clean()async {
            owners.forEach{$0.close()};for gate in gates {await gate.finish()}
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained() && owners.allSatisfy({owner in
                if let owner=owner as? StatisticsWindowController{return !owner.hasPendingWork}
                if let owner=owner as? RevisionGraphWindowController{return !owner.hasPendingWork}
                return true
            }) {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
    }
    static func palette(_ pixels:Pixels,graph:LogStatisticsGraph,plot:CGRect,dark:Bool,name:String)throws {
        let background=dark ? 32.0:255.0
        let colors=graph.colors.map{[Double($0.red),Double($0.green),Double($0.blue)]}
        var counts=[Int](repeating:0,count:colors.count)
        let bounds=plot.insetBy(dx:1,dy:1).integral.intersection(CGRect(x:0,y:0,width:pixels.width,height:pixels.height))
        for y in Int(bounds.minY)..<Int(bounds.maxY) {for x in Int(bounds.minX)..<Int(bounds.maxX) {
            let pixel=pixels.sample(x,y);var matches:[Int]=[]
            for(index,color)in colors.enumerated() {
                let ray=color.map{$0-background},norm=ray.reduce(0){$0+$1*$1};guard norm>1 else{continue}
                let sample=(0..<3).map{Double(pixel[$0])-background}
                let alpha=zip(sample,ray).reduce(0.0){$0+$1.0*$1.1}/norm
                if alpha>=0.25 && alpha<=1.01 && zip(sample,ray).allSatisfy({abs($0.0-alpha*$0.1)<=3}) {matches.append(index)}
            }
            if matches.count==1 {counts[matches[0]]+=1}
        }}
        for(index,count)in counts.enumerated(){try require(count>8,"Lost independent plot palette \(index) in \(name): \(count)")}
    }
    static func statistics(_ c:Context)async throws {
        let owner=try await c.statistics(),graph=try unwrap(owner.model.graph,"Missing actual statistics graph"),size=CGSize(width:720,height:420)
        let labels=graph.seriesLabels.map{Data($0.utf8)}
        for name in ["café","漢字","العربية","Turtle 🐢"] {try require(labels.contains(Data(name.utf8)),"Git author label missing "+name)}
        for dark in [false,true] {for style in LogStatisticsStyle.allCases {
            owner.model.selectStyle(style)
            let view=StatisticsVectorNativeView(frame:CGRect(origin:.zero,size:size)),window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.contentView=view
            let holder=NSWindowController(window:window);c.owners.append(holder);holder.showWindow(nil)
            view.update(graph:graph,style:style,size:size,dark:dark,interactive:true)
            let drawing=try unwrap(view.drawing,"Actual native chart has no immutable scene")
            try require(!drawing.accessibilityLabels.isEmpty && drawing.accessibilityLabels.count==graph.points.count,"Native scene lost accessible values")
            let expected=try nativeImage(size:size){view.draw(view.bounds)}
            let bytes=try StatisticsGraphExport.data(graph:graph,metric:graph.metric,style:style,size:size,dark:dark,format:.emf)
            let alias=try StatisticsGraphExport.data(graph:graph,metric:graph.metric,style:style,size:size,dark:dark,format:.wmf)
            try require(bytes==alias,"WMF suffix did not retain actual enhanced-EMF source convention")
            try c.artifact(bytes,name:"statistics-\(style.rawValue)-\(dark).emf")
            try c.artifact(MacGraphVectorRenderer.raster(drawing.scene,type:.png),name:"statistics-\(style.rawValue)-\(dark).png")
            _=try records(bytes,size:size)
            let actual=try await decoded(bytes,name:"statistics \(style) dark=\(dark)")
            let actualPixels=try Pixels(actual)
            try interiors(Pixels(expected),actualPixels,"statistics \(style) dark=\(dark)")
            try palette(actualPixels,graph:graph,plot:drawing.plotBounds,dark:dark,name:"\(style)/\(dark)")
            let resolved=try MacGraphVectorRenderer.resolvedText(drawing.scene)
            try require(!resolved.commands.contains{if case .text = $0{return true};return false},"Unicode labels remained unresolved text")
            // A color emoji may use a label-local bitmap. It may never replace
            // the source-colored paths or consume a whole graph-sized bitmap.
            for command in resolved.commands {if case .raster(let raster)=command {try require(raster.rect.width*raster.rect.height<size.width*size.height/2,"Color glyph fallback consumed graph")}}
            holder.close()
        }}
        // Explicit native shaping witnesses for Latin, CJK, right-to-left and
        // bitmap/color glyph fallback, with independent nonempty ink bands.
        let words=["café","漢字","العربية","Turtle 🐢"],font=NSFont.systemFont(ofSize:24),size2=CGSize(width:360,height:180)
        var commands:[GraphVectorCommand]=[.fill(path:.rectangle(CGRect(origin:.zero,size:size2)),color:.white,rule:.nonZero)]
        for(index,word)in words.enumerated(){commands.append(.text(.init(text:word,origin:CGPoint(x:12,y:32+index*40),fontName:font.fontName,fontSize:24)))}
        let scene=GraphVectorScene(size:size2,commands:commands),resolved=try MacGraphVectorRenderer.resolvedText(scene)
        try require(resolved.commands.contains{if case .raster = $0{return true};return false},"Native color emoji did not take a label-local fallback")
        let bytes=try MacGraphVectorRenderer.emf(scene),image=try await decoded(bytes,name:"Unicode shaping"),pixels=try Pixels(image)
        for index in words.indices {let ink=pixels.count([0,0,0],inside:CGRect(x:8,y:index*40+6,width:320,height:30),tolerance:24);try require(ink>10,"Unicode label lost native ink: "+words[index])}
        let native=try png(MacGraphVectorRenderer.raster(scene,type:.png));try interiors(Pixels(native),pixels,"Unicode shaping")
        try c.preserved()
    }
    static func revision(_ c:Context)async throws {
        let owner=try await c.revision(),model=owner.model,geometry=try unwrap(model.geometry,"No graph geometry")
        let ordered=geometry.nodes.sorted{$0.rect.minY>$1.rect.minY};try require(ordered.count>=3,"Insufficient real decorated Git graph")
        model.select(ordered[0].hash,extending:false);model.select(ordered[1].hash,extending:true)
        let canvas=try unwrap(views(owner.window?.contentView).compactMap{$0 as? RevisionGraphCanvas}.first,"Actual graph canvas missing")
        for dark in [false,true] {
            let appearance=try unwrap(NSAppearance(named:dark ? .darkAqua:.aqua),"Missing appearance");owner.window?.appearance=appearance
            for direction in [false,true] {
                model.arrowsTowardMerges=direction;model.zoom=1
                let bytes=try owner.graphExportData(format:.emf),alias=try owner.graphExportData(format:.wmf),size=try RevisionGraphExport.size(canvas:canvas,viewport:owner.window!.contentView!.bounds.size,format:.emf)
                // Use actual header dimensions because the canvas viewport is
                // smaller than the outer form and is the source export viewport.
                let actualSize=CGSize(width:word(bytes,16),height:word(bytes,20))
                try require(bytes==alias && actualSize.width>0 && size.width>=actualSize.width,"Revision suffix alias or source vector sizing changed")
                try c.artifact(bytes,name:"revision-\(dark)-\(direction).emf")
                try c.artifact(owner.graphExportData(format:.png),name:"revision-\(dark)-\(direction).png")
                let parsed=try records(bytes,size:actualSize)
                try require(parsed.contains{$0.type==64},"Revision arrows/selection lost vector strokes")
                let image=try await decoded(bytes,name:"revision graph"),pixels=try Pixels(image)
                let native=try withAppearance(appearance) {try nativeImage(size:actualSize) {
                    NSColor.textBackgroundColor.setFill();CGRect(origin:.zero,size:actualSize).fill()
                    NSGraphicsContext.current?.cgContext.translateBy(x:10,y:10);canvas.drawGraph(text:true,renderingZoom:1)
                }}
                try interiors(Pixels(native),pixels,"revision scene/native canvas")
                let nodes=Dictionary(uniqueKeysWithValues:model.nodes.map{($0.hash,$0)})
                try withAppearance(appearance) {
                    for item in geometry.nodes {
                        guard let node=nodes[item.hash] else{continue}
                        let labels=model.lines(node),height=item.rect.height/CGFloat(labels.count)
                        for(index,line)in labels.enumerated() {
                            let background=RevisionGraphVectorScene.color(RevisionGraphPalette.background(line.1,pointer:line.2,preferences:c.prefs)),rgb=[background.red,background.green,background.blue].map{Int(($0*255).rounded())}
                            let x=Int(item.rect.maxX+10-10),y=Int(item.rect.minY+10+(CGFloat(index)+0.5)*height)
                            let value=pixels.sample(x,y)
                            try require((0..<3).allSatisfy{abs(value[$0]-rgb[$0])<=3},"Node reference band lost color: "+line.0)
                        }
                    }
                    for(index,item)in ordered.prefix(2).enumerated() {
                        let color=index==0 ? NSColor.selectedControlColor:NSColor(srgbRed:136.0/255,green:0,blue:21.0/255,alpha:1),rgb=RevisionGraphVectorScene.color(color)
                        let expected=[rgb.red,rgb.green,rgb.blue].map{Int(($0*255).rounded())}
                        for x in (index==0 ? [10]:[5,15]) {
                            let pixel=pixels.sample(Int(item.rect.minX)+10+x,Int(item.rect.minY)+10-15)
                            try require((0..<3).allSatisfy{abs(pixel[$0]-expected[$0])<=3},"Selection marker missing index \(index)")
                        }
                    }
                }
                let scene=RevisionGraphVectorScene.make(model:model,size:actualSize,zoom:1)
                try require(scene.commands.contains{if case .text(let text)=$0{return text.text=="(Base)"};return false},"Source Base label absent from shared vector scene")
                let svg=String(decoding:try MacGraphVectorRenderer.svg(scene),as:UTF8.self)
                try require(svg.contains("(Base)") && svg.contains("漢字") && svg.contains("العربية") && svg.contains("Turtle-🐢"),"SVG lost raw descriptions/native outlined labels")
            }
        }
        // Public drawing entry still paints the same shared scene under the
        // caller's graph transform, including native text and selection markers.
        let graphSize=CGSize(width:ceil(geometry.size.width+20),height:ceil(geometry.size.height+20));model.zoom=1
        let direct=try withAppearance(owner.window!.effectiveAppearance) {try nativeImage(size:graphSize){NSColor.textBackgroundColor.setFill();CGRect(origin:.zero,size:graphSize).fill();NSGraphicsContext.current?.cgContext.translateBy(x:10,y:10);canvas.drawGraph(text:true,renderingZoom:1)}}
        let exported=try png(owner.graphExportData(format:.png));try interiors(Pixels(direct),Pixels(exported),"public drawGraph entry")
        let vectorAtOne=try owner.graphExportData(format:.emf)
        model.zoom=2
        let zoomed=try png(owner.graphExportData(format:.png)),unzoomed=try owner.graphExportData(format:.emf)
        try require(zoomed.width==Int(ceil(geometry.size.width*2+20)) && zoomed.height==Int(ceil(geometry.size.height*2+20)),"Raster export discarded current zoom")
        try require(unzoomed==vectorAtOne,"Vector export unexpectedly followed raster zoom")
        try c.preserved()
    }
    static func enter(_ gate:GraphMetafileWriteGate)async throws {for _ in 0..<3000 {if await gate.entered{return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Captured graph writer did not begin")}
    static func ownership(_ c:Context)async throws {
        let stats=try await c.statistics();stats.model.selectStyle(.bar);stats.model.graphSize=CGSize(width:640,height:360)
        let graph=try unwrap(stats.model.graph,"Missing save graph"),expected=try StatisticsGraphExport.data(graph:graph,metric:stats.model.metric,style:stats.model.style,size:stats.model.graphSize,dark:false,format:.emf)
        let gate=GraphMetafileWriteGate();c.gates.append(gate);stats.writeGraph={data,url,token in try await gate.write(data,to:url,cancellation:token)}
        let target=c.base.appendingPathComponent("captured.WMF"),sibling=c.base.appendingPathComponent("never.emf")
        var selected=target,reply:((NSApplication.ModalResponse)->Void)?
        stats.selectedSaveURL={_ in selected};stats.presentSavePanel={panel,owner,answer in reply=answer;owner.beginSheet(panel)}
        stats.saveGraphAs();let picker=try unwrap(stats.savePanel,"Actual Statistics save panel absent")
        picker.panel.nameFieldStringValue=target.lastPathComponent;reply?(.OK)
        selected=sibling;picker.panel.nameFieldStringValue=sibling.lastPathComponent;picker.formats.selectItem(at:1);picker.changeFormat();stats.model.graphSize=CGSize(width:900,height:700);stats.window?.appearance=NSAppearance(named:.darkAqua);reply?(.OK)
        try await enter(gate)
        let data=await gate.data,url=await gate.url
        try require(data==expected && url==target,"Statistics accepted suffix/immutable scene retargeted after reply")
        await gate.finish();try await wait{!stats.hasPendingWork}
        try require(try Data(contentsOf:target)==expected,"Statistics selected .wmf did not publish exact EMF")
        try require(!FileManager.default.fileExists(atPath:sibling.path),"Duplicate Statistics reply wrote sibling")
        let revision=try await c.revision();revision.model.zoom=1
        let prior=try revision.graphExportData(format:.emf),revisionGate=GraphMetafileWriteGate();c.gates.append(revisionGate)
        revision.writeGraph={data,url,token in try await revisionGate.write(data,to:url,cancellation:token)}
        let revisionTarget=c.base.appendingPathComponent("revision.emf");var revisionReply:((NSApplication.ModalResponse)->Void)?
        revision.selectedSaveURL={_ in revisionTarget};revision.presentSavePanel={panel,owner,answer in revisionReply=answer;owner.beginSheet(panel)}
        revision.saveGraph();let revisionPicker=try unwrap(revision.graphSavePanel,"Actual Revision chooser absent")
        revisionPicker.panel.nameFieldStringValue=revisionTarget.lastPathComponent
        // Palette/appearance mutation is not a topology change. Export must
        // still use the graph shown when Save was invoked, not reread defaults.
        c.prefs.set(0x1234ab,forKey:LogColorRole.currentBranch.preferenceKey);c.prefs.set(0xab3412,forKey:LogColorRole.tag.preferenceKey)
        revision.window?.appearance=NSAppearance(named:.darkAqua);revisionReply?(.OK)
        revisionPicker.panel.nameFieldStringValue="wrong.wmf";revisionReply?(.OK)
        try await enter(revisionGate)
        let captured=await revisionGate.data,capturedURL=await revisionGate.url
        try require(captured==prior && capturedURL==revisionTarget,"Revision chooser did not capture immutable scene/final suffix")
        await revisionGate.finish();try await wait{!revision.hasPendingWork}
        try require(try Data(contentsOf:revisionTarget)==prior,"Revision .emf did not publish captured vector bytes")
        // Denied final sibling must be refused before any receiver write.
        let invalid=try await c.statistics();invalid.selectedSaveURL={_ in c.base.appendingPathComponent("ungranted.custom")};invalid.presentSavePanel={_,_,answer in answer(.OK)}
        var error:NSAlert?,errorReply:((NSApplication.ModalResponse)->Void)?
        invalid.presentExportError={alert,window,answer in error=alert;errorReply=answer;alert.beginSheetModal(for:window,completionHandler:answer)}
        invalid.saveGraphAs();try await wait{error?.window.sheetParent===invalid.window}
        try require(!FileManager.default.fileExists(atPath:c.base.appendingPathComponent("ungranted.custom.jpg").path),"Final URL validation wrote ungranted normalized sibling")
        error?.buttons.first?.performClick(nil);try await wait{!invalid.hasPendingWork};errorReply?(.alertFirstButtonReturn)
        // Actual held writer survives visual close only until real drainage.
        for isRevision in [false,true] {
            let held=GraphMetafileWriteGate();c.gates.append(held)
            let destination=c.base.appendingPathComponent(isRevision ? "held-revision.wmf":"held-statistics.emf"),sentinel=Data("existing vector destination".utf8);try sentinel.write(to:destination)
            var closed=0
            if isRevision {
                let owner=try await c.revision();owner.writeGraph={data,url,token in try await held.write(data,to:url,cancellation:token)};owner.selectedSaveURL={_ in destination};owner.presentSavePanel={_,_,answer in answer(.OK)};owner.onClosed={closed+=1};owner.saveGraph();try await enter(held);owner.close()
                try require(closed==0 && owner.hasPendingWork && RevisionGraphWindowController.activeExportOperations>0,"Revision close discarded accepted writer")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored Revision writer")
                let cancelled=await held.cancelled;try require(cancelled,"Revision close failed to cancel writer")
                await held.finish();try await wait{closed==1 && !owner.hasPendingWork}
            } else {
                let owner=try await c.statistics();owner.writeGraph={data,url,token in try await held.write(data,to:url,cancellation:token)};owner.selectedSaveURL={_ in destination};owner.presentSavePanel={_,_,answer in answer(.OK)};owner.onClosed={closed+=1};owner.saveGraphAs();try await enter(held);owner.close()
                try require(closed==0 && owner.hasPendingWork && StatisticsWindowController.activeExports>0,"Statistics close discarded accepted writer")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored Statistics writer")
                let cancelled=await held.cancelled;try require(cancelled,"Statistics close failed to cancel writer")
                await held.finish();try await wait{closed==1 && !owner.hasPendingWork}
            }
            try require(try Data(contentsOf:destination)==sentinel,"Cancelled writer replaced original destination")
        }
        // A cancelled Quit permanently retires the old chooser intent.
        let stale=try await c.revision(),staleTarget=c.base.appendingPathComponent("quit.wmf");var staleReply:((NSApplication.ModalResponse)->Void)?
        stale.selectedSaveURL={_ in staleTarget};stale.presentSavePanel={_,_,answer in staleReply=answer};stale.saveGraph();stale.model.confirmingQuit=true;stale.model.confirmingQuit=false;staleReply?(.OK);staleReply?(.OK)
        try await wait{!stale.hasPendingWork};try require(!FileManager.default.fileExists(atPath:staleTarget.path),"Cancelled Quit revived Revision export")
        try c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.graphMetafileHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let c=Context()
        do {
            try await c.seed();let which=CommandLine.arguments[3]
            switch which {case "statistics":try await statistics(c);case "revision":try await revision(c);case "ownership":try await ownership(c);default:throw Failure(message:"Unknown graph metafile group")}
            await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Graph metafile owners did not drain")
            print("PASS: graph metafile family "+which)
        } catch {await c.clean();throw error}
    }
}
