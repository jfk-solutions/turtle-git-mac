// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import TurtleGitCore

/// One top-left display list serves native graphs and all graphic exports.
@MainActor enum MacGraphVectorRenderer {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {switch self {case .invalid(let reason):return reason}}
    }
    static func font(name:String,size:CGFloat)->NSFont {
        if let font=NSFont(name:name,size:size) {return font}
        let lower=name.lowercased()
        let weight:NSFont.Weight=lower.contains("semibold") ? .semibold:lower.contains("bold") ? .bold:.regular
        return lower.contains("mono") ? .monospacedSystemFont(ofSize:size,weight:weight):.systemFont(ofSize:size,weight:weight)
    }
    static func measure(_ text:String,font:NSFont)->CGSize {(text as NSString).size(withAttributes:[.font:font])}
    static func path(_ path:CGPath)->GraphVectorPath {
        var segments:[GraphVectorPath.Segment]=[]
        path.applyWithBlock {element in
            let p=element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:segments.append(.move(p[0]))
            case .addLineToPoint:segments.append(.line(p[0]))
            case .addQuadCurveToPoint:segments.append(.quad(control:p[0],end:p[1]))
            case .addCurveToPoint:segments.append(.cubic(control1:p[0],control2:p[1],end:p[2]))
            case .closeSubpath:segments.append(.close)
            @unknown default:break
            }
        }
        return GraphVectorPath(segments:segments)
    }
    private static func cgPath(_ path:GraphVectorPath)throws->CGPath {
        guard path.segments.count<=500_000 else {throw Failure.invalid("The graph contains too many path segments.")}
        let result=CGMutablePath()
        func valid(_ p:CGPoint)throws {guard p.x.isFinite,p.y.isFinite,abs(p.x)<=1e9,abs(p.y)<=1e9 else {throw Failure.invalid("The graph contains an invalid coordinate.")}}
        for segment in path.segments {switch segment {
        case .move(let p):try valid(p);result.move(to:p)
        case .line(let p):try valid(p);result.addLine(to:p)
        case .quad(let c,let p):try valid(c);try valid(p);result.addQuadCurve(to:p,control:c)
        case .cubic(let a,let b,let p):try valid(a);try valid(b);try valid(p);result.addCurve(to:p,control1:a,control2:b)
        case .close:result.closeSubpath()
        }}
        return result
    }
    private static func color(_ color:GraphVectorColor)throws->CGColor {
        guard [color.red,color.green,color.blue,color.alpha].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw Failure.invalid("The graph contains an invalid color.")}
        return CGColor(srgbRed:color.red,green:color.green,blue:color.blue,alpha:color.alpha)
    }
    private static func validate(_ scene:GraphVectorScene)throws {
        guard scene.size.width.isFinite,scene.size.height.isFinite,scene.size.width>=1,scene.size.height>=1,
              scene.size.width<=1e9,scene.size.height<=1e9,scene.commands.count<=100_000 else {throw Failure.invalid("The graph is too large to render.")}
    }
    private static func textLine(_ text:GraphVectorText)throws->CTLine {
        guard text.fontSize.isFinite,text.fontSize>0,text.fontSize<=16384,text.origin.x.isFinite,text.origin.y.isFinite,text.rotation.isFinite,text.text.utf8.count<=4_194_304,text.text.utf16.count<=262144 else {throw Failure.invalid("The graph contains invalid text geometry.")}
        let paint=NSColor(cgColor:try color(text.color)) ?? .black
        let string=NSAttributedString(string:text.text,attributes:[.font:font(name:text.fontName,size:text.fontSize),.foregroundColor:paint])
        return CTLineCreateWithAttributedString(string)
    }
    private static func alignment(_ text:GraphVectorText,_ width:CGFloat)->CGFloat {
        switch text.alignment {case .leading:return 0;case .center:return -width/2;case .trailing:return -width}
    }
    private static func rasterImage(_ raster:GraphVectorRaster)throws->CGImage {
        guard raster.width>0,raster.height>0,raster.width<=16384,raster.height<=16384,raster.width<=16_777_216/raster.height,
              raster.rgba.count==raster.width*raster.height*4,raster.rect.minX.isFinite,raster.rect.minY.isFinite,
              raster.rect.width.isFinite,raster.rect.height.isFinite,raster.rect.width>0,raster.rect.height>0,
              let space=CGColorSpace(name:CGColorSpace.sRGB),let provider=CGDataProvider(data:raster.rgba as CFData),
              let image=CGImage(width:raster.width,height:raster.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:raster.width*4,
                space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw Failure.invalid("The graph contains an invalid bitmap.")}
        return image
    }
    static func draw(_ scene:GraphVectorScene)throws {
        guard let context=NSGraphicsContext.current?.cgContext else {throw Failure.invalid("No graphics context is available for the graph.")}
        try draw(scene:scene,in:context)
    }
    static func draw(scene:GraphVectorScene,in context:CGContext)throws {
        try validate(scene)
        context.saveGState();var depth=0
        defer {while depth>0 {context.restoreGState();depth-=1};context.restoreGState()}
        context.setLineCap(.butt);context.setLineJoin(.miter)
        for command in scene.commands {switch command {
        case .save:guard depth<128 else {throw Failure.invalid("The graph contains too many nested clips.")};context.saveGState();depth+=1
        case .restore:guard depth>0 else {throw Failure.invalid("The graph contains an unbalanced drawing state.")};context.restoreGState();depth-=1
        case .clip(let path,let rule):context.addPath(try cgPath(path));context.clip(using:rule == .evenOdd ? .evenOdd:.winding)
        case .fill(let path,let paint,let rule):context.setFillColor(try color(paint));context.addPath(try cgPath(path));context.drawPath(using:rule == .evenOdd ? .eoFill:.fill)
        case .stroke(let path,let paint,let width,let dash):
            guard width.isFinite,width>=0,width<=1e6,dash.count<=1024,dash.allSatisfy({$0.isFinite && $0>0}) else {throw Failure.invalid("The graph contains an invalid stroke.")}
            context.setStrokeColor(try color(paint));context.setLineWidth(width);context.setLineDash(phase:0,lengths:dash);context.addPath(try cgPath(path));context.strokePath()
        case .text(let text):
            let line=try textLine(text),width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
            context.saveGState();context.translateBy(x:text.origin.x,y:text.origin.y);context.rotate(by:text.rotation)
            context.translateBy(x:alignment(text,width),y:0);context.scaleBy(x:1,y:-1);context.textMatrix = .identity;context.textPosition = .zero
            CTLineDraw(line,context);context.restoreGState()
        case .raster(let raster):
            let image=try rasterImage(raster)
            context.saveGState();context.translateBy(x:raster.rect.minX,y:raster.rect.maxY);context.scaleBy(x:1,y:-1)
            context.draw(image,in:CGRect(origin:.zero,size:raster.rect.size));context.restoreGState()
        }}
        guard depth==0 else {throw Failure.invalid("The graph contains an unbalanced drawing state.")}
    }
    /// Preserve shaping/fallback using each CoreText run's actual font. Color or
    /// bitmap-only glyphs use a bounded label-local image, never a graph snapshot.
    static func resolvedText(_ scene:GraphVectorScene,cancellation:OperationCancellation?=nil)throws->GraphVectorScene {
        try validate(scene);var commands:[GraphVectorCommand]=[],segments=0,rasterPixels=0
        for command in scene.commands {
            try cancellation?.check()
            guard case .text(let text)=command else {commands.append(command);continue}
            let line=try textLine(text),width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
            let shift=alignment(text,width),cosine=cos(text.rotation),sine=sin(text.rotation)
            var outlines:[GraphVectorCommand]=[],bitmapNeeded=false
            let runs=CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let count=CTRunGetGlyphCount(run)
                guard count<=262144 else {throw Failure.invalid("The graph label contains too many glyphs.")}
                let attributes=CTRunGetAttributes(run) as NSDictionary
                guard let runFont=attributes[kCTFontAttributeName] else {throw Failure.invalid("The graph label has no resolved font.")}
                let actualFont=runFont as! CTFont
                if CTFontGetSymbolicTraits(actualFont).contains(.traitColorGlyphs) {bitmapNeeded=true}
                var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs);CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
                for index in 0..<count {
                    if index%128==0 {try cancellation?.check()}
                    let glyph=glyphs[index],position=positions[index]
                    guard let outline=CTFontCreatePathForGlyph(actualFont,glyph,nil) else {
                        // Spaces have advance but no ink. Color-font runs have
                        // bitmap ink and must retain their native painted label.
                        var value=glyph
                        let ink=CTFontGetBoundingRectsForGlyphs(actualFont,.default,&value,nil,1)
                        if !ink.isEmpty {bitmapNeeded=true}
                        continue
                    }
                    let x=shift+position.x,y = -position.y
                    var transform=CGAffineTransform(a:cosine,b:sine,c:sine,d:-cosine,
                        tx:text.origin.x+cosine*x-sine*y,ty:text.origin.y+sine*x+cosine*y)
                    guard let moved=outline.copy(using:&transform) else {throw Failure.invalid("The graph label outline could not be transformed.")}
                    let vector=path(moved);segments+=vector.segments.count
                    guard segments<=500_000 else {throw Failure.invalid("The graph contains too many glyph outlines.")}
                    if !vector.segments.isEmpty {outlines.append(.fill(path:vector,color:text.color,rule:.nonZero))}
                }
            }
            if bitmapNeeded {
                let raster=try textRaster(text,line:line,width:width)
                rasterPixels+=raster.width*raster.height
                guard rasterPixels<=16_777_216 else {throw Failure.invalid("The graph contains too many bitmap glyphs.")}
                commands.append(.raster(raster))
            }else {commands.append(contentsOf:outlines)}
            guard commands.count<=100_000 else {throw Failure.invalid("The graph contains too many drawing commands.")}
        }
        return GraphVectorScene(size:scene.size,commands:commands)
    }
    private static func textRaster(_ text:GraphVectorText,line:CTLine,width:CGFloat)throws->GraphVectorRaster {
        var ascent:CGFloat=0,descent:CGFloat=0,leading:CGFloat=0
        _=CTLineGetTypographicBounds(line,&ascent,&descent,&leading)
        let ink=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
        let local=CGRect(x:min(0,ink.minX)+alignment(text,width)-2,y:-max(ascent,ink.maxY)-2,
            width:max(width,ink.maxX)-min(0,ink.minX)+4,height:max(ascent,ink.maxY)+max(descent,-ink.minY)+4)
        let rotation=CGAffineTransform(rotationAngle:text.rotation)
        let translated=local.applying(rotation).offsetBy(dx:text.origin.x,dy:text.origin.y).integral
        guard translated.width>=1,translated.height>=1,translated.width<=16384,translated.height<=16384,
              translated.width*translated.height<=16_777_216 else {throw Failure.invalid("The bitmap graph label is too large.")}
        let w=Int(translated.width),h=Int(translated.height)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure.invalid("The bitmap graph label could not be allocated.")}
        context.translateBy(x:0,y:CGFloat(h));context.scaleBy(x:1,y:-1);context.translateBy(x:-translated.minX,y:-translated.minY)
        context.translateBy(x:text.origin.x,y:text.origin.y);context.rotate(by:text.rotation);context.translateBy(x:alignment(text,width),y:0)
        context.scaleBy(x:1,y:-1);context.textMatrix = .identity;CTLineDraw(line,context)
        guard let storage=context.data else {throw Failure.invalid("The bitmap graph label could not be read.")}
        let source=storage.bindMemory(to:UInt8.self,capacity:w*h*4);var rgba=Data(count:w*h*4)
        for offset in stride(from:0,to:rgba.count,by:4) {
            let alpha=Int(source[offset+3]);rgba[offset+3]=UInt8(alpha)
            for channel in 0..<3 {rgba[offset+channel]=alpha>0 ? UInt8(min(255,(Int(source[offset+channel])*255+alpha/2)/alpha)):0}
        }
        return GraphVectorRaster(rect:translated,width:w,height:h,rgba:rgba)
    }
    static func emf(_ scene:GraphVectorScene,cancellation:OperationCancellation?=nil)throws->Data {
        try EnhancedMetafileWriter.encode(resolvedText(scene,cancellation:cancellation),cancellation:cancellation)
    }
    static func pdf(_ scene:GraphVectorScene,title:String="Graph")throws->Data {
        try validate(scene);let output=NSMutableData();var box=CGRect(origin:.zero,size:scene.size)
        guard let consumer=CGDataConsumer(data:output),let context=CGContext(consumer:consumer,mediaBox:&box,
            [kCGPDFContextTitle:title,kCGPDFContextCreator:"TurtleGit for Mac"] as CFDictionary) else {throw Failure.invalid("The graph PDF could not be created.")}
        context.beginPDFPage(nil);context.translateBy(x:0,y:scene.size.height);context.scaleBy(x:1,y:-1)
        try draw(scene:scene,in:context);context.endPDFPage();context.closePDF();return output as Data
    }
    static func raster(_ scene:GraphVectorScene,type:UTType,jpegQuality:Double=0.9)throws->Data {
        try validate(scene)
        let w=Int(ceil(scene.size.width)),h=Int(ceil(scene.size.height))
        guard w<=16384,h<=16384,w<=32_000_000/h,let space=CGColorSpace(name:CGColorSpace.sRGB),
            let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            else {throw Failure.invalid("The graph is too large for raster export.")}
        context.translateBy(x:0,y:CGFloat(h));context.scaleBy(x:1,y:-1);try draw(scene:scene,in:context)
        guard let image=context.makeImage() else {throw Failure.invalid("The graph bitmap could not be rendered.")}
        return try encoded(image,type:type,quality:jpegQuality)
    }
    private static func encoded(_ image:CGImage,type:UTType,quality:Double=0.9)throws->Data {
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,type.identifier as CFString,1,nil) else {throw Failure.invalid("The graph image encoder is unavailable.")}
        CGImageDestinationAddImage(destination,image,type == .jpeg ? [kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary:nil)
        guard CGImageDestinationFinalize(destination) else {throw Failure.invalid("The graph image could not be encoded.")}
        return output as Data
    }
    static func svg(_ scene:GraphVectorScene)throws->Data {
        let resolved=try resolvedText(scene)
        func n(_ value:CGFloat)->String {String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),Double(value))}
        func escape(_ text:String)->String {String(text.unicodeScalars.map{scalar in
            let value=scalar.value
            return value==9 || value==10 || value==13 || value>=32 && value<=0xD7FF || value>=0xE000 && value<=0xFFFD || value>=0x10000 && value<=0x10FFFF ? Character(scalar):Character("�")
        }).replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
        func paint(_ c:GraphVectorColor)throws->String {_ = try color(c);return String(format:"#%02x%02x%02x",Int((c.red*255).rounded()),Int((c.green*255).rounded()),Int((c.blue*255).rounded()))}
        func geometry(_ path:GraphVectorPath)throws->String {
            _ = try cgPath(path)
            return path.segments.map{segment in switch segment {
            case .move(let p):return "M\(n(p.x)) \(n(p.y))"
            case .line(let p):return "L\(n(p.x)) \(n(p.y))"
            case .quad(let c,let p):return "Q\(n(c.x)) \(n(c.y)) \(n(p.x)) \(n(p.y))"
            case .cubic(let a,let b,let p):return "C\(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(p.x)) \(n(p.y))"
            case .close:return "Z"
            }}.joined(separator:" ")
        }
        var output=["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(scene.size.width))\" height=\"\(n(scene.size.height))\" viewBox=\"0 0 \(n(scene.size.width)) \(n(scene.size.height))\">"]
        for command in scene.commands {if case .text(let text)=command {output.append("<desc>\(escape(text.text))</desc>")}}
        var depth=0,clips=0,scopeClips:[Int]=[]
        for command in resolved.commands {switch command {
        case .save:output.append("<g>");scopeClips.append(clips);depth+=1
        case .restore:guard let old=scopeClips.popLast(),depth>0 else {throw Failure.invalid("The graph contains an unbalanced drawing state.")};while clips>old {output.append("</g>");clips-=1};output.append("</g>");depth-=1
        case .clip(let path,let rule):
            let id="clip-\(output.count)";output.append("<defs><clipPath id=\"\(id)\"><path d=\"\(try geometry(path))\" clip-rule=\"\(rule == .evenOdd ? "evenodd":"nonzero")\"/></clipPath></defs><g clip-path=\"url(#\(id))\">");clips+=1
        case .fill(let path,let c,let rule):output.append("<path d=\"\(try geometry(path))\" fill=\"\(try paint(c))\" fill-opacity=\"\(c.alpha)\" fill-rule=\"\(rule == .evenOdd ? "evenodd":"nonzero")\"/>")
        case .stroke(let path,let c,let width,let dash):
            guard width.isFinite,width>=0,width<=1e6,dash.count<=1024,dash.allSatisfy({$0.isFinite && $0>0}) else {throw Failure.invalid("The graph contains an invalid stroke.")}
            let pattern=dash.isEmpty ? "":" stroke-dasharray=\""+dash.map(n).joined(separator:" ")+"\""
            output.append("<path d=\"\(try geometry(path))\" fill=\"none\" stroke=\"\(try paint(c))\" stroke-opacity=\"\(c.alpha)\" stroke-width=\"\(n(width))\"\(pattern)/>")
        case .text:throw Failure.invalid("The graph label was not resolved.")
        case .raster(let raster):
            let png=try encoded(rasterImage(raster),type:.png).base64EncodedString()
            output.append("<image x=\"\(n(raster.rect.minX))\" y=\"\(n(raster.rect.minY))\" width=\"\(n(raster.rect.width))\" height=\"\(n(raster.rect.height))\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,\(png)\"/>")
        }}
        guard depth==0 else {throw Failure.invalid("The graph contains an unbalanced drawing state.")};while clips>0 {output.append("</g>");clips-=1};output.append("</svg>")
        let data=Data(output.joined(separator:"\n").utf8)
        guard data.count<=64*1024*1024 else {throw Failure.invalid("The graph SVG is too large.")};return data
    }
}
