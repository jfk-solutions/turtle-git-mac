// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import ImageIO
import CoreText
import Darwin
import CryptoKit
@testable import TurtleGitCore

final class MetafileImageTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func image(_ name: String) throws -> ComparisonImage { try XCTUnwrap(ComparisonImage(bytes: data(name)), "Could not render \(name)") }
    /// Natural EMF extents include GDI+'s final device pixel. Geometry oracles
    /// below retain their original top-left viewport; crop, never rescale it.
    private func interior(_ image:ComparisonImage,width:Int,height:Int,emf:Bool = true,name:String = "")throws->CGImage {
        let edge=emf ? 1:0
        XCTAssertEqual(image.pixels.width,width+edge,name)
        XCTAssertEqual(image.pixels.height,height+edge,name)
        return try XCTUnwrap(image.pixels.cropping(to:CGRect(x:0,y:0,width:width,height:height)),name)
    }
    private func rgb(_ image: ComparisonImage, _ x: Int, _ y: Int) throws -> [CGFloat] {
        // NSBitmapImageRep.colorAt can return generic calibrated RGB despite an
        // sRGB CGImage profile; converting that NSColor changes pure magenta.
        // Normalize the actual image to a named sRGB byte buffer instead.
        let width = image.pixels.width, height = image.pixels.height
        XCTAssertTrue((0..<width).contains(x) && (0..<height).contains(y))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { storage in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
            let components = storage.bindMemory(to: UInt8.self), offset = (y * width + x) * 4
            let alpha = CGFloat(components[offset + 3]) / 255
            return (0..<3).map { alpha > 0 ? CGFloat(components[offset + $0]) / (255 * alpha) : 0 }
        }
    }
    private struct EmbeddedPaint {
        let x:Int,y:Int,width:Int,height:Int,pixels:CGImage,rgba:[UInt8]
        var diagnostic:String{"embeddedPNG=\(pixels.width)x\(pixels.height),deviceFrame=\(x),\(y),\(width),\(height),profile=\(String(describing:pixels.colorSpace?.name))"}
        func sample(_ deviceX:Int,_ deviceY:Int)throws->[CGFloat]{
            guard pixels.width==width,pixels.height==height else{throw NSError(domain:"Nonintrinsic source raster: \(diagnostic)",code:1)}
            let px=deviceX-x,py=deviceY-y
            guard (0..<width).contains(px),(0..<height).contains(py) else{throw NSError(domain:"Sample outside \(diagnostic)",code:1)}
            let offset=(py*width+px)*4,alpha=CGFloat(rgba[offset+3])/255
            return (0..<3).map{alpha>0 ? CGFloat(rgba[offset+$0])/(255*alpha):0}+[alpha]
        }
    }
    /// Inspect the helper's source pixels without SVG, AppKit caching, clipping,
    /// display profiles or reconstruction filters. Device placement comes from
    /// image attributes; no hatch lookup table is duplicated in this oracle.
    private func embeddedPaints(_ name:String)throws->[EmbeddedPaint]{
        let svg=String(decoding:try XCTUnwrap(MetafileImageDecoder.convert(data(name))),as:UTF8.self),text=svg as NSString
        let tags=try NSRegularExpression(pattern:"<image\\b[^>]*>").matches(in:svg,range:NSRange(location:0,length:text.length))
        return try tags.map{tag in
            let value=text.substring(with:tag.range),source=value as NSString
            func attribute(_ name:String)throws->String{
                let pattern="\\s"+name+"=\"([^\"]*)\"",expression=try NSRegularExpression(pattern:pattern)
                let match=try XCTUnwrap(expression.firstMatch(in:value,range:NSRange(location:0,length:source.length)),"Missing \(name) in embedded paint")
                return source.substring(with:match.range(at:1))
            }
            let href=try attribute("(?:xlink:)?href"),prefix="data:image/png;base64,"
            XCTAssertTrue(href.hasPrefix(prefix));let png=try XCTUnwrap(Data(base64Encoded:String(href.dropFirst(prefix.count))))
            let imageSource=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
            let x=Int(try XCTUnwrap(Double(attribute("x")))),y=Int(try XCTUnwrap(Double(attribute("y")))),width=Int(try XCTUnwrap(Double(attribute("width")))),height=Int(try XCTUnwrap(Double(attribute("height"))))
            XCTAssertEqual(image.width,width,"Embedded paint still depends on an assumed native backing scale")
            XCTAssertEqual(image.height,height,"Embedded paint still depends on an assumed native backing scale")
            var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
            try bytes.withUnsafeMutableBytes{storage in
                let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
                context.interpolationQuality = .none;context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
            return EmbeddedPaint(x:x,y:y,width:width,height:height,pixels:image,rgba:bytes)
        }
    }
    private func rasterDiagnostic(_ image:ComparisonImage)->String{
        "finalCGImage=\(image.pixels.width)x\(image.pixels.height),profile=\(String(describing:image.pixels.colorSpace?.name)),bits=\(image.pixels.bitsPerComponent)/\(image.pixels.bitsPerPixel),alpha=\(image.pixels.alphaInfo.rawValue)"
    }
    private func embeddedRGBA(_ name:String,_ x:Int=0,_ y:Int=0)throws->[CGFloat] {
        let svg=String(decoding:try XCTUnwrap(MetafileImageDecoder.convert(data(name))),as:UTF8.self)
        let start=try XCTUnwrap(svg.range(of:"data:image/png;base64,")),tail=svg[start.upperBound...]
        let end=try XCTUnwrap(tail.firstIndex(of:"\"")),png=try XCTUnwrap(Data(base64Encoded:String(tail[..<end])))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertTrue((0..<image.width).contains(x) && (0..<image.height).contains(y))
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        return try bytes.withUnsafeMutableBytes{storage in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            let values=storage.bindMemory(to:UInt8.self),offset=(y*image.width+x)*4,alpha=CGFloat(values[offset+3])/255
            return (0..<3).map{alpha>0 ? CGFloat(values[offset+$0])/(255*alpha):0}+[alpha]
        }
    }
    private func halfAlphaRed(_ name:String)throws {
        let pixel=try embeddedRGBA(name)
        XCTAssertEqual(pixel[0],1,accuracy:1.0/255);XCTAssertEqual(pixel[1],0,accuracy:1.0/255);XCTAssertEqual(pixel[2],0,accuracy:1.0/255)
        XCTAssertEqual(pixel[3],CGFloat(128)/255,accuracy:1.0/255,"Raw decoder changed actual source alpha")
        // Source alpha is checked above before native display color handling.
        // Compare uniform interiors to an independent CSS source-over oracle:
        // AppKit/CoreSVG color handling does not produce literal sRGB0.5 for
        // red/128 over white on every display profile. This reference contains
        // no metafile, bitmap adapter or embedded PNG.
        let referenceBytes=Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"64\"><rect width=\"96\" height=\"64\" fill=\"white\"/><rect width=\"96\" height=\"64\" fill=\"red\" fill-opacity=\"0.5019607843137255\"/></svg>".utf8)
        let reference=try XCTUnwrap(ComparisonImage(bytes:referenceBytes)),expected=try rgb(reference,44,44)
        let composite=try rgb(image(name.replacingOccurrences(of:".emf",with:"-plateau.emf")),44,44)
        XCTAssertGreaterThan(composite[0],0.95)
        for channel in 0..<3{XCTAssertEqual(composite[channel],expected[channel],accuracy:1.0/255,"Raw bitmap source-over differs from independent native CSS alpha")}
    }
    private func primary(_ image: ComparisonImage, _ channel: Int, _ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try rgb(image,x,y)
        XCTAssertGreaterThan(color[channel],0.8,"Sample(\(x),\(y))=\(color); \(rasterDiagnostic(image))",file:file,line:line)
        for i in 0..<3 where i != channel { XCTAssertLessThan(color[i],0.25,"Sample(\(x),\(y))=\(color); \(rasterDiagnostic(image))",file:file,line:line) }
    }
    func testNativeSVGIntrinsicPixelGridAndOrientationDoNotDependOnBackingScale() throws {
        var rectangles=""
        for y in 0..<8{for x in 0..<8{let color=(x+y)%2==0 ? "#ff0000":"#0000ff";rectangles += "<rect x=\"\(x+4)\" y=\"\(y+4)\" width=\"1\" height=\"1\" fill=\"\(color)\"/>"}}
        let bytes=Data(("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"20\" viewBox=\"0 0 24 20\"><rect width=\"24\" height=\"20\" fill=\"white\"/>"+rectangles+"<rect x=\"17\" y=\"2\" width=\"4\" height=\"3\" fill=\"#00ff00\"/><rect x=\"17\" y=\"15\" width=\"4\" height=\"3\" fill=\"#ff00ff\"/></svg>").utf8)
        let value=try XCTUnwrap(ComparisonImage(bytes:bytes)),diagnostic=rasterDiagnostic(value)
        XCTAssertEqual(value.size,CGSize(width:24,height:20),diagnostic)
        for y in 0..<8{for x in 0..<8{
            let color=try rgb(value,x+4,y+4),expected:[CGFloat]=(x+y)%2==0 ? [1,0,0]:[0,0,1]
            for channel in 0..<3{XCTAssertEqual(color[channel],expected[channel],accuracy:1.0/255,"SVG intrinsic cell(\(x),\(y)) blurred: \(diagnostic)")}
        }}
        let top=try rgb(value,19,3),bottom=try rgb(value,19,16)
        for channel in 0..<3{XCTAssertEqual(top[channel],[CGFloat(0),1,0][channel],accuracy:1.0/255,diagnostic);XCTAssertEqual(bottom[channel],[CGFloat(1),0,1][channel],accuracy:1.0/255,diagnostic)}
    }
    func testNativeSVGEmbeddedRasterRampUsesIntrinsicPixelCenters() throws {
        // Literal source samples isolate embedded-raster placement/filtering.
        // CoreSVG's own linearGradient color transfer is a separate contract:
        // the local backend does not match componentwise sRGB interpolation.
        let red:[UInt8]=[247,231,215,199,183,167,151,135,120,104,88,72,56,40,24,8]
        let rgba=Data((0..<8).flatMap{_ in red.flatMap{[$0,UInt8(0),255-$0,UInt8(255)]}})
        let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),provider=try XCTUnwrap(CGDataProvider(data:rgba as CFData))
        let source=try XCTUnwrap(CGImage(width:16,height:8,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:64,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,source,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let encoded=(png as Data).base64EncodedString()
        let bytes=Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"8\"><image x=\"0\" y=\"0\" width=\"16\" height=\"8\" href=\"data:image/png;base64,\(encoded)\"/></svg>".utf8)
        let value=try XCTUnwrap(ComparisonImage(bytes:bytes)),diagnostic=rasterDiagnostic(value)
        XCTAssertEqual(value.size,CGSize(width:16,height:8),diagnostic)
        for x in 0..<16{let color=try rgb(value,x,4),t=CGFloat(2*x+1)/32
            XCTAssertEqual(color[0],1-t,accuracy:1.0/255,"Embedded sRGB raster pixel center \(x): \(diagnostic)")
            XCTAssertEqual(color[1],0,accuracy:1.0/255,diagnostic);XCTAssertEqual(color[2],t,accuracy:1.0/255,diagnostic)
        }
    }
    func testWMFAndEMFRenderCapturedVectorColorsAtIntrinsicSize() throws {
        for name in ["clip-vector.wmf","classic-vector.emf"] {
            let value = try image(name)
            let edge=name.hasSuffix(".emf") ? 1:0
            XCTAssertEqual(value.size,CGSize(width:96+edge,height:64+edge))
            try primary(value,0,12,12)
            if name.hasSuffix("wmf") {
                let outside = try rgb(value,35,35)
                XCTAssertTrue(outside.allSatisfy { $0>0.9 },"WMF intersection clipping was ignored")
            } else { try primary(value,2,58,12) }
        }
    }
    func testFrameAndDeviceMetadataDetermineSizeAndDPI() throws {
        let physical = try image("physical-frame.emf")
        XCTAssertEqual(physical.size,CGSize(width:193,height:129))
        XCTAssertEqual(try XCTUnwrap(physical.dpiX),96,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(physical.dpiY),96,accuracy:0.1)
        let wmf = try image("clip-144dpi.wmf")
        XCTAssertEqual(wmf.size,CGSize(width:96,height:64))
        XCTAssertEqual(try XCTUnwrap(wmf.dpiX),144,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(wmf.dpiY),144,accuracy:0.1)
    }
    func testEMFPlusTransformsClipsAndIndexedRestoreRenderDifferentTargets() throws {
        let value = try image("plus-transform.emf")
        XCTAssertEqual(value.size,CGSize(width:97,height:65))
        try primary(value,0,20,12)
        try primary(value,2,58,12)
        let outside = try rgb(value,34,12)
        XCTAssertTrue(outside.allSatisfy { $0>0.9 },"EMF+ transformed clip did not constrain red rectangle")
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-transform.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("matrix(1 0 0 1 12 4)")); XCTAssertTrue(svg.contains("mask="))
    }
    func testGDIPlusAppendAndPrependUseDifferentNoncommutingOrder() throws {
        let value = try image("plus-matrix-order.emf")
        try primary(value,0,20,8)
        try primary(value,2,32,40)
        XCTAssertTrue(try rgb(value,35,8).allSatisfy { $0>0.9 })
    }
    func testDualPlaybackChoosesPlusAndPermitsOnlyGetDCClassicInterval() throws {
        let value = try image("plus-dual-getdc.emf")
        try primary(value,0,12,12)
        try primary(value,2,58,12)
    }
    func testClassicAndPlusBitmapsDecodeOriginalChannelOrderAndKeepTextFace() throws {
        for name in ["classic-bitmap.emf","plus-bitmap-text.emf"] {
            let value = try image(name)
            XCTAssertEqual(value.size,CGSize(width:97,height:65))
            // Sample the source-pixel centers after each captured destination
            // transform; shared coordinates would sample different interpolation.
            let first = name.hasPrefix("classic") ? 16 : 12
            let second = first + 16
            try primary(value,0,first,first)
            try primary(value,1,second,first)
            try primary(value,2,first,second)
        }
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-bitmap-text.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("Helvetica"));XCTAssertTrue(svg.contains("TurtleGit"));XCTAssertTrue(svg.contains("data:image/png;base64,"))
    }
    func testPlusPathContainerAndContinuedObjectKeepCapturedGeometry() throws {
        let path = try image("plus-path-container.emf")
        try primary(path,0,40,12)
        try primary(path,2,10,44)
        let bitmap = try image("plus-continued-bitmap.emf")
        try primary(bitmap,0,12,12)
        try primary(bitmap,1,30,12)
    }
    func testCompressedPlusBitmapUsesSignatureDimensionsAndSourceCrop() throws {
        let value = try image("plus-compressed-crop.emf")
        // Source green pixel center (1.5,0.5) through crop/destination
        // matrix (32,0,0,16,-24,8) lands exactly at (24,16).
        try primary(value,1,24,16)
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-compressed-crop.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("turtle-image-clip"));XCTAssertTrue(svg.contains("width=\"2\""))
    }
    func testLinearGradientPresetColorsComposeBrushAndWorldTransforms() throws {
        let value = try image("plus-gradient-transform.emf")
        XCTAssertEqual(value.size, CGSize(width: 97, height: 65))
        // Normalized horizontal-axis fractions through brush [0,48,-24,0,64,4]
        // then world Translate(8,4), independent of renderer-generated SVG.
        try primary(value, 0, 70, 10)
        try primary(value, 1, 60, 32)
        try primary(value, 2, 49, 54)
        XCTAssertTrue(try rgb(value, 44, 30).allSatisfy { $0 > 0.9 }, "Brush/world transforms misplaced the painted rectangle")
        // Final snapshots prune unreferenced semantic gradient definitions.
        // Verify the actual paint pixels before native SVG display instead.
        let paints = try embeddedPaints("plus-gradient-transform.emf")
        XCTAssertEqual(paints.count, 1)
        let paint = try XCTUnwrap(paints.first)
        for (channel, x, y) in [(0, 70, 10), (1, 60, 32), (2, 49, 54)] {
            let color = try paint.sample(x, y)
            XCTAssertGreaterThan(color[channel], 0.8, paint.diagnostic)
            for other in 0..<3 where other != channel { XCTAssertLessThan(color[other], 0.25, paint.diagnostic) }
            XCTAssertEqual(color[3], 1, accuracy: 1.0 / 255, paint.diagnostic)
        }
    }
    func testEllipticalPathGradientUsesBoundaryToCenterPresetOrderAndTransforms() throws {
        let value = try image("plus-gradient-radial.emf")
        // The boundary path is a four-Bezier ellipse (24x20 radii), not an
        // output-derived image. Brush/world translations align center(54.5,38.5)
        // with pixel(54,38); endpoint plateaus avoid testing near-stop blends.
        try primary(value, 0, 54, 38)
        try primary(value, 1, 66, 38)
        try primary(value, 2, 76, 38)
        XCTAssertTrue(try rgb(value, 20, 20).allSatisfy { $0 > 0.9 })
        let paints = try embeddedPaints("plus-gradient-radial.emf")
        XCTAssertEqual(paints.count, 1)
        let paint = try XCTUnwrap(paints.first)
        for (channel, x, y) in [(0, 54, 38), (1, 66, 38), (2, 76, 38)] {
            let color = try paint.sample(x, y)
            XCTAssertGreaterThan(color[channel], 0.8, paint.diagnostic)
            for other in 0..<3 where other != channel { XCTAssertLessThan(color[other], 0.25, paint.diagnostic) }
            XCTAssertEqual(color[3], 1, accuracy: 1.0 / 255, paint.diagnostic)
        }
    }
    func testLinearGradientHorizontalBlendFactorsRetainPlateausAndMidpoint() throws {
        let value = try image("plus-gradient-blend.emf")
        try primary(value, 0, 16, 24)
        try primary(value, 2, 80, 24)
        let middle = try rgb(value, 48, 24)
        XCTAssertGreaterThan(middle[0], 0.35); XCTAssertGreaterThan(middle[2], 0.35)
        XCTAssertLessThan(middle[1], 0.25)
        XCTAssertEqual(middle[0], middle[2], accuracy: 0.08)
    }
    func testLinearGradientTileAndFlipRetainDifferentStopOrders() throws {
        let paints=try embeddedPaints("plus-gradient-wrap.emf")
        XCTAssertEqual(paints.count,2)
        if paints.count==2{
            // Independent Windows linear-gradient controls establish integer device
            // sampling. x24 is exactly period1 after world translation8:
            // Tile restarts at red; FlipX starts at the reflected blue endpoint.
            for (index,y) in [(0,20),(1,52)]{
                let raw=try paints[index].sample(24,y),expected:[CGFloat]=index==0 ? [1,0,0,1]:[0,0,1,1]
                for channel in 0..<4{XCTAssertEqual(raw[channel],expected[channel],accuracy:1.0/255,"Wrapped source pixel differs before native SVG: \(paints[index].diagnostic)")}
            }
        }
        let value = try image("plus-gradient-wrap.emf")
        // Each sample is at the second period boundary at the same normalized
        // horizontal position: Tile restarts red; TileFlipX reflects from blue.
        try primary(value, 0, 24, 20)
        try primary(value, 2, 24, 52)
        XCTAssertTrue(try rgb(value, 92, 30).allSatisfy { $0 > 0.9 })
    }
    func testImageAttributesDefaultClampColorAndTileFlipPreserveOriginalPixels() throws {
        let plain = try image("plus-image-attributes.emf")
        try primary(plain, 0, 16, 16)
        try primary(plain, 1, 32, 16)
        try primary(plain, 2, 16, 32)
        let ignoredClamp = try image("plus-image-attributes-clamp-ignored.emf")
        for y in [16,32] { for x in [16,32] { XCTAssertEqual(try rgb(ignoredClamp,x,y),try rgb(plain,x,y),"GDI+ 1.0 ignores SetWrapMode clamp BOOL") } }
        let clamped = try image("plus-image-clamp.emf")
        for x in [16, 64] {
            let color = try rgb(clamped, x, 16)
            XCTAssertGreaterThan(color[0], 0.8); XCTAssertLessThan(color[1], 0.25); XCTAssertGreaterThan(color[2], 0.8)
        }
        try primary(clamped, 0, 32, 16)
        try primary(clamped, 1, 48, 16)
        let wrapped = try image("plus-image-wrap.emf")
        let tile = [0, 1, 0, 1, 0, 1], reflected = [1, 0, 0, 1, 1, 0]
        for index in 0..<6 {
            try primary(wrapped, tile[index], 8 + 16 * index, 12)
            try primary(wrapped, reflected[index], 8 + 16 * index, 40)
        }
    }
    func testRelativeSigned7And15AndAbsoluteInt16ImagePointsUseActualFlags() throws {
        let relative = try image("plus-image-relative.emf")
        // P=0x0800 wins over C=0x4000. Delta pairs (160,8),(-128,0),
        // (128,32) include both scalar widths/signs; world transform maps them.
        try primary(relative, 0, 68, 20)
        try primary(relative, 1, 36, 20)
        try primary(relative, 2, 68, 36)
        let absolute = try image("plus-image-int16.emf")
        // C alone means signed absolute Int16, including initial x=-16.
        try primary(absolute, 0, 24, 20)
        try primary(absolute, 1, 56, 20)
        try primary(absolute, 2, 24, 36)
        XCTAssertTrue(try rgb(absolute, 88, 52).allSatisfy { $0 > 0.9 })
    }
    func testOpaquePenAndHalfAlphaBrushPreserveSeparateSVGOpacity() throws {
        let value = try image("plus-alpha-pen.emf")
        try primary(value, 0, 20, 8)
        let translucent = try rgb(value, 20, 32)
        XCTAssertGreaterThan(translucent[0], 0.9)
        for channel in [1, 2] {
            XCTAssertGreaterThan(translucent[channel], 0.3)
            XCTAssertLessThan(translucent[channel], 0.85)
        }
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-alpha-pen.emf"))), as: UTF8.self)
        let opaqueOutline = try NSRegularExpression(pattern: ##"<path\b[^>]*fill="#ff0000"[^>]*fill-opacity="1(?:\.0+)?""##)
        XCTAssertNotNil(opaqueOutline.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)), "Opaque pen outline lost its separate full-opacity paint")
        XCTAssertTrue(svg.contains("fill=\"#ff0000\""))
        let expression = try NSRegularExpression(pattern: #"fill-opacity="([0-9.]+)""#)
        let opacities = expression.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: svg) else { return nil }
            return Double(svg[range])
        }
        XCTAssertTrue(opacities.contains { abs($0 - 128.0 / 255.0) < 0.0001 }, "Inline ARGB brush alpha was not preserved as separate SVG opacity")
    }
    func testRegionBooleanTreesAndClipCombinesPaintIndependentTruthTables() throws {
        let samples = [16, 44, 68, 88]
        let operations: [(String, [Bool])] = [
            ("and", [false, true, false, false]), ("or", [true, true, true, false]),
            ("xor", [true, false, true, false]), ("exclude", [true, false, false, false]),
            ("complement", [false, false, true, false])
        ]
        func check(_ name: String, _ expected: [Bool]) throws {
            let value = try image(name)
            XCTAssertEqual(value.size, CGSize(width: 97, height: 65))
            for (x, painted) in zip(samples, expected) {
                if painted { try primary(value, 0, x, 24) }
                else { XCTAssertTrue(try rgb(value, x, 24).allSatisfy { $0 > 0.9 }, "\(name) painted excluded x=\(x)") }
            }
        }
        for (name, expected) in operations { try check("plus-region-\(name).emf", expected) }
        try check("plus-region-clip-0.emf", [false, true, true, false])
        for (index, operation) in operations.enumerated() { try check("plus-region-clip-\(index + 1).emf", operation.1) }
    }
    func testRegionPathHoleInt16BoundaryInfiniteAndEmptyHaveActualGeometry() throws {
        let path = try image("plus-region-path.emf")
        try primary(path, 0, 12, 12); try primary(path, 0, 44, 28)
        XCTAssertTrue(try rgb(path, 28, 28).allSatisfy { $0 > 0.9 }, "Even-odd region path lost its hole")
        try primary(path, 2, 64, 16)
        XCTAssertTrue(try rgb(path, 84, 44).allSatisfy { $0 > 0.9 }, "Int16 triangular region became its bounding box")
        let leaves = try image("plus-region-infinite-empty.emf")
        try primary(leaves, 0, 12, 12); try primary(leaves, 0, 80, 48)
        XCTAssertTrue(try rgb(leaves, 40, 24).allSatisfy { $0 > 0.9 }, "Infinite minus rectangle or Empty fill lost its semantics")
    }
    func testRegionClipCapturesDeviceTransformAndIndexedRestore() throws {
        let value = try image("plus-region-state.emf")
        try primary(value, 0, 20, 12)
        XCTAssertTrue(try rgb(value, 44, 12).allSatisfy { $0 > 0.9 }, "World reset moved a captured region clip")
        try primary(value, 2, 68, 16)
        XCTAssertTrue(try rgb(value, 6, 6).allSatisfy { $0 > 0.9 }, "Region clip lost its translated boundary")
    }
    func testHatchStylesRetainForegroundBackgroundAndNativeCellOrientation() throws {
        let paints=try embeddedPaints("plus-hatch-atlas.emf")
        XCTAssertEqual(paints.count,53)
        if paints.count==53{
            for style in 0..<53{
                let left=2+10*(style%9),top=2+10*(style/9)
                var foreground=0,background=0
                for y in top..<(top+8){for x in left..<(left+8){
                    let raw=try paints[style].sample(x,y)
                    XCTAssertEqual(raw[1],0,accuracy:1.0/255,paints[style].diagnostic);XCTAssertEqual(raw[3],1,accuracy:1.0/255,paints[style].diagnostic)
                    XCTAssertEqual(raw[0]+raw[2],1,accuracy:1.0/255,"Hatch source mixed colors beyond foreground/background")
                    if raw[0]>0.8 && raw[2]<0.2{foreground+=1};if raw[2]>0.8 && raw[0]<0.2{background+=1}
                    if style==0{XCTAssertEqual(raw[0],y%8==0 ? 1:0,accuracy:1.0/255,"Horizontal source cell is not a device-pixel line")}
                    if style==1{XCTAssertEqual(raw[0],x%8==0 ? 1:0,accuracy:1.0/255,"Vertical source cell is not a device-pixel line")}
                }}
                XCTAssertGreaterThan(foreground,0,"Raw hatch\(style) lost foreground before SVG")
                XCTAssertGreaterThan(background,0,"Raw hatch\(style) lost background before SVG")
                if ![2,3,5].contains(style){XCTAssertEqual(foreground+background,64,"Raw hatch\(style) contains blended source cells")}
            }
        }
        let value = try image("plus-hatch-atlas.emf")
        for style in 0..<53 {
            let left = 2 + 10 * (style % 9), top = 2 + 10 * (style / 9)
            var red = 0, blue = 0
            for y in top..<(top + 8) {
                for x in left..<(left + 8) {
                    let color = try rgb(value, x, y)
                    if color[0] > 0.8 && color[1] < 0.2 && color[2] < 0.2 { red += 1 }
                    if color[2] > 0.8 && color[1] < 0.2 && color[0] < 0.2 { blue += 1 }
                }
            }
            XCTAssertGreaterThan(red, 0, "Hatch style \(style) discarded its foreground; \(rasterDiagnostic(value))")
            XCTAssertGreaterThan(blue, 0, "Hatch style \(style) discarded its background; \(rasterDiagnostic(value))")
            if ![2, 3, 5].contains(style) {
                XCTAssertEqual(red + blue, 64, "Hatch style \(style) became a solid approximation or blended pattern; \(rasterDiagnostic(value))")
            } else {
                // The two diagonal hatch styles and DiagonalCross are specified
                // as antialiased; edge coverage may blend only the two colors.
                for y in top..<(top + 8) {
                    for x in left..<(left + 8) {
                        let color = try rgb(value, x, y)
                        XCTAssertLessThan(color[1], 0.03)
                        XCTAssertEqual(color[0] + color[2], 1, accuracy: 0.04)
                    }
                }
            }
        }
        // MS-EMFPLUS describes horizontal/vertical line orientation, independent
        // of the backend's private serialized pattern representation.
        for delta in 0..<8 {
            let horizontal = try rgb(value, 2, 2 + delta)
            let vertical = try rgb(value, 12 + delta, 2)
            for step in 1..<8 {
                let h = try rgb(value, 2 + step, 2 + delta), v = try rgb(value, 12 + delta, 2 + step)
                for channel in 0..<3 {
                    XCTAssertEqual(h[channel], horizontal[channel], accuracy: 0.02)
                    XCTAssertEqual(v[channel], vertical[channel], accuracy: 0.02)
                }
            }
        }
    }
    func testHatchAlphaDeviceScaleRenderingOriginAndRestoreRemainIndependent() throws {
        let scaledPaint=try XCTUnwrap(embeddedPaints("plus-hatch-alpha-world.emf").first)
        for y in 10..<34{
            let raw=try scaledPaint.sample(20,y),repeatRaw=try scaledPaint.sample(20,y+8)
            for channel in 0..<4{XCTAssertEqual(raw[channel],repeatRaw[channel],accuracy:1.0/255,"Source device hatch period inherited world scale: \(scaledPaint.diagnostic)")}
            XCTAssertEqual(raw[3],CGFloat(128)/255,accuracy:1.0/255,"Hatch source alpha changed before SVG")
            XCTAssertEqual(raw[0],y%8==0 ? 1:0,accuracy:1.0/255);XCTAssertEqual(raw[1],0,accuracy:1.0/255);XCTAssertEqual(raw[2],y%8==0 ? 0:1,accuracy:1.0/255)
        }
        let origins=try embeddedPaints("plus-hatch-origin.emf")
        XCTAssertEqual(origins.count,3)
        if origins.count==3{for y in 8..<21{
            let baseline=try origins[0].sample(20,y),shifted=try origins[1].sample(60,y+3),restored=try origins[2].sample(20,y+32)
            for channel in 0..<4{XCTAssertEqual(baseline[channel],shifted[channel],accuracy:1.0/255,"Source rendering-origin phase changed before SVG");XCTAssertEqual(baseline[channel],restored[channel],accuracy:1.0/255,"Source restored rendering-origin phase changed before SVG")}
        }}
        let scaled = try image("plus-hatch-alpha-world.emf")
        var redRows = 0, blueRows = 0
        for y in 10..<34 {
            let color = try rgb(scaled, 20, y), repeated = try rgb(scaled, 20, y + 8)
            for channel in 0..<3 { XCTAssertEqual(color[channel], repeated[channel], accuracy: 0.03, "World scale stretched the device hatch cell; \(rasterDiagnostic(scaled))") }
            XCTAssertGreaterThan(color[1], 0.35); XCTAssertLessThan(color[1], 0.7)
            if color[0] > 0.9 && color[2] < 0.7 { redRows += 1 }
            if color[2] > 0.9 && color[0] < 0.7 { blueRows += 1 }
        }
        XCTAssertGreaterThan(redRows, 0); XCTAssertGreaterThan(blueRows, 0)
        // Transparent foreground RGB must not contaminate an antialiased
        // diagonal edge. Over white, transparent red + covered opaque blue
        // yields identical red/green components and unchanged blue for every
        // coverage. This oracle follows source alpha algebra, not a cell table.
        let edge = try image("plus-hatch-alpha-edge.emf")
        var partialCoverage = 0
        for y in 12..<20 {
            for x in 12..<20 {
                let clearForeground = try rgb(edge, x, y)
                XCTAssertGreaterThan(clearForeground[2], 0.95)
                XCTAssertEqual(clearForeground[0], clearForeground[1], accuracy: 0.03, "Invisible red stained hatch antialias coverage")
                if clearForeground[0] > 0.05 && clearForeground[0] < 0.95 { partialCoverage += 1 }
                let unequal = try rgb(edge, x + 40, y)
                // Foreground alpha128/255 and background alpha64/255. Their
                // source coverage weights sum to one; compositing both over
                // white therefore gives b+r-g=1, independently of coverage.
                XCTAssertEqual(unequal[2] + unequal[0] - unequal[1], 1, accuracy: 0.04)
                XCTAssertGreaterThan(unequal[0], 0.73)
                XCTAssertGreaterThan(unequal[1], 0.47); XCTAssertLessThan(unequal[1], 0.78)
            }
        }
        XCTAssertGreaterThan(partialCoverage, 0, "Diagonal hatch lost antialiased edge coverage")
        let origin = try image("plus-hatch-origin.emf")
        for y in 8..<21 {
            let baseline = try rgb(origin, 20, y), shifted = try rgb(origin, 60, y + 3), restored = try rgb(origin, 20, y + 32)
            for channel in 0..<3 {
                XCTAssertEqual(baseline[channel], shifted[channel], accuracy: 0.03, "Rendering origin did not shift hatch device phase; \(rasterDiagnostic(origin))")
                XCTAssertEqual(baseline[channel], restored[channel], accuracy: 0.03, "Restore did not restore hatch rendering origin; \(rasterDiagnostic(origin))")
            }
        }
    }
    func testTextureWrapModesReflectBothAxesAcrossNegativeAndPositiveTiles() throws {
        for mode in 0..<4 {
            let value = try image("plus-texture-wrap-\(mode).emf")
            for y in [11, 27, 43] {
                for x in [3, 11, 19, 27, 35, 43, 51, 59, 67, 75, 83, 91] {
                    // Invert the independently specified8x brush matrix at pixel
                    // centers. Floor division, including negatives, determines
                    // tile parity; reflection reverses only the matching axis.
                    let sx = (Double(x) + 0.5 - 24) / 8, sy = (Double(y) + 0.5 - 24) / 8
                    let tileX = Int(floor(sx / 2)), tileY = Int(floor(sy / 2))
                    var column = Int(floor(sx)) - 2 * tileX, row = Int(floor(sy)) - 2 * tileY
                    if mode & 1 != 0 && abs(tileX % 2) == 1 { column = 1 - column }
                    if mode & 2 != 0 && abs(tileY % 2) == 1 { row = 1 - row }
                    if row == 1 && column == 1 { XCTAssertTrue(try rgb(value, x, y).allSatisfy { $0 > 0.9 }) }
                    else { try primary(value, row == 0 ? column : 2, x, y) }
                }
            }
        }
        let corrected = try image("plus-texture-gamma.emf")
        try primary(corrected, 0, 27, 27); try primary(corrected, 1, 35, 27); try primary(corrected, 2, 27, 35)
        let clamped = try image("plus-texture-wrap-4.emf")
        try primary(clamped, 0, 27, 27); try primary(clamped, 1, 35, 27); try primary(clamped, 2, 27, 35)
        XCTAssertTrue(try rgb(clamped, 11, 27).allSatisfy { $0 > 0.9 }, "Clamp repeated a negative texture tile")
        XCTAssertTrue(try rgb(clamped, 43, 27).allSatisfy { $0 > 0.9 }, "Clamp repeated a positive texture tile")
    }
    func testTextureBrushWorldAndDoNotTransformMappingsKeepAlphaAndRegionFills() throws {
        let world = try image("plus-texture-world.emf"), device = try image("plus-texture-device.emf")
        // W*B maps source texel centers through(16,0,0,8,20,12),
        // whereas DoNotTransform keeps B=(8,0,0,8,8,8). Sample each
        // mapping near its actual source texel center, not at the red/green
        // transition. At x43 normal playback is green, device playback red;
        // their y centers differ because only normal playback includes W.
        try primary(world, 0, 27, 15); try primary(device, 1, 35, 11)
        try primary(world, 1, 43, 15); try primary(device, 0, 43, 11)
        XCTAssertTrue(try rgb(world, 90, 15).allSatisfy { $0 > 0.9 }, "Texture escaped transformed fill geometry")
        let alpha = try image("plus-texture-alpha.emf"), color = try rgb(alpha, 20, 20)
        XCTAssertGreaterThan(color[0], 0.9)
        for channel in [1, 2] { XCTAssertGreaterThan(color[channel], 0.35); XCTAssertLessThan(color[channel], 0.7) }
        let region = try image("plus-region-texture.emf")
        try primary(region, 0, 27, 27); try primary(region, 1, 35, 27); try primary(region, 2, 27, 35)
        XCTAssertTrue(try rgb(region, 80, 50).allSatisfy { $0 > 0.9 }, "Texture region painted its bounding box")
        let hatch = try image("plus-region-hatch.emf")
        XCTAssertTrue(try rgb(hatch, 28, 28).allSatisfy { $0 > 0.9 }, "Hatch FillRegion discarded its excluded hole")
        let samples = try (10..<18).map { try rgb(hatch, 16, $0) }
        XCTAssertTrue(samples.contains { $0[0] > 0.8 && $0[2] < 0.2 })
        XCTAssertTrue(samples.contains { $0[2] > 0.8 && $0[0] < 0.2 })
    }
    func testRawIndexedBitOrderPaletteAlphaAndSignedPaddedRows() throws {
        for sign in ["positive","negative"] {
            let one=try image("plus-raw-indexed1-\(sign).emf")
            try primary(one,0,8,12);try primary(one,2,16,12);try primary(one,0,72,12)
            try primary(one,2,8,28);try primary(one,0,16,28)
            for bits in [4,8] {
                let value=try image("plus-raw-indexed\(bits)-\(sign).emf")
                try primary(value,0,12,12);try primary(value,1,28,12);try primary(value,2,44,12)
                try primary(value,2,12,28);try primary(value,0,44,28)
            }
        }
        for name in ["indexed-alpha","indexed-alpha-unflagged"] {
            let value=try image("plus-raw-\(name).emf"),color=try rgb(value,12,12)
            XCTAssertGreaterThan(color[0],0.95);try halfAlphaRed("plus-raw-\(name).emf")
            XCTAssertTrue(try rgb(value,44,12).allSatisfy{$0>0.95},"Transparent palette blue stained the white background")
        }
        let gray=try rgb(image("plus-raw-indexed-gray.emf"),12,12)
        for channel in gray{XCTAssertEqual(channel,CGFloat(85)/255,accuracy:0.03)}
        let halftone=try image("plus-raw-indexed-halftone.emf")
        try primary(halftone,0,12,12);try primary(halftone,1,28,12);try primary(halftone,2,44,12)
    }
    func testRaw16BitMasksAlphaAndRetained24And32BitFormats() throws {
        for sign in ["positive","negative"] {
            for format in ["rgb555","rgb565","rgb24","rgb32"] {
                let value=try image("plus-raw-\(format)-\(sign).emf")
                try primary(value,0,12,12);try primary(value,1,28,12);try primary(value,2,44,12)
                XCTAssertTrue(try rgb(value,12,28).allSatisfy{$0>0.95})
                XCTAssertTrue(try rgb(value,28,28).allSatisfy{$0<0.05})
                let yellow=try rgb(value,44,28);XCTAssertGreaterThan(yellow[0],0.9);XCTAssertGreaterThan(yellow[1],0.9);XCTAssertLessThan(yellow[2],0.1)
            }
            let alpha=try image("plus-raw-argb1555-\(sign).emf")
            try primary(alpha,0,12,12);try primary(alpha,1,28,12);try primary(alpha,2,28,28)
            for point in [(44,12),(12,28)] {XCTAssertTrue(try rgb(alpha,point.0,point.1).allSatisfy{$0>0.95},"ARGB1555 transparent bit was ignored")}
            for format in ["argb32","pargb32"] {
                let retained=try image("plus-raw-\(format)-\(sign).emf"),red=try rgb(retained,12,12)
                XCTAssertGreaterThan(red[0],0.95);try halfAlphaRed("plus-raw-\(format)-\(sign).emf")
                try primary(retained,1,28,12);try primary(retained,2,28,28)
                XCTAssertTrue(try rgb(retained,44,12).allSatisfy{$0>0.95})
            }
        }
        for (name,expected) in [("rgb555-mid",[24,90,206]),("rgb565-mid",[57,69,189])] {
            let actual=try rgb(image("plus-raw-\(name).emf"),12,12)
            for channel in 0..<3{XCTAssertEqual(actual[channel],CGFloat(expected[channel])/255,accuracy:0.015,"16-bit channels were not expanded independently")}
        }
    }
    func testIndexedAnd16BitTextureBrushesMatchIndependentlyCheckedImageColors() throws {
        for name in ["indexed1-positive","indexed4-negative","indexed8-positive","rgb555-negative","rgb565-positive","argb1555-negative","indexed-alpha"] {
            let direct=try image("plus-raw-\(name).emf"),texture=try image("plus-raw-texture-\(name).emf")
            let points=name.hasPrefix("indexed1") ? [(8,12),(16,12),(72,12),(8,28),(16,28)]:[(12,12),(28,12),(44,12),(12,28),(28,28),(44,28)]
            for point in points {
                let a=try rgb(direct,point.0,point.1),b=try rgb(texture,point.0,point.1)
                for channel in 0..<3{XCTAssertEqual(a[channel],b[channel],accuracy:0.035,"Raw texture differed for \(name) at \(point)")}
            }
            XCTAssertTrue(try rgb(texture,80,48).allSatisfy{$0>0.95},"Clamp repeated raw image beyond its tile")
        }
    }
    func testMalformedIndexedPalettes16BitStridesAndRawSizesRefuseRendering() throws {
        let names=["palette-flags","palette-zero","palette-gray","palette-count","palette-truncated","palette-index","palette-index8","indexed-stride","indexed-unaligned-stride","indexed-truncated","indexed-trailing","rgb16-stride","rgb16-truncated","rgb16-min-stride","raw-size","texture-palette-flags","texture-palette-index8","texture-rgb16-truncated"]
        for suffix in names {
            let name="unsupported-raw-"+suffix+".emf",bytes=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes),name)
            XCTAssertNil(ComparisonImage(bytes:bytes),name)
            XCTAssertEqual(try data(name),bytes,"Refused image changed source bytes")
        }
    }
    func testMalformedRegionAndPatternObjectsRefuseSuccessfulBlankOrApproximation() throws {
        for name in ["unsupported-region-work-budget.emf", "unsupported-region-brush-id.emf", "unsupported-region-path-flags.emf", "unsupported-region-count.emf", "unsupported-region-trailing.emf", "unsupported-region-path-length.emf", "unsupported-region-depth.emf", "unsupported-region-id.emf", "unsupported-region-clip-mode.emf", "unsupported-hatch-style.emf", "unsupported-texture-flags.emf", "unsupported-texture-wrap.emf", "unsupported-texture-truncated.emf", "unsupported-texture-image.emf", "unsupported-texture-tile-budget.emf"] {
            XCTAssertThrowsError(try MetafileImageDecoder.convert(data(name)), name)
            XCTAssertNil(ComparisonImage(bytes: try data(name)), name)
        }
    }
    func testMalformedAndUnsupportedPaintingFailInsteadOfSuccessfulBlank() throws {
        for name in ["unsupported-region.emf", "unsupported-image-effect.emf", "unsupported-image-wrap.emf", "unsupported-image-attribute-type.emf", "unsupported-gradient-stops.emf", "unsupported-image-tile-budget.emf", "unsupported-gradient-canonical-precision.emf"] {
            XCTAssertThrowsError(try MetafileImageDecoder.convert(data(name)),name)
            XCTAssertNil(ComparisonImage(bytes: try data(name)),name)
        }
        var truncated = try data("plus-transform.emf");truncated.removeLast()
        XCTAssertThrowsError(try MetafileImageDecoder.convert(truncated),"truncated plus-transform.emf")
        var malformed = try data("classic-vector.emf");malformed.replaceSubrange(92..<96,with:[0xff,0xff,0xff,0x7f])
        XCTAssertThrowsError(try MetafileImageDecoder.convert(malformed),"invalid classic-vector.emf record extent")
        XCTAssertNil(try MetafileImageDecoder.convert(Data("ordinary text".utf8)),"unrecognized ordinary text")
    }
    func testLargeOffsetDistortedGradientUsesGeneralBoundaryAndTranslatedControl()throws {
        let names=["plus-gradient-large-offset-distorted.emf","plus-gradient-translated-distorted.emf","plus-gradient-translated-unshifted.emf"]
        let originals=try names.map{try data($0)}
        XCTAssertEqual(SHA256.hash(data:originals[0]).map{String(format:"%02x",$0)}.joined(),"dac9ffe587ce0ea4a0a007b1bc16bb515fa4f3f54f3136c2b54e482f51dd2a12","Former unsupported-gradient-precision bytes must remain exact")
        func pixels(_ value:ComparisonImage,_ name:String)throws->[UInt8] {
            let cropped=try interior(value,width:96,height:64,name:name)
            var bytes=[UInt8](repeating:0,count:96*64*4)
            try bytes.withUnsafeMutableBytes {storage in
                let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:96,height:64,bitsPerComponent:8,bytesPerRow:96*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
                context.interpolationQuality = .none;context.draw(cropped,in:CGRect(x:0,y:0,width:96,height:64))
            }
            return bytes
        }
        var rendered=[[UInt8]]()
        for (index,name) in names.enumerated() {
            let svg=String(decoding:try XCTUnwrap(MetafileImageDecoder.convert(originals[index]),name),as:UTF8.self)
            XCTAssertFalse(svg.contains("radialGradient"),"General cubic must not become an analytic ellipse: "+name)
            XCTAssertTrue(svg.contains("data:image/png;base64,"),"General boundary must retain its intrinsic raster: "+name)
            let value=try XCTUnwrap(ComparisonImage(bytes:originals[index]),name)
            rendered.append(try pixels(value,name))
            XCTAssertEqual(try data(name),originals[index],"Rendering changed source bytes: "+name)
        }
        let large=rendered[0],translated=rendered[1],unshifted=rendered[2]
        // The small control translates decoded Float32 coordinates and
        // conjugates the actual Float32 world matrix. Only its final translation
        // rounds again (below 0.000002 device pixels), permitting one byte of
        // color quantization, never a rescale or a different boundary.
        let translationDifference=zip(large,translated).map{abs(Int($0.0)-Int($0.1))}.max() ?? 0
        XCTAssertLessThanOrEqual(translationDifference,1,"Large coordinates changed the equivalent translated geometry/color")
        var red=0,blue=0,distortionDifference=0
        for pixel in 0..<(96*64) {
            let offset=pixel*4
            if Int(large[offset])>Int(large[offset+2])+32 {red += 1}
            if Int(large[offset+2])>Int(large[offset])+32 {blue += 1}
            for channel in 0..<3 {distortionDifference=max(distortionDifference,abs(Int(translated[offset+channel])-Int(unshifted[offset+channel])))}
        }
        XCTAssertGreaterThan(red,0,"Supported curve returned blank/no center color")
        XCTAssertGreaterThan(blue,0,"Supported curve lost surrounding color")
        XCTAssertGreaterThan(distortionDifference,2,"The authored control displacement was replaced by the unshifted ellipse-like boundary")
    }
    func testOutputRejectsExternalResourcesScriptsEntitiesAndOversizedDimensions() throws {
        for text in [
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"file:///etc/passwd\"/></svg>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'https://invalid.example/'>]><svg>&x;</svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect style=\"fill:url(https://invalid.example/)\"/></svg>"
        ] { XCTAssertThrowsError(try MetafileImageDecoder.validateSVG(Data(text.utf8))) }
        var huge = try data("classic-vector.emf")
        // Enormous physical frame while device DPI remains valid.
        huge.replaceSubrange(32..<36,with:[0xff,0xff,0xff,0x7f])
        XCTAssertThrowsError(try MetafileImageDecoder.convert(huge))
    }
    private func stalledHelper(_ directory: URL) throws -> (URL,URL) {
        let helper=directory.appendingPathComponent("owned-helper"),marker=directory.appendingPathComponent("pids")
        let script="#!/bin/sh\n/bin/sleep 60 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > '\(marker.path)'\ntrap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 143' TERM INT\nwait \"$child\"\n"
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        return(helper,marker)
    }
    private func assertReaped(_ marker: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pids=try String(contentsOf:marker).split(separator:" ").compactMap {Int32($0)}
        XCTAssertEqual(pids.count,2,file:file,line:line)
        for pid in pids {let status=kill(pid,0),code=errno;XCTAssertEqual(status,-1,"Owned metafile helper survived",file:file,line:line);XCTAssertEqual(code,ESRCH,file:file,line:line)}
    }
    func testOwnedHelperCancellationAndDeadlineReapBothProcessGroupMembers() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMetafileTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let bytes=try data("classic-vector.emf")
        let (helper,marker)=try stalledHelper(directory),token=OperationCancellation()
        let work=Task.detached {try MetafileImageDecoder.convert(bytes,executable:helper,cancellation:token)}
        for _ in 0..<500 where !FileManager.default.fileExists(atPath:marker.path) {try await Task.sleep(nanoseconds:10_000_000)}
        token.cancel()
        do {_ = try await work.value;XCTFail("Cancellation was accepted as an image")}catch {}
        try assertReaped(marker)
        try FileManager.default.removeItem(at:marker)
        XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes,executable:helper,timeout:0.5)) {error in
            guard let failure=error as? MetafileImageFailure, case .timedOut = failure else {return XCTFail("Expected decoder deadline, got \(error)")}
        }
        try assertReaped(marker)
    }
    private struct TextInk {
        let width:Int,height:Int,points:Set<Int>
        var bounds:CGRect? {
            guard !points.isEmpty else{return nil}
            let xs=points.map{$0%width},ys=points.map{$0/width}
            return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!+1,height:ys.max()!-ys.min()!+1)
        }
        var normalized:Set<Int> {
            guard let bounds else{return []}
            return Set(points.map{($0/width-Int(bounds.minY))*width+$0%width-Int(bounds.minX)})
        }
        var columnRuns:[CGRect] {
            let columns=Set(points.map{$0%width}).sorted();var groups:[[Int]]=[]
            for x in columns{if let last=groups.last?.last,x==last+1{groups[groups.count-1].append(x)}else{groups.append([x])}}
            return groups.map{group in
                let values=points.filter{group.contains($0%width)},ys=values.map{$0/width}
                return CGRect(x:group.first!,y:ys.min()!,width:group.count,height:ys.max()!-ys.min()!+1)
            }
        }
    }
    /// Pixel geometry is measured from actual final output, independently of the
    /// CoreText layout bridge. No native glyph-path/bounds API is used as oracle.
    private func textInk(_ name:String,colored:Bool=false)throws->TextInk {
        let value=try image("plus-formatted-"+name+".emf"),width=240,height=180
        let cropped=try interior(value,width:width,height:height,name:name)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes{storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(cropped,in:CGRect(x:0,y:0,width:width,height:height))
        }
        let points=Set((0..<(width*height)).filter{let offset=$0*4;return bytes[offset+3]>128 && (colored ? bytes[offset+1]<128 : bytes[offset]<128 && bytes[offset+1]<128 && bytes[offset+2]<128)})
        return TextInk(width:width,height:height,points:points)
    }
    func testFormattedTextTabsFirstOffsetAndTrackingHaveIndependentPixelGeometry()throws{
        let control=try textInk("tab-control"),tabs=try textInk("tabs"),offset=try textInk("tabs-offset")
        XCTAssertEqual(control.columnRuns.count,2);XCTAssertEqual(tabs.columnRuns.count,2);XCTAssertEqual(offset.columnRuns.count,2)
        guard control.columnRuns.count==2,tabs.columnRuns.count==2,offset.columnRuns.count==2 else{return}
        XCTAssertEqual(tabs.columnRuns[0].minX,control.columnRuns[0].minX,accuracy:1)
        XCTAssertEqual(offset.columnRuns[0].minX,tabs.columnRuns[0].minX,accuracy:1)
        XCTAssertGreaterThan(tabs.columnRuns[1].minX,control.columnRuns[1].minX+8,"Tab was drawn as a space/control glyph")
        XCTAssertEqual(offset.columnRuns[1].minX-tabs.columnRuns[1].minX,12,accuracy:1,"FirstTabOffset did not shift the first tab in page units")
        let continuation=try textInk("tabs-native-continuation").columnRuns
        XCTAssertEqual(continuation.count,4)
        if continuation.count==4 {
            XCTAssertEqual(continuation[1].minX-tabs.columnRuns[1].minX,12,accuracy:1)
            XCTAssertEqual(continuation[2].minX-continuation[1].minX,32,accuracy:1,"Native final-tab interval continuation changed phase")
            XCTAssertEqual(continuation[3].minX-continuation[2].minX,32,accuracy:1)
        }
        let baseline=try textInk("baseline"),tracked=try textInk("tracking")
        XCTAssertEqual(try textInk("ranges-metadata").points,baseline.points,"Character-range metadata changed DrawString paint")
        XCTAssertEqual(try textInk("lcid-bypass").points,baseline.points,"English LCID/BypassGDI changed the ordinary Latin glyph layout")
        XCTAssertGreaterThan(try XCTUnwrap(tracked.bounds).width,try XCTUnwrap(baseline.bounds).width*1.25)
        XCTAssertGreaterThan(tracked.points.count,Int(Double(baseline.points.count)*0.8));XCTAssertLessThan(tracked.points.count,Int(Double(baseline.points.count)*1.2),"Tracking scaled glyph shapes instead of their advances")
    }
    func testFormattedTextBidiVerticalAndLineAlignmentPaintPositionedOutlines()throws{
        let ltr=try textInk("ltr"),rtl=try textInk("rtl"),a=try XCTUnwrap(ltr.bounds),b=try XCTUnwrap(rtl.bounds)
        XCTAssertGreaterThan(b.minX,a.minX+80,"RTL near alignment did not use the right edge")
        XCTAssertEqual(a.width,b.width,accuracy:8);XCTAssertNotEqual(ltr.normalized,rtl.normalized,"Mixed Hebrew/numeric bidi order was not shaped")
        let horizontal=try XCTUnwrap(textInk("horizontal").bounds),vertical=try XCTUnwrap(textInk("vertical").bounds)
        XCTAssertGreaterThan(horizontal.width,horizontal.height*1.5);XCTAssertGreaterThan(vertical.height,vertical.width*1.5)
        // In image coordinates a clockwise turn maps (x,y) to (h-1-y,x).
        // Compare real ink, not only aspect ratio, to reject upright stacks,
        // mirrored glyphs and the double-rotation error of vertical run matrices.
        let hInk=try textInk("horizontal"),vInk=try textInk("vertical")
        let rotated=Set(hInk.normalized.map{point in (point%hInk.width)*hInk.width+Int(horizontal.height)-1-point/hInk.width})
        var overlap=0
        for point in vInk.normalized {
            let x=point%vInk.width,y=point/vInk.width
            if (-1...1).contains(where:{dy in (-1...1).contains(where:{dx in rotated.contains((y+dy)*vInk.width+x+dx)})}){overlap+=1}
        }
        XCTAssertGreaterThan(Double(overlap)/Double(max(1,vInk.points.count)),0.85,"Vertical Latin ink was mirrored or rotated twice")
        let near=try XCTUnwrap(textInk("line-near").bounds),center=try XCTUnwrap(textInk("line-center").bounds),far=try XCTUnwrap(textInk("line-far").bounds)
        XCTAssertGreaterThan(center.minY,near.minY+35);XCTAssertGreaterThan(far.minY,center.minY+35)
        XCTAssertEqual(near.width,center.width,accuracy:1);XCTAssertEqual(near.width,far.width,accuracy:1)
        let pointNear=try textInk("point-near"),pointCenter=try textInk("point-center"),pointFar=try textInk("point-far")
        let pn=try XCTUnwrap(pointNear.bounds),pc=try XCTUnwrap(pointCenter.bounds),pf=try XCTUnwrap(pointFar.bounds)
        func sameTranslatedInk(_ lhs:TextInk,_ rhs:TextInk)->Bool {
            let target=rhs.normalized
            let matched=lhs.normalized.filter{point in
                (-1...1).contains{dy in (-1...1).contains{dx in target.contains(point+dy*lhs.width+dx)}}
            }.count
            return Double(matched)/Double(max(1,lhs.points.count))>0.95
        }
        XCTAssertTrue(sameTranslatedInk(pointNear,pointCenter));XCTAssertTrue(sameTranslatedInk(pointNear,pointFar))
        // Advance width includes glyph side bearings, so the full center/far
        // displacement is compared to visible ink with a two-pixel allowance.
        XCTAssertEqual(pn.minX-pf.minX,pn.width,accuracy:2)
        XCTAssertEqual(pn.minX-pc.minX,(pn.minX-pf.minX)/2,accuracy:2)
        XCTAssertGreaterThan(pn.minY-pf.minY,pn.height)
        XCTAssertEqual(pn.minY-pc.minY,(pn.minY-pf.minY)/2,accuracy:2)
        XCTAssertEqual(pn.width,pc.width,accuracy:1);XCTAssertEqual(pn.width,pf.width,accuracy:1)
        XCTAssertEqual(pn.height,pc.height,accuracy:1);XCTAssertEqual(pn.height,pf.height,accuracy:1)
        let shortNearInk=try textInk("short-cross-near"),shortCenterInk=try textInk("short-cross-center"),shortFarInk=try textInk("short-cross-far")
        XCTAssertTrue(sameTranslatedInk(pointNear,shortNearInk));XCTAssertTrue(sameTranslatedInk(pointNear,shortCenterInk));XCTAssertTrue(sameTranslatedInk(pointNear,shortFarInk))
        let shortNear=try XCTUnwrap(shortNearInk.bounds),shortCenter=try XCTUnwrap(shortCenterInk.bounds),shortFar=try XCTUnwrap(shortFarInk.bounds)
        XCTAssertEqual(shortNear.minY-shortFar.minY,pn.minY-pf.minY-6,accuracy:2)
        XCTAssertEqual(shortNear.minY-shortCenter.minY,(shortNear.minY-shortFar.minY)/2,accuracy:2)
        XCTAssertGreaterThan(shortNear.minY-shortFar.minY,4,"Oversized cross-axis text incorrectly clamped negative alignment")
        XCTAssertEqual(shortNear.minX,shortCenter.minX,accuracy:1);XCTAssertEqual(shortNear.minX,shortFar.minX,accuracy:1)
        let svg=String(decoding:try XCTUnwrap(MetafileImageDecoder.convert(data("plus-formatted-rtl.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("אבג 123") && svg.contains("Helvetica"));XCTAssertTrue(svg.contains("<desc>"));XCTAssertFalse(svg.contains("<text"),"Formatted text still delegates painting/layout to the SVG text engine")
        XCTAssertTrue(svg.contains("<path"));XCTAssertFalse(try textInk("surrogate-pair").points.isEmpty)
        let supplementary=String(decoding:try XCTUnwrap(MetafileImageDecoder.convert(data("plus-formatted-surrogate-pair.emf"))),as:UTF8.self)
        XCTAssertTrue(supplementary.contains("A𝐀B"),"Valid supplementary-plane UTF16 was lost from semantic text")
        let missing=try textInk("no-fallback"),substituted=try textInk("surrogate-pair")
        XCTAssertFalse(missing.points.isEmpty,"NoFontFallback omitted the requested font's missing-glyph outline")
        XCTAssertNotEqual(missing.normalized,substituted.normalized,"NoFontFallback silently retained the supplementary fallback font")
    }
    func testFormattedTextWrappingClipLineLimitAndTrimmingRemainVisible()throws{
        let nowrap=try XCTUnwrap(textInk("nowrap").bounds),wrap=try XCTUnwrap(textInk("wrap").bounds)
        XCTAssertGreaterThan(wrap.height,nowrap.height*2);XCTAssertLessThanOrEqual(wrap.maxX,93)
        let clipped=try XCTUnwrap(textInk("clip").bounds),unclipped=try XCTUnwrap(textInk("no-clip").bounds)
        XCTAssertLessThanOrEqual(clipped.maxX,72);XCTAssertGreaterThan(unclipped.maxX,100,"NoClip discarded glyph overhang outside the layout rectangle")
        XCTAssertFalse(try textInk("partial-line").points.isEmpty);XCTAssertTrue(try textInk("line-limit").points.isEmpty,"LineLimit painted a partial first line")
        let ellipsis=try textInk("ellipsis"),runs=ellipsis.columnRuns
        XCTAssertGreaterThan(runs.count,3)
        if runs.count>=3{
            let dots=Array(runs.suffix(3));XCTAssertTrue(dots.allSatisfy{$0.height<=5 && $0.width<=5},"Trimming did not paint three visible ellipsis dots")
            XCTAssertEqual(dots[0].maxY,dots[2].maxY,accuracy:1);XCTAssertLessThanOrEqual(try XCTUnwrap(ellipsis.bounds).maxX,102)
        }
        let trimmed=try textInk("path-trim"),tail=try textInk("path-tail"),trimBounds=try XCTUnwrap(trimmed.bounds),tailBounds=try XCTUnwrap(tail.bounds)
        let tailWidth=Int(tailBounds.width),left=Int(trimBounds.maxX)-tailWidth,top=Int(trimBounds.minY)
        let suffix=Set(trimmed.points.filter{$0%trimmed.width>=left}.map{($0/trimmed.width-top)*trimmed.width+$0%trimmed.width-left})
        var best=0.0
        for dy in -2...2{for dx in -1...1{
            let shifted=Set(tail.normalized.map{$0+dy*tail.width+dx})
            best=max(best,Double(suffix.intersection(shifted).count)/Double(max(1,tail.points.count)))
        }}
        XCTAssertGreaterThan(best,0.8,"Path trimming lost the independently rendered filename suffix")
    }
    func testFormattedTextHotkeysAndFontDecorationsHaveActualPaintedStrokes()throws{
        let baseline=try textInk("decorations-control"),underline=try textInk("underline"),strike=try textInk("strikeout")
        XCTAssertGreaterThan(underline.points.count,baseline.points.count+10);XCTAssertGreaterThan(strike.points.count,baseline.points.count+10)
        XCTAssertGreaterThan(try XCTUnwrap(underline.bounds).maxY,try XCTUnwrap(baseline.bounds).maxY)
        let glyphs=baseline.columnRuns
        XCTAssertEqual(glyphs.count,4)
        if glyphs.count==4 {
            let spaceX=Int((glyphs[1].maxX+glyphs[2].minX)/2),bounds=try XCTUnwrap(baseline.bounds)
            XCTAssertFalse(baseline.points.contains{$0%baseline.width==spaceX})
            let strikeRows=strike.points.filter{$0%strike.width==spaceX}.map{$0/strike.width}
            XCTAssertFalse(strikeRows.isEmpty,"Strikeout omitted the visible bar across an actual space")
            XCTAssertTrue(strikeRows.allSatisfy{CGFloat($0)>=bounds.minY && CGFloat($0)<bounds.maxY},"Strikeout was painted outside the glyph body")
            XCTAssertTrue(underline.points.contains{$0%underline.width==spaceX && CGFloat($0/underline.width)>=bounds.maxY},"Underline omitted the visible bar beneath the space")
        }
        let plain=try textInk("hotkey-plain"),display=try textInk("hotkey-display"),show=try textInk("hotkey-show"),hide=try textInk("hotkey-hide"),literal=try textInk("hotkey-literal")
        XCTAssertEqual(hide.points,plain.points,"Hidden hotkey marker changed the displayed ABC glyphs")
        XCTAssertEqual(literal.points,display.points,"Escaped ampersand was not rendered literally")
        XCTAssertGreaterThan(show.points.count,plain.points.count+4,"Visible hotkey prefix omitted its underline")
        XCTAssertGreaterThan(try XCTUnwrap(display.bounds).width,try XCTUnwrap(plain.bounds).width+5)
    }
    func testFormattedTextOutlinesRetainBrushWorldTransformAndCapturedClip()throws{
        let base=try textInk("baseline"),translated=try textInk("translated"),clip=try textInk("translated-clip")
        let a=try XCTUnwrap(base.bounds),b=try XCTUnwrap(translated.bounds),c=try XCTUnwrap(clip.bounds)
        XCTAssertEqual(b.minX-a.minX,24,accuracy:1);XCTAssertEqual(b.minY-a.minY,36,accuracy:1)
        XCTAssertEqual(base.normalized,translated.normalized,"World translation reshaped the text")
        XCTAssertLessThanOrEqual(c.maxX,70);XCTAssertGreaterThan(clip.points.count,0)
        XCTAssertLessThan(c.width,b.width*0.7,"Text escaped the device clip captured before world translation")
        let gradient=try textInk("gradient",colored:true)
        XCTAssertGreaterThan(gradient.points.count,base.points.count*9/10,"Brush text lost its glyph interiors")
        XCTAssertEqual(try XCTUnwrap(gradient.bounds).width,a.width,accuracy:1)
        let value=try image("plus-formatted-gradient.emf")
        var red=0,blue=0
        // Probe independently selected dark glyph interiors. A clipped colored
        // rectangle would also color the counters/spaces and fail mask equality.
        XCTAssertEqual(gradient.points,base.points,"Gradient painted a text bounding box instead of glyph outlines")
        for point in gradient.points where point%gradient.width%3==0 && point/gradient.width%3==0 {
            let color=try rgb(value,point%gradient.width,point/gradient.width)
            if color[0]>color[2]+0.25{red+=1};if color[2]>color[0]+0.25{blue+=1}
        }
        XCTAssertGreaterThan(red,8);XCTAssertGreaterThan(blue,8,"Glyph brush lost its independent gradient endpoint")
    }
    func testMalformedFormattedTextFailsExplicitlyWithoutReplacementCharactersOrLayoutGuessing()throws{
        let names=["short","trailing","version","flags","align","line-align","substitution","digit-language","display-controls","hotkey","first-tab-negative","first-tab-nan","leading-negative","trailing-infinite","tracking-negative","tracking-nan","trimming","tabs-negative-count","tabs-count","tabs-truncated","tab-negative","tab-zero","tab-infinite","ranges-negative-count","ranges-count","range-truncated","range-negative","range-overflow","surrogate-high","surrogate-low","surrogate-order","text-count","text-payload-budget"]
        for name in names{
            let original=try data("unsupported-formatted-"+name+".emf")
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),name);XCTAssertNil(ComparisonImage(bytes:original),name)
            XCTAssertEqual(try data("unsupported-formatted-"+name+".emf"),original)
        }
    }

    /// Compare actual native SVG pixels on a fixed interior grid against an
    /// independent Boolean geometry oracle. No generated SVG path/mask is parsed.
    private func classicClip(_ name: String, _ expected: (Int, Int) -> Bool) throws {
        let value = try image("classic-clip-" + name + ".emf")
        let cropped=try interior(value,width:96,height:64,name:name)
        var rgba = [UInt8](repeating: 0, count: 96 * 64 * 4)
        try rgba.withUnsafeMutableBytes { storage in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 96, height: 64,
                bitsPerComponent: 8, bytesPerRow: 96 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        var wrong: [String] = []
        for y in stride(from: 2, to: 64, by: 4) {
            for x in stride(from: 2, to: 96, by: 4) {
                let at = (y * 96 + x) * 4
                let wantedRed = expected(x, y)
                let red = rgba[at] > 240 && rgba[at + 1] < 15 && rgba[at + 2] < 15 && rgba[at + 3] > 240
                let white = rgba[at] > 240 && rgba[at + 1] > 240 && rgba[at + 2] > 240 && rgba[at + 3] > 240
                if wantedRed ? !red : !white {
                    wrong.append("\(x),\(y): expected \(wantedRed ? "red" : "white"), got \(Array(rgba[at..<at+4]))")
                }
            }
        }
        XCTAssertTrue(wrong.isEmpty, "\(name): \(wrong.count) wrong native samples; \(wrong.prefix(12).joined(separator: "; ")); \(rasterDiagnostic(value))")
    }
    private func clipRect(_ rect: (Int, Int, Int, Int), _ x: Int, _ y: Int) -> Bool {
        x >= rect.0 && x < rect.2 && y >= rect.1 && y < rect.3
    }
    func testClassicClipRegionAndPathBooleanOperationsPaintActualGeometry() throws {
        func a(_ x: Int, _ y: Int) -> Bool { clipRect((8, 8, 56, 48), x, y) }
        func b(_ x: Int, _ y: Int) -> Bool { clipRect((32, 20, 80, 56), x, y) }
        for family in ["region", "path"] {
            try classicClip(family + "-and") { a($0, $1) && b($0, $1) }
            try classicClip(family + "-or") { a($0, $1) || b($0, $1) }
            try classicClip(family + "-xor") { a($0, $1) != b($0, $1) }
            try classicClip(family + "-diff") { a($0, $1) && !b($0, $1) }
            try classicClip(family + "-copy", b)
        }
        for operation in ["and", "copy"] { try classicClip("empty-" + operation) { _, _ in false } }
        for operation in ["or", "xor", "diff"] { try classicClip("empty-" + operation, a) }
        try classicClip("default-and", a)
        try classicClip("default-copy", a)
        try classicClip("default-or") { _, _ in true }
        for operation in ["xor", "diff"] { try classicClip("default-" + operation) { !a($0, $1) } }
        try classicClip("path-evenodd") { a($0, $1) && !self.clipRect((20, 20, 44, 36), $0, $1) }
        try classicClip("path-nonzero", a)
        try classicClip("control") { _, _ in true }
        try classicClip("null-reset") { _, _ in true }
        try classicClip("null-reset-mask") { _, _ in true }
        try classicClip("region-device", a)
        try classicClip("region-unknown-size", a)
        try classicClip("region-disjoint") { self.clipRect((8, 8, 24, 48), $0, $1) || self.clipRect((56, 8, 80, 48), $0, $1) }
        try classicClip("region-empty-rectangle") { _, _ in false }
        try classicClip("region-frame-origin") { self.clipRect((0, 4, 48, 44), $0, $1) }
    }
    func testClassicClipCapturesTransformsAndOffsetsOnlyLogicalVectors() throws {
        try classicClip("rect-intersect") { self.clipRect((32, 20, 56, 48), $0, $1) }
        try classicClip("rect-exclude") { self.clipRect((8, 8, 56, 48), $0, $1) && !self.clipRect((32, 20, 80, 56), $0, $1) }
        try classicClip("rect-exclude-default") { !self.clipRect((8, 8, 56, 48), $0, $1) }
        for name in ["rect-world", "path-world"] {
            try classicClip(name) { self.clipRect((18, 8, 50, 32), $0, $1) }
        }
        try classicClip("rect-map") { self.clipRect((12, 14, 44, 46), $0, $1) }
        try classicClip("offset-world") { self.clipRect((24, 4, 72, 44), $0, $1) }
        try classicClip("rect-shear") { x, y in
            y >= 8 && y < 40 && Double(x) >= 8 + Double(y) * 0.5 && Double(x) < 40 + Double(y) * 0.5
        }
        try classicClip("offset-mask") {
            self.clipRect((16, 8, 64, 48), $0, $1) != self.clipRect((40, 20, 88, 56), $0, $1)
        }
        for name in ["offset-offcanvas", "path-offcanvas-offset"] {
            try classicClip(name) { self.clipRect((8, 8, 40, 48), $0, $1) }
        }
        try classicClip("offset-none") { _, _ in true }
        try classicClip("offset-empty") { _, _ in false }
    }
    func testClassicMetaRegionsRemainSeparateAcrossSelectionResetAndRestore() throws {
        let a: (Int, Int) -> Bool = { self.clipRect((8, 8, 56, 48), $0, $1) }
        let intersection: (Int, Int) -> Bool = { self.clipRect((32, 20, 56, 48), $0, $1) }
        for name in ["meta-selected", "meta-repeated", "restore-meta-and-selection"] { try classicClip(name, intersection) }
        for name in ["meta-null-reset", "meta-offset-none", "meta-repeated-no-selection", "restore-negative-depth", "restore-offset", "restore-absolute-one"] { try classicClip(name, a) }
        try classicClip("meta-offset-selection") { a($0, $1) && self.clipRect((16, 12, 64, 48), $0, $1) }
        try classicClip("meta-empty") { _, _ in false }
        try classicClip("restore-before-meta") { _, _ in true }
        try classicClip("restore-absolute-two") { self.clipRect((32, 20, 80, 56), $0, $1) }
        for name in ["path-preserved-region", "path-preserved-meta"] { try classicClip(name, intersection) }
        try classicClip("path-preserved-offset") { self.clipRect((32, 20, 64, 48), $0, $1) }
    }
    func testClassicGetDCRetiresSelectedAndMetaClipsBeforeNextInterval() throws {
        for name in ["selected", "meta"] {
            let value = try image("classic-clip-getdc-" + name + ".emf")
            // First interval's A remains red outside B; B must paint green both
            // inside A and outside A in the independently acquired second DC.
            try primary(value, 0, 16, 12); try primary(value, 0, 48, 12)
            try primary(value, 1, 40, 32); try primary(value, 1, 72, 40)
            try primary(value, 1, 40, 52)
            for (x, y) in [(88, 60), (4, 4), (16, 52)] {
                XCTAssertTrue(try rgb(value, x, y).allSatisfy { $0 > 0.9 }, "GetDC \(name) painted outside A/B at \(x),\(y)")
            }
        }
    }
    func testMalformedClassicClipsFailBeforeReturningSuccessfulPartialImages() throws {
        let names = ["region-size-small", "region-size-large", "region-mode-zero", "region-mode-six",
                     "region-header-size", "region-type", "region-count", "region-buffer-size", "region-reversed",
                     "region-truncated", "region-trailing", "null-mode-0", "null-mode-1", "null-mode-2",
                     "null-mode-3", "null-mode-4", "null-mode-6", "null-trailing", "region-short",
                     "path-mode-0", "path-mode-6", "path-missing", "path-short", "path-consumed",
                     "rect-short", "offset-short", "offset-domain-budget", "offset-domain-area-budget", "restore-unmatched", "restore-depth", "restore-absolute-missing"]
        for name in names {
            let original = try data("unsupported-classic-clip-" + name + ".emf")
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original), name)
            XCTAssertEqual(try data("unsupported-classic-clip-" + name + ".emf"), original)
        }
        for name in ["region-count", "region-reversed", "path-consumed", "restore-depth"] {
            XCTAssertNil(ComparisonImage(bytes: try data("unsupported-classic-clip-" + name + ".emf")), name)
        }
    }

}

extension MetafileImageTests {
    private struct PenPixels {
        let width: Int, height: Int
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let at = (y * width + x) * 4
            return Array(bytes[at..<(at + 4)])
        }
    }
    private func penPixels(_ name: String) throws -> PenPixels {
        try metafilePixels("plus-pen-"+name+".emf")
    }
    private func metafilePixels(_ name:String) throws -> PenPixels {
        let value = try image(name)
        let width=96,height=64
        let cropped=try interior(value,width:width,height:height,emf:name.hasSuffix(".emf"),name:name)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return .init(width: width, height: height, bytes: bytes)
    }
    /// Independent signed-distance primitives describe expected physical ink,
    /// rather than parsing the SVG or asking the implementation to stroke a path.
    private func penBox(_ x: Double, _ y: Double, _ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Double {
        let dx = abs(x - (l + r) / 2) - (r - l) / 2
        let dy = abs(y - (t + b) / 2) - (b - t) / 2
        return hypot(max(0, dx), max(0, dy)) + min(0, max(dx, dy))
    }
    private func penPolygon(_ x: Double, _ y: Double, _ points: [(Double, Double)]) -> Double {
        var distance = Double.infinity, inside = false
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            let dx = b.0 - a.0, dy = b.1 - a.1
            let u = min(1, max(0, ((x - a.0) * dx + (y - a.1) * dy) / (dx * dx + dy * dy)))
            distance = min(distance, hypot(x - a.0 - u * dx, y - a.1 - u * dy))
            if (a.1 > y) != (b.1 > y), x < a.0 + (y - a.1) * dx / dy { inside.toggle() }
        }
        return inside ? -distance : distance
    }
    private func penCap(_ x: Double, _ y: Double, at endpoint: Double, start: Bool, cap: Int, width: Double) -> Double {
        let h = width / 2, direction = start ? -1.0 : 1.0
        switch cap {
        case 0, 16: return .infinity
        case 1: return penBox(x, y, endpoint - h, -h, endpoint + h, h)
        case 2: return hypot(x - endpoint, y) - h
        case 3: return penPolygon(x, y, [(endpoint, -h), (endpoint, h), (endpoint + direction * h, 0)])
        // Anchor dimensions follow the independently inspected Wine GDI+
        // implementation policy; this is not a Windows pixel certification.
        case 17:
            let a = width / sqrt(2)
            return penBox(x, y, endpoint - a, -a, endpoint + a, a)
        case 18: return hypot(x - endpoint, y) - width
        case 19: return penPolygon(x, y, [(endpoint - width, 0), (endpoint, -width), (endpoint + width, 0), (endpoint, width)])
        case 20:
            let base = endpoint - direction * 2 * width, half = 2 * width / sqrt(3)
            return penPolygon(x, y, [(endpoint, 0), (base, -half), (base, half)])
        default: XCTFail("Unknown oracle cap"); return .infinity
        }
    }
    private func penSegment(_ x: Double, _ y: Double, from a: Double, to b: Double, width: Double,
                            start: Int = 0, end: Int = 0) -> Double {
        let left = a + (start == 20 ? width : 0), right = b - (end == 20 ? width : 0)
        return min(penBox(x, y, left, -width / 2, right, width / 2),
                   penCap(x, y, at: a, start: true, cap: start, width: width),
                   penCap(x, y, at: b, start: false, cap: end, width: width))
    }
    private func penAssert(_ name: String, distance: (Double, Double) -> Double, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertInk(penPixels(name),name:name,distance:distance,file:file,line:line)
    }
    private func assertInk(_ value:PenPixels,name:String,distance:(Double,Double)->Double,file:StaticString=#filePath,line:UInt=#line) throws {
        var wrong: [String] = [], checked = 0, redSamples = 0
        // Ignore only the independently defined one-pixel antialias boundary.
        // Both ink interiors and the complete surrounding white canvas count.
        for y in 0..<value.height {
            for x in 0..<value.width {
                let d = distance(Double(x) + 0.5, Double(y) + 0.5)
                if abs(d) < 1 { continue }
                let p = value.pixel(x, y), red = p[0] > 240 && p[1] < 15 && p[2] < 15 && p[3] > 240
                let white = p[0] > 240 && p[1] > 240 && p[2] > 240 && p[3] > 240
                checked += 1; if d < 0 { redSamples += 1 }
                if d < 0 ? !red : !white { wrong.append("\(x),\(y): distance \(d), rgba \(p)") }
            }
        }
        XCTAssertGreaterThan(checked, 900, name, file: file, line: line)
        XCTAssertGreaterThan(redSamples, 3, name, file: file, line: line)
        XCTAssertTrue(wrong.isEmpty, "\(name): \(wrong.count) incorrect native samples; \(wrong.prefix(10).joined(separator: "; "))", file: file, line: line)
    }
    private func penSamePixels(_ name: String, _ control: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try penPixels(name), expected = try penPixels(control)
        XCTAssertEqual(value.bytes.count, expected.bytes.count, file: file, line: line)
        let wrong = zip(value.bytes, expected.bytes).filter { pair in abs(Int(pair.0) - Int(pair.1)) > 2 }.count
        XCTAssertEqual(wrong, 0, "\(name) differs from independent control \(control)", file: file, line: line)
    }

    func testPenFlatDirectionalAndAsymmetricCapsPaintAnalyticalOutlines() throws {
        try penAssert("flat") { self.penBox($0, $1, 20, 28, 76, 36) }
        try penAssert("vertical") { self.penBox($0, $1, 44, 12, 52, 52) }
        let length = hypot(56.0, 32.0)
        try penAssert("diagonal") { x, y in
            let u = ((x - 20) * 56 + (y - 16) * 32) / length
            let v = (-(x - 20) * 32 + (y - 16) * 56) / length
            return self.penBox(u, v, 0, -4, length, 4)
        }
        try penAssert("asymmetric-caps") { self.penSegment($0 - 20, $1 - 32, from: 0, to: 56, width: 8, start: 1, end: 2) }
        try penAssert("round-triangle") { self.penSegment($0 - 20, $1 - 32, from: 0, to: 56, width: 8, start: 2, end: 3) }
        for (cap, label) in [(0, "flat"), (1, "square"), (2, "round"), (3, "triangle"), (16, "no-anchor"),
                             (17, "square-anchor"), (18, "round-anchor"), (19, "diamond-anchor"), (20, "arrow-anchor")] {
            try penAssert("end-" + label) { self.penSegment($0 - 20, $1 - 32, from: 0, to: 56, width: 8, end: cap) }
            try penAssert("start-" + label) { self.penSegment($0 - 20, $1 - 32, from: 0, to: 56, width: 8, start: cap) }
        }
        for name in ["path", "curve-range", "curve-range-compressed", "lines-compressed", "lines-relative"] {
            try penSamePixels(name, "flat")
        }
        try penSamePixels("lines-closed", "center")
        try penSamePixels("rect-compressed", "center")
        try penSamePixels("width-zero", "width-one")
    }

    func testPenCompoundBandsAndClosedInsetRetainDistinctGeometry() throws {
        for (name, bands, reversed) in [
            ("compound", [(0.0, 0.15), (0.25, 0.5), (0.7, 1.0)], false),
            ("compound-asymmetric", [(0.0, 0.2), (0.45, 0.75)], false),
            ("compound-reversed", [(0.0, 0.2), (0.45, 0.75)], true),
        ] {
            try penAssert(name) { x, y in
                let normal = reversed ? 32 - y : y - 32
                return bands.map { self.penBox(x, normal, 20, ($0.0 - 0.5) * 20, 76, ($0.1 - 0.5) * 20) }.min()!
            }
        }
        try penAssert("center") { x, y in
            max(self.penBox(x, y, 16, 12, 80, 52), -self.penBox(x, y, 24, 20, 72, 44))
        }
        try penAssert("inset") { x, y in
            max(self.penBox(x, y, 20, 16, 76, 48), -self.penBox(x, y, 28, 24, 68, 40))
        }
        try penAssert("compound-closed") { x, y in
            min(max(self.penBox(x, y, 12, 8, 84, 56), -self.penBox(x, y, 16, 12, 80, 52)),
                max(self.penBox(x, y, 24, 20, 72, 44), -self.penBox(x, y, 28, 24, 68, 40)))
        }
        try penSamePixels("open-inset", "flat")
        let dashed = try image("plus-pen-inset-dash.emf")
        for (x, y) in [(32, 20), (64, 20), (56, 44), (28, 44), (24, 24)] { try primary(dashed, 0, x, y) }
        for (x, y) in [(48, 20), (40, 44), (24, 36), (12, 20), (48, 32)] {
            XCTAssertTrue(try rgb(dashed, x, y).allSatisfy { $0 > 0.95 }, "Inset dash gap at \(x),\(y) was scaled with the doubled outline")
        }
        let offset = try image("plus-pen-inset-dash-offset.emf")
        try primary(offset, 0, 28, 20); try primary(offset, 0, 56, 20)
        XCTAssertTrue(try rgb(offset, 40, 20).allSatisfy { $0 > 0.95 }, "Inset dash phase must use original pen width")
    }

    func testPenLinearTransformIgnoresTranslationAndRespectsCapturedWorldClip() throws {
        try penAssert("transform") { self.penBox($0, $1, 20, 20, 76, 44) }
        try penSamePixels("transform-translation", "transform")
        try penAssert("transform-shear") { x, y in
            self.penBox((x - 20) - (y - 32), y - 32, 0, -4, 56, 4)
        }
        try penAssert("transform-caps") { x, y in
            self.penSegment((x - 20) / 2, (y - 32) / 3, from: 0, to: 28, width: 8, start: 1, end: 2)
        }
        try penAssert("world-clip") { self.penBox($0, $1, 24, 20, 76, 44) }
        try penSamePixels("unit-world-page", "flat")
        try penSamePixels("unit-point-page", "flat")
        try penAssert("unit-pixel-page") { self.penBox($0, $1, 20, 29, 76, 35) }
        try penAssert("unit-inch-page") { self.penBox($0, $1, 20, 20, 76, 44) }
        try penSamePixels("hairline-world", "width-one")
    }

    private func penDash(_ x: Double, _ y: Double, pattern: [Double], offset: Double = 0,
                         dashCap: Int = 0, start: Int = 0, end: Int = 0) -> Double {
        let values = (pattern.count % 2 == 0 ? pattern : pattern + pattern).map { $0 * 4 }
        let period = values.reduce(0, +), phase = offset * 4
        var distance = Double.infinity
        for repeatIndex in -2...8 {
            var position = Double(repeatIndex) * period - phase
            for index in values.indices {
                let next = position + values[index]
                if index % 2 == 0 {
                    let a = max(0, position), b = min(56, next)
                    if b > a {
                        distance = min(distance, penSegment(x - 20, y - 32, from: a, to: b, width: 4,
                            start: a == 0 ? start : dashCap, end: b == 56 ? end : dashCap))
                    }
                }
                position = next
            }
        }
        return distance
    }
    func testPenDashPatternsOffsetsAndIndependentDashCapsHaveActualGaps() throws {
        try penAssert("style-solid") { self.penBox($0, $1, 20, 30, 76, 34) }
        for (name, pattern) in [("dash", [3.0, 1]), ("dot", [1.0, 1]), ("dash-dot", [3.0, 1, 1, 1]), ("dash-dot-dot", [3.0, 1, 1, 1, 1, 1])] {
            try penAssert("style-" + name) { self.penDash($0, $1, pattern: pattern) }
        }
        try penAssert("dash-offset") { self.penDash($0, $1, pattern: [3, 1], offset: 1) }
        try penAssert("dash-negative-offset") { self.penDash($0, $1, pattern: [3, 1], offset: -1) }
        try penAssert("dash-custom") { self.penDash($0, $1, pattern: [2, 1]) }
        try penAssert("dash-odd") { self.penDash($0, $1, pattern: [2, 1, 1]) }
        try penAssert("dash-round") { self.penDash($0, $1, pattern: [3, 1], dashCap: 2) }
        try penAssert("dash-triangle") { self.penDash($0, $1, pattern: [3, 1], dashCap: 3) }
        try penAssert("dash-round-line-caps") { self.penDash($0, $1, pattern: [3, 1], dashCap: 2, start: 1, end: 3) }
    }

    private func penJoin(_ x: Double, _ y: Double, kind: String) -> Double {
        let a = (24.0, 48.0), b = (48.0, 12.0), c = (72.0, 48.0)
        let length = hypot(24.0, 36.0), nx = 36 / length * 4, ny = 24 / length * 4
        let left = [(a.0 - nx, a.1 - ny), (b.0 - nx, b.1 - ny), (b.0 + nx, b.1 + ny), (a.0 + nx, a.1 + ny)]
        let right = [(b.0 + nx, b.1 - ny), (c.0 + nx, c.1 - ny), (c.0 - nx, c.1 + ny), (b.0 - nx, b.1 + ny)]
        let bodies = min(penPolygon(x, y, left), penPolygon(x, y, right))
        if kind == "round" { return min(bodies, hypot(x - b.0, y - b.1) - 4) }
        let outerLeft = (b.0 - nx, b.1 - ny), outerRight = (b.0 + nx, b.1 - ny)
        if kind == "bevel" || kind == "miter-clipped" { return min(bodies, penPolygon(x, y, [outerLeft, b, outerRight])) }
        let extent = 4 * length / 24
        let tip = (48.0, 12 - extent)
        if kind == "miter-limited" {
            // MS LineJoinMiter clips from the INNER intersection, using the
            // full pen width. LineJoinMiterClipped instead falls back to bevel.
            let limitY = 12 + extent - 1.6 * 8
            let u = (limitY - outerLeft.1) / (tip.1 - outerLeft.1)
            let first = (outerLeft.0 + u * (tip.0 - outerLeft.0), limitY)
            let second = (outerRight.0 + u * (tip.0 - outerRight.0), limitY)
            return min(bodies, penPolygon(x, y, [outerLeft, first, second, outerRight]))
        }
        return min(bodies, penPolygon(x, y, [outerLeft, tip, outerRight]))
    }
    func testPenMiterClippingUsesInnerCornerAndDiffersFromBevelInBothWindings() throws {
        for name in ["miter", "miter-limited", "bevel", "round", "miter-clipped"] {
            try penAssert("join-" + name) { self.penJoin($0, $1, kind: name) }
            try penAssert("join-" + name + "-reversed") { self.penJoin($0, $1, kind: name) }
        }
        let clipped = try penPixels("join-miter-limited"), bevel = try penPixels("join-miter-clipped")
        XCTAssertLessThan(clipped.pixel(48, 8)[1], 15)
        XCTAssertGreaterThan(bevel.pixel(48, 8)[1], 240)
    }

    func testPenCurvesAndBrushesShareNativeOutlinePaintingWithoutStateLeaks() throws {
        let ellipse = try image("plus-pen-ellipse.emf"), arc = try image("plus-pen-arc.emf"), bezier = try image("plus-pen-bezier.emf")
        for value in [ellipse, arc] {
            try primary(value, 0, 48, 52)
            XCTAssertTrue(try rgb(value, 48, 32).allSatisfy { $0 > 0.95 })
        }
        try primary(ellipse, 0, 48, 12)
        XCTAssertTrue(try rgb(arc, 48, 12).allSatisfy { $0 > 0.95 })
        for (x, y) in [(34, 25), (48, 32), (62, 38)] { try primary(bezier, 0, x, y) }
        XCTAssertTrue(try rgb(bezier, 48, 4).allSatisfy { $0 > 0.95 })
        let backtrack = try image("plus-pen-bezier-backtrack.emf")
        try primary(backtrack, 0, 34, 32); try primary(backtrack, 0, 62, 32)
        for x in [20, 76] { XCTAssertTrue(try rgb(backtrack, x, 32).allSatisfy { $0 > 0.95 }) }
        try penSamePixels("ellipse-compressed", "ellipse")
        try penSamePixels("bezier-compressed", "bezier")
        try penSamePixels("closed-curve-relative", "closed-curve-control")
        try penSamePixels("closed-curve-relative-c", "closed-curve-control")
        let closed = try image("plus-pen-closed-curve-relative.emf")
        for (x, y) in [(48, 16), (62, 32), (34, 32)] { try primary(closed, 0, x, y) }
        XCTAssertTrue(try rgb(closed, 48, 28).allSatisfy { $0 > 0.95 })
        for brush in ["hatch", "gradient", "texture"] { try penSamePixels(brush, brush + "-control") }
        let gradient = try image("plus-pen-gradient.emf")
        let red = try rgb(gradient, 20, 32), blue = try rgb(gradient, 75, 32)
        XCTAssertGreaterThan(red[0], red[2] + 0.6); XCTAssertGreaterThan(blue[2], blue[0] + 0.6)
        let texture = try image("plus-pen-texture.emf")
        try primary(texture, 0, 24, 28); try primary(texture, 1, 40, 28); try primary(texture, 2, 24, 36)
        let ownership = try image("plus-pen-brush-ownership.emf")
        try primary(ownership, 2, 48, 32); try primary(ownership, 1, 48, 48)
        let ownershipPixels = try penPixels("brush-ownership")
        var hatchRed = 0, hatchBlue = 0
        for y in 12..<20 { for x in 24..<72 {
            let p = ownershipPixels.pixel(x, y)
            if p[0] > 240 && p[1] < 15 && p[2] < 15 { hatchRed += 1 }
            if p[2] > 240 && p[0] < 15 && p[1] < 15 { hatchBlue += 1 }
        } }
        XCTAssertGreaterThan(hatchRed, 10); XCTAssertGreaterThan(hatchBlue, 10)
    }

    func testMalformedPenObjectsFailWithoutPublishingSuccessfulPartialImages() throws {
        let names = ["version", "type", "flags", "unit", "brush-version", "brush-type", "width-negative", "width-nan", "width-infinite",
                     "truncated-header", "truncated-brush", "trailing-brush", "legacy-unversioned-brush", "transform-truncated", "transform-singular", "transform-nan",
                     "start-cap", "end-cap", "join", "miter-nan", "miter-negative", "dash-style", "dash-cap", "dash-offset", "dash-custom-missing",
                     "dash-pattern-empty", "dash-pattern-negative", "dash-pattern-zero", "dash-pattern-nan", "dash-pattern-count", "dash-pattern-truncated", "alignment",
                     "compound-single", "compound-odd", "compound-descending", "compound-duplicate", "compound-negative", "compound-above-one", "compound-nan", "compound-count", "compound-truncated",
                     "inset-compound", "inset-triangle-dash", "custom-start-cap", "custom-end-cap", "hatch-style", "texture-image", "closed-curve-two-points", "curve-offset", "curve-segment-count", "curve-zero-segments", "curve-negative-tension", "lines-one-point", "lines-truncated", "lines-relative-truncated"]
        for name in names {
            let original = try data("unsupported-pen-" + name + ".emf")
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original), name)
            XCTAssertEqual(try data("unsupported-pen-" + name + ".emf"), original)
        }
        for name in ["brush-version", "legacy-unversioned-brush", "transform-singular", "compound-odd", "inset-compound"] {
            XCTAssertNil(ComparisonImage(bytes: try data("unsupported-pen-" + name + ".emf")), name)
        }
    }
}

extension MetafileImageTests {
    private func compressedPixels(_ name:String) throws -> PenPixels {try metafilePixels("plus-compressed-path-"+name+".emf")}
    private func compressedSame(_ name:String,_ control:String,file:StaticString=#filePath,line:UInt=#line) throws {
        let value=try compressedPixels(name),expected=try compressedPixels(control)
        XCTAssertEqual(value.width,expected.width,file:file,line:line);XCTAssertEqual(value.height,expected.height,file:file,line:line)
        let wrong=zip(value.bytes,expected.bytes).filter{abs(Int($0.0)-Int($0.1))>2}.count
        XCTAssertEqual(wrong,0,"\(name) differs from independent float coordinate control \(control)",file:file,line:line)
    }
    func testCompressedPathsPreserveAlternateFillSubpathsAndPointMetadata() throws {
        for encoding in ["float","short","relative","relative-c"] {
            let name="fill-"+encoding
            try assertInk(compressedPixels(name),name:name) {x,y in max(self.penBox(x,y,8,8,88,56),-self.penBox(x,y,24,20,72,44))}
            if encoding != "float" {try compressedSame(name,"fill-float")}
        }
        for encoding in ["float","relative"] {try compressedSame("metadata-"+encoding,"fill-float")}
    }
    func testCompressedPathsSignedIntegerLimitsAndRLE63BoundaryRetainEveryPoint() throws {
        for name in ["integer-limits","long-runs"] {
            try compressedSame(name+"-relative",name+"-float")
            try assertInk(compressedPixels(name+"-relative"),name:name) {self.penBox($0,$1,8,12,72,52)}
        }
        try compressedSame("integer7-boundary-relative","integer7-boundary-float")
        try assertInk(compressedPixels("integer7-boundary-relative"),name:"signed7-boundaries") {self.penBox($0,$1,8,8,71.5,39.75)}
    }
    func testCompressedPathsStrokeCubicTriplesSubpathsAndExplicitClose() throws {
        for encoding in ["float","short","relative","relative-c"] {
            if encoding != "float" {try compressedSame("stroke-"+encoding,"stroke-float")}
            let value=try compressedPixels("stroke-"+encoding)
            // Cubic t=.5 gives (28,18), independent of the decoder/outline.
            for(x,y) in [(28,18),(8,46),(48,46),(76,48)] {let p=value.pixel(x,y);XCTAssertGreaterThan(p[0],240);XCTAssertLessThan(p[1],15)}
            for(x,y) in [(28,40),(28,48),(56,48)] {let p=value.pixel(x,y);XCTAssertGreaterThan(p[1],240)}
        }
        try compressedSame("cubic-metadata-relative","cubic-metadata-float")
        let closed=try compressedPixels("cubic-metadata-relative")
        XCTAssertGreaterThan(closed.pixel(28,48)[0],240);XCTAssertLessThan(closed.pixel(28,48)[1],15,"Close belongs to the cubic endpoint and closes its figure")
    }
    func testCompressedPathsRegionAndDeviceCapturedClipUseActualBoundaries() throws {
        for encoding in ["float","short","relative","relative-c"] {
            try compressedSame("region-"+encoding,"fill-float")
            try compressedSame("clip-"+encoding,"clip-float")
            try assertInk(compressedPixels("clip-"+encoding),name:"captured-clip-"+encoding) {self.penBox($0,$1,16,12,80,52)}
        }
    }
    func testCompressedPathsEmbeddedCapsUseSamePhysicalEndpointGeometry() throws {
        for encoding in ["float","short","relative","relative-c"] {
            try compressedSame("cap-"+encoding,"cap-float")
            try assertInk(compressedPixels("cap-"+encoding),name:"custom-cap-"+encoding) {min(self.penBox($0,$1,20,30,76,34),self.penBox($0,$1,76,24,88,40))}
        }
    }
    func testCompressedPathsExistingEllipseGradientSubsetKeepsItsOwnPaintAndTransform() throws {
        for encoding in ["float","short","relative","relative-c"] {
            try compressedSame("gradient-"+encoding,"gradient-float")
            let value=try compressedPixels("gradient-"+encoding)
            XCTAssertGreaterThan(value.pixel(48,32)[0],240);XCTAssertLessThan(value.pixel(48,32)[2],15)
            XCTAssertGreaterThan(value.pixel(66,32)[2],240);XCTAssertLessThan(value.pixel(66,32)[0],15)
            XCTAssertGreaterThan(value.pixel(8,8)[1],240)
        }
    }
    func testMalformedCompressedPathsRefuseAllSharedConsumersAndAggregateBudgets() throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-compressed-path-") && $0.hasSuffix(".emf")}.sorted()
        XCTAssertEqual(names.count,41,"Keep every independently framed refusal fixture enrolled")
        let budgetDiagnostics=["unsupported-compressed-path-aggregate-points.emf":"aggregate decoded path point limit",
                               "unsupported-compressed-path-relative-coordinate-budget.emf":"path coordinate budget exceeded"]
        for name in names {
            let original=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),name) {error in
                if let expected=budgetDiagnostics[name] {
                    guard let failure=error as? MetafileImageFailure,case .failed(let diagnostic)=failure else {
                        return XCTFail("\(name) must reach the explicit decoder budget, not fail through a deadline/runtime/output error: \(error)")
                    }
                    XCTAssertTrue(diagnostic.contains(expected),"\(name): expected explicit budget diagnostic '\(expected)', got '\(diagnostic)'")
                }
            }
            XCTAssertEqual(try data(name),original)
        }
        for suffix in ["relative-truncated","region-rle-overrun","cap-relative-truncated","gradient-relative-truncated"] {
            XCTAssertNil(ComparisonImage(bytes:try data("unsupported-compressed-path-"+suffix+".emf")),suffix)
        }
    }
}

extension MetafileImageTests {
    func testCustomPenCapsUseIndependentFillStrokeWindingAndEndpointGeometry() throws {
        func body(_ x:Double,_ y:Double)->Double {penBox(x,y,20,30,76,34)}
        try penAssert("custom-fill") {min(body($0,$1),self.penBox($0,$1,76,24,88,40))}
        try penAssert("custom-start") {min(body($0,$1),self.penBox($0,$1,8,24,20,40))}
        try penAssert("custom-reversed") {min(body($0,$1),self.penBox($0,$1,8,24,20,40))}
        try penAssert("custom-both-ends") {x,y in min(body(x,y),self.penBox(x,y,76,24,88,40),self.penPolygon(x,y,[(32,24),(20,32),(32,40)]))}
        try penAssert("custom-vertical") {min(self.penBox($0,$1,46,12,50,40),self.penBox($0,$1,40,40,56,52))}
        let length=hypot(40.0,24.0)
        try penAssert("custom-diagonal") {x,y in
            let u=((x-20)*40+(y-16)*24)/length,v=(-(x-20)*24+(y-16)*40)/length
            return min(self.penBox(u,v,0,-2,length,2),self.penBox(u,v,length,-8,length+12,8))
        }
        try penAssert("custom-stroke") {x,y in
            let ring=max(self.penBox(x,y,62,22,82,42),-self.penBox(x,y,66,26,78,38))
            return min(body(x,y),ring)
        }
        try penSamePixels("custom-both-paths","custom-stroke")
        try penAssert("custom-winding") {min(body($0,$1),self.penBox($0,$1,76,20,92,44))}
        try penAssert("custom-winding-hole-shaft") {x,y in
            let cap=max(self.penBox(x,y,64,20,80,44),-self.penBox(x,y,68,28,76,36))
            return min(body(x,y),cap)
        }
        let curve=try penPixels("custom-curve")
        XCTAssertGreaterThan(curve.pixel(82,32)[0],240);XCTAssertLessThan(curve.pixel(82,32)[1],15)
        XCTAssertGreaterThan(curve.pixel(90,32)[1],240)
        for encoded in ["short","relative","relative-c","rle","padding","hotspot-ignored"] {try penSamePixels("custom-"+encoded,"custom-fill")}
    }
    func testCustomPenCapInsetWidthScaleEmptyGeometryAndCompoundDashEnds() throws {
        try penAssert("custom-width-scale") {min(self.penBox($0,$1,20,30,76,34),self.penBox($0,$1,76,16,100,48))}
        for (name,end) in [("inset",68.0),("negative-inset",84.0)] {
            try penAssert("custom-"+name) {x,y in
                let ring=max(self.penBox(x,y,62,22,82,42),-self.penBox(x,y,66,26,78,38))
                return min(self.penBox(x,y,20,30,end,34),ring)
            }
        }
        for name in ["empty-path","scale-zero","inactive"] {try penAssert("custom-"+name) {self.penBox($0,$1,20,30,76,34)}}
        try penAssert("custom-base-round") {min(self.penBox($0,$1,20,30,76,34),hypot($0-76,$1-32)-2)}
        try penAssert("custom-compound") {x,y in min(self.penBox(x,y,20,28,76,30),self.penBox(x,y,20,34,76,36),self.penBox(x,y,76,16,100,48))}
        try penAssert("custom-dash") {min(self.penDash($0,$1,pattern:[3,1],dashCap:2),self.penBox($0,$1,76,24,88,40))}
        try penAssert("custom-short-line") {self.penBox($0,$1,44,24,56,40)}
        try penAssert("custom-multiple-figures") {x,y in min(self.penBox(x,y,12,14,48,18),self.penBox(x,y,48,8,60,24),self.penBox(x,y,12,46,48,50),self.penBox(x,y,48,40,60,56))}
        try penSamePixels("custom-open-inset","custom-fill")
        try penAssert("custom-closed") {max(self.penBox($0,$1,18,14,78,50),-self.penBox($0,$1,22,18,74,46))}
        try penAssert("custom-closed-inset") {max(self.penBox($0,$1,20,16,76,48),-self.penBox($0,$1,24,20,72,44))}
        try penSamePixels("custom-object","flat")
    }
    func testCustomArrowCapsHaveDistinctFilledNotchDiamondAndOutlineGeometry() throws {
        let neck=76.0-4*4/3
        for (name,middle) in [("filled",0.0),("notch",2.0),("diamond",-2.0)] {
            try penAssert("custom-arrow-"+name) {x,y in min(self.penBox(x,y,20,30,neck,34),self.penPolygon(x,y,[(60,38),(76,32),(60,26),(60+4*middle,32)]))}
        }
        try penAssert("custom-arrow-scaled") {min(self.penBox($0,$1,20,30,neck,34),self.penPolygon($0,$1,[(44,44),(76,32),(44,20)]))}
        try penAssert("custom-arrow-invisible") {self.penBox($0,$1,20,30,neck,34)}
        for name in ["zero-width","zero-height"] {try penAssert("custom-arrow-"+name) {self.penBox($0,$1,20,30,76,34)}}
        try penAssert("custom-arrow-start") {min(self.penBox($0,$1,20+4*4/3,30,76,34),self.penPolygon($0,$1,[(36,26),(20,32),(36,38)]))}
        try penAssert("custom-arrow-asymmetric") {x,y in min(self.penBox(x,y,20,30,neck,34),self.penBox(x,y,8,24,20,40),self.penPolygon(x,y,[(60,38),(76,32),(60,26)]))}
        try penSamePixels("custom-arrow-outline-middle","custom-arrow-outline")
        try penSamePixels("custom-arrow-hotspot-ignored","custom-arrow-filled")
        try penSamePixels("custom-curve-relative","custom-curve")
        let filled=try penPixels("custom-arrow-filled"),outline=try penPixels("custom-arrow-outline")
        // The V's width-four miter reaches x=76+2*sqrt(1+0.375²)/0.375.
        // Pixel (77,32) lies wholly inside that outline and beyond the filled
        // arrow tip x=76; (79,32) crosses its antialiased sloping boundary.
        XCTAssertGreaterThan(outline.pixel(77,32)[0],240);XCTAssertLessThan(outline.pixel(77,32)[1],15)
        XCTAssertGreaterThan(filled.pixel(77,32)[1],240)
        let styled=try (0..<4).map {try penPixels("custom-stroke-style-"+String($0)).bytes}
        for index in 1..<styled.count {XCTAssertNotEqual(styled[index],styled[index-1],"Custom local cap/join style was ignored")}
    }
    func testCustomPenCapsRespectPenWorldClipAndEmbeddedBrushPainting() throws {
        try penAssert("custom-transform") {x,y in
            let local=x-0.5*y
            return min(self.penBox(local,y,4,30,60,34),self.penBox(local,y,60,24,72,40))/2
        }
        try penSamePixels("custom-transform-translation","custom-transform")
        try penAssert("custom-world-clip") {x,y in max(min(self.penBox(x,y,24,30,80,34),self.penBox(x,y,80,24,92,40)),self.penBox(x,y,12,12,84,52))}
        for brush in ["hatch","gradient","texture"] {try penSamePixels("custom-"+brush,"custom-"+brush+"-control")}
    }
    func testMalformedCustomPenCapsRefuseCompleteConversionWithoutMutatingInput() throws {
        let names=["version","type","flags","base-cap","stroke-start","stroke-end","join","path-length-negative","path-length-large","path-version","path-count","path-flags",
            "inset-nan","miter-nan","miter-zero","scale-negative","scale-infinite","path-coordinate","truncated","trailing","path-trailing",
            "path-first-line","path-cubic-count","path-cubic-close","path-type-reserved","path-relative-truncated","path-rle-zero","path-rle-overrun","path-rle-marker","path-rle-bezier-kind","path-rle-reserved-flag",
            "arrow-fill-state","arrow-negative-width","arrow-negative-height","arrow-middle-nan","arrow-scale-negative","overlong-inset","object-type","object-truncated"]
        for name in names {
            let filename="unsupported-pen-custom-"+name+".emf",original=try data(filename)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),name)
            XCTAssertEqual(try data(filename),original)
        }
        for name in ["path-cubic-count","path-rle-overrun","overlong-inset","object-truncated"] {XCTAssertNil(ComparisonImage(bytes:try data("unsupported-pen-custom-"+name+".emf")),name)}
    }
    private func positionedInk(_ bytes:Data)throws->TextInk {
        let rendered=try XCTUnwrap(ComparisonImage(bytes:bytes)),width=96,height=64
        let cropped=try interior(rendered,width:width,height:height)
        var rgba=[UInt8](repeating:0,count:width*height*4)
        try rgba.withUnsafeMutableBytes { storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cropped,in:CGRect(x:0,y:0,width:width,height:height))
        }
        return TextInk(width:width,height:height,points:Set((0..<width*height).filter{let p=$0*4;return rgba[p+3]>128 && rgba[p]<128 && rgba[p+1]<128 && rgba[p+2]<128}))
    }
    private func positionedInk(_ name:String)throws->TextInk {try positionedInk(data(name+".emf"))}
    /// Resolve actual installed cmap IDs, then change only the wire's glyph-mode
    /// bit and UInt16 values. Positions, font, brush and framing remain original.
    private func positionedRawGlyphCopy(_ original:Data)throws->Data {
        var bytes=original
        func u32(_ p:Int)throws->Int {try XCTUnwrap(p>=0 && p+4<=bytes.count ? (0..<4).reduce(0){$0|Int(bytes[p+$1])<<($1*8)}:nil)}
        func put32(_ value:Int,_ p:Int){for k in 0..<4{bytes[p+k]=UInt8(truncatingIfNeeded:value>>(k*8))}}
        func replace(_ p:Int,_ count:Int)throws {
            XCTAssertGreaterThan(count,0);XCTAssertLessThan(count,1024)
            let chars=try (0..<count).map { index -> UniChar in let q=p+index*2;return try XCTUnwrap(q+2<=bytes.count ? UInt16(bytes[q])|UInt16(bytes[q+1])<<8:nil) }
            let font=CTFontCreateWithName("Helvetica" as CFString,18,nil)
            var glyphs=[CGGlyph](repeating:0,count:count)
            let mapped=chars.withUnsafeBufferPointer{characters in glyphs.withUnsafeMutableBufferPointer{output in CTFontGetGlyphsForCharacters(font,characters.baseAddress!,output.baseAddress!,count)}}
            XCTAssertTrue(mapped)
            for (index,glyph) in glyphs.enumerated(){XCTAssertGreaterThan(glyph,0);let q=p+index*2;bytes[q]=UInt8(truncatingIfNeeded:glyph);bytes[q+1]=UInt8(truncatingIfNeeded:glyph>>8)}
        }
        var cursor=88,found=false
        while cursor+8<=bytes.count {
            let type=try u32(cursor),size=try u32(cursor+4);guard size>=8,cursor+size<=bytes.count else{throw NSError(domain:"Positioned fixture framing",code:1)}
            if type==84 {let body=cursor+8,count=try u32(body+36),offset=try u32(body+40);try replace(cursor+offset,count);put32(try u32(body+44)|0x10,body+44);found=true}
            if type==70,cursor+16<=bytes.count,bytes.subdata(in:cursor+12..<cursor+16)==Data("EMF+".utf8) {
                var item=cursor+16
                while item+12<=cursor+size {
                    let kind=Int(bytes[item])|Int(bytes[item+1])<<8,length=try u32(item+4)
                    guard length>=12,item+length<=cursor+size else{throw NSError(domain:"Positioned plus fixture framing",code:1)}
                    if kind==0x4036 {let body=item+12,count=try u32(body+12);try replace(body+16,count);put32((try u32(body+4)) & ~1,body+4);found=true}
                    item+=length
                }
            }
            cursor+=size
        }
        XCTAssertTrue(found);XCTAssertNotEqual(bytes,original);return bytes
    }
    func testPositionedDriverUnicodeAndRuntimeRawGlyphsMatchClassicExplicitDx()throws {
        let original=try data("plus-driver-positioned.emf"),driver=try positionedInk(original),classic=try positionedInk("classic-positioned-dx")
        XCTAssertEqual(driver.points,classic.points);XCTAssertEqual(driver.columnRuns.count,3)
        if driver.columnRuns.count==3 {XCTAssertEqual(driver.columnRuns[1].minX-driver.columnRuns[0].minX,28);XCTAssertEqual(driver.columnRuns[2].minX-driver.columnRuns[1].minX,28)}
        XCTAssertEqual(try positionedInk(positionedRawGlyphCopy(original)).points,driver.points)
        let classicBytes=try data("classic-positioned-dx.emf")
        XCTAssertEqual(try positionedInk(positionedRawGlyphCopy(classicBytes)).points,classic.points)
        XCTAssertEqual(try data("plus-driver-positioned.emf"),original);XCTAssertEqual(try data("classic-positioned-dx.emf"),classicBytes)
    }
    func testPositionedDriverRealizedAdvanceAndVerticalUseActualFontMetrics()throws {
        let natural=try positionedInk("plus-driver-natural"),unused=try positionedInk("plus-driver-natural-unused")
        XCTAssertEqual(natural.points,unused.points,"Unused realized-position slots must not affect paint")
        let font=CTFontCreateWithName("Helvetica" as CFString,18,nil);var character=UniChar(72),glyph=CGGlyph(),advance=CGSize.zero
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font,&character,&glyph,1));CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&advance,1)
        XCTAssertEqual(natural.columnRuns.count,3)
        if natural.columnRuns.count==3 {for index in 1...2{XCTAssertEqual(natural.columnRuns[index].minX-natural.columnRuns[index-1].minX,advance.width,accuracy:1)}}
        XCTAssertEqual(try positionedInk("classic-positioned-natural").points,natural.points)
        let horizontal=try positionedInk("plus-driver-single"),vertical=try positionedInk("plus-driver-vertical-single")
        let clockwise=Set(horizontal.points.map{point -> Int in let x=point%96,y=point/96;return (28+x-32)*96+32-(y-28)})
        let matched=vertical.points.filter{point in (-1...1).contains{dy in (-1...1).contains{dx in clockwise.contains(point+dy*96+dx)}}}.count
        XCTAssertGreaterThan(vertical.points.count,20);XCTAssertGreaterThan(Double(matched)/Double(max(1,vertical.points.count)),0.9)
        let verticalNatural=try positionedInk("plus-driver-vertical-natural"),bounds=try XCTUnwrap(verticalNatural.bounds)
        XCTAssertGreaterThan(bounds.height,bounds.width*1.5,"Vertical realized advances must follow the rotated font direction")
    }
    func testPositionedVerticalDriverMatrixPrecedesVerticalOrientation()throws {
        let original=try positionedInk("plus-driver-single"),transformed=try positionedInk("plus-driver-vertical-matrix")
        // Independent noncommuting M then clockwise V, about the supplied
        // alphabetic origin. Reversing the order makes a wide short H instead.
        let expected=Set(original.points.map{point -> Int in
            let u=Double(point%96-32),v=Double(point/96-28)
            let x=Int((32-v).rounded()),y=Int((28+2*u+0.25*v).rounded());return y*96+x
        })
        let covered=transformed.points.filter{point in (-2...2).contains{dy in (-2...2).contains{dx in expected.contains(point+dy*96+dx)}}}.count
        let bounds=try XCTUnwrap(transformed.bounds)
        XCTAssertGreaterThan(bounds.height,bounds.width*1.5)
        XCTAssertGreaterThan(Double(covered)/Double(max(1,transformed.points.count)),0.85,"Driver matrix and vertical orientation were applied in reversed order")
    }
    func testPositionedGlyphMatricesAndWorldClipsPreserveSuppliedOrigins()throws {
        let baseline=try positionedInk("plus-driver-positioned")
        XCTAssertEqual(try positionedInk("plus-driver-translated").points,baseline.points,"Driver matrix translation is unused, not a second origin transform")
        XCTAssertEqual(try positionedInk("plus-driver-fractional").points,try positionedInk("plus-driver-limit-subpixel").points,"Subpixel raster hint must not quantize the outline's supplied origins")
        let translated=Set(baseline.points.map{$0+12*96+4})
        XCTAssertEqual(try positionedInk("plus-driver-world").points,translated)
        XCTAssertEqual(try positionedInk("classic-positioned-world").points,translated)
        let clipped=try positionedInk("plus-driver-clipped"),expected=Set(baseline.points.filter{$0%96<48})
        XCTAssertEqual(clipped.points,expected);XCTAssertEqual(try positionedInk("classic-positioned-clipped").points,expected)
        let matrix=try positionedInk("plus-driver-linear-matrix")
        XCTAssertNotEqual(matrix.points,baseline.points);XCTAssertEqual(matrix.columnRuns.count,3)
        if matrix.columnRuns.count==3 {XCTAssertEqual(matrix.columnRuns[1].minX-matrix.columnRuns[0].minX,28,accuracy:1);XCTAssertEqual(matrix.columnRuns[2].minX-matrix.columnRuns[1].minX,28,accuracy:1)}
        for name in ["plus-driver-state","classic-positioned-state"] {let pixel=try rgb(image(name+".emf"),84,52);XCTAssertLessThan(pixel[0],0.05);XCTAssertGreaterThan(pixel[2],0.95,"Restored state retained text clip")}
    }
    func testClassicPositionedPdyAlignmentUpdateCPAndOpaqueRects()throws {
        let baseline=try positionedInk("classic-positioned-dx")
        XCTAssertEqual(try positionedInk("classic-positioned-path").points,baseline.points,"BeginPath must accumulate glyph outlines until FillPath")
        for name in ["center","right"] {XCTAssertEqual(try positionedInk("classic-positioned-"+name).points,baseline.points,name)}
        XCTAssertEqual(try positionedInk("classic-positioned-pdy").points,try positionedInk("plus-driver-pdy-control").points,"PDY positive deltas must move up in source font coordinates")
        XCTAssertEqual(try positionedInk("classic-positioned-updatecp").points,try positionedInk("classic-positioned-updatecp-control").points)
        for direction in ["right","center"] {XCTAssertEqual(try positionedInk("classic-positioned-updatecp-"+direction).points,try positionedInk("classic-positioned-updatecp-"+direction+"-control").points,direction)}
        let opaque=try image("classic-positioned-opaque.emf"),empty=try image("classic-positioned-empty-opaque.emf")
        for image in [opaque,empty] {let interior=try rgb(image,6,6),outside=try rgb(image,2,2);XCTAssertLessThan(interior[0],0.05);XCTAssertGreaterThan(interior[1],0.95);XCTAssertGreaterThan(outside[0],0.95);XCTAssertGreaterThan(outside[1],0.95)}
        XCTAssertEqual(try positionedInk("classic-positioned-empty-opaque").points.count,0)
        XCTAssertGreaterThan(try positionedInk("classic-positioned-opaque").points.count,50)
    }
    func testClassicPositionedCompatibleInkAndAdvancesHaveIndependentMappings()throws {
        for name in ["dx","natural","reflect-dx","reflect-natural","yreflect"] {
            XCTAssertEqual(try positionedInk("classic-positioned-compatible-"+name).points,try positionedInk("plus-driver-compatible-"+name).points,name)
        }
        let explicit=try positionedInk("classic-positioned-compatible-dx"),natural=try positionedInk("classic-positioned-compatible-natural")
        XCTAssertEqual(explicit.columnRuns.count,2);XCTAssertEqual(natural.columnRuns.count,2)
        if explicit.columnRuns.count==2,natural.columnRuns.count==2 {
            XCTAssertEqual(explicit.columnRuns[1].minX-explicit.columnRuns[0].minX,40)
            let font=CTFontCreateWithName("Helvetica" as CFString,18,nil);var character=UniChar(72),glyph=CGGlyph(),advance=CGSize.zero
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font,&character,&glyph,1));CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&advance,1)
            XCTAssertEqual(natural.columnRuns[1].minX-natural.columnRuns[0].minX,advance.width,accuracy:1,"Compatible natural advances were stretched by world.m11")
            XCTAssertEqual(explicit.columnRuns[0].width,natural.columnRuns[0].width,accuracy:1,"Compatible glyph ink was horizontally stretched")
        }
        XCTAssertEqual(try positionedInk("classic-positioned-compatible-scale-metadata").points,explicit.points,"exScale/eyScale conversion metadata must not repeat the captured DC mapping")
    }
    func testClassicPositionedCellHeightAndAverageWidthUseActualFontMetrics()throws {
        let normal=try XCTUnwrap(positionedInk("classic-positioned-em-height").bounds),cell=try XCTUnwrap(positionedInk("classic-positioned-cell-height").bounds)
        let font=CTFontCreateWithName("Arial" as CFString,18,nil),scale=18/(CTFontGetAscent(font)+CTFontGetDescent(font))
        XCTAssertEqual(cell.height,normal.height*scale,accuracy:2);XCTAssertLessThan(cell.height,normal.height)
        let small=try XCTUnwrap(positionedInk("classic-positioned-width10").bounds),large=try XCTUnwrap(positionedInk("classic-positioned-width20").bounds)
        XCTAssertEqual(large.width,small.width*2,accuracy:2);XCTAssertEqual(large.height,small.height,accuracy:1)
        let a=try positionedInk("classic-positioned-width10-natural"),b=try positionedInk("classic-positioned-width20-natural")
        XCTAssertEqual(a.columnRuns.count,3);XCTAssertEqual(b.columnRuns.count,3)
        if a.columnRuns.count==3,b.columnRuns.count==3 {XCTAssertEqual(b.columnRuns[1].minX-b.columnRuns[0].minX,2*(a.columnRuns[1].minX-a.columnRuns[0].minX),accuracy:2)}
        XCTAssertGreaterThan(try positionedInk("plus-driver-cmap-fallback").points.count,50,"Unicode cmap path may use native font substitution")
    }
    func testPositionedTextBrushesAndMalformedRecordsKeepOriginalBytes()throws {
        let normal=try image("plus-driver-positioned.emf"),gradient=try image("plus-driver-gradient.emf"),hatch=try image("plus-driver-hatch.emf")
        var red=0,blue=0,pattern=0
        for y in 10..<30 {for x in 6..<80 {let a=try rgb(gradient,x,y),b=try rgb(hatch,x,y),n=try rgb(normal,x,y);if a[0]>0.2 && a[2]<0.3 && a[1]<0.5{red+=1};if a[2]>0.2 && a[0]<0.3 && a[1]<0.5{blue+=1};if n[0]<0.5 && (b[0]>0.5 || b[2]>0.5){pattern+=1}}}
        XCTAssertGreaterThan(red,5);XCTAssertGreaterThan(blue,5);XCTAssertGreaterThan(pattern,20)
        let names=try FileManager.default.contentsOfDirectory(at:fixtures,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("unsupported-positioned-text-")}
        XCTAssertGreaterThanOrEqual(names.count,15)
        let budgetDiagnostics=["unsupported-positioned-text-driver-per-call-budget.emf":"positioned text unit limit",
                               "unsupported-positioned-text-driver-aggregate-budget.emf":"aggregate positioned text unit limit"]
        for url in names {
            let bytes=try Data(contentsOf:url)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes),url.lastPathComponent) { error in
                if let expected=budgetDiagnostics[url.lastPathComponent] {
                    guard let failure=error as? MetafileImageFailure,case .failed(let diagnostic)=failure else {
                        return XCTFail("\(url.lastPathComponent) must reach explicit positioned budget, not deadline/runtime/output failure: \(error)")
                    }
                    XCTAssertTrue(diagnostic.contains(expected),"\(url.lastPathComponent): expected '\(expected)', got '\(diagnostic)'")
                }
            }
            XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }

}

extension MetafileImageTests {
    private func booleanPixels(_ name:String)throws->PenPixels {
        try booleanPixels(image(name),name:name)
    }
    private func booleanPixels(_ value:ComparisonImage,name:String)throws->PenPixels {
        let width=64,height=64
        let cropped=try interior(value,width:width,height:height,emf:name.hasSuffix(".emf"),name:name)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes {storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(cropped,in:CGRect(x:0,y:0,width:width,height:height))
        }
        return .init(width:width,height:height,bytes:bytes)
    }
    private func booleanGray(_ pixels:PenPixels,_ x:Int,_ y:Int,_ expected:Int,_ message:String,file:StaticString = #filePath,line:UInt = #line) {
        let actual=pixels.pixel(x,y)
        for channel in 0..<3 {XCTAssertEqual(Double(actual[channel]),Double(expected),accuracy:1,"\(message) sample(\(x),\(y))=\(actual)",file:file,line:line)}
        XCTAssertEqual(actual[3],255,"\(message): Boolean DC/covered interior must remain opaque",file:file,line:line)
    }
    func testClassicBooleanROP2AllSixteenBrushAndPenTruthTables()throws {
        // P=11001100,D=10101010 enumerates all four P/D input combinations
        // twice. Hence each operation's specified truth nibble repeats twice;
        // no implementation Boolean-expression table is copied into this oracle.
        for name in ["classic-rop2-matrix.emf","wmf-rop2-matrix.wmf"] {
            let value=try booleanPixels(name)
            for operation in 1...16 {
                let expected=(operation-1)*17,x=(operation-1)*4+2
                booleanGray(value,x,10,expected,"\(name) brush ROP2=\(operation)")
                booleanGray(value,x,32,expected,"\(name) pen ROP2=\(operation)")
            }
            booleanGray(value,2,50,170,name+" untouched destination")
        }
    }
    func testClassicBooleanROP3All256TruthTablesForEachEMFBitmapRecord()throws {
        for kind in ["bitblt","stretchblt","stretchdibits"] {
            let name="classic-rop3-matrix-"+kind+".emf",value=try booleanPixels(name)
            // The source data itself encodes all eight independent truth rows:
            // P=11110000,S=11001100,D=10101010. The byte is its own oracle.
            for truth in 0..<256 {booleanGray(value,(truth%16)*4+2,(truth/16)*4+2,truth,"\(kind) ROP3=\(truth)")}
        }
    }
    func testClassicBooleanROP3All256TruthTablesForEachWMFDIBRecord()throws {
        for kind in ["dibbitblt","dibstretchblt","stretchdib"] {
            let name="wmf-rop3-matrix-"+kind+".wmf",value=try booleanPixels(name)
            for truth in 0..<256 {booleanGray(value,(truth%16)*4+2,(truth/16)*4+2,truth,"\(kind) ROP3=\(truth)")}
        }
    }
    func testClassicBooleanSourceIndependentOmittedBitmapsAndIrrelevantNullPatterns()throws {
        let independent=[0x00,0x05,0x0a,0x0f,0x50,0x55,0x5a,0x5f,0xa0,0xa5,0xaa,0xaf,0xf0,0xf5,0xfa,0xff]
        for name in ["wmf-rop3-patblt.wmf"]+["bitblt","stretchblt","stretchdibits"].map({"classic-rop3-no-source-"+$0+".emf"}) {
            let value=try booleanPixels(name)
            for(index,expected)in independent.enumerated(){booleanGray(value,(index%4)*16+8,(index/4)*16+8,expected,name)}
        }
        for kind in ["bitblt","stretchblt"] {
            let value=try booleanPixels("classic-rop3-no-source-transform-"+kind+".emf")
            booleanGray(value,24,16,240,kind+" PATCOPY ignores unused zero XformSrc")
            booleanGray(value,24,44,85,kind+" DSTINVERT ignores unused skew XformSrc")
            booleanGray(value,60,60,170,kind+" unused source metadata preserves outside D")
        }
        for kind in ["bitblt","stretchblt","stretchdibits"] {
            let value=try booleanPixels("classic-rop3-null-pattern-"+kind+".emf")
            booleanGray(value,24,24,204,kind+" source copy must ignore absent P")
            booleanGray(value,48,48,170,kind+" source copy must retain outside D")
        }
    }
    func testClassicBooleanWMFWithoutBitmapReservedWordFormsHaveAll16PatternDestinationFunctions()throws {
        let independent=[0x00,0x05,0x0a,0x0f,0x50,0x55,0x5a,0x5f,0xa0,0xa5,0xaa,0xaf,0xf0,0xf5,0xfa,0xff]
        for kind in ["bitblt","stretchblt","dibbitblt","dibstretchblt"] {
            let value=try booleanPixels("wmf-rop3-without-bitmap-"+kind+".wmf")
            for(index,expected)in independent.enumerated(){booleanGray(value,(index%4)*16+8,(index/4)*16+8,expected,"Without Bitmap \(kind), ignored nonzero ReservedWORD")}
        }
    }
    func testClassicBooleanOpaqueWhiteBackdropAndProgressiveClippedDestination()throws {
        for name in ["classic-rop3-white-backdrop.emf","wmf-rop3-white-backdrop.wmf"] {
            let value=try booleanPixels(name)
            booleanGray(value,24,24,0,name+" inverts white DC to black")
            booleanGray(value,60,60,255,name+" outside retained opaque white")
        }
        for(name,once)in[("classic-rop3-successive.emf",240),("wmf-rop3-successive.wmf",0)] {
            let value=try booleanPixels(name)
            booleanGray(value,12,12,once,name+" one operation")
            booleanGray(value,20,20,once,name+" clipped second operation must not paint here")
            booleanGray(value,30,30,255,name+" second XOR/invert restores previous destination")
            booleanGray(value,52,12,255,name+" RestoreDC removes captured middle clip")
            booleanGray(value,60,60,255,name+" untouched white DC")
        }
    }
    func testClassicBooleanROP2ClipTransformAndSavedStateRemainDeviceCorrect()throws {
        for name in ["classic-rop2-state.emf","wmf-rop2-state.wmf"] {
            let value=try booleanPixels(name)
            booleanGray(value,16,16,102,name+" XOR within captured device clip")
            booleanGray(value,4,4,170,name+" outside captured clip")
            booleanGray(value,40,16,204,name+" restored CopyPen and mapping")
            booleanGray(value,52,40,170,name+" final NOP preserves destination")
        }
    }
    func testClassicBooleanPatternBrushOriginRestoreAndWorldScaleUseDevicePhase()throws {
        let value=try booleanPixels("classic-rop3-pattern-state.emf")
        for y in 2..<14 {for x in 2..<22 {
            let expected=(x+y)%2==0 ? 0:255
            booleanGray(value,x,y,expected,"pattern original phase")
            booleanGray(value,x,y+24,expected,"RestoreDC restores pattern phase")
            booleanGray(value,x+32,y+24,expected,"world scale must not stretch device pattern")
        }}
        // Origin(1,0) shifts the checker, and XOR with the white destination
        // reverses it again. Combined result equals the original phase here.
        for y in 2..<14 {for x in 34..<54 {booleanGray(value,x,y,(x+y)%2==0 ? 0:255,"shifted P xor white D under saved clip")}}
        booleanGray(value,28,8,255,"pattern clipping left")
        booleanGray(value,60,8,255,"pattern clipping right")
    }
    func testClassicBooleanCoverageIsIndependentOfAntialiasedOperandColor()throws {
        let actual=try booleanPixels("classic-rop2-coverage.emf")
        let reference=try XCTUnwrap(ComparisonImage(bytes:Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"><rect width=\"64\" height=\"64\" fill=\"white\"/><rect x=\"8.5\" y=\"8.5\" width=\"24\" height=\"24\" fill=\"black\"/></svg>".utf8)))
        let expected=try booleanPixels(reference,name:"independent native SVG coverage")
        for(x,y)in[(8,16),(32,16),(16,8),(16,32),(8,8),(32,32),(16,16),(4,4)] {
            let a=actual.pixel(x,y),b=expected.pixel(x,y)
            for channel in 0..<4{XCTAssertEqual(Double(a[channel]),Double(b[channel]),accuracy:1,"Boolean coverage differs from independent fractional rectangle at \(x),\(y): \(a) vs \(b)")}
        }
    }
    func testClassicBooleanSourceCropMirrorAndPositiveScaleUseSourceWorldCoordinates()throws {
        let value=try image("classic-rop3-source-transform.emf")
        try primary(value,1,20,16);try primary(value,2,44,16)
        try primary(value,2,20,44);try primary(value,1,44,44)
        let scaled=try image("classic-rop3-source-scale.emf")
        try primary(scaled,1,20,16);try primary(scaled,2,44,16)
        for name in ["classic-rop3-source-bottom-up.emf","wmf-rop3-source-bottom-up.wmf"] {
            let bottom=try image(name)
            try primary(bottom,2,32,20)
            let yellow=try rgb(bottom,32,44)
            XCTAssertGreaterThan(yellow[0],0.8,name);XCTAssertGreaterThan(yellow[1],0.8,name);XCTAssertLessThan(yellow[2],0.25,name)
        }
    }
    func testPreviouslyUnsupportedROP2XorPaintsAgainstOpaqueWhiteDC()throws {
        let value=try image("unsupported-rop.emf")
        let cyan=try rgb(value,12,12),yellow=try rgb(value,58,12)
        for channel in 0..<3 {
            XCTAssertEqual(cyan[channel],[CGFloat(0),1,1][channel],accuracy:1.0/255)
            XCTAssertEqual(yellow[channel],[CGFloat(1),1,0][channel],accuracy:1.0/255)
        }
    }
    func testMalformedClassicBooleanRecordsAndUnrepresentableOperandsRefuseExplicitly()throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-raster-")}.sorted()
        XCTAssertEqual(names.count,36,"Enroll every independently framed Boolean refusal")
        for name in names {
            let original=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),name) {error in
                if name=="unsupported-raster-device-pixel-budget.emf" {
                    guard let failure=error as? MetafileImageFailure,case .failed(let diagnostic)=failure else{return XCTFail("Boolean pixel budget must fail explicitly, not by timeout/runtime/output: \(error)")}
                    let lower=diagnostic.lowercased()
                    XCTAssertTrue(lower.contains("raster") && (lower.contains("budget") || lower.contains("limit")),"Missing explicit native raster budget diagnostic: \(diagnostic)")
                }
            }
            XCTAssertEqual(try data(name),original)
        }
        // Shared image consumers must propagate refusal rather than expose an
        // approximate successful image. Representative failures cover each input.
        for name in ["unsupported-raster-required-source-bitblt.emf","unsupported-raster-required-pattern-stretchdibits.emf","unsupported-raster-patblt-source.wmf","unsupported-raster-device-bitblt.wmf","unsupported-raster-source-transform.emf"] {XCTAssertNil(ComparisonImage(bytes:try data(name)),name)}
    }
}

extension MetafileImageTests {
    private func transferRGB(_ pixels:PenPixels,_ x:Int,_ y:Int,_ expected:[Int],_ message:String,file:StaticString = #filePath,line:UInt = #line) {
        let actual=pixels.pixel(x,y)
        for channel in 0..<3 {XCTAssertEqual(Double(actual[channel]),Double(expected[channel]),accuracy:1,"\(message) pixel(\(x),\(y))=\(actual)",file:file,line:line)}
        XCTAssertEqual(actual[3],255,message,file:file,line:line)
    }
    func testClassicMaskBltAllForegroundAndBackgroundTruthBytes()throws {
        // Literal P=F0,S=CC,D=AA enumerate the three-input truth table in
        // their eight bit positions. A masked foreground n must return n;
        // the opposite selector independently returns its complemented table.
        let name="classic-maskblt-matrix.emf",before=try data(name)
        let started=ProcessInfo.processInfo.systemUptime
        let pixels:PenPixels
        do {
            // Decode once with the ordinary deadline. Keep the real failure
            // visible instead of ComparisonImage's intentionally failable API.
            let helper=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_METAFILE_HELPER"].map { URL(fileURLWithPath:$0) }
            let svg=try XCTUnwrap(MetafileImageDecoder.convert(before,executable:helper),"Expected metafile output for "+name)
            let rendered=try XCTUnwrap(ComparisonImage(bytes:svg),"Could not rasterize decoded "+name)
            pixels=try booleanPixels(rendered,name:name)
        } catch {
            XCTFail("\(name) decoder failed after \(ProcessInfo.processInfo.systemUptime-started)s: \(error)")
            throw error
        }
        for n in 0..<256 {
            booleanGray(pixels,(n%16)*4+1,(n/16)*4+2,n,"ROP4 foreground \(n)")
            booleanGray(pixels,(n%16)*4+3,(n/16)*4+2,255-n,"ROP4 background \(255-n)")
        }
        XCTAssertEqual(try data(name),before)
    }
    func testClassicMaskSelectorsOffsetsAndUnusedOperands()throws {
        for name in ["classic-maskblt-copy.emf","classic-maskblt-swapped-palette.emf","classic-maskblt-unused-mask-palette.emf"] {
            let pixels=try booleanPixels(name)
            transferRGB(pixels,16,16,[255,0,0],name+" mask bit 1")
            transferRGB(pixels,32,16,[0,0,255],name+" mask bit 0")
            transferRGB(pixels,4,4,[0,0,255],name+" outside")
        }
        // renderToSvg initializes the GDI canvas to opaque white before any
        // record. Absence of a painted base does not make this route transparent.
        let defaultDC=try booleanPixels("classic-maskblt-default-destination.emf")
        transferRGB(defaultDC,16,16,[255,0,0],"Mask foreground paints the initial white DC")
        XCTAssertEqual(defaultDC.pixel(32,16),[255,255,255,255],"DSTCOPY preserves exact initial white DC RGBA")
        XCTAssertEqual(defaultDC.pixel(4,4),[255,255,255,255],"Outside coverage preserves initial white DC RGBA")
        let nilMask=try booleanPixels("classic-maskblt-no-mask.emf")
        booleanGray(nilMask,16,16,85,"No mask ignores source-dependent background and unused NaN source transform")
        booleanGray(nilMask,4,4,170,"No mask outside destination")
        let noSource=try booleanPixels("classic-maskblt-no-source.emf")
        booleanGray(noSource,16,16,240,"Foreground uses selected pattern without a source")
        booleanGray(noSource,32,16,85,"Background inverts destination without a source")
        let cropEdge=try booleanPixels("classic-maskblt-crop-edge.emf")
        transferRGB(cropEdge,12,12,[255,0,0],"Selected crop interior is red")
        let boundary=cropEdge.pixel(16,12)
        XCTAssertEqual(boundary[1],0,"Antialiased destination edge must not sample green one past the selected source crop")
        XCTAssertGreaterThan(boundary[0],0,"Fractional destination edge must contain selected red source coverage")
        XCTAssertGreaterThan(boundary[2],0,"Fractional destination edge retains uncovered blue destination")
        let offset=try booleanPixels("classic-maskblt-offset.emf")
        transferRGB(offset,12,16,[255,0,0],"Mask offset retains selected bits")
        transferRGB(offset,20,16,[0,0,255],"Mask offset moves the bit transition")
    }
    func testClassicPlgBltRepeatingMaskParallelogramClipAndMirroring()throws {
        let shear=try booleanPixels("classic-plgblt-mask-shear.emf")
        transferRGB(shear,14,24,[255,0,0],"Skewed repeating mask foreground")
        transferRGB(shear,18,25,[0,0,255],"Skewed repeating mask destination preservation")
        transferRGB(shear,34,28,[0,0,255],"Destination clip excludes source ink")
        transferRGB(shear,52,12,[0,255,0],"RestoreDC releases the clip for the next masked transfer")
        let mirrored=try booleanPixels("classic-plgblt-mask-mirror.emf")
        transferRGB(mirrored,40,16,[255,0,0],"Mirrored parallelogram maps source-left to destination-right")
        transferRGB(mirrored,24,16,[0,0,255],"Mirrored mask preserves the opposite side")
        let noMask=try booleanPixels("classic-plgblt-no-mask.emf")
        transferRGB(noMask,16,16,[255,0,0],"Optional mask absent copies source")
        transferRGB(noMask,4,4,[0,0,255],"Optional mask absent still bounds destination")
    }
    func testClassicTransparentBltRGBIndexedAndBottomUpCroppedSources()throws {
        for name in ["classic-transparentblt-key.emf","classic-transparentblt-indexed.emf","classic-transparentblt-crop-bottom-up.emf"] {
            let before=try data(name),pixels=try booleanPixels(name)
            transferRGB(pixels,16,16,[0,0,255],name+" exact red color key preserves blue destination")
            transferRGB(pixels,32,16,[0,255,0],name+" non-key green is copied")
            transferRGB(pixels,4,4,[0,0,255],name+" source crop/world translation remain bounded")
            XCTAssertEqual(try data(name),before)
        }
        let bottom=try booleanPixels("classic-transparentblt-crop-bottom-up.emf")
        transferRGB(bottom,32,32,[255,255,0],"Bottom-up crop retains the distinct lower source row")
    }
    func testClassicAlphaBlendPixelConstantCombinedZeroAndIgnoredFlags()throws {
        let cases:[(String,[Int])]=[("classic-alphablend-pixel.emf",[128,0,127]),("classic-alphablend-constant.emf",[128,0,127]),("classic-alphablend-both.emf",[64,0,191]),("classic-alphablend-zero.emf",[0,0,255]),("classic-alphablend-ignored-flags.emf",[255,0,0])]
        for(name,expected)in cases {
            let before=try data(name),pixels=try booleanPixels(name)
            transferRGB(pixels,16,16,expected,name+" specified alpha equation")
            transferRGB(pixels,4,4,[0,0,255],name+" outside remains unchanged")
            XCTAssertEqual(try data(name),before)
        }
    }
    func testClassicTransferMalformedDIBMasksBlendAndGeometryRefuseWholeImage()throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-transfer-")}.sorted()
        XCTAssertEqual(names.count,18,"Enroll each independently framed transfer refusal")
        for name in names {
            let before=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(before),name)
            XCTAssertNil(ComparisonImage(bytes:before),name+" must not expose earlier/later painted partial success")
            XCTAssertEqual(try data(name),before)
        }
    }
}

extension MetafileImageTests {
    func testClassicExtendedPenCustomOddCosmeticAndBuiltInDashPixels() throws {
        let custom=try booleanPixels("classic-extpen-custom.emf")
        for x in [10,22,34,46] {transferRGB(custom,x,16,[255,0,0],"Geometric logical custom dash")}
        for x in [18,30,42,54] {booleanGray(custom,x,16,255,"Custom dash gap")}
        let mixedZero=try booleanPixels("classic-extpen-mixed-zero.emf")
        for x in 10..<54 {transferRGB(mixedZero,x,16,[255,0,0],"A mixed-zero user dash retains its nonzero on lengths and zero gaps")}
        let zeroRound=try booleanPixels("classic-extpen-zero-on-round.emf"),zeroFlat=try booleanPixels("classic-extpen-zero-on-flat.emf")
        // Nonzero gap advances a zero-length on segment. Round caps paint real
        // dots at those positions; flat caps have no area and paint nothing.
        for x in [8,12,16,20,24,28,32,36,40,44,48,52] {transferRGB(zeroRound,x,32,[255,0,0],"Round cap retains zero-length user dash dot")}
        XCTAssertGreaterThan(zeroRound.pixel(10,30)[1],100,"Zero-length round dots must retain curved inter-dot gaps rather than a solid wide line")
        for y in 28..<36 {for x in 10..<54 {booleanGray(zeroFlat,x,y,255,"Flat zero-length on segments have no painted area")}}
        let odd=try booleanPixels("classic-extpen-odd.emf")
        for x in [10,20,31,38,48] {transferRGB(odd,x,16,[255,0,0],"Odd dash sequence alternates across wrap")}
        for x in [18,25,35,44,53] {booleanGray(odd,x,16,255,"Odd dash inverted gap")}
        let cosmetic=try booleanPixels("classic-extpen-cosmetic-scale.emf")
        let deviceReference=try XCTUnwrap(ComparisonImage(bytes:Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"><rect width=\"64\" height=\"64\" fill=\"white\"/><path d=\"M8.5 32.5H56.5\" stroke=\"red\" stroke-width=\"1\" stroke-dasharray=\"8 4\"/></svg>".utf8)))
        let expected=try booleanPixels(deviceReference,name:"independent device-pen reference")
        for y in 30...34 {for x in 8..<56 {for c in 0..<4 {XCTAssertEqual(Double(cosmetic.pixel(x,y)[c]),Double(expected.pixel(x,y)[c]),accuracy:1,"Cosmetic width/dashes must remain device-sized under world scale at \(x),\(y)")}}}
        for x in [18,30,42,54] {booleanGray(cosmetic,x,32,255,"Cosmetic device gap")}
        booleanGray(cosmetic,12,35,255,"Cosmetic width does not scale")
        let hairline=try booleanPixels("classic-extpen-width-zero-scale.emf")
        for x in 10..<54 {transferRGB(hairline,x,32,[255,0,0],"Zero-width geometric pen is a device hairline under world scale");booleanGray(hairline,x,31,255,"Device hairline upper neighbor");booleanGray(hairline,x,33,255,"Device hairline lower neighbor")}
        XCTAssertEqual(try booleanPixels("classic-extpen-cosmetic-known-cap-join.emf").bytes,try booleanPixels("classic-extpen-cosmetic.emf").bytes,"Known cap/join encodings are ignored for cosmetic pens")
        let alternate=try booleanPixels("classic-extpen-alternate.emf")
        let row=(10..<54).map{alternate.pixel($0,16)[1]<200}
        XCTAssertGreaterThan(zip(row,row.dropFirst()).filter{$0.0 != $0.1}.count,30,"ALTERNATE must paint alternating device pixels")
        // Literal source coordinates at axis-aligned and 45-degree device
        // paths give an independent pixel oracle without duplicating a general
        // line rasterizer or assuming Windows-exact arbitrary-angle stepping.
        let vertical=try booleanPixels("classic-extpen-alternate-vertical.emf"),diagonal=try booleanPixels("classic-extpen-alternate-diagonal.emf")
        for n in 10..<54 {
            if n%2==0 {transferRGB(vertical,16,n,[255,0,0],"Vertical alternating device pixel");transferRGB(diagonal,n,n,[255,0,0],"Diagonal alternating device pixel")}
            else {booleanGray(vertical,16,n,255,"Vertical alternate gap");booleanGray(diagonal,n,n,255,"Diagonal alternate gap")}
            booleanGray(vertical,15,n,255,"Vertical device pen remains one pixel wide")
            booleanGray(diagonal,n,n+1,255,"Diagonal device pen does not antialias into adjacent cells")
        }
        let joined=try booleanPixels("classic-extpen-alternate-polyline.emf")
        transferRGB(joined,12,16,[255,0,0],"Joined polyline initial leg phase")
        booleanGray(joined,13,16,255,"Joined corner consumes one shared device position")
        for y in 17..<39 {if y%2==1 {transferRGB(joined,13,y,[255,0,0],"ALTERNATE phase continues through polyline corner")}else{booleanGray(joined,13,y,255,"Joined polyline alternate gap")}}
        let clipped=try booleanPixels("classic-extpen-alternate-transform-clip.emf")
        for x in 10..<54 {
            if (16..<40).contains(x) && x%2==0 {transferRGB(clipped,x,32,[255,0,0],"Transformed alternate remains device-spaced inside DC clip")}else{booleanGray(clipped,x,32,255,"Clip does not restart phase or paint outside coverage")}
            booleanGray(clipped,x,33,255,"Transformed alternate device width stays one pixel")
        }
        for name in ["dash","dot","dashdot","dashdotdot"] {
            let pixels=try booleanPixels("classic-extpen-"+name+".emf")
            let ink=(8..<56).filter{pixels.pixel($0,16)[1]<128}.count
            XCTAssertGreaterThan(ink,4,name);XCTAssertLessThan(ink,46,name+" must retain real gaps")
        }
    }
    func testClassicExtendedPenCapsJoinsAndInsideFramePaintActualBounds() throws {
        let flat=try booleanPixels("classic-extpen-cap-flat.emf"),round=try booleanPixels("classic-extpen-cap-round.emf"),square=try booleanPixels("classic-extpen-cap-square.emf")
        booleanGray(flat,13,32,255,"Flat cap has no endpoint extension")
        transferRGB(round,13,32,[255,0,0],"Round cap extends endpoint")
        transferRGB(square,13,32,[255,0,0],"Square cap extends endpoint")
        booleanGray(round,12,28,255,"Round cap excludes square corner")
        transferRGB(square,12,28,[255,0,0],"Square cap includes corner")
        let dashSquare=try booleanPixels("classic-extpen-dashcap-square.emf"),dashFlat=try booleanPixels("classic-extpen-dashcap-flat.emf"),dashRound=try booleanPixels("classic-extpen-dashcap-round.emf")
        // Width8 gives a radius4 cap at (24,32). The entire pixel (27,28)
        // lies outside that disk (nearest corner distance sqrt(18)>4), while
        // its whole area remains inside the square cap. These are stable
        // geometric interiors/exteriors rather than antialias edge guesses.
        transferRGB(dashSquare,27,28,[255,0,0],"Square cap applies to each custom dash corner")
        booleanGray(dashFlat,25,32,255,"Flat custom dash does not extend into gap")
        booleanGray(dashRound,27,28,255,"Round custom dash excludes complete square corner pixel")
        booleanGray(dashSquare,32,32,255,"Square custom dash retains remaining gap")
        // Pixel(27,29) crosses the circle: one corner has distance sqrt(13)<4,
        // another distance5>4. Require actual partial coverage, with exact
        // opaque red/white compositing channels. Different native curve
        // flatteners need not assign the same 8-bit area to this edge cell.
        let edge=dashRound.pixel(27,29)
        XCTAssertEqual(edge[0],255);XCTAssertEqual(edge[3],255)
        XCTAssertEqual(edge[1],edge[2]);XCTAssertGreaterThan(edge[1],0);XCTAssertLessThan(edge[1],255)
        let miter=try booleanPixels("classic-extpen-join-miter.emf"),bevel=try booleanPixels("classic-extpen-join-bevel.emf"),rounded=try booleanPixels("classic-extpen-join-round.emf")
        func tipInk(_ p:PenPixels)->Int {(7..<16).reduce(0){sum,y in sum+(27..<37).filter{p.pixel($0,y)[1]<128}.count}}
        let floatHigh=try booleanPixels("classic-extpen-miter-float-high.emf"),uintHigh=try booleanPixels("classic-extpen-miter-uint-high.emf"),floatLow=try booleanPixels("classic-extpen-miter-float-low.emf")
        XCTAssertEqual(floatHigh.bytes,uintHigh.bytes,"Windows FLOAT and normative UINT miter records must paint equivalent high-limit joins")
        XCTAssertEqual(try booleanPixels("classic-extpen-miter-restored.emf").bytes,uintHigh.bytes,"RestoreDC must restore actual miter limit before the extended pen outline")
        XCTAssertGreaterThan(tipInk(floatHigh),tipInk(floatLow),"Actual SETMITERLIMIT low FLOAT cuts the miter tip to a bevel")
        XCTAssertGreaterThan(tipInk(miter),tipInk(rounded),"Miter join retains extended tip")
        XCTAssertGreaterThan(tipInk(rounded),tipInk(bevel),"Round and bevel joins paint distinct actual outlines")
        for kind in ["rectangle","ellipse","roundrect"] {
            let pixels=try booleanPixels("classic-extpen-inside-"+kind+".emf")
            transferRGB(pixels,14,32,[255,0,0],"InsideFrame stroke remains inside "+kind)
            booleanGray(pixels,9,32,255,"InsideFrame must not escape original bounds "+kind)
            booleanGray(pixels,32,32,255,"InsideFrame hollow center "+kind)
        }
        let open=try booleanPixels("classic-extpen-inside-open.emf")
        transferRGB(open,32,29,[255,0,0],"InsideFrame open line remains centered")
        transferRGB(open,32,34,[255,0,0],"InsideFrame open line lower half")
    }
    func testClassicExtendedPenHatchDIBBrushesStateClipAndROP2() throws {
        var patterns=Set<Data>()
        for hatch in 0..<6 {
            let p=try booleanPixels("classic-extpen-hatch-\(hatch).emf")
            var red=0,white=0,signature=[UInt8]()
            for y in 27..<37 {for x in 12..<52 {let pixel=p.pixel(x,y);signature.append(pixel[1]);if pixel[0]>240 && pixel[1]<15 {red+=1};if pixel[1]>240 {white+=1}}}
            XCTAssertGreaterThan(red,8,"Hatch \(hatch) actual stroke ink");XCTAssertGreaterThan(white,8,"Hatch \(hatch) actual gaps")
            patterns.insert(Data(signature))
        }
        XCTAssertEqual(patterns.count,6,"Six classic hatch stroke styles must remain distinct")
        let nullBrush=try booleanPixels("classic-extpen-null-brush.emf")
        for y in 26..<38 {for x in 8..<56 {booleanGray(nullBrush,x,y,255,"Valid geometric solid pen with NULL brush paints no ink")}}
        let dib=try booleanPixels("classic-extpen-dib.emf")
        var red=0,blue=0
        for y in 28..<36 {for x in 12..<52 {let p=dib.pixel(x,y);if p[0]>240 && p[2]<15 {red+=1};if p[2]>240 && p[0]<15 {blue+=1}}}
        XCTAssertGreaterThan(red,80);XCTAssertGreaterThan(blue,80,"DIB pen brush must retain both source colors and ignored offset gap")
        let state=try booleanPixels("classic-extpen-state.emf")
        transferRGB(state,20,16,[255,0,0],"Transformed pen inside saved clip")
        booleanGray(state,40,16,255,"Saved clip bounds remain active")
        transferRGB(state,40,48,[255,0,0],"RestoreDC restores selected extended pen and clip/world state")
        let rop=try booleanPixels("classic-extpen-rop2.emf")
        booleanGray(rop,32,32,0,"Extended pen participates in R2_XORPEN white XOR white")
        booleanGray(rop,32,40,255,"ROP2 does not paint outside stroke coverage")
    }
    func testClassicExtendedPenMalformedArraysDIBOffsetsAndStylesRefuseWholeImage() throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-extpen-")}.sorted()
        XCTAssertEqual(names.count,21,"Each independently framed extended pen refusal remains enrolled")
        for name in names {
            let before=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(before),name)
            XCTAssertNil(ComparisonImage(bytes:before),name+" must refuse the complete image including earlier valid paint")
            XCTAssertEqual(try data(name),before,"Extended pen conversion must never modify source bytes")
        }
    }
}

extension MetafileImageTests {
    func testClassicRegionFillPaintInvertExplicitBrushAndWMFObjectLifetime() throws {
        for prefix in ["classic-region-","wmf-classic-region-"] {
            let fill=try booleanPixels(prefix+"fill-preserve."+(prefix.hasPrefix("wmf") ? "wmf":"emf"))
            transferRGB(fill,20,16,[255,0,0],"FillRgn uses explicit brush")
            transferRGB(fill,50,2,[0,0,255],"FillRgn must preserve selected current brush")
            booleanGray(fill,40,16,255,"L-region excludes notch")
            let paint=try booleanPixels(prefix+"paint-current."+(prefix.hasPrefix("wmf") ? "wmf":"emf"))
            transferRGB(paint,20,16,[0,0,255],"PaintRgn uses selected brush")
            let inverse=try booleanPixels(prefix+"invert."+(prefix.hasPrefix("wmf") ? "wmf":"emf"))
            transferRGB(inverse,20,16,[0,255,255],"InvertRgn complements actual red destination")
            transferRGB(inverse,40,16,[255,0,0],"InvertRgn excludes points outside region")
        }
        let empty=try booleanPixels("classic-region-empty.emf")
        for y in stride(from:4,to:64,by:8) {for x in stride(from:4,to:64,by:8) {booleanGray(empty,x,y,255,"Empty classic regions paint no pixels")}}
        let reused=try booleanPixels("wmf-classic-region-slot-reuse.wmf")
        transferRGB(reused,20,16,[255,0,0],"WMF first-free region object participates in fill")
        transferRGB(reused,44,2,[0,255,0],"DeleteObject releases region slot for next brush")
        let copiedClip=try booleanPixels("wmf-classic-region-select-clip-copy-device.wmf")
        transferRGB(copiedClip,16,16,[0,255,0],"Selected region clip copies geometry before object deletion/reuse")
        booleanGray(copiedClip,32,16,255,"Selected region clip uses initial device mapping, not current scaled DC")
        booleanGray(copiedClip,4,4,255,"Copied clip remains bounded after region object reuse")
        let mappedRegion=try booleanPixels("wmf-classic-region-select-clip-transformed-region.wmf")
        transferRGB(mappedRegion,16,16,[255,0,0],"Transformed FillRegion paints inside fixed selected device clip")
        transferRGB(mappedRegion,9,16,[0,0,255],"Transformed FrameRegion retains fixed selected clip and X inner border")
        transferRGB(mappedRegion,16,9,[0,0,255],"Transformed FrameRegion logical Y border scales independently")
        booleanGray(mappedRegion,32,32,255,"Region transform must not transform selected device clip a second time")
        booleanGray(mappedRegion,4,4,255,"Mapped region cannot escape selected device clip")
        let mappedBitmap=try booleanPixels("wmf-classic-region-select-clip-transformed-bitmap.wmf")
        transferRGB(mappedBitmap,12,12,[255,0,0],"Transformed bitmap coverage paints within initial selected device clip")
        booleanGray(mappedBitmap,32,32,255,"Raster transfer must not transform selected device clip a second time")
        booleanGray(mappedBitmap,4,4,255,"Transformed bitmap cannot escape device clip")
        let emptyClip=try booleanPixels("wmf-classic-region-select-empty.wmf")
        XCTAssertEqual(emptyClip.bytes,try booleanPixels("classic-region-empty.emf").bytes,"A valid empty selected region clips all attempted painting")
        let combinedClip=try booleanPixels("wmf-classic-region-select-combined-restore.wmf")
        transferRGB(combinedClip,12,12,[255,0,0],"Selected initial-device clip survives current logical mapping and intersection")
        transferRGB(combinedClip,36,36,[255,0,0],"Restored clip retains intersected region interior")
        transferRGB(combinedClip,20,20,[0,0,255],"Restored selected clip retains current-mapped excluded hole")
        transferRGB(combinedClip,44,12,[0,0,255],"Restored clip retains current-mapped intersection limit")
        transferRGB(combinedClip,4,4,[0,0,255],"Save/Restore restores selected boundary after NULL reset")
        let resetClip=try booleanPixels("wmf-classic-region-select-clip-null.wmf")
        transferRGB(resetClip,4,4,[255,0,0],"WMF SelectClipRegion zero restores default clip")
        transferRGB(resetClip,40,40,[255,0,0],"NULL reset removes selected region restriction")
        let restoredClip=try booleanPixels("wmf-classic-region-select-clip-restored.wmf")
        transferRGB(restoredClip,16,16,[255,0,0],"RestoreDC restores copied selected clip after original region deletion")
        transferRGB(restoredClip,32,16,[0,0,255],"Restored clip preserves destination outside copied geometry")
        transferRGB(restoredClip,4,4,[0,0,255],"Saved clip survives intervening NULL reset")
        let zeroIndex=try booleanPixels("wmf-classic-region-zero-index.wmf")
        transferRGB(zeroIndex,20,16,[255,0,0],"Region object slot zero remains valid for FillRegion")
        booleanGray(zeroIndex,40,16,255,"Region zero is not NULL for FillRegion")
        let negative=try booleanPixels("wmf-classic-region-negative.wmf")
        transferRGB(negative,4,4,[255,0,0],"WMF region scan coordinates preserve signed playback semantics")
        booleanGray(negative,20,4,255,"Signed region does not wrap into a large unsigned rectangle")
    }
    func testClassicRegionFrameUsesAnisotropicUnionInteriorWithoutBandSeams() throws {
        for ext in ["emf","wmf"] {
            let prefix=ext=="emf" ? "classic-region-frame-":"wmf-classic-region-frame-"
            let union=try booleanPixels(prefix+"union."+ext)
            transferRGB(union,9,32,[255,0,0],"Frame logical X thickness")
            booleanGray(union,12,32,255,"Frame is not stroke-centered or width doubled")
            transferRGB(union,20,10,[255,0,0],"Frame logical Y thickness differs from X")
            booleanGray(union,20,14,255,"Frame Y inner boundary")
            booleanGray(union,20,24,255,"Adjacent region bands must not leave a per-rectangle seam")
            // Explicit macOS rectangular union-boundary strip policy. Exact
            // Windows corner rasterization is not specified by FrameRgn.
            transferRGB(union,30,28,[255,0,0],"Concave anisotropic boundary-strip corner remains inside union")
            booleanGray(union,27,30,255,"Concave frame stops beyond both strip extents")
            transferRGB(union,30,20,[255,0,0],"Frame follows concave union edge")
            booleanGray(union,35,20,255,"Frame stays inside union")
            let hole=try booleanPixels(prefix+"hole."+ext)
            transferRGB(hole,14,32,[255,0,0],"Frame includes inside hole boundary")
            booleanGray(hole,11,32,255,"Hole frame retains interior strip")
            booleanGray(hole,32,32,255,"Frame never fills hole")
            let islands=try booleanPixels(prefix+"islands."+ext)
            transferRGB(islands,9,16,[255,0,0],"First disconnected frame island")
            transferRGB(islands,41,48,[255,0,0],"Second disconnected frame island")
            booleanGray(islands,32,32,255,"Frame never bridges disconnected regions")
        }
        XCTAssertEqual(try booleanPixels("classic-region-frame-negative.emf").bytes,try booleanPixels("classic-region-frame-union.emf").bytes,"Frame negative widths use absolute logical extents")
        let zero=try booleanPixels("classic-region-frame-zero.emf"),zeroX=try booleanPixels("classic-region-frame-zero-x.emf"),zeroY=try booleanPixels("classic-region-frame-zero-y.emf")
        XCTAssertEqual(zero.bytes,try booleanPixels("classic-region-empty.emf").bytes,"Both-zero frame has no area")
        transferRGB(zeroX,32,10,[255,0,0],"Zero-X frame retains horizontal inner borders")
        booleanGray(zeroX,9,32,255,"Zero-X frame has no vertical inner borders")
        transferRGB(zeroY,9,32,[255,0,0],"Zero-Y frame retains vertical inner borders")
        booleanGray(zeroY,32,10,255,"Zero-Y frame has no horizontal inner borders")
        let state=try booleanPixels("classic-region-transform-restore.emf")
        transferRGB(state,20,16,[255,0,0],"Region applies world transform inside saved clip")
        booleanGray(state,40,16,255,"Region retains effective DC clip")
        transferRGB(state,48,48,[0,0,255],"RestoreDC restores clip/world/current brush")
        let rop=try booleanPixels("classic-region-frame-rop2.emf")
        transferRGB(rop,9,20,[0,255,255],"FrameRgn uses actual R2_XORPEN destination")
        booleanGray(rop,20,20,255,"ROP2 frame leaves eroded union interior unchanged")
    }
    func testClassicFloodUsesDestinationConnectivityModesClipPatternsAndSavedState() throws {
        for name in ["classic-flood-surface.emf","classic-flood-border.emf","wmf-classic-flood-surface.wmf","wmf-classic-flood-border.wmf","wmf-classic-flood-legacy-border.wmf"] {
            let pixels=try booleanPixels(name)
            transferRGB(pixels,16,16,[255,0,0],"Flood paints connected seed component")
            booleanGray(pixels,40,16,255,"Flood cannot cross actual black dividing wall")
            booleanGray(pixels,4,4,255,"Enclosing boundary prevents escape")
            transferRGB(pixels,8,16,[0,0,0],"Flood preserves border destination")
            transferRGB(pixels,22,22,name.contains("surface") ? [0,0,255]:[255,0,0],"Surface matches seed color; border traverses non-border colors")
        }
        for suffix in ["surface-mismatch","border-seed","outside","invalid-color","clipped","hollow"] {
            let p=try booleanPixels("classic-flood-noop-"+suffix+".emf")
            booleanGray(p,16,16,255,"Unfillable seed is successful no-op")
            transferRGB(p,22,22,[0,0,255],"No-op preserves destination island")
        }
        for name in ["classic-flood-clip.emf","wmf-classic-flood-clip.wmf"] {
            let p=try booleanPixels(name)
            transferRGB(p,16,16,[255,0,0],"Flood uses effective clip as connectivity boundary")
            booleanGray(p,7,16,255,"Flood does not escape left clip")
            booleanGray(p,24,16,255,"Flood does not escape right clip")
        }
        for name in ["classic-flood-hatch.emf","wmf-classic-flood-hatch.wmf"] {
            let p=try booleanPixels(name);var red=0,white=0
            for y in 12..<50 {for x in 12..<28 {let c=p.pixel(x,y);if c[0]>240 && c[1]<15 {red+=1};if c[0]>240 && c[1]>240 && c[2]>240 {white+=1}}}
            XCTAssertGreaterThan(red,30,"Flood applies selected hatch over complete captured component")
            XCTAssertGreaterThan(white,30,"Pattern gaps remain actual holes")
            transferRGB(p,22,22,[0,0,255],"Surface flood preserves nonmatching island beneath pattern")
            booleanGray(p,40,16,255,"Patterned flood does not cross wall")
        }
        let blended=try booleanPixels("classic-flood-alpha-destination.emf")
        transferRGB(blended,16,16,[0,0,255],"Flood compares actual alpha-composited destination RGB over white DC")
        booleanGray(blended,7,16,255,"Alpha-derived flood component cannot escape into unpainted white backdrop")
        booleanGray(blended,26,16,255,"Alpha-derived destination component remains bounded")
        let diagonal=try booleanPixels("classic-flood-four-connected.emf")
        transferRGB(diagonal,10,10,[255,0,0],"Seed component contains its single pixel")
        booleanGray(diagonal,11,11,255,"Flood uses four-neighbor connectivity, not diagonal adjacency")
        transferRGB(diagonal,9,10,[0,0,0],"Flood preserves surrounding nonmatching pixels")
        let xor=try booleanPixels("classic-flood-rop2.emf")
        booleanGray(xor,16,16,0,"Flood participates in R2_XORPEN")
        booleanGray(xor,32,16,255,"Flood ROP2 leaves pixels outside clip unchanged")
        let state=try booleanPixels("classic-flood-transform-restore.emf")
        transferRGB(state,16,16,[255,0,0],"Flood seed uses current transform")
        booleanGray(state,30,16,255,"Transformed flood remains clipped")
        transferRGB(state,48,48,[0,0,255],"Flood preserves current brush and restores saved DC state")
    }
    func testClassicRegionFloodMalformedRecordsRefuseCompleteImageWithoutSourceChanges() throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-classic-region-") || $0.hasPrefix("unsupported-wmf-classic-region-")}.sorted()
        XCTAssertEqual(names.count,23,"Each region/scan/object/flood refusal remains independently enrolled")
        for name in names {
            let bytes=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes),name)
            XCTAssertNil(ComparisonImage(bytes:bytes),name+" cannot return earlier valid paint")
            XCTAssertEqual(try data(name),bytes,"Region/flood playback must preserve original input")
        }
    }
}

extension MetafileImageTests {
    func testClassicPatternBrushMonochromeBitOrderRowsPaddingAndIgnoredFields()throws {
        for name in ["wmf-classic-patternbrush-mono.wmf","classic-monobrush-dynamic.emf","classic-monobrush-bottom-up.emf","classic-monobrush-black-white.emf"] {
            let before=try data(name),value=try booleanPixels(name)
            transferRGB(value,8,8,[0,0,255],name+" bit1 uses current background")
            transferRGB(value,9,8,[255,0,0],name+" bit0 uses current text even transparent background mode")
            transferRGB(value,8,9,[255,0,0],name+" top-down display row1")
            transferRGB(value,9,9,[0,0,255],name+" asymmetric next row proves row orientation")
            transferRGB(value,16,8,[0,0,255],name+" tile repeats width, excluding padding")
            XCTAssertEqual(try data(name),before,"Playback never modifies original metafile bytes")
        }
        let wide=try booleanPixels("wmf-classic-patternbrush-wide.wmf")
        transferRGB(wide,16,8,[0,0,255],"17px DDB uses third data byte before WORD padding")
        transferRGB(wide,17,8,[0,0,255],"17px DDB wraps after last actual bit")
        transferRGB(wide,18,8,[255,0,0],"DDB padding does not widen the tile")
        transferRGB(wide,17,9,[255,0,0],"DDB second row is top-down, with its own WORD stride")
    }
    func testClassicPatternBrushPalettesLiveColorsSaveRestoreAndObjectReuse()throws {
        let fixed=try booleanPixels("classic-monobrush-colored.emf")
        transferRGB(fixed,8,8,[255,0,0],"Arbitrary RGB bitmap palette remains fixed on a color DC")
        transferRGB(fixed,9,8,[0,255,0],"RGBQUAD entry0 remains supplied green")
        let dib=try booleanPixels("classic-patternbrush-dib-fixed.emf")
        booleanGray(dib,8,8,255,"EMR94 black-white DIB retains fixed white entry1")
        booleanGray(dib,9,8,0,"EMR94 does not adopt EMR93 mono conversion")
        for name in ["classic-monobrush-state.emf","wmf-classic-patternbrush-state.wmf"] {
            let value=try booleanPixels(name)
            for y in [8,40] {transferRGB(value,8,y,[0,0,255],name+" restored original background");transferRGB(value,9,y,[255,0,0],name+" restored original text")}
            transferRGB(value,8,24,[255,255,0],name+" live background after SaveDC")
            transferRGB(value,9,24,[0,255,0],name+" live text after SaveDC")
            transferRGB(value,8,56,[0,255,0],name+" unselected object delete/reuse selects new solid brush")
        }
        let palette=try booleanPixels("classic-monobrush-palette-select.emf")
        for y in [8,40] {transferRGB(palette,8,y,[255,0,0],"Palette entry1 restored");transferRGB(palette,9,y,[0,255,0],"Palette entry0 restored")}
        transferRGB(palette,8,24,[255,255,0],"WORD palette index1 resolves against later selected paletteB")
        transferRGB(palette,9,24,[0,255,255],"WORD palette index0 uses PALETTEENTRY RGB byte order")
        let edited=try booleanPixels("classic-patternbrush-palette-select.emf")
        transferRGB(edited,8,8,[255,0,0],"EMR94 selected before palette receives later palette entry1")
        transferRGB(edited,9,8,[0,255,0],"EMR94 receives PALETTEENTRY RGB entry0")
        transferRGB(edited,8,24,[255,255,0],"EMR50 palette mutation is reflected when brush reselected")
        transferRGB(edited,9,24,[0,255,255],"EMR50 updated palette entry0 has independent RGB wire bytes")
        let wmfPalette=try booleanPixels("wmf-classic-patternbrush-palette-select.wmf")
        for y in [8,40] {transferRGB(wmfPalette,8,y,[255,0,0],"WMF selected palette restored");transferRGB(wmfPalette,9,y,[0,255,0],"WMF palette entry0 restored")}
        transferRGB(wmfPalette,8,24,[255,255,0],"WMF compatible two-WORD SelectPalette uses later B entry1")
        transferRGB(wmfPalette,9,24,[0,255,255],"WMF normative single-WORD SelectPalette uses correct RGB entries")
        transferRGB(wmfPalette,8,56,[255,0,255],"WMF palette resize/set makes newly indexed entry2 available")
        transferRGB(wmfPalette,9,56,[0,0,255],"WMF set-entry RGB wire order updates selected palette entry0")
        let flood=try booleanPixels("classic-monobrush-palette-flood.emf")
        transferRGB(flood,8,8,[255,0,0],"Flood COLORREF palette index and selected brush palette share correct RGB")
        transferRGB(flood,9,8,[0,255,0],"Flood pattern entry0 remains green")
        transferRGB(flood,40,8,[0,255,0],"Palette flood preserves destination outside effective clip")
    }
    func testClassicPatternBrushTransformsClipFillStrokeBooleanRegionAndFloodConsumers()throws {
        let transform=try booleanPixels("classic-monobrush-clip-origin.emf")
        transferRGB(transform,9,9,[0,0,255],"Device brush origin is preserved under scaled logical painting")
        transferRGB(transform,10,9,[255,0,0],"World scaling does not enlarge device bitmap brush tile")
        booleanGray(transform,40,16,255,"Effective clip bounds bitmap brush painting")
        transferRGB(transform,41,41,[0,0,255],"RestoreDC restores logical transform/clip while retaining saved brush origin")
        let clipped=try booleanPixels("wmf-classic-patternbrush-clip.wmf")
        booleanGray(clipped,4,8,255,"WMF device clip remains outside paint")
        transferRGB(clipped,8,8,[0,0,255],"WMF clip preserves native brush tile phase")
        let text=try booleanPixels("classic-monobrush-opaque-path.emf")
        transferRGB(text,8,8,[0,0,255],"Empty ETO_OPAQUE uses solid explicit background color")
        transferRGB(text,9,8,[0,0,255],"Opaque text background is not selected bitmap brush pattern")
        booleanGray(text,9,24,255,"Opaque rectangle remains bounded")
        transferRGB(text,8,40,[0,0,255],"Following FillPath restores mono background bit")
        transferRGB(text,9,40,[255,0,0],"Following FillPath restores selected live mono text bit")
        let stroke=try booleanPixels("classic-monobrush-fill-stroke.emf")
        transferRGB(stroke,8,20,[0,255,0],"Selected pen strokes independently of bitmap brush fill")
        transferRGB(stroke,16,20,[0,0,255],"Bitmap brush still fills closed stroked figure")
        for name in ["classic-monobrush-rop2.emf","wmf-classic-patternbrush-rop2.wmf","wmf-classic-patternbrush-patblt.wmf"] {
            let value=try booleanPixels(name)
            transferRGB(value,8,8,[255,255,0],name+" blue XOR opaque white")
            transferRGB(value,9,8,[0,255,255],name+" red XOR opaque white")
            booleanGray(value,4,4,255,name+" Boolean paint retains outside destination")
        }
        for name in ["classic-monobrush-region.emf","wmf-classic-patternbrush-region.wmf","classic-monobrush-flood.emf","wmf-classic-patternbrush-flood.wmf"] {
            let value=try booleanPixels(name)
            transferRGB(value,8,8,[0,0,255],name+" shared region/flood pattern bit1")
            transferRGB(value,9,8,[255,0,0],name+" shared region/flood pattern bit0")
            booleanGray(value,4,4,255,name+" preserves outside region/component")
        }
    }
    func testClassicPatternBrushMalformedOffsetsBitmap16AndResourceBoundsRefuseWholeImage()throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-classic-patternbrush-")}.sorted()
        XCTAssertEqual(names.count,19,"Every independently framed bitmap brush refusal remains enrolled")
        for name in names {
            let before=try data(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(before),name)
            XCTAssertNil(ComparisonImage(bytes:before),name+" cannot return earlier valid brush painting")
            XCTAssertEqual(try data(name),before,"Unsupported conversion retains exact original bytes")
        }
    }
}
