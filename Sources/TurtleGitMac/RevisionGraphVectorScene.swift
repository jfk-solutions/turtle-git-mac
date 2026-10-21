// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Captures the displayed graph once. No renderer consults the live model.
@MainActor enum RevisionGraphVectorScene {
    static func color(_ value: NSColor) -> GraphVectorColor {
        let rgb = value.usingColorSpace(.sRGB)!
        return GraphVectorColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }
    static func opaque(_ value: NSColor, over background: GraphVectorColor) -> GraphVectorColor {
        let foreground = color(value), alpha = foreground.alpha
        return GraphVectorColor(red: foreground.red * alpha + background.red * (1 - alpha),
            green: foreground.green * alpha + background.green * (1 - alpha),
            blue: foreground.blue * alpha + background.blue * (1 - alpha))
    }
    static func rounded(_ rect: CGRect, radius: CGFloat) -> GraphVectorPath {
        let r = min(radius, rect.width / 2, rect.height / 2), k: CGFloat = 0.5522847498307936
        return GraphVectorPath(segments: [
            .move(CGPoint(x: rect.minX+r,y: rect.minY)), .line(CGPoint(x: rect.maxX-r,y: rect.minY)),
            .cubic(control1: CGPoint(x: rect.maxX-r+k*r,y: rect.minY), control2: CGPoint(x: rect.maxX,y: rect.minY+r-k*r), end: CGPoint(x: rect.maxX,y: rect.minY+r)),
            .line(CGPoint(x: rect.maxX,y: rect.maxY-r)),
            .cubic(control1: CGPoint(x: rect.maxX,y: rect.maxY-r+k*r), control2: CGPoint(x: rect.maxX-r+k*r,y: rect.maxY), end: CGPoint(x: rect.maxX-r,y: rect.maxY)),
            .line(CGPoint(x: rect.minX+r,y: rect.maxY)),
            .cubic(control1: CGPoint(x: rect.minX+r-k*r,y: rect.maxY), control2: CGPoint(x: rect.minX,y: rect.maxY-r+k*r), end: CGPoint(x: rect.minX,y: rect.maxY-r)),
            .line(CGPoint(x: rect.minX,y: rect.minY+r)),
            .cubic(control1: CGPoint(x: rect.minX,y: rect.minY+r-k*r), control2: CGPoint(x: rect.minX+r-k*r,y: rect.minY), end: CGPoint(x: rect.minX+r,y: rect.minY)), .close])
    }
    static func make(model: RevisionGraphWindowModel, size: CGSize, zoom: CGFloat, margin: CGFloat = 10, text: Bool = true, background: Bool = true) -> GraphVectorScene {
        var commands: [GraphVectorCommand] = []
        let canvasColor = color(.textBackgroundColor)
        // System label colors may carry alpha (notably in Dark Aqua). Edges
        // are painted before opaque nodes, entirely onto this canvas color.
        // Resolve that source-over appearance once for native and every export;
        // enhanced-metafile vector pens have no alpha channel.
        let edgeColor = opaque(.labelColor, over: canvasColor)
        if background { commands.append(.fill(path: .rectangle(CGRect(origin: .zero,size:size)), color: canvasColor, rule: .nonZero)) }
        guard let graph = model.geometry, zoom.isFinite, zoom > 0 else { return GraphVectorScene(size:size,commands:commands) }
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*zoom+margin,y:p.y*zoom+margin) }
        func rect(_ r: CGRect) -> CGRect { CGRect(x:r.minX*zoom+margin,y:r.minY*zoom+margin,width:r.width*zoom,height:r.height*zoom) }
        func stroke(_ points: [CGPoint], _ ink: GraphVectorColor, _ width: CGFloat) {
            guard let first=points.first else{return}
            commands.append(.stroke(path:GraphVectorPath(segments:[.move(point(first))]+points.dropFirst().map{.line(point($0))}),color:ink,width:width*zoom,dash:[]))
        }
        let drawingFont=model.drawingFont(zoom:zoom)
        func label(_ value:String, at origin:CGPoint, ink:NSColor) {
            guard text,let font=drawingFont else{return}
            commands.append(.text(GraphVectorText(text:value,origin:point(CGPoint(x:origin.x,y:origin.y+font.ascender)),fontName:font.fontName,fontSize:font.pointSize*zoom,color:color(ink))))
        }
        for edge in graph.edges {
            let points=model.arrowsTowardMerges ? Array(edge.points.reversed()) : edge.points
            guard points.count>=2,let end=points.last else{continue}
            stroke(points,edgeColor,2)
            let previous=points[points.count-2],angle=atan2(end.y-previous.y,end.x-previous.x)
            stroke([CGPoint(x:end.x-8*cos(angle - .pi/8),y:end.y-8*sin(angle - .pi/8)),end,CGPoint(x:end.x-8*cos(angle + .pi/8),y:end.y-8*sin(angle + .pi/8))],edgeColor,2)
        }
        let nodes=Dictionary(uniqueKeysWithValues:model.nodes.map{($0.hash,$0)})
        for geometry in graph.nodes {
            guard let node=nodes[geometry.hash] else{continue}
            let bounds=geometry.rect,shape=rounded(rect(bounds),radius:6*zoom),labels=model.lines(node)
            guard !labels.isEmpty else{continue}
            let height=bounds.height/CGFloat(labels.count)
            commands.append(.save);commands.append(.clip(path:shape,rule:.nonZero))
            for (index,line) in labels.enumerated() {
                let row=CGRect(x:bounds.minX,y:bounds.minY+CGFloat(index)*height,width:bounds.width,height:height)
                let ink=RevisionGraphPalette.background(line.1,pointer:line.2,preferences:model.preferences)
                commands.append(.fill(path:.rectangle(rect(row)),color:color(ink),rule:.nonZero))
                if let font=drawingFont {
                    let height=(line.0 as NSString).size(withAttributes:[.font:font]).height
                    label(line.0,at:CGPoint(x:bounds.minX+20,y:row.midY-height/2),ink:RevisionGraphPalette.foreground(ink))
                }
            }
            commands.append(.restore)
            if let index=model.selection.firstIndex(of:node.hash) {
                let ink=index==0 ? NSColor.selectedControlColor : NSColor(srgbRed:136.0/255,green:0,blue:21.0/255,alpha:1),width=max(4,1/zoom)
                commands.append(.stroke(path:shape,color:color(ink),width:width*zoom,dash:[]))
                if text {
                    for x in (index==0 ? [CGFloat(10)] : [CGFloat(5),CGFloat(15)]) { stroke([CGPoint(x:bounds.minX+x,y:bounds.minY-25),CGPoint(x:bounds.minX+x,y:bounds.minY-5)],color(ink),width) }
                    if index==0,model.selection.count==2 {label("(Base)",at:CGPoint(x:bounds.minX+14,y:bounds.minY-25),ink:ink)}
                }
            }
        }
        return GraphVectorScene(size:size,commands:commands)
    }
}
