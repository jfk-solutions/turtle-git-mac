// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

/// Original wire records and independent ordinary-object/RGB-table controls.
/// DEFAULT_PALETTE expectations name the chosen Windows common-display logical
/// playback profile; they do not assert an arbitrary physical device palette.
final class MetafileDrawingStateTests:XCTestCase {
    private let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private var helper:URL? {ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_METAFILE_HELPER"].map{URL(fileURLWithPath:$0)}}
    private func pixels(_ name:String)throws->[UInt8] {
        let file=directory.appendingPathComponent(name),original=try Data(contentsOf:file)
        let svg=try XCTUnwrap(MetafileImageDecoder.convert(original,executable:helper)),image=try XCTUnwrap(ComparisonImage(bytes:svg),name)
        XCTAssertEqual(image.pixels.width,64);XCTAssertEqual(image.pixels.height,64)
        var result=[UInt8](repeating:0,count:64*64*4)
        try result.withUnsafeMutableBytes {storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:64,height:64))
        }
        XCTAssertEqual(try Data(contentsOf:file),original,"Decoder changed original encoded bytes")
        return result
    }
    @discardableResult private func pair(_ stem:String,_ ext:String="emf",file:StaticString = #filePath,line:UInt = #line)throws->[UInt8] {
        let actual=try pixels(stem+"."+ext),control=try pixels(stem+"-control."+ext)
        let firstDifference=zip(actual,control).enumerated().first{$0.element.0 != $0.element.1}?.offset
        XCTAssertTrue(actual==control,"Actual encoded state differs from independent ordinary object/RGB-table control: "+stem+" at byte "+String(describing:firstDifference),file:file,line:line)
        return actual
    }
    private func rgb(_ p:[UInt8],_ x:Int,_ y:Int,_ expected:[Int],_ message:String,file:StaticString = #filePath,line:UInt = #line) {
        let actual=(0..<4).map{Int(p[(y*64+x)*4+$0])}
        for c in 0..<3 {XCTAssertEqual(Double(actual[c]),Double(expected[c]),accuracy:1,message+" at \(x),\(y): \(actual)",file:file,line:line)}
        XCTAssertEqual(actual[3],255,message+" alpha",file:file,line:line)
    }
    func testEMFStockDCDefaultsRecordedColorReplacementsAndSavedSelection()throws {
        let p=try pair("classic-dc-stock-vector")
        for(x,y,color)in [(12,12,[255,255,255]),(12,28,[0,0,0]),(44,12,[255,0,0]),(44,28,[255,0,0]),(12,44,[255,255,255]),(12,60,[0,0,0]),(44,44,[255,0,0]),(44,60,[255,0,0]),(30,30,[0,0,255])] {
            rgb(p,x,y,color,"DC stock defaults are independent of text/background colors and restore ordinary recorded replacements")
        }
    }
    func testStockBrushFeedsExplicitRegionPATCOPYAndFloodWithoutChangingSelection()throws {
        let p=try pair("classic-dc-stock-consumers")
        for(x,y,color)in [(12,12,[255,255,255]),(44,12,[255,0,0]),(12,40,[255,255,255]),(44,44,[255,255,255]),(12,48,[0,0,0]),(44,60,[255,0,0]),(30,30,[0,0,255])] {
            rgb(p,x,y,color,"Stock region/current raster/flood/pen consumers preserve selected ordinary brush and restored pen")
        }
    }
    func testExplicitCommonDisplayDefaultPaletteAllTwentyLogicalEntriesAndVectorConsumers()throws {
        let colors=[[0,0,0],[128,0,0],[0,128,0],[128,128,0],[0,0,128],[128,0,128],[0,128,128],[192,192,192],[192,220,192],[166,202,240],[255,251,240],[160,160,164],[128,128,128],[255,0,0],[0,255,0],[255,255,0],[0,0,255],[255,0,255],[0,255,255],[255,255,255]]
        for(stem,ext)in [("classic-default-palette-profile","emf"),("wmf-default-palette-profile","wmf")] {
            let p=try pair(stem,ext)
            for(index,color)in colors.enumerated(){rgb(p,8+(index%5)*12,8+(index/5)*12,color,"Named common-display logical profile entry \(index)")}
            rgb(p,12,58,[255,0,0],"PALETTEINDEX ordinary brush resolves default entry13")
            rgb(p,44,58,[0,0,255],"PALETTEINDEX ordinary pen resolves default entry16")
            rgb(p,27,58,[0,0,0],"Attempted mutation of read-only DEFAULT_PALETTE leaves entry0 unchanged")
        }
    }
    func testFormerMissingPalettePatternIsValidAgainstExplicitDefaultProfile()throws {
        let p=try pixels("classic-patternbrush-default-palette.emf")
        rgb(p,8,8,[128,0,0],"Logical default palette entry1 gives maroon monochrome pattern bit1")
        rgb(p,9,8,[0,0,0],"Logical default palette entry0 gives black monochrome pattern bit0")
    }
    func testSavedPaletteIdentityRetainsLiveCustomEditsAndDeletionDoesNotRetargetDefault()throws {
        for(stem,ext)in [("classic-default-palette-state","emf"),("wmf-default-palette-state","wmf")] {
            let p=try pair(stem,ext)
            rgb(p,12,12,[255,0,0],"Initial custom entry0")
            rgb(p,44,12,[0,0,0],"Nested restore returns explicit DEFAULT profile")
            rgb(p,12,44,[0,0,255],"Outer restore retains live edited custom palette; saved selection prevented deletion")
            rgb(p,44,44,[0,0,0],"Deleting unselected custom palette cannot change later DEFAULT profile")
        }
    }
    func testLivePaletteIndexColorsReachOrdinaryExtendedHatchAndTextConsumers()throws {
        let p=try pair("classic-palette-color-consumers")
        for(offset,fill,stroke)in [(0,[255,0,0],[0,0,255]),(32,[0,255,0],[255,255,0])] {
            rgb(p,8,8+offset,fill,"Same ordinary brush resolves current palette at paint time")
            rgb(p,8,16+offset,stroke,"Same ordinary pen resolves current palette at paint time")
            rgb(p,8,24+offset,stroke,"Same extended pen resolves current palette at paint time")
            for(label,xs,ys)in [("hatch",20..<36,(2+offset)..<(26+offset)),("text",42..<63,(4+offset)..<(27+offset))] {
                var matches=0
                for y in ys {for x in xs {let q=(y*64+x)*4;if (0..<3).allSatisfy({abs(Int(p[q+$0])-fill[$0])<=1}) && p[q+3]==255 {matches+=1}}}
                XCTAssertGreaterThan(matches,5,"\(label) has no authored literal current-palette interior color at row \(offset)")
            }
        }
    }
    func testLogicalBrushSelectionDefersResolutionUntilPaintingWithLaterCustomPalette()throws {
        let p=try pair("classic-deferred-palette-brush")
        rgb(p,12,12,[0,255,255],"Index25 selected before palette creation resolves to later custom cyan at paint time")
        rgb(p,40,40,[255,255,255],"Unused unresolved selected brush does not paint or fail EOF")
    }
    func testUnsupportedHardwarePaletteIndicesOutOfProfileAndUnverifiedWMFStocksRefuseWholeImage()throws {
        let names=["unsupported-drawing-state-painted-unresolved-brush.emf","unsupported-drawing-state-palette-index.emf","unsupported-drawing-state-wmf-palette-index.wmf","unsupported-drawing-state-hardware-entry.emf","unsupported-drawing-state-wmf-hardware-entry.wmf","unsupported-drawing-state-wmf-stock-18.wmf","unsupported-drawing-state-wmf-stock-19.wmf"]
        for name in names {let bytes=try Data(contentsOf:directory.appendingPathComponent(name));XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes,executable:helper),name);XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent(name)),bytes)}
    }
    func testStockAndPaletteSelectionsStayIsolatedAcrossConversionsAndRefusals()throws {
        let before=try pixels("classic-default-palette-profile.emf")
        _=try pixels("classic-palette-color-consumers.emf");_=try pixels("wmf-default-palette-state.wmf");_=try pixels("classic-dc-stock-consumers.emf")
        let bad=try Data(contentsOf:directory.appendingPathComponent("unsupported-drawing-state-palette-index.emf"));XCTAssertThrowsError(try MetafileImageDecoder.convert(bad,executable:helper))
        XCTAssertEqual(try pixels("classic-default-palette-profile.emf"),before,"A previous conversion/failed paint leaked DC or palette state")
    }
}
