import Foundation
import XCTest
@testable import TurtleGitCore

final class LiteralToolConfigurationTests: XCTestCase {
    private let composed="\u{e9}", decomposed="e\u{301}"
    private func program(_ tag:String) -> DiffToolProgram {
        var value=DiffToolProgram();value.enabled=true;value.applicationPath="/Applications/Fixture.app";value.arguments="--tag="+tag+" %base %mine";return value
    }
    private func association(_ pattern:String,_ tag:String) -> DiffToolAssociation {
        var value=DiffToolAssociation();value.pattern=pattern;value.program=program(tag);return value
    }
    func testLiteralProgramAndEditorDraftIdentitiesSurvivePersistence() throws {
        let suite="TurtleGit.LiteralTools."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        var a=program(composed),b=a;b.arguments="--tag="+decomposed+" %base %mine"
        XCTAssertNotEqual(a,b)
        b=a;b.applicationPath="/Applications/"+composed+".app";a.applicationPath="/Applications/"+decomposed+".app"
        XCTAssertNotEqual(a,b)
        var tools=DiffToolPreferences();tools.program=b;try tools.save(to:prefs)
        XCTAssertEqual(Data(DiffToolPreferences.load(from:prefs).program.applicationPath.utf8),Data(b.applicationPath.utf8))
        let old=AlternativeEditorPreferences(custom:true,applicationPath:a.applicationPath),new=AlternativeEditorPreferences(custom:true,applicationPath:b.applicationPath)
        XCTAssertNotEqual(old,new);new.save(to:prefs)
        XCTAssertEqual(Data(AlternativeEditorPreferences.load(from:prefs).applicationPath.utf8),Data(new.applicationPath.utf8))
        let u=UnifiedDiffViewerPreferences(enabled:true,applicationPath:b.applicationPath,arguments:composed)
        var v=u;v.arguments=decomposed;XCTAssertNotEqual(u,v);v.save(to:prefs)
        XCTAssertEqual(Data(UnifiedDiffViewerPreferences.load(from:prefs).arguments.utf8),Data(decomposed.utf8))
    }
    func testDistinctFilenameAndExtensionRulesRetainCaseInsensitivePrecedence() throws {
        let a=association(composed+".txt","first"),b=association(decomposed+".txt","second")
        var tools=DiffToolPreferences();tools.program=program("fallback");tools.associations=[a,b,association(".txt","extension")]
        XCTAssertTrue(tools.valid)
        XCTAssertEqual(try tools.selected(base:"base",destination:"folder/"+composed+".txt")?.arguments,a.program.arguments)
        XCTAssertEqual(try tools.selected(base:"base",destination:"folder/"+decomposed+".txt")?.arguments,b.program.arguments)
        XCTAssertEqual(try tools.selected(base:composed+".txt",destination:"other.TXT")?.arguments,a.program.arguments)
        XCTAssertEqual(try tools.selected(base:"base",destination:"other.TXT")?.arguments,"--tag=extension %base %mine")
        var duplicate=a;duplicate.id=UUID();duplicate.pattern="***"+composed.uppercased()+".TXT";tools.associations.append(duplicate)
        XCTAssertFalse(tools.valid)
        tools.associations=[association("name","literal")]
        XCTAssertEqual(try tools.selected(base:"base",destination:" name")?.arguments,tools.program.arguments,"Candidate filenames must not be trimmed like configured patterns")
    }
    func testMergeRulesDefaultsAndDisabledAlternateKeepSeparateSpellings() throws {
        var tools=MergeToolPreferences();let a=association("."+composed+".txt","first"),b=association("."+decomposed+".txt","second")
        tools.associations=[a,b];XCTAssertTrue(tools.valid)
        XCTAssertEqual(try tools.selected(path:composed+".txt")?.arguments,a.program.arguments)
        XCTAssertEqual(try tools.selected(path:decomposed+".txt")?.arguments,b.program.arguments)
        tools.associations[0].program.enabled=false
        XCTAssertNil(try tools.selected(path:composed+".txt"))
        XCTAssertEqual(try tools.selected(path:composed+".txt",alternate:true)?.arguments,a.program.arguments)
        let ids=tools.associations.map(\.id);tools.restoreBundledAssociations()
        XCTAssertTrue(ids.allSatisfy{identity in tools.associations.contains{$0.id==identity}})
        XCTAssertTrue(tools.valid)
        var diff=DiffToolPreferences();diff.associations=[association("."+composed,"first"),association("."+decomposed,"second")]
        let retained=diff.associations;diff.restoreBundledAssociations()
        XCTAssertEqual(Array(diff.associations.prefix(2)),retained)
    }
    func testSelectedTemplateDeliversLiteralArgumentsToActualExecutable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("tg-literal-tool-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let tool=root.appendingPathComponent("tool"),output=root.appendingPathComponent("argv")
        try Data("#!/bin/sh\noutput=$1\nshift\nprintf '%s\\0' \"$@\" > \"$output\"\n".utf8).write(to:tool)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tool.path)
        var selected=program(decomposed);selected.applicationPath=tool.path;selected.arguments="%out --tag="+decomposed+" %base %mine"
        let arguments=try selected.expandedArguments(values:["out":output.path,"base":composed,"mine":decomposed])
        let execution=try await ExternalToolExecution.start(executable:tool,arguments:arguments,directory:root)
        let status=try await execution.completion.value;XCTAssertEqual(status,0)
        let actual=try Data(contentsOf:output).split(separator:0).map { Data($0) }
        XCTAssertEqual(actual,[Data(("--tag="+decomposed).utf8),Data(composed.utf8),Data(decomposed.utf8)])
    }
}
