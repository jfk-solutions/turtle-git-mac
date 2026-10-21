// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

final class MetafileClassicGradientTests:XCTestCase {
    private let fixtures=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func bytes(_ name:String)throws->Data {try Data(contentsOf:fixtures.appendingPathComponent(name+".emf"))}
    private struct Raster {
        let width:Int,height:Int,rgba:[UInt8]
        func pixel(_ x:Int,_ y:Int)->[Int] {(0..<4).map{Int(rgba[(y*width+x)*4+$0])}}
    }
    private func raster(_ name:String)throws->Raster {
        let original=try bytes(name),image=try XCTUnwrap(ComparisonImage(bytes:original),name)
        XCTAssertEqual(image.size,CGSize(width:64,height:64),name)
        let width=image.pixels.width,height=image.pixels.height
        var rgba=[UInt8](repeating:0,count:width*height*4)
        try rgba.withUnsafeMutableBytes {buffer in
            let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let ctx=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        XCTAssertEqual(try bytes(name),original,"Preview must retain original metafile bytes")
        return Raster(width:width,height:height,rgba:rgba)
    }
    private func color(_ value:Raster,_ x:Int,_ y:Int,_ expected:[Double],file:StaticString=#filePath,line:UInt=#line) {
        let sample=value.pixel(x,y)
        for channel in 0..<3 {XCTAssertEqual(Double(sample[channel]),expected[channel],accuracy:2,"pixel(\(x),\(y))=\(sample)",file:file,line:line)}
        XCTAssertEqual(sample[3],255,"Vertex Alpha must not make GradientFill translucent",file:file,line:line)
    }
    /// Independent analytic weights for the literal right triangle in the wire
    /// fixtures. This does not inspect the renderer's SVG, PNG or triangulation.
    private func triangleRGB(_ x:Double,_ y:Double)->[Double] {
        let green=(x-8)/48,blue=(y-8)/48
        return [255*(1-green-blue),255*green,255*blue]
    }
    func testClassicGradientTriangleRGBAlphaWindingSharedEdgesAndDrawingOrder()throws {
        let value=try raster("classic-gradient-triangle")
        for point in [(16,16),(40,12),(12,40),(24,24)] {color(value,point.0,point.1,triangleRGB(Double(point.0)+0.5,Double(point.1)+0.5))}
        color(value,56,56,[255,255,255]);color(value,4,4,[255,255,255])
        XCTAssertEqual(try raster("classic-gradient-triangle-reversed").rgba,value.rgba,"Opposite winding changed the gradient")
        XCTAssertEqual(try raster("classic-gradient-alpha-ignored").rgba,value.rgba,"Ignored Alpha fields changed the painted pixels")
        let shared=try raster("classic-gradient-shared-edge")
        XCTAssertEqual(try raster("classic-gradient-shared-edge-reversed").rgba,shared.rgba,"Mesh winding changed shared-edge coverage")
        for p in 8..<56 {
            let t=(Double(p)+0.5-8)/48
            color(shared,p,p,[255*(1-t),0,255*t])
        }
        let ordered=try raster("classic-gradient-mesh-order")
        color(ordered,12,12,[255,0,0]);color(ordered,24,24,[0,0,255]);color(ordered,56,56,[255,255,255])
        for name in ["classic-gradient-degenerate","classic-gradient-empty"] {
            let blank=try raster(name)
            XCTAssertTrue(blank.rgba.allSatisfy{$0==255},name+" should not paint a degenerate/empty primitive")
        }
        let outside=try raster("classic-gradient-outside")
        // Original vertices(-32,-32),(96,-32),(-32,96); samples stay inside
        // the visible half-plane while the primitive extends off the canvas.
        let g=(12.5+32)/128,b=(20.5+32)/128
        color(outside,12,20,[255*(1-g-b),255*g,255*b]);color(outside,56,56,[255,255,255])
    }
    func testClassicGradientRectangleModesAffineTransformsAndOwnedClipRestore()throws {
        for (suffix,vertical) in [("horizontal",false),("vertical",true)] {
            let name="classic-gradient-rectangle-"+suffix,value=try raster(name)
            XCTAssertEqual(try raster(name+"-compact").rgba,value.rgba,"Ignored normative padding and compact API representation differ")
            for (x,y) in [(20,32),(44,32),(32,20),(32,44)] {
                let t=((vertical ? Double(y):Double(x))+0.5-8)/48
                color(value,x,y,[255*(1-t),0,255*t])
            }
            color(value,4,4,[255,255,255])
        }
        let rotated=try raster("classic-gradient-rectangle-rotated")
        for y in [20,44] {let t=(Double(y)+0.5-8)/48;color(rotated,20,y,[255*(1-t),0,255*t])}
        let shear=try raster("classic-gradient-rectangle-sheared"),fraction=(40.5-0.5*20.5-8)/48
        color(shear,40,20,[255*(1-fraction),0,255*fraction]);color(shear,20,40,[255,255,255])
        let mirrored=try raster("classic-gradient-rectangle-mirrored")
        color(mirrored,20,20,[255*(1-12.5/48),0,255*12.5/48]);color(mirrored,4,4,[255,255,255])
        let triangle=try raster("classic-gradient-triangle-shear")
        // Invert the documented world transform x'=x+y/2, y'=x/4+y.
        let lx=(26.5-0.5*24.5)/0.875,ly=(24.5-0.25*26.5)/0.875
        color(triangle,26,24,triangleRGB(lx,ly));color(triangle,4,4,[255,255,255])
        let clipped=try raster("classic-gradient-clip-restored")
        color(clipped,12,24,[255,255,255]);color(clipped,44,24,[255,255,255])
        let t=(28.5-0.5*24.5-8)/48
        color(clipped,28,24,[255*(1-t),0,255*t]);color(clipped,48,48,[0,255,0])
    }
    func testClassicGradientStrictMeshFramingIndicesBoundsAndWholeImageRefusal()throws {
        let names=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter{$0.hasPrefix("unsupported-gradient-classic-")&&$0.hasSuffix(".emf")}.sorted()
        XCTAssertEqual(names.count,11,"Every independent classic GradientFill refusal must remain enrolled")
        for name in names {
            let original=try Data(contentsOf:fixtures.appendingPathComponent(name))
            XCTAssertThrowsError(try MetafileImageDecoder.convert(original),name) {error in
                if name.contains("mesh-work-budget") {
                    guard let failure=error as? MetafileImageFailure,case .failed(let diagnostic)=failure else{return XCTFail("Expected explicit gradient budget failure, got \(error)")}
                    XCTAssertTrue(diagnostic.contains("classic gradient raster work budget"),"Expected budget diagnostic, got \(diagnostic)")
                }
            }
            XCTAssertNil(ComparisonImage(bytes:original),name+" must not show earlier valid paint as partial success")
            XCTAssertEqual(try Data(contentsOf:fixtures.appendingPathComponent(name)),original)
        }
    }
}
