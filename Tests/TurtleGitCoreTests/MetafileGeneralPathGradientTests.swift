// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafileGeneralPathGradientTests:XCTestCase {
    private let corpus=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/GeneralPathGradient")
    private struct Reference:Decodable {let cases:[Case]}
    private struct Case:Decodable {let file:String,sourceSHA256:String,rgba:String,rgbaSHA256:String;let width:Int,height:Int,tolerance:Int;let exactGlyphGeometry:Bool}
    private func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func pixels(_ image:CGImage)throws->[UInt8] {
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        try bytes.withUnsafeMutableBytes { buffer in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return bytes
    }
    private func verify(_ names:[String],file:StaticString=#filePath,line:UInt=#line)throws {
        let reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:corpus.appendingPathComponent("windows-reference.json")))
        for name in names {
            let record=try XCTUnwrap(reference.cases.first{$0.file==name+".emf"},name,file:file,line:line)
            XCTAssertTrue(record.exactGlyphGeometry,file:file,line:line)
            let url=corpus.appendingPathComponent(record.file),original=try Data(contentsOf:url)
            XCTAssertEqual(hash(original),record.sourceSHA256,file:file,line:line)
            let expected=try Data(contentsOf:corpus.appendingPathComponent(record.rgba))
            XCTAssertEqual(hash(expected),record.rgbaSHA256,file:file,line:line)
            XCTAssertEqual(expected.count,record.width*record.height*4,file:file,line:line)
            let decoded=try XCTUnwrap(ComparisonImage(bytes:original),name,file:file,line:line)
            XCTAssertEqual(decoded.size,CGSize(width:record.width,height:record.height),file:file,line:line)
            let actual=try pixels(decoded.pixels)
            guard actual.count==expected.count else {XCTFail("Unexpected natural extent for "+name,file:file,line:line);continue}
            var maximum=0,channelsOverTolerance=0,worstOffset=0
            for offset in actual.indices {
                let channel=offset%4,pixel=offset-channel
                let wanted=channel==3 ? Int(expected[offset]):Int((Double(Int(expected[offset])*Int(expected[pixel+3]))/255).rounded())
                let difference=abs(Int(actual[offset])-wanted)
                if difference>maximum {maximum=difference;worstOffset=offset}
                if difference>record.tolerance {channelsOverTolerance+=1}
            }
            let worstPixel=worstOffset/4
            XCTAssertLessThanOrEqual(maximum,record.tolerance,"\(name): \(channelsOverTolerance) differing channels; maximum \(maximum) at (\(worstPixel%record.width),\(worstPixel/record.width)) channel \(worstOffset%4)",file:file,line:line)
            XCTAssertEqual(channelsOverTolerance,0,"Full original Windows frame must agree, including empty coverage",file:file,line:line)
            XCTAssertEqual(try Data(contentsOf:url),original,file:file,line:line)
        }
    }
    func testGeneralCubicUniformAndMulticolorExplicitAndNativeBoundaries()throws {
        try verify(["native-general-cubic-uniform","native-general-cubic-multi","explicit-cubic-uniform","explicit-cubic-multi"])
    }
    func testDisjointNestedAndReversedFigureOrderMatchesWindowsFan()throws {
        try verify(["native-general-disjoint-ab","native-general-disjoint-ba","native-general-nested-same","native-general-nested-reversed","explicit-disjoint-ab"])
    }
    func testSelfCrossingAndReversedBoundariesMatchWindowsCoverageAndColors()throws {
        try verify(["native-general-crossing","native-general-crossing-reversed"])
    }
    func testGeneralBrushThroughClipSourceCopyPenAndGlyphConsumers()throws {
        try verify(["native-general-cubic-clip","native-general-cubic-sourcecopy","native-general-cubic-pen"])
        // Glyph outlines/font fallback vary by platform. Verify actual colored
        // gradient ink and original wire identity rather than foreign outlines.
        let url=corpus.appendingPathComponent("native-general-cubic-glyph.emf"),original=try Data(contentsOf:url)
        let image=try XCTUnwrap(ComparisonImage(bytes:original))
        XCTAssertEqual(image.size,CGSize(width:64,height:64))
        let bytes=try pixels(image.pixels)
        var colored=0
        for offset in stride(from:0,to:bytes.count,by:4) {
            let red=Int(bytes[offset]),green=Int(bytes[offset+1]),blue=Int(bytes[offset+2])
            if red>green+20 && blue>green+20 && bytes[offset+3]>0 {colored+=1}
        }
        XCTAssertGreaterThan(colored,8)
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testOpenCubicAndLineFiguresImplicitlyCloseWithoutChangingColorOrder()throws {
        try verify(["open-cubic-after-paint","closed-cubic-after-paint","open-cubic-multi","open-disjoint-ab"])
    }
    func testExcessiveCubicBoundaryRefusesWholeImageAfterEarlierPaint()throws {
        for suffix in ["flatten-budget"] {
            let url=corpus.appendingPathComponent("refused-cubic-"+suffix+"-after-paint.emf"),original=try Data(contentsOf:url)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),suffix)
            XCTAssertNil(ComparisonImage(bytes:original),"A later invalid/unbounded brush cannot expose earlier red paint")
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
}
