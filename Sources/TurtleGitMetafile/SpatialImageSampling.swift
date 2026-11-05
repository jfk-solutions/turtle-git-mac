// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation

/// Original sampling arithmetic for the two actual image consumers: the effect
/// draw's affine placement and the final file-backed Picture rectangle copy.
/// Inputs remain immutable. Color and geometric coverage are separate planes.
enum SpatialImageSampling {
    /// Recorded ordinary-image kernels. Texture brushes and the final Picture
    /// copy keep their separate sampling contracts rather than inheriting a
    /// mutable graphics-state setting.
    enum Interpolation:Equatable { case bilinear, nearest }
    struct Rect { let x:Double,y:Double,width:Double,height:Double }
    struct Output {let pixels:Data,coverage:Data,width:Int,height:Int,x:Int,y:Int}
    static func down(_ value:Double)->Double {
        let rounded=Float(value)
        return Double(rounded)>value ? Double(rounded.nextDown):Double(rounded)
    }
    private static func coordinate(_ value:Double)->(Int,Int) {
        let whole=floor(value),fraction=Int(floor((value-whole)*2048+0.5))
        return (Int(whole),fraction)
    }
    private static func straight(_ associated:Int,_ alpha:Int)->UInt8 {
        UInt8(alpha==0 ? 0:max(0,min(255,(associated*((255<<16)/alpha))>>16)))
    }
    private static func reflected(_ position:Int,_ length:Int,_ mirror:Bool)->Int {
        let period=mirror ? length*2:length
        var q=position%period;if q<0 {q+=period}
        return mirror && q>=length ? period-1-q:q
    }
    private static func pixel(_ source:UnsafeRawBufferPointer,width:Int,height:Int,
                              x:Int,y:Int,channel:Int,premultiplied:Bool,
                              originX:Int=0,originY:Int=0,logicalWidth:Int=0,logicalHeight:Int=0,
                              wrap:Int=4,clamp:UInt32=0)->Int {
        var x=x,y=y
        if !(0..<width).contains(x) || !(0..<height).contains(y) {
            if wrap<4,logicalWidth>0,logicalHeight>0 {
                x=reflected(x+originX,logicalWidth,wrap==1 || wrap==3)-originX
                y=reflected(y+originY,logicalHeight,wrap==2 || wrap==3)-originY
            }
            if !(0..<width).contains(x) || !(0..<height).contains(y) {
                let a=Int(clamp>>24)
                if channel==3 {return a}
                return (Int((clamp>>UInt32((2-channel)*8))&255)*a+127)/255
            }
        }
        let offset=(y*width+x)*4
        if premultiplied || channel==3 {return Int(source[offset+channel])}
        return (Int(source[offset+channel])*Int(source[offset+3])+127)/255
    }
    private static func filtered(_ source:UnsafeRawBufferPointer,width:Int,height:Int,
                                 u:Double,v:Double,premultiplied:Bool,
                                 originX:Int=0,originY:Int=0,logicalWidth:Int=0,logicalHeight:Int=0,
                                 wrap:Int=4,clamp:UInt32=0)->(UInt8,UInt8,UInt8,UInt8) {
        let (x,fx)=coordinate(u), (y,fy)=coordinate(v)
        var channels=(0,0,0,0)
        for c in 0..<4 {
            var sum=0
            for dy in 0...1 {for dx in 0...1 {
                let wx=dx==0 ? 2048-fx:fx,wy=dy==0 ? 2048-fy:fy
                if wx==0 || wy==0 {continue}
                sum+=pixel(source,width:width,height:height,x:x+dx,y:y+dy,channel:c,premultiplied:premultiplied,
                           originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,
                           wrap:wrap,clamp:clamp)*wx*wy
            }}
            let value=max(0,min(255,(sum+(1<<21))>>22))
            switch c {case 0:channels.0=value;case 1:channels.1=value;case 2:channels.2=value;default:channels.3=value}
        }
        // Native fixed-point unassociation belongs after filtering. The next
        // image/composition boundary supplies association, not a pre-filter LUT.
        return (straight(channels.0,channels.3),straight(channels.1,channels.3),straight(channels.2,channels.3),UInt8(channels.3))
    }
    private static func nearest(_ source:UnsafeRawBufferPointer,width:Int,height:Int,
                                u:Double,v:Double,originX:Int,originY:Int,
                                logicalWidth:Int,logicalHeight:Int,wrap:Int,clamp:UInt32,phase:Double)->(UInt8,UInt8,UInt8,UInt8) {
        // These are two recorded Float32 boundaries, not a Double tie fix.
        let x=Int(floor(Double(Float(Float(u)-Float(phase))+0.5)))
        let y=Int(floor(Double(Float(Float(v)-Float(phase))+0.5)))
        let alpha=pixel(source,width:width,height:height,x:x,y:y,channel:3,premultiplied:false,
                        originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,wrap:wrap,clamp:clamp)
        func channel(_ index:Int)->UInt8 {
            straight(pixel(source,width:width,height:height,x:x,y:y,channel:index,premultiplied:false,
                           originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,wrap:wrap,clamp:clamp),alpha)
        }
        return (channel(0),channel(1),channel(2),UInt8(alpha))
    }
    static func affine(_ pixels:Data,width:Int,height:Int,originX:Int,originY:Int,
                       logicalWidth:Int,logicalHeight:Int,matrix:[Double],source:Rect,
                       canvasWidth:Int,canvasHeight:Int,wrap:Int,clamp:UInt32,associateOutput:Bool,
                       interpolation:Interpolation = .bilinear,
                       pixelOffsetMode:Int? = nil,
                       budget:inout SpatialImageEffectBudget)throws->Output? {
        try SpatialImageEffects.validate(pixels:pixels,width:width,height:height)
        guard matrix.count==6,matrix.allSatisfy({$0.isFinite && abs($0)<=1e12}),
              [source.x,source.y,source.width,source.height].allSatisfy({$0.isFinite && abs($0)<=1e9}),
              source.width>0,source.height>0,canvasWidth>0,canvasHeight>0,
              canvasWidth<=32768,canvasHeight<=32768,canvasWidth<=16_777_216/canvasHeight,
              logicalWidth>0,logicalHeight>0,logicalWidth<=32768,logicalHeight<=32768,(0...4).contains(wrap),
              (pixelOffsetMode.map({(0...4).contains($0)}) ?? true)
        else {throw SpatialImageEffectError.invalid("invalid spatial sampling geometry")}
        let a=matrix[0],b=matrix[1],c=matrix[2],d=matrix[3],tx=matrix[4],ty=matrix[5],det=a*d-b*c
        guard det.isFinite else {throw SpatialImageEffectError.invalid("invalid spatial sampling determinant")}
        if det==0 {return nil}
        guard [d/det,-b/det,-c/det,a/det].allSatisfy({$0.isFinite && abs($0)<=1e12}) else {throw SpatialImageEffectError.invalid("spatial sampling inverse exceeds bound")}
        func point(_ x:Double,_ y:Double)->(Double,Double) {(a*x+c*y+tx,b*x+d*y+ty)}
        let corners=[point(source.x,source.y),point(source.x+source.width,source.y),point(source.x+source.width,source.y+source.height),point(source.x,source.y+source.height)]
        guard corners.allSatisfy({$0.0.isFinite && $0.1.isFinite && abs($0.0)<=1e12 && abs($0.1)<=1e12}) else {throw SpatialImageEffectError.invalid("invalid spatial sampling extent")}
        // Recorded Half/HighQuality draws locate destination centers at +.5
        // and source centers at +.5 as well. The wire source rectangle already
        // contains any adjustment made by the Windows recorder; retain it.
        // Absent options preserve the separate measured effect/texture profile.
        let phase:Double=(pixelOffsetMode==2 || pixelOffsetMode==4) ? 0.5:0
        let left=Int(max(0,min(Double(canvasWidth),ceil(corners.map(\.0).min()!-phase))))
        let right=Int(max(0,min(Double(canvasWidth),ceil(corners.map(\.0).max()!-phase))))
        let top=Int(max(0,min(Double(canvasHeight),ceil(corners.map(\.1).min()!-phase))))
        let bottom=Int(max(0,min(Double(canvasHeight),ceil(corners.map(\.1).max()!-phase))))
        if right<=left || bottom<=top {return nil}
        let outWidth=right-left,outHeight=bottom-top,count=outWidth*outHeight
        // Both independent destination planes and all scalar visits are charged
        // atomically before allocation, even for a tiny source enlarged greatly.
        try budget.reserve(outputPixels:count*2,work:count*64+outHeight*32)
        var output=Data(count:count*4),coverage=Data(count:count*4)
        let axisAligned=b==0 && c==0
        let nearestProfile=interpolation == .nearest
        // Independent recorded nearest controls establish nearest-rounded row
        // starts/additions and increments truncated toward zero. The measured
        // bilinear/effect profile retains downward rounding at those stages.
        func roundPosition(_ value:Double)->Double {nearestProfile ? Double(Float(value)):down(value)}
        func step(_ value:Double)->Double {nearestProfile && value<0 ? -down(-value):down(value)}
        let stepU=axisAligned ? Double(Float(1/Float(a))):step(d/det)
        let stepV=axisAligned ? 0:step(-b/det)
        let verticalStep=axisAligned ? step(source.height*step(1/(d*source.height))):0
        let destinationOrigin=point(source.x,source.y)
        var invalidCoordinate=false
        pixels.withUnsafeBytes {(input:UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                coverage.withUnsafeMutableBytes {(mask:UnsafeMutableRawBufferPointer) in
                    for y in top..<bottom {
                        let deviceY=Double(y)+phase
                        var minX=Double.infinity,maxX = -Double.infinity
                        for edge in 0..<4 {
                            let p=corners[edge],q=corners[(edge+1)%4]
                            if p.1==q.1 || deviceY<min(p.1,q.1) || deviceY>=max(p.1,q.1) {continue}
                            let x=p.0+(q.0-p.0)*(deviceY-p.1)/(q.1-p.1)
                            minX=min(minX,x);maxX=max(maxX,x)
                        }
                        if !minX.isFinite || !maxX.isFinite {continue}
                        let start=max(left,min(right,Int(ceil(minX-phase)))),end=max(left,min(right,Int(ceil(maxX-phase))))
                        if end<=start {continue}
                        var u:Double,v:Double
                        if axisAligned {
                            u=roundPosition(Double(Float(source.x))+roundPosition((Double(start)+phase-destinationOrigin.0)*stepU))
                            v=roundPosition(Double(Float(source.y))+roundPosition((deviceY-destinationOrigin.1)*verticalStep))
                        } else {
                            u=roundPosition((d*(Double(start)+phase-tx)-c*(deviceY-ty))/det)
                            v=roundPosition((-b*(Double(start)+phase-tx)+a*(deviceY-ty))/det)
                        }
                        for x in start..<end {
                            guard u.isFinite,v.isFinite,abs(u)<=1e12,abs(v)<=1e12 else {invalidCoordinate=true;break}
                            let value:(UInt8,UInt8,UInt8,UInt8)
                            switch interpolation {
                            case .bilinear:
                                value=filtered(input,width:width,height:height,u:u-Double(originX)-phase,v:v-Double(originY)-phase,premultiplied:false,
                                               originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,wrap:wrap,clamp:clamp)
                            case .nearest:
                                value=nearest(input,width:width,height:height,u:u-Double(originX),v:v-Double(originY),
                                              originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,wrap:wrap,clamp:clamp,phase:phase)
                            }
                            let offset=((y-top)*outWidth+x-left)*4
                            let alpha=Int(value.3)
                            func output(_ channel:UInt8)->UInt8 {associateOutput ? straight((Int(channel)*alpha+127)/255,alpha):channel}
                            target[offset]=output(value.0);target[offset+1]=output(value.1);target[offset+2]=output(value.2);target[offset+3]=value.3
                            mask[offset]=255;mask[offset+1]=255;mask[offset+2]=255;mask[offset+3]=255
                            u=roundPosition(u+stepU);v=roundPosition(v+stepV)
                        }
                    }
                }
            }
        }
        if invalidCoordinate {throw SpatialImageEffectError.invalid("spatial sample coordinate exceeds bound")}
        return Output(pixels:output,coverage:coverage,width:outWidth,height:outHeight,x:left,y:top)
    }
    private static func rectangleStep(_ length:Int)->Double {down(Double(length)*down(1/Double(length)))}
    static func pictureNeeded(width:Int,height:Int,budget:inout SpatialImageEffectBudget)throws->Bool {
        guard width>0,height>0 else {throw SpatialImageEffectError.invalid("invalid Picture sample dimensions")}
        guard width<=32768,height<=32768,width<=16_777_216/height else {throw SpatialImageEffectError.invalid("Picture raster dimension/pixel budget exceeded")}
        try budget.reserve(outputPixels:0,work:(width+height)*4)
        for length in [width,height] {
            let step=rectangleStep(length);var position=down(0.5*step)
            for pixel in 0..<length {
                let (whole,fraction)=coordinate(position-0.5)
                if whole*2048+fraction != pixel*2048 {return true}
                position=down(position+step)
            }
        }
        return false
    }
    static func picture(_ pixels:Data,width:Int,height:Int,budget:inout SpatialImageEffectBudget)throws->Data {
        try SpatialImageEffects.validate(pixels:pixels,width:width,height:height)
        try budget.reserve(outputPixels:width*height,work:width*height*64+(width+height)*8)
        let sx=rectangleStep(width),sy=rectangleStep(height)
        var output=Data(count:pixels.count),v=down(0.5*sy)
        pixels.withUnsafeBytes {(input:UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    var u=down(0.5*sx)
                    for x in 0..<width {
                        let value=filtered(input,width:width,height:height,u:u-0.5,v:v-0.5,premultiplied:true,
                                           logicalWidth:width,logicalHeight:height,wrap:3)
                        let offset=(y*width+x)*4
                        target[offset]=value.0;target[offset+1]=value.1;target[offset+2]=value.2;target[offset+3]=value.3
                        u=down(u+sx)
                    }
                    v=down(v+sy)
                }
            }
        }
        return output
    }
}
