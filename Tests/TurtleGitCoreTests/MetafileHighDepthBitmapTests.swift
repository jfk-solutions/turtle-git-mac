// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import ImageIO
@testable import TurtleGitCore

/// Raw EMF+ WORD samples exercise the documented Mac eight-bit display profile,
/// supported by Wine's raw-image playback path. These are not Windows HDR or
/// GDI+13-bit LockBits pixel-certification tests. Expected colors are authored
/// independently as literal32-bit pixels and literal channel values.
final class MetafileHighDepthBitmapTests:XCTestCase {
    private let fixtures=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private let formats=["gray","rgb48","argb64","pargb64"]
    private func bytes(_ name:String)throws->Data {try Data(contentsOf:fixtures.appendingPathComponent(name+".emf"))}
    private func converted(_ name:String)throws->Data {
        let input=try bytes(name),original=input
        let output=try XCTUnwrap(MetafileImageDecoder.convert(input),"High-depth conversion refused \(name)")
        XCTAssertEqual(input,original,"Conversion mutated caller bytes")
        XCTAssertEqual(try bytes(name),original,"Conversion rewrote source fixture")
        return output
    }
    private struct Raster {
        let width:Int,height:Int,rgba:[UInt8]
        func sample(_ x:Int,_ y:Int)->[Double] {
            let offset=(y*width+x)*4,a=Double(rgba[offset+3])/255
            return (0..<3).map{a>0 ? Double(rgba[offset+$0])/(255*a):0}+[a]
        }
    }
    private func raster(_ image:CGImage)throws->Raster {
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        try bytes.withUnsafeMutableBytes {storage in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let ctx=try XCTUnwrap(CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.interpolationQuality = .none
            ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return Raster(width:image.width,height:image.height,rgba:bytes)
    }
    private func embedded(_ name:String)throws->Raster {
        let svg=String(decoding:try converted(name),as:UTF8.self)
        let start=try XCTUnwrap(svg.range(of:"data:image/png;base64,")),tail=svg[start.upperBound...]
        let end=try XCTUnwrap(tail.firstIndex(of:"\"")),data=try XCTUnwrap(Data(base64Encoded:String(tail[..<end])))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        return try raster(XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil)))
    }
    private func display(_ name:String)throws->Raster {
        let input=try bytes(name),original=input,image=try XCTUnwrap(ComparisonImage(bytes:input),"Native image refused \(name)")
        XCTAssertEqual(image.size,CGSize(width:64,height:64))
        XCTAssertEqual(try bytes(name),original)
        return try raster(image.pixels)
    }
    private func assertEquivalent(_ a:Raster,_ b:Raster,_ name:String,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertEqual(a.width,b.width,name,file:file,line:line);XCTAssertEqual(a.height,b.height,name,file:file,line:line)
        guard a.rgba.count==b.rgba.count else{XCTFail("Raster extent differs: \(name)",file:file,line:line);return}
        let maxError=zip(a.rgba,b.rgba).map{abs(Int($0)-Int($1))}.max() ?? 0
        XCTAssertLessThanOrEqual(maxError,1,"\(name) differs from independent32-bit control",file:file,line:line)
    }
    private func assertPixel(_ actual:[Double],_ expected:[Double],_ message:String,file:StaticString = #filePath,line:UInt = #line) {
        for channel in 0..<4 {XCTAssertEqual(actual[channel],expected[channel],accuracy:1.1/255,message+" channel\(channel)",file:file,line:line)}
    }
    func testFourRawWordFormatsHaveIndependentColorAndAlphaSamples()throws {
        let expected:[String:[[Double]]]=[
            "gray":[[0,0,0,1],[128.0/255,128.0/255,128.0/255,1],[1,1,1,1],[64.0/255,64.0/255,64.0/255,1]],
            "rgb48":[[1,0,0,1],[0,1,0,1],[0,0,1,1],[1,1,1,1]],
            "argb64":[[1,0,0,128.0/255],[0,1,0,1],[0,0,1,64.0/255],[0,0,0,0]],
            "pargb64":[[1,0,0,128.0/255],[0,1,0,1],[0,0,1,64.0/255],[0,0,0,0]]]
        for name in formats {
            let actual=try embedded("high-depth-"+name)
            XCTAssertEqual(actual.width,2);XCTAssertEqual(actual.height,2)
            for y in 0..<2{for x in 0..<2{assertPixel(actual.sample(x,y),expected[name]![y*2+x],name+" \(x),\(y)")}}
        }
    }
    func testNegativeStrideAndNonzeroRowPaddingPreserveSourceOrientation()throws {
        for name in formats {
            let expected=try embedded("high-depth-"+name)
            for suffix in ["-negative","-padded"] {
                assertEquivalent(try embedded("high-depth-"+name+suffix),expected,name+suffix)
            }
        }
    }
    func testTexturesAndThreePointWorldMappingMatchIndependentLowDepthControls()throws {
        for name in formats {
            for suffix in ["","-texture","-mapped"] {
                assertEquivalent(try display("high-depth-"+name+suffix),try display("high-depth-"+name+suffix+"-control"),name+suffix)
            }
        }
    }
    func testLowWordBytesDoNotBecomeRoundedOrThirteenBitDisplayValues()throws {
        let actual=try embedded("high-depth-gray-precision")
        // 0x00ff,0x7fff,0x2000,0x0101: consume high bytes, not rounded
        // full-range values or a0...8192 LockBits normalization heuristic.
        for (index,value) in [0.0,127.0/255,32.0/255,1.0/255].enumerated() {
            assertPixel(actual.sample(index%2,index/2),[value,value,value,1],"literalWORD high-byte probe\(index)")
        }
        assertEquivalent(actual,try embedded("high-depth-gray-precision-control"),"gray precision")
    }
    func testPremultipliedWordsQuantizeBeforeAlphaConversionAndAcceptBothDocumentedEnums()throws {
        assertEquivalent(try embedded("high-depth-pargb64-precision"),try embedded("high-depth-pargb64-precision-control"),"nontrivial premultiplication")
        let source=try embedded("high-depth-pargb64"),sdk=try embedded("high-depth-pargb64-sdk")
        assertEquivalent(sdk,source,"wire0x1a400e andSDK0x1c400e")
        assertEquivalent(try display("high-depth-pargb64-sdk-texture"),try display("high-depth-pargb64-texture-control"),"SDK texture")
        let precision=try embedded("high-depth-pargb64-precision")
        XCTAssertEqual(precision.sample(0,0)[3],127.0/255,accuracy:1.0/255)
        // High-byte alpha0 normalizes RGB0, even when low WORD bytes are nonzero.
        assertPixel(precision.sample(0,1),[0,0,0,0],"zero quantized alpha")
    }
    func testMalformedHighDepthLayoutAndPaletteRefuseTheEntirePaintedPrefix()throws {
        let suffixes=["truncated","trailing","short-stride","unaligned-stride","zero-stride","min-stride","palette","indexed-flag","overflow","negative-width","negative-height"]
        var names=formats.flatMap{name in suffixes.map{"high-depth-refused-"+name+"-"+$0}}
        names += ["high-depth-refused-pargb-undocumented-enum","high-depth-refused-rgb24-unaligned-positive","high-depth-refused-rgb24-unaligned-negative"]
        names += formats.flatMap{name in ["truncated","palette"].map{"high-depth-refused-texture-"+name+"-"+$0}}
        XCTAssertEqual(names.count,55)
        for name in names {
            let input=try bytes(name),original=input
            XCTAssertThrowsError(try MetafileImageDecoder.convert(input),"Accepted malformed high-depth record \(name)")
            XCTAssertNil(ComparisonImage(bytes:input),"Returned plausible red-prefix success for \(name)")
            XCTAssertEqual(input,original);XCTAssertEqual(try bytes(name),original)
        }
    }
}
