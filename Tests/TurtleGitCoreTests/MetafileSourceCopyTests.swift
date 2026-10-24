// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

/// Authored source records and independent RGBA/PNG color controls. Pixel
/// assertions describe bounded native display playback, not Windows certification.
final class MetafileSourceCopyTests:XCTestCase {
    private let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private var helper:URL?{ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_METAFILE_HELPER"].map{URL(fileURLWithPath:$0)}}
    private func data(_ name:String)throws->Data{try Data(contentsOf:directory.appendingPathComponent(name))}
    private func pixels(_ name:String)throws->[UInt8]{
        let original=try data(name),image:ComparisonImage
        if name.hasSuffix(".emf") {
            // Exercise production's original-byte path: feeding the converted
            // SVG back as an ordinary SVG selects high image reconstruction,
            // unlike the metafile/native compositor's device-pixel profile.
            let installed=try MetafileImageDecoder.executable()
            if let helper,helper.resolvingSymlinksInPath().standardizedFileURL != installed.resolvingSymlinksInPath().standardizedFileURL {
                XCTAssertEqual(try Data(contentsOf:installed),try Data(contentsOf:helper),"Production image path must use the explicitly selected helper artifact")
            }
            image=try XCTUnwrap(ComparisonImage(bytes:original),name)
        } else {image=try XCTUnwrap(ComparisonImage(bytes:original),name)}
        XCTAssertEqual(image.pixels.width,64,name);XCTAssertEqual(image.pixels.height,64,name)
        var result=[UInt8](repeating:0,count:64*64*4)
        try result.withUnsafeMutableBytes{storage in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:64,height:64))
        }
        XCTAssertEqual(try data(name),original,"Renderer rewrote encoded source")
        return result
    }
    private func sample(_ p:[UInt8],_ x:Int,_ y:Int)->[Int]{Array(p[(y*64+x)*4..<(y*64+x)*4+4]).map(Int.init)}
    private func pixel(_ p:[UInt8],_ x:Int,_ y:Int,_ expected:[Int],accuracy:Int=2,file:StaticString = #filePath,line:UInt = #line){
        let actual=sample(p,x,y)
        for channel in 0..<4{XCTAssertLessThanOrEqual(abs(actual[channel]-expected[channel]),accuracy,"RGBA \(x),\(y): \(actual), expected \(expected)",file:file,line:line)}
    }
    private func equivalent(_ a:[UInt8],_ b:[UInt8],_ message:String,accuracy:Int=2,file:StaticString = #filePath,line:UInt = #line){
        XCTAssertEqual(a.count,b.count,message,file:file,line:line)
        XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,accuracy,message,file:file,line:line)
    }
    func testTransparentSemiAndOpaqueSourceCopyReplaceAllChannelsAgainstLiteralPNGControls()throws{
        for mode in ["sourcecopy","sourceover"]{for kind in ["transparent","semi","opaque"]{
            equivalent(try pixels(mode+"-solid-"+kind+".emf"),try pixels(mode+"-solid-"+kind+"-control.png"),mode+" "+kind)
        }}
        let copy=try pixels("sourcecopy-solid-semi.emf"),over=try pixels("sourceover-solid-semi.emf")
        pixel(copy,32,32,[128,0,0,128]);pixel(over,32,32,[128,0,127,255]);pixel(copy,4,4,[0,0,255,255])
        equivalent(try pixels("sourcecopy-reserved-flags.emf"),try pixels("sourcecopy-solid-transparent.emf"),"High reserved mode flags are ignored")
    }
    func testEachOverlappingRectangleIsAnOrderedReplacementRatherThanFlattenedSourceOver()throws{
        let p=try pixels("sourcecopy-overlapping-rects.emf")
        for(x,y)in[(16,16),(32,32),(48,48)]{pixel(p,x,y,[128,0,0,128])}
        pixel(p,4,4,[0,0,255,255]);pixel(p,48,16,[0,0,255,255])
    }
    func testGradientHatchTextureAndImageCoverageIsIndependentOfSourceOpacity()throws{
        for kind in ["gradient","hatch","texture","image","image-affine"]{
            let copy=try pixels("sourcecopy-"+kind+".emf"),isolated=try pixels("sourcecopy-"+kind+"-isolated.emf"),over=try pixels("sourceover-"+kind+".emf")
            // The geometric rectangle replaces every interior pixel, including
            // transparent pattern/texture cells. Isolated paint retains the
            // same source alpha with no destination color to blend.
            for y in 12..<52{for x in 12..<52{for c in 0..<4{XCTAssertLessThanOrEqual(abs(Int(copy[(y*64+x)*4+c])-Int(isolated[(y*64+x)*4+c])),2,kind+" geometric coverage")};XCTAssertEqual(over[(y*64+x)*4+3],255,kind+" SourceOver opacity")}}
            pixel(copy,4,4,[0,0,255,255]);XCTAssertTrue(stride(from:3,to:copy.count,by:4).contains{copy[$0]<200},kind+" lost source alpha")
        }
        let image=try pixels("sourcecopy-image.emf")
        let control=try pixels("sourcecopy-image-control.png")
        // Interior clamped-texel points avoid asserting an unverified default
        // interpolation kernel at the boundary between source pixels.
        for(x,y)in[(14,14),(50,14),(14,50),(50,50),(4,4)]{pixel(image,x,y,sample(control,x,y))}
        pixel(image,14,14,[0,0,0,0]);pixel(image,50,14,[0,128,0,128]);pixel(image,50,50,[64,0,0,64])
    }
    func testTransparentPathRegionAndClipHolesPreserveDestinationOutsideActualGeometry()throws{
        for kind in ["path-hole","region-hole","path-clip"]{
            let p=try pixels("sourcecopy-"+kind+".emf")
            pixel(p,16,16,[0,0,0,0]);pixel(p,32,32,[0,0,255,255]);pixel(p,4,4,[0,0,255,255])
        }
        let p=try pixels("sourcecopy-clip-transform.emf")
        pixel(p,16,16,[0,0,0,0]);pixel(p,36,16,[0,0,255,255]);pixel(p,4,4,[0,0,255,255]);pixel(p,16,36,[0,0,255,255])
    }
    func testPenAndBothNativeGlyphPathsReplaceWithSourceAlphaOnlyOnInkCoverage()throws{
        let stroke=try pixels("sourcecopy-stroke.emf"),clear=try pixels("sourcecopy-stroke-transparent.emf")
        pixel(stroke,32,32,[128,0,0,128]);pixel(stroke,32,20,[0,0,255,255]);pixel(clear,32,32,[0,0,0,0])
        for kind in ["glyph","positioned-glyph"]{
            let copy=try pixels("sourcecopy-"+kind+".emf"),over=try pixels("sourceover-"+kind+".emf"),isolated=try pixels("sourcecopy-"+kind+"-isolated.emf")
            var ink=0,unchanged=0
            for i in stride(from:0,to:copy.count,by:4){
                if isolated[i+3]>=127{ink += 1;XCTAssertLessThanOrEqual(abs(Int(copy[i+3])-Int(isolated[i+3])),2);XCTAssertLessThanOrEqual(copy[i+2],2);XCTAssertEqual(over[i+3],255)}
                if isolated[i+3]==0 && copy[i+3]==255 && copy[i+2]==255{unchanged += 1}
            }
            XCTAssertGreaterThan(ink,15,kind+" emitted no actual native ink");XCTAssertGreaterThan(unchanged,1500,kind+" erased bounding box instead of ink")
        }
    }
    func testSaveContainersGetDCPreserveModeAndClearIgnoresCompositingMode()throws{
        let p=try pixels("sourcecopy-state.emf")
        pixel(p,16,16,[0,128,127,255]);pixel(p,48,16,[0,0,0,0]);pixel(p,16,48,[128,0,127,255]);pixel(p,48,48,[128,0,0,128])
        let dc=try pixels("sourcecopy-getdc.emf")
        pixel(dc,16,16,[0,0,0,0]);pixel(dc,48,16,[0,255,0,255]);pixel(dc,16,48,[0,0,0,0]);pixel(dc,48,48,[128,0,0,128])
        let clear=try pixels("sourcecopy-clear-mode0.emf")
        equivalent(clear,try pixels("sourcecopy-clear-mode1.emf"),"Graphics.Clear ignores compositing mode")
        pixel(clear,32,32,[128,0,0,128])
        pixel(try pixels("sourcecopy-clear-continuity0.emf"),16,16,[64,128,0,192])
        pixel(try pixels("sourcecopy-clear-continuity1.emf"),16,16,[0,128,0,128])
    }
    func testInvalidModesPaintAndClearTypeRefuseWholePrefixAndDoNotLeakState()throws{
        let names=["mode","mode-data","missing-brush","image-truncated","nonfinite-geometry","cleartype"]
        let before=try pixels("sourcecopy-solid-semi.emf")
        for name in names{let file="sourcecopy-refused-"+name+".emf",original=try data(file);XCTAssertThrowsError(try MetafileImageDecoder.convert(original,executable:helper),file);XCTAssertEqual(try data(file),original)}
        equivalent(try pixels("sourcecopy-solid-semi.emf"),before,"Refused conversion leaked compositing state")
        equivalent(try pixels("sourceover-solid-semi.emf"),try pixels("sourceover-solid-semi-control.png"),"SourceCopy leaked into subsequent conversion")
    }
}
