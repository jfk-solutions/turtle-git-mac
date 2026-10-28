// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

/// Original Windows Bitmap(file,FALSE) observations, not a second implementation
/// of the blur, sharpen or RedEye numerical algorithm.
final class MetafileSpatialEffectsTests:XCTestCase {
    struct Sample:Decodable {let x:Int,y:Int,rgba:[Int],tolerance:Int}
    struct Parameters:Decodable,Equatable {
        let radius:Double?,expandEdge:Bool?,amount:Double?,numberOfAreas:Int?,areas:[[Int]]?
    }
    struct ReferenceCase:Decodable {
        let file:String,family:String,sourceSHA256:String,referenceRGBA:String,rgbaSHA256:String
        let width:Int,height:Int,alphaTolerance:Int,samples:[Sample],parameters:Parameters
        let directOpaqueChangedPixelCount:Int?
    }
    struct Refusal:Decodable {let file:String,family:String,sourceSHA256:String}
    struct Reference:Decodable {
        let windowsRun:Int,artifact:Int,startupVersion:Int,archiveSHA256:String
        let coverage:[String:Int],cases:[ReferenceCase],refusals:[Refusal]
    }
    struct PlaybackContexts:Decodable {
        struct Repeated:Decodable {let finalSHA256:String,intrinsicSHA256:String}
        struct Replacement:Decodable {
            let file:String,sourceSHA256:String,previousReferenceRGBA:String,previousRGBA_SHA256:String
            let freshRepeats:[Repeated]
            let referenceCase:ReferenceCase
            enum CodingKeys:String,CodingKey {
                case file,sourceSHA256,previousReferenceRGBA,previousRGBA_SHA256,freshRepeats
                case referenceCase="case"
            }
        }
        struct History:Decodable {
            struct Context:Decodable {let finalSHA256:String,intrinsicSHA256:String}
            let file:String,freshFirstUseSHA256:String,priorCapturedSHA256:String
            let contexts:[Context]
        }
        let originalManifestSHA256:String,startupVersion:Int,windowsRun:Int,artifact:Int
        let replacements:[Replacement],additionalCases:[ReferenceCase],historyObservations:[History]
    }
    private let folder=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/SpatialEffects")
    private func reference()throws->Reference {
        try JSONDecoder().decode(Reference.self,from:Data(contentsOf:folder.appendingPathComponent("windows-reference.json")))
    }
    private func playbackContexts()throws->PlaybackContexts {
        let result=try JSONDecoder().decode(PlaybackContexts.self,from:Data(contentsOf:folder.appendingPathComponent("playback-context-reference.json")))
        let original=try Data(contentsOf:folder.appendingPathComponent("windows-reference.json"))
        XCTAssertEqual(SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined(),result.originalManifestSHA256)
        XCTAssertEqual(result.startupVersion,1);XCTAssertGreaterThan(result.windowsRun,0);XCTAssertGreaterThan(result.artifact,0)
        return result
    }
    private func verified(_ file:String,hash:String)throws->Data {
        XCTAssertFalse(file.contains("/"));XCTAssertFalse(file.contains("\\"))
        let bytes=try Data(contentsOf:folder.appendingPathComponent(file))
        XCTAssertEqual(SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),hash,file)
        return bytes
    }
    private func check(_ item:ReferenceCase)throws {
        let wire=try verified(item.file,hash:item.sourceSHA256)
        let expected=try verified(item.referenceRGBA,hash:item.rgbaSHA256)
        XCTAssertGreaterThan(item.width,0);XCTAssertGreaterThan(item.height,0)
        XCTAssertEqual(expected.count,item.width*item.height*4,item.file)
        XCTAssertEqual(item.alphaTolerance,1)
        XCTAssertTrue(item.samples.allSatisfy{$0.tolerance==1},"No unmeasured numerical tolerance")
        let image=try XCTUnwrap(ComparisonImage(bytes:wire),item.file)
        XCTAssertEqual(image.pixels.width,item.width,item.file)
        XCTAssertEqual(image.pixels.height,item.height,item.file)
        guard image.pixels.width==item.width,image.pixels.height==item.height,
              expected.count==item.width*item.height*4 else{return}
        var actual=[UInt8](repeating:0,count:expected.count)
        try actual.withUnsafeMutableBytes {storage in
            let colorSpace=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
            let context=try XCTUnwrap(CGContext(data:storage.baseAddress,width:item.width,height:item.height,
                bitsPerComponent:8,bytesPerRow:item.width*4,space:colorSpace,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image.pixels,in:CGRect(x:0,y:0,width:item.width,height:item.height))
        }
        var failures=0,maxDelta=0,details=[String]()
        for index in stride(from:0,to:expected.count,by:4) {
            let alpha=Int(expected[index+3])
            for channel in 0..<4 {
                let wanted=channel==3 ? alpha:Int((Double(Int(expected[index+channel])*alpha)/255).rounded())
                let delta=abs(Int(actual[index+channel])-wanted)
                maxDelta=max(maxDelta,delta)
                if delta>1 {
                    failures += 1
                    if details.count<12 {details.append("(\((index/4)%item.width),\((index/4)/item.width)) c\(channel): \(actual[index+channel]) vs \(wanted)")}
                }
            }
        }
        XCTAssertEqual(failures,0,"\(item.file): complete native raster differs maxDelta=\(maxDelta); \(details.joined(separator:"; "))")
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),wire,"Rendering changed original source")
    }
    private func family(_ name:String)throws->[ReferenceCase] {
        let value=try reference(),cases=value.cases.filter{$0.family==name}
        let contexts=try playbackContexts()
        XCTAssertFalse(cases.isEmpty,name)
        XCTAssertEqual(cases.count,try XCTUnwrap(value.coverage[name]),name)
        for item in cases {
            if let entry=contexts.replacements.first(where:{$0.file==item.file}) {
                // The old observation remains intact: it belongs to an earlier
                // native process history, not a fresh converter invocation.
                XCTAssertEqual(entry.sourceSHA256,item.sourceSHA256)
                XCTAssertEqual(entry.previousReferenceRGBA,item.referenceRGBA)
                XCTAssertEqual(entry.previousRGBA_SHA256,item.rgbaSHA256)
                _ = try verified(item.referenceRGBA,hash:item.rgbaSHA256)
                XCTAssertEqual(entry.referenceCase.file,item.file)
                XCTAssertEqual(entry.referenceCase.sourceSHA256,item.sourceSHA256)
                XCTAssertEqual(entry.referenceCase.family,item.family)
                XCTAssertEqual(entry.referenceCase.parameters,item.parameters)
                XCTAssertEqual(entry.referenceCase.width,item.width);XCTAssertEqual(entry.referenceCase.height,item.height)
                XCTAssertEqual(entry.referenceCase.alphaTolerance,item.alphaTolerance)
                try check(entry.referenceCase)
            } else {try check(item)}
        }
        return cases
    }
    func testPictureSourceRectanglesPreservePriorPaintAndActualCoverage()throws {
        let contexts=try playbackContexts()
        XCTAssertEqual(contexts.additionalCases.count,5)
        for item in contexts.additionalCases {try check(item)}
    }
    func testFreshFirstUseReferencesRetainDistinctNativeProcessHistory()throws {
        let contexts=try playbackContexts()
        XCTAssertEqual(contexts.replacements.count,2);XCTAssertEqual(contexts.historyObservations.count,2)
        for entry in contexts.replacements {
            XCTAssertEqual(entry.freshRepeats.count,3)
            for repeated in entry.freshRepeats {
                XCTAssertEqual(repeated.finalSHA256,entry.referenceCase.rgbaSHA256)
                XCTAssertEqual(repeated.intrinsicSHA256,repeated.finalSHA256)
            }
            XCTAssertNotEqual(entry.previousRGBA_SHA256,entry.referenceCase.rgbaSHA256)
            let history=try XCTUnwrap(contexts.historyObservations.first(where:{$0.file==entry.file}))
            XCTAssertEqual(history.freshFirstUseSHA256,entry.referenceCase.rgbaSHA256)
            XCTAssertEqual(history.priorCapturedSHA256,entry.previousRGBA_SHA256)
            XCTAssertTrue(history.contexts.contains{$0.finalSHA256==entry.previousRGBA_SHA256})
            for item in history.contexts {XCTAssertEqual(item.finalSHA256,item.intrinsicSHA256)}
            _ = try verified(entry.previousReferenceRGBA,hash:entry.previousRGBA_SHA256)
            _ = try verified(entry.referenceCase.referenceRGBA,hash:entry.referenceCase.rgbaSHA256)
        }
    }
    func testSpatialBlurFullNativeRasterIncludesExpandedOutput()throws {
        let cases=try family("blur")
        XCTAssertTrue(cases.contains{$0.parameters.expandEdge==true && ($0.width>32 || $0.height>32)},"Expanded draw coverage must remain in this family")
    }
    func testSpatialSharpenFullNativeRaster()throws {_ = try family("sharpen")}
    func testSpatialRedEyeFullNativeRasterIncludesActualCorrection()throws {
        let cases=try family("redEyeCorrection")
        XCTAssertTrue(cases.contains{($0.directOpaqueChangedPixelCount ?? 0)>0},"No-op pictures alone cannot establish active RedEye support")
    }
    func testSpatialMalformedLateEffectsRefuseWholeConversionWithoutChangingSource()throws {
        let value=try reference()
        XCTAssertEqual(Set(value.cases.map(\.family)),Set(["blur","sharpen","redEyeCorrection"]))
        XCTAssertEqual(value.startupVersion,1);XCTAssertGreaterThan(value.windowsRun,0);XCTAssertGreaterThan(value.artifact,0)
        XCTAssertEqual(value.archiveSHA256.count,64)
        XCTAssertFalse(value.refusals.isEmpty)
        XCTAssertEqual(Set(value.refusals.map(\.family)),Set(value.cases.map(\.family)))
        for item in value.refusals {
            let wire=try verified(item.file,hash:item.sourceSHA256)
            XCTAssertThrowsError(try MetafileImageDecoder.convert(wire),item.file)
            XCTAssertNil(ComparisonImage(bytes:wire),"Malformed effect exposed partial earlier paint: "+item.file)
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(item.file)),wire)
        }
    }
}
