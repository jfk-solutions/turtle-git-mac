// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

/// Independent original scenes exercise the production universal decoder. The
/// existing exhaustive ROP2/ROP3 truth matrices retain their ordinary 15s limit.
final class MetafileRasterROITests: XCTestCase {
    private let directory = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func painting(_ name:String)throws->[UInt8] {
        let file=directory.appendingPathComponent(name),original=try Data(contentsOf:file)
        let helper=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_METAFILE_HELPER"].map{URL(fileURLWithPath:$0)}
        let svg=try XCTUnwrap(MetafileImageDecoder.convert(original,executable:helper))
        let image=try XCTUnwrap(ComparisonImage(bytes:svg),name)
        let naturalExtent = name.hasSuffix(".emf") ? 65 : 64
        XCTAssertEqual(image.pixels.width,naturalExtent,name);XCTAssertEqual(image.pixels.height,naturalExtent,name)
        // Preserve the independent 64x64 playback samples without rescaling the
        // inclusive natural EMF canvas measured with Windows Bitmap(filename,FALSE).
        let playback = try XCTUnwrap(image.pixels.cropping(to:CGRect(x:0,y:0,width:64,height:64)))
        var bytes=[UInt8](repeating:0,count:64*64*4)
        try bytes.withUnsafeMutableBytes { storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(playback,in:CGRect(x:0,y:0,width:64,height:64))
        }
        XCTAssertEqual(try Data(contentsOf:file),original)
        return bytes
    }
    private func gray(_ pixels:[UInt8],_ samples:[(Int,Int,Int)],file:StaticString = #filePath,line:UInt = #line) {
        for(x,y,value)in samples {
            let actual=(0..<4).map{Int(pixels[(y*64+x)*4+$0])},expected=[value,value,value,255]
            XCTAssertTrue(zip(actual,expected).allSatisfy{abs($0.0-$0.1)<=1},"(\(x),\(y)): \(actual), expected \(expected)",file:file,line:line)
        }
    }
    func testFourCornerAffineROIMirroredCropAndAsymmetricY()throws {
        gray(try painting("classic-roi-affine-crop.emf"),[(30,14,192),(34,26,64),(20,10,170),(44,26,170)])
        gray(try painting("classic-roi-asymmetric-y.emf"),[(44,46,64),(44,53,192),(44,12,170),(6,9,102),(6,55,170)])
    }
    func testCheckpointInvalidatedByVectorAndFullViewportPaint()throws {
        gray(try painting("classic-roi-checkpoint-interleave.emf"),[(12,12,102),(36,12,236),(12,44,85),(52,44,153),(52,12,170)])
        gray(try painting("classic-roi-pen-fallback.emf"),[(12,12,102),(24,32,102),(24,40,170),(4,4,170)])
    }
    func testSavedPatternClipAndDevicePhaseSurviveSnapshots()throws {
        gray(try painting("classic-roi-saved-pattern.emf"),[(10,10,255),(11,10,0),(4,4,170),(16,16,255),(36,12,170),(42,42,255),(43,42,0),(10,42,255),(11,42,0)])
        // Existing authored offset/repeating mask exercises global device mask
        // phase through a parallelogram and a restored clip, without a new oracle.
        let mask=try painting("classic-plgblt-mask-shear.emf")
        for(x,y,expected)in [(14,24,[255,0,0,255]),(18,25,[0,0,255,255]),(34,28,[0,0,255,255]),(52,12,[0,255,0,255])] {
            let actual=(0..<4).map{Int(mask[(y*64+x)*4+$0])}
            for channel in 0..<3 {XCTAssertEqual(Double(actual[channel]),Double(expected[channel]),accuracy:1,"Device mask/clip at \(x),\(y): \(actual)")}
            XCTAssertEqual(actual[3],expected[3],"Device mask alpha at \(x),\(y)")
        }
    }
    func testOffcanvasValidationNOPAndConversionIsolation()throws {
        let name="classic-roi-checkpoint-interleave.emf",first=try painting(name)
        gray(try painting("classic-roi-offcanvas.emf"),[(4,4,170),(62,62,102),(62,4,170)])
        // GDI initializes an opaque white DC; DSTCOPY retains exact destination.
        gray(try painting("classic-roi-alpha-nop.emf"),[(12,12,64),(4,4,255),(40,40,255)])
        XCTAssertEqual(try painting(name),first,"A later conversion reused another conversion's checkpoint")
        let helper=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_METAFILE_HELPER"].map{URL(fileURLWithPath:$0)}
        for invalid in ["unsupported-roi-offcanvas-payload.emf","unsupported-raster-device-pixel-budget.emf"] {
            let bytes=try Data(contentsOf:directory.appendingPathComponent(invalid))
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes,executable:helper),invalid)
        }
    }
}
