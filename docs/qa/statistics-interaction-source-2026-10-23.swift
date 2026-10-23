// Staged native verification. No receiver compilation or execution performed.
import AppKit
import TurtleGitCore

@MainActor enum StatisticsInteractionVerification {
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        if !value {throw NSError(domain:"Statistics interaction: \(message)",code:line)}
    }
    static func graph(dense:Bool=false,firstCount:Int=2)throws->LogStatisticsGraph {
        var entries:[LogEntry]=[]
        for index in 0..<(dense ? 41:3) {
            let date=dense ? String(format:"%04d-01-01T12:00:00Z",1980+index):"2024-01-0\(index+1)T12:00:00Z"
            let count=index==0 ? firstCount:index+1
            for copy in 0..<count {
                entries.append(LogEntry(hash:"\(index)A\(copy)",author:"A",date:date,subject:"",committerDate:date))
            }
            if index==0 {entries.append(LogEntry(hash:"B",author:"B",date:date,subject:"",committerDate:date))}
        }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        return try LogStatisticsGraph.make(LogStatistics.analyze(entries),metric:.commitsByDate,authorsShown:2,calendar:calendar)
    }
    static func verify()throws {
        let graph=try graph(),size=CGSize(width:960,height:500)
        for dark in [false,true] { for style in LogStatisticsStyle.allCases {
            let scene=StatisticsVectorScene.make(graph:graph,style:style,size:size,dark:dark)
            try require(scene.tooltip(at:CGPoint(x:scene.titleBounds.midX,y:scene.titleBounds.midY))=="Title","missing title tooltip")
            if let box=scene.legendBounds {
                // Border and label/swatch/ellipsis whitespace all report Legend.
                try require(scene.tooltip(at:CGPoint(x:box.minX+1,y:box.minY+1))=="Legend","legend border has no tooltip")
                try require(scene.tooltip(at:CGPoint(x:box.midX,y:box.midY))=="Legend","legend replaced with group caption")
            }
            guard let guide=scene.averageBounds else{throw NSError(domain:"No all-style average",code:1)}
            let p=CGPoint(x:guide.midX,y:guide.midY)
            try require(scene.tooltip(at:p)==graph.averageTooltip(style:style),"all-style virtual average missing: \(style)")
            try require(scene.hits.first(where:{$0.role == .average})?.contains(CGPoint(x:guide.maxX,y:guide.maxY))==true,"average inclusive source cutoff changed")
            if style == .stackedLine {try require(scene.hits.allSatisfy{$0.role != .data},"stacked area invented hover regions")}
            if style == .bar || style == .stackedBar {
                guard let first=scene.hits.first(where:{$0.role == .data && $0.series==0 && $0.group==0}),
                      let second=scene.hits.first(where:{$0.role == .data && $0.series==0 && $0.group==1}) else{throw NSError(domain:"Missing source bar neighbors",code:4)}
                let a=first.bounds,b=second.bounds,point:CGPoint
                if style == .bar {
                    try require(a.maxX-b.minX==1,"adjacent source bars do not share one border pixel")
                    point=CGPoint(x:b.minX+0.5,y:max(a.minY,b.minY)+min(a.height,b.height)/2)
                } else {
                    try require(b.maxY-a.minY==1,"stacked source bars do not share one border pixel")
                    point=CGPoint(x:a.midX,y:a.minY+0.5)
                }
                try require(first.contains(point) && second.contains(point),"shared bar border lost one group's hit region")
                try require(!scene.hits.contains{$0.role != .data && $0.contains(point)},"shared group-order sample intersects a higher-priority source region")
                try require(scene.tooltip(at:point)==first.label+", "+second.label,"shared bar tooltip omitted or reordered a group")
            }
            if style == .line {
                guard let hit=scene.hits.first(where:{$0.role == .data}) else{throw NSError(domain:"Missing line hit",code:2)}
                let b=hit.bounds
                try require(b.width==6 && b.height==6,"line marker is not source six-point rectangle")
                try require(hit.contains(CGPoint(x:b.minX+0.1,y:b.minY+0.1)),"line marker lost rectangular corner")
                try require(!hit.contains(CGPoint(x:b.maxX,y:b.midY)),"line marker included exclusive right edge")
                try require(scene.hits.contains{$0.role == .data && $0.label.contains(": 0 ")},"zero-valued line points lost their invisible source regions")
            }
        } }
        // With equal first-interval bars the stacked border lies exactly at
        // the virtual average. Source gives the average precedence there;
        // keep that collision distinct from the unobstructed group-order test.
        let collisionGraph=try self.graph(firstCount:1)
        let collision=StatisticsVectorScene.make(graph:collisionGraph,style:.stackedBar,size:size,dark:false)
        guard let lower=collision.hits.first(where:{$0.role == .data && $0.series==0 && $0.group==0}),
              let upper=collision.hits.first(where:{$0.role == .data && $0.series==0 && $0.group==1}),
              let collisionGuide=collision.hits.first(where:{$0.role == .average}) else{throw NSError(domain:"Missing source collision geometry",code:7)}
        let collisionPoint=CGPoint(x:lower.bounds.midX,y:lower.bounds.minY+0.5)
        try require(lower.contains(collisionPoint) && upper.contains(collisionPoint) && collisionGuide.contains(collisionPoint),"source average/bar collision was not exercised")
        try require(collision.tooltip(at:collisionPoint)==collisionGraph.averageTooltip(style:.stackedBar),"average lost precedence over overlapping bar groups")
        // Tiny first wedge rounds to the same integer endpoint as the
        // leftmost start. The following accepted wedge inherits that start;
        // neither an invisible tooltip nor a gap may be invented for the tiny
        // value. Large line counts avoid building huge commit fixtures.
        let weightedEntries=["A","B","C"].map{LogEntry(hash:$0,author:$0,date:"2024-01-01T12:00:00Z",subject:"",committerDate:"2024-01-01T12:00:00Z")}
        var weightedChanges:[String:LogStatisticsChanges]=[:]
        for (name,value) in [("A",1),("B",100000),("C",100000)] {
            var change=LogStatisticsChanges();change.added=value;weightedChanges[name]=change
        }
        let weighted=try LogStatisticsGraph.make(LogStatistics.analyze(weightedEntries,changes:weightedChanges),metric:.linesIncluding,authorsShown:3,alphabetical:true)
        let pie=StatisticsVectorScene.make(graph:weighted,style:.pie,size:size,dark:false)
        let wedges=pie.hits.filter{$0.role == .data}
        try require(wedges.count==2 && wedges.map(\.group)==[1,2],"integer endpoint cutoff did not suppress only the tiny wedge")
        guard case let .wedge(center,radius,start,end)=wedges[0].shape else{throw NSError(domain:"Missing actual wedge geometry",code:5)}
        try require(start==0 && end>Double.pi-0.1 && end<Double.pi+0.1,"accepted pie wedge did not retain the previous painted endpoint")
        let inside=CGPoint(x:center.x-radius*0.8,y:center.y+radius*0.000001)
        try require(wedges[0].contains(inside),"skipped tiny wedge left a hole in the next accepted wedge")
        let single=try LogStatisticsGraph.make(LogStatistics.analyze([weightedEntries[0]]),metric:.commitsByDate,authorsShown:1)
        let whole=StatisticsVectorScene.make(graph:single,style:.pie,size:size,dark:false)
        guard let only=whole.hits.first(where:{$0.role == .data}),case let .wedge(c,r,_,_)=only.shape else{throw NSError(domain:"Single-valued pie disappeared",code:6)}
        for delta in [CGPoint(x:-0.7,y:0),CGPoint(x:0.7,y:0),CGPoint(x:0,y:-0.7),CGPoint(x:0,y:0.7)] {
            try require(only.contains(CGPoint(x:c.x+delta.x*r,y:c.y+delta.y*r)),"source single nonzero wedge became empty")
        }
        let dense=StatisticsVectorScene.make(graph:try self.graph(dense:true),style:.line,size:size,dark:false)
        try require(dense.hits.allSatisfy{$0.role != .data},"dense 40+ original series incorrectly have line regions")
        // Deliberate overlapping data verifies source first-series selection,
        // group-order concatenation and guide/title/legend precedence.
        let region=CGRect(x:0,y:0,width:20,height:20)
        func hit(_ label:String,_ role:StatisticsVectorScene.Hit.Role = .data,_ series:Int?=nil,_ group:Int?=nil)->StatisticsVectorScene.Hit {
            .init(shape:.rectangle(region),label:label,role:role,series:series,group:group)
        }
        let template=StatisticsVectorScene.make(graph:graph,style:.bar,size:size,dark:false)
        func overlap(_ hits:[StatisticsVectorScene.Hit])->String {
            StatisticsVectorScene(scene:template.scene,accessibilityLabels:[],hits:hits,titleBounds:.zero,averageBounds:nil,plotBounds:.zero,legendBounds:nil,pieBounds:[]).tooltip(at:CGPoint(x:10,y:10))
        }
        try require(overlap([hit("late",.data,1,0),hit("second",.data,0,1),hit("first",.data,0,0)])=="first, second","overlapping source series precedence lost")
        try require(overlap([hit("data",.data,0,0),hit("Average",.average),hit("Title",.title),hit("Legend",.legend)])=="Legend","legend precedence lost")
        try require(overlap([hit("data",.data,0,0),hit("Average",.average),hit("Title",.title)])=="Title","title precedence lost")
        let view=StatisticsVectorNativeView(frame:CGRect(origin:.zero,size:size))
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.alphaValue=0;window.setFrameOrigin(CGPoint(x:-12000,y:-12000));window.contentView=view
        defer{view.retire();window.close()}
        var accepted=true
        view.update(graph:graph,style:.line,size:size,dark:false,interactive:true,acceptsInteraction:{accepted})
        guard let tag=view.installedToolTip,let title=view.drawing?.titleBounds else{throw NSError(domain:"No actual tooltip receipt",code:3)}
        let generation=view.projectionGeneration,point=CGPoint(x:title.midX,y:title.midY)
        func tip(_ tag:NSView.ToolTipTag,_ generation:Int)->String {
            view.view(view,stringForToolTip:tag,point:point,userData:UnsafeMutableRawPointer(bitPattern:generation))
        }
        try require(tip(tag,generation)=="Title","actual native view omitted tooltip")
        accepted=false
        try require(tip(tag,generation).isEmpty,"blocked owner retained tooltip")
        accepted=true
        view.update(graph:graph,style:.bar,size:size,dark:true,interactive:true,acceptsInteraction:{accepted})
        try require(tip(tag,generation).isEmpty,"obsolete projected tooltip receipt revived")
        view.retire()
        try require(tip(tag,generation).isEmpty && view.installedToolTip==nil,"retired view retained tooltip")
    }
}
