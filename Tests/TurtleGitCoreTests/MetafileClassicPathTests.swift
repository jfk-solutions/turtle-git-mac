// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafileClassicPathTests:XCTestCase {
    private let corpus=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/ClassicPaths")
    private struct Manifest:Decodable {
        struct File:Decodable {let file:String,sha256:String;let bytes:Int;let refused:Bool?}
        struct Pair:Decodable {let subject:String,control:String}
        let files:[File],pairs:[Pair]
    }
    private func manifest()throws->Manifest {try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:corpus.appendingPathComponent("manifest.json")))}
    private func pixels(_ name:String)throws->[UInt8] {
        let url=corpus.appendingPathComponent(name),original=try Data(contentsOf:url)
        let image=try XCTUnwrap(ComparisonImage(bytes:original),name)
        XCTAssertEqual(image.pixels.width,65,name);XCTAssertEqual(image.pixels.height,65,name)
        var result=[UInt8](repeating:0,count:65*65*4)
        try result.withUnsafeMutableBytes {buffer in
            let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:65,height:65,bitsPerComponent:8,bytesPerRow:65*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:65,height:65))
        }
        XCTAssertEqual(try Data(contentsOf:url),original,"Classic path conversion must preserve complete original bytes")
        return result
    }
    private func color(_ pixels:[UInt8],_ x:Int,_ y:Int,_ expected:[UInt8],accuracy:Int=1,file:StaticString=#filePath,line:UInt=#line) {
        let offset=(y*65+x)*4
        for channel in 0..<4 {XCTAssertLessThanOrEqual(abs(Int(pixels[offset+channel])-Int(expected[channel])),accuracy,"at \(x),\(y) channel\(channel)",file:file,line:line)}
    }
    private func pairs(prefix:String,tolerance:Int=0)throws {
        for pair in try manifest().pairs where pair.subject.hasPrefix(prefix) {
            let a=try pixels(pair.subject),b=try pixels(pair.control)
            XCTAssertEqual(a.count,b.count)
            let differences=zip(a,b).map{abs(Int($0)-Int($1))}
            XCTAssertLessThanOrEqual(differences.max() ?? 0,tolerance,"Complete independently encoded path controls differ: "+pair.subject)
        }
    }
    private func verifyAnalyticFlattenGeometry()throws {
        let source=try Data(contentsOf:corpus.appendingPathComponent("flatten-cubic-stroke.emf"))
        let output=try XCTUnwrap(MetafileImageDecoder.convert(source)),svg=try XCTUnwrap(String(data:output,encoding:.utf8))
        let pattern=try NSRegularExpression(pattern:#"<path d="([^"]+)" fill="none" stroke="[^"]+""#)
        let matches=pattern.matches(in:svg,range:NSRange(svg.startIndex...,in:svg))
        XCTAssertEqual(matches.count,1,"Flatten must retain exactly one unpainted selected curve until its single StrokePath")
        guard let match=matches.first,let range=Range(match.range(at:1),in:svg)else{return}
        let fields=svg[range].split(separator:" ")
        XCTAssertEqual(fields.count%3,0,"Flatten must serialize only complete M/L point commands")
        guard fields.count%3==0 else{return}
        var points:[CGPoint]=[]
        for i in stride(from:0,to:fields.count,by:3) {
            XCTAssertEqual(fields[i],i==0 ? "M":"L","Open cubic must stay open and contain no curve commands")
            let x=try XCTUnwrap(Double(fields[i+1])),y=try XCTUnwrap(Double(fields[i+2]))
            XCTAssertTrue(x>=8 && x<=56 && y>=16 && y<=40,"Flatten escaped the authored cubic extent")
            points.append(.init(x:x,y:y))
        }
        XCTAssertGreaterThan(points.count,2);XCTAssertLessThanOrEqual(points.count,131072)
        let first=try XCTUnwrap(points.first),last=try XCTUnwrap(points.last)
        XCTAssertEqual(first,CGPoint(x:8,y:40));XCTAssertEqual(last,CGPoint(x:56,y:40))
        func curve(_ t:Double)->CGPoint {.init(x:8+24*t+72*t*t-48*t*t*t,y:40-96*t+96*t*t)}
        func derivative(_ t:Double)->CGPoint {.init(x:24+144*t-144*t*t,y:-96+192*t)}
        func parameter(_ x:CGFloat)->Double {
            var lo=0.0,hi=1.0
            for _ in 0..<60 {let mid=(lo+hi)/2;if curve(mid).x<x {lo=mid}else{hi=mid}}
            return(lo+hi)/2
        }
        guard points.count>1 else{return}
        var hullBound=0.0
        for i in 0..<(points.count-1) {
            let a=points[i],b=points[i+1],t0=parameter(a.x),t1=parameter(b.x),dt=CGFloat(t1-t0),c0=curve(t0),c1=curve(t1),d0=derivative(t0),d1=derivative(t1)
            XCTAssertGreaterThan(t1,t0,"Flatten reversed or repeated a segment")
            XCTAssertEqual(a.y,c0.y,accuracy:1e-9);XCTAssertEqual(b.y,c1.y,accuracy:1e-9)
            let u=CGPoint(x:c0.x+dt*d0.x/3,y:c0.y+dt*d0.y/3),v=CGPoint(x:c1.x-dt*d1.x/3,y:c1.y-dt*d1.y/3)
            let dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
            XCTAssertGreaterThan(length,0)
            // A cubic lies inside its control hull: these exact subcurve
            // controls bound every point, rather than sampling returned pixels.
            hullBound=max(hullBound,Double(abs((u.x-a.x)*dy-(u.y-a.y)*dx)/length),Double(abs((v.x-a.x)*dy-(v.y-a.y)*dx)/length))
        }
        XCTAssertLessThanOrEqual(hullBound,1.0/256,"Flatten exceeded its declared device-space geometric approximation")
        XCTAssertEqual(try Data(contentsOf:corpus.appendingPathComponent("flatten-cubic-stroke.emf")),source)
    }
    func testAuthoredSourceInventoryAndOriginalByteHashes()throws {
        let value=try manifest()
        XCTAssertGreaterThan(value.files.filter{$0.refused != true}.count,30)
        XCTAssertGreaterThan(value.files.filter{$0.refused==true}.count,20)
        for file in value.files {
            let data=try Data(contentsOf:corpus.appendingPathComponent(file.file))
            XCTAssertEqual(data.count,file.bytes)
            XCTAssertEqual(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),file.sha256,file.file)
        }
    }
    func testCompactAndWidePolyDrawCubicCloseFiguresAndCurrentPositionMatchExplicitRecords()throws {
        try pairs(prefix:"polydraw16");try pairs(prefix:"polydraw32")
        let shape=try pixels("polydraw16-cubic.emf")
        color(shape,32,16,[255,0,0,255],accuracy:1)
        color(shape,32,32,[255,255,255,255])
        let following=try pixels("polydraw16-current-position.emf")
        color(following,56,48,[255,0,0,255])
    }
    func testFlattenReplacementNoEarlyInkAndBothOpenAndCompletedSavedPaths()throws {
        try pairs(prefix:"flatten-no-early-ink")
        try pairs(prefix:"flatten-active-save-restore")
        try pairs(prefix:"flatten-completed-save-restore")
        try pairs(prefix:"flatten-cubic-stroke",tolerance:2)
        try pairs(prefix:"flatten-following-position",tolerance:2)
        try verifyAnalyticFlattenGeometry()
        color(try pixels("flatten-following-position.emf"),56,48,[255,0,0,255])
        color(try pixels("flatten-original-cubic.emf"),32,16,[255,0,0,255])
    }
    func testWidenSelectedGeometricPenCapsJoinsAndDashBecomesFillableArea()throws {
        for kind in ["round","flat","square","miter","bevel","dash"] {try pairs(prefix:"widen-"+kind+"-fill",tolerance:2)}
        let current=try pixels("widen-current-pen.emf")
        color(current,32,20,[0,0,255,255]);color(current,32,28,[0,0,255,255]);color(current,32,16,[255,255,255,255])
        let normal=try pixels("widen-normal-wide.emf")
        color(normal,32,22,[0,0,255,255]);color(normal,32,14,[255,255,255,255])
        let repeated=try pixels("widen-cubic-flatten-repeat.emf")
        XCTAssertTrue(stride(from:0,to:repeated.count,by:4).contains{repeated[$0]<10 && repeated[$0+1]<10 && repeated[$0+2]>245},"Widened cubic lost its blue fill")
    }
    func testNativeSuccessThinStockNullAndMappedClassicWidenGeometry()throws {
        for name in ["widen-default-pen","widen-normal-thin","widen-normal-zero","widen-stock","widen-null","widen-normal-wide-dash-solid","widen-shrunk-minimum"] {try pairs(prefix:name,tolerance:2)}
        for name in ["widen-normal-enlarged","widen-normal-anisotropic","widen-normal-sheared"] {
            let actual=try pixels(name+".emf")
            XCTAssertTrue(stride(from:0,to:actual.count,by:4).contains{actual[$0+2]>actual[$0] && actual[$0+2]>actual[$0+1]},"Legitimate transformed WidenPath produced no blue area: "+name)
        }
    }
    func testWidenClipCapturedDeviceGeometryAndAbortDoNotLeakOriginalStroke()throws {
        try pairs(prefix:"widen-device-capture",tolerance:1);try pairs(prefix:"widen-no-early-ink")
        let clip=try pixels("widen-clip.emf")
        color(clip,32,22,[0,255,0,255]);color(clip,32,12,[255,255,255,255]);color(clip,8,24,[255,255,255,255])
    }
    func testMalformedTypedGroupsReplacementStateAndThinNullPensRefuseWholeImage()throws {
        for file in try manifest().files where file.refused==true {
            let url=corpus.appendingPathComponent(file.file),original=try Data(contentsOf:url)
            XCTAssertNil(try ComparisonImage(bytes:original),"Invalid path record must not publish earlier red paint: "+file.file)
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
}
