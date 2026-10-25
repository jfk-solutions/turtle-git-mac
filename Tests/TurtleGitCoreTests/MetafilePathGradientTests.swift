// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafilePathGradientTests:XCTestCase {
    private let corpus=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private struct Sample:Decodable {let x:Int,y:Int,rgba:[Int];let tolerance:Int}
    private struct ReferenceCase:Decodable {let file:String;let sourceSHA256:String;let samples:[Sample];let width:Int?;let height:Int?}
    private struct Reference:Decodable {let cases:[ReferenceCase]}
    private func cases()throws->[ReferenceCase] {
        let value=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:corpus.appendingPathComponent("path-gradient-windows-reference.json")))
        XCTAssertEqual(Set(value.cases.map(\.file)).count,value.cases.count,"Duplicate reference cases obscure the independent oracle")
        return value.cases
    }
    private func verify(_ names:[String],file:StaticString=#filePath,line:UInt=#line)throws {
        let reference=try cases()
        for name in names {
            let sample=try XCTUnwrap(reference.first{$0.file==name+".emf"},"Independent Windows reference missing "+name,file:file,line:line)
            XCTAssertFalse(sample.samples.isEmpty,"Reference must contain observed pixels",file:file,line:line)
            let url=corpus.appendingPathComponent(sample.file),original=try Data(contentsOf:url)
            XCTAssertEqual(SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined(),sample.sourceSHA256,"Reference must be bound to the exact Windows-tested wire",file:file,line:line)
            let image=try XCTUnwrap(ComparisonImage(bytes:original),sample.file,file:file,line:line)
            XCTAssertEqual(image.size,CGSize(width:sample.width ?? 64,height:sample.height ?? 64),file:file,line:line)
            let width=image.pixels.width,height=image.pixels.height
            var rgba=[UInt8](repeating:0,count:width*height*4)
            try rgba.withUnsafeMutableBytes {buffer in
                let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
                let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
                context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
            }
            for point in sample.samples {
                XCTAssertTrue(point.x>=0 && point.x<width && point.y>=0 && point.y<height && point.rgba.count==4,file:file,line:line)
                guard point.x>=0,point.x<width,point.y>=0,point.y<height,point.rgba.count==4 else {continue}
                let offset=(point.y*width+point.x)*4
                for channel in 0..<4 {
                    let expected=channel==3 ? point.rgba[channel]:Int((Double(point.rgba[channel]*point.rgba[3])/255).rounded())
                    XCTAssertLessThanOrEqual(abs(Int(rgba[offset+channel])-expected),point.tolerance,"\(name) pixel(\(point.x),\(point.y)) channel\(channel)",file:file,line:line)}
            }
            XCTAssertEqual(try Data(contentsOf:url),original,"Viewing must not replace original metafile bytes",file:file,line:line)
        }
    }
    func testLinePathPolygonsOffcenterAndIndependentSurroundColors()throws {
        try verify(["path-gradient-square","path-gradient-triangle","path-gradient-quad-offcenter","path-gradient-quad-multicolor","path-gradient-triangle-multicolor","path-gradient-concave","path-gradient-cardinal-boundary","path-gradient-center-outside","path-gradient-concave-outsidekernel","path-gradient-surround-two","path-gradient-surround-excess"])
        // The extra earlier-paint variant was not itself Windows-rendered.
        // Its unchanged brush payload has the sampled excess-color semantics;
        // retain it as a positive no-partial-refusal regression.
        let excessURL=corpus.appendingPathComponent("path-gradient-surround-excess-after-paint.emf"),excess=try Data(contentsOf:excessURL)
        XCTAssertNotNil(ComparisonImage(bytes:excess),"Valid excess colors must not discard earlier painting")
        XCTAssertEqual(try Data(contentsOf:excessURL),excess)
    }
    func testFocusGammaAndBoundaryToCenterBlendSemantics()throws {
        try verify(["path-gradient-focus-zero","path-gradient-focus-xy","path-gradient-focus-one","path-gradient-gamma","path-gradient-preset","path-gradient-blend","path-gradient-focus-offcenter","path-gradient-focus-multicolor","path-gradient-preset-multicolor","path-gradient-blend-multicolor","path-gradient-linear-gamma-off","path-gradient-linear-gamma-on","path-gradient-native-linear-alpha-off","path-gradient-native-linear-alpha-on"])
    }
    func testBrushAndWorldTransformsAlphaAndClampedCoverage()throws {
        try verify(["path-gradient-brush-transform","path-gradient-world-transform","path-gradient-sheared","path-gradient-alpha","path-gradient-gamma-alpha","path-gradient-wrap-0","path-gradient-wrap-1","path-gradient-wrap-2","path-gradient-wrap-3"])
    }
    func testSharedPenGlyphClipAndSourceCopyUseActualGradientPaint()throws {
        try verify(["path-gradient-pen","path-gradient-clip","path-gradient-sourcecopy"])
        // Font fallback differs between Windows and macOS. Check the shared
        // brush's colored ink without asserting a foreign platform glyph shape.
        let source=try Data(contentsOf:corpus.appendingPathComponent("path-gradient-glyph.emf"))
        let image=try XCTUnwrap(ComparisonImage(bytes:source))
        XCTAssertEqual(image.pixels.width,65);XCTAssertEqual(image.pixels.height,65)
        let width=image.pixels.width,height=image.pixels.height
        var ink=[UInt8](repeating:0,count:width*height*4)
        try ink.withUnsafeMutableBytes {buffer in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        let colored=stride(from:0,to:ink.count,by:4).filter {Int(ink[$0])>Int(ink[$0+1])+20 && Int(ink[$0+2])>Int(ink[$0+1])+20}
        XCTAssertGreaterThan(colored.count,8,"Gradient glyph ink must use the colored brush, not solid default text")
        XCTAssertEqual(try Data(contentsOf:corpus.appendingPathComponent("path-gradient-glyph.emf")),source)
    }
    func testMalformedAndUnsupportedBrushAfterEarlierPaintRefusesWholeImageWithoutChangingBytes()throws {
        for suffix in ["colors-empty","path-truncated","center-nonfinite","focus-truncated","focus-nonfinite","wrap-invalid","transform-singular","preset-unsorted","blend-unsorted","raster-work-budget","self-crossing","multi-subpath"] {
            let url=corpus.appendingPathComponent("path-gradient-refused-"+suffix+".emf"),original=try Data(contentsOf:url)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),suffix) {error in
                if suffix=="raster-work-budget" {
                    guard let failure=error as? MetafileImageFailure,case .failed(let diagnostic)=failure else {return XCTFail("Expected raster budget diagnostic, got \(error)")}
                    XCTAssertTrue(diagnostic.contains("aggregate path-gradient raster work limit"),diagnostic)
                }
            }
            XCTAssertNil(ComparisonImage(bytes:original),"A malformed later record must not expose earlier red paint: "+suffix)
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
}
