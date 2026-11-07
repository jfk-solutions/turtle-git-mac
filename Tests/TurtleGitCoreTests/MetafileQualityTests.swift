// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import ImageIO
import CryptoKit
@testable import TurtleGitCore

final class MetafileQualityTests: XCTestCase {
    private let folder = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/Quality")
    private func bytes(_ name:String)throws->Data {try Data(contentsOf:folder.appendingPathComponent(name))}
    private func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func pixels(_ image:CGImage)throws->[UInt8] {
        XCTAssertEqual(image.width,128);XCTAssertEqual(image.height,96)
        var result=[UInt8](repeating:0,count:128*96*4)
        try result.withUnsafeMutableBytes {buffer in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:128,height:96,bitsPerComponent:8,bytesPerRow:128*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image,in:CGRect(x:0,y:0,width:128,height:96))
        }
        return result
    }
    private func actual(_ name:String)throws->[UInt8] {
        let original=try bytes(name+".emf")
        let decoded=try XCTUnwrap(ComparisonImage(bytes:original),"Metafile conversion failed: "+name)
        XCTAssertEqual(try bytes(name+".emf"),original,"Decoder modified independent wire fixture")
        return try pixels(decoded.pixels)
    }
    private func expected(_ name:String)throws->[UInt8] {
        let source=try XCTUnwrap(CGImageSourceCreateWithData(try bytes(name+".windows.png") as CFData,nil))
        return try pixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil)))
    }
    private func compare(_ actual:[UInt8],_ expected:[UInt8],x:Range<Int>,y:Range<Int>,channels:[Int],name:String,excluding:CGRect?=nil,file:StaticString=#filePath,line:UInt=#line) {
        var mismatches=0,first=[String]()
        for row in y {for column in x {
            if let excluding,excluding.contains(CGPoint(x:column,y:row)) {continue}
            for channel in channels {
            let index=(row*128+column)*4+channel
            if actual[index] != expected[index] {
                mismatches += 1
                if first.count<8 {first.append("\(column),\(row),c\(channel):\(actual[index])!=\(expected[index])")}
            }
        }}}
        XCTAssertEqual(mismatches,0,name+": "+first.joined(separator:"; "),file:file,line:line)
    }
    func testWindowsFixtureIdentitiesAndIndependentNaturalCapture()throws {
        let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes("windows-reference.json")) as? [String:Any])
        XCTAssertEqual(manifest["source_run"] as? Int,41938727574)
        XCTAssertEqual(manifest["source_commit"] as? String,"d39b4ff42a0e5f9161ca6b4f40d0436c7400c19c")
        let cases=try XCTUnwrap(manifest["cases"] as? [[String:Any]]);XCTAssertEqual(cases.count,53)
        for item in cases {
            let name=try XCTUnwrap(item["name"] as? String)
            XCTAssertEqual(sha(try bytes(name+".emf")),item["wire_sha256"] as? String,name)
            XCTAssertEqual(sha(try bytes(name+".windows.png")),item["windows_png_sha256"] as? String,name)
            XCTAssertEqual(item["direct_rgba_sha256"] as? String,item["windows_rgba_sha256"] as? String,name)
            XCTAssertEqual(item["reserved_flag_pixel_differences"] as? Int,0,name)
        }
    }
    func testAllRecordedQualityModesMatchIndependentFillAndStrokeInteriorGrids()throws {
        for smoothing in 0...5 {for offset in 0...4 {
            let name="ordinary-s\(smoothing)-p\(offset)",rendered=try actual(name),windows=try expected(name)
            // Whole independent opaque control islands, including their edges.
            // Native curve/cap metrics are a separately retained port boundary.
            compare(rendered,windows,x:0..<61,y:34..<83,channels:[3],name:name+" wedge")
            compare(rendered,windows,x:46..<87,y:4..<32,channels:[3],name:name+" rectangles")
            compare(rendered,windows,x:4..<39,y:8..<26,channels:[3],name:name+" stroke bodies")
        }}
    }
    func testPixelOffsetBrushPlanesMatchIndependentWindowsColors()throws {
        for kind in ["linear","hatch","texture"] {
            var images=[[UInt8]]()
            for offset in [3,4] {
                let name="brush-\(kind)-p\(offset)",rendered=try actual(name),windows=try expected(name)
                compare(rendered,windows,x:5..<124,y:5..<92,channels:[0,1,2,3],name:name+" opaque plane")
                images.append(rendered)
            }
            let colorsDiffer=(5..<92).contains {row in (5..<124).contains {column in
                let start=(row*128+column)*4
                return (0..<3).contains {images[0][start+$0] != images[1][start+$0]}
            }}
            XCTAssertEqual(colorsDiffer,kind=="linear","Only the linear brush moves its color sampling lattice")
        }
    }
    func testAliasedStraightThinLinesMatchCapturedDevicePixelsIncludingEndpoints()throws {
        for smoothing in [0,1,3] {for offset in [0,1,3] {
            let name="ordinary-s\(smoothing)-p\(offset)",rendered=try actual(name),windows=try expected(name)
            compare(rendered,windows,x:4..<39,y:3..<32,channels:[0,1,2,3],name:name+" complete vertical lines")
            // The independently recorded ellipse is painted after the diagonal.
            // Its fill/curved outline is a separate profile; retain every other
            // diagonal sample, including both endpoints and surrounding canvas.
            compare(rendered,windows,x:61..<125,y:34..<74,channels:[0,1,2,3],name:name+" exposed complete diagonal",excluding:CGRect(x:64,y:53,width:27,height:26))
        }}
    }
    func testSourceCopyAntialiasedPaintReplacesDestinationRatherThanFadingIt()throws {
        for quality in 0...4 {
            let name="source-copy-compositing-quality-\(quality)",rendered=try actual(name),windows=try expected(name)
            compare(rendered,windows,x:9..<14,y:16..<25,channels:[0,1,2,3],name:name+" red edge over opaque background")
            compare(rendered,windows,x:14..<30,y:14..<25,channels:[0,1,2,3],name:name+" red interior")
            XCTAssertEqual(rendered[(20*128+10)*4+3],32,"Partial coverage must not retain opaque destination alpha")
        }
    }
    func testSavedAndContainerQualityStateUsesCapturedDefaultsAndRestoration()throws {
        for name in ["save-restore","container","rectangle-container"] {
            let rendered=try actual(name),windows=try expected(name)
            compare(rendered,windows,x:0..<28,y:15..<40,channels:[3],name:name+" outer antialiased wedge")
            if name=="container" {
                compare(rendered,windows,x:111..<125,y:4..<32,channels:[3],name:name+" default-quality entry marker")
            } else if name=="rectangle-container" {
                compare(rendered,windows,x:110..<124,y:0..<17,channels:[3],name:name+" default-quality entry marker")
            }
            compare(rendered,windows,x:12..<40,y:65..<90,channels:[3],name:name+" restored outer wedge")
        }
    }
    func testWorldAndDeviceClipKeepTheIndependentQualityLattice()throws {
        let affine=try actual("affine-transform"),affineWindows=try expected("affine-transform")
        compare(affine,affineWindows,x:14..<50,y:33..<66,channels:[3],name:"affine transformed wedge")
        let clipped=try actual("device-clip"),clipWindows=try expected("device-clip")
        compare(clipped,clipWindows,x:20..<61,y:40..<70,channels:[3],name:"clipped transformed interior")
        compare(clipped,clipWindows,x:0..<17,y:0..<96,channels:[3],name:"left of captured device clip")
        compare(clipped,clipWindows,x:105..<128,y:0..<96,channels:[3],name:"right of captured device clip")
    }
    func testSourceOverGammaAndQualityAliasesFollowIndependentWindowsControls()throws {
        var rendered=[[UInt8]]()
        for quality in 0...4 {
            let name="compositing-quality-\(quality)"
            let setters=try records(bytes(name+".emf")).filter {$0.type==0x4024}
            // The independent Windows default capture omits its setter. It must
            // enter the same integer composition path as explicit aliases1/4.
            XCTAssertEqual(setters.count,quality==0 ? 0:1,name+" captured setter identity")
            let image=try actual(name),windows=try expected(name)
            compare(image,windows,x:14..<30,y:14..<25,channels:[0,1,2,3],name:name+" isolated red")
            compare(image,windows,x:4..<6,y:4..<12,channels:[0,1,2,3],name:name+" transparent-destination background edge")
            rendered.append(image)
        }
        compare(rendered[0],rendered[1],x:0..<128,y:0..<96,channels:[0,1,2,3],name:"default and high-speed quality alias")
        compare(rendered[0],rendered[4],x:0..<128,y:0..<96,channels:[0,1,2,3],name:"default and assume-linear quality alias")
        compare(rendered[2],rendered[3],x:0..<128,y:0..<96,channels:[0,1,2,3],name:"high-quality and gamma quality alias")
        XCTAssertTrue(rendered[0] != rendered[2],"Gamma mode must differ from plain SourceOver")
    }
    private func records(_ input:Data)throws->[(outer:Int,offset:Int,type:Int,size:Int)] {
        let bytes=[UInt8](input)
        func word(_ p:Int)->Int {Int(bytes[p]) | Int(bytes[p+1])<<8}
        func dword(_ p:Int)->Int {word(p) | word(p+2)<<16}
        var result=[(outer:Int,offset:Int,type:Int,size:Int)](),outer=0
        while outer<bytes.count {
            guard outer+8<=bytes.count else {throw NSError(domain:"Quality wire",code:1)}
            let type=dword(outer),length=dword(outer+4)
            guard length>=8,length<=bytes.count-outer else {throw NSError(domain:"Quality wire",code:2)}
            if type==70,length>=16,dword(outer+8)>=4,dword(outer+12)==0x2b464d45 {
                var record=outer+16;let end=outer+12+dword(outer+8)
                while record<end {let size=dword(record+4);guard size>=12,size<=end-record else {throw NSError(domain:"Quality wire",code:3)};result.append((outer,record,word(record),size));record += size}
            }
            outer += length
        }
        return result
    }
    func testReservedQualityFlagBytesPreserveTheCapturedWindowsResult()throws {
        let name="compositing-quality-2",original=try bytes(name+".emf")
        var changed=original,count=0
        for record in try records(original) where [0x401e,0x4022,0x4024].contains(record.type) {changed[record.offset+3] = 255;count += 1}
        XCTAssertGreaterThan(count,0)
        let decoded=try XCTUnwrap(ComparisonImage(bytes:changed))
        compare(try pixels(decoded.pixels),try actual(name),x:0..<128,y:0..<96,channels:[0,1,2,3],name:"Windows ignores the measured reserved high flag byte")
    }
    func testInvalidQualityModesRefuseTheWholeConversion()throws {
        let original=try bytes("compositing-quality-2.emf")
        for (type,value) in [(0x401e,13),(0x4022,5),(0x4024,5)] {
            var changed=original
            let record=try XCTUnwrap(records(original).first {$0.type==type})
            changed[record.offset+2]=UInt8(value)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(changed),"Unsupported recorded quality must not publish a partial image")
            XCTAssertEqual(try bytes("compositing-quality-2.emf"),original)
        }
    }
    func testQualityRecordsWithUnexpectedBodiesRefuseTheWholeConversion()throws {
        let original=try bytes("compositing-quality-2.emf")
        func word(_ bytes:Data,_ at:Int)->UInt32 {(0..<4).reduce(0){$0 | UInt32(bytes[at+$1])<<($1*8)}}
        func write(_ value:UInt32,_ bytes:inout Data,_ at:Int) {for i in 0..<4 {bytes[at+i]=UInt8(truncatingIfNeeded:value>>(i*8))}}
        for type in [0x401e,0x4022,0x4024] {
            let record=try XCTUnwrap(records(original).first {$0.type==type})
            var changed=original
            // Keep the complete EMF/comment/EMF+ framing consistent. Only the
            // quality record's forbidden body is invalid, not a truncated file.
            write(word(original,48)+4,&changed,48)
            write(word(original,record.outer+4)+4,&changed,record.outer+4)
            write(word(original,record.outer+8)+4,&changed,record.outer+8)
            write(UInt32(record.size+4),&changed,record.offset+4)
            write(word(original,record.offset+8)+4,&changed,record.offset+8)
            changed.insert(contentsOf:[0,0,0,0],at:record.offset+record.size)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(changed),"Quality payload was accepted as a successful partial image")
        }
    }
}
