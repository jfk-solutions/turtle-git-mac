// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

/// Authored source records and independent RGBA/PNG color controls. Pixel
/// assertions describe bounded native display playback, not Windows certification.
final class MetafileEmbeddedImageTests:XCTestCase {
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
    func testAllEmbeddedMetafileKindsUseLivePlaybackAgainstLiteralPNG()throws{
        let control=try pixels("embedded-image-control.png")
        for kind in ["wmf","placeable","emf","plus-only","plus-dual"]{
            let p=try pixels("embedded-image-"+kind+".emf")
            // Sample away from classic rectangle boundary rounding, while the
            // independently authored PNG defines both ink and unpainted holes.
            for(x,y)in[(4,4),(16,16),(16,32),(28,16),(32,32),(44,44)]{pixel(p,x,y,sample(control,x,y))}
        }
        for kind in 1...5{
            let p=try pixels("embedded-image-crop-\(kind).emf")
            pixel(p,12,16,[255,0,0,255]);pixel(p,28,16,[0,255,0,255])
            pixel(p,28,32,[0,0,255,255]);pixel(p,4,4,[0,0,255,255])
        }
    }
    func testRecursiveRepeatedAffineAndDeviceClipKeepIndependentChildState()throws{
        equivalent(try pixels("embedded-image-recursive.emf"),try pixels("embedded-image-plus-only.emf"),"Nested image placement")
        let repeated=try pixels("embedded-image-repeated.emf")
        pixel(repeated,8,8,[255,0,0,255]);pixel(repeated,40,40,[255,0,0,255]);pixel(repeated,40,8,[0,0,255,255])
        let affine=try pixels("embedded-image-affine.emf")
        // Child(5,5) -> (20.5,23); child(11,5) -> (32.5,26).
        pixel(affine,20,23,[255,0,0,255]);pixel(affine,32,26,[0,255,0,255]);pixel(affine,52,52,[0,0,255,255])
        let clipped=try pixels("embedded-image-world-clip.emf")
        pixel(clipped,16,16,[0,0,255,255]);pixel(clipped,32,23,[255,0,0,255]);pixel(clipped,44,23,[0,0,255,255])
    }
    func testDirectMetafileAttributesAreValidatedButDoNotTileOrClampVectorPlayback()throws{
        let baseline=try pixels("embedded-image-attributes-noattrs.emf")
        for wrap in 0...4{equivalent(try pixels("embedded-image-attributes-\(wrap).emf"),baseline,"Windows direct vector wrap/clamp is ignored")}
        equivalent(try pixels("embedded-image-attributes-clamp-ignored.emf"),baseline,"Clamp BOOL is ignored in GDI+ 1.0")
        pixel(baseline,25,25,[255,0,0,255]);pixel(baseline,35,25,[0,255,0,255]);pixel(baseline,13,13,[0,0,255,255])
    }
    func testClassicGlyphAxesAndRoundClipKeepFullParentAffine()throws{
        equivalent(try pixels("embedded-image-classic-text-affine.emf"),try pixels("embedded-image-classic-text-affine-control.emf"),"Classic glyph origin and axes must both receive parent placement")
        let glyphs=try pixels("embedded-image-classic-text-affine.emf")
        XCTAssertGreaterThan(stride(from:0,to:glyphs.count,by:4).filter{glyphs[$0]>20}.count,5,"Affine text control cannot be an empty image")
        let control=try pixels("embedded-image-plus-affine-control.emf")
        for kind in ["wmf","emf"]{
            let value=try pixels("embedded-image-"+kind+"-affine.emf")
            for(x,y)in[(20,20),(34,24),(34,34),(4,4)]{pixel(value,x,y,sample(control,x,y))}
        }
        let round=try pixels("embedded-image-wmf-round-clip-affine.emf")
        pixel(round,24,27,[255,0,0,255]);pixel(round,36,30,[0,0,255,255]);pixel(round,12,35,[0,0,255,255])
        let large=try pixels("embedded-image-wmf-large-clip.emf")
        pixel(large,26,26,[255,0,0,255]);pixel(large,16,16,[0,0,255,255]);pixel(large,35,35,[0,0,255,255])
        let bracket=try pixels("embedded-image-classic-bracket-affine.emf")
        pixel(bracket,20,20,[0,255,0,255]);pixel(bracket,37,36,[0,255,0,255]);pixel(bracket,30,30,[0,0,255,255])
    }
    func testEveryMetafileTextureKindAndWrapMatchesIndependentRawBitmap()throws{
        let control=try pixels("embedded-texture-wrap-0-control.emf")
        for kind in 1...5{
            let p=try pixels("embedded-texture-\(kind).emf")
            // Classic vector raster edges can differ at the outline itself;
            // compare interior cells and untouched transparent texture holes.
            for(x,y)in[(16,16),(28,16),(32,32),(48,48),(4,4)]{pixel(p,x,y,sample(control,x,y))}
        }
        for wrap in 0...4{equivalent(try pixels("embedded-texture-wrap-\(wrap).emf"),try pixels("embedded-texture-wrap-\(wrap)-control.emf"),"Metafile/raw texture wrap \(wrap)")}
    }
    func testMetafileTexturePensGlyphsAndSourceCopyUseTransparentOwnedSurface()throws{
        for kind in ["stroke","glyph","copy"]{
            let a=try pixels("embedded-texture-"+kind+".emf"),b=try pixels("embedded-texture-"+kind+"-control.emf")
            equivalent(a,b,"Embedded texture consumer "+kind)
            XCTAssertGreaterThan(stride(from:0,to:a.count,by:4).filter{a[$0] != 0 || a[$0+1] != 0 || a[$0+2] != 255 || a[$0+3] != 255}.count,15,"Texture consumer emitted no actual painted pixels: "+kind)
        }
        let copy=try pixels("embedded-texture-copy.emf")
        pixel(copy,16,16,[255,0,0,255]);pixel(copy,32,32,[0,0,0,0]);pixel(copy,4,4,[0,0,255,255])
    }
    func testDirectPlaybackStartsSourceOverWithoutErasingUnpaintedViewport()throws{
        for(kind,color)in[("inherit",[128,0,127,255]),("over",[128,0,127,255]),("copy",[0,0,0,0])]{
            let p=try pixels("embedded-compositing-"+kind+".emf")
            pixel(p,24,24,color);pixel(p,9,9,[0,0,255,255]);pixel(p,4,4,[0,0,255,255])
        }
        let p=try pixels("embedded-parent-state.emf")
        pixel(p,24,24,[128,0,127,255]);pixel(p,48,16,[0,128,0,128])
    }
    func testDestinationDependentROPChildClearAndIsolatedCheckpointRestoration()throws{
        let rop=try pixels("embedded-image-destination-rop.emf")
        pixel(rop,24,24,[255,255,0,255]);pixel(rop,9,9,[0,0,255,255])
        let clear=try pixels("embedded-child-clear.emf")
        pixel(clear,24,24,[0,0,0,0]);pixel(clear,4,4,[0,0,255,255]);pixel(clear,44,44,[0,0,255,255])
        let scope=try pixels("embedded-checkpoint-scopes.emf")
        pixel(scope,4,4,[128,0,0,128]);pixel(scope,24,24,[0,0,0,0]);pixel(scope,60,60,[0,128,0,128]);pixel(scope,4,40,[0,0,255,255])
    }
    func testMalformedNestedImagesFailWholePictureWithBoundedRecursionAndCancellation()throws{
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("embedded-refused-") && $0.hasSuffix(".emf")}.sorted()
        XCTAssertEqual(names.count,15)
        for name in names{
            let original=try data(name)
            do{_ = try MetafileImageDecoder.convert(original,executable:helper);XCTFail("Accepted "+name)}
            catch{
                if name.contains("recursion") || name.contains("playback-count"){
                    guard case MetafileImageFailure.failed(let diagnostic)=error else{XCTFail("Budget must fail explicitly, not time out: \(error)");continue}
                    XCTAssertTrue(diagnostic.contains(name.contains("recursion") ? "embedded metafile recursion budget exceeded":"embedded metafile image count budget exceeded"),diagnostic)
                }
            }
            XCTAssertEqual(try data(name),original)
        }
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try MetafileImageDecoder.convert(data("embedded-image-plus-only.emf"),executable:helper,cancellation:token)) {XCTAssertTrue($0 is OperationCancellationFailure)}
        equivalent(try pixels("embedded-image-plus-only.emf"),try pixels("embedded-image-control.png"),"Rejected child leaked render state")
    }
}
