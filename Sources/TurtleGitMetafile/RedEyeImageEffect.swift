// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation

/// Native Picture playback leaves the destination untouched when any valid
/// red-eye rectangle misses the source, including after an earlier valid area.
/// This is distinct from malformed wire data and transparent SourceCopy output.
enum RedEyeImageEffectNoPaint:Error {case rejectedArea}

/// Source-derived RedEye correction with deterministic fresh-first-use behavior.
/// Independent Windows FILE-v1 observations establish the image-local numerical
/// contract; unrelated native process history is not serialized effect state.
enum RedEyeImageEffects {
    static let angularBinCount=60

    /// Opaque-source statistics only. Native neutral0/96/255 probes have equal
    /// scalar-redness histograms but different angular corrections, so retain
    /// RGB co-moments too. This does not identify their eventual reduction.
    /// Center/ellipse detection and radial composition remain unresolved.
    struct AngularBinStatistics {
        private(set) var count=0
        private(set) var meanRedness=0.0
        private(set) var squaredDeviationSum=0.0
        private(set) var minimumRedness=1.0
        private(set) var maximumRedness=0.0
        private(set) var redSum=0.0
        private(set) var greenSum=0.0
        private(set) var blueSum=0.0
        private(set) var meanRed=0.0
        private(set) var meanGreen=0.0
        private(set) var meanBlue=0.0
        private(set) var redSquaredDeviationSum=0.0
        private(set) var greenSquaredDeviationSum=0.0
        private(set) var blueSquaredDeviationSum=0.0
        private(set) var redGreenDeviationProductSum=0.0
        private(set) var redBlueDeviationProductSum=0.0
        private(set) var greenBlueDeviationProductSum=0.0
        var populationVariance:Double {count>0 ? max(0,squaredDeviationSum/Double(count)):0}
        var sampleVariance:Double {count>1 ? max(0,squaredDeviationSum/Double(count-1)):0}
        var redPopulationVariance:Double {count>0 ? max(0,redSquaredDeviationSum/Double(count)):0}
        var greenPopulationVariance:Double {count>0 ? max(0,greenSquaredDeviationSum/Double(count)):0}
        var bluePopulationVariance:Double {count>0 ? max(0,blueSquaredDeviationSum/Double(count)):0}
        var redGreenPopulationCovariance:Double {count>0 ? redGreenDeviationProductSum/Double(count):0}
        var redBluePopulationCovariance:Double {count>0 ? redBlueDeviationProductSum/Double(count):0}
        var greenBluePopulationCovariance:Double {count>0 ? greenBlueDeviationProductSum/Double(count):0}

        fileprivate mutating func add(red:UInt8,green:UInt8,blue:UInt8) {
            let value=max(0,Double(red)-(Double(green)+Double(blue))/2)/255
            count += 1
            let delta=value-meanRedness
            meanRedness += delta/Double(count)
            squaredDeviationSum += delta*(value-meanRedness)
            minimumRedness=min(minimumRedness,value)
            maximumRedness=max(maximumRedness,value)
            let r=Double(red),g=Double(green),b=Double(blue)
            let dr=r-meanRed,dg=g-meanGreen,db=b-meanBlue
            meanRed += dr/Double(count)
            meanGreen += dg/Double(count)
            meanBlue += db/Double(count)
            redSquaredDeviationSum += dr*(r-meanRed)
            greenSquaredDeviationSum += dg*(g-meanGreen)
            blueSquaredDeviationSum += db*(b-meanBlue)
            redGreenDeviationProductSum += dr*(g-meanGreen)
            redBlueDeviationProductSum += dr*(b-meanBlue)
            greenBlueDeviationProductSum += dg*(b-meanBlue)
            redSum += r;greenSum += g;blueSum += b
        }
    }

    struct AreaPlan {
        let sourceRect:SpatialImageEffectRect
        let clippedLeft:Int
        let clippedTop:Int
        let clippedRight:Int
        let clippedBottom:Int
        var pixelCount:Int {(clippedRight-clippedLeft)*(clippedBottom-clippedTop)}
    }

    static func apply(pixels:Data,width:Int,height:Int,areas:[SpatialImageEffectRect],
                      budget:inout SpatialImageEffectBudget)throws->SpatialImageEffectResult {
        // Each conversion has an explicit fresh-first-use numerical contract.
        // Native repeated-file observations can inherit different process state;
        // that state is not part of the serialized image/effect input.
        return try causalCandidate(pixels:pixels,width:width,height:height,areas:areas,budget:&budget)
    }

    static func plan(areas:[SpatialImageEffectRect],width:Int,height:Int)throws->[AreaPlan] {
        guard !areas.isEmpty,areas.count<=4096 else {
            throw SpatialImageEffectError.invalid("invalid red-eye area count")
        }
        // The wire endpoints are signed Int32. The bridge first validates that
        // original profile, then translates by a bounded source crop origin.
        // A valid Int32.min endpoint may therefore be lower by up to32768.
        let minimumEndpoint=Int(Int32.min)-SpatialImageEffects.maximumDimension
        let maximumEndpoint=Int(Int32.max)+SpatialImageEffects.maximumDimension
        var result=[AreaPlan]();result.reserveCapacity(areas.count)
        var hasEmptyClip=false
        for area in areas {
            let endpoints=[area.left,area.top,area.right,area.bottom]
            guard endpoints.allSatisfy({$0>=minimumEndpoint && $0<=maximumEndpoint}),
                  area.left<area.right,area.top<area.bottom else {
                throw SpatialImageEffectError.invalid("invalid red-eye rectangle endpoints")
            }
            let left=max(0,min(width,area.left)),right=max(0,min(width,area.right))
            let top=max(0,min(height,area.top)),bottom=max(0,min(height,area.bottom))
            if left>=right || top>=bottom {hasEmptyClip=true;continue}
            result.append(AreaPlan(sourceRect:area,clippedLeft:left,clippedTop:top,clippedRight:right,clippedBottom:bottom))
        }
        // Validate every authored endpoint before reporting native no-paint:
        // a later malformed rectangle must still refuse the entire conversion.
        if hasEmptyClip {throw RedEyeImageEffectNoPaint.rejectedArea}
        return result
    }

    /// Independently measured on both native inverse/seed assays: sixty
    /// half-open angular sectors, each six degrees. This does not choose the
    /// center: translated/noncentral foreground requires a separate detector.
    static func angularBin(x:Double,y:Double,centerX:Double,centerY:Double)->Int? {
        guard x.isFinite,y.isFinite,centerX.isFinite,centerY.isFinite else {return nil}
        var angle=atan2(y-centerY,x-centerX)
        if angle<0 {angle += 2*Double.pi}
        let index=Int(floor(angle*30/Double.pi))
        return index==angularBinCount ? 0:index
    }

    /// Accumulate immutable opaque input over an explicitly supplied ellipse.
    /// Geometry is an input here, not an inferred general-image contract.
    /// Welford accumulation retains both variance conventions for the still
    /// unresolved radial component; no pixel conversion calls this yet.
    static func aggregateOpaque(pixels:Data,width:Int,height:Int,area:AreaPlan,
                                centerX:Double,centerY:Double,radiusX:Double,radiusY:Double,
                                budget:inout SpatialImageEffectBudget)throws->[AngularBinStatistics] {
        _ = try SpatialImageEffects.validate(pixels:pixels,width:width,height:height)
        guard centerX.isFinite,centerY.isFinite,radiusX.isFinite,radiusY.isFinite,radiusX>0,radiusY>0,
              area.clippedLeft>=0,area.clippedTop>=0,area.clippedRight<=width,area.clippedBottom<=height,
              area.clippedLeft<area.clippedRight,area.clippedTop<area.clippedBottom else {
            throw SpatialImageEffectError.invalid("invalid red-eye angular geometry")
        }
        let (work,overflow)=area.pixelCount.multipliedReportingOverflow(by:64)
        guard !overflow else {throw SpatialImageEffectError.invalid("red-eye angular work overflow")}
        try budget.reserve(outputPixels:0,work:work)
        var bins=Array(repeating:AngularBinStatistics(),count:angularBinCount)
        try pixels.withUnsafeBytes { (source:UnsafeRawBufferPointer) in
            for y in area.clippedTop..<area.clippedBottom {
                for x in area.clippedLeft..<area.clippedRight {
                    guard hypot((Double(x)-centerX)/radiusX,(Double(y)-centerY)/radiusY)<1 else {continue}
                    let index=4*(y*width+x)
                    guard source[index+3]==255 else {
                        throw SpatialImageEffectError.invalid("red-eye angular alpha contract pending")
                    }
                    guard let bin=angularBin(x:Double(x),y:Double(y),centerX:centerX,centerY:centerY) else {
                        throw SpatialImageEffectError.invalid("invalid red-eye angular coordinate")
                    }
                    bins[bin].add(red:source[index],green:source[index+1],blue:source[index+2])
                }
            }
        }
        return bins
    }

    /// The natural floor component matches all-channel rounding intervals for
    /// fifteen distinct native central square/disk bin populations. Its use,
    /// subtraction/gating and radial composition are not yet established for
    /// general images; in particular this must not replace the uniform cone.
    /// The measured low-mean domain does not uniquely distinguish this rational
    /// expression from a finite odd-power expansion. Keep it inactive until
    /// high-red-fraction composition resolves that ambiguity.
    static func naturalFloorMask(meanRedness:Double)throws->Double {
        guard meanRedness.isFinite,meanRedness>=0,meanRedness<=1 else {
            throw SpatialImageEffectError.invalid("invalid red-eye angular mean")
        }
        if meanRedness==1 {return 0}
        return max(0,min(1,1-0.4*meanRedness/(1-meanRedness*meanRedness)))
    }

    /// Exact baseline for an opaque constant-color ROI, independently derived
    /// from20 original Windows cases (colors,16/24/32/33 dimensions, tight and
    /// partial ROIs). The radius spans pixel centers, hence extent minus one.
    /// This is one component of the detector, not a fallback for general photos.
    static func uniformBaselineMask(x:Int,y:Int,area:SpatialImageEffectRect)->Double {
        let radiusX=Double(area.right-area.left-1)/2
        let radiusY=Double(area.bottom-area.top-1)/2
        guard radiusX>0,radiusY>0 else {return 0}
        let centerX=Double(area.left)+radiusX,centerY=Double(area.top)+radiusY
        let distance=hypot((Double(x)-centerX)/radiusX,(Double(y)-centerY)/radiusY)
        return max(0,1-distance)/2
    }

    /// The supplied glint's local component was independently observed at
    /// 16/24/32/33 pixel dimensions, rectangular images, a tight ROI, and several
    /// source colors. Its coefficient is in original source pixels: neither
    /// image dimensions nor the ROI scale it. Selection, spatial eligibility
    /// and the detector's clipping ellipse are separate operations; this does
    /// not choose a glint or substitute a circle for the general detector.
    static func opaqueGlintStrength(red:UInt8,green:UInt8,blue:UInt8,
                                    x:Int,y:Int,glintX:Int,glintY:Int)->Double {
        let redness=Double(max(0,Int(red)-max(Int(green),Int(blue))))
        // Convert before subtraction so even a rejected caller coordinate
        // cannot overflow integer arithmetic. Far coordinates contribute zero.
        let dx=Double(x)-Double(glintX),dy=Double(y)-Double(glintY)
        return max(0,redness-5*(dx*dx+dy*dy))
    }

    /// The correction direction and final rounding are exact for the observed
    /// uniform baseline and supplied opaque-glint component. Alpha is retained;
    /// alpha-source mask generation remains a separate unresolved operation.
    static func correct(red:UInt8,green:UInt8,blue:UInt8,alpha:UInt8,strength:Double)
        ->(UInt8,UInt8,UInt8,UInt8) {
        let redness=Double(max(0,Int(red)-max(Int(green),Int(blue))))
        let change=strength.isFinite ? max(0,min(redness,strength)):0
        func byte(_ value:Double)->UInt8 {UInt8(max(0,min(255,Int(value.rounded()))))}
        return (byte(Double(red)-11*change/16),byte(Double(green)+5*change/16),
                byte(Double(blue)+5*change/16),alpha)
    }

    /// A supplied mask is squared before the shared RGB correction. The
    /// general nonuniform mask must still be independently established.
    static func correct(red:UInt8,green:UInt8,blue:UInt8,alpha:UInt8,mask:Double)
        ->(UInt8,UInt8,UInt8,UInt8) {
        let boundedMask=mask.isFinite ? max(0,min(1,mask)):0
        let redness=Double(max(0,Int(red)-max(Int(green),Int(blue))))
        return correct(red:red,green:green,blue:blue,alpha:alpha,
                       strength:redness*boundedMask*boundedMask)
    }

    // Research lead: ChristopherVR/emf-converter, commit
    // effcf337218fefc08e4ac8f74e59cd2af1a9235c,
    // https://github.com/ChristopherVR/emf-converter/blob/effcf337218fefc08e4ac8f74e59cd2af1a9235c/src/emf-plus-image-effects.ts
    // The independent Swift formulation below uses our original Windows RGBA
    // observations as its oracle. No external source code or reference pixels
    // are incorporated. Fresh-first-use FILE-v1 captures resolve the two old
    // pure-red residuals; old process-history observations remain preserved.

    struct CausalCarry {
        fileprivate var previousCenter:(x:Double,y:Double)?
        fileprivate var brightest:(x:Int,y:Int,luma:Int)?
    }

    struct CausalGeometry {
        let centerX:Double
        let centerY:Double
        let radius:Double
        let usedDarknessCenter:Bool
        let radialStrength:Double
        let highlight:Int?
    }

    private struct CausalSamples {
        let width:Int
        let height:Int
        let redness:[Double]
        let darkness:[Double]
        let luma:[Int]
        let histogram:[Int]
        let participates:[Bool]
        let population:Int

        init(source:[UInt8],stride:Int,area:AreaPlan) {
            width=area.clippedRight-area.clippedLeft
            height=area.clippedBottom-area.clippedTop
            var red=[Double]();red.reserveCapacity(area.pixelCount)
            var dark=[Double]();dark.reserveCapacity(area.pixelCount)
            var luminance=[Int]();luminance.reserveCapacity(area.pixelCount)
            var bins=Array(repeating:0,count:256)
            var active=[Bool]();active.reserveCapacity(area.pixelCount)
            var visibleCount=0
            for y in area.clippedTop..<area.clippedBottom {
                for x in area.clippedLeft..<area.clippedRight {
                    let i=4*(y*stride+x)
                    let r=Int(source[i]),g=Int(source[i+1]),b=Int(source[i+2])
                    let l=(9*g+2*b+5)/11
                    red.append(Double(max(0,r-max(g,b))))
                    dark.append(Double(g)+Double(b)*2/9)
                    luminance.append(l)
                    let visible=source[i+3]>0
                    active.append(visible)
                    if visible {bins[l]+=1;visibleCount+=1}
                }
            }
            redness=red;darkness=dark;luma=luminance;histogram=bins
            participates=active;population=visibleCount
        }

        func quantile(index:Int)->Int {
            var cumulative=0
            for value in histogram.indices {
                cumulative += histogram[value]
                if cumulative>index {return value}
            }
            return 255
        }
    }

    /// Round a finite intermediate toward zero to the adjacent binary32 value.
    /// Keeping the operation in Double first makes the direction explicit; a
    /// native Float cast alone uses the process's nearest rounding convention.
    static func truncatingBinary32(_ value:Double)->Double {
        let rounded=Float(value)
        guard value.isFinite,rounded.isFinite else {return Double(rounded)}
        if abs(Double(rounded))>abs(value) {
            return Double(value<0 ? rounded.nextUp:rounded.nextDown)
        }
        return Double(rounded)
    }

    private static func causalGeometry(samples:CausalSamples,area:AreaPlan,
                                       carry:inout CausalCarry)->CausalGeometry? {
        let t=truncatingBinary32
        var sx=0.0,sy=0.0,total=0.0
        for i in samples.redness.indices where samples.participates[i] && samples.redness[i]>0 {
            let l=samples.luma[i]
            let weight=l>0 ? t(samples.redness[i]/Double(l)):1
            sx=t(sx+t(weight*Double(i%samples.width)))
            sy=t(sy+t(weight*Double(i/samples.width)))
            total=t(total+weight)
        }
        guard total>0 else {return nil}
        if let previous=carry.previousCenter {
            sx=t(sx+t(previous.x-0.5));sy=t(sy+t(previous.y-0.5))
        }
        var cx=t(t(sx/total)+0.5),cy=t(t(sy/total)+0.5)
        carry.previousCenter=(Double(area.clippedLeft)+cx,Double(area.clippedTop)+cy)
        let w=Double(samples.width),h=Double(samples.height)
        let fallback=hypot(cx-w/2,cy-h/2)>=(w+h)/6
        if fallback {
            sx=0;sy=0;total=0
            for i in samples.luma.indices {
                let weight=Double(255-samples.luma[i])
                sx=t(sx+t(weight*Double(i%samples.width)))
                sy=t(sy+t(weight*Double(i/samples.width)))
                total=t(total+weight)
            }
            guard total>0 else {return nil}
            cx=t(t(sx/total)+0.5);cy=t(t(sy/total)+0.5)
        }
        let edgeX=floor(cx+0.5)>w/2 ? w-cx+0.5:cx-0.5
        let edgeY=floor(cy+0.5)>h/2 ? h-cy+0.5:cy-0.5
        let absoluteX=Double(area.clippedLeft)+cx,absoluteY=Double(area.clippedTop)+cy
        let radius=absoluteX>absoluteY ? min(edgeX,absoluteY-0.5):min(edgeY,absoluteX-0.5)
        let low=samples.quantile(index:samples.population*3/10)
        let high=samples.quantile(index:samples.population*7/10)
        let spread=high-low
        let strength:Double
        switch spread {
        case ...25:strength=0.25
        case ...40:strength=0.5
        case ...80:strength=0.66
        default:strength=0.75
        }
        let brightest=samples.quantile(index:samples.population-1)
        // The first maximum survives tied maxima in later authored areas.
        // Disjoint native ROIs distinguish this image-coordinate carry from a
        // fresh maximum per ROI. A strictly brighter sample replaces it.
        if carry.brightest.map({brightest>$0.luma}) ?? true {
            if let i=samples.luma.firstIndex(of:brightest) {
                carry.brightest=(area.clippedLeft+i%samples.width,
                                 area.clippedTop+i/samples.width,brightest)
            }
        }
        var highlight:Int?
        if let peak=carry.brightest,peak.luma-high>=40,
           peak.x>=area.clippedLeft,peak.x<area.clippedRight,
           peak.y>=area.clippedTop,peak.y<area.clippedBottom {
            highlight=(peak.y-area.clippedTop)*samples.width+peak.x-area.clippedLeft
        }
        return CausalGeometry(centerX:cx,centerY:cy,radius:radius,
                              usedDarknessCenter:fallback,radialStrength:strength,highlight:highlight)
    }

    /// Shared image-local numerical entry, also exposed to the arithmetic
    /// development probe. Every area reads the original source;
    /// later authored areas replace their complete ROI, while retaining the
    /// centroid and first-brightest-point carries. This differs from in-place SDK ApplyEffect.
    static func causalCandidate(pixels:Data,width:Int,height:Int,areas:[SpatialImageEffectRect],
                                budget:inout SpatialImageEffectBudget)throws->SpatialImageEffectResult {
        let count=try SpatialImageEffects.validate(pixels:pixels,width:width,height:height)
        let plans=try plan(areas:areas,width:width,height:height)
        // One atomic reservation precedes every detector/output allocation.
        // Allocation units are four-byte pixel equivalents: three full-image
        // copies plus a conservative twelve units per area sample for RGB/luma,
        // participation, distance and sector buffers. Fixed area tables/metadata
        // fit in 1024 further units. Account all authored areas, not only peak
        // live storage, matching the conversion-owned aggregate budget.
        func product(_ value:Int,_ factor:Int)throws->Int {
            let (result,overflow)=value.multipliedReportingOverflow(by:factor)
            guard !overflow else {throw SpatialImageEffectError.invalid("red-eye area work overflow")}
            return result
        }
        func adding(_ left:Int,_ right:Int)throws->Int {
            let (result,overflow)=left.addingReportingOverflow(right)
            guard !overflow else {throw SpatialImageEffectError.invalid("red-eye area work overflow")}
            return result
        }
        var allocations=try product(count,3),work=try product(count,12)
        for area in plans {
            allocations=try adding(allocations,adding(product(area.pixelCount,12),1024))
            work=try adding(work,adding(product(area.pixelCount,192),2048))
        }
        try budget.reserve(outputPixels:allocations,work:work)
        let source=[UInt8](pixels)
        var result=source,carry=CausalCarry()
        for area in plans {
            for y in area.clippedTop..<area.clippedBottom {
                let a=4*(y*width+area.clippedLeft),b=4*(y*width+area.clippedRight)
                result.replaceSubrange(a..<b,with:source[a..<b])
            }
            let samples=CausalSamples(source:source,stride:width,area:area)
            guard let geometry=causalGeometry(samples:samples,area:area,carry:&carry) else {continue}
            causalCorrection(samples:samples,geometry:geometry,area:area,stride:width,source:source,result:&result)
        }
        return SpatialImageEffectResult(pixels:Data(result),width:width,height:height)
    }

    private static func causalCorrection(samples:CausalSamples,geometry:CausalGeometry,area:AreaPlan,
                                         stride:Int,source:[UInt8],result:inout [UInt8]) {
        let t=truncatingBinary32
        guard geometry.radius>0,samples.width>1,samples.height>1 else {return}
        var distance=Array(repeating:0.0,count:samples.luma.count)
        var sector=Array(repeating:0,count:samples.luma.count)
        var populations=Array(repeating:0,count:angularBinCount)
        var redness=Array(repeating:0.0,count:angularBinCount)
        var darkness=Array(repeating:0.0,count:angularBinCount)
        let radiusSquared=t(geometry.radius*geometry.radius)
        for i in samples.luma.indices {
            let dx=Double(i%samples.width)+0.5-geometry.centerX
            let dy=Double(i/samples.width)+0.5-geometry.centerY
            let squared=t(t(dx*dx)+t(dy*dy))
            distance[i]=t(sqrt(squared))
            let bin:Int
            if dx==0,dy==0 {bin=15}
            else if dy==0 {bin=0}
            else {bin=angularBin(x:dx,y:dy,centerX:0,centerY:0) ?? 0}
            sector[i]=bin
            if squared<radiusSquared,samples.participates[i] {
                populations[bin]+=1
                redness[bin]+=samples.redness[i]
                darkness[bin]+=samples.darkness[i]
            }
        }
        let highlight=geometry.highlight.flatMap {distance[$0]<geometry.radius*2/3 ? $0:nil}
        for i in samples.luma.indices where samples.participates[i] && samples.redness[i]>0 && distance[i]<geometry.radius {
            let bin=sector[i]
            guard populations[bin]>0 else {continue}
            let mean=t(redness[bin]/Double(populations[bin]))
            let meanDark=t(darkness[bin]/Double(populations[bin]))
            let ratio=meanDark>0 ? t(samples.darkness[i]/meanDark):1
            let q=t(1-t(distance[i]/geometry.radius))
            let radial=t(t(geometry.radialStrength)*t(q*q))
            let difference=t(1-ratio)
            let pupil=ratio<2 ? t(0.5*t(difference*difference)):0
            let fallback=geometry.usedDarknessCenter ? t(0.33*q):0
            var remainder=t(t(1-max(max(radial,pupil),fallback))*mean)
            if let highlight {
                let dx=Double(i%samples.width-highlight%samples.width)
                let dy=Double(i/samples.width-highlight/samples.width)
                remainder=min(remainder,5*(dx*dx+dy*dy))
            }
            let offset=4*((area.clippedTop+i/samples.width)*stride+area.clippedLeft+i%samples.width)
            let rgba=correct(red:source[offset],green:source[offset+1],blue:source[offset+2],alpha:source[offset+3],
                             strength:samples.redness[i]-remainder)
            result[offset]=rgba.0;result[offset+1]=rgba.1;result[offset+2]=rgba.2
        }
    }
}
