// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import TurtleGitCore

/// These fixtures inspect saved XML through the system ZIP reader, independently
/// of the review's manifests, fingerprints and package-reader implementation.
final class PresentationGroupRevisionTests:XCTestCase {
    private let p="http://schemas.openxmlformats.org/presentationml/2006/main"
    private let a="http://schemas.openxmlformats.org/drawingml/2006/main"
    private let r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private let rel="http://schemas.openxmlformats.org/package/2006/relationships"
    private let slidePath="ppt/slides/slide256.xml"
    private func data(_ value:String)->Data {Data(value.utf8)}
    private func shape(_ id:Int,_ name:String,_ text:String)->String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
    }
    private func group(_ id:Int,_ name:String,_ children:String,rotation:Int=0)->String {
        "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm rot=\"\(rotation)\"><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"100\" cy=\"100\"/></a:xfrm></p:grpSpPr>"+children+"</p:grpSp>"
    }
    private func connector(_ id:Int,_ name:String,_ from:Int,_ to:Int)->String {
        "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvCxnSpPr><a:stCxn id=\"\(from)\" idx=\"0\"/><a:endCxn id=\"\(to)\" idx=\"0\"/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>"
    }
    private func picture(_ id:Int,_ name:String,_ relationship:String)->String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(relationship)\"/></p:blipFill><p:spPr/></p:pic>"
    }
    private func edge(_ id:String,_ type:String,_ target:String)->String {"<Relationship Id=\"\(id)\" Type=\"\(r)/\(type)\" Target=\"\(target)\"/>"}
    private func relationships(_ body:String)->Data {data("<Relationships xmlns=\"\(rel)\">"+body+"</Relationships>")}
    private func tree(_ content:String)->String {"<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"+content+"</p:spTree>"}
    private func deck(_ content:String,media:[String:Data]=[:],extraRelationships:String="")throws->PresentationPackage {
        let slide="<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld>"+tree(content)+"</p:cSld></p:sld>"
        let types="<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"bin\" ContentType=\"application/octet-stream\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/\(slidePath)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/><Override PartName=\"/ppt/slideLayouts/layout.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/slideMasters/master.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/theme/theme.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/></Types>"
        var entries:[String:Data]=[
            "[Content_Types].xml":data(types),"_rels/.rels":relationships(edge("office","officeDocument","ppt/presentation.xml")),
            "ppt/presentation.xml":data("<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id=\"256\" r:id=\"slide\"/></p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/></p:presentation>"),
            "ppt/_rels/presentation.xml.rels":relationships(edge("slide","slide","slides/slide256.xml")+edge("master","slideMaster","slideMasters/master.xml")),
            slidePath:data(slide),"ppt/slides/_rels/slide256.xml.rels":relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+extraRelationships),
            "ppt/slideLayouts/layout.xml":data("<p:sldLayout xmlns:p=\"\(p)\"><p:cSld>"+tree("")+"</p:cSld></p:sldLayout>"),
            "ppt/slideLayouts/_rels/layout.xml.rels":relationships(edge("master","slideMaster","../slideMasters/master.xml")),
            "ppt/slideMasters/master.xml":data("<p:sldMaster xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:cSld>"+tree("")+"</p:cSld><p:sldLayoutIdLst><p:sldLayoutId id=\"1\" r:id=\"layout\"/></p:sldLayoutIdLst></p:sldMaster>"),
            "ppt/slideMasters/_rels/master.xml.rels":relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("theme","theme","../theme/theme.xml")),
            "ppt/theme/theme.xml":data("<a:theme xmlns:a=\"\(a)\" name=\"Fixture\"><a:themeElements/></a:theme>"),"custom/opaque.bin":Data([0,255,7,10])]
        for (path,value) in media {entries[path]=value}
        return try PresentationPackage(entries:entries)
    }
    private func unzip(_ package:PresentationPackage,member:String)throws->Data {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-group-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("reviewed.pptx")
        try package.encoded(cancellation:.init()).write(to:file)
        let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");process.arguments=["-p",file.path,member];process.standardOutput=output;process.standardError=FileHandle.nullDevice
        try process.run();let bytes=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus==0 else{throw NSError(domain:"PresentationGroupZIP",code:Int(process.terminationStatus))}
        return bytes
    }
    private func document(_ package:PresentationPackage)throws->XMLDocument {try XMLDocument(data:unzip(package,member:slidePath),options:[])}
    private func nodes(_ node:XMLNode,_ local:String)throws->[XMLElement] {try node.nodes(forXPath:".//*[local-name()='\(local)']").compactMap{$0 as? XMLElement}}
    private func named(_ node:XMLNode,_ name:String)throws->XMLElement {
        let identities=try nodes(node,"cNvPr").filter{$0.attribute(forName:"name")?.stringValue==name}
        let identity=try XCTUnwrap(identities.first,"Missing object named "+name)
        return try XCTUnwrap(identity.parent?.parent as? XMLElement)
    }
    private func objectNames(_ container:XMLElement)->[String] {
        (container.children ?? []).compactMap{$0 as? XMLElement}.filter{["sp","pic","grpSp","cxnSp"].contains($0.localName ?? "")}.compactMap{object in
            guard let identities=try? nodes(object,"cNvPr"),let identity=identities.first else{return nil}
            return identity.attribute(forName:"name")?.stringValue
        }
    }
    private func text(_ node:XMLNode)throws->String {try nodes(node,"t").map{$0.stringValue ?? ""}.joined(separator:"\n")}
    private func change(_ review:PresentationRevisionReview,_ kind:PresentationRevisionChange.Kind,name:String?=nil,path:[String]=[])throws->PresentationRevisionChange {
        let matches=review.changes.filter{$0.kind==kind && $0.groupPath==path && (name==nil || $0.title.contains(name!))}
        XCTAssertEqual(matches.count,1,"Ambiguous/missing change \(kind) \(path) \(name ?? "")")
        return try XCTUnwrap(matches.first)
    }
    private func uniqueIDs(_ document:XMLDocument)throws->[String:String] {
        let elements=try nodes(document,"cNvPr"),ids=elements.compactMap{$0.attribute(forName:"id")?.stringValue}
        XCTAssertEqual(ids.count,Set(ids).count,"IDs must be unique throughout the slide, including nested children")
        return Dictionary(elements.compactMap{element in guard let name=element.attribute(forName:"name")?.stringValue,let id=element.attribute(forName:"id")?.stringValue else{return nil};return(name,id)},uniquingKeysWith:{$1})
    }

    func testNestedMixedChildrenAndIndependentOrderDecisionsWithUndoRedo()throws {
        let before=group(10,"Outer",group(20,"Inner",shape(2,"Alpha","alpha old")+shape(3,"Beta","beta old")+shape(4,"Removed","retained deletion"))+shape(6,"Sibling","sibling old"))+shape(7,"Root","root old")
        let after=shape(7,"Root","root new")+group(10,"Outer",shape(6,"Sibling","sibling new")+group(20,"Inner",shape(3,"Beta","beta new")+shape(2,"Alpha","alpha new")+shape(5,"Added","accepted addition")))
        let base=try deck(before),destination=try deck(after);var review=try PresentationRevisionReview(base:base,destination:destination)
        XCTAssertFalse(review.changes.contains{$0.kind == .slideEnvironment});XCTAssertThrowsError(try review.exported())
        review.decideAll(accept:false)
        for (kind,name,path) in [(PresentationRevisionChange.Kind.shapeChanged,"Alpha",["Outer","Inner"]),(.shapeChanged,"Sibling",["Outer"]),(.shapeChanged,"Root",[]),(.shapeAdded,"Added",["Outer","Inner"])] {
            review.decide(changeID:try change(review,kind,name:name,path:path).id,accept:true)
        }
        for path in [[],["Outer"],["Outer","Inner"]] {review.decide(changeID:try change(review,.shapeOrder,path:path).id,accept:true)}
        let xml=try document(review.exported()),outer=try named(xml,"Outer"),inner=try named(xml,"Inner")
        XCTAssertEqual(objectNames(try XCTUnwrap(try nodes(xml,"spTree").first)),["Root","Outer"])
        XCTAssertEqual(objectNames(outer),["Sibling","Inner"])
        let children=objectNames(inner);XCTAssertEqual(Set(children),["Alpha","Beta","Removed","Added"])
        XCTAssertLessThan(try XCTUnwrap(children.firstIndex(of:"Beta")),try XCTUnwrap(children.firstIndex(of:"Alpha")))
        XCTAssertLessThan(try XCTUnwrap(children.firstIndex(of:"Alpha")),try XCTUnwrap(children.firstIndex(of:"Added")))
        XCTAssertEqual(try text(try named(xml,"Alpha")),"alpha new");XCTAssertEqual(try text(try named(xml,"Beta")),"beta old")
        XCTAssertEqual(try text(try named(xml,"Removed")),"retained deletion")
        let decisions=review.decisions;review.undo();XCTAssertTrue(review.canRedo);review.redo();XCTAssertEqual(review.decisions,decisions)
        XCTAssertEqual(try unzip(review.exported(),member:"custom/opaque.bin"),Data([0,255,7,10]))
    }

    func testRegeneratedIDsAreMatchedWithinEachParentWhileDuplicatesStayAmbiguous()throws {
        let base=try deck(group(10,"Left",shape(2,"Unit","left old"))+group(11,"Right",shape(3,"Unit","right old")))
        let destination=try deck(group(10,"Left",shape(20,"Unit","left new"))+group(11,"Right",shape(30,"Unit","right new")))
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        XCTAssertEqual(review.changes.filter{$0.kind == .shapeChanged}.count,2)
        review.decide(changeID:try change(review,.shapeChanged,name:"Unit",path:["Left"]).id,accept:true)
        let xml=try document(review.exported())
        XCTAssertEqual(try text(try named(xml,"Left")),"left new");XCTAssertEqual(try text(try named(xml,"Right")),"right old")
        let duplicates=try deck(group(10,"Assembly",shape(2,"Duplicate","same")+shape(3,"Duplicate","same")))
        let regenerated=try deck(group(10,"Assembly",shape(20,"Duplicate","same")+shape(30,"Duplicate","same")))
        let ambiguous=try PresentationRevisionReview(base:duplicates,destination:regenerated)
        XCTAssertEqual(ambiguous.changes.filter{$0.kind == .shapeDeleted && $0.groupPath==["Assembly"]}.count,2)
        XCTAssertEqual(ambiguous.changes.filter{$0.kind == .shapeAdded && $0.groupPath==["Assembly"]}.count,2)
        XCTAssertFalse(ambiguous.changes.contains{$0.kind == .shapeChanged})
    }

    func testChangedNestedGroupShellIsAtomicWithoutPretendingItsChildrenAreIndependent()throws {
        let base=try deck(group(10,"Outer",group(20,"Inner",shape(2,"Child","old"),rotation:0))+shape(8,"Outside","outside old"))
        let destination=try deck(group(10,"Outer",group(20,"Inner",shape(2,"Child","new")+shape(3,"Added","new child"),rotation:6000000))+shape(8,"Outside","outside new"))
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        let shell=try change(review,.shapeChanged,name:"Inner",path:["Outer"])
        XCTAssertFalse(review.changes.contains{$0.groupPath==["Outer","Inner"]})
        review.decide(changeID:shell.id,accept:true)
        let xml=try document(review.exported()),inner=try named(xml,"Inner")
        XCTAssertEqual(try text(inner),"new\nnew child");XCTAssertEqual(try text(try named(xml,"Outside")),"outside old")
        XCTAssertEqual(try nodes(inner,"xfrm").first?.attribute(forName:"rot")?.stringValue,"6000000")
        review.decide(changeID:shell.id,accept:false);review.decide(changeID:try change(review,.shapeChanged,name:"Outside").id,accept:true)
        let rejected=try document(review.exported());XCTAssertEqual(try text(try named(rejected,"Inner")),"old")
        XCTAssertEqual(try nodes(try named(rejected,"Inner"),"xfrm").first?.attribute(forName:"rot")?.stringValue,"0")
    }

    func testNestedPictureImportsItsOwnMediaWithoutRetargetingRetainedAnchorPicture()throws {
        let content=group(10,"Outer",group(20,"Inner",picture(2,"Changed picture","image"))+picture(3,"Retained picture","keep"))+shape(8,"Label","label old")
        let next=content.replacingOccurrences(of:"label old",with:"label new")
        let rels=edge("image","image","../media/image.png")+edge("keep","image","../media/keep.png")
        let base=try deck(content,media:["ppt/media/image.png":Data([1,2,3]),"ppt/media/keep.png":Data([7,8])],extraRelationships:rels)
        let destination=try deck(next,media:["ppt/media/image.png":Data([4,5,6]),"ppt/media/keep.png":Data([7,8])],extraRelationships:rels)
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        review.decide(changeID:try change(review,.shapeChanged,name:"Changed picture",path:["Outer","Inner"]).id,accept:true)
        let output=try review.exported(),xml=try document(output)
        let relationships=try XMLDocument(data:unzip(output,member:"ppt/slides/_rels/slide256.xml.rels"),options:[])
        for (name,expected) in [("Changed picture",Data([4,5,6])),("Retained picture",Data([7,8]))] {
            let blip=try XCTUnwrap(try nodes(try named(xml,name),"blip").first)
            let id=try XCTUnwrap(blip.attributes?.first(where:{$0.localName=="embed"})?.stringValue)
            let relationship=try XCTUnwrap(try nodes(relationships,"Relationship").first{$0.attribute(forName:"Id")?.stringValue==id})
            let relative=try XCTUnwrap(relationship.attribute(forName:"Target")?.stringValue)
            let path=URL(fileURLWithPath:"/ppt/slides").appendingPathComponent(relative).standardizedFileURL.path
            XCTAssertEqual(try unzip(output,member:String(path.dropFirst())),expected)
        }
        XCTAssertEqual(try text(try named(xml,"Label")),"label old")
    }

    func testGlobalIDsAndInsideOutsideConnectorsFollowMixedRegeneratedChildren()throws {
        let base=try deck(group(10,"Assembly",shape(2,"Node A","old A")+shape(3,"Node B","old B")+connector(4,"Inside",2,3))+shape(8,"Outside","old outside")+connector(9,"External",2,8))
        let destination=try deck(group(10,"Assembly",shape(8,"Node A","new A")+shape(30,"Node B","new B")+connector(40,"Inside",8,30))+shape(80,"Outside","new outside")+connector(90,"External",8,80))
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        review.decide(changeID:try change(review,.shapeChanged,name:"Node A",path:["Assembly"]).id,accept:true)
        let xml=try document(review.exported()),ids=try uniqueIDs(xml)
        XCTAssertEqual(try text(try named(xml,"Node A")),"new A");XCTAssertEqual(try text(try named(xml,"Node B")),"old B")
        for (name,from,to) in [("Inside","Node A","Node B"),("External","Node A","Outside")] {
            let wire=try named(xml,name)
            XCTAssertEqual(try nodes(wire,"stCxn").first?.attribute(forName:"id")?.stringValue,ids[from])
            XCTAssertEqual(try nodes(wire,"endCxn").first?.attribute(forName:"id")?.stringValue,ids[to])
        }
        XCTAssertEqual(try text(try named(xml,"Outside")),"old outside")
    }

    func testCrossGroupMoveIsDeletePlusAddAndRetainedCopiesReceiveUniqueIDs()throws {
        let base=try deck(group(10,"Left",shape(2,"Moved","payload"))+group(20,"Right",""))
        let destination=try deck(group(10,"Left","")+group(20,"Right",shape(2,"Moved","payload")))
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        let removed=try change(review,.shapeDeleted,name:"Moved",path:["Left"]),added=try change(review,.shapeAdded,name:"Moved",path:["Right"])
        review.decide(changeID:added.id,accept:true)
        let copies=try document(review.exported());XCTAssertEqual(try text(try named(copies,"Left")),"payload");XCTAssertEqual(try text(try named(copies,"Right")),"payload");_=try uniqueIDs(copies)
        review.decide(changeID:added.id,accept:false);review.decide(changeID:removed.id,accept:true)
        let empty=try document(review.exported());XCTAssertTrue(objectNames(try named(empty,"Left")).isEmpty);XCTAssertTrue(objectNames(try named(empty,"Right")).isEmpty)
    }

    func testMixedDeletionCannotExportAConnectorToAnAbsentChild()throws {
        let base=try deck(group(10,"Assembly",shape(2,"Deleted","old")+shape(3,"Retained","same"))+connector(4,"External",2,3))
        let destination=try deck(group(10,"Assembly",shape(3,"Retained","same"))+connector(4,"External",3,3))
        var review=try PresentationRevisionReview(base:base,destination:destination);review.decideAll(accept:false)
        review.decide(changeID:try change(review,.shapeDeleted,name:"Deleted",path:["Assembly"]).id,accept:true)
        XCTAssertThrowsError(try review.exported(),"A mixed deck must not contain a connector targeting a removed child")
    }

    func testCompleteChoicesPreserveUnsignedPackagesIncludingNestedEmptyGroupsAndOpaqueParts()throws {
        let base=try deck(group(10,"Outer",group(20,"Inner",shape(2,"Child","old"))+group(30,"Empty","")))
        var destination=try deck(group(10,"Outer",group(20,"Inner",shape(2,"Child","new"))+group(30,"Empty","")))
        destination.entries["custom/opaque.bin"]=Data([1,0,255,4,5]);destination.entries["custom/new.bin"]=Data([99,0,7])
        var review=try PresentationRevisionReview(base:base,destination:destination)
        review.decideAll(accept:true);let accepted=try review.exported();XCTAssertEqual(accepted.entries,destination.entries)
        XCTAssertEqual(try unzip(accepted,member:slidePath),destination.entries[slidePath]);XCTAssertEqual(try unzip(accepted,member:"custom/new.bin"),Data([99,0,7]))
        review.decideAll(accept:false);let rejected=try review.exported();XCTAssertEqual(rejected.entries,base.entries)
        XCTAssertEqual(try unzip(rejected,member:slidePath),base.entries[slidePath]);XCTAssertNil(rejected.entries["custom/new.bin"])
    }
    func testOpaqueNestedAlternativesStayAtomicAndUnchangedForeignGroupContentSurvivesMixedExport()throws {
        func alternatives(_ value:String)->String {
            "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice Requires=\"p\">"+shape(3,"Choice",value)+"</mc:Choice><mc:Fallback>"+shape(4,"Fallback",value)+"</mc:Fallback></mc:AlternateContent>"
        }
        let base=try deck(group(10,"Outer",group(20,"Nested",shape(2,"Ordinary","same")+alternatives("old alternative")))+shape(8,"Outside","old outside"))
        let destination=try deck(group(10,"Outer",group(20,"Nested",shape(2,"Ordinary","same")+alternatives("new alternative")))+shape(8,"Outside","new outside"))
        var atomic=try PresentationRevisionReview(base:base,destination:destination)
        XCTAssertEqual(atomic.changes.filter{$0.kind == .slideEnvironment}.count,1)
        XCTAssertFalse(atomic.changes.contains{[PresentationRevisionChange.Kind.shapeChanged,.shapeAdded,.shapeDeleted,.shapeOrder].contains($0.kind)},"Opaque markup compatibility content must retain the whole-slide guard")
        atomic.decideAll(accept:true);let accepted=try atomic.exported()
        XCTAssertEqual(accepted.entries,destination.entries);XCTAssertEqual(try unzip(accepted,member:slidePath),destination.entries[slidePath])
        atomic.decideAll(accept:false);let rejected=try atomic.exported()
        XCTAssertEqual(rejected.entries,base.entries);XCTAssertEqual(try unzip(rejected,member:slidePath),base.entries[slidePath])

        let payload="<q:opaque xmlns:q=\"urn:turtlegit:test:opaque\" token=\"keep-exactly\"><q:nested q:key=\"retained\">  significant text  </q:nested><!--opaque comment--></q:opaque>"
        let opaque=group(20,"Opaque",shape(2,"Unchanged child","untouched")).replacingOccurrences(of:"</p:grpSp>",with:payload+"</p:grpSp>")
        let old=try deck(group(10,"Outer",opaque+shape(8,"Alpha","old alpha"))+shape(9,"Beta","old beta"))
        let next=try deck(group(10,"Outer",opaque+shape(8,"Alpha","new alpha"))+shape(9,"Beta","new beta"))
        var mixed=try PresentationRevisionReview(base:old,destination:next)
        XCTAssertFalse(mixed.changes.contains{$0.kind == .slideEnvironment})
        mixed.decideAll(accept:false);mixed.decide(changeID:try change(mixed,.shapeChanged,name:"Alpha",path:["Outer"]).id,accept:true)
        let output=try mixed.exported(),xml=try document(output),original=try document(old)
        XCTAssertEqual(try text(try named(xml,"Alpha")),"new alpha");XCTAssertEqual(try text(try named(xml,"Beta")),"old beta")
        let nodes=try self.nodes(try named(xml,"Opaque"),"opaque"),originalNodes=try self.nodes(try named(original,"Opaque"),"opaque")
        XCTAssertEqual(nodes.count,1);XCTAssertEqual(originalNodes.count,1)
        let saved=try XCTUnwrap(nodes.first),prior=try XCTUnwrap(originalNodes.first)
        XCTAssertEqual(saved.uri,"urn:turtlegit:test:opaque");XCTAssertEqual(saved.xmlString,prior.xmlString)
        XCTAssertEqual(try text(try named(xml,"Unchanged child")),"untouched")
        _=try uniqueIDs(xml)
    }

}
