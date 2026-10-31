// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

/// Independent full-canvas contracts for original WMF alpha and explicit paint.
/// No white test matte, canvas crop, source substitution or raster tolerance.
final class MetafileClassicGDIContractsTests:XCTestCase {
    private let corpus=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func bytes(_ name:String)throws->Data {try Data(contentsOf:corpus.appendingPathComponent(name))}
    private func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func pixels(_ name:String)throws->[UInt8] {
        let original=try bytes(name),image=try XCTUnwrap(ComparisonImage(bytes:original))
        XCTAssertEqual(image.pixels.width,64,name);XCTAssertEqual(image.pixels.height,64,name)
        var result=[UInt8](repeating:0,count:64*64*4)
        try result.withUnsafeMutableBytes {buffer in
            let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:64*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:64,height:64))
        }
        XCTAssertEqual(try bytes(name),original,"Rendering must preserve the entire original wire")
        return result
    }
    private func canvas(_ color:(Int,Int)->[UInt8])->[UInt8] {(0..<64).flatMap{y in (0..<64).flatMap{x in color(x,y)}}}
    private func inside(_ x:Double,_ y:Double,_ r:[Int])->Bool {x>=Double(r[0]) && y>=Double(r[1]) && x<Double(r[2]) && y<Double(r[3])}
    private let walls=[[8,8,56,10],[8,54,56,56],[8,10,10,54],[54,10,56,54],[30,10,34,54]]

    func testOriginalSourceHashesAndExactStatePreservingPATCOPYDerivations()throws {
        let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes("classic-gdi-contract-controls.json")) as? [String:Any])
        let originals=try XCTUnwrap(manifest["originals"] as? [String:String])
        XCTAssertEqual(originals.count,255)
        for (name,hash) in originals {XCTAssertEqual(digest(try bytes(name)),hash,name)}
        let controls=try XCTUnwrap(manifest["controls"] as? [[String:Any]]);XCTAssertEqual(controls.count,7)
        func u16(_ d:Data,_ p:Int)->Int {Int(d[p])|Int(d[p+1])<<8}
        func u32(_ d:Data,_ p:Int)->Int {u16(d,p)|u16(d,p+2)<<16}
        func word(_ v:Int)->Data {Data((0..<4).map{UInt8(truncatingIfNeeded:v>>($0*8))})}
        func short(_ v:Int)->Data {Data([UInt8(truncatingIfNeeded:v),UInt8(truncatingIfNeeded:v>>8)])}
        func record(_ kind:Int,_ body:Data=Data())->Data {word((body.count+6)/2)+short(kind)+body}
        let white=[record(0x1e),record(0x12d,short(0x8000)),record(0x61d,word(0x00f00021)+short(64)+short(64)+short(0)+short(0)),record(0x127,short(-1))]
        for item in controls {
            let source=try XCTUnwrap(item["source"] as? String),name=try XCTUnwrap(item["control"] as? String)
            let original=try bytes(source),control=try bytes(name)
            XCTAssertEqual(digest(original),item["source_sha256"] as? String,source)
            XCTAssertEqual(digest(control),item["control_sha256"] as? String,name)
            var output=[Data](),position=40,ordinal=0,replacements=[[Int]]()
            let sealed=name.contains("-sealed-")
            while position<original.count {
                let size=u32(original,position)*2,kind=u16(original,position+4)
                guard size>=6,position+size<=original.count else {throw NSError(domain:"Invalid original WMF framing",code:1)}
                var raw=original.subdata(in:position..<(position+size))
                if sealed && kind==0x41b {
                    let values=(0..<4).map{Int(Int16(bitPattern:UInt16(u16(raw,6+$0*2))))}
                    let rect=[values[3],values[2],values[1],values[0]]
                    if walls.contains(rect) {
                        replacements.append(rect)
                        raw=record(0x61d,word(0x00f00021)+short(rect[3]-rect[1])+short(rect[2]-rect[0])+short(rect[1])+short(rect[0]))
                    }
                }
                output.append(raw);ordinal += 1
                if ordinal==2 {output.append(contentsOf:white)}
                position += size
            }
            XCTAssertEqual(replacements,sealed ? walls:[],name)
            var expected=Data(original.prefix(40));output.forEach{expected.append($0)}
            expected.replaceSubrange(28..<32,with:word((expected.count-22)/2))
            expected.replaceSubrange(34..<38,with:word(try XCTUnwrap(output.map{$0.count/2}.max())))
            XCTAssertEqual(control,expected,"Only the four state-preserving white paint records, five named wall records and required header sizes may differ")
        }
    }

    func testFullWMFRegionFrameClipAndPatternBackgroundsRemainActualAlpha()throws {
        let red:[UInt8]=[255,0,0,255],blue:[UInt8]=[0,0,255,255],clear:[UInt8]=[0,0,0,0]
        func union(_ x:Double,_ y:Double)->Bool {inside(x,y,[8,8,32,24]) || inside(x,y,[8,24,56,56])}
        let fill=canvas{x,y in
            if self.inside(Double(x),Double(y),[48,0,63,5]) {return blue}
            return union(Double(x),Double(y)) ? red:clear
        }
        XCTAssertEqual(try pixels("wmf-classic-region-fill-preserve.wmf"),fill)
        let frame=canvas{x,y in
            if self.inside(Double(x),Double(y),[48,0,63,5]) {return blue}
            let cx=Double(x)+0.5,cy=Double(y)+0.5
            guard union(cx,cy) else{return clear}
            let eroded=[(-3.0,-5.0),(3.0,-5.0),(-3.0,5.0),(3.0,5.0)].allSatisfy{union(cx+$0.0,cy+$0.1)}
            return eroded ? clear:red
        }
        XCTAssertEqual(try pixels("wmf-classic-region-frame-union.wmf"),frame)
        let clipped=canvas{x,y in
            guard (8..<48).contains(x),(8..<48).contains(y) else{return clear}
            return x%8==(y%2==0 ? 0:1) ? blue:red
        }
        XCTAssertEqual(try pixels("wmf-classic-patternbrush-clip.wmf"),clipped)
        XCTAssertEqual(try pixels("wmf-classic-flood-clip.wmf"),canvas{x,y in (8..<24).contains(x) && (8..<24).contains(y) ? red:clear})
        XCTAssertEqual(try pixels("wmf-classic-region-select-empty.wmf"),[UInt8](repeating:0,count:64*64*4))
    }

    func testFullOriginalGappedFloodAndExplicitSealedControlsHaveDistinctConnectivity()throws {
        let black:[UInt8]=[0,0,0,255],blue:[UInt8]=[0,0,255,255],red:[UInt8]=[255,0,0,255],white:[UInt8]=[255,255,255,255]
        for kind in ["surface","border","legacy-border","hatch"] {
            let surface=kind=="surface" || kind=="hatch",hatch=kind=="hatch"
            for sealed in [false,true] {
                let filename="wmf-classic-flood-"+kind+(sealed ? "-sealed-white-patcopy-control.wmf":".wmf")
                // Original PS_NULL Rectangle records omit their final row and
                // column. The explicit PATCOPY controls paint the full walls.
                // Thus every nonblack original pixel is connected through the
                // row9/row53 gaps; only the left interior is connected when sealed.
                let expected=canvas{x,y in
                    if self.walls.contains(where:{r in self.inside(Double(x),Double(y),sealed ? r:[r[0],r[1],r[2]-1,r[3]-1])}) {return black}
                    let island=(20..<23).contains(x) && (20..<23).contains(y)
                    if surface && island {return blue}
                    let component = !sealed || ((10..<30).contains(x) && (10..<54).contains(y))
                    guard component else{return white}
                    return !hatch || x%8==0 || y%8==0 ? red:white
                }
                XCTAssertEqual(try pixels(filename),expected,"Every full-canvas RGBA pixel follows its actual recorded walls/brush/island: "+filename)
            }
        }
    }
}
