// Statistics drawing geometry shared by the native view and every encoder.
// Adapted from pinned MyGraph.cpp; SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor struct StatisticsVectorScene {
    struct Hit {
        enum Shape { case rectangle(CGRect), guide(CGRect), circle(CGPoint,CGFloat), wedge(CGPoint,CGFloat,Double,Double) }
        let shape:Shape
        let label:String
        enum Role { case legend, title, average, data }
        var role:Role = .data
        // Original MyGraphSeries identity, independently of group/color.
        var series:Int? = nil
        var group:Int? = nil
        var bounds:CGRect {
            switch shape {
            case let .rectangle(rect),let .guide(rect):return rect
            case let .circle(center,radius),let .wedge(center,radius,_,_):return CGRect(x:center.x-radius,y:center.y-radius,width:2*radius,height:2*radius)
            }
        }
        func contains(_ point:CGPoint)->Bool {
            switch shape {
            case let .rectangle(rect):return rect.contains(point)
            case let .guide(rect):return point.x>=rect.minX && point.x<=rect.maxX && point.y>=rect.minY && point.y<=rect.maxY
            case let .circle(center,radius):return hypot(point.x-center.x,point.y-center.y)<=radius
            case let .wedge(center,radius,start,end):
                guard hypot(point.x-center.x,point.y-center.y)<=radius else{return false}
                var angle=Double.pi-atan2(point.y-center.y,point.x-center.x)
                if angle>=2 * .pi {angle-=2 * .pi}
                return angle>=start && angle<end
            }
        }
    }
    let scene:GraphVectorScene
    let accessibilityLabels:[String]
    let hits:[Hit]
    let titleBounds:CGRect
    let averageBounds:CGRect?
    let plotBounds:CGRect
    let legendBounds:CGRect?
    let pieBounds:[CGRect]
    func tooltip(at point:CGPoint)->String {
        let matching=hits.filter{$0.contains(point)}
        for role in [Hit.Role.legend,.title,.average] {
            if let hit=matching.first(where:{$0.role == role}) {return hit.label}
        }
        // MyGraph stops after the first original series with any hits. Within
        // that series it reports overlapping group regions in source order.
        guard let series=matching.compactMap(\.series).min() else{return ""}
        return matching.filter{$0.role == .data && $0.series == series}
            .sorted{($0.group ?? 0)<($1.group ?? 0)}.map(\.label).joined(separator:", ")
    }

    static func make(graph:LogStatisticsGraph,style:LogStatisticsStyle,size:CGSize,dark:Bool)->Self {
        let width=max(1,size.width),height=max(1,size.height)
        let foreground:GraphVectorColor=dark ? .init(red:0.92,green:0.92,blue:0.92):.black
        let background:GraphVectorColor=dark ? .init(red:32/255,green:32/255,blue:32/255):.white
        let palette=graph.colors.map{GraphVectorColor(red:Double($0.red)/255,green:Double($0.green)/255,blue:Double($0.blue)/255)}
        var commands:[GraphVectorCommand]=[.fill(path:.rectangle(CGRect(x:0,y:0,width:width,height:height)),color:background,rule:.nonZero)]
        var hits:[Hit]=[],pies:[CGRect]=[]
        var averageBounds:CGRect?
        let totals=Dictionary(grouping:graph.points,by: \.category).mapValues{$0.reduce(0){$0+$1.value}}
        let allTotal=graph.points.reduce(0){$0+$1.value}
        func tooltip(_ point:LogStatisticsGraph.Point)->String {
            let name=graph.metric.byAuthor ? graph.categoryLabels[point.category]:graph.seriesLabels[point.series]
            let total=graph.metric.byAuthor ? allTotal:(totals[point.category] ?? 0)
            let percent=total==0 ? 0:Int(100.0*Double(point.value)/Double(total))
            return "\(name): \(point.value) \(graph.yAxisLabel) (\(percent)%)"
        }
        let accessibilityLabels=graph.points.map{tooltip($0)}
        func font(_ size:CGFloat)->NSFont {NSFont.systemFont(ofSize:size)}
        func displayCaption(_ value:String)->String {
            value.replacingOccurrences(of:"\t",with:"⇥").replacingOccurrences(of:"\r",with:"↵").replacingOccurrences(of:"\n",with:"↵").replacingOccurrences(of:"\u{2028}",with:"↵").replacingOccurrences(of:"\u{2029}",with:"↵")
        }
        func measure(_ text:String,_ size:CGFloat)->CGSize {MacGraphVectorRenderer.measure(displayCaption(text),font:font(size))}
        func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,alignment:GraphVectorTextAlignment = .leading,rotation:CGFloat=0) {
            let caption=displayCaption(value)
            commands.append(.text(.init(text:caption,origin:CGPoint(x:x,y:y),fontName:font(size).fontName,fontSize:size,color:foreground,alignment:alignment,rotation:rotation)))
        }
        func stroke(_ points:[CGPoint],color:GraphVectorColor,width:CGFloat=1) {
            guard let first=points.first else{return}
            commands.append(.stroke(path:.init(segments:[.move(first)]+points.dropFirst().map{.line($0)}),color:color,width:width,dash:[]))
        }
        func polygon(_ points:[CGPoint],color:GraphVectorColor,outline:GraphVectorColor?=nil) {
            guard let first=points.first else{return}
            let path=GraphVectorPath(segments:[.move(first)]+points.dropFirst().map{.line($0)}+[.close])
            commands.append(.fill(path:path,color:color,rule:.nonZero))
            if let outline {commands.append(.stroke(path:path,color:outline,width:1,dash:[]))}
        }
        func circle(_ center:CGPoint,_ radius:CGFloat,color:GraphVectorColor) {
            let path=CGPath(ellipseIn:CGRect(x:center.x-radius,y:center.y-radius,width:2*radius,height:2*radius),transform:nil)
            commands.append(.fill(path:MacGraphVectorRenderer.path(path),color:color,rule:.nonZero))
        }
        let titleSize=max(7,min(32,(width-20)/50)),titleHeight=measure(graph.metric.title,titleSize).height
        text(graph.metric.title,width/2,10+font(titleSize).ascender,titleSize,alignment:.center)
        // The source title rectangle spans the chart width, not only glyph ink.
        let titleBounds=CGRect(x:10,y:10,width:max(0,width-10),height:titleHeight)
        hits.append(.init(shape:.rectangle(titleBounds),label:"Title",role:.title))
        let top=20+titleHeight,bodyHeight=max(1,height-top-10)
        let labelSize=max(7,min(16,bodyHeight/60)),labelHeight=measure("Ag",labelSize).height
        var legend:CGRect?
        if width>320 && !graph.legendLabels.isEmpty {
            let layout=StatisticsLegendLayout(graph:graph,height:bodyHeight)
            let legendWidth=min(layout.width,max(50,width*0.55)),legendHeight=CGFloat(layout.groups.count)*layout.rowHeight+10
            let box=CGRect(x:width-10-legendWidth,y:top+max(0,(bodyHeight-legendHeight)/2),width:legendWidth,height:legendHeight)
            legend=box
            hits.append(.init(shape:.rectangle(box),label:"Legend",role:.legend))
            commands.append(.stroke(path:.rectangle(box),color:foreground,width:1,dash:[]))
            commands.append(.save);commands.append(.clip(path:.rectangle(box.insetBy(dx:4,dy:1)),rule:.nonZero))
            for (row,group) in layout.groups.enumerated() {
                let y=box.minY+5+CGFloat(row)*layout.rowHeight
                text(group.map{graph.legendLabels[$0]} ?? "...",box.minX+5,y+font(layout.fontSize).ascender,layout.fontSize)
                if let group,palette.indices.contains(group) {
                    let sample=CGRect(x:box.maxX-33,y:y+1,width:28,height:max(1,layout.rowHeight-2))
                    // Keep an opaque margin between a long label and its swatch.
                    commands.append(.fill(path:.rectangle(CGRect(x:sample.minX-4,y:y,width:37,height:layout.rowHeight)),color:background,rule:.nonZero))
                    commands.append(.fill(path:.rectangle(sample),color:palette[group],rule:.nonZero))
                    commands.append(.stroke(path:.rectangle(sample),color:foreground,width:1,dash:[]))
                }
            }
            commands.append(.restore)
        }
        let right=max(11,(legend?.minX ?? (width-10))-10)
        if graph.points.isEmpty {
            text("No graph data available.",right/2,top+bodyHeight/2,labelSize,alignment:.center)
            return Self(scene:.init(size:CGSize(width:width,height:height),commands:commands),accessibilityLabels:accessibilityLabels,hits:hits,titleBounds:titleBounds,averageBounds:averageBounds,plotBounds:.zero,legendBounds:legend,pieBounds:[])
        }
        if style == .pie {
            // Source skips zero-total series; retain the visible, unscrolled row.
            let categories=graph.pieCategories
            let slot=max(0,min((right-10)/CGFloat(max(1,categories.count)),bodyHeight-50))
            let startX=10+max(0,(right-10-slot*CGFloat(categories.count))/2)
            let centerY=top+max(0,(bodyHeight-40)/2)
            for (index,category) in categories.enumerated() {
                let center=CGPoint(x:CGFloat(Int(startX+(CGFloat(index)+0.5)*slot)),y:CGFloat(Int(centerY))),radius=CGFloat(Int(slot*0.425))
                pies.append(CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
                guard radius>0 else{continue}
                let points=graph.points.filter{(graph.metric.byAuthor || $0.category==category) && $0.value>0}
                let total=points.reduce(0.0){$0+Double($1.value)}
                var paintedPortion=0.0,portion=0.0
                var previousEndpoint=CGPoint(x:center.x-radius,y:center.y)
                for point in points where total>0 {
                    let end=portion+Double(point.value)/total*2 * .pi
                    let endpoint=CGPoint(x:center.x-CGFloat(Int(radius*cos(end))),y:center.y+CGFloat(Int(radius*sin(end))))
                    // GDI would turn coincident/subpixel endpoints into a full
                    // pie. Source skips those wedges and leaves ptStart at the
                    // preceding PAINTED endpoint for the next accepted wedge.
                    let distance=abs(previousEndpoint.x-endpoint.x)+abs(previousEndpoint.y-endpoint.y)
                    if points.count==1 || distance>1 {
                        var paintedEnd=Double.pi-atan2(endpoint.y-center.y,endpoint.x-center.x)
                        if paintedEnd<=0 {paintedEnd+=2 * .pi}
                        if points.count==1 {paintedEnd=2 * .pi}
                        let path=CGMutablePath();path.move(to:center)
                        path.addArc(center:center,radius:radius,startAngle:CGFloat(Double.pi-paintedPortion),endAngle:CGFloat(Double.pi-paintedEnd),clockwise:true);path.closeSubpath()
                        let group=graph.metric.byAuthor ? point.category:point.series
                        if palette.indices.contains(group) {commands.append(.fill(path:MacGraphVectorRenderer.path(path),color:palette[group],rule:.nonZero))}
                        hits.append(.init(shape:.wedge(center,radius,paintedPortion,paintedEnd),label:tooltip(point),series:graph.metric.byAuthor ? 0:point.category,group:graph.metric.byAuthor ? point.category:point.series))
                        paintedPortion=paintedEnd;previousEndpoint=endpoint
                    }
                    portion=end
                }
                if !graph.metric.byAuthor {text(graph.categoryLabels[category],center.x,center.y+radius+10+font(labelSize).ascender,labelSize,alignment:.center)}
            }
            let guideY=(height-10)-(height-titleBounds.maxY)*CGFloat(graph.averageGuide)/CGFloat(graph.yAxisMaximum(style:style))
            let guide=CGRect(x:10,y:guideY-2,width:max(0,right-10),height:4)
            averageBounds=guide
            hits.append(.init(shape:.guide(guide),label:graph.averageTooltip(style:style),role:.average))
            text(graph.xAxisLabel,(right+10)/2,height-10,labelSize,alignment:.center)
            return Self(scene:.init(size:CGSize(width:width,height:height),commands:commands),accessibilityLabels:accessibilityLabels,hits:hits,titleBounds:titleBounds,averageBounds:averageBounds,plotBounds:CGRect(x:10,y:top,width:max(1,right-10),height:bodyHeight),legendBounds:legend,pieBounds:pies)
        }
        let ticks=graph.yAxisTicks(style:style),maximum=Double(graph.yAxisMaximum(style:style))
        let tickWidth=ticks.map{measure(String($0),labelSize).width}.max() ?? 0
        let left=min(max(35,tickWidth+labelHeight+22),max(35,right*0.4))
        let plot=CGRect(x:left,y:top+8,width:max(1,right-left),height:max(1,height-top-2*labelHeight-32))
        let bars=style == .bar || style == .stackedBar
        let labels=bars ? graph.barLabels:(graph.metric.byAuthor ? [""]:graph.categoryLabels)
        let slots=max(1,labels.count)
        func x(_ value:Double)->CGFloat {plot.minX+CGFloat(value/Double(slots))*plot.width}
        func y(_ value:Double)->CGFloat {plot.maxY-CGFloat(value/maximum)*plot.height}
        stroke([CGPoint(x:plot.minX,y:plot.minY),CGPoint(x:plot.minX,y:plot.maxY),CGPoint(x:plot.maxX,y:plot.maxY)],color:foreground)
        for tick in ticks {
            let location=y(Double(tick))
            stroke([CGPoint(x:plot.minX-4,y:location),CGPoint(x:plot.minX,y:location)],color:foreground)
            text(String(tick),plot.minX-7,location+(font(labelSize).ascender+font(labelSize).descender)/2,labelSize,alignment:.trailing)
        }
        text(graph.yAxisLabel,10,plot.midY,labelSize,alignment:.center,rotation:-.pi/2)
        text(graph.xAxisLabel,plot.midX,height-8,labelSize,alignment:.center)
        // Label clipping is part of the shared scene, not native-only truncation.
        let slotWidth=plot.width/CGFloat(slots)
        for (index,label) in labels.enumerated() {
            let center=x(Double(index)+0.5)
            stroke([CGPoint(x:center,y:plot.maxY),CGPoint(x:center,y:plot.maxY+4)],color:foreground)
            commands.append(.save);commands.append(.clip(path:.rectangle(CGRect(x:center-slotWidth/2,y:plot.maxY+5,width:slotWidth,height:labelHeight+4)),rule:.nonZero))
            text(label,center,plot.maxY+6+font(labelSize).ascender,labelSize,alignment:.center)
            commands.append(.restore)
        }
        commands.append(.save);commands.append(.clip(path:.rectangle(plot.insetBy(dx:-1,dy:-1)),rule:.nonZero))
        if bars {
            for bar in graph.barLayout(stacked:style == .stackedBar) {
                // Source rcBar has integer corners and includes the shared
                // right/bottom border pixel in both painting and hit regions.
                let minX=CGFloat(Int(x(bar.left))),minY=CGFloat(Int(y(bar.top)))
                let rect=CGRect(x:minX,y:minY,width:max(0,CGFloat(Int(x(bar.right)))+1-minX),height:max(0,CGFloat(Int(y(bar.bottom)))+1-minY))
                let group=graph.metric.byAuthor ? bar.point.category:bar.point.series
                guard palette.indices.contains(group) else{continue}
                commands.append(.fill(path:.rectangle(rect),color:palette[group],rule:.nonZero))
                commands.append(.stroke(path:.rectangle(rect),color:foreground,width:1,dash:[]))
                hits.append(.init(shape:.rectangle(rect),label:tooltip(bar.point),series:graph.metric.byAuthor ? 0:bar.point.category,group:graph.metric.byAuthor ? bar.point.category:bar.point.series))
            }
        } else {
            let groupCount=palette.count,categoryCount=graph.metric.byAuthor ? 1:graph.categoryLabels.count
            var values=Array(repeating:Array(repeating:0.0,count:categoryCount),count:groupCount)
            var pointRows=Array(repeating:Array<LogStatisticsGraph.Point?>(repeating:nil,count:categoryCount),count:groupCount)
            for point in graph.points {
                let group=graph.metric.byAuthor ? point.category:point.series,category=graph.metric.byAuthor ? 0:point.category
                if values.indices.contains(group),values[group].indices.contains(category) {values[group][category]=Double(point.value);pointRows[group][category]=point}
            }
            var accumulated=Array(repeating:0.0,count:categoryCount)
            for group in 0..<groupCount {
                let centers=(0..<categoryCount).map{x(Double($0)+0.5)}
                if style == .stackedLine {
                    let bottom=(0..<categoryCount).map{CGPoint(x:centers[$0],y:y(accumulated[$0]))}
                    let top=(0..<categoryCount).map{CGPoint(x:centers[$0],y:y(accumulated[$0]+values[group][$0]))}
                    let previous=palette[max(0,group-1)],color=palette[group]
                    let outline=GraphVectorColor(red:(previous.red+color.red)/3,green:(previous.green+color.green)/3,blue:(previous.blue+color.blue)/3)
                    if categoryCount==1 {
                        polygon([CGPoint(x:centers[0]-5,y:bottom[0].y),CGPoint(x:centers[0]+5,y:bottom[0].y),CGPoint(x:centers[0]+5,y:top[0].y),CGPoint(x:centers[0]-5,y:top[0].y)],color:color,outline:outline)
                    } else {polygon(Array(bottom.reversed())+top,color:color,outline:outline)}
                    for category in 0..<categoryCount {accumulated[category]+=values[group][category]}
                } else {
                    for category in 0..<categoryCount {
                        let center=CGPoint(x:centers[category],y:y(values[group][category]))
                        if category>0 && (values[group][category]>0 || values[group][category-1]>0) {
                            stroke([CGPoint(x:centers[category-1],y:y(values[group][category-1])),center],color:palette[group])
                        }
                        if values[group][category]>0 {circle(center,3,color:palette[group])}
                        if categoryCount<40,let point=pointRows[group][category] {
                            hits.append(.init(shape:.rectangle(CGRect(x:center.x-3,y:center.y-3,width:6,height:6)),label:tooltip(point),series:graph.metric.byAuthor ? 0:point.category,group:graph.metric.byAuthor ? point.category:point.series))
                        }
                    }
                }
            }
        }
        let average=y(Double(graph.averageGuide))
        let guide=CGRect(x:plot.minX,y:average-2,width:plot.width,height:4)
        averageBounds=guide
        hits.append(.init(shape:.guide(guide),label:graph.averageTooltip(style:style),role:.average))
        if style == .bar || style == .line {
            stroke([CGPoint(x:plot.minX,y:average),CGPoint(x:plot.maxX,y:average)],color:foreground)
        }
        commands.append(.restore)
        return Self(scene:.init(size:CGSize(width:width,height:height),commands:commands),accessibilityLabels:accessibilityLabels,hits:hits,titleBounds:titleBounds,averageBounds:averageBounds,plotBounds:plot,legendBounds:legend,pieBounds:pies)
    }
}
