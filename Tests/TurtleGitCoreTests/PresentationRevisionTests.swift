import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import TurtleGitCore

final class PresentationRevisionTests:XCTestCase {
    private let p="http://schemas.openxmlformats.org/presentationml/2006/main",a="http://schemas.openxmlformats.org/drawingml/2006/main",r="http://schemas.openxmlformats.org/officeDocument/2006/relationships",rel="http://schemas.openxmlformats.org/package/2006/relationships"
    private func bytes(_ text:String)->Data {Data(text.utf8)}
    private func shape(_ id:Int,_ text:String)->String {"<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Shape \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"}
    private func tree(_ content:String)->String {"<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"+content+"</p:spTree>"}
    private func slide(_ content:String,_ tail:String="")->Data {bytes("<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld>"+tree(content)+"</p:cSld>"+tail+"</p:sld>")}
    private func relationships(_ body:String)->Data {bytes("<Relationships xmlns=\"\(rel)\">"+body+"</Relationships>")}
    private func edge(_ id:String,_ type:String,_ target:String,_ mode:String="")->String {"<Relationship Id=\"\(id)\" Type=\"\(r)/\(type)\" Target=\"\(target)\"\(mode)/>"}
    private func package(_ slides:[(Int,String)],macro:Bool=false)throws->PresentationPackage {
        var entries:[String:Data]=[:]
        let main=macro ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml":"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
        var types="<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"bin\" ContentType=\"application/octet-stream\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(main)\"/>"
        for (id,content) in slides {
            types += "<Override PartName=\"/ppt/slides/slide\(id).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            entries["ppt/slides/slide\(id).xml"]=slide(content)
            entries["ppt/slides/_rels/slide\(id).xml.rels"]=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml"))
        }
        for (path,type) in [("slideLayouts/layout.xml","slideLayout"),("slideMasters/master.xml","slideMaster"),("theme/theme.xml","theme")] {types += "<Override PartName=\"/ppt/\(path)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\(type)+xml\"/>"}
        entries["[Content_Types].xml"]=bytes(types.replacingOccurrences(of:"application/vnd.openxmlformats-officedocument.presentationml.theme+xml",with:"application/vnd.openxmlformats-officedocument.theme+xml")+"</Types>")
        entries["_rels/.rels"]=relationships(edge("office","officeDocument","ppt/presentation.xml"))
        entries["ppt/presentation.xml"]=bytes("<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>"+slides.map{"<p:sldId id=\"\($0.0)\" r:id=\"s\($0.0)\"/>"}.joined()+"</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        entries["ppt/_rels/presentation.xml.rels"]=relationships(edge("master","slideMaster","slideMasters/master.xml")+slides.map{edge("s\($0.0)","slide","slides/slide\($0.0).xml")}.joined()+(macro ? edge("vba","vbaProject","vbaProject.bin"):""))
        entries["ppt/slideLayouts/layout.xml"]=bytes("<p:sldLayout xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld>"+tree("")+"</p:cSld></p:sldLayout>")
        entries["ppt/slideLayouts/_rels/layout.xml.rels"]=relationships(edge("master","slideMaster","../slideMasters/master.xml"))
        entries["ppt/slideMasters/master.xml"]=bytes("<p:sldMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld>"+tree("")+"</p:cSld><p:sldLayoutIdLst><p:sldLayoutId id=\"1\" r:id=\"layout\"/></p:sldLayoutIdLst></p:sldMaster>")
        entries["ppt/slideMasters/_rels/master.xml.rels"]=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("theme","theme","../theme/theme.xml"))
        entries["ppt/theme/theme.xml"]=bytes("<a:theme xmlns:a=\"\(a)\" name=\"Fixture theme\"><a:themeElements/></a:theme>")
        entries["custom/opaque.bin"]=Data([0,255,10,3])
        if macro {entries["ppt/vbaProject.bin"]=Data([0,1,255,2])}
        return try PresentationPackage(entries:entries)
    }
    private func changed(_ package:PresentationPackage,_ path:String,_ text:String)throws->PresentationPackage {var entries=package.entries;entries[path]=bytes(text);return try .init(entries:entries)}
    private func manifest(_ package:PresentationPackage)throws->PresentationSlideManifest {try PresentationRevisionReview(base:package,destination:package).baseManifest}
    private func all(_ base:PresentationPackage,_ new:PresentationPackage,_ accept:Bool)throws->PresentationPackage {var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:accept);return try review.exported()}

    func testGranularShapesRequireDecisionsAndUndoRedoExportsEditableContent()throws {
        let base=try package([(256,shape(2,"old two")+shape(3,"old three"))]),new=try package([(256,shape(2,"new two")+shape(3,"new three"))])
        var review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertEqual(review.changes.map(\.kind),[.shapeChanged,.shapeChanged]);XCTAssertEqual(review.unresolvedCount,2)
        XCTAssertThrowsError(try review.exported());XCTAssertFalse(review.isDirty)
        review.decide(changeID:review.changes[0].id,accept:true);review.decide(changeID:review.changes[1].id,accept:false)
        XCTAssertTrue(review.canUndo);XCTAssertEqual(review.unresolvedCount,0)
        let result=try review.exported(),text=try manifest(result).slides[0].text
        XCTAssertTrue(text.contains("new two"));XCTAssertTrue(text.contains("old three"));XCTAssertFalse(text.contains("new three"))
        XCTAssertEqual(result.entries["custom/opaque.bin"],base.entries["custom/opaque.bin"])
        review.undo();XCTAssertEqual(review.unresolvedCount,1);XCTAssertTrue(review.canRedo)
        review.redo();XCTAssertEqual(review.unresolvedCount,0);review.undo();review.undo();XCTAssertFalse(review.isDirty)
        review.decideAll(accept:false);XCTAssertFalse(review.canRedo);XCTAssertEqual(try manifest(review.exported()).slides[0].text,"old two\nold three")
    }
    func testAddedDeletedMovedSlidesAndShapeStackingChoices()throws {
        let base=try package([(256,shape(2,"A")+shape(3,"B")),(257,shape(2,"deleted")),(258,shape(2,"last"))])
        let new=try package([(258,shape(2,"last")),(256,shape(3,"B")+shape(2,"A")),(259,shape(2,"added"))])
        var review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertTrue(review.changes.contains{$0.kind == .slideAdded});XCTAssertTrue(review.changes.contains{$0.kind == .slideDeleted});XCTAssertTrue(review.changes.contains{$0.kind == .slideMoved});XCTAssertTrue(review.changes.contains{$0.kind == .shapeOrder})
        review.decideAll(accept:true)
        for change in review.changes where change.kind == .slideDeleted {review.decide(changeID:change.id,accept:false)}
        let result=try manifest(review.exported())
        XCTAssertEqual(Set(result.slides.compactMap(\.stableID)),["256","257","258","259"])
        XCTAssertEqual(result.slides.first?.stableID,"258");XCTAssertEqual(result.slides.first{$0.stableID=="256"}?.text,"B\nA")
    }
    func testSameRelationshipIDWithChangedMediaIsARealShapeChangeAndImportsCollisionSafely()throws {
        let picture="<p:pic><p:nvPicPr><p:cNvPr id=\"3\" name=\"Picture\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"image\"/></p:blipFill><p:spPr/></p:pic>"
        var a=try package([(256,shape(2,"old")+picture)]).entries,b=try package([(256,shape(2,"new")+picture)]).entries
        a["ppt/media/image.png"]=Data([1,2,3]);b["ppt/media/image.png"]=Data([4,5,6])
        let rels=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("image","image","../media/image.png"))
        a["ppt/slides/_rels/slide256.xml.rels"]=rels;b["ppt/slides/_rels/slide256.xml.rels"]=rels
        var review=try PresentationRevisionReview(base:.init(entries:a),destination:.init(entries:b))
        XCTAssertEqual(review.changes.count,2);XCTAssertEqual(review.changes.filter{$0.title.contains("Picture")}.count,1)
        review.decideAll(accept:false);review.decide(changeID:review.changes.first{$0.title.contains("Picture")}!.id,accept:true)
        let output=try review.exported()
        XCTAssertEqual(output.entries["ppt/media/image.png"],Data([1,2,3]));XCTAssertTrue(output.entries.contains{$0.key.hasPrefix("ppt/media/turtlegit-") && $0.value==Data([4,5,6])})
        XCTAssertEqual(try manifest(output).slides[0].text,"old")
        let relData=try XCTUnwrap(output.entries["ppt/slides/_rels/slide256.xml.rels"])
        XCTAssertTrue(String(decoding:relData,as:UTF8.self).contains("rIdTurtleGit"))
    }
    func testWholeSlideEnvironmentImportsCyclicLayoutMasterThemeGraphs()throws {
        let base=try package([(256,shape(2,"old")),(257,shape(2,"other old"))])
        var new=try package([(256,shape(2,"new")),(257,shape(2,"other new"))]).entries
        new["ppt/slideLayouts/layout.xml"]=bytes(String(decoding:new["ppt/slideLayouts/layout.xml"]!,as:UTF8.self).replacingOccurrences(of:"<p:cSld>",with:"<p:cSld name=\"New layout\">"))
        var review=try PresentationRevisionReview(base:base,destination:.init(entries:new))
        XCTAssertTrue(review.changes.contains{$0.kind == .slideEnvironment})
        review.decideAll(accept:false);review.decide(changeID:review.changes.first{$0.destinationSlideIndex==0}!.id,accept:true)
        let output=try review.exported()
        XCTAssertTrue(output.entries.keys.contains{$0.hasPrefix("ppt/slideMasters/turtlegit-")})
        XCTAssertTrue(output.entries.keys.contains{$0.hasPrefix("ppt/slideLayouts/turtlegit-")})
        XCTAssertTrue(String(decoding:output.entries["ppt/presentation.xml"]!,as:UTF8.self).contains("2147483649"))
        XCTAssertEqual(try manifest(output).slides.map(\.text),["new","other old"])
    }
    func testNotesAndTimingAreAtomicAndMacrosPreserveRequiredExtension()throws {
        let base=try package([(256,shape(2,"old"))],macro:true)
        var new=try package([(256,shape(2,"new"))],macro:true).entries
        new["ppt/slides/slide256.xml"]=slide(shape(2,"new"),"<p:timing/>")
        new["ppt/slides/_rels/slide256.xml.rels"]=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("notes","notesSlide","../notesSlides/n.xml"))
        new["ppt/notesSlides/n.xml"]=bytes("<p:notes xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld>"+tree(shape(2,"speaker notes"))+"</p:cSld></p:notes>")
        new["ppt/notesSlides/_rels/n.xml.rels"]=relationships(edge("slide","slide","../slides/slide256.xml"))
        var review=try PresentationRevisionReview(base:base,destination:.init(entries:new))
        XCTAssertEqual(review.requiredFileExtension,"pptm");XCTAssertTrue(review.destinationManifest.slides[0].notes.contains("speaker notes"));XCTAssertTrue(review.changes.contains{$0.kind == .slideEnvironment})
        review.decideAll(accept:true);let output=try review.exported()
        XCTAssertEqual(output.entries["ppt/vbaProject.bin"],base.entries["ppt/vbaProject.bin"])
        XCTAssertTrue(String(decoding:output.entries["[Content_Types].xml"]!,as:UTF8.self).contains("macroEnabled.main+xml"))
    }
    func testPackageSignatureGraphRemovedWithExplicitNoticeAndNoOpaqueLoss()throws {
        var entries=try package([(256,shape(2,"text"))]).entries
        entries["_rels/.rels"]=relationships(edge("office","officeDocument","ppt/presentation.xml")+"<Relationship Id=\"signature\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/digital-signature/origin\" Target=\"signatures/origin.bin\"/>")
        entries["signatures/origin.bin"]=Data([1]);entries["signatures/signature.xml"]=bytes("<Signature/>")
        entries["signatures/_rels/origin.bin.rels"]=relationships("<Relationship Id=\"sig\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/digital-signature/signature\" Target=\"signature.xml\"/>")
        let package=try PresentationPackage(entries:entries),review=try PresentationRevisionReview(base:package,destination:package)
        XCTAssertTrue(review.invalidatesDigitalSignatures);XCTAssertFalse(review.notices.isEmpty)
        let output=try review.exported()
        XCTAssertNil(output.entries["signatures/origin.bin"]);XCTAssertNil(output.entries["signatures/signature.xml"])
        XCTAssertEqual(output.entries["custom/opaque.bin"],entries["custom/opaque.bin"])
    }
    func testRejectsMalformedRelationshipsDTDsNamespacesAndBudgets()throws {
        let valid=try package([(256,shape(2,"text"))])
        for xml in ["<!DOCTYPE x [<!ENTITY x 'expanded'>]><p:sld xmlns:p=\"\(p)\"/>","<sld xmlns=\"wrong\"/>",String(repeating:"<x>",count:140)+String(repeating:"</x>",count:140)] {
            let bad=try changed(valid,"ppt/slides/slide256.xml",xml)
            XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:bad))
        }
        var missing=valid.entries;missing["ppt/slides/_rels/slide256.xml.rels"]=relationships(edge("x","image","%2e%2e/%2e%2e/%2e%2e/escape.bin"))
        XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:.init(entries:missing)))
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:valid,cancellation:token))
    }
    func testMixedConnectorDeletionIsRefusedAndCompleteRevisionRemainsAvailable()throws {
        let connector="<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"4\" name=\"Connector\"/><p:cNvCxnSpPr><a:stCxn id=\"2\" idx=\"0\"/><a:endCxn id=\"3\" idx=\"0\"/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>"
        let base=try package([(256,shape(2,"A")+shape(3,"B")+connector)]),new=try package([(256,shape(2,"A changed"))])
        var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:false)
        review.decide(changeID:review.changes.first{$0.kind == .shapeDeleted && $0.title.contains("Shape 3")}!.id,accept:true)
        XCTAssertThrowsError(try review.exported())
        review.decideAll(accept:true);XCTAssertEqual(try manifest(review.exported()).slides[0].text,"A changed")
    }
    func testExternalReferencesStayReferencesWithoutFetching()throws {
        var a=try package([(256,shape(2,"old")+shape(3,"base"))]).entries,b=try package([(256,shape(2,"new")+shape(3,"base"))]).entries
        let linked=shape(2,"new").replacingOccurrences(of:"<a:r>",with:"<a:r><a:rPr><a:hlinkClick r:id=\"web\"/></a:rPr>")
        b["ppt/slides/slide256.xml"]=slide(linked+shape(3,"new second"))
        b["ppt/slides/_rels/slide256.xml.rels"]=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("web","hyperlink","https://example.invalid/external", " TargetMode=\"External\""))
        a["custom/opaque.bin"]=Data([7]);b["custom/opaque.bin"]=Data([8])
        var review=try PresentationRevisionReview(base:.init(entries:a),destination:.init(entries:b));review.decideAll(accept:false)
        review.decide(changeID:review.changes.first{$0.kind == .shapeChanged && $0.title.contains("Shape 2")}!.id,accept:true)
        let out=try review.exported(),rels=String(decoding:out.entries["ppt/slides/_rels/slide256.xml.rels"]!,as:UTF8.self)
        XCTAssertTrue(rels.contains("https://example.invalid/external"));XCTAssertTrue(rels.contains("External"));XCTAssertEqual(out.entries["custom/opaque.bin"],Data([7]))
    }
    func testMixedCommentRegistryIsExplicitlyRefusedAndCompleteNewPreservesAuthors()throws {
        let base=try package([(256,shape(2,"old")),(257,shape(2,"old second"))])
        var entries=try package([(256,shape(2,"new")),(257,shape(2,"new second"))]).entries
        entries["ppt/slides/_rels/slide256.xml.rels"]=relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("comments","comments","../comments/comment.xml"))
        entries["ppt/_rels/presentation.xml.rels"]=relationships(edge("master","slideMaster","slideMasters/master.xml")+edge("s256","slide","slides/slide256.xml")+edge("s257","slide","slides/slide257.xml")+edge("authors","commentAuthors","commentAuthors.xml"))
        entries["ppt/comments/comment.xml"]=bytes("<p:cmLst xmlns:p=\"\(p)\"><p:cm authorId=\"7\" idx=\"1\"><p:text>Review note</p:text></p:cm></p:cmLst>")
        entries["ppt/commentAuthors.xml"]=bytes("<p:cmAuthorLst xmlns:p=\"\(p)\"><p:cmAuthor id=\"7\" name=\"Reviewer\" initials=\"R\" lastIdx=\"1\" clrIdx=\"0\"/></p:cmAuthorLst>")
        let types=String(decoding:entries["[Content_Types].xml"]!,as:UTF8.self).replacingOccurrences(of:"</Types>",with:"<Override PartName=\"/ppt/comments/comment.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.comments+xml\"/><Override PartName=\"/ppt/commentAuthors.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml\"/></Types>")
        entries["[Content_Types].xml"]=bytes(types)
        var review=try PresentationRevisionReview(base:base,destination:.init(entries:entries));review.decideAll(accept:true)
        let output=try review.exported()
        XCTAssertEqual(output.entries["ppt/commentAuthors.xml"],entries["ppt/commentAuthors.xml"]);XCTAssertEqual(output.entries["ppt/comments/comment.xml"],entries["ppt/comments/comment.xml"])
        review.decide(changeID:review.changes.first{$0.kind == .presentation}!.id,accept:false)
        XCTAssertThrowsError(try review.exported()){error in XCTAssertTrue(error.localizedDescription.contains("comment/author"))}
    }
    func testDeletingCustomShowSlideRequiresConsistentPresentationDecision()throws {
        var entries=try package([(256,shape(2,"old")),(257,shape(2,"show slide"))]).entries
        entries["ppt/presentation.xml"]=bytes(String(decoding:entries["ppt/presentation.xml"]!,as:UTF8.self).replacingOccurrences(of:"</p:presentation>",with:"<p:custShowLst><p:custShow name=\"Show\" id=\"1\"><p:sldLst><p:sld r:id=\"s257\"/></p:sldLst></p:custShow></p:custShowLst></p:presentation>"))
        let base=try PresentationPackage(entries:entries),new=try package([(256,shape(2,"new"))])
        var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:true)
        review.decide(changeID:review.changes.first{$0.kind == .presentation}!.id,accept:false)
        XCTAssertThrowsError(try review.exported()){error in XCTAssertTrue(error.localizedDescription.contains("custom show"))}
        review.decideAll(accept:true);XCTAssertEqual(try manifest(review.exported()).slides.map(\.text),["new"])
    }

    func testCompleteUnsignedRevisionExportPreservesEveryMemberByteAndHasNoNewChanges()throws {
        for macro in [false,true] {
            let base=try package([(256,shape(2,"old"))],macro:macro)
            let plain=try package([(256,shape(2,"new"))],macro:macro)
            // Exercise both absent declarations and explicitly declared metadata.
            var entries=plain.entries
            entries["docProps/custom.xml"]=bytes("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<properties>  <value>New metadata</value> </properties>\n")
            let new=try PresentationPackage(entries:entries)
            var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:true)
            let accepted=try review.exported()
            XCTAssertEqual(accepted.entries,new.entries)
            XCTAssertTrue(try PresentationRevisionReview(base:new,destination:accepted).changes.isEmpty)
            review.decideAll(accept:false);let rejected=try review.exported()
            XCTAssertEqual(rejected.entries,base.entries)
            XCTAssertTrue(try PresentationRevisionReview(base:base,destination:rejected).changes.isEmpty)
            XCTAssertTrue(review.changes.contains{$0.kind == .presentation},"Real metadata differences must remain reviewable")
        }
    }

}
