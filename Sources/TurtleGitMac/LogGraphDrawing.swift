import AppKit
import TurtleGitCore

/// Native Core Graphics adaptation of GitLogListBase::paintGraphLane.
/// Positive arc angles follow the flipped Log cell's downward y axis.
enum LogGraphDrawing {
    static func paint(_ context: CGContext, lane: HistoryLane, rolled: Bool, x: CGFloat, width: CGFloat, height: CGFloat, settings: LogColorPreferences, color: NSColor, activeColor: NSColor) {
        let x1 = x, x2 = x+width, h = floor(height/2), m = floor((x1+x2)/2)
        let r = floor(width*CGFloat(settings.nodeSize)/30)
        let top = CGPoint(x:m,y:-1), bottom = CGPoint(x:m,y:2*h+1), center = CGPoint(x:m,y:h)
        let north = CGPoint(x:m,y:h-r), south = CGPoint(x:m,y:h+r)
        let left = CGPoint(x:x1,y:h), right = CGPoint(x:x2,y:h)
        let west = CGPoint(x:m-r,y:h), east = CGPoint(x:m+r,y:h)
        func line(_ from: CGPoint, _ to: CGPoint, _ color: NSColor) {
            context.setStrokeColor(color.cgColor); context.setLineWidth(CGFloat(settings.lineWidth)); context.beginPath(); context.move(to:from); context.addLine(to:to); context.strokePath()
        }
        func arc(rect: CGRect, start: CGFloat, from: CGPoint, to: CGPoint, first: NSColor, last: NSColor) {
            let path = CGMutablePath()
            let transform = CGAffineTransform(translationX:rect.midX,y:rect.midY).scaledBy(x:rect.width/2,y:rect.height/2)
            path.addRelativeArc(center:.zero,radius:1,startAngle:start * .pi/180,delta:.pi/2,transform:transform)
            context.saveGState(); context.setShouldAntialias(true); context.setLineWidth(CGFloat(settings.lineWidth))
            context.addPath(path); context.replacePathWithStrokedPath(); context.clip()
            if let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[first.cgColor,last.cgColor] as CFArray,locations:[0,1]) {
                context.drawLinearGradient(gradient,start:from,end:to,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
            }
            context.restoreGState()
        }
        context.saveGState(); defer { context.restoreGState() }
        switch lane {
        case .join,.joinRight,.head,.headRight:
            arc(rect:CGRect(x:x1-floor(width/2)-1,y:h-1,width:width,height:height),start:270,from:CGPoint(x:x1-2,y:h-2),to:bottom,first:activeColor,last:color)
        case .joinLeft:
            arc(rect:CGRect(x:x1+floor(width/2),y:h-1,width:width,height:height),start:180,from:bottom,to:CGPoint(x:x2+1,y:h-1),first:color,last:activeColor)
        case .tail,.tailRight:
            arc(rect:CGRect(x:x1-floor(width/2)-1,y:-h-1,width:width,height:height),start:0,from:CGPoint(x:x1-2,y:h-2),to:top,first:activeColor,last:color)
        default: break
        }
        context.setShouldAntialias(false)
        switch lane {
        case .active,.mergeFork,.mergeForkRight,.mergeForkLeft:
            if rolled { line(top,north,color); line(south,bottom,color) } else { line(top,bottom,color) }
        case .notActive,.join,.joinRight,.joinLeft,.cross: line(top,bottom,color)
        case .branch: line(rolled ? south : center,bottom,color)
        case .headLeft: line(center,bottom,color)
        case .initial,.mergeForkLeftInitial,.boundary,.boundaryCenter,.boundaryRight,.boundaryLeft: line(top,rolled ? north : center,color)
        case .tailLeft: line(top,center,color)
        default: break
        }
        switch lane {
        case .mergeFork,.boundaryCenter:
            if rolled { line(left,west,activeColor); line(east,right,activeColor) } else { line(left,right,activeColor) }
        case .join,.head,.tail,.cross,.crossEmpty: line(left,right,activeColor)
        case .mergeForkRight,.boundaryRight: line(left,rolled ? west : center,activeColor)
        case .mergeForkLeft,.mergeForkLeftInitial,.boundaryLeft: line(rolled ? east : center,right,activeColor)
        case .headLeft,.tailLeft: line(center,right,activeColor)
        default: break
        }
        let rect = CGRect(x:m-r,y:h-r,width:2*r,height:2*r)
        context.setFillColor(color.cgColor); context.setStrokeColor(color.cgColor)
        switch lane {
        case .active,.initial,.branch:
            context.setShouldAntialias(true)
            if rolled { context.setLineWidth(1); context.strokeEllipse(in:rect) } else { context.fillEllipse(in:rect) }
        case .mergeFork,.mergeForkRight,.mergeForkLeft,.mergeForkLeftInitial,.boundaryCenter,.boundaryRight,.boundaryLeft:
            if rolled { context.setLineWidth(1); context.stroke(rect) } else { context.fill(rect) }
        case .boundary:
            context.setShouldAntialias(true); context.setLineWidth(CGFloat(settings.lineWidth)); context.strokeEllipse(in:rect)
        case .unapplied: context.fill(CGRect(x:m-r,y:h-1,width:2*r,height:2))
        case .applied:
            context.fill(CGRect(x:m-r,y:h-1,width:2*r,height:2)); context.fill(CGRect(x:m-1,y:h-r,width:2,height:2*r))
        default: break
        }
    }
}
