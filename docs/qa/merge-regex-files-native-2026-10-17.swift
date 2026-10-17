// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

struct MergeRegexFilesVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description:message) } }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Regex files did not settle")
    }
    @MainActor static func verify(parser: URL) async throws {
        let suite="TurtleGit.RegexFiles."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRegexFiles-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root) }
        let first=MergeRegexFilter(name:"é",expression:"[0-9]+",replacement:""),second=MergeRegexFilter(name:"e\u{301}",expression:"[a-z]+",replacement:"")
        let imported=[first,second],input=root.appendingPathComponent("regexfilters.ini"),output=root.appendingPathComponent("export.ini")
        try MergeRegexFilters.encodeINI(imported).write(to:input)
        let originalBytes=try Data(contentsOf:input)
        let list=MergeRegexFilterListController(defaults:prefs);list.executable=parser
        defer { list.retire() }
        list.window?.alphaValue=0;list.window?.orderFront(nil)
        let model=list.model
        try require(model.filters==MergeRegexFilters.shipped && model.filters.count==1 && prefs.object(forKey:"TurtleGitMerge.RegexFilters")==nil,"Fresh native library missed the shipped GUID preset or wrote preferences on read")
        var open:(NSOpenPanel,(NSApplication.ModalResponse)->Void)?,save:(NSSavePanel,(NSApplication.ModalResponse)->Void)?
        list.presentOpen={ panel,_,reply in open=(panel,reply) };list.chosenOpenURL={ _ in input }
        list.presentSave={ panel,_,reply in save=(panel,reply) };list.chosenSaveURL={ _ in output }
        var scopes=0;list.startScope={ _ in scopes += 1;return true };list.stopScope={ _ in scopes -= 1 }
        let old=model.context
        model.importFile(old)
        try require(open != nil && model.transferring && !model.canEdit && !list.windowShouldClose(list.window!) && MergeRegexOperations.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Import chooser did not own close/Quit")
        model.requestEdit(nil,context:old);model.accept(first,oldName:nil);model.saveAndClose()
        try require(list.editor==nil && !model.retired && model.filters.count==1,"Import chooser allowed competing mutation")
        let cancelled=open!;cancelled.1(.cancel);cancelled.1(.OK)
        try require(model.canEdit && MergeRegexOperations.activeRequests==0 && scopes==0,"Cancelled or duplicate chooser changed ownership")
        model.importFile(model.context);open!.1(.OK);open!.1(.OK)
        try await wait { model.canEdit && MergeRegexOperations.activeRequests==0 }
        try require(model.filters==MergeRegexFilters.shipped+imported && model.selection==second.id && scopes==0 && prefs.object(forKey:"TurtleGitMerge.RegexFilters")==nil,"Import lost exact names, persisted early or leaked a scope")
        if let captures=ProcessInfo.processInfo.environment["TURTLEGIT_REGEX_FILES_CAPTURE"] {
            try await MergeRegexSourceVerification.capture(list.window!,name:"merge-regex-library",folder:URL(fileURLWithPath:captures))
        }
        model.remove(first,context:old)
        try require(model.filters.count==3,"Retired menu mutated imported draft")
        model.exportFile(model.context)
        try require(save != nil && !model.canEdit,"Export chooser missing")
        let cancelledSave=save!;cancelledSave.1(.cancel);cancelledSave.1(.OK)
        try require(!FileManager.default.fileExists(atPath:output.path) && model.canEdit,"Cancelled export wrote a file")
        model.exportFile(model.context);save!.1(.OK);save!.1(.OK)
        try await wait { model.canEdit && MergeRegexOperations.activeRequests==0 }
        try require(try MergeRegexFilters.decodeINI(Data(contentsOf:output))==model.filters,"Actual export did not capture the complete draft")
        try require(scopes==0 && prefs.object(forKey:"TurtleGitMerge.RegexFilters")==nil,"Export persisted definitions or retained destination scope")
        let draft=model.filters
        try Data("[Invalid]\nregex=(\nreplace=\n".utf8).write(to:input)
        model.importFile(model.context);open!.1(.OK)
        try await wait { model.canEdit && MergeRegexOperations.activeRequests==0 }
        try require(model.filters==draft && model.error != nil && scopes==0,"Invalid regex partially replaced the library")
        try originalBytes.write(to:input)
        var readGate:CheckedContinuation<Void,Never>?, reading=false
        list.readFile={ _,_,token in reading=true;await withCheckedContinuation { readGate=$0 };try token.check();return imported }
        model.importFile(model.context);let staleCancel=model.context;open!.1(.OK)
        try await wait { reading }
        model.cancelTransfer(staleCancel)
        try require(!model.canEdit && MergeRegexOperations.activeRequests==1 && scopes==1,"Cancel released an in-flight read early")
        readGate!.resume();readGate=nil
        try await wait { model.canEdit && MergeRegexOperations.activeRequests==0 }
        try require(model.filters==draft && scopes==0,"Cancelled read changed the draft")
        model.saveAndClose()
        try require(model.retired && MergeRegexFilters.load(defaults:prefs)==draft,"Outer OK did not persist imported definitions")
        let a=root.appendingPathComponent("base.txt"),b=root.appendingPathComponent("mine.txt")
        try Data("value 12\n".utf8).write(to:a);try Data("value 81\n".utf8).write(to:b)
        let comparison=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[])
        defer { comparison.window?.close() }
        let compare=comparison.model;compare.regexDefaults=prefs;compare.regexExecutable=parser
        compare.load();try await wait { !compare.busy && compare.document != nil };compare.refreshRegexFilters()
        compare.selectRegexFilter(first.name);try await wait { !compare.busy && !compare.filtering }
        try require(compare.alignment?.differences.isEmpty==true,"Imported first exact section was not applied")
        compare.selectRegexFilter(second.name);try await wait { !compare.busy && !compare.filtering }
        try require(compare.regexFilterName?.utf8.elementsEqual(second.name.utf8)==true && compare.alignment?.differences.isEmpty==false,"Canonical section names were merged by menu selection")
        let writing=MergeRegexFilterListController(defaults:prefs);writing.window?.alphaValue=0;writing.window?.orderFront(nil)
        defer { writing.retire() }
        let lateOutput=root.appendingPathComponent("accepted-export.ini")
        var writeGate:CheckedContinuation<Void,Never>?,started=false,writeReply:((NSApplication.ModalResponse)->Void)?,writePanel:NSSavePanel?
        writing.presentSave={ panel,_,reply in writePanel=panel;writeReply=reply };writing.chosenSaveURL={ _ in lateOutput }
        writing.startScope={ _ in scopes += 1;return true };writing.stopScope={ _ in scopes -= 1 }
        writing.writeFile={ data,url,token in try token.check();started=true;await withCheckedContinuation { writeGate=$0 };try data.write(to:url,options:.atomic) }
        writing.model.exportFile(writing.model.context);writeReply!(.OK)
        try await wait { started }
        writing.retire();writeReply!(.OK)
        try require(writing.model.retired && MergeRegexOperations.activeRequests==1 && scopes==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close dropped an accepted write")
        writeGate!.resume();writeGate=nil
        try await wait { MergeRegexOperations.activeRequests==0 }
        try require(scopes==0 && writing.model.retired && (try MergeRegexFilters.decodeINI(Data(contentsOf:lateOutput)))==draft && writePanel != nil,"Accepted export lost its bytes/scope or revived the owner")
        try require(try Data(contentsOf:input)==originalBytes,"Import modified its source INI")
        print("PASS regex INI family: compiled shipped preset, source codec, exact-name menu selection, real import/export, chooser Cancel/duplicates, validation failure atomicity, draft OK, scopes and cancelled/closed-owner worker drain")
    }
}
