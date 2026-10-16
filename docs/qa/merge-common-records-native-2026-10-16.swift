import AppKit
import TurtleGitCore

struct MergeCommonRecordsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitCommon-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.Common."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        MergeComparisonOptions(ignoreEndings:true).save(to:prefs)
        let a=root.appendingPathComponent("before.txt"),b=root.appendingPathComponent("after.txt"),out=root.appendingPathComponent("export.txt")
        let base="head 🐢\r\nsame\r\nlast",mine="head 🐢\nsame\nlast"
        let old=try ComparisonTextEncoding.utf16LEBOM.encode(base),new=try ComparisonTextEncoding.utf8BOM.encode(mine)
        try old.write(to:a);try new.write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model
        defer {owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        model.commentProfileURL=root.appendingPathComponent("comments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        try require(model.alignment?.differences.isEmpty==true && model.alignment?.rows[0].base.text=="head 🐢\r\n" && model.alignment?.rows[0].destination.text=="head 🐢\n","Two-pane common rows lost original endings")
        model.chooseExportLocation={_,_,_ in out};model.export(base:false)
        try await TwoPaneEngineVerification.wait {!model.busy && FileManager.default.fileExists(atPath:out.path)}
        try require(try Data(contentsOf:out)==new,"Two-pane export changed Mine ending or encoding")
        try FileManager.default.removeItem(at:out)
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        try require(model.combined?.sourceSaveText==base && !model.dirty && model.draftText(base:false)==mine,"Combined common record did not retain Base EOL independently of draft")
        try await TwoPaneEngineVerification.wait {TwoPaneEngineVerification.editors(owner.window?.contentView).filter{$0 is ComparisonContextMenuProviding}.count==1}
        let text=TwoPaneEngineVerification.editors(owner.window?.contentView).first{$0 is ComparisonContextMenuProviding}!
        try require(text.string=="head 🐢\nsame\nlast\n","Combined display serialized physical EOL characters")
        model.export(base:false);try await TwoPaneEngineVerification.wait {!model.busy && FileManager.default.fileExists(atPath:out.path)}
        try require(try Data(contentsOf:out)==ComparisonTextEncoding.utf8BOM.encode(base),"Combined export lost Base EOL or Mine encoding")
        try require(!model.dirty && !model.canUndo && Data(contentsOf:a)==old && Data(contentsOf:b)==new,"Viewing/export changed drafts or input bytes")
        model.activatePane(base:false);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait {text.isEditable}
        text.insertText("changed",replacementRange:(text.string as NSString).range(of:"same"))
        try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)=="head 🐢\r\nchanged\r\nlast" && model.dirty,"Combined edit did not retain captured common-record endings")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==mine && !model.dirty && model.combined?.sourceSaveText==base,"Undo lost original Mine draft or combined projection")
        model.redo();try await TwoPaneEngineVerification.settled(model)
        model.save();try await TwoPaneEngineVerification.wait {!model.busy && !model.dirty}
        try require(try Data(contentsOf:b)==ComparisonTextEncoding.utf8BOM.encode("head 🐢\r\nchanged\r\nlast") && Data(contentsOf:a)==old,"Save lost exact combined bytes/encoding or rewrote Base")
        model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
        try require(!model.onePaneActive && model.alignment?.rows[1].destination.text=="changed\r\n","Returning to two panes lost saved record endings")
        owner.close()
        print("PASS: common records retain independent two-pane bytes, Base-ending combined export, Mine encoding, native edit Undo/Redo/Save, source preservation and mode restoration")
    }
}
