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

    private func renamedShape(_ id:Int,_ text:String,_ name:String)->String {shape(id,text).replacingOccurrences(of:"name=\"Shape \(id)\"",with:"name=\"\(name)\"")}
    private func withComments(_ package:PresentationPackage,authors:[(Int,String)],comments:[(Int,Int,Int,String)],usingDefault:Bool=false)throws->PresentationPackage {
        var entries=package.entries
        let authorsXML="<p:cmAuthorLst xmlns:p=\"\(p)\">"+authors.map{"<p:cmAuthor id=\"\($0.0)\" name=\"\($0.1)\" initials=\"R\" lastIdx=\"2\" clrIdx=\"0\"/>"}.joined()+"</p:cmAuthorLst>"
        entries["ppt/commentAuthors.xml"]=bytes(authorsXML)
        let presRel="ppt/_rels/presentation.xml.rels"
        entries[presRel]=bytes(String(decoding:entries[presRel]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:edge("authors","commentAuthors","commentAuthors.xml")+"</Relationships>"))
        var types=String(decoding:entries["[Content_Types].xml"]!,as:UTF8.self).replacingOccurrences(of:"</Types>",with:"<Override PartName=\"/ppt/commentAuthors.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml\"/></Types>")
        if usingDefault {types=types.replacingOccurrences(of:"</Types>",with:"<Default Extension=\"comments\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.comments+xml\"/></Types>")}
        for (slideID,author,index,text) in comments {
            let path="ppt/comments/c\(slideID)."+(usingDefault ? "comments":"xml")
            entries[path]=bytes("<p:cmLst xmlns:p=\"\(p)\"><p:cm authorId=\"\(author)\" idx=\"\(index)\"><p:pos x=\"0\" y=\"0\"/><p:text>\(text)</p:text></p:cm></p:cmLst>")
            let relPath="ppt/slides/_rels/slide\(slideID).xml.rels"
            entries[relPath]=bytes(String(decoding:entries[relPath]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:edge("comments","comments","../comments/"+(path as NSString).lastPathComponent)+"</Relationships>"))
            if !usingDefault {types=types.replacingOccurrences(of:"</Types>",with:"<Override PartName=\"/\(path)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.comments+xml\"/></Types>")}
        }
        entries["[Content_Types].xml"]=bytes(types);return try .init(entries:entries)
    }
    private func withNotes(_ package:PresentationPackage,slideID:Int,text:String,master:String,masterDefault:Bool=false)throws->PresentationPackage {
        var entries=package.entries
        let notePath="ppt/notesSlides/n\(slideID).xml",masterPath="ppt/notesMasters/"+master
        entries[notePath]=bytes("<p:notes xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld>"+tree(shape(2,text))+"</p:cSld></p:notes>")
        entries["ppt/notesSlides/_rels/n\(slideID).xml.rels"]=relationships(edge("slide","slide","../slides/slide\(slideID).xml")+edge("master","notesMaster","../notesMasters/"+master))
        entries[masterPath]=bytes("<p:notesMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld>"+tree("")+"</p:cSld></p:notesMaster>")
        let slideRel="ppt/slides/_rels/slide\(slideID).xml.rels"
        entries[slideRel]=bytes(String(decoding:entries[slideRel]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:edge("notes","notesSlide","../notesSlides/n\(slideID).xml")+"</Relationships>"))
        let presRel="ppt/_rels/presentation.xml.rels"
        entries[presRel]=bytes(String(decoding:entries[presRel]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:edge("notesMaster","notesMaster","notesMasters/"+master)+"</Relationships>"))
        entries["ppt/presentation.xml"]=bytes(String(decoding:entries["ppt/presentation.xml"]!,as:UTF8.self).replacingOccurrences(of:"<p:sldIdLst>",with:"<p:notesMasterIdLst><p:notesMasterId r:id=\"notesMaster\"/></p:notesMasterIdLst><p:sldIdLst>"))
        let masterType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"
        let masterDeclaration=masterDefault ? "<Default Extension=\"\((master as NSString).pathExtension)\" ContentType=\"\(masterType)\"/>":"<Override PartName=\"/\(masterPath)\" ContentType=\"\(masterType)\"/>"
        entries["[Content_Types].xml"]=bytes(String(decoding:entries["[Content_Types].xml"]!,as:UTF8.self).replacingOccurrences(of:"</Types>",with:masterDeclaration+"<Override PartName=\"/\(notePath)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/></Types>"))
        return try .init(entries:entries)
    }
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
    func testMixedClassicCommentsCreateAuthorRegistryAndCompleteNewPreservesAuthors()throws {
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
        review.decide(changeID:review.changes.first{$0.kind == .shapeChanged && $0.destinationSlideIndex==1}!.id,accept:false)
        let mixed=try review.exported()
        XCTAssertTrue(mixed.entries.keys.contains{$0.hasPrefix("ppt/comments/turtlegit-")})
        XCTAssertTrue(mixed.entries.keys.contains{$0.hasPrefix("ppt/turtlegit-") && $0.hasSuffix("commentAuthors.xml")})
        XCTAssertEqual(try manifest(mixed).slides.map(\.text),["new","old second"])
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

    func testRegeneratedSlideAndShapeIDsRecoverExactIdentityWithoutOrdinalPairing()throws {
        let base=try package([(256,renamedShape(2,"Alpha release plan","Title")+renamedShape(3,"Stable second block","Body"))])
        let new=try package([(900,renamedShape(22,"Alpha release plan","Title")+renamedShape(33,"Stable second block","Body"))])
        let review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertTrue(review.changes.isEmpty)
        XCTAssertEqual(review.destinationManifest.slides[0].stableID,"256")
        XCTAssertEqual(try review.exported().entries,new.entries)
    }
    func testTrustworthyRegeneratedIDSimilarityRetainsIndependentMixedShapeChoices()throws {
        let first="Plan the next release with a stable schedule and a careful team review"
        let second="Track the release work with clear tasks and a careful quality review"
        let base=try package([(256,renamedShape(2,first,"Release title")+renamedShape(3,second,"Progress block"))])
        let new=try package([(900,renamedShape(22,first.replacingOccurrences(of:"schedule",with:"calendar"),"Release title")+renamedShape(33,second.replacingOccurrences(of:"quality",with:"final"),"Progress block"))])
        var review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertEqual(review.changes.filter{$0.kind == .shapeChanged}.count,2)
        XCTAssertFalse(review.changes.contains{$0.kind == .slideAdded || $0.kind == .slideDeleted})
        review.decideAll(accept:false);review.decide(changeID:review.changes.first{$0.title.contains("Release title")}!.id,accept:true)
        let result=try review.exported(),text=try manifest(result).slides[0].text
        XCTAssertTrue(text.contains("calendar"));XCTAssertTrue(text.contains(second));XCTAssertFalse(text.contains("final"))
        let xml=String(decoding:result.entries["ppt/slides/slide256.xml"]!,as:UTF8.self)
        XCTAssertTrue(xml.contains("id=\"2\""));XCTAssertTrue(xml.contains("id=\"3\""))
    }
    func testAmbiguousRegeneratedSlidesAndShapesRemainDeleteAdd()throws {
        let duplicate=renamedShape(2,"Same repeated slide title","Title")
        let old=try package([(256,duplicate),(257,duplicate)]),new=try package([(900,duplicate),(901,duplicate)])
        let slides=try PresentationRevisionReview(base:old,destination:new)
        XCTAssertEqual(slides.changes.filter{$0.kind == .slideDeleted}.count,2);XCTAssertEqual(slides.changes.filter{$0.kind == .slideAdded}.count,2)
        let a=try package([(256,renamedShape(2,"Repeated content","Repeated")+renamedShape(3,"Repeated content","Repeated"))])
        let b=try package([(256,renamedShape(22,"Repeated content","Repeated")+renamedShape(33,"Repeated content","Repeated"))])
        let shapes=try PresentationRevisionReview(base:a,destination:b)
        XCTAssertEqual(shapes.changes.filter{$0.kind == .shapeDeleted}.count,2);XCTAssertEqual(shapes.changes.filter{$0.kind == .shapeAdded}.count,2)
    }
    func testImportedGroupChildIDCollisionsAndCrossSourceConnectorEndpointsAreRemapped()throws {
        func group(_ id:Int,_ aID:Int,_ bID:Int,_ rotation:Int)->String {"<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"Assembly\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm rot=\"\(rotation)\"/></p:grpSpPr>"+renamedShape(aID,"First item","Child A")+renamedShape(bID,"Second item","Child B")+"</p:grpSp>"}
        func connector(_ id:Int,_ aID:Int,_ bID:Int)->String {"<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"Wire\"/><p:cNvCxnSpPr><a:stCxn id=\"\(aID)\" idx=\"0\"/><a:endCxn id=\"\(bID)\" idx=\"0\"/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>"}
        let base=try package([(256,group(2,3,4,0)+connector(5,3,4)+renamedShape(6,"last old value","Label"))])
        let new=try package([(256,group(20,6,7,10)+connector(50,6,7)+renamedShape(60,"last new value","Label"))])
        var review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertFalse(review.changes.contains{$0.kind == .slideEnvironment})
        review.decideAll(accept:false);review.decide(changeID:review.changes.first{$0.title.contains("Assembly")}!.id,accept:true)
        let result=try review.exported(),xml=try XMLDocument(data:result.entries["ppt/slides/slide256.xml"]!,options:[])
        let all=try xml.nodes(forXPath:"//*[local-name()='cNvPr']").compactMap{($0 as? XMLElement)?.attribute(forName:"id")?.stringValue}
        XCTAssertEqual(Set(all).count,all.count)
        let targets=try xml.nodes(forXPath:"//*[local-name()='stCxn' or local-name()='endCxn']").compactMap{($0 as? XMLElement)?.attribute(forName:"id")?.stringValue}
        XCTAssertTrue(targets.allSatisfy{all.contains($0)})
        let childA=try xml.nodes(forXPath:"//*[local-name()='cNvPr' and @name='Child A']").compactMap{($0 as? XMLElement)?.attribute(forName:"id")?.stringValue}
        let childB=try xml.nodes(forXPath:"//*[local-name()='cNvPr' and @name='Child B']").compactMap{($0 as? XMLElement)?.attribute(forName:"id")?.stringValue}
        XCTAssertEqual(childA.count,1);XCTAssertEqual(childB.count,1)
        let aID=try XCTUnwrap(childA.first),bID=try XCTUnwrap(childB.first)
        XCTAssertNotEqual(aID,bID);XCTAssertEqual(targets,[aID,bID])
        XCTAssertTrue(try manifest(result).slides[0].text.contains("last old value"))
    }
    func testMixedClassicCommentsMergeCollidingAuthorIDsAndReserveDefaultTypedIndices()throws {
        let a=try package([(256,shape(2,"old one")),(257,shape(2,"old two"))]),b=try package([(256,shape(2,"new one")),(257,shape(2,"new two"))])
        let base=try withComments(a,authors:[(0,"Alice")],comments:[(256,0,1,"Base comment"),(257,0,2,"Retained comment")],usingDefault:true)
        let new=try withComments(b,authors:[(0,"Bob")],comments:[(256,0,1,"New comment"),(257,0,2,"New second comment")],usingDefault:true)
        var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:false)
        let comment=try XCTUnwrap(review.changes.first{$0.kind == .commentChanged && $0.destinationSlideIndex==0})
        review.decide(changeID:comment.id,accept:true)
        let result=try review.exported(),inventory=try PresentationRevisionReview(base:result,destination:result)
        XCTAssertEqual(Set(inventory.baseComments.map(\.text)),Set(["New comment","Retained comment"]))
        XCTAssertEqual(Set(inventory.baseComments.map(\.author)),Set(["Alice","Bob"]))
        XCTAssertEqual(try manifest(result).slides.map(\.text),["old one","old two"],"Comment decisions must not silently choose shape changes")
        let sameAuthor=try withComments(b,authors:[(0,"Alice")],comments:[(256,0,1,"Changed comment"),(257,0,2,"Changed second")],usingDefault:true)
        var same=try PresentationRevisionReview(base:base,destination:sameAuthor);same.decideAll(accept:false)
        same.decide(changeID:same.changes.first{$0.kind == .commentChanged && $0.destinationSlideIndex==0}!.id,accept:true)
        let combined=try same.exported(),read=try PresentationRevisionReview(base:combined,destination:combined)
        XCTAssertEqual(read.baseComments.count,2);XCTAssertEqual(Set(read.baseComments.map(\.author)),Set(["Alice"]))
        // Inspect the package contract, independently of XML quote style or
        // generated registry filenames. One logical author owns both indexes.
        let typeDoc=try XMLDocument(data:combined.entries["[Content_Types].xml"]!,options:[])
        let typeNodes=typeDoc.rootElement()!.elements(forLocalName:"Override",uri:"http://schemas.openxmlformats.org/package/2006/content-types")
        let authorPart=try XCTUnwrap(typeNodes.first{$0.attribute(forName:"ContentType")?.stringValue=="application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"}?.attribute(forName:"PartName")?.stringValue)
        let authorBytes=try XCTUnwrap(combined.entries[String(authorPart.dropFirst())])
        let authorDoc=try XMLDocument(data:authorBytes,options:[])
        let authors=authorDoc.rootElement()!.elements(forLocalName:"cmAuthor",uri:p)
        XCTAssertEqual(authors.count,1,"Equivalent Alice authors were split: \(String(decoding:authorBytes,as:UTF8.self))")
        let alice=try XCTUnwrap(authors.first),aliceID=try XCTUnwrap(alice.attribute(forName:"id")?.stringValue)
        var indexes=Set<UInt32>(),commentCount=0
        for item in typeNodes where item.attribute(forName:"ContentType")?.stringValue=="application/vnd.openxmlformats-officedocument.presentationml.comments+xml" {
            let path=String(try XCTUnwrap(item.attribute(forName:"PartName")?.stringValue).dropFirst())
            let doc=try XMLDocument(data:XCTUnwrap(combined.entries[path]),options:[])
            for comment in doc.rootElement()!.elements(forLocalName:"cm",uri:p) {
                XCTAssertEqual(comment.attribute(forName:"authorId")?.stringValue,aliceID)
                let index=try XCTUnwrap(comment.attribute(forName:"idx")?.stringValue.flatMap(UInt32.init))
                XCTAssertTrue(indexes.insert(index).inserted,"Retained comments reused one author's index")
                commentCount += 1
            }
        }
        XCTAssertEqual(commentCount,2)
        XCTAssertEqual(alice.attribute(forName:"lastIdx")?.stringValue.flatMap(UInt32.init),indexes.max(),"Registry must cover actual published indexes: \(String(decoding:authorBytes,as:UTF8.self))")
    }
    func testEquivalentRenamedDefaultTypedNotesMasterIsReusedForMixedSlideChoices()throws {
        let base=try withNotes(package([(256,shape(2,"old")),(257,shape(2,"old second"))]),slideID:256,text:"Base notes",master:"old.nmaster",masterDefault:true)
        let new=try withNotes(package([(256,shape(2,"new")),(257,shape(2,"new second"))]),slideID:256,text:"New notes",master:"renamed.nmaster",masterDefault:true)
        var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:false);review.decide(changeID:review.changes.first{$0.destinationSlideIndex==0}!.id,accept:true)
        let output=try review.exported()
        XCTAssertEqual(output.entries.keys.filter{$0.hasSuffix(".nmaster")}.count,1)
        XCTAssertNotNil(output.entries["ppt/notesMasters/old.nmaster"])
        XCTAssertEqual(try manifest(output).slides.map(\.text),["new","old second"])
        XCTAssertTrue(try manifest(output).slides[0].notes.contains("New notes"))
    }
    func testNumericIdentityAliasesAreNotAllowedToCreateDuplicateObjects()throws {
        let valid=try package([(256,shape(2,"text"))])
        var duplicate=valid.entries
        duplicate["ppt/slides/slide256.xml"]=slide(shape(2,"first")+shape(3,"second").replacingOccurrences(of:"id=\"3\"",with:"id=\"02\""))
        XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:.init(entries:duplicate)))
        var slides=try package([(256,shape(2,"first")),(257,shape(2,"second"))]).entries
        slides["ppt/presentation.xml"]=bytes(String(decoding:slides["ppt/presentation.xml"]!,as:UTF8.self).replacingOccurrences(of:"id=\"257\"",with:"id=\"0256\""))
        XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:.init(entries:slides)))
        var authors=try withComments(valid,authors:[(0,"Alice"),(1,"Bob")],comments:[(256,0,1,"Comment")]).entries
        authors["ppt/commentAuthors.xml"]=bytes(String(decoding:authors["ppt/commentAuthors.xml"]!,as:UTF8.self).replacingOccurrences(of:"id=\"1\"",with:"id=\"00\""))
        XCTAssertThrowsError(try PresentationRevisionReview(base:valid,destination:.init(entries:authors)))
    }

    private func modernComments(_ package:PresentationPackage,text:String="Root",reply:String="Reply",name:String="Alice",status:String="active",anchorID:Int?=nil)throws->PresentationPackage {
        let ns="http://schemas.microsoft.com/office/powerpoint/2018/8/main",pc="http://schemas.microsoft.com/office/powerpoint/2013/main/command",ac="http://schemas.microsoft.com/office/drawing/2013/main/command",mr="http://schemas.microsoft.com/office/2018/10/relationships/"
        let author="{10000000-0000-0000-0000-000000000001}",rootID="{20000000-0000-0000-0000-000000000001}",replyID="{20000000-0000-0000-0000-000000000002}"
        var entries=package.entries
        func xml(_ x:String)->Data {Data(x.utf8)}
        let anchor=anchorID.map{"<ac:deMkLst><pc:sldMkLst><pc:sldMk sldId=\"256\"/></pc:sldMkLst><ac:spMk id=\"\($0)\"/></ac:deMkLst>"} ?? "<pc:sldMkLst><pc:sldMk sldId=\"256\"/></pc:sldMkLst>"
        func body(_ text:String)->String {"<p188:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p188:txBody>"}
        entries["ppt/authors/authors.xml"]=xml("<p188:authorLst xmlns:p188=\"\(ns)\"><p188:author id=\"\(author)\" name=\"\(name)\" initials=\"A\" userId=\"\(name)@example.invalid\" providerId=\"AD\"/></p188:authorLst>")
        entries["ppt/comments/modern.xml"]=xml("<p188:cmLst xmlns:p188=\"\(ns)\" xmlns:a=\"\(a)\" xmlns:pc=\"\(pc)\" xmlns:ac=\"\(ac)\"><p188:cm id=\"\(rootID)\" authorId=\"\(author)\" created=\"2026-10-24T12:00:00Z\" status=\"active\" assignedTo=\"\(author)\" startDate=\"2026-10-24T12:00:00Z\" dueDate=\"2026-10-25T12:00:00Z\" complete=\"50000\" title=\"Task\">\(anchor)<p188:replyLst><p188:reply id=\"\(replyID)\" authorId=\"\(author)\" created=\"2026-10-24T12:01:00Z\" status=\"\(status)\">\(body(reply))</p188:reply></p188:replyLst>\(body(text))</p188:cm></p188:cmLst>")
        for (path,type) in [("ppt/authors/authors.xml","authors"),("ppt/comments/modern.xml","comments")] {
            entries["[Content_Types].xml"]=xml(String(decoding:entries["[Content_Types].xml"]!,as:UTF8.self).replacingOccurrences(of:"</Types>",with:"<Override PartName=\"/\(path)\" ContentType=\"application/vnd.ms-powerpoint.\(type)+xml\"/></Types>"))
        }
        entries["ppt/_rels/presentation.xml.rels"]=xml(String(decoding:entries["ppt/_rels/presentation.xml.rels"]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:"<Relationship Id=\"authors\" Type=\"\(mr)authors\" Target=\"authors/authors.xml\"/></Relationships>"))
        entries["ppt/slides/_rels/slide256.xml.rels"]=xml(String(decoding:entries["ppt/slides/_rels/slide256.xml.rels"]!,as:UTF8.self).replacingOccurrences(of:"</Relationships>",with:"<Relationship Id=\"modernComments\" Type=\"\(mr)comments\" Target=\"../comments/modern.xml\"/></Relationships>"))
        entries["ppt/slides/slide256.xml"]=xml(String(decoding:entries["ppt/slides/slide256.xml"]!,as:UTF8.self).replacingOccurrences(of:"</p:sld>",with:"<p:extLst><p:ext uri=\"{6950BFC3-D8DA-4A85-94F7-54DA5524770B}\"><p188:commentRel xmlns:p188=\"\(ns)\" r:id=\"modernComments\"/></p:ext></p:extLst></p:sld>"))
        return try .init(entries:entries)
    }
    func testModernCommentReplyMixedChoicePreservesThreadAuthorsAssignmentsAndStatus()throws {
        let deck=try package([(256,shape(2,"Same shape"))])
        let base=try modernComments(deck),new=try modernComments(deck,reply:"New reply",name:"Bob",status:"resolved")
        var review=try PresentationRevisionReview(base:base,destination:new)
        XCTAssertEqual(review.baseComments.count,2);XCTAssertEqual(review.destinationComments.count,2)
        let reply=try XCTUnwrap(review.changes.first{review.commentChanges[$0.id]?.destination?.depth==1})
        review.decideAll(accept:false);review.decide(changeID:reply.id,accept:true)
        let output=try review.exported(),roundtrip=try PresentationRevisionReview(base:output,destination:output)
        XCTAssertEqual(Set(roundtrip.baseComments.map(\.text)),Set(["Root","New reply"]))
        XCTAssertEqual(Set(roundtrip.baseComments.map(\.author)),Set(["Alice","Bob"]))
        let resultReply=try XCTUnwrap(roundtrip.baseComments.first{$0.depth==1})
        XCTAssertEqual(resultReply.status,"resolved");XCTAssertNotNil(resultReply.parentID)
        let xml=output.entries.filter{$0.key.contains("comments/")}.values.compactMap{String(data:$0,encoding:.utf8)}.joined()
        XCTAssertTrue(xml.contains("assignedTo="));XCTAssertTrue(xml.contains("dueDate=\"2026-10-25T12:00:00Z\""));XCTAssertTrue(xml.contains("complete=\"50000\""))
        XCTAssertEqual(try manifest(output).slides[0].text,"Same shape")
    }
    func testCommentDeleteResolvesChangeCascadesAndUndoRestoresUnresolved()throws {
        let deck=try package([(256,shape(2,"Same"))])
        let base=try modernComments(deck),new=try modernComments(deck,text:"New root",reply:"New reply")
        var review=try PresentationRevisionReview(base:base,destination:new)
        let root=try XCTUnwrap(review.baseComments.first{$0.depth==0}),reply=try XCTUnwrap(review.baseComments.first{$0.depth==1})
        review.deleteComment(changeID:root.id)
        XCTAssertTrue(review.commentIsDeleted(changeID:reply.id));XCTAssertFalse(review.commentIsDirectlyDeleted(changeID:reply.id))
        XCTAssertEqual(review.unresolvedCount,0)
        let removed=try review.exported();XCTAssertTrue(try PresentationRevisionReview(base:removed,destination:removed).baseComments.isEmpty)
        review.undo();XCTAssertFalse(review.commentIsDeleted(changeID:root.id));XCTAssertGreaterThan(review.unresolvedCount,0)
        review.redo();XCTAssertEqual(review.unresolvedCount,0)
        review.restoreComment(changeID:root.id);XCTAssertGreaterThan(review.unresolvedCount,0)
    }
    func testUnchangedCommentCanBeDeletedWithoutChangingAnyShapes()throws {
        let deck=try modernComments(package([(256,shape(2,"Same"))]))
        var review=try PresentationRevisionReview(base:deck,destination:deck)
        XCTAssertTrue(review.changes.isEmpty)
        let reply=try XCTUnwrap(review.baseComments.first{$0.depth==1});review.deleteComment(changeID:reply.id)
        let output=try review.exported(),read=try PresentationRevisionReview(base:output,destination:output)
        XCTAssertEqual(read.baseComments.map(\.text),["Root"]);XCTAssertEqual(try manifest(output).slides[0].text,"Same")
        review.undo();XCTAssertEqual(try review.exported().entries,deck.entries)
    }
    func testClassicThreadParentAuthorAndIndexSurviveMixedAuthorCollision()throws {
        let deck=try package([(256,shape(2,"Same")),(257,shape(2,"Second"))])
        let base=try withComments(deck,authors:[(0,"Alice"),(1,"Bob")],comments:[(256,0,1,"Parent"),(257,1,2,"Reply")])
        var entries=base.entries
        let key="ppt/comments/c257.xml"
        entries[key]=bytes(String(decoding:entries[key]!,as:UTF8.self).replacingOccurrences(of:"</p:cm>",with:"<p:extLst><p:ext uri=\"{threading}\"><p15:threadingInfo xmlns:p15=\"http://schemas.microsoft.com/office/powerpoint/2012/main\" timeZoneBias=\"60\"><p15:parentCm authorId=\"0\" idx=\"1\"/></p15:threadingInfo></p:ext></p:extLst></p:cm>"))
        let threaded=try PresentationPackage(entries:entries)
        var changed=entries
        changed[key]=bytes(String(decoding:entries[key]!,as:UTF8.self).replacingOccurrences(of:"Reply",with:"Changed reply"))
        changed["ppt/commentAuthors.xml"]=bytes(String(decoding:entries["ppt/commentAuthors.xml"]!,as:UTF8.self).replacingOccurrences(of:"Alice",with:"Carol"))
        var review=try PresentationRevisionReview(base:threaded,destination:.init(entries:changed))
        XCTAssertEqual(review.baseComments.filter{$0.depth==1}.count,1)
        review.decideAll(accept:false)
        let root=try XCTUnwrap(review.destinationComments.first{$0.depth==0}),reply=try XCTUnwrap(review.baseComments.first{$0.depth==1})
        review.decide(changeID:root.id,accept:true)
        let mixed=try review.exported(),read=try PresentationRevisionReview(base:mixed,destination:mixed)
        let resultParent=try XCTUnwrap(read.baseComments.first{$0.depth==0}),resultReply=try XCTUnwrap(read.baseComments.first{$0.depth==1})
        XCTAssertEqual(resultParent.author,"Carol");XCTAssertEqual(resultReply.author,"Bob");XCTAssertEqual(resultReply.parentID,resultParent.id)
        XCTAssertEqual(resultReply.text,"Reply");XCTAssertEqual(try manifest(mixed).slides.map(\.text),["Same","Second"])
        review.deleteComment(changeID:root.id)
        XCTAssertTrue(review.commentIsDeleted(changeID:reply.id));XCTAssertEqual(review.unresolvedCount,0)
        let empty=try review.exported();XCTAssertTrue(try PresentationRevisionReview(base:empty,destination:empty).baseComments.isEmpty)
        review.undo();XCTAssertFalse(review.commentIsDeleted(changeID:reply.id))
    }
    func testModernAnchoredCommentRefusesMissingSelectedShapeAndInvalidReplyParent()throws {
        let a=try modernComments(package([(256,shape(2,"Keep"))]),anchorID:2)
        let b=try modernComments(package([(256,shape(3,"Different"))]),reply:"Changed",anchorID:3)
        var review=try PresentationRevisionReview(base:a,destination:b);review.decideAll(accept:false)
        let comment=try XCTUnwrap(review.changes.first{review.commentChanges[$0.id]?.destination?.depth==0})
        review.decide(changeID:comment.id,accept:true)
        XCTAssertThrowsError(try review.exported()) {XCTAssertTrue($0.localizedDescription.contains("anchor"))}
        let plain=try package([(256,shape(2,"Keep"))]),added=try modernComments(plain)
        var orphan=try PresentationRevisionReview(base:plain,destination:added);orphan.decideAll(accept:false)
        let reply=try XCTUnwrap(orphan.changes.first{orphan.commentChanges[$0.id]?.destination?.depth==1})
        orphan.decide(changeID:reply.id,accept:true)
        XCTAssertThrowsError(try orphan.exported()) {XCTAssertTrue($0.localizedDescription.contains("parent"))}
    }
    func testCommentWholeRevisionPreservesOpaqueExtensionsButMixedRefusesPrecisely()throws {
        let base=try modernComments(package([(256,shape(2,"Old"))]))
        var entries=try modernComments(package([(256,shape(2,"New"))])).entries
        let path="ppt/comments/modern.xml"
        entries[path]=bytes(String(decoding:entries[path]!,as:UTF8.self).replacingOccurrences(of:"</p188:cm>",with:"<p188:extLst><p:ext xmlns:p=\"\(p)\" uri=\"unknown\"/></p188:extLst></p188:cm>"))
        let new=try PresentationPackage(entries:entries)
        var review=try PresentationRevisionReview(base:base,destination:new);review.decideAll(accept:true)
        XCTAssertEqual(try review.exported().entries,new.entries)
        review.decideAll(accept:false);XCTAssertEqual(try review.exported().entries,base.entries)
        if let last=review.changes.last {review.decide(changeID:last.id,accept:true);XCTAssertThrowsError(try review.exported())}
    }
    func testCommentUnknownAuthorAndCancellationAreNotSilentlyAccepted()throws {
        let deck=try modernComments(package([(256,shape(2,"Text"))]))
        var entries=deck.entries
        entries["ppt/comments/modern.xml"]=bytes(String(decoding:entries["ppt/comments/modern.xml"]!,as:UTF8.self).replacingOccurrences(of:"authorId=\"{10000000-0000-0000-0000-000000000001}\"",with:"authorId=\"{90000000-0000-0000-0000-000000000001}\""))
        XCTAssertThrowsError(try PresentationRevisionReview(base:deck,destination:.init(entries:entries)))
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try PresentationRevisionReview(base:deck,destination:deck,cancellation:token))
    }

    func testRootLevelMainPartCommentCompositionRetainsValidRelationships()throws {
        func moveMain(_ package:PresentationPackage)throws->PresentationPackage {
            var entries=package.entries
            entries["presentation.xml"]=entries.removeValue(forKey:"ppt/presentation.xml")
            let old=entries.removeValue(forKey:"ppt/_rels/presentation.xml.rels")!
            let relDoc=try XMLDocument(data:old,options:[])
            for node in relDoc.rootElement()!.elements(forName:"Relationship") {
                if let target=node.attribute(forName:"Target"),let value=target.stringValue {target.stringValue="ppt/"+value}
            }
            entries["_rels/presentation.xml.rels"]=relDoc.xmlData()
            entries["_rels/.rels"]=bytes(String(decoding:entries["_rels/.rels"]!,as:UTF8.self).replacingOccurrences(of:"ppt/presentation.xml",with:"presentation.xml"))
            entries["[Content_Types].xml"]=bytes(String(decoding:entries["[Content_Types].xml"]!,as:UTF8.self).replacingOccurrences(of:"/ppt/presentation.xml",with:"/presentation.xml"))
            return try .init(entries:entries)
        }
        let plain=try package([(256,shape(2,"Same")),(257,shape(2,"Second"))])
        for modern in [false,true] {
            let a=try moveMain(modern ? modernComments(plain,text:"Base root",reply:"Base reply"):withComments(plain,authors:[(0,"Alice")],comments:[(256,0,1,"Base root"),(257,0,2,"Context")]))
            let b=try moveMain(modern ? modernComments(plain,text:"New root",reply:"New reply"):withComments(plain,authors:[(0,"Bob")],comments:[(256,0,1,"New root"),(257,0,2,"Context")]))
            var review=try PresentationRevisionReview(base:a,destination:b);review.decideAll(accept:false)
            let root=try XCTUnwrap(review.changes.first{review.commentChanges[$0.id]?.destination?.depth==0})
            review.decide(changeID:root.id,accept:true)
            let output=try review.exported(),read=try PresentationRevisionReview(base:output,destination:output)
            XCTAssertNotNil(output.entries["presentation.xml"]);XCTAssertNil(output.entries["ppt/presentation.xml"])
            XCTAssertNotNil(output.entries["_rels/presentation.xml.rels"])
            XCTAssertEqual(try manifest(output).slides[0].text,"Same")
            XCTAssertEqual(Set(read.baseComments.map(\.text)),modern ? Set(["New root","Base reply"]):Set(["New root","Context"]))
            let mainRelationships=String(decoding:output.entries["_rels/presentation.xml.rels"]!,as:UTF8.self)
            XCTAssertFalse(mainRelationships.contains("Target=\"commentAuthors.xml\""),"Root main-part relationships must resolve to their actual package paths")
        }
    }

    func testModernReplyMovedBetweenThreadsIsAnIndependentExportDecision()throws {
        let deck=try modernComments(package([(256,shape(2,"Same"))]))
        var entries=deck.entries
        let path="ppt/comments/modern.xml",ns="http://schemas.microsoft.com/office/powerpoint/2018/8/main"
        let oldDoc=try XMLDocument(data:entries[path]!,options:[]),list=oldDoc.rootElement()!
        let original=try XCTUnwrap(list.children?.compactMap{$0 as? XMLElement}.first)
        let other=original.copy() as! XMLElement
        other.attribute(forName:"id")?.stringValue="{20000000-0000-0000-0000-000000000003}"
        other.elements(forLocalName:"replyLst",uri:ns).forEach{$0.detach()}
        let text=try XCTUnwrap(other.elements(forLocalName:"txBody",uri:ns).first)
        for node in try text.nodes(forXPath:".//*[local-name()='t']") {node.stringValue="Other root"}
        list.addChild(other)
        entries[path]=oldDoc.xmlData();let base=try PresentationPackage(entries:entries)
        let moving=try XMLDocument(data:entries[path]!,options:[]),roots=moving.rootElement()!.elements(forLocalName:"cm",uri:ns)
        let replies=try XCTUnwrap(roots[0].elements(forLocalName:"replyLst",uri:ns).first);replies.detach()
        let position=(roots[1].children ?? []).firstIndex{($0 as? XMLElement)?.localName=="txBody"} ?? roots[1].childCount
        roots[1].insertChild(replies,at:position)
        entries[path]=moving.xmlData()
        entries["ppt/slides/slide256.xml"]=bytes(String(decoding:entries["ppt/slides/slide256.xml"]!,as:UTF8.self).replacingOccurrences(of:"Same",with:"New shape"))
        var review=try PresentationRevisionReview(base:base,destination:.init(entries:entries));review.decideAll(accept:false)
        let reply=try XCTUnwrap(review.changes.first{review.commentChanges[$0.id]?.destination?.text=="Reply"})
        XCTAssertEqual(reply.kind,.commentChanged)
        XCTAssertNotEqual(review.commentChanges[reply.id]?.base?.parentID,review.commentChanges[reply.id]?.destination?.parentID)
        review.decide(changeID:reply.id,accept:true)
        let output=try review.exported(),read=try PresentationRevisionReview(base:output,destination:output)
        let moved=try XCTUnwrap(read.baseComments.first{$0.text=="Reply"})
        XCTAssertEqual(read.baseComments.first{$0.id==moved.parentID}?.text,"Other root")
        XCTAssertEqual(try manifest(output).slides[0].text,"Same","Reply move must not choose an unrelated shape change")
    }

}
