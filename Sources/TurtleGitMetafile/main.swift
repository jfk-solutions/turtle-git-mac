// Copyright (C) TurtleGit contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Darwin
import JavaScriptCore
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import CryptoKit

private let inputLimit = 64 * 1024 * 1024
private let outputLimit = 128 * 1024 * 1024
private enum ConversionError: Error { case invalid(String) }
/// CoreFoundation advertises CP1361 but has no working Johab decoder on
/// supported hosts. The system codec stays in this sandboxed process: no shell,
/// executable, files or conversion fallback are exposed to the document.
private func decodeJohab(_ bytes:Data)throws->String {
    guard bytes.count<=32_768 else {throw ConversionError.invalid("Johab text unit limit")}
    if bytes.isEmpty {return ""}
    guard let converter=iconv_open("UTF-8","JOHAB"),converter != OpaquePointer(bitPattern:-1) else {throw ConversionError.invalid("System Johab decoder unavailable")}
    defer {_ = iconv_close(converter)}
    var input=bytes.map{CChar(bitPattern:$0)},output=[CChar](repeating:0,count:bytes.count*4+4)
    var inputLeft=input.count,outputLeft=output.count
    let converted=input.withUnsafeMutableBufferPointer {source in
        output.withUnsafeMutableBufferPointer {destination in
            var from=source.baseAddress,to=destination.baseAddress
            return iconv(converter,&from,&inputLeft,&to,&outputLeft)
        }
    }
    guard converted==0,inputLeft==0 else {throw ConversionError.invalid("Invalid encoded Johab text")}
    let used=output.count-outputLeft
    guard let text=output.withUnsafeBytes({String(bytes:$0.prefix(used),encoding:.utf8)}) else {throw ConversionError.invalid("Invalid Johab decoder output")}
    return text
}
/// GDI+ exposes timed/looping GIFs as animation (default frame zero), but
/// flattens an untimed, nonlooping sequence to its final composited canvas.
/// ImageIO clamps zero delays and supplies a default LoopCount, so classify
/// the original control/application records instead of those normalized values.
private func compressedGIFIsAnimated(_ bytes:Data)throws->Bool {
    func need(_ p:Int,_ n:Int)throws {guard p>=0,n>=0,p<=bytes.count-n else{throw ConversionError.invalid("Truncated compressed GIF control data")}}
    try need(0,13)
    var p=13+((bytes[10]&128) != 0 ? 3*(1 << (Int(bytes[10]&7)+1)):0),animated=false,steps=0
    func subblocks(_ inspect:((Data)->Void)? = nil)throws {
        while true {try need(p,1);let count=Int(bytes[p]);p += 1;if count==0{return};try need(p,count);inspect?(bytes.subdata(in:p..<p+count));p += count;steps += 1;guard steps<=1_048_576 else{throw ConversionError.invalid("Compressed GIF control budget exceeded")}}
    }
    while true {
        try need(p,1);let kind=bytes[p];p += 1;steps += 1
        guard steps<=1_048_576 else{throw ConversionError.invalid("Compressed GIF control budget exceeded")}
        if kind==59{return animated}
        if kind==33 {
            try need(p,1);let label=bytes[p];p += 1
            if label==249 {
                try need(p,6);guard bytes[p]==4,bytes[p+5]==0 else{throw ConversionError.invalid("Invalid compressed GIF graphics control")}
                if bytes[p+2] != 0 || bytes[p+3] != 0 {animated=true};p += 6
            } else if label==255 {
                try need(p,1);let count=Int(bytes[p]);p += 1;try need(p,count)
                let identifier=String(data:bytes.subdata(in:p..<p+count),encoding:.ascii);p += count
                try subblocks { block in if identifier=="NETSCAPE2.0",block.count==3,block[0]==1{animated=true} }
            } else {try subblocks()}
        } else if kind==44 {
            try need(p,9);let flags=bytes[p+8];p += 9+((flags&128) != 0 ? 3*(1 << (Int(flags&7)+1)):0)
            try need(p,1);p += 1;try subblocks()
        } else {throw ConversionError.invalid("Invalid compressed GIF record")}
    }
}

/// Classic direct bitmap copies use RGB, independently of a compressed PNG's
/// alpha. Preserve the decoded channel samples before any drawing/compositing;
/// flattening over white would invent colors. Premultiplied transparent sources
/// cannot prove their original RGB and are refused rather than guessed.
private func classicOpaqueCompressedImage(_ image:CGImage)throws->CGImage {
    switch image.alphaInfo {
    case .none,.noneSkipFirst,.noneSkipLast:return image
    case .first,.last,.premultipliedFirst,.premultipliedLast:break
    default:throw ConversionError.invalid("Unsupported classic compressed alpha layout")
    }
    guard !image.isMask,!image.bitmapInfo.contains(.floatComponents),
          let space=image.colorSpace,[CGColorSpaceModel.rgb,.monochrome].contains(space.model),
          [8,16].contains(image.bitsPerComponent),
          image.bitsPerPixel==image.bitsPerComponent*(space.numberOfComponents+1),
          let stored=image.dataProvider?.data else {throw ConversionError.invalid("Unsupported classic compressed channel layout")}
    let step=image.bitsPerPixel/8,sample=image.bitsPerComponent/8
    guard step>0,image.bytesPerRow>=image.width*step,image.height<=inputLimit/image.bytesPerRow,
          CFDataGetLength(stored)>=image.height*image.bytesPerRow else {throw ConversionError.invalid("Invalid classic compressed pixel storage")}
    var bytes=Data(bytes:CFDataGetBytePtr(stored),count:image.height*image.bytesPerRow)
    let first=image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst
    let premultiplied=image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
    let byteOrder=image.bitmapInfo.intersection(.byteOrderMask)
    // Little-endian packed pixels move the alpha sample to the opposite end.
    // With 16-bit components, component byte order alone does not move it.
    var alphaOffset=first ? 0:step-sample
    if byteOrder == .byteOrder32Little {
        guard image.bitsPerPixel==32 else {throw ConversionError.invalid("Unsupported classic compressed pixel byte order")}
        alphaOffset=step-sample-alphaOffset
    } else if byteOrder == .byteOrder16Little && image.bitsPerComponent==8 {
        guard image.bitsPerPixel==16 else {throw ConversionError.invalid("Unsupported classic compressed pixel byte order")}
        alphaOffset=step-sample-alphaOffset
    }
    for y in 0..<image.height {for x in 0..<image.width {
        let offset=y*image.bytesPerRow+x*step+alphaOffset
        for n in 0..<sample {
            if premultiplied && bytes[offset+n] != 255 {throw ConversionError.invalid("Premultiplied compressed alpha cannot preserve classic RGB")}
            bytes[offset+n]=255
        }
    }}
    guard let provider=CGDataProvider(data:bytes as CFData),let result=CGImage(width:image.width,height:image.height,
        bitsPerComponent:image.bitsPerComponent,bitsPerPixel:image.bitsPerPixel,bytesPerRow:image.bytesPerRow,
        space:space,bitmapInfo:image.bitmapInfo,provider:provider,decode:image.decode,shouldInterpolate:false,intent:image.renderingIntent)
        else {throw ConversionError.invalid("Cannot preserve classic compressed RGB")}
    return result
}
/// Pointwise EMF+ effects operate on straight color samples before image
/// placement, clipping and compositing. The source PNG and image-table object
/// remain immutable; each conversion owns its aggregate work budget.
private final class NativeImageEffects {
    private var calls = 0
    private var pixelsProcessed = 0
    private var curveData:Data?
    private var spatialBudget=SpatialImageEffectBudget()
    private var picturePlan:(width:Int,height:Int,needed:Bool)?
    /// Parameters are copied out of JavaScript before pixel work starts. No
    /// transform retains mutable script objects or changes an image-object cache.
    private enum Effect {
        case matrix([Double])
        case lookup([[UInt8]])
        case brightnessContrast(Int,Int)
        case colorBalance(Int,Int,Int)
        case hueSaturationLightness(Int,Int,Int)
        case levels(Int,Int,Int)
        case colorCurve(adjustment:Int,channel:Int,value:Int)
        case tint(hue:Int,amount:Int)
        case spatial(SpatialImageEffect)
    }
    private enum PreparedEffect {
        case ordinary
        case matrix([Double])
        case lookup([[UInt8]])
        case rgb((UInt8,UInt8,UInt8)->(UInt8,UInt8,UInt8))
    }
    private func invalid(_ message:String)->ConversionError { .invalid("Metafile image effect: "+message) }
    private func numbers(_ object:JSValue,_ key:String,count:Int)throws->[Double] {
        guard let values=object.forProperty(key),values.isArray,
              values.forProperty("length")?.toDouble()==Double(count) else {throw invalid("invalid "+key+" length")}
        return try (0..<count).map { index in
            guard let value=values.atIndex(index),value.isNumber else {throw invalid("invalid "+key+" value")}
            let number=value.toDouble()
            guard number.isFinite else {throw invalid("nonfinite "+key+" value")}
            return number
        }
    }
    private func table(_ object:JSValue,_ key:String)throws->[UInt8] {
        try numbers(object,key,count:256).map { value in
            guard value>=0,value<=255,value.rounded()==value else {throw invalid("invalid "+key+" byte")}
            return UInt8(value)
        }
    }
    private func integer(_ object:JSValue,_ key:String,range:ClosedRange<Int>)throws->Int {
        guard let value=object.forProperty(key),value.isNumber else {throw invalid("missing "+key)}
        let number=value.toDouble()
        guard number.isFinite,number.rounded()==number,number>=Double(range.lowerBound),number<=Double(range.upperBound) else {throw invalid("invalid "+key)}
        return Int(number)
    }
    private func real(_ object:JSValue,_ key:String,range:ClosedRange<Double>)throws->Double {
        guard let value=object.forProperty(key),value.isNumber else {throw invalid("missing "+key)}
        let number=value.toDouble()
        guard number.isFinite,range.contains(number) else {throw invalid("invalid "+key)}
        return number
    }
    private func areas(_ object:JSValue)throws->[SpatialImageEffectRect] {
        guard let values=object.forProperty("areas"),values.isArray,
              let countValue=values.forProperty("length"),countValue.isNumber else {throw invalid("invalid red-eye areas")}
        let size=countValue.toDouble()
        guard size.isFinite,size>=1,size<=4096,size.rounded()==size else {throw invalid("invalid red-eye area count")}
        return try (0..<Int(size)).map {index in
            guard let area=values.atIndex(index),area.isArray,area.forProperty("length")?.toDouble()==4 else {throw invalid("invalid red-eye rectangle")}
            let endpoints=try (0..<4).map {component->Int in
                guard let item=area.atIndex(component),item.isNumber else {throw invalid("invalid red-eye rectangle endpoint")}
                let number=item.toDouble()
                guard number.isFinite,number.rounded()==number,number>=Double(Int32.min),number<=Double(Int32.max) else {throw invalid("invalid red-eye rectangle endpoint")}
                return Int(number)
            }
            // Validate the complete wire profile before image decoding or an
            // empty source-crop shortcut. Valid outside areas may skip paint;
            // malformed later endpoints must still refuse the conversion.
            guard endpoints[0]<endpoints[2],endpoints[1]<endpoints[3] else {throw invalid("invalid red-eye rectangle endpoints")}
            return SpatialImageEffectRect(left:endpoints[0],top:endpoints[1],right:endpoints[2],bottom:endpoints[3])
        }
    }
    private func parse(_ object:JSValue)throws->Effect {
        guard object.isObject,!object.isArray,let kind=object.forProperty("kind"),kind.isString else {throw invalid("invalid effect object")}
        switch kind.toString() {
        case "colorMatrix":return .matrix(try numbers(object,"matrix",count:25))
        case "colorLookupTable":return .lookup(try [table(object,"red"),table(object,"green"),table(object,"blue"),table(object,"alpha")])
        case "brightnessContrast":return .brightnessContrast(try integer(object,"brightness",range:-255...255),try integer(object,"contrast",range:-100...100))
        case "colorBalance":return .colorBalance(try integer(object,"cyanRed",range:-100...100),try integer(object,"magentaGreen",range:-100...100),try integer(object,"yellowBlue",range:-100...100))
        case "hueSaturationLightness":return .hueSaturationLightness(try integer(object,"hueLevel",range:-180...180),try integer(object,"saturationLevel",range:-100...100),try integer(object,"lightnessLevel",range:-100...100))
        case "levels":return .levels(try integer(object,"highlight",range:0...100),try integer(object,"midtone",range:-100...100),try integer(object,"shadow",range:0...100))
        case "colorCurve":
            let adjustment=try integer(object,"adjustment",range:0...7)
            let range:ClosedRange<Int>=adjustment<2 ? -255...255:adjustment<6 ? -100...100:0...255
            return .colorCurve(adjustment:adjustment,channel:try integer(object,"channel",range:0...3),value:try integer(object,"adjustValue",range:range))
        case "tint":return .tint(hue:try integer(object,"hue",range:-180...180),amount:try integer(object,"amount",range:-100...100))
        case "blur":
            guard let expand=object.forProperty("expandEdge"),expand.isBoolean else {throw invalid("invalid blur expandEdge")}
            return .spatial(.blur(radius:try real(object,"radius",range:0...255),expandEdge:expand.toBool()))
        case "sharpen":return .spatial(.sharpen(radius:try real(object,"radius",range:0...255),amount:try real(object,"amount",range:0...100)))
        case "redEyeCorrection":return .spatial(.redEyeCorrection(areas:try areas(object)))
        default:throw invalid("unsupported effect kind")
        }
    }
    private func prepare(_ effect:Effect)throws->PreparedEffect {
        switch effect {
        case .matrix(let values):return .matrix(values)
        case .lookup(let values):return .lookup(values)
        case .brightnessContrast(let brightness,let contrast):
            let values=brightnessTable(brightness,contrast)
            return .lookup([values,values,values,(0..<256).map{UInt8($0)}])
        case .colorBalance(let red,let green,let blue):
            return .lookup([balanceTable(red),balanceTable(green),balanceTable(blue),(0..<256).map{UInt8($0)}])
        case .levels(let highlight,let midtone,let shadow):
            let values=levelsTable(highlight,midtone,shadow)
            return .lookup([values,values,values,(0..<256).map{UInt8($0)}])
        case .hueSaturationLightness(let hue,let saturation,let lightness):
            return .rgb(hslTransform(hue,saturation,lightness))
        case .colorCurve(let adjustment,let channel,let value):
            let values=try curveTable(adjustment,value)
            let identity=(0..<256).map{UInt8($0)}
            return .lookup((1...3).map {channel==0 || channel==$0 ? values:identity}+[identity])
        case .tint(let hue,let amount):return .rgb(tintTransform(hue,amount))
        case .spatial:throw invalid("spatial effects require the geometry adapter")
        }
    }
    /// The complete finite integer Curve domain was captured from native
    /// Windows GDI+ v1/v2. Verify the immutable bundled table before using any
    /// row: a missing, replaced, truncated or unknown-profile resource fails
    /// this conversion rather than silently dropping the requested effect.
    private func curveTable(_ adjustment:Int,_ value:Int)throws->[UInt8] {
        if adjustment==6 && value==0 || adjustment==7 && value==255 {
            // Correct-GUID wire endpoint profiles play as ordinary images.
            // JS bypasses the bridge for these; retain identity defensively.
            return (0..<256).map{UInt8($0)}
        }
        let starts=[0,511,1022,1223,1424,1625,1826,2081]
        let minimums=[-255,-255,-100,-100,-100,-100,1,0]
        let counts=[511,511,201,201,201,201,255,255]
        guard adjustment>=0,adjustment<starts.count,
              value>=minimums[adjustment],value<minimums[adjustment]+counts[adjustment] else {throw invalid("invalid curve table index")}
        if curveData==nil {
            let expectedSize=598_032
            guard let location=rendererURL()?.deletingLastPathComponent().appendingPathComponent("color-curves.bin"),
                  let attributes=try? FileManager.default.attributesOfItem(atPath:location.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue==expectedSize,
                  let handle=try? FileHandle(forReadingFrom:location) else {throw invalid("curve resource unavailable")}
            defer {try? handle.close()}
            var bytes=Data()
            while bytes.count<=expectedSize {
                let fragment:Data
                do {fragment=try handle.read(upToCount:min(16_384,expectedSize+1-bytes.count)) ?? Data()}
                catch {throw invalid("cannot read curve resource")}
                if fragment.isEmpty {break}
                bytes.append(fragment)
            }
            guard bytes.count==expectedSize,bytes.prefix(8)==Data("TGCCLUT1".utf8) else {throw invalid("invalid curve resource size or header")}
            func word(_ offset:Int)->Int {
                Int(bytes[offset]) | Int(bytes[offset+1])<<8 | Int(bytes[offset+2])<<16 | Int(bytes[offset+3])<<24
            }
            let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
            guard word(8)==2336,word(12)==256,
                  digest=="440a11991aed54e095ea4867c6a83791b4eaca7a4be7be9db51610c087c05628" else {throw invalid("unverified curve resource")}
            curveData=bytes
        }
        let offset=16+(starts[adjustment]+value-minimums[adjustment])*256
        return Array(curveData![offset..<offset+256])
    }
    /// All captured Windows balance tables match this rational, half-up
    /// channel multiplier, including both parameter endpoints. Alpha is inert.
    private func balanceTable(_ amount:Int)->[UInt8] {
        (0..<256).map {UInt8(min(255,($0*(100+amount)+50)/100))}
    }
    /// Captured Levels auxiliary tables and full direct RGBA outputs agree
    /// exactly on the independently recorded endpoint/midpoint parameter grid.
    /// Inverted thresholds reverse the curve after gamma, rather than applying
    /// gamma to an already inverted input. Equal interior thresholds retain a
    /// one-byte ramp; the all-zero thresholds produce the measured white table.
    private func levelsTable(_ highlight:Int,_ midtone:Int,_ shadow:Int)->[UInt8] {
        if highlight==0 && shadow==0 {return [UInt8](repeating:255,count:256)}
        let high=Double(highlight)*255/100,low=Double(shadow)*255/100
        let gamma=pow(10,-Double(midtone)/100)
        return (0..<256).map {input in
            let value:Double
            if high<low {
                let normalized=max(0,min(1,(Double(input)-high)/(low-high)))
                value=1-pow(normalized,gamma)
            } else {
                let normalized=max(0,min(1,(Double(input)-low)/max(1,high-low)))
                value=pow(normalized,gamma)
            }
            return UInt8(max(0,min(255,(value*255).rounded())))
        }
    }
    /// Windows uses this integer HSL conversion, not a floating-point HSL
    /// filter. In particular red's negative hue wraps by 253, blue wins the
    /// blue/green maximum tie, and inverse hue intervals have asymmetric ends.
    /// These details reproduce the full independently captured color cube.
    private func hslTransform(_ hue:Int,_ saturation:Int,_ lightness:Int)->(UInt8,UInt8,UInt8)->(UInt8,UInt8,UInt8) {
        let saturationTable=(0..<256).map {min(255,($0*(100+saturation)+50)/100)}
        let lightnessTable=(0..<256).map {min(255,max(0,$0*100+255*lightness+50)/100)}
        let hueShift=((hue<0 ? hue+360:hue)*255+180)/360
        return {red,green,blue in
            let r=Int(red),g=Int(green),b=Int(blue)
            let high=max(r,max(g,b)),low=min(r,min(g,b)),delta=high-low,sum=high+low
            var h=0,s=0
            if delta != 0 {
                s=delta*255/(sum<=255 ? sum:510-sum)
                if high==r {h=(g-b)*43/delta;if h<0 {h+=253}}
                else if high==b {h=(170*delta+(r-g)*43)/delta}
                else {h=(86*delta+(b-r)*43)/delta}
            }
            let l=lightnessTable[sum/2]
            s=saturationTable[s];h+=hueShift;if h>255 {h-=255}
            if s==0 {return (UInt8(l),UInt8(l),UInt8(l))}
            let q=l<128 ? l*(255+s)/255:l+s-l*s/255
            let p=2*l-q
            func channel(_ input:Int)->UInt8 {
                var t=input;if t<0 {t+=255};if t>255 {t-=255}
                let value:Int
                if t<43 {value=p+(q-p)*t/43}
                else if t<=128 {value=q}
                else if t<170 {value=p+(q-p)*(170-t)/43}
                else {value=p}
                return UInt8(value)
            }
            return (channel(h+85),channel(h),channel(h-85))
        }
    }
    /// Native Windows' RGB lookup tables agree with this normalized Float32
    /// model within one byte in the recorded parameter grid. Preserve the
    /// operation order and nearest-even rounding; alpha is independent.
    private func brightnessTable(_ brightness:Int,_ contrast:Int)->[UInt8] {
        if brightness == -255 {return [UInt8](repeating:0,count:256)}
        if brightness == 255 {return [UInt8](repeating:255,count:256)}
        if contrast == 100 {
            return (0..<256).map { input in
                let threshold=2*input+brightness
                return threshold<255 ? 0:threshold>255 ? 255:128
            }
        }
        let slope:Float=contrast>0 ? 100/Float(100-contrast):Float(100+contrast)/100
        let normalizedBrightness=Float(brightness)/255
        let midpoint=(1-slope)/2,brightnessScale=(slope+1)/2
        let offset=midpoint+normalizedBrightness*brightnessScale
        return (0..<256).map { input in
            let scaled=(Float(input)/255)*slope
            let shifted=scaled+offset
            let pixel=shifted*255
            return UInt8(max(0,min(255,pixel.rounded(.toNearestOrEven))))
        }
    }
    /// Functional Tint profile with an explicitly measured precision limit.
    /// This general luma-preserving hue blend differs from native Windows by
    /// at most three associated-channel levels in the 35 captured profiles;
    /// it is not a claim to reproduce Windows' undocumented Tint quantization.
    /// Alpha remains independent. No fitted coefficients or sampled-case LUTs
    /// participate in this approximation; exact Tint precision remains open.
    private func tintTransform(_ hue:Int,_ amount:Int)->(UInt8,UInt8,UInt8)->(UInt8,UInt8,UInt8) {
        let signedPosition=hue>=0 ? (hue*255+180)/360:(hue*255)/360
        let position=signedPosition<0 ? signedPosition+256:signedPosition
        let scale=Double(amount)/100
        return {red,green,blue in
            let r=Int(red),g=Int(green),b=Int(blue)
            let upper=max(0,2*(max(r,max(g,b))/2)-1)
            func component(_ input:Int)->Int {
                var t=input;if t<0 {t+=255};if t>255 {t-=255}
                if t<43 {return upper*t/43}
                if t<=128 {return upper}
                if t<170 {return upper*(170-t)/43}
                return 0
            }
            let targetR=component(position+85),targetG=component(position),targetB=component(position-85)
            let sourceY=Double(54*r+183*g+19*b)/256
            let targetY=Double(54*targetR+183*targetG+19*targetB)/256
            func channel(_ original:Int,_ colored:Int)->UInt8 {
                let value=Double(original)+scale*(Double(colored-original)+sourceY-targetY)
                return UInt8(max(0,min(255,floor(value+0.5))))
            }
            return (channel(r,targetR),channel(g,targetG),channel(b,targetB))
        }
    }
    private func windowsUnassociate(_ associated:Int,_ alpha:Int)->UInt8 {
        UInt8(alpha==0 ? 0:min(255,(associated*((255<<16)/alpha))>>16))
    }
    private func windowsAssociation(_ channel:UInt8,_ alpha:Int)->UInt8 {
        windowsUnassociate((Int(channel)*alpha+127)/255,alpha)
    }
    /// Metafile DrawImage effects receive GDI+'s premultiplied source conversion,
    /// unlike Bitmap.ApplyEffect on its original straight-channel storage. Make
    /// that round-trip explicit before a lookup can amplify low-alpha rounding.
    /// The native reciprocal conversion is fixed-point: truncating 255/alpha
    /// before multiplication matters for nonlinear effects at low alpha. This
    /// also exactly reproduces the earlier matrix/LUT captured draw bands.
    /// Other ImageIO layouts use bounded native RGBA conversion without scaling.
    private func straightPixels(_ image:CGImage,normalizeStraight:Bool=true)throws->(bytes:Data,space:CGColorSpace) {
        let width=image.width,height=image.height
        var result=Data(count:width*height*4)
        let alpha=image.alphaInfo
        let model=image.colorSpace?.model
        let channels=model == .rgb ? 3:0
        let hasAlpha=[CGImageAlphaInfo.first,.last,.premultipliedFirst,.premultipliedLast].contains(alpha)
        let hasSlot=hasAlpha || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let step=channels+(hasSlot ? 1:0)
        if channels>0,image.bitsPerComponent==8,image.bitsPerPixel==step*8,
           image.bytesPerRow>=width*step,image.bytesPerRow<=inputLimit/height,
           let stored=image.dataProvider?.data,CFDataGetLength(stored)>=image.bytesPerRow*height {
            let bytes=CFDataGetBytePtr(stored)!
            let first=[CGImageAlphaInfo.first,.premultipliedFirst,.noneSkipFirst].contains(alpha)
            let premultiplied=alpha == .premultipliedFirst || alpha == .premultipliedLast
            let order=image.bitmapInfo.intersection(.byteOrderMask)
            let reversed=step==4 && order == .byteOrder32Little || step==2 && order == .byteOrder16Little
            for y in 0..<height {for x in 0..<width {
                let input=y*image.bytesPerRow+x*step,output=(y*width+x)*4
                func sample(_ channel:Int)->Int {Int(bytes[input+(reversed ? step-1-channel:channel)])}
                let a=hasAlpha ? sample(first ? 0:step-1):255
                for channel in 0..<3 {
                    let value=sample((first && hasSlot ? 1:0)+(channels==1 ? 0:channel))
                    let associated=premultiplied ? value:(value*a+127)/255
                    result[output+channel] = !normalizeStraight && !premultiplied ? UInt8(value):windowsUnassociate(associated,a)
                }
                result[output+3]=UInt8(a)
            }}
            return (result,image.colorSpace!)
        }
        guard let outputSpace=CGColorSpace(name:CGColorSpace.sRGB) else {throw invalid("cannot prepare output color space")}
        let prepared=result.withUnsafeMutableBytes { bytes->Bool in
            guard let canvas=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                    space:outputSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
            canvas.setBlendMode(.copy);canvas.interpolationQuality = .none
            canvas.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard prepared else {throw invalid("cannot decode source pixels")}
        for offset in stride(from:0,to:result.count,by:4) {
            let a=Int(result[offset+3])
            for channel in 0..<3 {result[offset+channel]=windowsUnassociate(Int(result[offset+channel]),a)}
        }
        return (result,outputSpace)
    }
    func apply(_ href:String,effect:JSValue)throws->String {
        try transform(href,prepared:prepare(parse(effect)),outputAssociations:2)
    }
    /// Internal bitmap-loading operation, never a serialized effect kind. A
    /// plain draw has two measured association boundaries in total. An ignored
    /// serialized block selected by E additionally enters source preparation.
    func prepareOrdinary(_ href:String,effectPipeline:Bool)throws->String {
        try transform(href,prepared:.ordinary,outputAssociations:effectPipeline ? 2:1)
    }
    private func decode(_ href:String,normalizeStraight:Bool=true)throws->(pixels:Data,width:Int,height:Int,space:CGColorSpace) {
        let prefix="data:image/png;base64,"
        guard href.hasPrefix(prefix),href.utf8.count<=outputLimit,
              let encoded=Data(base64Encoded:String(href.dropFirst(prefix.count))),encoded.count<=inputLimit,
              encoded.starts(with:[137,80,78,71,13,10,26,10]),
              let source=CGImageSourceCreateWithData(encoded as CFData,nil),CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=32768,height<=32768,width<=16_777_216/height else {throw invalid("invalid source or effect")}
        let pixels=width*height
        guard calls<4096,pixels<=67_108_864-pixelsProcessed else {throw invalid("aggregate pixel work budget exceeded")}
        calls+=1;pixelsProcessed+=pixels
        // Use the same lazy source-image policy as classic compressed images.
        // Effect source normalization is explicit in straightPixels and does
        // not rely on ImageIO selecting a particular alpha-storage layout.
        guard let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:false] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,image.width==width,image.height==height else {throw invalid("incomplete source PNG")}
        let decoded=try straightPixels(image,normalizeStraight:normalizeStraight)
        return (decoded.bytes,width,height,decoded.space)
    }
    func applySpatial(_ href:String,effect:JSValue,sourceRect:JSValue)throws->NSDictionary {
        guard case .spatial(let requested)=try parse(effect) else {throw invalid("expected spatial effect")}
        let decoded=try decode(href)
        let range = -Double(Float.greatestFiniteMagnitude)...Double(Float.greatestFiniteMagnitude)
        let x=try real(sourceRect,"x",range:range),y=try real(sourceRect,"y",range:range)
        let w=try real(sourceRect,"w",range:0...Double(Float.greatestFiniteMagnitude))
        let h=try real(sourceRect,"h",range:0...Double(Float.greatestFiniteMagnitude))
        guard w>0,h>0 else {throw invalid("invalid spatial source rectangle")}
        let requestedLeft=floor(x),requestedTop=floor(y)
        let requestedRight=ceil(x+w)+1,requestedBottom=ceil(y+h)+1
        let contained=requestedLeft>=0 && requestedTop>=0 && requestedRight<=Double(decoded.width) && requestedBottom<=Double(decoded.height)
        // Clamp while values are floating point, before conversion to Int. A
        // recorded source rectangle may extend beyond its bitmap by any finite
        // amount; it may not allocate an image of that untrusted extent.
        let left=Int(max(0,min(Double(decoded.width),requestedLeft)))
        let top=Int(max(0,min(Double(decoded.height),requestedTop)))
        // DrawImage's effect source region includes the rounded far endpoint.
        // The extra source sample affects the convolution before the original
        // floating rectangle clips the painted result. A minimal covering crop
        // incorrectly mirrors that last sample back into the visible edge.
        let right=Int(max(0,min(Double(decoded.width),requestedRight)))
        let bottom=Int(max(0,min(Double(decoded.height),requestedBottom)))
        if right<=left || bottom<=top {
            // Native FILE playback preserves prior paint when even the extra
            // working sample misses the bitmap. A transparent dummy would
            // instead erase the destination under SourceCopy. Exact-touch ROIs
            // with a nonempty inclusive working sample still run the effect.
            return ["skipsDrawing":true]
        }
        let padding:Int
        if case .blur(let radius,let expandEdge)=requested,expandEdge,!contained {padding=Int(ceil(radius))}
        else {padding=0}
        // Noncontained expanding Blur reads the original bitmap around the
        // working ROI. Build that bounded full-resolution canvas before its
        // axis passes; only coordinates outside the bitmap are transparent.
        // Strictly contained regions keep their existing cropped edge policy.
        let inputLeft=left-padding,inputTop=top-padding
        let width=right-left+2*padding,height=bottom-top+2*padding
        guard width>0,height>0,width<=32768,height<=32768,width<=16_777_216/height else {
            throw invalid("expanded spatial source exceeds pixel limit")
        }
        // Charge the private input plane and its copy work before allocation.
        try spatialBudget.reserve(outputPixels:width*height,work:width*height*4)
        var cropped=Data(count:width*height*4)
        let copyLeft=max(0,inputLeft),copyTop=max(0,inputTop)
        let copyRight=min(decoded.width,inputLeft+width),copyBottom=min(decoded.height,inputTop+height)
        if copyRight>copyLeft,copyBottom>copyTop {
            let rowBytes=(copyRight-copyLeft)*4
            for row in copyTop..<copyBottom {
                let source=(row*decoded.width+copyLeft)*4
                let destination=((row-inputTop)*width+copyLeft-inputLeft)*4
                cropped.replaceSubrange(destination..<destination+rowBytes,with:decoded.pixels[source..<source+rowBytes])
            }
        }
        let spatial:SpatialImageEffect
        if case .redEyeCorrection(let areas)=requested {
            spatial = .redEyeCorrection(areas:areas.map {SpatialImageEffectRect(left:$0.left-left,top:$0.top-top,right:$0.right-left,bottom:$0.bottom-top)})
        } else {spatial=requested}
        let result:SpatialImageEffectResult
        // The noncontained Blur canvas is already expanded and positioned.
        // Filter it in place so its dimensions also determine the native small
        // kernel's leading vertical rows and large-kernel block alignment.
        do {result=try SpatialImageEffects.apply(spatial,toStraightRGBA:cropped,width:width,height:height,expandOutput:padding==0 && !contained,budget:&spatialBudget)}
        catch is RedEyeImageEffectNoPaint {
            // Native file playback rejects the complete draw, including mixed
            // valid/outside area lists. Preserve the destination; transparent
            // SourceCopy pixels would incorrectly erase existing paint.
            return ["skipsDrawing":true]
        }
        catch {throw invalid(error.localizedDescription)}
        guard result.width>0,result.height>0,result.width<=32768,result.height<=32768,
              result.width<=16_777_216/result.height,result.pixels.count==result.width*result.height*4,
              (-512...512).contains(result.originX),(-512...512).contains(result.originY) else {throw invalid("invalid spatial image output geometry")}
        // Spatial paint is sampled before output association. Retaining raw
        // effect bytes here avoids moving two conversion boundaries across an
        // affine bilinear filter, which changes translucent edge colors.
        return ["href":try encode(result.pixels,width:result.width,height:result.height,space:decoded.space),
                "width":result.width,"height":result.height,"originX":result.originX+inputLeft,"originY":result.originY+inputTop]
    }
    func sampleSpatial(_ href:String,geometry:JSValue)throws->NSDictionary {
        guard let picturePlan else {throw invalid("missing root Picture plan")}
        let decoded=try decode(href,normalizeStraight:false)
        let matrix=try numbers(geometry,"matrix",count:6),source=try numbers(geometry,"source",count:4)
        let originX=try integer(geometry,"originX",range:-512...33280),originY=try integer(geometry,"originY",range:-512...33280)
        let logicalWidth=try integer(geometry,"logicalWidth",range:1...32768),logicalHeight=try integer(geometry,"logicalHeight",range:1...32768)
        let canvasWidth=try integer(geometry,"canvasWidth",range:1...32768),canvasHeight=try integer(geometry,"canvasHeight",range:1...32768)
        let wrap=try integer(geometry,"wrap",range:0...4),clamp=try real(geometry,"clamp",range:0...Double(UInt32.max))
        guard clamp.rounded()==clamp else {throw invalid("invalid spatial sample clamp")}
        guard let output=try SpatialImageSampling.affine(decoded.pixels,width:decoded.width,height:decoded.height,
            originX:originX,originY:originY,logicalWidth:logicalWidth,logicalHeight:logicalHeight,matrix:matrix,
            source:.init(x:source[0],y:source[1],width:source[2],height:source[3]),canvasWidth:canvasWidth,canvasHeight:canvasHeight,
            wrap:wrap,clamp:UInt32(clamp),associateOutput:!picturePlan.needed,budget:&spatialBudget) else {return ["skipsDrawing":true]}
        return ["href":try encode(output.pixels,width:output.width,height:output.height,space:decoded.space),
                "coverage":try encode(output.coverage,width:output.width,height:output.height,space:decoded.space),
                "width":output.width,"height":output.height,"originX":output.x,"originY":output.y]
    }
    func pictureNeeded(width:Int,height:Int)throws->Bool {
        if let picturePlan {
            guard picturePlan.width==width,picturePlan.height==height else {throw invalid("root Picture plan changed")}
            return picturePlan.needed
        }
        let needed=try SpatialImageSampling.pictureNeeded(width:width,height:height,budget:&spatialBudget)
        picturePlan=(width,height,needed);return needed
    }
    func samplePicture(_ pixels:Data,width:Int,height:Int)throws->String {
        let output=try SpatialImageSampling.picture(pixels,width:width,height:height,budget:&spatialBudget)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB) else {throw invalid("cannot prepare Picture color space")}
        return try encode(output,width:width,height:height,space:space)
    }
    private func transform(_ href:String,prepared:PreparedEffect,outputAssociations:Int)throws->String {
        guard let picturePlan else {throw invalid("missing root Picture plan")}
        // A nonidentity final document consumer supplies the final truncating
        // boundary itself. Keep the source association in decode(), but avoid
        // baking that output boundary a second time into ordinary/pointwise
        // pixels, including those mixed with spatial paints or child scenes.
        let preparedAssociations=max(0,outputAssociations-(picturePlan.needed ? 1:0))
        let decoded=try decode(href)
        let width=decoded.width,height=decoded.height
        var output=decoded.pixels
        try output.withUnsafeMutableBytes { storage in
            let bytes=storage.bindMemory(to:UInt8.self)
            for offset in stride(from:0,to:bytes.count,by:4) {
                switch prepared {
                case .ordinary:break
                case .matrix(let matrix):
                    let r=Double(bytes[offset])/255,g=Double(bytes[offset+1])/255,
                        b=Double(bytes[offset+2])/255,a=Double(bytes[offset+3])/255
                    for channel in 0..<4 {
                        var value=r*matrix[channel]
                        value+=g*matrix[5+channel];value+=b*matrix[10+channel]
                        value+=a*matrix[15+channel];value+=matrix[20+channel]
                        guard value.isFinite else {throw invalid("matrix result overflow")}
                        bytes[offset+channel]=UInt8(max(0,min(255,(value*255).rounded())))
                    }
                case .lookup(let tables):
                    for channel in 0..<4 {bytes[offset+channel]=tables[channel][Int(bytes[offset+channel])]}
                case .rgb(let transform):
                    let (r,g,b)=transform(bytes[offset],bytes[offset+1],bytes[offset+2])
                    bytes[offset]=r;bytes[offset+1]=g;bytes[offset+2]=b
                }
                // Active/selected-fallback blocks require both the intrinsic
                // Bitmap raster and final Picture draw associations. Ordinary
                // playback uses its source association plus one final boundary.
                // Apple SVG/PNG associations cannot supply GDI+'s truncating
                // fixed-point reciprocal, so model those boundaries explicitly.
                // Use the effect's resulting alpha (matrix/LUT may change it).
                let alpha=Int(bytes[offset+3])
                for channel in 0..<3 {
                    var value=bytes[offset+channel]
                    for _ in 0..<preparedAssociations {value=windowsAssociation(value,alpha)}
                    bytes[offset+channel]=value
                }
            }
        }
        return try encode(output,width:width,height:height,space:decoded.space)
    }
    private func encode(_ output:Data,width:Int,height:Int,space:CGColorSpace)throws->String {
        let prefix="data:image/png;base64,"
        guard let provider=CGDataProvider(data:output as CFData),
              let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw invalid("cannot prepare result PNG")}
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else {throw invalid("cannot encode result PNG")}
        CGImageDestinationAddImage(destination,result,nil)
        // The JS shared budget counts the final base64 href, not PNG bytes.
        let maximumPNG=(inputLimit-prefix.utf8.count)/4*3
        guard CGImageDestinationFinalize(destination),bytes.length<=maximumPNG else {throw invalid("result PNG output exceeds limit")}
        return prefix+(bytes as Data).base64EncodedString()
    }
}
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
private func data(_ value: JSValue) -> Data? {
    let context = value.context.jsGlobalContextRef
    let kind = JSValueGetTypedArrayType(context, value.jsValueRef, nil)
    if kind == kJSTypedArrayTypeUint8Array || kind == kJSTypedArrayTypeUint8ClampedArray,
       let object = JSValueToObject(context, value.jsValueRef, nil) {
        let count = JSObjectGetTypedArrayByteLength(context, object, nil)
        guard count <= inputLimit else { return nil }
        if count == 0 { return Data() }
        let offset = JSObjectGetTypedArrayByteOffset(context, object, nil)
        guard let buffer = JSObjectGetTypedArrayBuffer(context, object, nil),
              let pointer = JSObjectGetArrayBufferBytesPtr(context, buffer, nil) else { return nil }
        return Data(bytes: pointer.advanced(by: offset), count: count)
    }
    guard let length = value.forProperty("length"), !length.isUndefined else { return nil }
    let count = length.toDouble()
    guard count.isFinite, count >= 0, count <= Double(inputLimit), count.rounded() == count else { return nil }
    var result = Data(count: Int(count))
    for index in 0..<Int(count) { result[index] = UInt8(truncatingIfNeeded: value.atIndex(index).toUInt32()) }
    return result
}
private func rendererURL() -> URL? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let candidates = [executable.deletingLastPathComponent().appendingPathComponent("renderer.js"),
        executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/TurtleGitRuntimes/Metafile/renderer.js")]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}
private final class SVGGuard: NSObject, XMLParserDelegate {
    var valid = true
    private let rasterSize:CGSize?
    private var depth=0,elementsSeen=0,embeddedPixels=0
    init(rasterSize:CGSize?=nil){self.rasterSize=rasterSize;super.init()}
    private let elements: Set<String> = ["svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "clipPath", "image", "pattern", "linearGradient", "radialGradient", "stop", "mask", "title", "desc"]
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if let rasterSize {
            elementsSeen += 1
            if depth>=128 || elementsSeen>262144 {valid=false}
            if depth==0 {
                func extent(_ key:String)->Double? {
                    guard var value=attributes[key] else{return nil}
                    if value.hasSuffix("px"){value=String(value.dropLast(2))}
                    return Double(value)
                }
                if element != "svg" || extent("width") != Double(rasterSize.width) || extent("height") != Double(rasterSize.height){valid=false}
            }
        }
        depth += 1
        if !elements.contains(element) || namespaceURI != "http://www.w3.org/2000/svg" { valid = false }
        for (name, value) in attributes {
            let key = name.lowercased(), lowered = value.lowercased()
            if key.hasPrefix("on") || lowered.contains("@import") { valid = false }
            if rasterSize != nil,(key=="base" || key.hasSuffix(":base")){valid=false}
            if key == "href" || key.hasSuffix(":href") {
                if !value.hasPrefix("#") && !value.hasPrefix("data:image/png;base64,") { valid = false }
                if rasterSize != nil,value.hasPrefix("data:image/png;base64,") {
                    guard let bytes=Data(base64Encoded:String(value.dropFirst(22))),bytes.count<=16*1024*1024,bytes.starts(with:[137,80,78,71,13,10,26,10]),
                          let source=CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,
                          let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                          let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
                          width>0,height>0,width<=32768,height<=32768,width<=16777216/height,
                          width*height<=16777216-embeddedPixels else{valid=false;parser.abortParsing();return}
                    embeddedPixels += width*height
                }
            }
            if lowered.contains("url(") {
                let pattern = #"url\(\s*["']?#[a-zA-Z0-9_.:-]+["']?\s*\)"#
                let remainder = lowered.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if remainder.contains("url(") { valid = false }
            }
        }
        if !valid { parser.abortParsing() }
    }
    func parser(_ parser:XMLParser,didEndElement element:String,namespaceURI:String?,qualifiedName:String?){depth -= 1}
    func parser(_ parser:XMLParser,foundProcessingInstructionWithTarget target:String,data:String?){if rasterSize != nil{valid=false;parser.abortParsing()}}
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { valid = false; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { valid = false; parser.abortParsing() }
}

/// GDI's bytewise Boolean operations cannot be represented by SVG blend modes.
/// Only renderer-generated, independently guarded SVG operands enter AppKit.
private final class NativeRasterComposite {
    private var renderedPixels=0,compositePixels=0,markupBytes=0,calls=0,sampledPixels=0
    private struct Region { let x:Int,y:Int,width:Int,height:Int;var pixels:Int{width*height} }
    /// Original, uncut transfer geometry. The rectangular lattice is only a
    /// bounding domain for a non-axis-aligned parallelogram; the inverse keeps
    /// its actual normalized shape and the signed source/destination mapping.
    /// Neither the clipped work ROI nor the snapshot dimensions define its edges.
    private struct SelfCopySamplingDomain {
        let destination:[Double],inverseDestination:[Double],source:[Double]
        let minX:Double,maxX:Double,minY:Double,maxY:Double
        let sourceMinX:Double,sourceMaxX:Double,sourceMinY:Double,sourceMaxY:Double
        let boundingColumns:Range<Int>,boundingRows:Range<Int>
        let axisAlignedDestination:Bool,axisAlignedSource:Bool
    }
    private struct Checkpoint {let token:String,width:Int,height:Int,pixels:Data}
    // One native-produced canvas per conversion, never an SVG/state cache.
    private var checkpoint:Checkpoint?
    private var checkpointScopes:[Checkpoint?]=[]
    func embeddedScope(_ entering:Bool)throws {
        if entering {
            let retained=checkpointScopes.compactMap{$0}.reduce(0){$0+$1.pixels.count}+(checkpoint?.pixels.count ?? 0)
            guard checkpointScopes.count<8,retained<=128*1024*1024 else{throw invalid("embedded checkpoint scope budget exceeded")}
            checkpointScopes.append(checkpoint);checkpoint=nil
        } else {
            guard !checkpointScopes.isEmpty else{throw invalid("unmatched embedded checkpoint scope")}
            checkpoint=checkpointScopes.removeLast()
        }
    }
    /// Only a guarded, renderer-generated transparent child scene enters this
    /// bridge. Existing conversion-wide work/markup counters remain cumulative.
    func embeddedImage(_ value:JSValue,_ widthValue:Double,_ heightValue:Double)throws->String {
        guard widthValue.isFinite,heightValue.isFinite,widthValue.rounded()==widthValue,heightValue.rounded()==heightValue,
              widthValue>=1,heightValue>=1,widthValue<=32768,heightValue<=32768,widthValue*heightValue<=16777216 else{throw invalid("invalid embedded raster dimensions")}
        let width=Int(widthValue),height=Int(heightValue),pixels=width*height
        guard calls<4096,pixels<=67108864-renderedPixels else{throw invalid("embedded image raster work budget exceeded")}
        calls+=1;renderedPixels+=pixels
        guard let source=try svg(value,size:CGSize(width:width,height:height),required:true) else{throw invalid("missing embedded image scene")}
        return try encode(render(source,width:width,height:height),width:width,height:height)
    }
    func picturePixels(_ value:JSValue,width:Int,height:Int)throws->Data {
        guard width>0,height>0,width<=32768,height<=32768,width<=16_777_216/height else {throw invalid("invalid Picture raster dimensions")}
        let pixels=width*height
        guard calls<4096,pixels<=67_108_864-renderedPixels else {throw invalid("Picture raster work budget exceeded")}
        calls+=1;renderedPixels+=pixels
        guard let source=try svg(value,size:CGSize(width:width,height:height),required:true) else {throw invalid("missing Picture scene")}
        return try render(source,width:width,height:height)
    }
    private func region(_ request:JSValue,width:Int,height:Int)throws->Region {
        if request.isUndefined || request.isNull{return Region(x:0,y:0,width:width,height:height)}
        guard request.isObject,!request.isArray else{throw invalid("invalid raster ROI request")}
        func integer(_ name:String,_ maximum:Int)throws->Int {
            guard let value=request.forProperty(name),value.isNumber else{throw invalid("missing raster ROI "+name)}
            let n=value.toDouble()
            guard n.isFinite,n.rounded()==n,n>=0,n<=Double(maximum) else{throw invalid("invalid raster ROI "+name)}
            return Int(n)
        }
        let x=try integer("x",width),y=try integer("y",height)
        let w=try integer("width",width-x),h=try integer("height",height-y)
        guard let receipt=request.forProperty("checkpoint"),receipt.isNull || receipt.isString else{throw invalid("invalid raster checkpoint receipt")}
        return Region(x:x,y:y,width:w,height:h)
    }
    private func destinationPixels(_ svg:Data,request:JSValue,width:Int,height:Int)throws->Data {
        if !request.isUndefined && !request.isNull,let receipt=request.forProperty("checkpoint"),!receipt.isNull {
            guard receipt.isString,let current=checkpoint,current.token==receipt.toString(),current.width==width,current.height==height else{throw invalid("stale raster checkpoint receipt")}
            return current.pixels
        }
        return try render(svg,width:width,height:height)
    }
    private func finish(_ output:Data,request:JSValue,width:Int,height:Int)throws->NSObject {
        let href=try encode(output,width:width,height:height)
        let token=UUID().uuidString
        checkpoint=Checkpoint(token:token,width:width,height:height,pixels:output)
        if request.isUndefined || request.isNull{return href as NSString}
        return ["href":href,"checkpoint":token] as NSDictionary
    }
    private func cropped(_ bytes:Data,region:Region,width:Int)->Data {
        var result=Data(count:region.pixels*4)
        result.withUnsafeMutableBytes {(dst:UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes {(src:UnsafeRawBufferPointer) in
                for row in 0..<region.height where region.width>0 {
                    dst.baseAddress!.advanced(by:row*region.width*4).copyMemory(from:src.baseAddress!.advanced(by:((region.y+row)*width+region.x)*4),byteCount:region.width*4)
                }
            }
        }
        return result
    }
    private func install(_ tile:Data,in output:inout Data,region:Region,width:Int) {
        output.withUnsafeMutableBytes {(dst:UnsafeMutableRawBufferPointer) in
            tile.withUnsafeBytes {(src:UnsafeRawBufferPointer) in
                for row in 0..<region.height where region.width>0 {
                    dst.baseAddress!.advanced(by:((region.y+row)*width+region.x)*4).copyMemory(from:src.baseAddress!.advanced(by:row*region.width*4),byteCount:region.width*4)
                }
            }
        }
    }
    private func invalid(_ message:String)->ConversionError{.invalid("Metafile raster operation: "+message)}
    private func svg(_ value:JSValue,size:CGSize,required:Bool)throws->Data? {
        if value.isNull || value.isUndefined || (value.isString && value.toString()=="") {
            if required{throw invalid("missing required SVG operand")};return nil
        }
        guard value.isString,let text=value.toString(),text.utf8.count<=16*1024*1024,
              text.range(of:"<!DOCTYPE",options:.caseInsensitive)==nil,text.range(of:"<!ENTITY",options:.caseInsensitive)==nil else{throw invalid("invalid or oversized SVG operand")}
        let bytes=Data(text.utf8)
        guard bytes.count<=64*1024*1024-markupBytes else{throw invalid("aggregate SVG operand budget exceeded")}
        markupBytes += bytes.count
        let safety=SVGGuard(rasterSize:size),parser=XMLParser(data:bytes)
        parser.shouldProcessNamespaces=true;parser.shouldResolveExternalEntities=false;parser.delegate=safety
        guard parser.parse(),safety.valid else{throw invalid("SVG operand contains invalid geometry or external resources")}
        return bytes
    }
    private func render(_ svg:Data,width:Int,height:Int,region:Region?=nil)throws->Data {
        return try autoreleasepool {
        let area=region ?? Region(x:0,y:0,width:width,height:height)
        if area.pixels==0{return Data()}
        guard let image=NSImage(data:svg) else{throw invalid("native SVG decoding failed")}
        var bytes=Data(count:area.pixels*4)
        try bytes.withUnsafeMutableBytes { (buffer:UnsafeMutableRawBufferPointer) in
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:area.width,height:area.height,bitsPerComponent:8,bytesPerRow:area.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else{throw invalid("cannot allocate native RGBA canvas")}
            context.interpolationQuality = .none;context.setShouldAntialias(true)
            NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
            let graphics=NSGraphicsContext(cgContext:context,flipped:false);graphics.imageInterpolation = .none;NSGraphicsContext.current=graphics
            // SVG/global and RGBA rows run downward; this unflipped AppKit
            // destination runs upward. Position the original full-size draw
            // relative to the crop's bottom edge, not its top edge. No scaling
            // or reset of SVG coordinates, brush phase or pixel centers occurs.
            image.draw(in:NSRect(x:-area.x,y:area.y+area.height-height,width:width,height:height),from:.zero,operation:.copy,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.none])
            context.flush()
        }
        return bytes
        }
    }
    private func depends(_ rop:Int,_ shift:Int,_ mask:Int)->Bool{((rop ^ (rop >> shift)) & mask) != 0}
    @inline(__always) private func cofactor(_ code:Int,_ d:UInt8)->UInt8 {
        switch code {case 0:return 0;case 1:return ~d;case 2:return d;default:return 255}
    }
    @inline(__always) private func apply(_ rop:Int,_ p:UInt8,_ s:UInt8,_ d:UInt8)->UInt8 {
        let a=cofactor(rop & 3,d),b=cofactor((rop >> 2) & 3,d),c=cofactor((rop >> 4) & 3,d),e=cofactor((rop >> 6) & 3,d)
        return (~p & ((~s & a) | (s & b))) | (p & ((~s & c) | (s & e)))
    }
    /// Sample the immutable pre-paint destination as a WMF source DC. The
    /// existing native checkpoint supplies pixels, not rerendered vector shapes
    /// scaled to a new size. Out-of-surface source pixels exclude destination
    /// coverage; overlapping source/destination rectangles cannot feed back.
    /// Compatibility kernel for matrix-only or affine
    /// self transfers outside the independently measured domain-aware family.
    /// This profile is retained deliberately and is not claimed GDI-exact.
    private func legacyQualityAxis(center:Double,span:Double,limit:Int,box:Bool)throws->[(Int,Double)] {
        if span<=1.000000001 {return [(max(0,min(limit-1,Int(floor(center)))),1)]}
        let first=box ? floor(center-span*0.5+1e-9):ceil(center-0.5-3*span)
        let last=box ? floor(center+span*0.5+1e-9)-1:floor(center-0.5+3*span)
        let count=max(0,last-first+1)
        guard count.isFinite,count<=Double(67_108_864-sampledPixels) else {throw invalid("aggregate raster sampling budget exceeded")}
        sampledPixels+=Int(count)
        var weights=[Int:Double]()
        let period=2*limit-2
        if count>0 {for i in Int(first)...Int(last) {
            let t=(Double(i)+0.5-center)/span,pi=Double.pi*t
            let weight=box || abs(t)<1e-12 ? 1:abs(t)>=3 ? 0:sin(pi)*sin(pi/3)/(pi*pi/3)
            let index:Int
            if box {index=max(0,min(limit-1,i))}
            else if limit==1 {index=0}
            else {let reflected=((i%period)+period)%period;index=reflected<limit ? reflected:period-reflected}
            if weight != 0 {weights[index,default:0]+=weight}
        }}
        let total=weights.values.reduce(0,+)
        guard total.isFinite,abs(total)>=1e-12 else {throw invalid("invalid HALFTONE kernel")}
        return weights.keys.sorted().map{($0,weights[$0]!/total)}
    }
    private struct HalftoneDCKey:Hashable {let x:Int,y:Int}
    private struct HalftoneDCRGB {let r:Int64,g:Int64,b:Int64
        subscript(_ c:Int)->Int64 {c==0 ? r:c==1 ? g:b}
    }
    private struct HalftoneDCAxis {let destinationStart:Int,destinationCount:Int,sourceStart:Int,sourceCount:Int,reflectOutput:Bool
        var shrinks:Bool {sourceCount>destinationCount}
    }
    /// Independently derived from retained Windows WMF captures: cumulative
    /// 13-bit footprint shares, a byte horizontal intermediate only when both
    /// axes reduce, then unrounded reduction and destination-neighbour CROSS.
    /// Signed geometry follows the independently captured serialized-bitmap
    /// profile: reduce a positive canonical crop, then reflect finished output.
    /// Its reuse for source-DC snapshots retains the same mathematical profile;
    /// signed/out-of-surface self copies have not independently been captured.
    /// Legacy/affine callers retain the compatibility sampler below; no clipped
    /// ROI is ever invented as their source domain.
    private func halftoneDCSource(_ snapshot:Data,width:Int,height:Int,area:Region,domain:SelfCopySamplingDomain)throws->Data? {
        guard domain.axisAlignedDestination,domain.axisAlignedSource else{return nil}
        func edge(_ v:Double)throws->Int {
            let n=floor(v+0.5)
            guard n.isFinite,abs(n)<=10_000_000_000 else{throw invalid("HALFTONE device edge limit")}
            return Int(n)
        }
        func axis(_ d:Double,_ dn:Double,_ s:Double,_ sn:Double)throws->HalftoneDCAxis? {
            let a=try edge(d),b=try edge(d+dn),c=try edge(s),e=try edge(s+sn)
            // A transfer with an empty snapped source/destination extent
            // contributes no source coverage; it has no sampling lattice.
            guard b != a,e != c else{return nil}
            let count=abs(b-a),sourceCount=abs(e-c)
            guard count<=2_000_000_000,sourceCount<=2_000_000_000 else{throw invalid("HALFTONE device span limit")}
            // The bridge already converts negative WMF inclusive endpoints to
            // snapped half-open edges. Applying another +1 here shifts twice.
            return HalftoneDCAxis(destinationStart:min(a,b),destinationCount:count,sourceStart:min(c,e),sourceCount:sourceCount,reflectOutput:(b<a) != (e<c))
        }
        guard let ax=try axis(domain.destination[4],domain.destination[0],domain.source[4],domain.source[0]),
              let ay=try axis(domain.destination[5],domain.destination[3],domain.source[5],domain.source[3]) else{return Data(count:area.pixels*4)}
        let reducingAxes=(ax.shrinks ? 1:0)+(ay.shrinks ? 1:0),both=reducingAxes==2
        // Entirely-left footprint columns produce opaque black and are not
        // neighbours of the first supported column. Bound before multiplying:
        // a partially overlapping origin has magnitude < sourceCount <=2e9.
        let firstActiveColumn:Int
        if ax.sourceStart>=0 {firstActiveColumn=0}
        else if ax.sourceStart+ax.sourceCount<=0 {firstActiveColumn=ax.destinationCount}
        else {firstActiveColumn=Int(Int64(-ax.sourceStart)*Int64(ax.destinationCount)/Int64(ax.sourceCount))}
        // All numerators after the optional horizontal byte step have Q13
        // units. 255*8192 and the CROSS numerator fit comfortably in Int64.
        // Coordinate products are bounded by (2e9)^2 before any conversion.
        var xWeights=[Int:[(Int,Int64)]](),yWeights=[Int:[(Int,Int64)]]()
        var xTaps=0,yTaps=0
        var horizontal=[HalftoneDCKey:HalftoneDCRGB](),reduced=[HalftoneDCKey:HalftoneDCRGB]()
        let cacheEntries=32_768,axisTapLimit=262_144
        func work(_ count:Int)throws {
            guard count>=0,count<=67_108_864-sampledPixels else{throw invalid("aggregate raster sampling budget exceeded")}
            sampledPixels+=count
        }
        func weights(_ a:HalftoneDCAxis,_ index:Int,_ cache:inout[Int:[(Int,Int64)]],_ stored:inout Int)throws->[(Int,Int64)] {
            if let saved=cache[index]{return saved}
            let row:[(Int,Int64)]
            if !a.shrinks {
                try work(1)
                row=[(a.sourceStart+Int(Int64(index)*Int64(a.sourceCount)/Int64(a.destinationCount)),8192)]
            } else {
                let n=Int64(a.sourceCount),m=Int64(a.destinationCount),left=Int64(index)*n,right=Int64(index+1)*n
                let first=left/m,end=(right+m-1)/m
                try work(Int(end-first))
                var taps=[(Int,Int64)]();taps.reserveCapacity(Int(min(8192,end-first)))
                var previous:Int64=0
                for i in first..<end {
                    let covered=min((i+1)*m,right)-left
                    let cumulative=covered*8192/n,share=cumulative-previous
                    if share>0{taps.append((a.sourceStart+Int(i),share))}
                    previous=cumulative
                }
                guard previous==8192 else{throw invalid("invalid HALFTONE footprint shares")}
                row=taps
            }
            // Deterministic bounded caches; eviction may repeat computation,
            // which remains charged to the conversion-wide work counter.
            if cache.count>=4096 || stored>axisTapLimit-row.count{cache.removeAll(keepingCapacity:true);stored=0}
            cache[index]=row;stored+=row.count
            return row
        }
        var result=Data(count:area.pixels*4)
        try snapshot.withUnsafeBytes { (source:UnsafeRawBufferPointer) in
            func pixel(_ x:Int,_ y:Int)->HalftoneDCRGB {
                // Captured bitmap boundary profile, explicitly reused for
                // source DC: left clamps, right is black, vertical edges clamp.
                // Surface bounds are independent of the
                // original crop and of the clipped destination work region.
                if x>=width{return HalftoneDCRGB(r:0,g:0,b:0)}
                let p=(max(0,min(height-1,y))*width+max(0,min(width-1,x)))*4,alpha=Int64(source[p+3])
                return HalftoneDCRGB(r:min(255,Int64(source[p])+255-alpha),g:min(255,Int64(source[p+1])+255-alpha),b:min(255,Int64(source[p+2])+255-alpha))
            }
            func horizontalPixel(_ x:Int,_ sourceY:Int)throws->HalftoneDCRGB {
                let key=HalftoneDCKey(x:x,y:sourceY)
                if let saved=horizontal[key]{return saved}
                let taps=try weights(ax,x,&xWeights,&xTaps);try work(taps.count)
                var r:Int64=0,g:Int64=0,b:Int64=0
                for (sourceX,share) in taps {let p=pixel(sourceX,sourceY);r+=p.r*share;g+=p.g*share;b+=p.b*share}
                let value=HalftoneDCRGB(r:both ? (r+4096)/8192:r,g:both ? (g+4096)/8192:g,b:both ? (b+4096)/8192:b)
                if horizontal.count>=cacheEntries{horizontal.removeAll(keepingCapacity:true)}
                horizontal[key]=value;return value
            }
            func base(_ x:Int,_ y:Int)throws->HalftoneDCRGB {
                let key=HalftoneDCKey(x:x,y:y)
                if let saved=reduced[key]{return saved}
                let taps=try weights(ay,y,&yWeights,&yTaps);try work(taps.count)
                var r:Int64=0,g:Int64=0,b:Int64=0
                for (sourceY,share) in taps {
                    let p=try horizontalPixel(x,sourceY)
                    // With no horizontal byte step its result already has
                    // Q13 units; y is then a single nearest row of weight8192.
                    let weight=both ? share:share/8192
                    if ax.shrinks {r+=p.r*weight;g+=p.g*weight;b+=p.b*weight}
                    else {r+=p.r*share/8192;g+=p.g*share/8192;b+=p.b*share/8192}
                }
                let value=HalftoneDCRGB(r:r,g:g,b:b)
                if reduced.count>=cacheEntries{reduced.removeAll(keepingCapacity:true)}
                reduced[key]=value;return value
            }
            try result.withUnsafeMutableBytes { (target:UnsafeMutableRawBufferPointer) in
                for row in 0..<area.height {for column in 0..<area.width {
                    let physicalX=area.x+column-ax.destinationStart,physicalY=area.y+row-ay.destinationStart
                    guard physicalX>=0,physicalX<ax.destinationCount,physicalY>=0,physicalY<ay.destinationCount else{continue}
                    let x=ax.reflectOutput ? ax.destinationCount-1-physicalX:physicalX
                    let y=ay.reflectOutput ? ay.destinationCount-1-physicalY:physicalY
                    try work(1)
                    let o=(row*area.width+column)*4
                    if x<firstActiveColumn {target[o+3]=255;continue}
                    let center=try base(x,y)
                    var neighbours=[HalftoneDCRGB]()
                    if ax.shrinks {neighbours.append(try base(max(firstActiveColumn,x-1),y));neighbours.append(try base(min(ax.destinationCount-1,x+1),y))}
                    if ay.shrinks {neighbours.append(try base(x,max(0,y-1)));neighbours.append(try base(x,min(ay.destinationCount-1,y+1)))}
                    for channel in 0..<3 {
                        let numerator=reducingAxes==0 ? center[channel]:Int64(6*reducingAxes)*center[channel]-neighbours.reduce(Int64(0)){$0+$1[channel]}
                        let denominator:Int64=reducingAxes==0 ? 8192:Int64(8192*4*reducingAxes)
                        target[o+channel]=UInt8(max(0,min(255,numerator/denominator)))
                    }
                    target[o+3]=255
                }}
            }
        }
        return result
    }
    private func selfSource(_ snapshot:Data,width:Int,height:Int,area:Region,matrix:[Double],mode:Int,domain:SelfCopySamplingDomain?)throws->Data {
        if mode==4,let domain,let exact=try halftoneDCSource(snapshot,width:width,height:height,area:area,domain:domain){return exact}
        var result=Data(count:area.pixels*4)
        let halfX=(abs(matrix[0])+abs(matrix[2]))*0.5,halfY=(abs(matrix[1])+abs(matrix[3]))*0.5
        try snapshot.withUnsafeBytes { (source:UnsafeRawBufferPointer) in
            try result.withUnsafeMutableBytes { (target:UnsafeMutableRawBufferPointer) in
                for y in 0..<area.height {for x in 0..<area.width {
                    let dx=Double(area.x+x)+0.5,dy=Double(area.y+y)+0.5
                    let sx=matrix[0]*dx+matrix[2]*dy+matrix[4],sy=matrix[1]*dx+matrix[3]*dy+matrix[5]
                    if sx<0 || sy<0 || sx>=Double(width) || sy>=Double(height){continue}
                    let o=(y*area.width+x)*4
                    if mode==4 && (halfX>0.500000001 || halfY>0.500000001) {
                        let spanX=halfX*2,spanY=halfY*2
                        func integral(_ span:Double)->Bool {span<=1.000000001 || abs(span-span.rounded())<1e-9}
                        let box=integral(spanX) && integral(spanY)
                        let xs=try legacyQualityAxis(center:sx,span:spanX,limit:width,box:box),ys=try legacyQualityAxis(center:sy,span:spanY,limit:height,box:box)
                        let visits=xs.count*ys.count
                        guard visits<=67_108_864-sampledPixels else {throw invalid("aggregate raster sampling budget exceeded")};sampledPixels+=visits
                        var rgb=[Double](repeating:0,count:3)
                        for (yy,wy) in ys {for (xx,wx) in xs {
                            let p=(yy*width+xx)*4,alpha=Int(source[p+3])
                            for channel in 0..<3 {rgb[channel]+=Double(min(255,Int(source[p+channel])+255-alpha))*wx*wy}
                        }}
                        for channel in 0..<3 {target[o+channel]=UInt8(max(0,min(255,rgb[channel])).rounded())}
                    } else if (mode==1 || mode==2) && (halfX>0.500000001 || halfY>0.500000001) {
                        let left=halfX>0.500000001 ? max(0,Int(floor(sx-halfX+1e-9))):Int(sx),right=halfX>0.500000001 ? min(width-1,Int(floor(sx+halfX+1e-9))-1):Int(sx)
                        let top=halfY>0.500000001 ? max(0,Int(floor(sy-halfY+1e-9))):Int(sy),bottom=halfY>0.500000001 ? min(height-1,Int(floor(sy+halfY+1e-9))-1):Int(sy),visits=max(0,right-left+1)*max(0,bottom-top+1)
                        guard visits<=67_108_864-sampledPixels else {throw invalid("aggregate raster sampling budget exceeded")};sampledPixels+=visits
                        target[o]=mode==1 ? 255:0;target[o+1]=target[o];target[o+2]=target[o]
                        if visits>0 {for yy in top...bottom {for xx in left...right {
                            let p=(yy*width+xx)*4,alpha=Int(source[p+3])
                            for channel in 0..<3 {
                                let rgb=UInt8(min(255,Int(source[p+channel])+255-alpha))
                                target[o+channel]=mode==1 ? target[o+channel]&rgb:target[o+channel]|rgb
                            }
                        }}}
                    } else {
                        guard sampledPixels<67_108_864 else {throw invalid("aggregate raster sampling budget exceeded")};sampledPixels+=1
                        let p=(Int(sy)*width+Int(sx))*4,alpha=Int(source[p+3])
                        for channel in 0..<3 {target[o+channel]=UInt8(min(255,Int(source[p+channel])+255-alpha))}
                    }
                    target[o+3]=255
                }}
            }
        }
        return result
    }
    private func selfCopySamplingDomain(_ value:JSValue,matrix:[Double])throws->SelfCopySamplingDomain {
        guard value.isArray,let length=value.forProperty("length"),length.isNumber,length.toDouble()==6 else {throw invalid("invalid self-copy destination domain")}
        var destination=[Double]();destination.reserveCapacity(6)
        for index in 0..<6 {
            guard let component=value.atIndex(index),component.isNumber else {throw invalid("invalid self-copy destination value")}
            let number=component.toDouble()
            guard number.isFinite,abs(number)<=1_000_000_000 else {throw invalid("self-copy destination coordinate limit")}
            destination.append(number)
        }
        let a=destination[0],b=destination[1],c=destination[2],d=destination[3],tx=destination[4],ty=destination[5]
        let determinant=a*d-b*c
        guard determinant.isFinite,abs(determinant)>=1e-15 else {throw invalid("singular self-copy destination domain")}
        let inverse=[d/determinant,-b/determinant,-c/determinant,a/determinant,(c*ty-d*tx)/determinant,(b*tx-a*ty)/determinant]
        // Compose the accepted device-to-source matrix with the original
        // normalized destination. Preserve out-of-surface source coordinates;
        // existing source validity/coverage still decides whether they paint.
        let source=[matrix[0]*a+matrix[2]*b,matrix[1]*a+matrix[3]*b,
                    matrix[0]*c+matrix[2]*d,matrix[1]*c+matrix[3]*d,
                    matrix[0]*tx+matrix[2]*ty+matrix[4],matrix[1]*tx+matrix[3]*ty+matrix[5]]
        let xs=[tx,tx+a,tx+c,tx+a+c],ys=[ty,ty+b,ty+d,ty+b+d]
        let sourceXs=[source[4],source[4]+source[0],source[4]+source[2],source[4]+source[0]+source[2]]
        let sourceYs=[source[5],source[5]+source[1],source[5]+source[3],source[5]+source[1]+source[3]]
        guard inverse.allSatisfy(\.isFinite),source.allSatisfy(\.isFinite),xs.allSatisfy(\.isFinite),ys.allSatisfy(\.isFinite),sourceXs.allSatisfy(\.isFinite),sourceYs.allSatisfy(\.isFinite) else {throw invalid("invalid self-copy sampling geometry")}
        let minX=xs.min()!,maxX=xs.max()!,minY=ys.min()!,maxY=ys.max()!
        // Device pixel centers use i+0.5. These bounds describe the original
        // geometric extent before canvas/clip intersection, without allocating
        // its potentially off-canvas lattice. Empty center domains stay empty.
        func lattice(_ lower:Double,_ upper:Double)throws->Range<Int> {
            let first=ceil(lower-0.5),end=ceil(upper-0.5)
            guard first.isFinite,end.isFinite,abs(first)<=10_000_000_000,abs(end)<=10_000_000_000,end>=first else {throw invalid("self-copy destination lattice limit")}
            return Int(first)..<Int(end)
        }
        return SelfCopySamplingDomain(destination:destination,inverseDestination:inverse,source:source,
            minX:minX,maxX:maxX,minY:minY,maxY:maxY,
            sourceMinX:sourceXs.min()!,sourceMaxX:sourceXs.max()!,sourceMinY:sourceYs.min()!,sourceMaxY:sourceYs.max()!,
            boundingColumns:try lattice(minX,maxX),boundingRows:try lattice(minY,maxY),
            axisAlignedDestination:b==0 && c==0,axisAlignedSource:source[1]==0 && source[2]==0)
    }
    func composite(_ destination:JSValue,_ source:JSValue,_ pattern:JSValue,_ coverage:JSValue,_ widthValue:Double,_ heightValue:Double,_ ropValue:Double,_ request:JSValue)throws->NSObject {
        guard widthValue.isFinite,heightValue.isFinite,ropValue.isFinite,widthValue.rounded()==widthValue,heightValue.rounded()==heightValue,ropValue.rounded()==ropValue,
              widthValue>=1,heightValue>=1,widthValue<=32768,heightValue<=32768,widthValue*heightValue<=16777216,ropValue>=0,ropValue<=255 else{throw invalid("invalid dimensions or ROP3 truth byte")}
        let width=Int(widthValue),height=Int(heightValue),pixels=width*height,rop=Int(ropValue),size=CGSize(width:width,height:height)
        let area=try region(request,width:width,height:height)
        let needsSource=depends(rop,2,0x33),needsPattern=depends(rop,4,0x0f)
        var selfMap:[Double]?,selfMode=1,selfDomain:SelfCopySamplingDomain?
        if let value=request.forProperty("selfSource"),!value.isUndefined,!value.isNull {
            guard needsSource,value.isArray,value.forProperty("length")?.toInt32()==6 else {throw invalid("invalid self-copy source mapping")}
            var entries=[Double]();entries.reserveCapacity(6)
            for index in 0..<6 {
                guard let component=value.atIndex(index),component.isNumber else {throw invalid("invalid self-copy matrix value")}
                let n=component.toDouble();guard n.isFinite,abs(n)<=1_000_000_000 else {throw invalid("self-copy coordinate limit")};entries.append(n)
            }
            selfMap=entries
            if let stretch=request.forProperty("stretchMode"),!stretch.isUndefined {
                guard stretch.isNumber,[1.0,2,3,4].contains(stretch.toDouble()) else {throw invalid("invalid self-copy stretch mode")};selfMode=Int(stretch.toDouble())
            }
        }
        // Optional during this internal protocol transition: legacy matrix-only
        // bridge callers remain valid, without inventing a domain from the ROI.
        if let value=request.forProperty("selfDestination"),!value.isUndefined,!value.isNull {
            guard let selfMap,selfMode==4 else {throw invalid("self-copy destination domain requires HALFTONE source")}
            selfDomain=try selfCopySamplingDomain(value,matrix:selfMap)
        }
        let renders=2+(needsSource ? 1:0)+(needsPattern ? 1:0)
        // Domain-aware self HALFTONE uses bounded axis/row caches in addition
        // to the existing canvas/operand buffers. Reserve their complete cap.
        let samplingCacheBytes=selfMode==4 && selfDomain != nil ? 32*1024*1024:0
        guard calls<4096,pixels<=33554432-compositePixels,pixels*renders<=67108864-renderedPixels,
              pixels*4*(renders+2)<=256*1024*1024-samplingCacheBytes else{throw invalid("pixel, work or memory budget exceeded")}
        calls += 1;compositePixels += pixels;renderedPixels += pixels*renders
        guard let destinationSVG=try svg(destination,size:size,required:true),let coverageSVG=try svg(coverage,size:size,required:true) else{throw invalid("missing canvas or coverage")}
        let sourceSVG=try svg(source,size:size,required:needsSource && selfMap==nil),patternSVG=try svg(pattern,size:size,required:needsPattern)
        var output=try destinationPixels(destinationSVG,request:request,width:width,height:height)
        var tile=cropped(output,region:area,width:width)
        let mask=try render(coverageSVG,width:width,height:height,region:area)
        let sourcePixels:Data?
        if let selfMap {sourcePixels=try selfSource(output,width:width,height:height,area:area,matrix:selfMap,mode:selfMode,domain:selfDomain)}
        else {sourcePixels=needsSource ? try render(sourceSVG!,width:width,height:height,region:area):nil}
        let patternPixels=needsPattern ? try render(patternSVG!,width:width,height:height,region:area):nil
        try tile.withUnsafeMutableBytes { (destinationBytes:UnsafeMutableRawBufferPointer) in
            try mask.withUnsafeBytes { (coverageBytes:UnsafeRawBufferPointer) in
                func evaluate(_ sourceBytes:UnsafeRawBufferPointer?,_ patternBytes:UnsafeRawBufferPointer?)throws {
                    for pixel in 0..<area.pixels {
                        let offset=pixel*4,c=Int(coverageBytes[offset+3]);if c==0{continue}
                        // Coverage is alpha only. ROP2 supplies the actual paint
                        // SVG so transparent hatch holes remain unaffected;
                        // operand RGB never changes the geometric coverage.
                        if let sourceBytes {let alpha=Int(sourceBytes[offset+3]);if selfMap != nil && alpha==0 {continue};guard alpha>0,alpha+2>=c else{throw invalid("transparent required source is unsupported")}}
                        if let patternBytes {let alpha=Int(patternBytes[offset+3]);guard alpha>0,alpha+2>=c else{throw invalid("transparent required pattern is unsupported")}}
                        let destinationAlpha=Int(destinationBytes[offset+3])
                        func straight(_ bytes:UnsafeRawBufferPointer?,_ channel:Int)->UInt8 {
                            guard let bytes else{return 0};let alpha=Int(bytes[offset+3])
                            return UInt8(min(255,(Int(bytes[offset+channel])*255+alpha/2)/alpha))
                        }
                        for channel in 0..<3 {
                            let old=Int(destinationBytes[offset+channel]),d=UInt8(min(255,old+255-destinationAlpha))
                            let result=Int(apply(rop,straight(patternBytes,channel),straight(sourceBytes,channel),d))
                            destinationBytes[offset+channel]=UInt8((result*c+old*(255-c)+127)/255)
                        }
                        destinationBytes[offset+3]=UInt8(c+(destinationAlpha*(255-c)+127)/255)
                    }
                }
                if let sourcePixels {try sourcePixels.withUnsafeBytes { sourceBytes in
                    if let patternPixels {try patternPixels.withUnsafeBytes {try evaluate(sourceBytes,$0)}}else{try evaluate(sourceBytes,nil)}
                }}else if let patternPixels {try patternPixels.withUnsafeBytes {try evaluate(nil,$0)}}else{try evaluate(nil,nil)}
            }
        }
        install(tile,in:&output,region:area,width:width)
        return try finish(output,request:request,width:width,height:height)
    }
    private func encode(_ output:Data,width:Int,height:Int)throws->String {
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let provider=CGDataProvider(data:output as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{throw invalid("cannot prepare composite image")}
        let encoded=NSMutableData()
        guard let encoder=CGImageDestinationCreateWithData(encoded,UTType.png.identifier as CFString,1,nil) else{throw invalid("cannot encode composite image")}
        CGImageDestinationAddImage(encoder,image,nil)
        guard CGImageDestinationFinalize(encoder),encoded.length<=outputLimit/2 else{throw invalid("composite PNG output exceeds limit")}
        return "data:image/png;base64,"+(encoded as Data).base64EncodedString()
    }
    /// Mask selection, RGB color-key copies, premultiplied source-over and
    /// EMF+ SourceCopy share one guarded raster boundary and cumulative budgets.
    /// SourceCopy receives the paint and its independent opaque geometry; the
    /// source already contains exactly one edge/clip-coverage application.
    func transfer(_ destination:JSValue,_ source:JSValue,_ pattern:JSValue,_ coverage:JSValue,_ selection:JSValue,_ widthValue:Double,_ heightValue:Double,_ options:JSValue,_ request:JSValue)throws->NSObject {
        guard widthValue.isFinite,heightValue.isFinite,widthValue.rounded()==widthValue,heightValue.rounded()==heightValue,
              widthValue>=1,heightValue>=1,widthValue<=32768,heightValue<=32768,widthValue*heightValue<=16777216,
              options.isObject,!options.isArray,let modeValue=options.forProperty("mode"),modeValue.isString,
              let mode=modeValue.toString(),["mask","transparent","alpha","source-copy"].contains(mode) else{throw invalid("invalid transfer dimensions or mode")}
        func integer(_ name:String,_ maximum:Double)throws->Int {
            guard let value=options.forProperty(name),value.isNumber else{throw invalid("missing transfer "+name)}
            let number=value.toDouble()
            guard number.isFinite,number.rounded()==number,number>=0,number<=maximum else{throw invalid("invalid transfer "+name)}
            return Int(number)
        }
        let foreground=mode == "mask" ? try integer("foreground",255):0xcc
        let background=mode == "mask" ? try integer("background",255):0xaa
        let key=mode == "transparent" ? try integer("colorKey",16777215):0
        let constant=mode == "alpha" ? try integer("constantAlpha",255):255
        var perPixel=false
        if mode == "alpha" {
            guard let value=options.forProperty("perPixelAlpha"),value.isBoolean else{throw invalid("invalid per-pixel alpha selection")}
            perPixel=value.toBool()
        }
        let needsSource=mode != "mask" || depends(foreground,2,0x33) || depends(background,2,0x33)
        let needsPattern=mode == "mask" && (depends(foreground,4,0x0f) || depends(background,4,0x0f))
        let width=Int(widthValue),height=Int(heightValue),pixels=width*height,size=CGSize(width:width,height:height)
        let area=try region(request,width:width,height:height)
        let renders=2+(mode == "mask" ? 1:0)+(needsSource ? 1:0)+(needsPattern ? 1:0)
        guard calls<4096,pixels<=33554432-compositePixels,pixels*renders<=67108864-renderedPixels,
              pixels*4*(renders+2)<=256*1024*1024 else{throw invalid("pixel, work or memory budget exceeded")}
        calls += 1;compositePixels += pixels;renderedPixels += pixels*renders
        guard let destinationSVG=try svg(destination,size:size,required:true),let coverageSVG=try svg(coverage,size:size,required:true) else{throw invalid("missing canvas or coverage")}
        let sourceSVG=try svg(source,size:size,required:needsSource),patternSVG=try svg(pattern,size:size,required:needsPattern)
        let selectionSVG=try svg(selection,size:size,required:mode == "mask")
        var output=try destinationPixels(destinationSVG,request:request,width:width,height:height)
        var tile=cropped(output,region:area,width:width)
        let coveragePixels=try render(coverageSVG,width:width,height:height,region:area)
        let sourcePixels=needsSource ? try render(sourceSVG!,width:width,height:height,region:area):Data()
        let patternPixels=needsPattern ? try render(patternSVG!,width:width,height:height,region:area):Data()
        let selectionPixels=mode == "mask" ? try render(selectionSVG!,width:width,height:height,region:area):Data()
        try tile.withUnsafeMutableBytes { (dst:UnsafeMutableRawBufferPointer) in
            try coveragePixels.withUnsafeBytes { (coverageBytes:UnsafeRawBufferPointer) in
                try sourcePixels.withUnsafeBytes { (src:UnsafeRawBufferPointer) in
                    try patternPixels.withUnsafeBytes { (pat:UnsafeRawBufferPointer) in
                        try selectionPixels.withUnsafeBytes { (mono:UnsafeRawBufferPointer) in
                            try evaluateTransfer(dst:dst,area:coverageBytes,src:src,pat:pat,mono:mono,pixels:area.pixels,
                                                 mode:mode,foreground:foreground,background:background,
                                                 key:key,constant:constant,perPixel:perPixel)
                        }
                    }
                }
            }
        }
        install(tile,in:&output,region:area,width:width)
        return try finish(output,request:request,width:width,height:height)
    }
    /// Capture destination and clip before painting. Four-neighbor traversal
    /// owns a bounded queue and never crosses an excluded device pixel.
    func flood(_ destination:JSValue,_ coverage:JSValue,_ widthValue:Double,_ heightValue:Double,_ xValue:Double,_ yValue:Double,_ colorValue:Double,_ modeValue:Double)throws->String {
        let numbers=[widthValue,heightValue,xValue,yValue,colorValue,modeValue]
        guard numbers.allSatisfy({$0.isFinite && $0.rounded()==$0}),widthValue>=1,heightValue>=1,widthValue<=32768,heightValue<=32768,widthValue*heightValue<=16777216,colorValue>=0,colorValue<=16777215,[0.0,1.0].contains(modeValue) else{throw invalid("invalid flood dimensions, color or mode")}
        let width=Int(widthValue),height=Int(heightValue),pixels=width*height
        guard calls<4096,pixels<=33554432-compositePixels,pixels*2<=67108864-renderedPixels,pixels*24<=256*1024*1024 else{throw invalid("flood pixel, work or memory budget exceeded")}
        calls += 1;compositePixels += pixels;renderedPixels += pixels*2
        let size=CGSize(width:width,height:height)
        guard let dest=try svg(destination,size:size,required:true),let clip=try svg(coverage,size:size,required:true) else{throw invalid("missing flood destination or clip")}
        if xValue<0 || yValue<0 || xValue>=widthValue || yValue>=heightValue{return ""}
        let destinationPixels=try render(dest,width:width,height:height),clipPixels=try render(clip,width:width,height:height)
        var output=Data(count:pixels*4),queue=Data(count:pixels*4)
        var painted=false
        try output.withUnsafeMutableBytes {(out:UnsafeMutableRawBufferPointer) in
            try queue.withUnsafeMutableBytes {(storage:UnsafeMutableRawBufferPointer) in
                try destinationPixels.withUnsafeBytes {(dst:UnsafeRawBufferPointer) in
                    try clipPixels.withUnsafeBytes {(area:UnsafeRawBufferPointer) in
                        painted=try self.floodPixels(dst:dst,area:area,out:out,queue:storage.bindMemory(to:UInt32.self),width:width,height:height,x:Int(xValue),y:Int(yValue),color:Int(colorValue),surface:modeValue==1)
                    }
                }
            }
        }
        return painted ? try encode(output,width:width,height:height):""
    }
    private func floodPixels(dst:UnsafeRawBufferPointer,area:UnsafeRawBufferPointer,out:UnsafeMutableRawBufferPointer,queue:UnsafeMutableBufferPointer<UInt32>,width:Int,height:Int,x:Int,y:Int,color:Int,surface:Bool)throws->Bool {
        let pixels=width*height
        func eligible(_ p:Int)->Bool {
            let o=p*4
            if area[o+3]<128{return false}
            let alpha=Int(dst[o+3]),r=min(255,Int(dst[o])+255-alpha),g=min(255,Int(dst[o+1])+255-alpha),b=min(255,Int(dst[o+2])+255-alpha)
            let equal=(r<<16 | g<<8 | b)==color
            return surface ? equal:!equal
        }
        let seed=y*width+x
        guard eligible(seed) else{return false}
        var head=0,tail=1;queue[0]=UInt32(seed);out[seed*4+3]=1
        func enqueue(_ p:Int)throws {
            if out[p*4+3]==0 && eligible(p) {
                guard tail<pixels else{throw invalid("flood queue budget exceeded")}
                queue[tail]=UInt32(p);tail += 1;out[p*4+3]=1
            }
        }
        while head<tail {
            let p=Int(queue[head]),o=p*4;head += 1
            let alpha=area[o+3];out[o]=alpha;out[o+1]=alpha;out[o+2]=alpha;out[o+3]=alpha
            let column=p%width
            if column>0{try enqueue(p-1)};if column+1<width{try enqueue(p+1)}
            if p>=width{try enqueue(p-width)};if p+width<pixels{try enqueue(p+width)}
        }
        return true
    }
    // Keep pointer borrowing separate from pixel evaluation. Older distribution
    // compilers otherwise time out inferring the five nested Data closures.
    private func evaluateTransfer(dst:UnsafeMutableRawBufferPointer,area:UnsafeRawBufferPointer,
                                  src:UnsafeRawBufferPointer,pat:UnsafeRawBufferPointer,
                                  mono:UnsafeRawBufferPointer,pixels:Int,mode:String,
                                  foreground:Int,background:Int,key:Int,constant:Int,
                                  perPixel:Bool)throws {
        for pixel in 0..<pixels {
            let offset=pixel*4,c=Int(area[offset+3])
            if mode == "source-copy" {
                // Independent geometry carries edge/clip coverage even when
                // the paint itself is fully transparent. The painted SVG has
                // already applied that coverage to premultiplied RGBA; another
                // multiplication would square antialiasing at every edge.
                let alpha=Int(src[offset+3])
                guard alpha<=c+2 else{throw invalid("SourceCopy paint escaped independent geometry")}
                for channel in 0..<3 {
                    guard Int(src[offset+channel])<=alpha else{throw invalid("SourceCopy source is not premultiplied")}
                }
                if c==0 {continue}
                for channel in 0..<4 {
                    let result=Int(src[offset+channel])+(Int(dst[offset+channel])*(255-c)+127)/255
                    dst[offset+channel]=UInt8(min(255,result))
                }
                continue
            }
            if c==0{continue}
            func straight(_ bytes:UnsafeRawBufferPointer,_ channel:Int)throws->UInt8 {
                let a=Int(bytes[offset+3]);guard a>0,a+2>=c else{throw invalid("transparent required transfer operand")}
                return UInt8(min(255,(Int(bytes[offset+channel])*255+a/2)/a))
            }
            if mode == "alpha" {
                let a=Int(src[offset+3])
                // Source is an inverse-mapped full-device
                // plane. Only independent geometry supplies
                // edge/clip coverage; apply it exactly once.
                guard perPixel || a==255 else{throw invalid("constant-alpha source plane is not opaque")}
                let denominator=255*255
                let effective=(a*constant*c+denominator/2)/denominator
                for channel in 0..<3 {
                    let value=(Int(src[offset+channel])*constant*c+denominator/2)/denominator+(Int(dst[offset+channel])*(255-effective)+127)/255
                    dst[offset+channel]=UInt8(min(255,value))
                }
                dst[offset+3]=UInt8(min(255,effective+(Int(dst[offset+3])*(255-effective)+127)/255))
                continue
            }
            var rop=foreground
            if mode == "mask" {
                let r=try straight(mono,0),g=try straight(mono,1),b=try straight(mono,2)
                // The parser admits only 1-bit mask data, but
                // native SVG mapping can antialias cell edges.
                // Requantize that achromatic sample once; do
                // not blend foreground/background truth tables.
                guard Int(max(r,max(g,b)))-Int(min(r,min(g,b)))<=2 else{throw invalid("mask is not monochrome at device pixels")}
                rop=r>=128 ? foreground:background
                if rop==0xaa {continue} // Preserve destination RGBA exactly.
            }
            if mode == "transparent" {
                let r=try straight(src,0),g=try straight(src,1),b=try straight(src,2)
                if (Int(r)<<16 | Int(g)<<8 | Int(b))==key {continue}
            }
            let usesSource=depends(rop,2,0x33),usesPattern=depends(rop,4,0x0f),oldAlpha=Int(dst[offset+3])
            for channel in 0..<3 {
                let old=Int(dst[offset+channel]),d=UInt8(min(255,old+255-oldAlpha))
                let sourceByte=usesSource ? try straight(src,channel):0
                let patternByte=usesPattern ? try straight(pat,channel):0
                let result=Int(apply(rop,patternByte,sourceByte,d))
                dst[offset+channel]=UInt8((result*c+old*(255-c)+127)/255)
            }
            dst[offset+3]=UInt8(c+(oldAlpha*(255-c)+127)/255)
        }
    }

}

/// Region frames are inside the union, never separate strokes around each
/// constituent rectangle. Work in region coordinates before the JS affine map.
private final class NativeRegionGeometry {
    private var rectangles=0,edges=0
    private func invalid(_ text:String)->ConversionError{.invalid("Metafile region: "+text)}
    func path(_ value:JSValue,_ widthValue:Double,_ heightValue:Double,_ frame:Bool)throws->[String:Any] {
        guard value.isArray,let length=value.forProperty("length"),length.isNumber else{throw invalid("missing rectangles")}
        let raw=length.toDouble()
        guard raw.isFinite,raw.rounded()==raw,raw>=0,raw<=4096,widthValue.isFinite,heightValue.isFinite,widthValue>=0,heightValue>=0,widthValue<=1e6,heightValue<=1e6 else{throw invalid("invalid dimensions or rectangle budget exceeded")}
        let count=Int(raw)
        guard count<=65536-rectangles else{throw invalid("aggregate rectangle budget exceeded")};rectangles += count
        let input=CGMutablePath()
        for i in 0..<count {
            guard let row=value.atIndex(i),row.isArray,row.forProperty("length")?.toInt32()==4 else{throw invalid("invalid rectangle")}
            var numbers:[Double]=[]
            for j in 0..<4 {guard let v=row.atIndex(j),v.isNumber else{throw invalid("invalid coordinate")};let n=v.toDouble();guard n.isFinite,abs(n)<=1e9 else{throw invalid("coordinate exceeds limit")};numbers.append(n)}
            guard numbers[0]<=numbers[2],numbers[1]<=numbers[3] else{throw invalid("reversed rectangle")}
            if numbers[0]<numbers[2],numbers[1]<numbers[3] {input.addRect(CGRect(x:numbers[0],y:numbers[1],width:numbers[2]-numbers[0],height:numbers[3]-numbers[1]))}
        }
        var result=input.normalized(using:.winding)
        if frame {
            if widthValue==0 && heightValue==0 {return ["path":"","bounds":[0,0,0,0]]}
            let boundary=CGMutablePath();var current=CGPoint.zero,start=CGPoint.zero,failed=false
            func edge(_ next:CGPoint){
                self.edges += 1
                guard self.edges<=131072,current.x==next.x || current.y==next.y else{failed=true;return}
                let l=min(current.x,next.x)-widthValue,r=max(current.x,next.x)+widthValue
                let t=min(current.y,next.y)-heightValue,b=max(current.y,next.y)+heightValue
                boundary.addRect(CGRect(x:l,y:t,width:r-l,height:b-t));current=next
            }
            result.applyWithBlock {pointer in
                let e=pointer.pointee
                switch e.type {
                case .moveToPoint:current=e.points[0];start=current
                case .addLineToPoint:edge(e.points[0])
                case .closeSubpath:edge(start)
                default:failed=true
                }
            }
            guard !failed else{throw invalid("boundary geometry or edge budget exceeded")}
            result=boundary.normalized(using:.winding).intersection(result,using:.winding)
        }
        var commands:[String]=[],points=0,failed=false
        result.applyWithBlock {pointer in
            let e=pointer.pointee
            switch e.type {
            case .moveToPoint,.addLineToPoint:
                points += 1;guard points<=131072 else{failed=true;return}
                let p=e.points[0];guard p.x.isFinite,p.y.isFinite,abs(p.x)<=1e9,abs(p.y)<=1e9 else{failed=true;return}
                commands.append((e.type == .moveToPoint ? "M ":"L ")+String(Double(p.x))+" "+String(Double(p.y)))
            case .closeSubpath:commands.append("Z")
            default:failed=true
            }
        }
        guard !failed else{throw invalid("normalized geometry exceeds limit")}
        let bounds=result.boundingBoxOfPath
        return ["path":commands.joined(separator:" "),"bounds":result.isEmpty ? [0.0,0,0,0]:[Double(bounds.minX),Double(bounds.minY),Double(bounds.maxX),Double(bounds.maxY)]]
    }
}

/// Bounded geometric EMF+ pen playback. Input paths are generated by the private
/// renderer, never document-provided SVG. Curves are adaptively subdivided in
/// the nib's coordinate space with a conservative device-space error bound.
private final class NativeStrokeGeometry {
    private struct Figure { var points:[CGPoint]; var closed:Bool }
    private struct Piece { var points:[CGPoint]; var closed:Bool; var start:Bool; var end:Bool; var dotDirection:CGPoint?=nil }
    private struct Scanner {
        let bytes:[UInt8]; var offset=0
        mutating func skip() { while offset < bytes.count && [9,10,13,32,44].contains(bytes[offset]) { offset += 1 } }
        mutating func command() throws -> UInt8 { skip();guard offset < bytes.count else {throw NativeStrokeGeometry.invalid("missing path command")};let value=bytes[offset];offset += 1;return value }
        mutating func number() throws -> CGFloat {
            skip();let start=offset
            if offset < bytes.count && (bytes[offset] == 43 || bytes[offset] == 45) {offset += 1}
            var digits=0
            while offset < bytes.count && (48...57).contains(bytes[offset]) {offset += 1;digits += 1}
            if offset < bytes.count && bytes[offset] == 46 {offset += 1;while offset < bytes.count && (48...57).contains(bytes[offset]) {offset += 1;digits += 1}}
            guard digits > 0 else {throw NativeStrokeGeometry.invalid("invalid path number")}
            if offset < bytes.count && (bytes[offset] == 69 || bytes[offset] == 101) {
                offset += 1;if offset < bytes.count && (bytes[offset] == 43 || bytes[offset] == 45) {offset += 1}
                let exponent=offset;while offset < bytes.count && (48...57).contains(bytes[offset]) {offset += 1}
                guard offset > exponent else {throw NativeStrokeGeometry.invalid("invalid path exponent")}
            }
            guard let value=Double(String(decoding:bytes[start..<offset],as:UTF8.self)),value.isFinite,abs(value)<=1e9 else {throw NativeStrokeGeometry.invalid("path coordinate exceeds limit")}
            return CGFloat(value)
        }
    }
    private var inputPoints=0, outlinePoints=0, markupBytes=0, primitives=0
    private var coveragePaths:[String:CGPath]=[:]
    private var coveragePoints=0, coveragePixels=0
    private let maximumPoints=1_048_576
    private static func invalid(_ text:String)->ConversionError {.invalid("Metafile pen: "+text)}
    private func number(_ options:JSValue,_ name:String,_ fallback:Double)->Double {
        guard let value=options.forProperty(name),!value.isUndefined else {return fallback};return value.isNumber ? value.toDouble():.nan
    }
    private func array(_ options:JSValue,_ name:String,_ fallback:[Double]) throws ->[Double] {
        guard let value=options.forProperty(name),!value.isUndefined else {return fallback}
        guard value.isArray,let values=value.toArray() as? [NSNumber],values.count<=1024 else {throw Self.invalid("invalid "+name)}
        let result=values.map(\.doubleValue);guard result.allSatisfy({$0.isFinite && abs($0)<=1e9}) else {throw Self.invalid("invalid "+name)};return result
    }
    private func add(_ a:CGPoint,_ b:CGPoint)->CGPoint {.init(x:a.x+b.x,y:a.y+b.y)}
    private func sub(_ a:CGPoint,_ b:CGPoint)->CGPoint {.init(x:a.x-b.x,y:a.y-b.y)}
    private func mul(_ a:CGPoint,_ k:CGFloat)->CGPoint {.init(x:a.x*k,y:a.y*k)}
    private func dot(_ a:CGPoint,_ b:CGPoint)->CGFloat {a.x*b.x+a.y*b.y}
    private func cross(_ a:CGPoint,_ b:CGPoint)->CGFloat {a.x*b.y-a.y*b.x}
    private func length(_ a:CGPoint)->CGFloat {hypot(a.x,a.y)}
    private func unit(_ a:CGPoint)->CGPoint {let n=length(a);return n>0 ? mul(a,1/n):.zero}
    private func normal(_ a:CGPoint)->CGPoint {.init(x:-a.y,y:a.x)}
    private func midpoint(_ a:CGPoint,_ b:CGPoint)->CGPoint {mul(add(a,b),0.5)}
    private func finite(_ p:CGPoint) throws {guard p.x.isFinite,p.y.isFinite,abs(p.x)<=1e9,abs(p.y)<=1e9 else {throw Self.invalid("outline coordinate exceeds limit")}}
    private func reserveInput(_ count:Int=1) throws {guard count<=maximumPoints-inputPoints else {throw Self.invalid("aggregate flattened-point budget exceeded")};inputPoints += count}
    private func polygon(_ points:[CGPoint],to path:CGMutablePath) throws {
        guard points.count>2 else{return};guard points.count<=maximumPoints-outlinePoints,primitives<262_144 else {throw Self.invalid("aggregate outline budget exceeded")}
        outlinePoints += points.count;primitives += 1
        for p in points {try finite(p)}
        // All primitive strips have the same winding, so overlapping segments
        // union instead of erasing one another before native normalization.
        var area:CGFloat=0;for i in points.indices {area += cross(points[i],points[(i+1)%points.count])}
        let values=area>=0 ? points:Array(points.reversed())
        path.move(to:values[0]);for p in values.dropFirst() {path.addLine(to:p)};path.closeSubpath()
    }
    private func arcPoints(center:CGPoint,radius:CGFloat,start:CGFloat,sweep:CGFloat,tolerance:CGFloat) throws ->[CGPoint] {
        guard radius>0 else{return[center]}
        let maximumAngle=max(0.000001,min(.pi/8,2*acos(max(-1,min(1,1-tolerance/radius)))))
        let count=max(1,Int(ceil(abs(sweep)/maximumAngle)))
        guard count<=65536,count<=maximumPoints-outlinePoints else {throw Self.invalid("arc outline budget exceeded")}
        return (0...count).map { i in let a=start+sweep*CGFloat(i)/CGFloat(count);return add(center,.init(x:cos(a)*radius,y:sin(a)*radius)) }
    }
    private func circle(_ center:CGPoint,_ radius:CGFloat,to path:CGMutablePath,tolerance:CGFloat) throws {try polygon(arcPoints(center:center,radius:radius,start:0,sweep:2 * .pi,tolerance:tolerance),to:path)}
    private func parse(_ text:String,inverse:CGAffineTransform,tolerance:CGFloat,radius:CGFloat) throws ->[Figure] {
        guard text.utf8.count<=2*1024*1024 else {throw Self.invalid("input path budget exceeded")}
        var scanner=Scanner(bytes:Array(text.utf8)),result:[Figure]=[],points:[CGPoint]=[],closed=false,current=CGPoint.zero,start=CGPoint.zero,commands=0,lastArc=false
        func transformed(_ p:CGPoint)->CGPoint {p.applying(inverse)}
        func append(_ p:CGPoint) throws {try reserveInput();try finite(p);if points.last.map({length(sub($0,p))>1e-10}) ?? true {points.append(p)}}
        func finish() {if !points.isEmpty {var values=points;let arcClosed=lastArc && values.count>2 && length(sub(values[0],values[values.count-1]))<1e-8;if (closed || arcClosed) && values.count>1 && length(sub(values[0],values[values.count-1]))<1e-8 {values.removeLast()};result.append(.init(points:values,closed:closed || arcClosed))};points=[];closed=false;lastArc=false}
        func flat(_ p0:CGPoint,_ p1:CGPoint,_ p2:CGPoint,_ p3:CGPoint)->Bool {
            let chord=sub(p3,p0),n=length(chord)
            func segmentDistance(_ point:CGPoint)->CGFloat {
                guard n>1e-12 else {return length(sub(point,p0))}
                let projection=max(0,min(1,dot(sub(point,p0),chord)/(n*n)))
                return length(sub(point,add(p0,mul(chord,projection))))
            }
            let distance=max(segmentDistance(p1),segmentDistance(p2))
            let a=unit(sub(p1,p0)),b=unit(sub(p3,p2)),cosine=max(-1,min(1,dot(a,b)))
            // Derivative extrema are split explicitly below. A remaining tiny
            // interval around a stationary endpoint is bounded by its complete
            // control hull, even when roundoff reverses a near-zero tangent.
            if max(length(sub(p1,p0)),length(sub(p2,p0)),length(sub(p3,p0)))<=tolerance/4 {return true}
            let nibError=radius*(1-sqrt(max(0,(1+cosine)/2)))
            return distance<=tolerance && (length(a)==0 || length(b)==0 || nibError<=tolerance)
        }
        func cubic(_ p0:CGPoint,_ p1:CGPoint,_ p2:CGPoint,_ p3:CGPoint,_ depth:Int) throws {
            if flat(p0,p1,p2,p3) {try append(p3);return};guard depth<24 else {throw Self.invalid("curve subdivision limit")}
            let a=midpoint(p0,p1),b=midpoint(p1,p2),c=midpoint(p2,p3),d=midpoint(a,b),e=midpoint(b,c),f=midpoint(d,e)
            try cubic(p0,a,d,f,depth+1);try cubic(f,e,c,p3,depth+1)
        }
        func curve(_ p0:CGPoint,_ p1:CGPoint,_ p2:CGPoint,_ p3:CGPoint) throws {
            func roots(_ a:CGFloat,_ b:CGFloat,_ c:CGFloat,_ d:CGFloat)->[CGFloat] {
                let qa = -a+3*b-3*c+d,qb=2*(a-2*b+c),qc=b-a
                if abs(qa)<1e-14 {return abs(qb)>1e-14 ? [-qc/qb]:[]}
                let discriminant=qb*qb-4*qa*qc
                guard discriminant>=0 else{return []}
                let square=sqrt(discriminant),q = -0.5*(qb+(qb>=0 ? square: -square))
                if abs(q)<1e-20 {return [-qb/(2*qa)]}
                return [q/qa,qc/q]
            }
            let candidates=(roots(p0.x,p1.x,p2.x,p3.x)+roots(p0.y,p1.y,p2.y,p3.y)).filter{$0>1e-10 && $0<1-1e-10}.sorted()
            var cuts:[CGFloat]=[]
            for cut in candidates where cuts.last.map({abs($0-cut)>1e-10}) ?? true {cuts.append(cut)}
            var a=p0,b=p1,c=p2,d=p3,previous:CGFloat=0
            for cut in cuts {
                let t=(cut-previous)/(1-previous),ab=add(a,mul(sub(b,a),t)),bc=add(b,mul(sub(c,b),t)),cd=add(c,mul(sub(d,c),t)),abc=add(ab,mul(sub(bc,ab),t)),bcd=add(bc,mul(sub(cd,bc),t)),point=add(abc,mul(sub(bcd,abc),t))
                try cubic(a,ab,abc,point,0)
                a=point;b=bcd;c=cd;previous=cut
            }
            try cubic(a,b,c,d,0)
        }
        while true {
            scanner.skip();if scanner.offset==scanner.bytes.count {break};commands += 1;guard commands<=262_144 else {throw Self.invalid("path command budget exceeded")}
            let command=try scanner.command()
            func pair() throws ->CGPoint {.init(x:try scanner.number(),y:try scanner.number())}
            switch command {
            case 77: finish();current=try pair();start=current;try append(transformed(current))
            case 76: guard !points.isEmpty else {throw Self.invalid("line without path start")};current=try pair();try append(transformed(current));lastArc=false
            case 72: guard !points.isEmpty else {throw Self.invalid("line without path start")};current.x=try scanner.number();try append(transformed(current));lastArc=false
            case 86: guard !points.isEmpty else {throw Self.invalid("line without path start")};current.y=try scanner.number();try append(transformed(current));lastArc=false
            case 67:
                guard !points.isEmpty else {throw Self.invalid("curve without path start")};let a=try pair(),b=try pair(),end=try pair();try curve(transformed(current),transformed(a),transformed(b),transformed(end));current=end;lastArc=false
            case 81:
                guard !points.isEmpty else {throw Self.invalid("curve without path start")};let a=try pair(),end=try pair();let p0=transformed(current),p1=transformed(a),p2=transformed(end)
                try curve(p0,add(p0,mul(sub(p1,p0),2/3)),add(p2,mul(sub(p1,p2),2/3)),p2);current=end;lastArc=false
            case 65:
                guard !points.isEmpty else {throw Self.invalid("arc without path start")}
                var rx=abs(try scanner.number()),ry=abs(try scanner.number());let rotation=try scanner.number() * .pi/180,large=try scanner.number(),sweep=try scanner.number(),end=try pair()
                guard (large==0 || large==1) && (sweep==0 || sweep==1) else {throw Self.invalid("invalid arc flags")}
                if rx==0 || ry==0 {try append(transformed(end));current=end;lastArc=true;continue}
                if length(sub(current,end))<1e-12 {current=end;lastArc=true;continue}
                let c=cos(rotation),s=sin(rotation),delta=mul(sub(current,end),0.5),x=c*delta.x+s*delta.y,y = -s*delta.x+c*delta.y
                let correction=x*x/(rx*rx)+y*y/(ry*ry);if correction>1 {let k=sqrt(correction);rx *= k;ry *= k}
                let denominator=rx*rx*y*y+ry*ry*x*x
                let factor=(large==sweep ? -1.0:1.0)*sqrt(max(0,(rx*rx*ry*ry-denominator)/max(1e-300,denominator)))
                let cx=factor*rx*y/ry,cy = -factor*ry*x/rx,mid=midpoint(current,end),center=add(mid,.init(x:c*cx-s*cy,y:s*cx+c*cy))
                let a=atan2((y-cy)/ry,(x-cx)/rx),z=atan2((-y-cy)/ry,(-x-cx)/rx);var angle=z-a
                if sweep==0 && angle>0 {angle -= 2 * .pi};if sweep==1 && angle<0 {angle += 2 * .pi}
                let ellipseScale=max(length(CGPoint(x:c*rx,y:s*rx).applying(.init(a:inverse.a,b:inverse.b,c:inverse.c,d:inverse.d,tx:0,ty:0))),length(CGPoint(x:-s*ry,y:c*ry).applying(.init(a:inverse.a,b:inverse.b,c:inverse.c,d:inverse.d,tx:0,ty:0))))
                let step=max(0.000001,min(.pi/16,2*acos(max(-1,min(1,1-tolerance/max(1e-9,ellipseScale+radius))))))
                let count=max(1,Int(ceil(abs(angle)/step)));guard count<=65536 else {throw Self.invalid("arc subdivision budget exceeded")}
                for i in 1...count {let theta=a+angle*CGFloat(i)/CGFloat(count);let q=CGPoint(x:center.x+c*rx*cos(theta)-s*ry*sin(theta),y:center.y+s*rx*cos(theta)+c*ry*sin(theta));try append(transformed(q))}
                current=end;lastArc=true
            case 90: guard !points.isEmpty else {throw Self.invalid("close without path start")};closed=true;current=start
            default: throw Self.invalid("unsupported generated path command")
            }
        }
        finish();return result
    }
    private func trim(_ points:[CGPoint],by amount:CGFloat,fromStart:Bool)->[CGPoint] {
        var values=fromStart ? points:Array(points.reversed()),remaining=amount
        while values.count>1 {
            let span=length(sub(values[1],values[0]));if remaining<span {values[0]=add(values[0],mul(unit(sub(values[1],values[0])),remaining));break}
            remaining -= span;values.removeFirst()
        }
        return fromStart ? values:Array(values.reversed())
    }
    private func dashed(_ figure:Figure,pattern:[CGFloat],offset:CGFloat,width:CGFloat) throws ->[Piece] {
        guard !pattern.isEmpty else{return [.init(points:figure.points,closed:figure.closed,start:true,end:true)]}
        let values=pattern.count%2==0 ? pattern:pattern+pattern,total=values.reduce(0,+)*width
        guard total.isFinite,total>1e-10 else {throw Self.invalid("dash cycle is too small")}
        var phase=(offset*width).truncatingRemainder(dividingBy:total);if phase<0 {phase += total}
        var index=0
        while phase>0 {
            let span=values[index]*width
            if span>phase {break}
            phase -= span;index=(index+1)%values.count
        }
        var remaining=values[index]*width-phase,result:[Piece]=[],active:[CGPoint]=[],activeStart=false,steps=0
        let points=figure.closed ? figure.points+[figure.points[0]]:figure.points
        for segment in 0..<max(0,points.count-1) {
            let a=points[segment],b=points[segment+1],distance=length(sub(b,a));if distance<1e-10 {continue};let direction=unit(sub(b,a));var travelled:CGFloat=0
            while travelled<distance-1e-10 {
                steps += 1;guard steps<=131072 else {throw Self.invalid("dash subdivision budget exceeded")}
                let begin=add(a,mul(direction,travelled))
                if remaining==0 {
                    // Classic USERSTYLE permits true zero lengths. Preserve a
                    // zero on-segment as its cap, not a fabricated epsilon dash.
                    if index%2==0 {result.append(.init(points:[begin,begin],closed:false,start:false,end:false,dotDirection:direction))}
                    index=(index+1)%values.count;remaining=values[index]*width
                    continue
                }
                let step=min(remaining,distance-travelled),end=add(a,mul(direction,travelled+step))
                guard step>1e-12 else {throw Self.invalid("dash length is below geometry precision")}
                if index%2==0 {if active.isEmpty {active=[begin];activeStart=segment==0 && travelled<1e-10};active.append(end)}
                travelled += step;remaining -= step
                if remaining<1e-10 {
                    if !active.isEmpty {result.append(.init(points:active,closed:false,start:activeStart,end:segment==points.count-2 && travelled>=distance-1e-10));active=[]}
                    index=(index+1)%values.count;remaining=values[index]*width
                }
            }
        }
        if !active.isEmpty {result.append(.init(points:active,closed:false,start:activeStart,end:true))}
        if figure.closed,result.count>1,result[0].start,result[result.count-1].end {
            let last=result.removeLast(),first=result.removeFirst();result.insert(.init(points:last.points+first.points.dropFirst(),closed:false,start:false,end:false),at:0)
        } else if figure.closed,result.count==1,result[0].start,result[0].end {result[0].closed=true}
        if figure.closed {for i in result.indices {result[i].start=false;result[i].end=false}}
        return result
    }
    /// PS_ALTERNATE is a cosmetic device-pixel pattern, not an antialiased
    /// one-unit SVG dash shifted half a pixel along its tangent. Walk the
    /// bounded flattened device path and emit alternate complete pixel cells.
    private func alternatePixels(_ figure:Figure,to path:CGMutablePath) throws {
        guard figure.points.count>1 else{return}
        let points=figure.closed ? figure.points+[figure.points[0]]:figure.points
        var phase=0,steps=0
        for i in 0..<(points.count-1) {
            var x=Int(points[i].x.rounded()),y=Int(points[i].y.rounded())
            let endX=Int(points[i+1].x.rounded()),endY=Int(points[i+1].y.rounded())
            let dx=abs(endX-x),dy = -abs(endY-y),sx=x<endX ? 1:-1,sy=y<endY ? 1:-1
            guard max(dx,-dy)<=131072-steps else {throw Self.invalid("alternate device-pixel budget exceeded")}
            var error=dx+dy
            // Exclude the terminal cell: the next segment owns its vertex,
            // and an open GDI line does not draw the final endpoint twice.
            while x != endX || y != endY {
                steps += 1
                if phase%2==0 {
                    guard primitives<32768,outlinePoints<=131068 else {throw Self.invalid("alternate outline budget exceeded")}
                    let a=CGPoint(x:CGFloat(x),y:CGFloat(y))
                    try polygon([a,CGPoint(x:CGFloat(x+1),y:CGFloat(y)),CGPoint(x:CGFloat(x+1),y:CGFloat(y+1)),CGPoint(x:CGFloat(x),y:CGFloat(y+1))],to:path)
                }
                phase += 1
                let twice=2*error
                if twice>=dy {error += dy;x += sx}
                if twice<=dx {error += dx;y += sy}
            }
        }
    }
    private func sideJoin(_ p:CGPoint,_ t0:CGPoint,_ t1:CGPoint,_ offset:CGFloat,width:CGFloat,join:Int,limit:CGFloat,tolerance:CGFloat) throws ->[CGPoint] {
        let u=add(p,mul(normal(t0),offset)),v=add(p,mul(normal(t1),offset)),turn=cross(t0,t1),cosine=max(-1,min(1,dot(t0,t1)))
        if abs(offset)<1e-12 {return[p]}
        if abs(turn)<1e-10 {return[u,v]}
        let intersection=add(u,mul(t0,cross(sub(v,u),t1)/turn)),outer=turn*offset<0
        if !outer {return[intersection]}
        if join==2 {return try arcPoints(center:p,radius:abs(offset),start:atan2(u.y-p.y,u.x-p.x),sweep:atan2(turn,cosine),tolerance:tolerance)}
        if join==1 {return[u,v]}
        let half=max(1e-12,sqrt(max(0,(1+cosine)/2))),ratio=1/half
        if ratio<=limit {return[u,intersection,v]}
        if join==3 {return[u,v]}
        // Enum zero's clipping plane is applied to both adjacent segment
        // quads and the entire joint below, including exceptionally acute tips.
        return[u,intersection,v]
    }
    private func clip(_ points:[CGPoint],origin:CGPoint,axis:CGPoint,cut:CGFloat)->[CGPoint] {
        guard !points.isEmpty else {return []};var result:[CGPoint]=[]
        for i in points.indices {
            let a=points[i],b=points[(i+1)%points.count],da=dot(sub(a,origin),axis)-cut,db=dot(sub(b,origin),axis)-cut
            if da<=0 {result.append(a)}
            if (da<=0) != (db<=0) {result.append(add(a,mul(sub(b,a),da/(da-db))))}
        }
        return result
    }
    private func miterClip(_ points:[CGPoint],at index:Int,figure:[CGPoint],closed:Bool,low:CGFloat,high:CGFloat,join:Int,limit:CGFloat)->[CGPoint] {
        let count=figure.count
        guard join==0,(closed || (index>0 && index<count-1)) else{return points}
        let p=figure[index],t0=unit(sub(p,figure[(index+count-1)%count])),t1=unit(sub(figure[(index+1)%count],p)),turn=cross(t0,t1)
        guard abs(turn)>1e-10 else{return points}
        let offset=turn>0 ? low:high,half=sqrt(max(0,(1+max(-1,min(1,dot(t0,t1))))/2))
        guard turn*offset<0,half>1e-12,1/half>limit else{return points}
        let axis=mul(unit(add(normal(t0),normal(t1))),offset<0 ? -1:1)
        return clip(points,origin:p,axis:axis,cut:abs(offset)*(2*limit-1/half))
    }
    private func stripCorner(_ figure:[CGPoint],index:Int,offset:CGFloat,segmentTangent:CGPoint,closed:Bool)->CGPoint {
        let count=figure.count,p=figure[index],base=add(p,mul(normal(segmentTangent),offset))
        guard closed || (index>0 && index<count-1) else{return base}
        let incoming=unit(sub(p,figure[(index+count-1)%count])),outgoing=unit(sub(figure[(index+1)%count],p)),turn=cross(incoming,outgoing)
        guard turn*offset>0,abs(turn)>1e-10 else{return base}
        let u=add(p,mul(normal(incoming),offset)),v=add(p,mul(normal(outgoing),offset))
        return add(u,mul(incoming,cross(sub(v,u),outgoing)/turn))
    }
    private func cap(_ p:CGPoint,direction:CGPoint,low:CGFloat,high:CGFloat,kind:Int,to path:CGMutablePath,tolerance:CGFloat) throws {
        let n=normal(direction),center=add(p,mul(n,(low+high)/2)),radius=(high-low)/2
        let a=add(p,mul(n,low)),b=add(p,mul(n,high))
        switch kind {
        case 1:try polygon([a,b,add(b,mul(direction,radius)),add(a,mul(direction,radius))],to:path)
        case 2:let angle=atan2(direction.y,direction.x);try polygon([center]+arcPoints(center:center,radius:radius,start:angle - .pi/2,sweep:.pi,tolerance:tolerance),to:path)
        case 3:try polygon([a,b,add(center,mul(direction,radius))],to:path)
        default:break
        }
    }
    private func anchor(_ p:CGPoint,direction:CGPoint,width:CGFloat,kind:Int,to path:CGMutablePath,tolerance:CGFloat) throws {
        let n=normal(direction)
        func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {add(p,add(mul(direction,x),mul(n,y)))}
        switch kind {
        case 17:let r=width/sqrt(2);try polygon([point(-r,-r),point(r,-r),point(r,r),point(-r,r)],to:path)
        case 18:try circle(p,width,to:path,tolerance:tolerance)
        case 19:try polygon([point(-width,0),point(0,-width),point(width,0),point(0,width)],to:path)
        case 20:let r=2*width/sqrt(3);try polygon([p,point(-2*width,-r),point(-2*width,r)],to:path)
        default:break
        }
    }
    private struct CustomCap {
        let figures:[Figure],filled:Bool
        let baseCap:Int,baseInset:CGFloat,widthScale:CGFloat
        let adjustableArrow:Bool
        // Arrow's API base-cap property is Triangle. The rendering reference
        // places its custom head directly, without another shaft triangle.
        var shaftCap:Int {adjustableArrow ? 0:baseCap}
        let startCap:Int,endCap:Int,join:Int,miterLimit:CGFloat
    }
    private func customCap(_ options:JSValue,_ name:String,width:CGFloat,tolerance:CGFloat) throws ->CustomCap? {
        guard let value=options.forProperty(name),!value.isUndefined else {return nil}
        guard value.isObject,!value.isNull,!value.isArray else {throw Self.invalid("invalid "+name)}
        func scalar(_ key:String,_ fallback:Double=0)->CGFloat {
            CGFloat(number(value,key,fallback))
        }
        func enumeration(_ key:String,_ allowed:[Int],_ fallback:Int=0) throws ->Int {
            let n=scalar(key,Double(fallback));guard n.isFinite,n>=0,n<=255,n.rounded()==n,allowed.contains(Int(n)) else {throw Self.invalid("invalid custom cap "+key)};return Int(n)
        }
        let type=try enumeration("type",[0,1]),start=try enumeration("strokeStartCap",[0,1,2,3]),end=try enumeration("strokeEndCap",[0,1,2,3]),join=try enumeration("join",[0,1,2,3])
        let scale=scalar("widthScale",1),limit=scalar("miterLimit",10)
        guard scale.isFinite,scale>=0,scale<=65536,limit.isFinite,limit>=1,limit<=65536 else {throw Self.invalid("invalid custom cap scale or miter")}
        let localTolerance=tolerance/max(1e-12,width*scale)
        var figures:[Figure]=[],filled=false,base=0,inset:CGFloat=0
        if type==0 {
            base=try enumeration("baseCap",[0,1,2,3]);inset=scalar("baseInset")
            guard inset.isFinite,abs(inset)<=65536 else {throw Self.invalid("invalid custom base inset")}
            func path(_ key:String) throws ->String? {
                guard let field=value.forProperty(key),!field.isUndefined else {return nil}
                guard field.isString,let text=field.toString(),text.utf8.count<=2*1024*1024 else {throw Self.invalid("invalid custom "+key)}
                return text
            }
            let fill=try path("fillPath"),stroke=try path("strokePath")
            if let selected=stroke ?? fill {
                filled=stroke==nil
                figures=try parse(selected,inverse:.identity,tolerance:localTolerance,radius:1)
            }
        } else {
            let w=scalar("width"),h=scalar("height"),middle=scalar("middleInset")
            guard w.isFinite,h.isFinite,middle.isFinite,w>=0,h>=0,w<=65536,h<=65536,abs(middle)<=65536,
                  let fill=value.forProperty("filled"),fill.isBoolean else {throw Self.invalid("invalid adjustable arrow")}
            filled=fill.toBool();base=3;inset=w==0 ? 0:h/w
            if filled {
                if h>0,middle<h {figures=[.init(points:[.init(x:-w/2,y:-h),.zero,.init(x:w/2,y:-h),.init(x:0,y:-h+middle)],closed:true)]}
            } else {figures=[.init(points:[.init(x:-w/2,y:-h),.zero,.init(x:w/2,y:-h)],closed:false)]}
            try reserveInput(figures.reduce(0){$0+$1.points.count})
        }
        return CustomCap(figures:figures,filled:filled,baseCap:base,baseInset:inset,widthScale:scale,adjustableArrow:type==1,startCap:start,endCap:end,join:join,miterLimit:limit)
    }
    private func checkNormalizationBudget() throws {
        guard primitives<=32768,outlinePoints<=131072 else {throw Self.invalid("native normalization budget exceeded")}
    }
    /// Keep a cap's winding holes independent of the shaft's winding strips;
    /// boolean union must add shaft ink through a hole rather than cancel it.
    private func customInk(_ custom:CustomCap,at endpoint:CGPoint,direction:CGPoint,width:CGFloat,tolerance:CGFloat) throws ->CGPath {
        let scale=width*custom.widthScale,local=CGMutablePath()
        guard scale>0,!custom.figures.isEmpty else {return local}
        if custom.filled {
            for figure in custom.figures where figure.points.count>2 {
                guard figure.points.count<=131072-outlinePoints,primitives<32768 else {throw Self.invalid("custom fill budget exceeded")}
                outlinePoints += figure.points.count;primitives += 1
                local.move(to:figure.points[0]);for p in figure.points.dropFirst() {local.addLine(to:p)};local.closeSubpath()
            }
        } else {
            for figure in custom.figures {
                try outline(figure,width:1,bands:[0,1],pattern:[],offset:0,startCap:custom.startCap,endCap:custom.endCap,dashCap:0,join:custom.join,limit:custom.miterLimit,tolerance:tolerance/scale,to:local)
            }
        }
        try checkNormalizationBudget()
        let n=normal(direction)
        var transform=CGAffineTransform(a:-n.x*scale,b:-n.y*scale,c:direction.x*scale,d:direction.y*scale,tx:endpoint.x,ty:endpoint.y)
        guard let result=local.normalized(using:.winding).copy(using:&transform) else {throw Self.invalid("could not place custom cap")}
        var invalidPoint=false
        result.applyWithBlock { element in
            let count:Int
            switch element.pointee.type {case .moveToPoint,.addLineToPoint:count=1;case .addQuadCurveToPoint:count=2;case .addCurveToPoint:count=3;case .closeSubpath:count=0;@unknown default:invalidPoint=true;return}
            for index in 0..<count {
                let point=element.pointee.points[index]
                if !point.x.isFinite || !point.y.isFinite || abs(point.x)>1e9 || abs(point.y)>1e9 {invalidPoint=true}
            }
        }
        guard !invalidPoint else {throw Self.invalid("custom cap coordinate exceeds limit")}
        return result
    }
    private func outline(_ figure:Figure,width:CGFloat,bands:[CGFloat],pattern:[CGFloat],offset:CGFloat,startCap:Int,endCap:Int,dashCap:Int,join:Int,limit:CGFloat,tolerance:CGFloat,dashWidth:CGFloat?=nil,customStart:CustomCap?=nil,customEnd:CustomCap?=nil,to path:CGMutablePath) throws {
        guard figure.points.count>1 else{return}
        let original=figure.points;var adjusted=figure
        if !figure.closed {
            if customStart != nil || customEnd != nil {
                let available=zip(original,original.dropFirst()).reduce(CGFloat(0)) {$0+length(sub($1.1,$1.0))}
                let requested=max(0,customStart?.baseInset ?? 0)*width+max(0,customEnd?.baseInset ?? 0)*width
                guard requested.isFinite,requested<=available+1e-9 else {throw Self.invalid("custom cap inset exceeds physical line length")}
            }
            if let customStart {adjusted.points=trim(adjusted.points,by:customStart.baseInset*width,fromStart:true)}
            else if startCap==20 {adjusted.points=trim(adjusted.points,by:width,fromStart:true)}
            if let customEnd {adjusted.points=trim(adjusted.points,by:customEnd.baseInset*width,fromStart:false)}
            else if endCap==20 {adjusted.points=trim(adjusted.points,by:width,fromStart:false)}
        }
        let pieces=try dashed(adjusted,pattern:pattern,offset:offset,width:dashWidth ?? width)
        for piece in pieces {
            guard piece.points.count>1 else {continue}
            var points=piece.points
            if let direction=piece.dotDirection {
                for band in stride(from:0,to:bands.count,by:2) {
                    let low=(bands[band]-0.5)*width,high=(bands[band+1]-0.5)*width
                    try cap(points[0],direction:direction,low:low,high:high,kind:dashCap,to:path,tolerance:tolerance)
                    try cap(points[0],direction:mul(direction,-1),low:-high,high:-low,kind:dashCap,to:path,tolerance:tolerance)
                }
                continue
            }
            if piece.closed,points.last==points.first {points.removeLast()}
            let count=points.count,segments=piece.closed ? count:count-1
            guard segments*max(1,bands.count/2)<=32768-primitives else {throw Self.invalid("stroke primitive budget exceeded")}
            for band in stride(from:0,to:bands.count,by:2) {
                let low=(bands[band]-0.5)*width,high=(bands[band+1]-0.5)*width
                for i in 0..<segments {
                    let tangent=unit(sub(points[(i+1)%count],points[i]))
                    let aLow=stripCorner(points,index:i,offset:low,segmentTangent:tangent,closed:piece.closed)
                    let bLow=stripCorner(points,index:(i+1)%count,offset:low,segmentTangent:tangent,closed:piece.closed)
                    let bHigh=stripCorner(points,index:(i+1)%count,offset:high,segmentTangent:tangent,closed:piece.closed)
                    let aHigh=stripCorner(points,index:i,offset:high,segmentTangent:tangent,closed:piece.closed)
                    var strip=[aLow,bLow,bHigh,aHigh]
                    strip=miterClip(strip,at:i,figure:points,closed:piece.closed,low:low,high:high,join:join,limit:limit)
                    strip=miterClip(strip,at:(i+1)%count,figure:points,closed:piece.closed,low:low,high:high,join:join,limit:limit)
                    try polygon(strip,to:path)
                }
                if count>2 {for i in (piece.closed ? 0:1)..<(piece.closed ? count:count-1) {
                    let p=points[i],t0=unit(sub(p,points[(i+count-1)%count])),t1=unit(sub(points[(i+1)%count],p))
                    if dot(t0,t1)>0.9999999999 {continue}
                    if join==2 && dot(t0,t1)<(-0.9999999999) {
                        // A retraced segment has no signed cross-product. Its
                        // round cusp still extends in the incoming direction.
                        let outer=max(abs(low),abs(high)),inner=low<=0 && high>=0 ? 0:min(abs(low),abs(high)),angle=atan2(t0.y,t0.x)
                        let edge=try arcPoints(center:p,radius:outer,start:angle - .pi/2,sweep:.pi,tolerance:tolerance)
                        let hole=inner>0 ? try arcPoints(center:p,radius:inner,start:angle + .pi/2,sweep: -.pi,tolerance:tolerance):[p]
                        try polygon(edge+hole,to:path);continue
                    }
                    let lo=try sideJoin(p,t0,t1,low,width:width,join:join,limit:limit,tolerance:tolerance),hi=try sideJoin(p,t0,t1,high,width:width,join:join,limit:limit,tolerance:tolerance)
                    try polygon(miterClip(lo+Array(hi.reversed()),at:i,figure:points,closed:piece.closed,low:low,high:high,join:join,limit:limit),to:path)
                }}
                if !piece.closed {
                    let firstDirection=unit(sub(points[0],points[1])),lastDirection=unit(sub(points[count-1],points[count-2]))
                    // Reversing the first tangent also reverses the offset axes.
                    try cap(points[0],direction:firstDirection,low:-high,high:-low,kind:piece.start ? (customStart?.shaftCap ?? startCap):dashCap,to:path,tolerance:tolerance)
                    try cap(points[count-1],direction:lastDirection,low:low,high:high,kind:piece.end ? (customEnd?.shaftCap ?? endCap):dashCap,to:path,tolerance:tolerance)
                }
            }
        }
        if !figure.closed {
            if customStart==nil {try anchor(original[0],direction:unit(sub(original[0],original[1])),width:width,kind:startCap,to:path,tolerance:tolerance)}
            if customEnd==nil {try anchor(original[original.count-1],direction:unit(sub(original[original.count-1],original[original.count-2])),width:width,kind:endCap,to:path,tolerance:tolerance)}
        }
    }
    func stroke(_ text:String,options:JSValue) throws ->[String:Any] {
        guard options.isObject else {throw Self.invalid("invalid stroke options")}
        let rawWidth=number(options,"width",1),rawLimit=number(options,"miterLimit",10),rawOffset=number(options,"dashOffset",0)
        guard rawWidth.isFinite,rawWidth>=0,rawWidth<=1e6,rawLimit.isFinite,rawLimit>=1,rawLimit<=1e6,rawOffset.isFinite,abs(rawOffset)<=1e9 else {throw Self.invalid("invalid pen dimensions")}
        func enumeration(_ name:String,_ allowed:[Int],_ fallback:Int) throws ->Int {let n=number(options,name,Double(fallback));guard n.isFinite,n>=0,n<=255,n.rounded()==n,allowed.contains(Int(n)) else {throw Self.invalid("unsupported "+name)};return Int(n)}
        let startCap=try enumeration("startCap",[0,1,2,3,16,17,18,19,20,255],0),endCap=try enumeration("endCap",[0,1,2,3,16,17,18,19,20,255],0),dashCap=try enumeration("dashCap",[0,1,2,3],0),join=try enumeration("join",[0,1,2,3],0),alignment=try enumeration("alignment",[0,1],0)
        var bands=try array(options,"compound",[]);if bands.isEmpty {bands=[0,1]}
        guard bands.count>=2,bands.count%2==0,bands[0]>=0,bands[bands.count-1]<=1,zip(bands,bands.dropFirst()).allSatisfy({$0<$1}) else {throw Self.invalid("invalid compound bands")}
        let dash=try array(options,"dash",[])
        let classicZeros=options.forProperty("classicDashZeros")?.toBool()==true
        guard dash.allSatisfy({classicZeros ? $0>=0:$0>0}),dash.isEmpty || dash.contains(where:{$0>0}) else {throw Self.invalid("invalid dash pattern")}
        guard alignment==0 || (bands==[0,1] && dashCap != 3) else {throw Self.invalid("inset alignment cannot combine with compound or triangle dash caps")}
        let matrix=try array(options,"transform",[1,0,0,1,0,0]),worldValues=try array(options,"world",[1,0,0,1,0,0])
        guard matrix.count==6,worldValues.count==6 else {throw Self.invalid("invalid affine matrix")}
        let pen=CGAffineTransform(a:matrix[0],b:matrix[1],c:matrix[2],d:matrix[3],tx:0,ty:0),world=CGAffineTransform(a:worldValues[0],b:worldValues[1],c:worldValues[2],d:worldValues[3],tx:worldValues[4],ty:worldValues[5])
        let hairline=rawWidth==0,width:CGFloat=hairline ? 1:CGFloat(rawWidth),geometry=hairline ? world:pen.inverted(),output=hairline ? world.inverted():pen
        guard abs(world.a*world.d-world.b*world.c)>1e-14,abs(pen.a*pen.d-pen.b*pen.c)>1e-14 else {throw Self.invalid("singular stroke transform")}
        let device=hairline ? CGAffineTransform.identity:pen.concatenating(world),scale=hypot(device.a,device.b)+hypot(device.c,device.d)
        guard scale.isFinite,scale>0 else {throw Self.invalid("invalid device stroke scale")}
        let tolerance:CGFloat=0.05/max(1e-9,scale),figures=try parse(text,inverse:geometry,tolerance:tolerance,radius:width)
        let storedStart=try customCap(options,"customStart",width:width,tolerance:tolerance),storedEnd=try customCap(options,"customEnd",width:width,tolerance:tolerance)
        guard startCap != 255 || storedStart != nil,endCap != 255 || storedEnd != nil else {throw Self.invalid("missing custom cap object")}
        let customStart=startCap==255 ? storedStart:nil,customEnd=endCap==255 ? storedEnd:nil
        let strokeBands: [CGFloat] = bands.map { CGFloat($0) }
        let dashPattern: [CGFloat] = dash.map { CGFloat($0) }
        let dashOffset = CGFloat(rawOffset)
        let miterLimit = CGFloat(rawLimit)
        let ordinary=CGMutablePath(),inset=CGMutablePath(),closedFill=CGMutablePath()
        let alternate=options.forProperty("classicAlternate")?.toBool()==true
        guard !alternate || (rawWidth==1 && matrix==[1,0,0,1,0,0] && worldValues==[1,0,0,1,0,0]) else {throw Self.invalid("invalid cosmetic alternate mapping")}
        var caps:CGPath=CGMutablePath()
        for figure in figures {
            if alternate {try alternatePixels(figure,to:ordinary);continue}
            if !figure.closed,figure.points.count>1 {
                if let customStart {
                    let shape=try customInk(customStart,at:figure.points[0],direction:unit(sub(figure.points[0],figure.points[1])),width:width,tolerance:tolerance)
                    if !shape.isEmpty {caps=caps.union(shape,using:.winding)}
                }
                if let customEnd {
                    let last=figure.points.count-1
                    let shape=try customInk(customEnd,at:figure.points[last],direction:unit(sub(figure.points[last],figure.points[last-1])),width:width,tolerance:tolerance)
                    if !shape.isEmpty {caps=caps.union(shape,using:.winding)}
                }
            }
            if alignment==1 && figure.closed {
                closedFill.move(to:figure.points[0]);for p in figure.points.dropFirst() {closedFill.addLine(to:p)};closedFill.closeSubpath()
                try outline(figure, width: 2 * width, bands: strokeBands,
                            pattern: dashPattern, offset: dashOffset,
                            startCap: startCap, endCap: endCap, dashCap: dashCap,
                            join: join, limit: miterLimit, tolerance: tolerance,
                            dashWidth: width, to: inset)
            } else {
                try outline(figure, width: width, bands: strokeBands,
                            pattern: dashPattern, offset: dashOffset,
                            startCap: startCap, endCap: endCap, dashCap: dashCap,
                            join: join, limit: miterLimit, tolerance: tolerance,
                            customStart:customStart,customEnd:customEnd,to: ordinary)
            }
        }
        try checkNormalizationBudget()
        var result:CGPath=ordinary.normalized(using:.winding)
        if !caps.isEmpty {result=result.union(caps,using:.winding)}
        if !inset.isEmpty {result=result.union(inset.normalized(using:.winding).intersection(closedFill,using:.evenOdd),using:.winding)}
        var transform=output
        guard let transformed=result.copy(using:&transform) else {throw Self.invalid("could not transform stroke outline")}
        var commands:[String]=[],finalPoints=0,serializationError:ConversionError?
        func coordinate(_ value:CGFloat)->String {String(Double(value))}
        transformed.applyWithBlock { pointer in
            guard serializationError==nil else{return};let element=pointer.pointee,count:Int
            switch element.type {case .moveToPoint,.addLineToPoint:count=1;case .addQuadCurveToPoint:count=2;case .addCurveToPoint:count=3;case .closeSubpath:count=0;@unknown default:serializationError=Self.invalid("unknown native outline element");return}
            finalPoints += count;if finalPoints>131072 {serializationError=Self.invalid("normalized outline budget exceeded");return}
            for i in 0..<count {do {try self.finite(element.points[i])} catch {serializationError=Self.invalid("nonfinite normalized outline");return}}
            let command:String
            switch element.type {
            case .moveToPoint:command="M"+coordinate(element.points[0].x)+" "+coordinate(element.points[0].y)
            case .addLineToPoint:command="L"+coordinate(element.points[0].x)+" "+coordinate(element.points[0].y)
            case .addQuadCurveToPoint:command="Q"+(0..<2).map{coordinate(element.points[$0].x)+" "+coordinate(element.points[$0].y)}.joined(separator:" ")
            case .addCurveToPoint:command="C"+(0..<3).map{coordinate(element.points[$0].x)+" "+coordinate(element.points[$0].y)}.joined(separator:" ")
            default:command="Z"
            }
            self.markupBytes += command.utf8.count;guard self.markupBytes<=32*1024*1024 else {serializationError=Self.invalid("outline markup budget exceeded");return};commands.append(command)
        }
        if let serializationError {throw serializationError}
        let bounds=transformed.boundingBoxOfPath
        var receipt:[String:Any] = ["path":commands.joined(separator:" "),"bounds":transformed.isEmpty ? [0.0,0.0,0.0,0.0]:[Double(bounds.minX),Double(bounds.minY),Double(bounds.maxX),Double(bounds.maxY)]]
        if options.forProperty("retainAliasedCoverage")?.toBool()==true {
            guard coveragePaths.count<4096,coveragePoints<=maximumPoints-finalPoints else {throw Self.invalid("retained stroke coverage limit")}
            coveragePoints += finalPoints
            let id=UUID().uuidString
            coveragePaths[id]=transformed
            receipt["coverageID"]=id
        }
        return receipt
    }
    /// Binary device-lattice coverage of the exact native pen outline. This is
    /// separate from brush alpha so SourceCopy clears only geometric coverage.
    func coverage(_ id:String,options:JSValue)throws->[String:Any] {
        guard options.isObject,let path=coveragePaths[id] else {throw Self.invalid("unknown stroke coverage receipt")}
        let left=number(options,"left",.nan),top=number(options,"top",.nan),w=number(options,"width",.nan),h=number(options,"height",.nan)
        guard left.isFinite,top.isFinite,abs(left)<=1e9,abs(top)<=1e9,w.isFinite,h.isFinite,w>=1,h>=1,w<=32768,h<=32768,w.rounded()==w,h.rounded()==h,w*h<=16777216 else {throw Self.invalid("invalid stroke coverage viewport")}
        let width=Int(w),height=Int(h),pixels=width*height
        guard coveragePixels<=67108864-pixels else {throw Self.invalid("aggregate stroke coverage raster limit")}
        coveragePixels += pixels
        let m=try array(options,"world",[1,0,0,1,0,0])
        guard m.count==6,m.allSatisfy({$0.isFinite && abs($0)<=1e9}),abs(m[0]*m[3]-m[1]*m[2])>1e-14 else {throw Self.invalid("invalid stroke coverage transform")}
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {throw Self.invalid("cannot allocate stroke coverage")}
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.translateBy(x:0,y:CGFloat(height))
        context.scaleBy(x:1,y:-1)
        // GDI+ default aliased coverage samples integer device coordinates.
        context.translateBy(x:CGFloat(-left+0.5),y:CGFloat(-top+0.5))
        context.concatenate(CGAffineTransform(a:m[0],b:m[1],c:m[2],d:m[3],tx:m[4],ty:m[5]))
        context.addPath(path)
        context.setFillColor(red:1,green:1,blue:1,alpha:1)
        context.fillPath(using:.winding)
        guard let image=context.makeImage() else {throw Self.invalid("cannot prepare stroke coverage")}
        let data=NSMutableData()
        guard let encoder=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw Self.invalid("cannot encode stroke coverage")}
        CGImageDestinationAddImage(encoder,image,nil)
        guard CGImageDestinationFinalize(encoder),data.length<=32*1024*1024 else {throw Self.invalid("stroke coverage PNG exceeds limit")}
        return ["href":"data:image/png;base64,"+(data as Data).base64EncodedString(),"width":width,"height":height]
    }
}

/// Native formatted-text geometry only. The renderer retains original semantic
/// UTF-16 text separately and applies the EMF+ rectangle/graphics clip and paint.
private final class NativeTextLayout {
    private var shapedGlyphs = 0, pathElements = 0, pathBytes = 0, textUnits = 0
    private let maximumGlyphs = 262_144, maximumElements = 2_000_000
    private struct Line {
        var value: CTLine
        let start: Int, end: Int, paragraphEnd: Int
        // Typesetter lines retain global UTF-16 indices; trimming creates a new
        // local string. Keep the exact text/range that supplied each CTLine so
        // format controls removed by trimming cannot reappear as painted ink.
        var visualString: NSString, visualRange: NSRange
        var ascent: CGFloat, descent: CGFloat, height: CGFloat, top: CGFloat
    }
    private func invalid(_ message: String) -> ConversionError { .invalid("Formatted metafile text: " + message) }
    private func charge(_ line: CTLine) throws -> CTLine {
        let count = CTLineGetGlyphCount(line)
        guard count <= maximumGlyphs - shapedGlyphs else { throw invalid("aggregate shaped-glyph budget exceeded") }
        shapedGlyphs += count; return line
    }
    private func number(_ options: JSValue, _ key: String, _ fallback: Double = 0) throws -> Double {
        guard let value = options.forProperty(key), !value.isUndefined else { return fallback }
        guard value.isNumber else { throw invalid("non-numeric " + key) }
        let result = value.toDouble()
        guard result.isFinite, abs(result) <= (["flags", "language"].contains(key) ? Double(UInt32.max) : 10_000_000) else { throw invalid("invalid " + key) }; return result
    }
    private func append(_ path: CGPath, to target: CGMutablePath, transform: CGAffineTransform = .identity) throws {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        guard count <= maximumElements - pathElements else { throw invalid("aggregate outline-element budget exceeded") }
        pathElements += count
        let rect = path.boundingBoxOfPath.applying(transform)
        guard rect.isNull || [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else { throw invalid("non-finite glyph outline") }
        target.addPath(path, transform: transform)
    }
    private func svg(_ path: CGPath) throws -> String {
        var result = "", bad = false, bytes = 0
        func coordinate(_ value: CGFloat) -> String {
            guard value.isFinite, abs(value) <= 1_000_000_000 else { bad = true; return "0" }
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
        path.applyWithBlock { element in
            guard !bad else { return }
            let e = element.pointee, count: Int, prefix: String
            switch e.type {
            case .moveToPoint: count = 1; prefix = "M"
            case .addLineToPoint: count = 1; prefix = "L"
            case .addQuadCurveToPoint: count = 2; prefix = "Q"
            case .addCurveToPoint: count = 3; prefix = "C"
            case .closeSubpath: count = 0; prefix = "Z"
            @unknown default: bad = true; return
            }
            var command = prefix
            for index in 0..<count { command += coordinate(e.points[index].x) + " " + coordinate(e.points[index].y) + " " }
            bytes += command.utf8.count
            guard bytes <= 32 * 1024 * 1024 - pathBytes else { bad = true; return }
            result += command
        }
        guard !bad else { throw invalid("invalid or oversized outline output") }
        pathBytes += bytes; return result
    }
    /// Driver strings have already been laid out by their producer. Never send
    /// their characters through CTLine shaping, kerning or font fallback runs.
    func positioned(face:String,size:Double,bold:Bool,italic:Bool,options:JSValue) throws -> [String:Any] {
        guard size.isFinite,size>0,size<=65_536,!face.isEmpty,face.utf8.count<=4096,
              options.isObject,!options.isNull,!options.isUndefined else {throw invalid("invalid positioned font or options")}
        func boolean(_ key:String,_ fallback:Bool=false) throws -> Bool {
            guard let value=options.forProperty(key),!value.isUndefined else{return fallback}
            guard value.isBoolean else {throw invalid("invalid positioned "+key)};return value.toBool()
        }
        func length(_ value:JSValue,_ maximum:Int) throws -> Int {
            guard let count=value.forProperty("length"),count.isNumber else {throw invalid("missing positioned array length")}
            let n=count.toDouble();guard n.isFinite,n>=0,n.rounded()==n,n<=Double(maximum) else {throw invalid("positioned array count limit")};return Int(n)
        }
        func vector(_ value:JSValue) throws -> CGPoint {
            guard value.isArray,try length(value,2)==2 else {throw invalid("invalid positioned vector")}
            var result=[CGFloat]();result.reserveCapacity(2)
            for index in 0..<2 {
                guard let component=value.atIndex(index),component.isNumber else {throw invalid("non-numeric positioned coordinate")}
                let n=component.toDouble();guard n.isFinite,abs(n)<=1_000_000_000 else {throw invalid("positioned coordinate limit")};result.append(CGFloat(n))
            }
            return CGPoint(x:result[0],y:result[1])
        }
        func matrix(_ key:String,ignoreTranslation:Bool=false) throws -> CGAffineTransform {
            guard let value=options.forProperty(key),!value.isUndefined else{return .identity}
            guard value.isArray,try length(value,6)==6 else {throw invalid("invalid positioned "+key)}
            var entries=[CGFloat]();entries.reserveCapacity(6)
            for index in 0..<6 {
                guard let component=value.atIndex(index),component.isNumber else {throw invalid("non-numeric positioned matrix")}
                let n=component.toDouble()
                guard n.isFinite,(ignoreTranslation && index>=4) || abs(n)<=(index<4 ? 10_000_000:1_000_000_000) else {throw invalid("positioned matrix limit")}
                entries.append(ignoreTranslation && index>=4 ? 0:CGFloat(n))
            }
            return CGAffineTransform(a:entries[0],b:entries[1],c:entries[2],d:entries[3],tx:entries[4],ty:entries[5])
        }
        let cmap=try boolean("cmap"),realized=try boolean("realizedAdvance"),vertical=try boolean("vertical"),classic=try boolean("classic")
        _ = try boolean("limitSubpixel") // Vector outlines have no glyph bitmap cache.
        let underline=try boolean("underline"),strikeout=try boolean("strikeout"),cellHeight=try boolean("cellHeight")
        let horizontal=try number(options,"horizontal"),baseline=try number(options,"baseline")
        let characterExtra=try number(options,"characterExtra"),breakSpacing=try number(options,"breakSpacing")
        guard (characterExtra==0 && breakSpacing==0) || (classic && realized && cmap) else {throw invalid("spacing requires realized classic character text")}
        guard [0.0,1,2].contains(horizontal),[0.0,1,2].contains(baseline),
              let values=options.forProperty("values"),let positions=options.forProperty("positions"),positions.isArray else {throw invalid("invalid positioned alignment or arrays")}
        let kind=JSValueGetTypedArrayType(values.context.jsGlobalContextRef,values.jsValueRef,nil)
        guard values.isArray || kind==kJSTypedArrayTypeUint16Array else {throw invalid("positioned values must be UInt16")}
        let count=try length(values,32_768),positionCount=try length(positions,32_768)
        guard positionCount==(realized && count>0 ? 1:count) || (realized && positionCount==count),
              count<=maximumGlyphs-shapedGlyphs,count<=262_144-textUnits else {throw invalid("aggregate positioned glyph/text budget exceeded")}
        var explicitAdvance:CGPoint?
        if let value=options.forProperty("advance"),!value.isUndefined,!value.isNull {explicitAdvance=try vector(value)}
        let glyphMatrix=try matrix("matrix",ignoreTranslation:true),layoutMatrix=try matrix("layoutMatrix",ignoreTranslation:true),outputTransform=try matrix("outputTransform")
        // Validate the complete typed payload before reserving native arrays.
        for index in 0..<count {
            guard let value=values.atIndex(index),value.isNumber else {throw invalid("non-numeric positioned glyph")}
            let n=value.toDouble();guard n.isFinite,n>=0,n<=65535,n.rounded()==n else {throw invalid("positioned glyph is not UInt16")}
        }
        for index in 0..<positionCount {_ = try vector(positions.atIndex(index))}
        shapedGlyphs+=count;textUnits+=count
        var units=[UniChar]();units.reserveCapacity(count)
        for index in 0..<count {units.append(UInt16(values.atIndex(index).toDouble()))}
        var skipped=[Bool](repeating:false,count:count)
        if cmap {
            var index=0
            while index<count {
                let value=units[index]
                if (0xd800...0xdbff).contains(value) {
                    guard index+1<count,(0xdc00...0xdfff).contains(units[index+1]) else {throw invalid("malformed positioned UTF-16")}
                    skipped[index+1]=true;index+=2
                } else {guard !(0xdc00...0xdfff).contains(value) else {throw invalid("malformed positioned UTF-16")};index+=1}
            }
        }
        let requestedFace=face.hasPrefix("@") ? String(face.dropFirst()):face
        var font=CTFontCreateWithName(requestedFace as CFString,size,nil)
        func requestedFont(_ value:CTFont)->Bool {
            let names=[CTFontCopyFamilyName(value),CTFontCopyPostScriptName(value),CTFontCopyFullName(value)].map{$0 as String}
            return names.contains(where:{$0.compare(requestedFace,options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")) == .orderedSame})
        }
        if !cmap,!requestedFont(font) {throw invalid("raw glyph font is not installed: "+face)}
        var traits:CTFontSymbolicTraits=[]
        if bold {traits.insert(.boldTrait)};if italic {traits.insert(.italicTrait)}
        if !traits.isEmpty {
            if let changed=CTFontCreateCopyWithSymbolicTraits(font,CTFontGetSize(font),nil,traits,traits) {font=changed}
            else if !cmap {throw invalid("raw glyph font style is not installed: "+face)}
        }
        if !cmap,!requestedFont(font) {throw invalid("raw glyph font style substituted another family: "+face)}
        if cellHeight {
            let nativeHeight=CTFontGetAscent(font)+CTFontGetDescent(font)
            let adjusted=size*Double(CTFontGetSize(font))/Double(nativeHeight)
            guard nativeHeight.isFinite,nativeHeight>0,adjusted.isFinite,adjusted>0,adjusted<=65_536 else {throw invalid("invalid positioned font cell metrics")}
            font=CTFontCreateCopyWithAttributes(font,adjusted,nil,nil)
        }
        let requestedWidth=try number(options,"averageWidth")
        var widthScale=CGFloat(1)
        if requestedWidth != 0 {
            guard let table=CTFontCopyTable(font,CTFontTableTag(0x4f532f32),[]) as Data?,table.count>=4 else {throw invalid("positioned average width requires OS/2 font metrics")}
            let average=CGFloat(Int16(bitPattern:UInt16(table[2])<<8|UInt16(table[3]))),units=CGFloat(CTFontGetUnitsPerEm(font))
            guard average>0,units>0 else {throw invalid("invalid positioned average-width font metric")}
            // LOGFONT negative width is an absolute requested average width,
            // matching native GDI's font-selection normalization.
            widthScale=CGFloat(abs(requestedWidth))/(average*CTFontGetSize(font)/units)
            guard widthScale.isFinite,widthScale>0,widthScale<=10_000_000 else {throw invalid("positioned average-width scale limit")}
        }
        let ascent=CTFontGetAscent(font),descent=CTFontGetDescent(font)
        guard ascent.isFinite,descent.isFinite,ascent>=0,descent>=0,ascent+descent>0 else {throw invalid("invalid positioned font metrics")}
        var glyphs=[CGGlyph](repeating:0,count:count)
        if cmap {if count>0 {_ = CTFontGetGlyphsForCharacters(font,units,&glyphs,count)}}
        else {glyphs=units}
        // Unicode character lookup may fall outside the requested face's cmap.
        // Keep the chosen font with that scalar's glyph, advance and outline;
        // raw glyph-index records must retain their exact original font.
        var glyphFonts=[CTFont](repeating:font,count:count)
        var glyphLimits=[Int](repeating:CTFontGetGlyphCount(font),count:count)
        var advances=[CGSize](repeating:.zero,count:count)
        if count>0 {_ = CTFontGetAdvancesForGlyphs(font,.horizontal,glyphs,&advances,count)}
        var fallbacks=[UInt32:(font:CTFont,glyph:CGGlyph,advance:CGSize,limit:Int)]()
        if cmap {
            for index in 0..<count where !skipped[index] && glyphs[index]==0 {
                let pair=(0xd800...0xdbff).contains(units[index]),scalar=pair ? 0x10000+(UInt32(units[index])-0xd800)*0x400+UInt32(units[index+1])-0xdc00:UInt32(units[index])
                let entry:(font:CTFont,glyph:CGGlyph,advance:CGSize,limit:Int)
                if let cached=fallbacks[scalar] {entry=cached}
                else {
                    let text=String(decoding:units[index..<(index+(pair ? 2:1))],as:UTF16.self)
                    let fallback=CTFontCreateForString(font,text as CFString,CFRange(location:0,length:pair ? 2:1))
                    guard !(CTFontCopyPostScriptName(fallback) as String).lowercased().contains("lastresort") else {throw invalid("Unicode character has no installed fallback font")}
                    let characters=Array(units[index..<(index+(pair ? 2:1))]),limit=CTFontGetGlyphCount(fallback)
                    var mapped=[CGGlyph](repeating:0,count:characters.count)
                    _ = CTFontGetGlyphsForCharacters(fallback,characters,&mapped,characters.count)
                    guard mapped[0] != 0,Int(mapped[0])<limit else {throw invalid("Unicode character has no native fallback glyph")}
                    var glyph=mapped[0],advance=CGSize.zero
                    _ = CTFontGetAdvancesForGlyphs(fallback,.horizontal,&glyph,&advance,1)
                    entry=(font:fallback,glyph:glyph,advance:advance,limit:limit);fallbacks[scalar]=entry
                }
                glyphFonts[index]=entry.font;glyphs[index]=entry.glyph;advances[index]=entry.advance;glyphLimits[index]=entry.limit
            }
        }
        guard glyphs.enumerated().allSatisfy({skipped[$0.offset] || Int($0.element)<glyphLimits[$0.offset]}) else {throw invalid("raw glyph index exceeds selected font")}
        guard advances.allSatisfy({$0.width.isFinite && $0.height.isFinite && abs($0.width)<=10_000_000 && abs($0.height)<=10_000_000}) else {throw invalid("positioned glyph advance limit")}
        func fontVector(_ x:CGFloat,_ y:CGFloat)->CGPoint {
            // Input uses font y-up. Convert to page y-down, apply the driver's
            // linear matrix, then turn a vertical run clockwise. GDI+'s row
            // order is driver M followed by V (Prepend into the vertical matrix).
            let scaledX=x*widthScale
            let mx=glyphMatrix.a*scaledX-glyphMatrix.c*y,my=glyphMatrix.b*scaledX-glyphMatrix.d*y
            return vertical ? CGPoint(x:-my,y:mx):CGPoint(x:mx,y:my)
        }
        func layoutVector(_ x:CGFloat,_ y:CGFloat)->CGPoint {
            // GDI's escapement controls the baseline separately from each
            // glyph's orientation. The caller maps the complete classic run by
            // escapement; its relative glyph matrix must not rotate advances.
            if !classic {return fontVector(x,y)}
            let px=x*widthScale,py = -y
            return CGPoint(x:layoutMatrix.a*px+layoutMatrix.c*py,y:layoutMatrix.b*px+layoutMatrix.d*py)
        }
        // Windows native WMF playback applies natural character-extra only when
        // that character's resulting advance remains positive. Justification
        // instead clamps a break cell at zero. The break character belongs to
        // the selected font, not an arbitrary Unicode whitespace category.
        var breakCharacter:UniChar=0x20
        if breakSpacing != 0,let table=CTFontCopyTable(font,CTFontTableTag(0x4f532f32),[]) as Data?,table.count>=94 {
            let version=UInt16(table[0])<<8|UInt16(table[1])
            if version>=2 {breakCharacter=UInt16(table[92])<<8|UInt16(table[93])}
        }
        var origins=[CGPoint](repeating:.zero,count:count),cursor=CGPoint.zero,first=CGPoint.zero,lastIndex:Int?
        if count>0 {first=try vector(positions.atIndex(0));cursor=first}
        for index in 0..<count where !skipped[index] {
            if realized {origins[index]=cursor} else {origins[index]=try vector(positions.atIndex(index))}
            lastIndex=index
            var step=layoutVector(advances[index].width,0)
            if realized {
                if characterExtra != 0 && step.x+CGFloat(characterExtra)>0 {step.x+=CGFloat(characterExtra)}
                if breakSpacing != 0 && units[index]==breakCharacter {
                    step.x+=CGFloat(breakSpacing)
                    if step.x<0 {step = .zero}
                }
                cursor.x+=step.x;cursor.y+=step.y
            }
        }
        var advance=CGPoint.zero
        if let explicitAdvance {advance=explicitAdvance}
        else if realized {advance=CGPoint(x:cursor.x-first.x,y:cursor.y-first.y)}
        else if let lastIndex {let step=layoutVector(advances[lastIndex].width,0);advance=CGPoint(x:origins[lastIndex].x-first.x+step.x,y:origins[lastIndex].y-first.y+step.y)}
        guard advance.x.isFinite,advance.y.isFinite,abs(advance.x)<=1_000_000_000,abs(advance.y)<=1_000_000_000 else {throw invalid("positioned run advance limit")}
        let alignFactor=horizontal==1 ? CGFloat(0.5):horizontal==2 ? 1:0
        let baselineShift=baseline==1 ? layoutVector(0,-ascent):baseline==2 ? layoutVector(0,descent):.zero
        let shift=CGPoint(x:baselineShift.x-alignFactor*advance.x,y:baselineShift.y-alignFactor*advance.y)
        let output=CGMutablePath()
        let columnX=fontVector(1,0),columnY=fontVector(0,1)
        for index in 0..<count where !skipped[index] {
            let origin=CGPoint(x:origins[index].x+shift.x,y:origins[index].y+shift.y)
            let transform=CGAffineTransform(a:columnX.x,b:columnX.y,c:columnY.x,d:columnY.y,tx:origin.x,ty:origin.y)
            if let path=CTFontCreatePathForGlyph(glyphFonts[index],glyphs[index],nil) {try append(path,to:output,transform:transform)}
            else {
                var glyph=glyphs[index],rect=CGRect.zero
                _ = CTFontGetBoundingRectsForGlyphs(glyphFonts[index],.horizontal,&glyph,&rect,1)
                guard rect.isNull || rect.isEmpty else {throw invalid("selected positioned glyph has no vector outline")}
            }
        }
        func decoration(_ position:CGFloat,_ thickness:CGFloat) throws {
            guard position.isFinite,thickness.isFinite,thickness>0 else {throw invalid("invalid positioned decoration metrics")}
            let offset=fontVector(0,position),cross=fontVector(0,thickness)
            let indices=(0..<count).filter{!skipped[$0]}
            for (ordinal,index) in indices.enumerated() {
                let start=origins[index],end=ordinal+1<indices.count ? origins[indices[ordinal+1]]:CGPoint(x:first.x+advance.x,y:first.y+advance.y)
                let p=CGPoint(x:start.x+shift.x+offset.x,y:start.y+shift.y+offset.y),q=CGPoint(x:end.x+shift.x+offset.x,y:end.y+shift.y+offset.y)
                let path=CGMutablePath();path.move(to:p);path.addLine(to:q);path.addLine(to:CGPoint(x:q.x+cross.x,y:q.y+cross.y));path.addLine(to:CGPoint(x:p.x+cross.x,y:p.y+cross.y));path.closeSubpath()
                try append(path,to:output)
            }
        }
        if underline {try decoration(CTFontGetUnderlinePosition(font),CTFontGetUnderlineThickness(font))}
        if strikeout {
            guard let table=CTFontCopyTable(font,CTFontTableTag(0x4f532f32),[]) as Data?,table.count>=30 else {throw invalid("positioned strikeout requires OS/2 font metrics")}
            func signed(_ offset:Int)->CGFloat {CGFloat(Int16(bitPattern:UInt16(table[offset])<<8|UInt16(table[offset+1])))*CTFontGetSize(font)/CGFloat(CTFontGetUnitsPerEm(font))}
            let thickness=signed(26);try decoration(signed(28)-thickness,thickness)
        }
        let mapped=CGMutablePath();mapped.addPath(output,transform:outputTransform)
        let bounds=mapped.boundingBoxOfPath
        guard bounds.isNull || [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY].allSatisfy({$0.isFinite && abs($0)<=1_000_000_000}) else {throw invalid("positioned output bounds limit")}
        return ["path":try svg(mapped),"bounds":bounds.isNull ? [0.0,0,0,0]:[Double(bounds.minX),Double(bounds.minY),Double(bounds.maxX),Double(bounds.maxY)],"advance":[Double(advance.x),Double(advance.y)],"ascent":Double(ascent),"descent":Double(descent)]
    }
    func layout(_ original: String, face: String, size: Double, bold: Bool, italic: Bool, options: JSValue) throws -> [String: Any] {
        guard size.isFinite, size > 0, size <= 65_536, face.utf8.count <= 4096,
              original.utf16.count <= 32_768, original.utf16.count <= 262_144 - textUnits,
              !options.isNull, !options.isUndefined, options.isObject else { throw invalid("invalid font, text or options") }
        textUnits += original.utf16.count
        let x = try number(options, "x"), y = try number(options, "y"), width = try number(options, "width"), height = try number(options, "height")
        let rawFlags = try number(options, "flags"), rawAlign = try number(options, "align"), rawLine = try number(options, "line"), rawTrimming = try number(options, "trimming"), rawHotkey = try number(options, "hotkey"), rawStyle = try number(options, "fontStyle"), rawLanguage = try number(options, "language")
        let rawSubstitution = try number(options, "substitution"), rawDigitLanguage = try number(options, "digitLanguage")
        guard width >= 0, height >= 0, rawFlags >= 0, rawFlags <= Double(UInt32.max), rawFlags.rounded() == rawFlags,
              [0.0, 1, 2].contains(rawAlign), [0.0, 1, 2].contains(rawLine), (0...5).contains(Int(rawTrimming)), rawTrimming.rounded() == rawTrimming,
              [0.0, 1, 2].contains(rawHotkey), rawStyle >= 0, rawStyle <= 15, rawStyle.rounded() == rawStyle,
              rawLanguage >= 0, rawLanguage <= Double(UInt16.max), rawLanguage.rounded() == rawLanguage,
              [0.0, 1, 2, 3].contains(rawSubstitution), rawDigitLanguage >= 0, rawDigitLanguage <= Double(UInt16.max),
              rawDigitLanguage.rounded() == rawDigitLanguage else { throw invalid("invalid rectangle, flags, alignment, language or trimming") }
        let flags = UInt32(rawFlags), alignment = Int(rawAlign), lineAlignment = Int(rawLine), trimming = Int(rawTrimming), style = Int(rawStyle)
        guard flags & ~UInt32(0x80007c27) == 0 else { throw invalid("unsupported StringFormat flags") }
        let vertical = flags & 2 != 0, rtl = flags & 1 != 0, noClip = flags & 0x4000 != 0
        let leading = try number(options, "leading") * size, trailing = try number(options, "trailing") * size, tracking = try number(options, "tracking", 1)
        let firstTab = try number(options, "firstTab")
        guard leading >= 0, trailing >= 0, tracking > 0, tracking <= 1000, firstTab >= 0 else { throw invalid("invalid margins, tracking or tab offset") }
        let inlineExtent = vertical ? height : width, crossExtent = vertical ? width : height
        let pointInline = inlineExtent == 0, pointCross = crossExtent == 0
        let available = pointInline ? 10_000_000 : max(0, inlineExtent - leading - trailing)
        let noWrap = flags & 0x1000 != 0 || pointInline, lineLimit = flags & 0x2000 != 0 && !pointCross
        guard leading + trailing <= 10_000_000 else { throw invalid("oversized margins") }
        if original.isEmpty || available == 0 { return ["path": "", "bounds": [x, y, x, y]] }
        var font = CTFontCreateWithName(face as CFString, size, nil), traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }; if italic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let adjusted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = adjusted }
        // Windows GDI+ direct and serialized playback preserve the recorded
        // digit code points in the measured National/Traditional locale and
        // RTL contexts. Do not rewrite them using the host's locale data.
        // Retain the original semantic text; hotkeys affect visual text only.
        var text = original, hotkeyRange: NSRange?
        if rawHotkey != 0 {
            let clusters = text.map(String.init); var output = "", index = 0
            while index < clusters.count {
                if clusters[index] == "&" {
                    if index + 1 < clusters.count {
                        if clusters[index + 1] == "&" { output += "&"; index += 2; continue }
                        if hotkeyRange == nil { hotkeyRange = NSRange(location: output.utf16.count, length: clusters[index + 1].utf16.count) }
                    }
                    index += 1; continue
                }
                output += clusters[index]; index += 1
            }
            text = output
        }
        if text.isEmpty { return ["path": "", "bounds": [x, y, x, y]] }
        var tabLocations: [CGFloat] = [], tabPosition = firstTab, lastTabInterval: Double?
        if let tabs = options.forProperty("tabs"), !tabs.isUndefined {
            guard tabs.isArray, let count = tabs.forProperty("length")?.toDouble(), count >= 0, count <= 256, count.rounded() == count else { throw invalid("invalid tab array") }
            for index in 0..<Int(count) {
                guard let value = tabs.atIndex(index), value.isNumber else { throw invalid("non-numeric tab interval") }
                let interval = value.toDouble()
                guard interval.isFinite, interval > 0, interval <= 10_000_000, tabPosition + interval <= 10_000_000 else { throw invalid("invalid tab interval") }
                tabPosition += interval; tabLocations.append(CGFloat(tabPosition / tracking)); lastTabInterval = interval
            }
        }
        // Explicit stops are cumulative PageUnit distances, not em multiples.
        // The default interval comes from actual shaped spaces in the font.
        let space = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var defaultTab = CGFloat(CTLineGetTypographicBounds(space, nil, nil, nil) * 8)
        guard defaultTab.isFinite, defaultTab > 0 else { throw invalid("font has invalid tab metrics") }
        defaultTab /= tracking
        if tabLocations.isEmpty, firstTab > 0 { tabLocations = [CGFloat(firstTab / tracking)] }
        if let interval = lastTabInterval, text.contains("\t") {
            // Core Text's default interval is zero-phased. Expand the repeated
            // final GDI+ interval explicitly so a nonzero initial offset survives
            // second/third tabs beyond the list of recorded stops.
            let withoutTabs = text.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            let probe = try charge(CTLineCreateWithAttributedString(NSAttributedString(string: withoutTabs, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])))
            let textAdvance = CTLineGetTypographicBounds(probe, nil, nil, nil) * tracking
            let tabCount = text.utf16.filter { $0 == 9 }.count
            let target = min(10_000_000, max(pointInline ? 0 : available, textAdvance + Double(tabCount + 1) * interval + tabPosition))
            while tabPosition <= target {
                guard tabLocations.count < 8192 else { throw invalid("expanded tab-stop budget exceeded") }
                tabPosition += interval; tabLocations.append(CGFloat(tabPosition / tracking))
            }
            defaultTab = CGFloat(interval / tracking)
        }
        let nativeTabs = tabLocations.map { CTTextTabCreate(.left, Double($0), nil) } as CFArray
        var direction: CTWritingDirection = rtl && !vertical ? .rightToLeft : .leftToRight
        let paragraph = withUnsafePointer(to: &direction) { directionPointer in
            withUnsafePointer(to: &defaultTab) { intervalPointer in
                var tabs = nativeTabs
                return withUnsafePointer(to: &tabs) { tabsPointer in
                    let settings = [CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: directionPointer),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabsPointer),
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPointer)]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        // GDI+ DirectionVertical turns a shaped text line into a column. Core
        // Text's VerticalForms is a different layout mode: its runs already have
        // quarter-turn matrices and vertical cell positions. Combining that mode
        // with the column transform below rotates glyphs/positions twice and
        // replaces proportional Latin advances by vertical font cell advances.
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
        if rawLanguage != 0 {
            guard let locale = NSLocale.localeIdentifier(fromWindowsLocaleCode: UInt32(rawLanguage)), !locale.isEmpty else { throw invalid("unsupported Windows language identifier") }
            attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = NSLocale.canonicalLanguageIdentifier(from: locale)
        }
        if style & 4 != 0 { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = 1 }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes), string = text as NSString
        if rawHotkey == 1, let range = hotkeyRange { attributed.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: 1, range: range) }
        // .NET/GDI+ NoFontFallback means missing glyphs in the requested font;
        // MS-EMFPLUS's prose for this bit is contradictory. Bind unsupported
        // clusters to that font's actual .notdef outline instead of substitution.
        if flags & 0x400 != 0 {
            var index = 0
            while index < string.length {
                let range = string.rangeOfComposedCharacterSequence(at: index), part = string.substring(with: range)
                let units = Array(part.utf16); var glyphs = [CGGlyph](repeating: 0, count: units.count)
                let controlsOnly = part.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .format || CharacterSet.controlCharacters.contains($0) }
                if !controlsOnly, !CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) {
                    guard let info = CTGlyphInfoCreateWithGlyph(0, font, part as CFString) else { throw invalid("font cannot represent a missing-character glyph") }
                    attributed.addAttribute(NSAttributedString.Key(kCTGlyphInfoAttributeName as String), value: info, range: range)
                }
                index = NSMaxRange(range)
            }
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let baseAscent = CTFontGetAscent(font), baseDescent = CTFontGetDescent(font), baseLeading = CTFontGetLeading(font)
        guard [baseAscent, baseDescent, baseLeading].allSatisfy({ $0.isFinite }), baseAscent + baseDescent + baseLeading > 0 else { throw invalid("invalid font line metrics") }
        var lines: [Line] = [], cursor = 0, top: CGFloat = 0
        while cursor < string.length {
            guard lines.count < 8192 else { throw invalid("line-count budget exceeded") }
            var paragraphStart = 0, paragraphEnd = 0, contentEnd = 0
            string.getLineStart(&paragraphStart, end: &paragraphEnd, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            var count = noWrap ? contentEnd - cursor : min(contentEnd - cursor, CTTypesetterSuggestLineBreak(typesetter, cursor, available / tracking))
            if count == 0, cursor < contentEnd { count = string.rangeOfComposedCharacterSequence(at: cursor).length }
            let end = cursor + count
            // Core Text interprets a zero-length range as "to the end", not an
            // empty paragraph. Blank lines still advance actual base-font metrics.
            let line = try charge(count == 0 ? CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes)) : CTTypesetterCreateLine(typesetter, CFRange(location: cursor, length: count)))
            var ascent: CGFloat = 0, descent: CGFloat = 0, nativeLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &nativeLeading)
            if count == 0 { ascent = baseAscent; descent = baseDescent; nativeLeading = baseLeading }
            let lineHeight = ascent + descent + nativeLeading
            guard [ascent, descent, lineHeight].allSatisfy({ $0.isFinite }), lineHeight > 0 else { throw invalid("invalid shaped line metrics") }
            if !pointCross, lineLimit ? top + ascent + descent > crossExtent : (!noClip && top >= crossExtent) { break }
            lines.append(Line(value: line, start: cursor, end: end, paragraphEnd: contentEnd, visualString: string, visualRange: NSRange(location: cursor, length: count), ascent: ascent, descent: descent, height: lineHeight, top: top))
            top += lineHeight
            cursor = end == contentEnd ? paragraphEnd : end
        }
        // Trimming belongs to the last visible/partly-visible line only.
        if trimming != 0, !lines.isEmpty {
            let index = lines.count - 1, last = lines[index]
            let overflow = CTLineGetTypographicBounds(last.value, nil, nil, nil) * tracking > available || cursor < string.length
            if overflow {
                let range = NSRange(location: last.start, length: last.paragraphEnd - last.start)
                let source = attributed.attributedSubstring(from: range), value = source.string as NSString
                let ellipsis = trimming >= 3 ? NSAttributedString(string: "…", attributes: attributes) : NSAttributedString(string: "", attributes: attributes)
                let tokenWidth = CTLineGetTypographicBounds(try charge(CTLineCreateWithAttributedString(ellipsis)), nil, nil, nil) * tracking
                var boundaries = [0], position = 0
                while position < value.length { position = NSMaxRange(value.rangeOfComposedCharacterSequence(at: position)); boundaries.append(position) }
                if trimming == 2 || trimming == 4 {
                    var words = [0]
                    source.string.enumerateSubstrings(in: source.string.startIndex..<source.string.endIndex, options: [.byWords, .substringNotRequired]) { _, _, end, _ in words.append(NSRange(source.string.startIndex..<end.upperBound, in: source.string).length) }
                    boundaries = Array(Set(words)).sorted()
                }
                func candidate(_ count: Int, suffix: Int = 0) -> NSAttributedString {
                    let result = NSMutableAttributedString(attributedString: source.attributedSubstring(from: NSRange(location: 0, length: count)))
                    result.append(ellipsis)
                    if suffix > 0 { result.append(source.attributedSubstring(from: NSRange(location: value.length - suffix, length: suffix))) }
                    return result
                }
                var chosen = try charge(CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes)))
                var chosenText = ""
                if tokenWidth <= available {
                    if trimming == 5 {
                        // Prefer the tail of a path, preserving its final component
                        // whenever it fits; binary search uses composed clusters.
                        var low = 0, high = boundaries.count - 1, suffixIndex = value.length
                        while low <= high {
                            let mid = (low + high) / 2, start = boundaries[mid]
                            let line = try charge(CTLineCreateWithAttributedString(candidate(0, suffix: value.length - start)))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { suffixIndex = start; high = mid - 1 } else { low = mid + 1 }
                        }
                        let suffix = value.length - suffixIndex
                        low = 0; high = boundaries.firstIndex(of: suffixIndex) ?? 0
                        while low <= high {
                            let mid = (low + high) / 2, count = boundaries[mid], candidateText = candidate(count, suffix: suffix), line = try charge(CTLineCreateWithAttributedString(candidateText))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { chosen = line; chosenText = candidateText.string; low = mid + 1 } else { high = mid - 1 }
                        }
                    } else {
                        var low = 0, high = boundaries.count - 1
                        while low <= high {
                            let mid = (low + high) / 2, candidateText = candidate(boundaries[mid]), line = try charge(CTLineCreateWithAttributedString(candidateText))
                            if CTLineGetTypographicBounds(line, nil, nil, nil) * tracking <= available { chosen = line; chosenText = candidateText.string; low = mid + 1 } else { high = mid - 1 }
                        }
                    }
                }
                lines[index].value = chosen
                lines[index].visualString = chosenText as NSString
                lines[index].visualRange = NSRange(location: 0, length: (chosenText as NSString).length)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(chosen, &ascent, &descent, &leading)
                if ascent + descent + leading > 0 {
                    guard [ascent, descent, leading].allSatisfy({ $0.isFinite }) else { throw invalid("invalid trimmed line metrics") }
                    lines[index].ascent = ascent; lines[index].descent = descent; lines[index].height = ascent + descent + leading
                }
            }
        }
        let block = lines.last.map { $0.top + $0.ascent + $0.descent } ?? 0
        // A zero extent is unbounded for fitting, but remains zero for alignment.
        // Center/Far can deliberately position ink before the anchor or above a
        // rectangle shorter than the shaped line; the graphics clip decides what
        // remains visible. Clamping would silently turn those alignments to Near.
        let crossOffset = (CGFloat(crossExtent) - block) * CGFloat(lineAlignment) / 2
        let output = CGMutablePath(); var measurement = CGRect.null
        for item in lines {
            let line = item.value, local = CGMutablePath()
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) * tracking)
            let trailingSpace = CGFloat(CTLineGetTrailingWhitespaceWidth(line) * tracking)
            let measuredWidth = flags & 0x800 != 0 ? width : max(0, width - trailingSpace)
            let effectiveAlignment = rtl && !vertical ? 2 - alignment : alignment
            var inlineOffset = CGFloat(leading) + ((pointInline ? 0 : CGFloat(available)) - measuredWidth) * CGFloat(effectiveAlignment) / 2
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run), runAttributes = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = runAttributes[kCTFontAttributeName] else { throw invalid("shaped run has no font") }
                let runFont = fontValue as! CTFont
                if flags & 0x400 != 0, CTFontCopyPostScriptName(runFont) as String != CTFontCopyPostScriptName(font) as String { throw invalid("requested no-fallback font could not supply its missing-glyph outline") }
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count), advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions); CTRunGetAdvances(run, CFRange(), &advances)
                let matrix = CTRunGetTextMatrix(run)
                guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy({ $0.isFinite }) else { throw invalid("invalid run text matrix") }
                var minimum = CGFloat.infinity, maximum = -CGFloat.infinity
                for index in 0..<count {
                    let position = positions[index]
                    guard position.x.isFinite, position.y.isFinite, advances[index].width.isFinite else { throw invalid("invalid glyph position") }
                    minimum = min(minimum, position.x * tracking); maximum = max(maximum, (position.x + advances[index].width) * tracking)
                    if let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil), !outline.isEmpty {
                        var transform = matrix; transform.tx += position.x * tracking; transform.ty += position.y
                        try append(outline, to: local, transform: transform)
                    } else {
                        // Real font bounds distinguish non-ink spaces/controls
                        // from visible bitmap/color glyphs, even after truncation
                        // changes string indices (middle ellipsis and path tail).
                        var glyph = glyphs[index]
                        let ink = CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &glyph, nil, 1)
                        guard ink.isNull || ink.isEmpty else { throw invalid("visible glyph has no vector outline (color/bitmap fonts are unsupported)") }
                    }
                }
                if minimum.isFinite, maximum > minimum {
                    if ((runAttributes[kCTUnderlineStyleAttributeName] as? NSNumber)?.intValue ?? 0) != 0 {
                        let thickness = CTFontGetUnderlineThickness(runFont), position = CTFontGetUnderlinePosition(runFont)
                        guard thickness.isFinite, thickness > 0, position.isFinite else { throw invalid("invalid underline font metrics") }
                        try append(CGPath(rect: CGRect(x: minimum, y: position, width: maximum - minimum, height: thickness), transform: nil), to: local)
                    }
                    if style & 8 != 0 {
                        guard let table = CTFontCopyTable(runFont, CTFontTableTag(0x4f532f32), []) as Data?, table.count >= 30 else { throw invalid("strikeout requires OS/2 font metrics") }
                        func signed(_ offset: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(table[offset]) << 8 | UInt16(table[offset + 1]))) * CTFontGetSize(runFont) / CGFloat(CTFontGetUnitsPerEm(runFont)) }
                        let thickness = signed(26), position = signed(28)
                        guard thickness > 0, thickness.isFinite, position.isFinite else { throw invalid("invalid strikeout font metrics") }
                        try append(CGPath(rect: CGRect(x: minimum, y: position - thickness, width: maximum - minimum, height: thickness), transform: nil), to: local)
                    }
                }
            }
            if flags & 4 == 0, !pointInline, !local.isEmpty {
                let bounds = local.boundingBoxOfPath
                if inlineOffset + bounds.minX < leading { inlineOffset = CGFloat(leading) - bounds.minX }
                if inlineOffset + bounds.maxX > inlineExtent - trailing { inlineOffset -= min(inlineOffset + bounds.maxX - CGFloat(inlineExtent - trailing), max(0, inlineOffset + bounds.minX - CGFloat(leading))) }
            }
            if flags & 0x20 != 0 {
                // DisplayFormatControl exposes the selected font's actual cmap
                // outlines without replacing Unicode characters or splitting
                // shaped runs. Glyph-info substitution changes Arabic joining
                // and is ignored for some joiners. These zero-advance overlays
                // deliberately follow FitBlackBox alignment, preserving the
                // original line's advance and baseline placement.
                // In the measured Windows DrawString/serialized-replay
                // contexts, joiners expose their cmap ink only when the whole
                // visual DrawString consists of that one control. A joiner in
                // Latin, separated or Arabic text retains ordinary shaping.
                // Use the pre-wrap/pre-trim visual text, never a lone remainder
                // produced by line breaking or truncation.
                let loneJoiner = string.length == 1 && (string.character(at: 0) == 0x200c || string.character(at: 0) == 0x200d)
                for index in item.visualRange.location..<NSMaxRange(item.visualRange) {
                    let unit = item.visualString.character(at: index)
                    guard unit == 0x200e || unit == 0x200f || (loneJoiner && (unit == 0x200c || unit == 0x200d)) else { continue }
                    var character = unit, glyph: CGGlyph = 0
                    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
                          let outline = CTFontCreatePathForGlyph(font, glyph, nil), !outline.isEmpty else { continue }
                    guard shapedGlyphs < maximumGlyphs else { throw invalid("aggregate shaped-glyph budget exceeded") }
                    shapedGlyphs += 1
                    let offset = CTLineGetOffsetForStringIndex(line, index, nil) * tracking
                    guard offset.isFinite else { throw invalid("invalid format-control position") }
                    try append(outline, to: local, transform: CGAffineTransform(translationX: offset, y: 0))
                }
            }
            let transform: CGAffineTransform
            if vertical {
                let column = rtl ? CGFloat(crossExtent) - crossOffset - item.top - item.ascent : crossOffset + item.top + item.descent
                transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: CGFloat(x) + column, ty: CGFloat(y) + inlineOffset)
            } else { transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: CGFloat(x) + inlineOffset, ty: CGFloat(y) + crossOffset + item.top + item.ascent) }
            // Elements were charged on their original glyphs, not a second time
            // when moving the completed line into absolute rectangle coordinates.
            output.addPath(local, transform: transform)
            if flags & 0x800 != 0 {
                let rect = CGRect(x: 0, y: -item.descent, width: measuredWidth, height: item.ascent + item.descent).applying(transform)
                measurement = measurement.union(rect)
            }
        }
        let bounds = output.isEmpty ? measurement : output.boundingBoxOfPath.union(measurement)
        guard bounds.isNull || [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else { throw invalid("non-finite text bounds") }
        return ["path": try svg(output), "bounds": bounds.isNull ? [x, y, x, y] : [Double(bounds.minX), Double(bounds.minY), Double(bounds.maxX), Double(bounds.maxY)]]
    }
}
private func run() throws {
    // System JavaScriptCore supports interpreter-only execution. Set this before
    // creating any context/VM so hardened helpers need no executable-memory/JIT
    // entitlement, including when invoked with inherited App Store sandboxing.
    setenv("JSC_useJIT", "false", 1)
    guard CommandLine.arguments.count == 2, ["--wmf", "--emf"].contains(CommandLine.arguments[1]) else {
        throw ConversionError.invalid("Usage: metafile-convert --wmf|--emf (binary stdin, SVG stdout)")
    }
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard chunk.count <= inputLimit - input.count else { throw ConversionError.invalid("Metafile exceeds 64 MiB") }
        input.append(chunk)
    }
    guard !input.isEmpty, let context = JSContext(), let sourceURL = rendererURL() else {
        throw ConversionError.invalid("Missing metafile input or packaged renderer")
    }
    var exception: String?
    context.exceptionHandler = { _, value in exception = value?.toString() ?? "JavaScript rendering failed" }
    func nativeError(_ text: String) { context.exception = JSValue(newErrorFromMessage: text, in: context) }
    let decode: @convention(block) (JSValue, String) -> String = { value, encoding in
        guard let bytes = data(value) else { nativeError("Invalid text bytes"); return "" }
        let names: [String: CFStringEncoding] = ["shift_jis": CFStringEncoding(CFStringEncodings.shiftJIS.rawValue),
            "euc-kr": CFStringEncoding(CFStringEncodings.EUC_KR.rawValue), "gbk": CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue),
            "big5": CFStringEncoding(CFStringEncodings.big5.rawValue),
            "windows-932": CFStringEncoding(CFStringEncodings.dosJapanese.rawValue),
            "windows-936": CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue),
            "windows-949": CFStringEncoding(CFStringEncodings.dosKorean.rawValue),
            "windows-950": CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue),
            "windows-437": CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)]
        let label = encoding.lowercased()
        if label=="windows-1361" {
            do {return try decodeJohab(bytes)}
            catch {nativeError("Invalid encoded Johab text");return ""}
        }
        let swiftEncoding: String.Encoding
        if label == "utf-8" || label == "utf8" { swiftEncoding = .utf8 }
        else if label == "utf-16le" { swiftEncoding = .utf16LittleEndian }
        else if ["windows-1250", "windows-1251", "windows-1252", "windows-1253", "windows-1254", "windows-1255", "windows-1256", "windows-1257", "windows-1258", "windows-874"].contains(label) {
            let code = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            guard code != kCFStringEncodingInvalidId else { nativeError("Unsupported Windows charset: " + label); return "" }
            swiftEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(code))
        }
        else if let code = names[label] { swiftEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(code)) }
        else { nativeError("Unsupported text encoding: " + encoding); return "" }
        guard let text = String(data: bytes, encoding: swiftEncoding) else { nativeError("Invalid encoded text"); return "" }
        return text
    }
    let base64: @convention(block) (JSValue) -> String = { value in
        guard let bytes = data(value) else { nativeError("Invalid base64 bytes"); return "" }; return bytes.base64EncodedString()
    }
    let measure: @convention(block) (String, String, Double, Bool, Bool) -> Double = { text, face, size, bold, italic in
        guard size.isFinite, size > 0, size <= 65536, text.utf8.count <= inputLimit else { nativeError("Invalid font metrics"); return 0 }
        var font = CTFontCreateWithName(face as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }; if italic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let adjusted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = adjusted }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
    let textLayout = NativeTextLayout()
    let layoutText: @convention(block) (String, String, Double, Bool, Bool, JSValue) -> NSDictionary = { text, face, size, bold, italic, options in
        do { return try textLayout.layout(text, face: face, size: size, bold: bold, italic: italic, options: options) as NSDictionary }
        catch ConversionError.invalid(let message) { nativeError(message); return [:] }
        catch { nativeError("Formatted metafile text layout failed: " + String(describing: error)); return [:] }
    }
    let positionedText:@convention(block) (String,Double,Bool,Bool,JSValue)->NSDictionary = {face,size,bold,italic,options in
        do {return try textLayout.positioned(face:face,size:size,bold:bold,italic:italic,options:options) as NSDictionary}
        catch ConversionError.invalid(let message) {nativeError(message);return [:]}
        catch {nativeError("Positioned metafile glyph layout failed: "+String(describing:error));return [:]}
    }
    let strokeGeometry = NativeStrokeGeometry()
    let strokePath: @convention(block) (String, JSValue) -> NSDictionary = { path, options in
        do { return try strokeGeometry.stroke(path, options: options) as NSDictionary }
        catch ConversionError.invalid(let message) { nativeError(message); return [:] }
        catch { nativeError("Metafile pen geometry failed: " + String(describing: error)); return [:] }
    }
    let strokeCoverage:@convention(block)(String,JSValue)->NSDictionary = { id,options in
        do {return try strokeGeometry.coverage(id,options:options) as NSDictionary}
        catch ConversionError.invalid(let message) {nativeError(message);return [:]}
        catch {nativeError("Metafile stroke coverage failed: "+String(describing:error));return [:]}
    }
    let regionGeometry=NativeRegionGeometry()
    let regionPath:@convention(block)(JSValue,Double,Double,Bool)->NSDictionary = {rectangles,width,height,frame in
        do{return try regionGeometry.path(rectangles,width,height,frame) as NSDictionary}
        catch ConversionError.invalid(let message){nativeError(message);return [:]}
        catch{nativeError("Metafile region geometry failed: "+String(describing:error));return [:]}
    }
    let rasterCompositor=NativeRasterComposite()
    let embeddedScope:@convention(block)(Bool)->Void = {entering in
        do {try rasterCompositor.embeddedScope(entering)}
        catch ConversionError.invalid(let message){nativeError(message)}
        catch{nativeError("Embedded metafile scope failed")}
    }
    let embeddedImage:@convention(block)(JSValue,Double,Double)->String = {scene,width,height in
        do {return try rasterCompositor.embeddedImage(scene,width,height)}
        catch ConversionError.invalid(let message){nativeError(message);return ""}
        catch{nativeError("Embedded metafile raster failed");return ""}
    }
    let rasterComposite:@convention(block)(JSValue,JSValue,JSValue,JSValue,Double,Double,Double,JSValue)->NSObject = {destination,source,pattern,coverage,width,height,rop,request in
        do{return try autoreleasepool{try rasterCompositor.composite(destination,source,pattern,coverage,width,height,rop,request)}}
        catch ConversionError.invalid(let message){nativeError(message);return "" as NSString}
        catch{nativeError("Metafile raster operation failed: "+String(describing:error));return "" as NSString}
    }
    let floodCoverage:@convention(block)(JSValue,JSValue,Double,Double,Double,Double,Double,Double)->String = {destination,clip,width,height,x,y,color,mode in
        do{return try autoreleasepool{try rasterCompositor.flood(destination,clip,width,height,x,y,color,mode)}}
        catch ConversionError.invalid(let message){nativeError(message);return ""}
        catch{nativeError("Metafile flood operation failed: "+String(describing:error));return ""}
    }
    let rasterTransfer:@convention(block)(JSValue,JSValue,JSValue,JSValue,JSValue,Double,Double,JSValue,JSValue)->NSObject = {destination,source,pattern,coverage,selection,width,height,options,request in
        do{return try autoreleasepool{try rasterCompositor.transfer(destination,source,pattern,coverage,selection,width,height,options,request)}}
        catch ConversionError.invalid(let message){nativeError(message);return "" as NSString}
        catch{nativeError("Metafile raster transfer failed: "+String(describing:error));return "" as NSString}
    }
    var decodedBitmapPixels=0
    // The optional sixth argument contains EmfPlusPalette ARGB values. Existing
    // gradient/hatch callers have no palette and continue to pass five arguments.
    let bitmap: @convention(block) (JSValue, Int, Int, Int, UInt32, JSValue) -> String = { value, width, height, stride, format, paletteValue in
        guard width > 0, height > 0, width <= 32768, height <= 32768, width <= 16777216 / height,
              stride != Int.min, stride != 0, abs(stride) <= inputLimit / height else { nativeError("Invalid or oversized metafile bitmap"); return "" }
        // GDI+ PixelFormat values encode bits-per-pixel in bits 8...15.
        let bits = Int((format >> 8) & 255)
        // MS-EMFPLUS 2.1.1.24 names 0x1A400E for PARGB64; the public
        // Microsoft GDI+ SDK names 0x1C400E. Both exact encodings describe the
        // same premultiplied channel layout; do not infer alpha from flags alone.
        guard [UInt32(0x30101),0x30402,0x30803,0x101004,0x21005,0x21006,0x61007,0x21808,0x22009,0x26200A,0xE200B,0x10300C,0x34400D,0x1A400E,0x1C400E].contains(format) else { nativeError("Unsupported metafile pixel format"); return "" }
        guard abs(stride) >= (width * bits + 7) / 8, abs(stride).isMultiple(of:4),
              let raw=data(value),raw.count == abs(stride) * height else {nativeError("Invalid metafile bitmap stride or pixel count");return ""}
        var palette:[UInt32]=[]
        if bits <= 8 {
            guard !paletteValue.isUndefined,!paletteValue.isNull,let countValue=paletteValue.forProperty("length") else {nativeError("Missing metafile bitmap palette");return ""}
            let length=countValue.toDouble()
            guard length.isFinite,length.rounded() == length,length >= 1,length <= Double(1 << bits) else {nativeError("Invalid metafile bitmap palette count");return ""}
            for index in 0..<Int(length) {
                guard let entry=paletteValue.atIndex(index),entry.isNumber else {nativeError("Invalid metafile bitmap palette entry");return ""}
                let color=entry.toDouble()
                guard color.isFinite,color.rounded() == color,color >= 0,color <= Double(UInt32.max) else {nativeError("Invalid metafile bitmap palette color");return ""}
                palette.append(UInt32(color))
            }
        }
        // Bound total native expansion, including generated gradient/hatch cells,
        // before allocating the per-bitmap RGBA representation.
        let pixels=width * height
        guard pixels <= 67108864-decodedBitmapPixels else {nativeError("Metafile bitmap expansion budget exceeded");return ""}
        decodedBitmapPixels += pixels
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            let row = (stride < 0 ? height - 1 - y : y) * abs(stride)
            for x in 0..<width {
                let end = (y * width + x) * 4
                if bits <= 8 {
                    let byte=raw[row + x * bits / 8]
                    let index=Int(bits == 1 ? (byte >> (7-x%8)) & 1:bits == 4 ? (byte >> (x%2 == 0 ? 4:0)) & 15:byte)
                    guard index < palette.count else {nativeError("Metafile bitmap palette index exceeds count");return ""}
                    let color=palette[index]
                    rgba[end]=UInt8(truncatingIfNeeded:color>>16);rgba[end+1]=UInt8(truncatingIfNeeded:color>>8);rgba[end+2]=UInt8(truncatingIfNeeded:color);rgba[end+3]=UInt8(truncatingIfNeeded:color>>24)
                }else if format == 0x101004 {
                    // Raw playback follows the documented Wine GDI+ channel
                    // layout: little-endian WORD, high-byte display projection.
                    // This is not a guessed 13-bit LockBits normalization.
                    let gray=raw[row+x*2+1]
                    rgba[end]=gray;rgba[end+1]=gray;rgba[end+2]=gray;rgba[end+3]=255
                }else if bits == 48 || bits == 64 {
                    // B,G,R,[A] WORDs. Quantize each channel before native
                    // compositing, including premultiplied alpha. Low bytes are
                    // intentionally not rounded into their display high bytes.
                    let start=row+x*(bits/8),alpha:UInt8=bits == 64 ? raw[start+7]:255
                    rgba[end]=raw[start+5];rgba[end+1]=raw[start+3];rgba[end+2]=raw[start+1];rgba[end+3]=alpha
                    if (format == 0x1A400E || format == 0x1C400E) && alpha == 0 {
                        rgba[end]=0;rgba[end+1]=0;rgba[end+2]=0
                    }
                }else if bits == 16 {
                    let start=row+x*2,word=UInt16(raw[start]) | UInt16(raw[start+1]) << 8
                    let is565=format == 0x21006
                    let red=(word >> (is565 ? 11:10)) & 31,green=(word >> 5) & (is565 ? 63:31),blue=word & 31
                    rgba[end]=UInt8((red<<3)|(red>>2));rgba[end+1]=UInt8(is565 ? (green<<2)|(green>>4):(green<<3)|(green>>2));rgba[end+2]=UInt8((blue<<3)|(blue>>2))
                    rgba[end+3]=format == 0x61007 && word & 0x8000 == 0 ? 0:255
                }else {
                    let start=row+x*(bits/8)
                    rgba[end] = raw[start + 2]; rgba[end + 1] = raw[start + 1]; rgba[end + 2] = raw[start]
                    rgba[end + 3] = bits == 32 && (format & 0x40000) != 0 ? raw[start + 3] : 255
                }
            }
        }
        let alpha: CGImageAlphaInfo = format & 0x80000 != 0 ? .premultipliedLast : .last
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: rgba as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { nativeError("Cannot decode metafile bitmap"); return "" }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { nativeError("Cannot encode metafile bitmap"); return "" }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= outputLimit / 2 else { nativeError("Metafile bitmap output exceeds limit"); return "" }
        return "data:image/png;base64," + (output as Data).base64EncodedString()
    }
    func compressedImage(_ value:JSValue,classicOpaque:Bool,raster:Bool=false)->NSDictionary {
        guard let raw = data(value), raw.count >= 8,
              raw.count <= inputLimit,
              let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let kind = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier,UTType.jpeg.identifier,UTType.gif.identifier,UTType.tiff.identifier].contains(kind),
              (!classicOpaque || kind == UTType.png.identifier || kind == UTType.jpeg.identifier),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) >= 1,CGImageSourceGetCount(source) <= 512,
              (CGImageSourceGetCount(source) == 1 || !classicOpaque && [UTType.tiff.identifier,UTType.gif.identifier].contains(kind)) else {
            nativeError("Invalid or oversized compressed metafile image");return [:]
        }
        let frames=CGImageSourceGetCount(source),selectedFrame:Int
        do {if kind == UTType.gif.identifier {let animated=try compressedGIFIsAnimated(raw);selectedFrame=animated ? 0:frames-1}else{selectedFrame=0}}
        catch {nativeError("Invalid compressed GIF frame controls");return [:]}
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, selectedFrame, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, width <= 16777216 / height else {
            nativeError("Invalid or oversized compressed metafile image"); return [:]
        }
        let pixels = width * height,dependencies=kind == UTType.gif.identifier && selectedFrame>0 ? frames:1
        guard pixels <= (67108864-decodedBitmapPixels)/dependencies else {nativeError("Metafile bitmap expansion budget exceeded");return [:]}
        decodedBitmapPixels += pixels*dependencies
        // ImageIO returns the complete logical GIF canvas at the chosen index,
        // including preceding delta rectangles, transparency and disposal.
        guard let decoded = CGImageSourceCreateImageAtIndex(source, selectedFrame, [kCGImageSourceShouldCacheImmediately: !classicOpaque] as CFDictionary),CGImageSourceGetStatusAtIndex(source,selectedFrame) == .statusComplete,decoded.width == width,decoded.height == height else {
            nativeError("Invalid compressed metafile image pixels");return [:]
        }
        let image:CGImage
        do {image=classicOpaque ? try classicOpaqueCompressedImage(decoded):decoded}
        catch ConversionError.invalid(let message) {nativeError(message);return [:]}
        catch {nativeError("Cannot preserve classic compressed image colors");return [:]}
        if raster {
            var rgba = Data(count: pixels * 4)
            let prepared = rgba.withUnsafeMutableBytes { storage -> Bool in
                guard let space=CGColorSpace(name:CGColorSpace.sRGB),let canvas=CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
                canvas.interpolationQuality = .none;canvas.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
            }
            guard prepared else {nativeError("Cannot prepare compressed raster pixels");return [:]}
            for offset in stride(from:3,to:rgba.count,by:4){rgba[offset]=255}
            return ["rgba":rgba.base64EncodedString(),"width":width,"height":height]
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            nativeError("Cannot encode compressed metafile image"); return [:]
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= outputLimit / 2 else {
            nativeError("Compressed metafile image output exceeds limit"); return [:]
        }
        return ["href": "data:image/png;base64," + (output as Data).base64EncodedString(), "width": width, "height": height]
    }
    let imageEffects=NativeImageEffects()
    let applyImageEffect:@convention(block)(String,JSValue)->String = {href,effect in
        do {return try imageEffects.apply(href,effect:effect)}
        catch ConversionError.invalid(let message) {nativeError(message);return ""}
        catch {nativeError("Cannot apply metafile image effect");return ""}
    }
    context.setObject(applyImageEffect,forKeyedSubscript:"turtleGitApplyImageEffect" as NSString)
    let applySpatialImageEffect:@convention(block)(String,JSValue,JSValue)->NSDictionary = {href,effect,sourceRect in
        do {return try imageEffects.applySpatial(href,effect:effect,sourceRect:sourceRect)}
        catch ConversionError.invalid(let message) {nativeError(message);return [:]}
        catch {nativeError("Cannot apply spatial metafile image effect");return [:]}
    }
    context.setObject(applySpatialImageEffect,forKeyedSubscript:"turtleGitApplySpatialImageEffect" as NSString)
    let sampleSpatialImage:@convention(block)(String,JSValue)->NSDictionary = {href,geometry in
        do {return try imageEffects.sampleSpatial(href,geometry:geometry)}
        catch {nativeError("Cannot sample spatial image: "+String(describing:error));return [:]}
    }
    context.setObject(sampleSpatialImage,forKeyedSubscript:"turtleGitSampleSpatialImage" as NSString)
    let planPicture:@convention(block)(Double,Double)->Bool = {width,height in
        do {
            guard width.isFinite,height.isFinite,width.rounded()==width,height.rounded()==height,width>=1,height>=1 else {throw ConversionError.invalid("Invalid Picture plan dimensions")}
            guard width<=32768,height<=32768,width*height<=16_777_216 else {throw ConversionError.invalid("Picture raster dimension/pixel budget exceeded")}
            return try imageEffects.pictureNeeded(width:Int(width),height:Int(height))
        }catch {nativeError("Cannot plan Picture document: "+String(describing:error));return false}
    }
    context.setObject(planPicture,forKeyedSubscript:"__turtlePicturePlan" as NSString)
    let samplePicture:@convention(block)(JSValue,Double,Double)->String = {scene,width,height in
        do {
            guard width.isFinite,height.isFinite,width.rounded()==width,height.rounded()==height,width>=1,height>=1 else {throw ConversionError.invalid("Invalid Picture raster dimensions")}
            guard width<=32768,height<=32768,width*height<=16_777_216 else {throw ConversionError.invalid("Picture raster dimension/pixel budget exceeded")}
            let w=Int(width),h=Int(height)
            guard try imageEffects.pictureNeeded(width:w,height:h) else {return ""}
            let pixels=try rasterCompositor.picturePixels(scene,width:w,height:h)
            return try imageEffects.samplePicture(pixels,width:w,height:h)
        }catch {nativeError("Cannot sample Picture document: "+String(describing:error));return ""}
    }
    context.setObject(samplePicture,forKeyedSubscript:"__turtlePictureSample" as NSString)
    let prepareOrdinaryImage:@convention(block)(String,Bool)->String = {href,effectPipeline in
        do {return try imageEffects.prepareOrdinary(href,effectPipeline:effectPipeline)}
        catch ConversionError.invalid(let message) {nativeError(message);return ""}
        catch {nativeError("Cannot prepare metafile bitmap playback");return ""}
    }
    context.setObject(prepareOrdinaryImage,forKeyedSubscript:"turtleGitPrepareImage" as NSString)
    let compressed:@convention(block)(JSValue)->NSDictionary = {compressedImage($0,classicOpaque:false)}
    let compressedClassic:@convention(block)(JSValue)->NSDictionary = {compressedImage($0,classicOpaque:true)}
    context.setObject(compressed, forKeyedSubscript: "__turtleCompressedImage" as NSString)
    context.setObject(compressedClassic,forKeyedSubscript:"__turtleCompressedClassicImage" as NSString)
    let compressedRaster:@convention(block)(JSValue)->NSDictionary = {compressedImage($0,classicOpaque:true,raster:true)}
    context.setObject(compressedRaster,forKeyedSubscript:"__turtleCompressedClassicRaster" as NSString)
    context.setObject(decode, forKeyedSubscript: "__turtleDecode" as NSString)
    context.setObject(base64, forKeyedSubscript: "__turtleBase64" as NSString)
    context.setObject(measure, forKeyedSubscript: "__turtleMeasureText" as NSString)
    context.setObject(layoutText, forKeyedSubscript: "__turtleLayoutText" as NSString)
    context.setObject(positionedText,forKeyedSubscript:"__turtlePositionedText" as NSString)
    context.setObject(strokePath, forKeyedSubscript: "__turtleStrokePath" as NSString)
    context.setObject(strokeCoverage,forKeyedSubscript:"__turtleStrokeCoverage" as NSString)
    context.setObject(regionPath,forKeyedSubscript:"__turtleRegionPath" as NSString)
    context.setObject(floodCoverage,forKeyedSubscript:"__turtleFloodCoverage" as NSString)
    context.setObject(embeddedScope,forKeyedSubscript:"__turtleMetafileScope" as NSString)
    context.setObject(embeddedImage,forKeyedSubscript:"__turtleMetafileRaster" as NSString)
    context.setObject(rasterComposite,forKeyedSubscript:"__turtleRasterComposite" as NSString)
    context.setObject(rasterTransfer,forKeyedSubscript:"__turtleRasterTransfer" as NSString)
    context.setObject(bitmap, forKeyedSubscript: "__turtleBitmapNative" as NSString)
    context.evaluateScript("""
    globalThis.__turtleBitmap = function(bytes,width,height,stride,format,palette){return __turtleBitmapNative(bytes,width,height,stride,format,palette === undefined ? [] : palette);};
    globalThis.console = {log(){}, warn(){}, error(){}, debug(){}};
    globalThis.TextDecoder = class { constructor(label='utf-8'){this.label=label;} decode(bytes){return __turtleDecode(bytes || new Uint8Array(0),this.label);} };
    globalThis.btoa = function(text){let bytes=new Uint8Array(text.length);for(let i=0;i<text.length;i++){let n=text.charCodeAt(i);if(n>255)throw Error('Invalid binary string');bytes[i]=n;}return __turtleBase64(bytes);};
    globalThis.Buffer = {from(bytes){return {toString(encoding){if(encoding !== 'base64')throw Error('Unsupported Buffer encoding');return __turtleBase64(bytes);}};}};
    """)
    context.evaluateScript(try String(contentsOf: sourceURL, encoding: .utf8), withSourceURL: sourceURL)
    guard exception == nil else { throw ConversionError.invalid(exception!) }
    // JavaScriptCore owns the typed buffer, including throughout native callbacks.
    guard let typed = JSObjectMakeTypedArray(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, input.count, nil),
          let storage = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, typed, nil) else {
        throw ConversionError.invalid("Cannot allocate metafile input")
    }
    input.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: input.count)
    let value = JSValue(jsValueRef: typed, in: context)!
    let result = context.objectForKeyedSubscript("__turtleRender")?.call(withArguments: [value, String(CommandLine.arguments[1].dropFirst(2))])
    guard exception == nil, let svg = result?.toString(), svg.contains("<svg"), svg.utf8.count <= outputLimit,
          svg.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
          svg.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
        throw ConversionError.invalid(exception ?? "Invalid or oversized SVG output")
    }
    let output = Data(svg.utf8), safety = SVGGuard()
    let parser = XMLParser(data: output)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = safety
    guard parser.parse(), safety.valid else { throw ConversionError.invalid("Renderer produced invalid SVG or external resources") }
    try FileHandle.standardOutput.write(contentsOf: output)
}
do { try run() } catch ConversionError.invalid(let text) { fail(text) } catch { fail(String(describing: error)) }
