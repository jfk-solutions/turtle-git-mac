// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafilePointwiseEffectsTests:XCTestCase {
    struct Sample:Decodable {let x:Int,y:Int,rgba:[Int],tolerance:Int}
    struct ReferenceCase:Decodable {
        let file:String,family:String,profile:String,sourceSHA256:String,referenceRGBA:String,rgbaSHA256:String
        let width:Int,height:Int,alphaTolerance:Int,samples:[Sample]
    }
    struct Derived:Decodable {let file:String,sourceSHA256:String,referenceFile:String}
    struct Refusal:Decodable {let file:String,family:String,sourceSHA256:String}
    struct TintQualification:Decodable {
        let sha256:String,model:String
        let nativeCases:Int,associatedRGBTolerance:Int,alphaTolerance:Int,otherFamiliesAssociatedRGBTolerance:Int
    }
    struct Reference:Decodable {
        let windowsRun:Int,artifact:Int,startupVersion:Int,archiveSHA256:String
        let tintQualification:TintQualification
        let normativeCount:Int,recordedIgnoredCount:Int
        let coverage:[String:Int],curveModeChannels:[[Int]],cases:[ReferenceCase],states:[ReferenceCase],derived:[Derived],refusals:[Refusal]
    }
    private let folder=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/PointwiseEffects")
    private func reference()throws->Reference {try JSONDecoder().decode(Reference.self,from:Data(contentsOf:folder.appendingPathComponent("windows-reference.json")))}
    private func verified(_ file:String,hash:String)throws->Data {
        let bytes=try Data(contentsOf:folder.appendingPathComponent(file))
        XCTAssertEqual(SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),hash,file)
        return bytes
    }
    private func check(_ item:ReferenceCase,wireOverride:Derived?=nil)throws {
        let file=wireOverride?.file ?? item.file
        let wire=try verified(file,hash:wireOverride?.sourceSHA256 ?? item.sourceSHA256)
        let expected=try verified(item.referenceRGBA,hash:item.rgbaSHA256)
        XCTAssertEqual(item.width,32,file);XCTAssertEqual(item.height,32,file)
        XCTAssertEqual(expected.count,item.width*item.height*4,file)
        // Tint's separately recorded full35-case model analysis qualifies only
        // associated RGB to3 bytes. Every other family and all alpha stay at1.
        let colorTolerance=item.family=="tint" ? 3:1
        XCTAssertEqual(item.alphaTolerance,1,"Alpha may not inherit Tint RGB tolerance")
        XCTAssertTrue(item.samples.allSatisfy{$0.tolerance==colorTolerance},"Tolerance must match the explicit family contract")
        let image=try XCTUnwrap(ComparisonImage(bytes:wire),file)
        XCTAssertEqual(image.pixels.width,item.width,file);XCTAssertEqual(image.pixels.height,item.height,file)
        guard image.pixels.width==item.width,image.pixels.height==item.height,expected.count==item.width*item.height*4 else{return}
        var actual=[UInt8](repeating:0,count:expected.count)
        try actual.withUnsafeMutableBytes {storage in
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:item.width,height:item.height,bitsPerComponent:8,bytesPerRow:item.width*4,space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image.pixels,in:CGRect(x:0,y:0,width:item.width,height:item.height))
        }
        // Inspect every pixel/channel, including transparent SourceCopy output.
        // GetPixel's straight Windows samples are independently premultiplied
        // here for the actual display buffer; the explicit family budget is applied.
        var failures=0,maxDelta=0,details=[String]()
        for index in stride(from:0,to:expected.count,by:4) {
            let alpha=Int(expected[index+3])
            for channel in 0..<4 {
                let wanted=channel==3 ? alpha:Int((Double(Int(expected[index+channel])*alpha)/255).rounded())
                let delta=abs(Int(actual[index+channel])-wanted);maxDelta=max(maxDelta,delta)
                if delta>(channel==3 ? 1:colorTolerance) {
                    failures += 1
                    if details.count<12 {details.append("(\((index/4)%item.width),\((index/4)/item.width)) c\(channel): \(actual[index+channel]) vs \(wanted)")}
                }
            }
        }
        XCTAssertEqual(failures,0,"\(file): full native raster differs, maxDelta=\(maxDelta); \(details.joined(separator:"; "))")
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(file)),wire,"Rendering changed original EMF bytes")
    }
    private func family(_ name:String)throws {
        let value=try reference(),cases=value.cases.filter{$0.family==name && $0.profile=="normative"}
        XCTAssertFalse(cases.isEmpty,name);XCTAssertEqual(cases.count,try XCTUnwrap(value.coverage[name]),name)
        for item in cases {try check(item)}
    }
    func testPointwiseColorBalanceMatchesFullNativeWindowsRaster()throws {try family("colorBalance")}
    func testPointwiseHueSaturationLightnessMatchesFullNativeWindowsRaster()throws {try family("hueSaturationLightness")}
    func testPointwiseLevelsMatchesFullNativeWindowsRaster()throws {try family("levels")}
    func testPointwiseTintMatchesFullNativeWindowsRaster()throws {try family("tint")}
    func testPointwiseCurveEveryModeAndChannelMatchesFullNativeWindowsRaster()throws {
        let value=try reference()
        XCTAssertEqual(Set(value.curveModeChannels.map{ $0.map(String.init).joined(separator:":") }),Set((0..<8).flatMap{mode in (0..<4).map{"\(mode):\($0)"}}))
        try family("colorCurve")
    }
    func testPointwiseOriginalRecordedCurveCompatibilityRemainsPlain()throws {
        let value=try reference(),cases=value.cases.filter{$0.profile=="recordedIgnored"}
        XCTAssertEqual(cases.count,152)
        XCTAssertTrue(cases.allSatisfy{$0.family=="colorCurve" && $0.file.hasPrefix("original-")})
        for item in cases {try check(item)}
    }
    func testPointwiseIgnoredCurveInterpositionAndPlainDrawUseActualNativeStatePixels()throws {
        let value=try reference();XCTAssertEqual(value.states.count,3)
        XCTAssertEqual(Set(value.states.map(\.file)),Set(["state-balance-pending-ignoredCurve-E.emf","state-ignoredCurve-balance-pending-E.emf","state-ignoredCurve-Eclear-Eset.emf"]))
        for item in value.states {try check(item)}
    }
    func testPointwiseReservedSerializableFlagsRetainActualNativePixels()throws {
        let value=try reference()
        XCTAssertEqual(value.startupVersion,1);XCTAssertGreaterThan(value.windowsRun,0);XCTAssertGreaterThan(value.artifact,0)
        XCTAssertEqual(value.archiveSHA256.count,64)
        XCTAssertEqual(value.tintQualification.sha256,"ea7f3bcf7445ef5cd039364f7d87678abe6fc566c7dd6c5de16bb7326e7f8e27")
        XCTAssertEqual(value.tintQualification.model,"luma_max");XCTAssertEqual(value.tintQualification.nativeCases,35)
        XCTAssertEqual(value.tintQualification.associatedRGBTolerance,3);XCTAssertEqual(value.tintQualification.alphaTolerance,1)
        XCTAssertEqual(value.tintQualification.otherFamiliesAssociatedRGBTolerance,1)
        XCTAssertEqual(value.normativeCount,288);XCTAssertEqual(value.recordedIgnoredCount,152)
        XCTAssertEqual(value.cases.count,440,"Do not drop normative or original-compatibility profiles silently")
        XCTAssertEqual(Set(value.cases.map(\.family)),Set(["colorBalance","hueSaturationLightness","levels","colorCurve","tint"]))
        XCTAssertEqual(value.derived.count,5)
        for derived in value.derived {try check(XCTUnwrap(value.cases.first{$0.file==derived.referenceFile}),wireOverride:derived)}
    }
    func testPointwiseMalformedProfilesRefuseWholeConversionAndPreserveOriginalBytes()throws {
        let value=try reference();XCTAssertEqual(value.refusals.count,62)
        XCTAssertEqual(Set(value.refusals.map(\.family)),Set(value.cases.map(\.family)))
        for item in value.refusals {
            let bytes=try verified(item.file,hash:item.sourceSHA256)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes),item.file)
            XCTAssertNil(ComparisonImage(bytes:bytes),"Malformed late effect exposed partial earlier paint: "+item.file)
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),bytes)
        }
    }
}
