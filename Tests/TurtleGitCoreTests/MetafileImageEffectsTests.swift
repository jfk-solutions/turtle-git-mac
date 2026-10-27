// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafileImageEffectsTests:XCTestCase {
    struct Sample:Decodable {let x:Int,y:Int,rgba:[Int],tolerance:Int}
    struct Case:Decodable {let file:String,sourceSHA256:String;let width:Int,height:Int;let samples:[Sample]}
    struct Refusal:Decodable {let file:String,sourceSHA256:String}
    struct Reference:Decodable {let windowsRun:Int;let cases:[Case],refusals:[Refusal]}
    private let folder=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/ImageEffects")
    private func reference()throws->Reference {try JSONDecoder().decode(Reference.self,from:Data(contentsOf:folder.appendingPathComponent("windows-reference.json")))}
    private func source(_ file:String,_ hash:String)throws->Data {let bytes=try Data(contentsOf:folder.appendingPathComponent(file));XCTAssertEqual(SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),hash,file);return bytes}
    private func check(_ item:Case)throws {
        let wire=try source(item.file,item.sourceSHA256)
        let image=try XCTUnwrap(ComparisonImage(bytes:wire),item.file)
        XCTAssertEqual(image.pixels.width,item.width,item.file);XCTAssertEqual(image.pixels.height,item.height,item.file)
        var rgba=[UInt8](repeating:0,count:image.pixels.width*image.pixels.height*4)
        try rgba.withUnsafeMutableBytes {storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:image.pixels.width,height:image.pixels.height,bitsPerComponent:8,bytesPerRow:image.pixels.width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:image.pixels.width,height:image.pixels.height))
        }
        XCTAssertFalse(item.samples.isEmpty)
        for sample in item.samples {
            let offset=(sample.y*image.pixels.width+sample.x)*4
            let expected=sample.rgba.enumerated().map {channel,value in channel==3 ? value:Int((Double(value*sample.rgba[3])/255).rounded())}
            for channel in 0..<4 {XCTAssertLessThanOrEqual(abs(Int(rgba[offset+channel])-expected[channel]),sample.tolerance,"\(item.file) (\(sample.x),\(sample.y)) channel\(channel)")}
        }
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),wire,"Rendering changed original EMF")
    }
    func testImageEffectsRecordedWindowsStateAndActualPixels()throws {
        let reference=try reference();XCTAssertEqual(reference.windowsRun,40491928071)
        let cases=reference.cases.filter{!$0.file.hasPrefix("brightness-") && !$0.file.hasPrefix("fallback-")};XCTAssertEqual(cases.count,9)
        for item in cases {try check(item)}
    }
    func testImageEffectsBrightnessContrastUsesIndependentNativeRamps()throws {
        let cases=try reference().cases.filter{$0.file.hasPrefix("brightness-")};XCTAssertEqual(cases.count,6)
        for item in cases {try check(item)}
    }
    func testImageEffectsFallback16BitPNGPreservesAsymmetricRowsAndNamedSRGB()throws {
        let cases=try reference().cases.filter{$0.file.hasPrefix("fallback-")};XCTAssertEqual(cases.count,2)
        for item in cases {try check(item)}
    }
    func testImageEffectsMalformedProfilesRefuseWholeConversionAndPreserveBytes()throws {
        let refusals=try reference().refusals;XCTAssertEqual(refusals.count,10)
        for item in refusals {let bytes=try source(item.file,item.sourceSHA256);XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes),item.file);XCTAssertNil(ComparisonImage(bytes:bytes),item.file);XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),bytes)}
    }
}
