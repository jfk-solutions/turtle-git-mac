// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation

/// Pixel-space SDK RECT endpoints, retained as signed integers until an effect
/// validates/clips them against its own source image. No AppKit coordinate space.
struct SpatialImageEffectRect:Equatable {
    let left:Int
    let top:Int
    let right:Int
    let bottom:Int
}

/// Immutable effect output. Origins are relative to the original bitmap; a
/// measured expanding effect can therefore preserve its source/destination map.
struct SpatialImageEffectResult {
    let pixels:Data
    let width:Int
    let height:Int
    let originX:Int
    let originY:Int

    init(pixels:Data,width:Int,height:Int,originX:Int=0,originY:Int=0) {
        self.pixels=pixels;self.width=width;self.height=height
        self.originX=originX;self.originY=originY
    }
}

enum SpatialImageEffect {
    case blur(radius:Double,expandEdge:Bool)
    case sharpen(radius:Double,amount:Double)
    case redEyeCorrection(areas:[SpatialImageEffectRect])
}

enum SpatialImageEffectError:Error,LocalizedError {
    case invalid(String)
    var errorDescription:String? {
        switch self {case .invalid(let message):return message}
    }
}

/// Conversion-owned aggregate limits, shared across spatial draws and nested
/// renderers. A rejected reservation leaves the previous accounting untouched.
/// Work is scalar pixel/channel arithmetic, not an elapsed-time threshold.
struct SpatialImageEffectBudget {
    let maximumOutputPixels:Int
    let maximumWork:Int
    private(set) var outputPixels=0
    private(set) var work=0

    init(maximumOutputPixels:Int=67_108_864,maximumWork:Int=134_217_728) {
        self.maximumOutputPixels=max(0,maximumOutputPixels)
        self.maximumWork=max(0,maximumWork)
    }

    mutating func reserve(outputPixels:Int,work:Int)throws {
        guard outputPixels>=0,work>=0,
              self.outputPixels<=maximumOutputPixels,self.work<=maximumWork,
              outputPixels<=maximumOutputPixels-self.outputPixels,
              work<=maximumWork-self.work else {
            throw SpatialImageEffectError.invalid("spatial image effect aggregate work/output budget exceeded")
        }
        self.outputPixels+=outputPixels
        self.work+=work
    }
}

/// Kernel entry points receive an immutable, tightly packed, top-row-first
/// straight RGBA source after the caller's measured Windows input conversion.
/// Final Windows associations and PNG encoding remain the caller's operation.
enum SpatialImageEffects {
    static let maximumPixels=16_777_216
    static let maximumDimension=32_768

    static func apply(_ effect:SpatialImageEffect,toStraightRGBA pixels:Data,
                      width:Int,height:Int,expandOutput:Bool=true,
                      budget:inout SpatialImageEffectBudget)throws->SpatialImageEffectResult {
        switch effect {
        case .blur(let radius,let expandEdge):
            return try blur(pixels:pixels,width:width,height:height,radius:radius,expandEdge:expandEdge,expandOutput:expandOutput,budget:&budget)
        case .sharpen(let radius,let amount):
            return try sharpen(pixels:pixels,width:width,height:height,radius:radius,amount:amount,budget:&budget)
        case .redEyeCorrection(let areas):
            return try RedEyeImageEffects.apply(pixels:pixels,width:width,height:height,areas:areas,budget:&budget)
        }
    }

    @discardableResult
    static func validate(pixels:Data,width:Int,height:Int)throws->Int {
        guard width>0,height>0,width<=maximumDimension,height<=maximumDimension,
              width<=maximumPixels/height else {
            throw SpatialImageEffectError.invalid("invalid spatial image dimensions")
        }
        let count=width*height
        guard pixels.count==count*4 else {
            throw SpatialImageEffectError.invalid("invalid spatial image RGBA extent")
        }
        return count
    }

    static func validate(radius:Double)throws {
        guard radius.isFinite,radius>=0,radius<=255 else {
            throw SpatialImageEffectError.invalid("invalid spatial image effect radius")
        }
    }

    /// Work extents selected by the small-kernel row walk and the full large
    /// kernel pass. Every admitted dimension selects an explicit extent.
    enum VerticalPolicy {case none,leadingRows(Int),all}
    enum EdgePolicy {case mirror,transparent,clamp}

    private struct GaussianPlan {
        let sourceWidth:Int,sourceHeight:Int,width:Int,height:Int,pad:Int
        let weights:[Double]
        let vertical:VerticalPolicy
        let edge:EdgePolicy
        var pixels:Int {width*height}
    }

    private static func plan(width:Int,height:Int,radius:Double,expand:Bool,
                             vertical:VerticalPolicy,edge:EdgePolicy)throws->GaussianPlan {
        let support=Int(ceil(radius)),pad=expand ? support:0
        let outWidth=width+pad*2,outHeight=height+pad*2
        guard outWidth<=maximumDimension,outHeight<=maximumDimension,
              outWidth<=maximumPixels/outHeight else {throw SpatialImageEffectError.invalid("expanded spatial image exceeds pixel limit")}
        let weights=gaussianWeights(radius:radius)
        return GaussianPlan(sourceWidth:width,sourceHeight:height,width:outWidth,height:outHeight,pad:pad,weights:weights,vertical:vertical,edge:edge)
    }

    /// Behavioral research: ChristopherVR/emf-converter, commit
    /// effcf337218fefc08e4ac8f74e59cd2af1a9235c, Blur/Sharpen parity notes.
    /// This original Swift arithmetic is independently compared with our own
    /// retained Windows buffers. No external pixel tables enter the predictor.
    private static func towardZeroFloat(_ value:Double)->Double {
        let nearest=Float(value)
        if abs(Double(nearest))>abs(value) {return Double(value>=0 ? nearest.nextDown:nearest.nextUp)}
        return Double(nearest)
    }

    private static func gaussianWeights(radius:Double)->[Double] {
        if radius==0 {return [1]}
        let support=Int(ceil(radius))
        let step=towardZeroFloat(towardZeroFloat(1.4)/Double(Float(radius)))
        var positive=[Double](repeating:1,count:support+1),position=0.0,total=1.0
        for offset in 1...support {
            position=towardZeroFloat(position+step)
            let weight=towardZeroFloat(exp(-towardZeroFloat(position*position)))
            positive[offset]=weight
            total=towardZeroFloat(total+towardZeroFloat(2*weight))
        }
        let scale=towardZeroFloat(256/total)
        return (-support...support).map {towardZeroFloat(positive[abs($0)]*scale)/256}
    }

    private static func work(_ plan:GaussianPlan,extra:Int=0)throws->Int {
        let verticalRows:Int
        switch plan.vertical {
        case .none:verticalRows=0
        case .leadingRows(let count):
            guard count>=0,count<=plan.height else {throw SpatialImageEffectError.invalid("invalid vertical convolution extent")}
            verticalRows=count
        case .all:verticalRows=plan.height
        }
        let horizontalTaps=plan.edge == .transparent ? min(plan.weights.count,plan.sourceWidth):plan.weights.count
        let verticalTaps=plan.edge == .transparent ? min(plan.weights.count,plan.sourceHeight):plan.weights.count
        let horizontal=plan.width*plan.sourceHeight*(horizontalTaps+1)
        let vertical=plan.width*verticalRows*(verticalTaps+1)
        let (visits,overflow)=(horizontal+vertical).multipliedReportingOverflow(by:4)
        let (total,extraOverflow)=visits.addingReportingOverflow(extra)
        guard !overflow,!extraOverflow,total>=0 else {throw SpatialImageEffectError.invalid("spatial convolution work overflow")}
        return total
    }

    private static func gaussianPixels(_ plan:GaussianPlan)->Int {
        let rows:Int
        switch plan.vertical {
        case .none:rows=0
        case .leadingRows(let count):rows=count
        case .all:rows=plan.height
        }
        return plan.pixels+plan.width*rows
    }

    private static func sample(_ value:Int,limit:Int,edge:EdgePolicy)->Int? {
        if value>=0,value<limit {return value}
        switch edge {
        case .transparent:return nil
        case .clamp:return max(0,min(limit-1,value))
        case .mirror:
            if limit==1 {return 0}
            let period=2*(limit-1)
            var position=value%period;if position<0 {position+=period}
            return position<limit ? position:period-position
        }
    }
    private static func byte(_ value:Double)->UInt8 {
        UInt8(max(0,min(255,floor(value+0.5))))
    }

    /// The center consists of two half contributions, each rounded to Q8
    /// independently. Reflected duplicate taps likewise retain their own
    /// product rounding before accumulation. The native isolated/pair maps and
    /// independent high-gain Sharpen buffers distinguish this from one product.
    private static func q8Product(_ sample:UInt8,weight:Double,center:Bool)->Int {
        if center {return 2*Int(floor(Double(sample)*weight*128+0.5))}
        return Int(floor(Double(sample)*weight*256+0.5))
    }

    /// Separable CPU convolution with immutable source borrowing. Expanded
    /// transparent rows are initialized once; no source, PNG or global cache
    /// is modified. Callers reserve all output/work before allocation.
    private static func gaussian(_ pixels:Data,_ plan:GaussianPlan)->Data {
        let half=plan.weights.count/2
        var horizontal=Data(count:plan.pixels*4)
        pixels.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            horizontal.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                for y in 0..<plan.sourceHeight {for x in 0..<plan.width {
                    var r=0,g=0,b=0,a=0
                    let center=x-plan.pad
                    let first=plan.edge == .transparent ? max(0,half-center):0
                    let last=plan.edge == .transparent ? min(plan.weights.count,half+plan.sourceWidth-center):plan.weights.count
                    for tap in first..<max(first,last) {
                        guard let sx=sample(center+tap-half,limit:plan.sourceWidth,edge:plan.edge == .mirror && (half|1)>=plan.sourceWidth ? .clamp:plan.edge) else {continue}
                        let offset=(y*plan.sourceWidth+sx)*4,weight=plan.weights[tap]
                        r+=q8Product(source[offset],weight:weight,center:tap==half);g+=q8Product(source[offset+1],weight:weight,center:tap==half)
                        b+=q8Product(source[offset+2],weight:weight,center:tap==half);a+=q8Product(source[offset+3],weight:weight,center:tap==half)
                    }
                    let offset=((y+plan.pad)*plan.width+x)*4
                    target[offset]=byte(Double(r)/256);target[offset+1]=byte(Double(g)/256)
                    target[offset+2]=byte(Double(b)/256);target[offset+3]=byte(Double(a)/256)
                }}
            }
        }
        let count:Int
        switch plan.vertical {
        case .none:return horizontal
        case .leadingRows(let rows):count=rows
        case .all:count=plan.height
        }
        if count==0{return horizontal}
        // The measured optimized path changes only a small leading prefix.
        // Retain that prefix separately while reading horizontal bytes, rather
        // than triggering a full-image Data copy-on-write allocation.
        var output=Data(count:count*plan.width*4)
        horizontal.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                for y in 0..<count {for x in 0..<plan.width {
                    var r=0,g=0,b=0,a=0
                    let center=y-plan.pad
                    let first=plan.edge == .transparent ? max(0,half-center):0
                    let last=plan.edge == .transparent ? min(plan.weights.count,half+plan.sourceHeight-center):plan.weights.count
                    for tap in first..<max(first,last) {
                        guard let sy=sample(center+tap-half,limit:plan.sourceHeight,edge:plan.edge == .mirror && (half|1)>=plan.sourceHeight ? .clamp:plan.edge) else {continue}
                        let offset=((sy+plan.pad)*plan.width+x)*4,weight=plan.weights[tap]
                        r+=q8Product(source[offset],weight:weight,center:tap==half);g+=q8Product(source[offset+1],weight:weight,center:tap==half)
                        b+=q8Product(source[offset+2],weight:weight,center:tap==half);a+=q8Product(source[offset+3],weight:weight,center:tap==half)
                    }
                    let offset=(y*plan.width+x)*4
                    target[offset]=byte(Double(r)/256);target[offset+1]=byte(Double(g)/256)
                    target[offset+2]=byte(Double(b)/256);target[offset+3]=byte(Double(a)/256)
                }}
            }
        }
        horizontal.replaceSubrange(0..<output.count,with:output)
        return horizontal
    }

    /// Each axis completes its own byte reduction, Q8 filtering and enlargement
    /// before the next one starts. Expanded effects first pad the actual pixel
    /// canvas, so block alignment follows the requested output origin.
    private struct LargeAxisPlan {
        let width:Int,height:Int,horizontal:Bool
        let length:Int,lanes:Int,reducedLength:Int,factor:Int
        let weights:[Double],edge:EdgePolicy
        var pixels:Int {width*height}
        var reducedPixels:Int {reducedLength*lanes}
    }
    private struct LargeGaussianPlan {
        let axes:[LargeAxisPlan]
        let width:Int,height:Int,pad:Int
        let outputPixels:Int,work:Int
    }

    private static func largePlan(width:Int,height:Int,radius:Double,
                                  expandEdge:Bool,expandOutput:Bool,
                                  sharpening:Bool=false)throws->LargeGaussianPlan {
        let pad=expandEdge && expandOutput ? Int(ceil(radius)):0
        let outWidth=width+2*pad,outHeight=height+2*pad
        guard outWidth<=maximumDimension,outHeight<=maximumDimension,
              outWidth<=maximumPixels/outHeight else {
            throw SpatialImageEffectError.invalid("expanded spatial image exceeds pixel limit")
        }
        // Eighty belongs to the four-sample branch; the next representable
        // radius enters the eight-sample branch.
        let factor=radius<40 ? 2:radius<=80 ? 4:radius<160 ? 8:16
        let weights=gaussianWeights(radius:radius/Double(factor))
        let half=weights.count/2
        var axes:[LargeAxisPlan]=[],outputPixels=outWidth*outHeight,totalWork=0
        func add(_ amount:Int,to value:inout Int)throws {
            let (result,overflow)=value.addingReportingOverflow(amount)
            guard amount>=0,!overflow,result>=0 else {throw SpatialImageEffectError.invalid("spatial axis accounting overflow")}
            value=result
        }
        // Reserve the padded source and both axes' reduced, filtered and
        // reconstructed planes before allocating any working pixels.
        if pad>0 {try add(outWidth*outHeight,to:&outputPixels)}
        for horizontal in [true,false] {
            let length=horizontal ? outWidth:outHeight,lanes=horizontal ? outHeight:outWidth
            let reducedLength=(length+factor-1)/factor
            let edge:EdgePolicy=expandEdge ? .transparent:((half|1)>=reducedLength ? .clamp:.mirror)
            let axis=LargeAxisPlan(width:outWidth,height:outHeight,horizontal:horizontal,length:length,
                                   lanes:lanes,reducedLength:reducedLength,factor:factor,weights:weights,edge:edge)
            try add(axis.reducedPixels*2,to:&outputPixels)
            try add(axis.pixels,to:&outputPixels)
            try add(axis.pixels*4,to:&totalWork)
            let taps=edge == .transparent ? min(weights.count,reducedLength):weights.count
            // The center is two independent products, not one combined tap.
            try add(axis.reducedPixels*(taps+1)*4,to:&totalWork)
            try add(axis.pixels*32,to:&totalWork)
            axes.append(axis)
        }
        if sharpening {try add(width*height,to:&outputPixels);try add(width*height*4,to:&totalWork)}
        return LargeGaussianPlan(axes:axes,width:outWidth,height:outHeight,pad:pad,outputPixels:outputPixels,work:totalWork)
    }

    private static func axisGaussian(_ pixels:Data,_ plan:LargeAxisPlan)->Data {
        func index(_ position:Int,_ lane:Int,_ length:Int)->Int {
            plan.horizontal ? (lane*length+position)*4:(position*plan.lanes+lane)*4
        }
        var reduced=Data(count:plan.reducedPixels*4)
        pixels.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            reduced.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                for lane in 0..<plan.lanes {for block in 0..<plan.reducedLength {
                    let begin=block*plan.factor,end=min(plan.length,begin+plan.factor),count=end-begin
                    var sums=(0,0,0,0)
                    for position in begin..<end {
                        let origin=index(position,lane,plan.length)
                        sums.0+=Int(source[origin]);sums.1+=Int(source[origin+1]);sums.2+=Int(source[origin+2]);sums.3+=Int(source[origin+3])
                    }
                    let destination=index(block,lane,plan.reducedLength)
                    target[destination]=UInt8(sums.0/count);target[destination+1]=UInt8(sums.1/count)
                    target[destination+2]=UInt8(sums.2/count);target[destination+3]=UInt8(sums.3/count)
                }}
            }
        }
        let half=plan.weights.count/2
        var filtered=Data(count:plan.reducedPixels*4)
        reduced.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            filtered.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                for lane in 0..<plan.lanes {for position in 0..<plan.reducedLength {
                    let first=plan.edge == .transparent ? max(0,half-position):0
                    let last=plan.edge == .transparent ? min(plan.weights.count,half+plan.reducedLength-position):plan.weights.count
                    var sums=(0,0,0,0)
                    for tap in first..<max(first,last) {
                        guard let coordinate=sample(position+tap-half,limit:plan.reducedLength,edge:plan.edge) else {continue}
                        let origin=index(coordinate,lane,plan.reducedLength),weight=plan.weights[tap],center=tap==half
                        sums.0+=q8Product(source[origin],weight:weight,center:center);sums.1+=q8Product(source[origin+1],weight:weight,center:center)
                        sums.2+=q8Product(source[origin+2],weight:weight,center:center);sums.3+=q8Product(source[origin+3],weight:weight,center:center)
                    }
                    let destination=index(position,lane,plan.reducedLength)
                    target[destination]=byte(Double(sums.0)/256);target[destination+1]=byte(Double(sums.1)/256)
                    target[destination+2]=byte(Double(sums.2)/256);target[destination+3]=byte(Double(sums.3)/256)
                }}
            }
        }
        var output=Data(count:plan.pixels*4)
        filtered.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                pixels.withUnsafeBytes {(original:UnsafeRawBufferPointer) in
                    for lane in 0..<plan.lanes {for position in 0..<plan.length {
                        let destination=index(position,lane,plan.length)
                        // One sample has no slope. The single pixel past that
                        // branch's covered half-block retains its input.
                        if plan.reducedLength==1,plan.length-(plan.factor+1)/2==1,position==plan.length-1 {
                            for channel in 0..<4 {target[destination+channel]=original[destination+channel]}
                            continue
                        }
                        let coordinate=(Double(position)+0.5)/Double(plan.factor)-0.5
                        let left=max(0,min(max(0,plan.reducedLength-2),Int(floor(coordinate))))
                        let right=min(plan.reducedLength-1,left+1),fraction=coordinate-Double(left)
                        let first=index(left,lane,plan.reducedLength),second=index(right,lane,plan.reducedLength)
                        for channel in 0..<4 {
                            let value=Double(source[first+channel])*(1-fraction)+Double(source[second+channel])*fraction
                            target[destination+channel]=UInt8(max(0,min(255,floor(value+1e-9))))
                        }
                    }}
                }
            }
        }
        return output
    }

    private static func largeGaussian(_ pixels:Data,width:Int,height:Int,plan:LargeGaussianPlan)->Data {
        var output=pixels
        if plan.pad>0 {
            var canvas=Data(count:plan.width*plan.height*4)
            pixels.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
                canvas.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                    for row in 0..<height {
                        let origin=row*width*4,destination=((row+plan.pad)*plan.width+plan.pad)*4
                        target.baseAddress!.advanced(by:destination).copyMemory(from:source.baseAddress!.advanced(by:origin),byteCount:width*4)
                    }
                }
            }
            output=canvas
        }
        for axis in plan.axes {output=axisGaussian(output,axis)}
        return output
    }

    /// Given independently captured native Blur bytes, this Q6 unsharp rule
    /// matches all 220 initial direct Sharpen RGBA captures exactly. Fractional
    /// amount probes separately establish gain quantization across the API.
    private static func unsharp(_ pixels:Data,blurred:Data,amount:Double)->Data {
        let gain=Int(floor(64*amount/(250-2*amount)+0.5))
        var output=Data(count:pixels.count)
        pixels.withUnsafeBytes {(source:UnsafeRawBufferPointer) in
            blurred.withUnsafeBytes {(blur:UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes {(target:UnsafeMutableRawBufferPointer) in
                    for offset in stride(from:0,to:pixels.count,by:4) {
                        var maximum:UInt8=0
                        for channel in 0..<4 {
                            let value=Double(source[offset+channel])+Double(Int(source[offset+channel])-Int(blur[offset+channel]))*Double(gain)/64
                            let result=byte(value);target[offset+channel]=result;maximum=max(maximum,result)
                        }
                        target[offset+3]=maximum
                    }
                }
            }
        }
        return output
    }

    static func blur(pixels:Data,width:Int,height:Int,radius:Double,expandEdge:Bool,
                     expandOutput:Bool=true,budget:inout SpatialImageEffectBudget)throws->SpatialImageEffectResult {
        try validate(pixels:pixels,width:width,height:height)
        try validate(radius:radius)
        if radius==0 {
            try budget.reserve(outputPixels:width*height,work:0)
            return SpatialImageEffectResult(pixels:pixels,width:width,height:height)
        }
        if radius>=20 {
            let shape=try largePlan(width:width,height:height,radius:radius,
                                    expandEdge:expandEdge,expandOutput:expandOutput)
            try budget.reserve(outputPixels:shape.outputPixels,work:shape.work)
            return SpatialImageEffectResult(pixels:largeGaussian(pixels,width:width,height:height,plan:shape),
                                            width:shape.width,height:shape.height,originX:-shape.pad,originY:-shape.pad)
        }
        let vertical=playbackVerticalPolicy(width:width,height:height)
        // Native contained source ROIs use the transparent-edge kernel in
        // place; only the noncontained/created-output route adds padding.
        let shape=try plan(width:width,height:height,radius:radius,expand:expandEdge && expandOutput,
                           vertical:vertical,edge:expandEdge ? .transparent:.mirror)
        try budget.reserve(outputPixels:gaussianPixels(shape),work:work(shape))
        return SpatialImageEffectResult(pixels:gaussian(pixels,shape),width:shape.width,height:shape.height,
                                        originX:-shape.pad,originY:-shape.pad)
    }

    static func sharpen(pixels:Data,width:Int,height:Int,radius:Double,amount:Double,
                        budget:inout SpatialImageEffectBudget)throws->SpatialImageEffectResult {
        try validate(pixels:pixels,width:width,height:height)
        try validate(radius:radius)
        guard amount.isFinite,amount>=0,amount<=100 else {
            throw SpatialImageEffectError.invalid("invalid sharpening amount")
        }
        if radius==0 || amount==0 {
            try budget.reserve(outputPixels:width*height,work:width*height*4)
            return SpatialImageEffectResult(pixels:unsharp(pixels,blurred:pixels,amount:amount),width:width,height:height)
        }
        if radius>=20 {
            let shape=try largePlan(width:width,height:height,radius:radius,
                                    expandEdge:false,expandOutput:false,sharpening:true)
            try budget.reserve(outputPixels:shape.outputPixels,work:shape.work)
            let blurred=largeGaussian(pixels,width:width,height:height,plan:shape)
            return SpatialImageEffectResult(pixels:unsharp(pixels,blurred:blurred,amount:amount),width:width,height:height)
        }
        let vertical=playbackVerticalPolicy(width:width,height:height)
        let shape=try plan(width:width,height:height,radius:radius,expand:false,vertical:vertical,edge:.mirror)
        try budget.reserve(outputPixels:gaussianPixels(shape)+shape.pixels,work:work(shape,extra:shape.pixels*4))
        let blurred=gaussian(pixels,shape)
        return SpatialImageEffectResult(pixels:unsharp(pixels,blurred:blurred,amount:amount),width:width,height:height)
    }

    private static func playbackVerticalPolicy(width:Int,height:Int)->VerticalPolicy {
        // Tall opaque gradients establish complete leading-row extents 8 and
        // 4 for 17×129 and 33×129. This policy belongs to radius<20, regardless
        // of source minimum dimension; large kernels complete each whole axis
        // in turn above. Finite captures do not prove universal
        // undocumented Windows branch/precision identity.
        return .leadingRows(min(height,(height+width-1)/width))
    }
}
