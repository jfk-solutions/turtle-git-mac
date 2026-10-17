import XCTest
@testable import TurtleGitCore

final class AboutWaterEffectTests:XCTestCase {
    func testPinnedSourceFrames()throws {
        struct Oracle:Decodable {let cases:[Case]}
        struct Case:Decodable {let width:Int;let height:Int;let density:Int;let rgb_frame_checksums:[String]}
        let path=try XCTUnwrap(Bundle.module.url(forResource:"oracle",withExtension:"json",subdirectory:"WaterEffect"))
        let oracle=try JSONDecoder().decode(Oracle.self,from:Data(contentsOf:path))
        for test in oracle.cases {
            let width=test.width,height=test.height
            var effect=try XCTUnwrap(AboutWaterEffect(width:width,height:height));effect.density=test.density
            let source=(0..<(width*height)).map {i in UInt32(0xFF000000)|UInt32((i*13+17)&255)|(UInt32((i*7+23)&255)<<8)|(UInt32((i*3+91)&255)<<16)}
            var result=source
            for frame in 0..<24 {
                if frame==0 {effect.blob(x:width/2,y:height/2,radius:2,strength:800)}
                if frame==3 {effect.blob(x:0,y:1,radius:3,strength:50)}
                if frame==7 {effect.blob(x:width-1,y:height-2,radius:3,strength:-300)}
                if frame==11 {effect.blob(x:width/2,y:height/2,radius:10,strength:1600)}
                if frame==14 {effect.smooth()}
                effect.render(source:source,destination:&result)
                var checksum:UInt64=14695981039346656037
                for pixel in result {checksum=(checksum ^ UInt64(pixel&0xFFFFFF)) &* 1099511628211}
                XCTAssertEqual(String(format:"%016llx",checksum),test.rgb_frame_checksums[frame],"\(width)x\(height), frame \(frame)")
                XCTAssertTrue(result.allSatisfy{$0&0xFF000000==0xFF000000},"Native alpha was discarded")
                XCTAssertEqual(effect.page,(frame+1)%2)
            }
        }
    }
    func testClearAndUndisturbedPixels()throws {
        var effect=try XCTUnwrap(AboutWaterEffect(width:10,height:8))
        let source=(0..<80).map{UInt32($0)|0xFF000000};var result=source
        effect.render(source:source,destination:&result);XCTAssertEqual(result,source)
        effect.blob(x:5,y:4,radius:2,strength:800);effect.clear();result=source
        effect.render(source:source,destination:&result);XCTAssertEqual(result,source)
    }
    func testBoundsAndUnsupportedPixelShapes()throws {
        for pair in [(0,4),(3,4),(5,8),(2049,4),(4,Int.max)] {XCTAssertNil(AboutWaterEffect(width:pair.0,height:pair.1))}
        var effect=try XCTUnwrap(AboutWaterEffect(width:4,height:4));effect.density=Int.max;XCTAssertEqual(effect.density,16)
        effect.density=Int.min;XCTAssertEqual(effect.density,1)
        effect.blob(x:Int.max,y:0,radius:Int.max,strength:Int.max)
        effect.blob(x:0,y:Int.min,radius:Int.max,strength:Int.min)
        var wrong=[UInt32](repeating:0,count:2)
        effect.render(source:[0,0],destination:&wrong);XCTAssertEqual(effect.page,0)
    }
}
