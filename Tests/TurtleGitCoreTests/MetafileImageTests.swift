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
        XCTAssertGreaterThan(color[channel],0.8,file:file,line:line)
        for i in 0..<3 where i != channel { XCTAssertLessThan(color[i],0.25,file:file,line:line) }
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
        XCTAssertTrue(svg.contains("stroke=\"#ff0000\""))
        XCTAssertTrue(svg.contains("stroke-opacity=\"1\""))
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
            XCTAssertGreaterThan(red, 0, "Hatch style \(style) discarded its foreground")
            XCTAssertGreaterThan(blue, 0, "Hatch style \(style) discarded its background")
            if ![2, 3, 5].contains(style) {
                XCTAssertEqual(red + blue, 64, "Hatch style \(style) became a solid approximation or blended pattern")
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
        let scaled = try image("plus-hatch-alpha-world.emf")
        var redRows = 0, blueRows = 0
        for y in 10..<34 {
            let color = try rgb(scaled, 20, y), repeated = try rgb(scaled, 20, y + 8)
            for channel in 0..<3 { XCTAssertEqual(color[channel], repeated[channel], accuracy: 0.03, "World scale stretched the device hatch cell") }
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
                XCTAssertEqual(baseline[channel], shifted[channel], accuracy: 0.03, "Rendering origin did not shift hatch device phase")
                XCTAssertEqual(baseline[channel], restored[channel], accuracy: 0.03, "Restore did not restore hatch rendering origin")
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
}
