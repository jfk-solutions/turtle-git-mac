// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

/// Original compressed containers and independently serialized raw-pixel controls.
final class MetafileCompressedRasterTests:XCTestCase {
    private let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func original(_ name:String)throws->Data{try Data(contentsOf:directory.appendingPathComponent(name))}
    private func pixels(_ name:String)throws->[UInt8]{
        let bytes=try original(name),image=try XCTUnwrap(ComparisonImage(bytes:bytes),name)
        XCTAssertEqual(image.pixels.width,64,name);XCTAssertEqual(image.pixels.height,64,name)
        var rgba=[UInt8](repeating:0,count:64*64*4)
        try rgba.withUnsafeMutableBytes{storage in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:64,height:64))
        }
        XCTAssertEqual(try original(name),bytes,"Decode rewrote source")
        return rgba
    }
    private func sample(_ bytes:[UInt8],_ x:Int,_ y:Int)->[Int]{Array(bytes[(y*64+x)*4..<(y*64+x)*4+4]).map(Int.init)}
    private func equal(_ a:[UInt8],_ b:[UInt8],_ name:String,file:StaticString = #filePath,line:UInt = #line){
        XCTAssertEqual(a.count,b.count,name,file:file,line:line)
        XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,2,name,file:file,line:line)
    }
    private func pixel(_ bytes:[UInt8],_ x:Int,_ y:Int,_ expected:[Int],accuracy:Int=2,file:StaticString = #filePath,line:UInt = #line){
        let actual=sample(bytes,x,y)
        for i in 0..<4{XCTAssertLessThanOrEqual(abs(actual[i]-expected[i]),accuracy,"\(x),\(y) \(actual) != \(expected)",file:file,line:line)}
    }
    func testGIFDefaultDistinguishesAnimationFromUntimedStaticComposite()throws{
        let first=try pixels("compressed-raster-image-gif.emf")
        for suffix in ["delay10-noloop","delay0-loop","delay10-loop","delta-loop"]{
            equal(try pixels("compressed-raster-image-gif-two-frames-\(suffix).emf"),first,"GIF animation starts at first frame: \(suffix)")
        }
        let staticImage=try pixels("compressed-raster-image-gif-two-frames-visible.emf")
        pixel(staticImage,20,20,[0,0,255,255]);pixel(staticImage,44,44,[0,0,255,255]);pixel(staticImage,4,4,[255,255,255,255])
        let delta=try pixels("compressed-raster-image-gif-two-frames-delta-noloop.emf")
        // The final 8x8 transparent delta changes only odd checker positions;
        // prior source pixels survive both the delta holes and untouched canvas.
        pixel(delta,12,12,[255,0,0,255]);pixel(delta,15,12,[0,255,0,255])
        pixel(delta,44,20,[0,255,0,255]);pixel(delta,44,44,[255,255,0,255])
    }
    func testJPEGEXIFDoesNotInventAnImplicitOrientationTransform()throws{
        equal(try pixels("compressed-raster-image-exif-orientation6.emf"),try pixels("compressed-raster-image-jpeg.emf"),"GDI+ ignores EXIF orientation for serialized image playback")
    }
    func testTIFFSelectsFirstPageAndIgnoresOrientationMetadata()throws{
        let expected=try pixels("compressed-raster-image-tiff.emf")
        equal(try pixels("compressed-raster-image-ignored-metadata.emf"),expected,"Compressed bitmap dimensions/stride/pixel format are ignored metadata")
        equal(try pixels("compressed-raster-image-tiff-two-pages.emf"),expected,"Default TIFF page")
        equal(try pixels("compressed-raster-image-tiff-orientation6.emf"),expected,"TIFF orientation is metadata, not an implicit draw transform")
    }
    func testGIFAndTIFFImageTextureAndPenBrushMatchRawControls()throws{
        for name in ["gif","tiff","gif-alpha","tiff-alpha"]{
            let control=name.hasSuffix("-alpha") ? name:"opaque"
            for kind in ["image","texture","pen"]{
                equal(try pixels("compressed-raster-\(kind)-\(name).emf"),try pixels("compressed-raster-control-\(kind)-\(control).emf"),"\(kind) \(name)")
            }
        }
    }
    func testCompressedAlphaSourceCopyAndSourceOverUseIndependentRawRGBA()throws{
        for name in ["gif-alpha","tiff-alpha"]{for mode in ["copy","over"]{
            equal(try pixels("compressed-raster-alpha-\(name)-\(mode).emf"),try pixels("compressed-raster-control-\(name)-\(mode).emf"),"\(name) \(mode)")
        }}
        for name in ["gif-alpha","tiff-alpha"]{for kind in ["texture","pen"]{
            equal(try pixels("compressed-raster-\(kind)-\(name)-copy.emf"),try pixels("compressed-raster-control-\(kind)-\(name)-copy.emf"),"Compressed \(kind) SourceCopy \(name)")
        }}
        let copy=try pixels("compressed-raster-alpha-tiff-alpha-copy.emf")
        pixel(copy,44,20,[0,128,0,128]);pixel(copy,20,44,[0,0,0,0]);pixel(copy,4,4,[0,0,255,255])
    }
    func testCompressedImageCropAffineAndClipHaveIndependentInteriorColors()throws{
        for name in ["gif","tiff"]{
            let crop=try pixels("compressed-raster-crop-\(name).emf")
            pixel(crop,20,20,[0,255,0,255]);pixel(crop,20,44,[255,255,0,255])
            let affine=try pixels("compressed-raster-affine-\(name).emf")
            pixel(affine,20,20,[255,0,0,255]);pixel(affine,40,24,[0,255,0,255]);pixel(affine,48,4,[0,0,255,255])
            let clip=try pixels("compressed-raster-clip-\(name).emf")
            pixel(clip,20,20,[255,0,0,255]);pixel(clip,12,12,[0,0,255,255]);pixel(clip,44,44,[0,0,255,255])
        }
    }
    func testCompressedTextureWrapAndImageAttributesMatchExistingRawImageSemantics()throws{
        // Wrap0 is also independently covered by the complete raw texture control.
        equal(try pixels("compressed-raster-wrap-0.emf"),try pixels("compressed-raster-control-texture-tiff-alpha.emf"),"Tiled transparent TIFF")
        for wrap in 0...4{
            let texture=try pixels("compressed-raster-wrap-\(wrap).emf"),attributes=try pixels("compressed-raster-attributes-\(wrap).emf")
            equal(texture,try pixels("compressed-raster-control-wrap-\(wrap).emf"),"Texture wrap \(wrap)")
            equal(attributes,try pixels("compressed-raster-control-attributes-\(wrap).emf"),"Image attribute wrap \(wrap)")
        }
    }
    func testClassicJPEGAndPNGStretchedTransfersCropMirrorAndPreserveOpaqueColors()throws{
        for kind in ["png","jpeg"]{for ext in ["emf","wmf"]{
            let full=try pixels("compressed-raster-stretch-\(kind)-\(ext).\(ext)")
            let mirrored=try pixels("compressed-raster-stretch-mirror-\(kind)-\(ext).\(ext)")
            let crop=try pixels("compressed-raster-stretch-crop-\(kind)-\(ext).\(ext)")
            let tolerance=kind=="jpeg" ? 12:2
            pixel(full,20,20,[255,0,0,255],accuracy:tolerance);pixel(full,44,20,[0,255,0,255],accuracy:tolerance)
            pixel(mirrored,20,20,[0,255,0,255],accuracy:tolerance);pixel(mirrored,44,20,[255,0,0,255],accuracy:tolerance)
            pixel(crop,20,20,[0,255,0,255],accuracy:tolerance);pixel(crop,20,44,[255,255,0,255],accuracy:tolerance)
        }}
    }
    func testClassicCompressedPNGUsesRGBRatherThanImageAlpha()throws{
        equal(try pixels("compressed-raster-stretch-png-alpha-emf.emf"),try pixels("compressed-raster-stretch-png-emf.emf"),"Classic compressed RGB ignores alpha without flattening")
    }
    func testClassicCompressedTransfersRetainAffinePlacementAndDCClip()throws{
        for kind in ["png","jpeg"]{
            let affine=try pixels("compressed-raster-stretch-affine-\(kind).emf"),clip=try pixels("compressed-raster-stretch-clip-\(kind).emf")
            let tolerance=kind=="jpeg" ? 12:2
            pixel(affine,20,20,[255,0,0,255],accuracy:tolerance);pixel(affine,44,24,[0,255,0,255],accuracy:tolerance)
            pixel(clip,20,20,[255,0,0,255],accuracy:tolerance);pixel(clip,12,12,[255,255,255,255]);pixel(clip,44,44,[255,255,255,255])
        }
    }
    func testPrecancelledCompressedConversionDoesNotLaunchOrModifyInputs()throws{
        let bytes=try original("compressed-raster-image-gif.emf"),token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes,cancellation:token)){XCTAssertTrue($0 is OperationCancellationFailure)}
        XCTAssertEqual(try original("compressed-raster-image-gif.emf"),bytes)
    }
    func testMalformedCompressedContainersAndInvalidClassicOperationsRefuseWholeImage()throws{
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("refused-compressed-raster-") && $0.hasSuffix(".emf")}
        XCTAssertEqual(names.count,21)
        for name in names{
            let bytes=try original(name)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes)){error in
                guard case MetafileImageFailure.failed(let message)=error else{return XCTFail("Must reject decoding, not accept runtime/deadline failure: \(name): \(error)")}
                if name.contains("aggregate"){XCTAssertTrue(message.contains("Metafile bitmap expansion budget exceeded"),message)}
            }
            XCTAssertEqual(try original(name),bytes)
        }
    }
}
