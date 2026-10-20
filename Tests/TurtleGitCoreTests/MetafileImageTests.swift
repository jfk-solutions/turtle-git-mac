// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import ImageIO
import Darwin
@testable import TurtleGitCore

final class MetafileImageTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func image(_ name: String) throws -> ComparisonImage { try XCTUnwrap(ComparisonImage(bytes: data(name)), "Could not render \(name)") }
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
            XCTAssertEqual(value.size,CGSize(width:96,height:64))
            try primary(value,0,12,12)
            if name.hasSuffix("wmf") {
                let outside = try rgb(value,35,35)
                XCTAssertTrue(outside.allSatisfy { $0>0.9 },"WMF intersection clipping was ignored")
            } else { try primary(value,2,58,12) }
        }
    }
    func testFrameAndDeviceMetadataDetermineSizeAndDPI() throws {
        let physical = try image("physical-frame.emf")
        XCTAssertEqual(physical.size,CGSize(width:192,height:128))
        XCTAssertEqual(try XCTUnwrap(physical.dpiX),96,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(physical.dpiY),96,accuracy:0.1)
        let wmf = try image("clip-144dpi.wmf")
        XCTAssertEqual(wmf.size,CGSize(width:96,height:64))
        XCTAssertEqual(try XCTUnwrap(wmf.dpiX),144,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(wmf.dpiY),144,accuracy:0.1)
    }
    func testEMFPlusTransformsClipsAndIndexedRestoreRenderDifferentTargets() throws {
        let value = try image("plus-transform.emf")
        XCTAssertEqual(value.size,CGSize(width:96,height:64))
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
            XCTAssertEqual(value.size,CGSize(width:96,height:64))
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
        XCTAssertEqual(value.size, CGSize(width: 96, height: 64))
        // Normalized horizontal-axis fractions through brush [0,48,-24,0,64,4]
        // then world Translate(8,4), independent of renderer-generated SVG.
        try primary(value, 0, 70, 10)
        try primary(value, 1, 60, 32)
        try primary(value, 2, 49, 54)
        XCTAssertTrue(try rgb(value, 44, 30).allSatisfy { $0 > 0.9 }, "Brush/world transforms misplaced the painted rectangle")
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-gradient-transform.emf"))), as: UTF8.self)
        XCTAssertTrue(svg.contains("<linearGradient"), "Gradient was flattened to a solid color")
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
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-gradient-radial.emf"))), as: UTF8.self)
        XCTAssertTrue(svg.contains("<radialGradient"))
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
            // x24.5 is .5/16 into period1 after world translation8.
            // Three equally spaced red/green/blue stops give red15/16
            // for Tile and blue15/16 for FlipX, with green1/16.
            for (index,y) in [(0,20),(1,52)]{
                let raw=try paints[index].sample(24,y),expected:[CGFloat]=index==0 ? [15.0/16,1.0/16,0,1]:[0,1.0/16,15.0/16,1]
                for channel in 0..<4{XCTAssertEqual(raw[channel],expected[channel],accuracy:1.0/255,"Wrapped source pixel differs before native SVG: \(paints[index].diagnostic)")}
            }
        }
        let value = try image("plus-gradient-wrap.emf")
        // Each sample is just inside the second period at the same normalized
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
            XCTAssertEqual(value.size, CGSize(width: 96, height: 64))
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
        for name in ["unsupported-region.emf", "unsupported-rop.emf", "unsupported-image-effect.emf", "unsupported-image-attributes.emf", "unsupported-image-wrap.emf", "unsupported-image-attribute-type.emf", "unsupported-gradient-stops.emf", "unsupported-image-tile-budget.emf", "unsupported-gradient-precision.emf"] {
            XCTAssertThrowsError(try MetafileImageDecoder.convert(data(name)))
            XCTAssertNil(ComparisonImage(bytes: try data(name)))
        }
        var truncated = try data("plus-transform.emf");truncated.removeLast()
        XCTAssertThrowsError(try MetafileImageDecoder.convert(truncated))
        var malformed = try data("classic-vector.emf");malformed.replaceSubrange(92..<96,with:[0xff,0xff,0xff,0x7f])
        XCTAssertThrowsError(try MetafileImageDecoder.convert(malformed))
        XCTAssertNil(try MetafileImageDecoder.convert(Data("ordinary text".utf8)))
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
        let value=try image("plus-formatted-"+name+".emf"),width=value.pixels.width,height=value.pixels.height
        XCTAssertEqual(width,240);XCTAssertEqual(height,180)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes{storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(value.pixels,in:CGRect(x:0,y:0,width:width,height:height))
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
        XCTAssertEqual(value.pixels.width, 96, name); XCTAssertEqual(value.pixels.height, 64, name)
        var rgba = [UInt8](repeating: 0, count: 96 * 64 * 4)
        try rgba.withUnsafeMutableBytes { storage in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 96, height: 64,
                bitsPerComponent: 8, bytesPerRow: 96 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(value.pixels, in: CGRect(x: 0, y: 0, width: 96, height: 64))
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
        let width = value.pixels.width, height = value.pixels.height
        XCTAssertEqual(width, 96, name); XCTAssertEqual(height, 64, name)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(value.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
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
}
