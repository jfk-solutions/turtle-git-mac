// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

/// Original literal EMF+ records, independent RGBA arithmetic controls. The
/// retained Windows image-effect captures separately supply native observations.
final class MetafileInitialAlphaTests:XCTestCase {
    private func words(_ values:[UInt32])->Data {
        Data(values.flatMap {value in (0..<4).map {UInt8(truncatingIfNeeded:value >> ($0*8))}})
    }
    private func record(_ type:UInt32,_ body:Data)->Data {words([type,UInt32(body.count+8)])+body}
    private func plus(_ type:UInt32,_ body:Data=Data(),flags:UInt32=0)->Data {
        words([type|(flags<<16),UInt32(body.count+12),UInt32(body.count)])+body
    }
    private func comment(_ records:[Data])->Data {
        let stream=records.reduce(Data(),+),body=Data("EMF+".utf8)+stream
        return record(70,words([UInt32(body.count)])+body)
    }
    private func fill(_ color:UInt32)->Data {
        plus(0x400a,words([color,1]+[Float(16),16,32,32].map(\.bitPattern)),flags:0x8000)
    }
    private func image(_ actions:[Data],dual:Bool=false,mixed:[Data]?=nil)throws->([UInt8],Data) {
        let header=plus(0x4001,words([0xdbc01002,dual ? 1:0,96,96]),flags:dual ? 1:0)
        let body=(mixed.map {[comment([header]+actions)]+$0+[comment([plus(0x4002)])]} ?? [comment([header]+actions+[plus(0x4002)])])+[record(14,words([0,0,20]))]
        let file=words([1,88,0,0,64,64,0,0,1693,1693,0x464d4520,0x10000,UInt32(88+body.reduce(0){$0+$1.count}),UInt32(body.count+1),32,0,0,0,960,960,254,254])+body.reduce(Data(),+)
        return (try rgba(file,width:65,height:65),file)
    }
    private func rgba(_ file:Data,width:Int,height:Int)throws->[UInt8] {
        let original=file,image=try XCTUnwrap(ComparisonImage(bytes:file))
        XCTAssertEqual(image.pixels.width,width);XCTAssertEqual(image.pixels.height,height)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes {storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        XCTAssertEqual(file,original)
        return bytes
    }
    private func pixel(_ bytes:[UInt8],_ x:Int,_ y:Int)->[Int] {Array(bytes[((y*65+x)*4)..<((y*65+x)*4+4)]).map(Int.init)}
    func testUnpaintedOnlyAndDualStreamsRetainTransparentAllocationThroughStateChanges()throws {
        for dual in [false,true] {
            let blank=try image([],dual:dual).0
            XCTAssertTrue(blank.allSatisfy {$0==0},"Unpainted file-backed EMF+ must not acquire a white matte")
            let state=try image([plus(0x4025,words([7])),plus(0x4023,flags:1),plus(0x4026,words([7]))],dual:dual).0
            XCTAssertEqual(state,blank,"Graphics-state records cannot paint")
        }
    }
    func testSourceOverAndSourceCopyOnEmptyCanvasPreserveLiteralSourceAlpha()throws {
        for dual in [false,true] {for mode in [UInt32(0),1] {
            let bytes=try image([plus(0x4023,flags:mode),fill(0x80ff0000)],dual:dual).0
            XCTAssertEqual(pixel(bytes,32,32),[128,0,0,128])
            for (x,y) in [(4,4),(60,60),(64,64)] {XCTAssertEqual(pixel(bytes,x,y),[0,0,0,0])}
        }}
    }
    func testExplicitClearOwnsWholeCanvasRegardlessOfCompositingMode()throws {
        for mode in [UInt32(0),1] {
            let white=try image([fill(0x80ff0000),plus(0x4023,flags:mode),plus(0x4009,words([0xffffffff]))]).0
            XCTAssertTrue(white.allSatisfy {$0==255},"Recorded Clear must still cover the full natural canvas")
            let empty=try image([fill(0xffff0000),plus(0x4023,flags:mode),plus(0x4009,words([0]))]).0
            XCTAssertTrue(empty.allSatisfy {$0==0},"Recorded transparent Clear must erase previous paint")
            let semi=try image([plus(0x4023,flags:mode),plus(0x4009,words([0x80ff0000]))]).0
            for (x,y) in [(4,4),(32,32),(64,64)] {XCTAssertEqual(pixel(semi,x,y),[128,0,0,128])}
        }
    }
    func testDualGetDCAddsOnlyActualGDIPaintAndReturnsToTransparentPlusState()throws {
        let gdi=[record(39,words([1,0,0x0000ff00,0])),record(37,words([1])),record(43,words([16,16,48,48])),comment([plus(0x400a,words([0x800000ff,1]+[Float(0),0,8,8].map(\.bitPattern)),flags:0x8000)])]
        let bytes=try image([plus(0x4004)],dual:true,mixed:gdi).0
        XCTAssertEqual(pixel(bytes,32,32),[0,255,0,255])
        XCTAssertEqual(pixel(bytes,4,4),[0,0,128,128])
        XCTAssertEqual(pixel(bytes,60,60),[0,0,0,0])
    }
    func testFullRetainedWindowsEffectPicturesPreserveUnpaintedAndPaintedAlpha()throws {
        struct Windows:Decodable {let file:String,sha256:String}
        struct Item:Decodable {let file:String,sourceSHA256:String,width:Int,height:Int,windowsRGBA:Windows?}
        struct References:Decodable {let cases:[Item]}
        let folder=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/ImageEffects")
        let references=try JSONDecoder().decode(References.self,from:Data(contentsOf:folder.appendingPathComponent("windows-reference.json")))
        let originals=references.cases.filter {$0.windowsRGBA != nil}
        XCTAssertEqual(originals.count,9)
        func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()}
        var corpusPartial=0,corpusOpaque=0
        for item in originals {
            let witness=try XCTUnwrap(item.windowsRGBA)
            let source=try Data(contentsOf:folder.appendingPathComponent(item.file))
            let native=try Data(contentsOf:folder.appendingPathComponent(witness.file))
            XCTAssertEqual(hash(source),item.sourceSHA256);XCTAssertEqual(hash(native),witness.sha256)
            XCTAssertEqual(native.count,item.width*item.height*4)
            let actual=try rgba(source,width:item.width,height:item.height),observed=Array(native)
            var wrong=0,examples:[String]=[],transparent=0,partial=0,opaque=0
            for offset in stride(from:0,to:actual.count,by:4) {
                let alpha=Int(observed[offset+3])
                if alpha==0 {transparent+=1}else if alpha==255 {opaque+=1}else {partial+=1}
                let expected=(0..<4).map {c in c==3 ? alpha:Int((Double(Int(observed[offset+c])*alpha)/255).rounded())}
                let mismatch=(0..<4).contains {c in abs(Int(actual[offset+c])-expected[c])>3} || (alpha==0 && actual[offset+3] != 0)
                if mismatch {
                    wrong+=1
                    if examples.count<12 {examples.append("\(offset/4%item.width),\(offset/4/item.width): \(Array(actual[offset..<offset+4])) expected \(expected)")}
                }
            }
            XCTAssertGreaterThan(transparent,100,item.file)
            XCTAssertGreaterThan(opaque+partial,100,item.file)
            corpusPartial+=partial;corpusOpaque+=opaque
            XCTAssertEqual(wrong,0,item.file+": "+examples.joined(separator:"; "))
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),source)
        }
        XCTAssertGreaterThan(corpusPartial,100);XCTAssertGreaterThan(corpusOpaque,100)
    }

}
