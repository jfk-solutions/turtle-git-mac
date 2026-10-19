// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PDFKit
import CryptoKit
import TurtleGitCore

/// Rasterize immutable exported PDFs, never the private editable presentations.
/// Each invocation owns its PDF readers on its worker thread.
enum PresentationComparisonRendering {
    enum Failure:LocalizedError {
        case pdf,limit,page
        var errorDescription:String? {switch self {
        case .pdf:return "The exported presentation PDF could not be read."
        case .limit:return "The presentation exceeds the review rendering limit."
        case .page:return "The exported PDF does not match the slide manifest."
        }}
    }
    struct Raster:Sendable {
        let width:Int,height:Int,pixels:Data
        var fingerprint:String {
            var data=Data("\(width)x\(height):".utf8);data.append(pixels)
            return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        }
        var image:NSImage? {
            guard let provider=CGDataProvider(data:pixels as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return nil}
            return NSImage(cgImage:image,size:NSSize(width:CGFloat(width),height:CGFloat(height)))
        }
    }
    struct Pair:Sendable {let base:Raster?,destination:Raster?,difference:Raster?}
    static let maximumSlides=512
    private static func document(_ url:URL,expected:Int)throws->PDFDocument {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? NSNumber,size.uint64Value<=128*1024*1024,
              expected>=0,expected<=maximumSlides else{throw Failure.limit}
        guard let document=PDFDocument(url:url),!document.isLocked else{throw Failure.pdf}
        guard document.pageCount==expected else{throw Failure.page}
        return document
    }
    private static func raster(_ page:PDFPage,longest:Int,cancellation:OperationCancellation)throws->Raster {
        try cancellation.check()
        guard let reference=page.pageRef else{throw Failure.pdf}
        let bounds=reference.getBoxRect(.cropBox)
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0,bounds.width<=100_000,bounds.height<=100_000 else{throw Failure.limit}
        let rotation=((reference.rotationAngle%360)+360)%360
        let swapped=rotation==90 || rotation==270
        let size=CGSize(width:swapped ? bounds.height:bounds.width,height:swapped ? bounds.width:bounds.height)
        let scale=CGFloat(longest)/max(size.width,size.height)
        let width=max(1,Int((size.width*scale).rounded())),height=max(1,Int((size.height*scale).rounded()))
        guard width<=2048,height<=2048,width*height<=4_194_304 else{throw Failure.limit}
        var bytes=Data(count:width*height*4)
        let drawn:Bool=bytes.withUnsafeMutableBytes{buffer in
            guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{return false}
            let target=CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height))
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(target)
            context.concatenate(reference.getDrawingTransform(.cropBox,rect:target,rotate:0,preserveAspectRatio:true))
            context.drawPDFPage(reference);return true
        }
        guard drawn else{throw Failure.pdf};try cancellation.check()
        return Raster(width:width,height:height,pixels:bytes)
    }
    static func fingerprints(base:URL,destination:URL,baseCount:Int,destinationCount:Int,cancellation:OperationCancellation)throws->([String],[String]) {
        let started=ProcessInfo.processInfo.systemUptime
        func read(_ url:URL,_ count:Int)throws->[String] {
            let pdf=try document(url,expected:count)
            return try (0..<count).map{index in
                try cancellation.check();guard ProcessInfo.processInfo.systemUptime-started<90,let page=pdf.page(at:index) else{throw Failure.limit}
                return try autoreleasepool{try raster(page,longest:256,cancellation:cancellation).fingerprint}
            }
        }
        return try (read(base,baseCount),read(destination,destinationCount))
    }
    static func pair(base:URL,destination:URL,baseCount:Int,destinationCount:Int,baseIndex:Int?,destinationIndex:Int?,cancellation:OperationCancellation)throws->Pair {
        func read(_ url:URL,_ count:Int,_ index:Int?)throws->Raster? {
            guard let index else{return nil};guard index>=0,index<count else{throw Failure.page}
            let document=try document(url,expected:count)
            guard let page=document.page(at:index) else{throw Failure.page}
            return try raster(page,longest:1536,cancellation:cancellation)
        }
        let a=try read(base,baseCount,baseIndex),b=try read(destination,destinationCount,destinationIndex)
        return Pair(base:a,destination:b,difference:try difference(a,b,cancellation:cancellation))
    }
    /// Red marks changed pixels. The destination remains visible as a neutral
    /// background; different page dimensions are a whole-slide difference.
    static func difference(_ a:Raster?,_ b:Raster?,cancellation:OperationCancellation)throws->Raster? {
        guard let reference=b ?? a else{return nil}
        var result=reference.pixels
        try result.withUnsafeMutableBytes{(out:UnsafeMutableRawBufferPointer) in
            try reference.pixels.withUnsafeBytes{(right:UnsafeRawBufferPointer) in
                try (a?.pixels ?? Data()).withUnsafeBytes{(left:UnsafeRawBufferPointer) in
                    let sameSize=a?.width==b?.width && a?.height==b?.height
                    for pixel in 0..<(reference.width*reference.height) {
                        if pixel%8192==0{try cancellation.check()}
                        let offset=pixel*4
                        let changed = !sameSize || (0..<3).contains{abs(Int(left[offset+$0])-Int(right[offset+$0]))>8}
                        if changed {out[offset]=255;out[offset+1]=UInt8(Int(right[offset+1])/3);out[offset+2]=UInt8(Int(right[offset+2])/3)}
                        else {let gray=(Int(right[offset])+Int(right[offset+1])+Int(right[offset+2]))/3;for channel in 0..<3{out[offset+channel]=UInt8((gray+255)/2)}}
                        out[offset+3]=255
                    }
                }
            }
        }
        return Raster(width:reference.width,height:reference.height,pixels:result)
    }
}
