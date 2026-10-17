import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct LegacyFormatFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static var diagnostic:()->String = {""}
    @MainActor static func wait(_ ready:()->Bool,line:UInt = #line) async throws {
        for _ in 0..<1000 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Legacy format wait timed out at \(line): " + diagnostic())
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_LEGACY_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        window.alphaValue=1;window.orderFront(nil);defer {window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned legacy capture unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("legacy-format-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.LegacyNative."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let profiles=root.appendingPathComponent("profiles");try Data("txt=//,/*,*/\n".utf8).write(to:profiles)
        let settings=MergeEditorSettingsModel(defaults:defaults,commentProfileURL:profiles)
        settings.binding(\.legacyEncoding).wrappedValue = .windows1251
        try require(settings.changed && settings.apply() && ComparisonTextEncoding.legacyEncoding(from:defaults) == .windows1251,"Legacy Apply/persistence")
        settings.binding(\.legacyEncoding).wrappedValue = .windows1250;settings.restore()
        try require(settings.legacyEncoding == .windows1251 && !settings.changed,"Legacy Cancel/draft restore")
        let left=root.appendingPathComponent("left"),right=root.appendingPathComponent("right")
        let original="Привет\r\nстрока",bytes=try ComparisonTextEncoding.windows1251.encode(original)
        try bytes.write(to:left);try bytes.write(to:right);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:right.path)
        let compare=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:defaults)
        defer {compare.close()};compare.window!.alphaValue=0;compare.window!.orderFront(nil);compare.model.load()
        try await wait {!compare.model.busy && !compare.model.filtering && compare.model.document != nil}
        let model=compare.model
        diagnostic={"Compare busy=\(model.busy) filtering=\(model.filtering) error=\(String(describing:model.error)) sheet=\(String(describing:compare.window?.attachedSheet))"}
        try require(model.document?.destination.text==original && model.encoding(base:false) == .windows1251,"Compare regional decode")
        model.activatePane(base:false);model.editingEnabled=true
        settings.binding(\.legacyEncoding).wrappedValue = .shiftJIS;try require(settings.apply(),"Change next-load default")
        try require(model.encoding(base:false) == .windows1251,"Preferences reinterpreted an open pane")
        let prompt=MergeFormatPrompt(pane:"Mine",selection:.init(encoding:model.encoding(base:false)!),legacyEncoding:model.legacyEncoding)
        try require(prompt.encoding.numberOfItems==9 && prompt.encodings.first == .windows1251 && prompt.encoding.titleOfSelectedItem==ComparisonTextEncoding.windows1251.rawValue,"Nine choices/current codec retention")
        prompt.window!.alphaValue=0;prompt.window!.orderFront(nil);try await capture(prompt.window!);prompt.cancel()
        model.changeEncoding(.windows1252,base:false)
        try require(model.error != nil && model.encoding(base:false) == .windows1251,"Unrepresentable conversion changed codec")
        model.error=nil
        let edited=original+"\r\nновое";model.updateDraft(edited,base:false)
        try await wait {!model.filtering}
        var completed:Bool?;model.save {completed=$0};try await wait {completed != nil}
        try require(completed==true && Data(contentsOf:right)==ComparisonTextEncoding.windows1251.encode(edited),"Compare Save ignored retained legacy codec")
        try require(try Data(contentsOf:left)==bytes && (FileManager.default.attributesOfItem(atPath:right.path)[.posixPermissions] as? NSNumber)?.intValue==0o755,"Compare source/mode preservation")
        compare.close()
        let base=root.appendingPathComponent("base-ja"),theirs=root.appendingPathComponent("theirs-ja"),mine=root.appendingPathComponent("mine-ja")
        let baseText="日本語\r\n元の行",mineText="日本語\r\n自分の変更"
        let baseBytes=try ComparisonTextEncoding.shiftJIS.encode(baseText)
        try baseBytes.write(to:base);try baseBytes.write(to:theirs);try ComparisonTextEncoding.shiftJIS.encode(mineText).write(to:mine)
        let merge=TextConflictWindowController(repository:GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/git")),access:nil,path:mine.path,workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:defaults)
        diagnostic={"Merge busy=\(merge.model.busy) document=\(merge.model.document != nil) ready=\(merge.model.nativeEditorReady) error=\(String(describing:merge.model.error))"}
        defer {merge.close()};merge.window!.alphaValue=0;merge.window!.orderFront(nil);merge.model.load()
        try await wait {!merge.model.busy && merge.model.document != nil && merge.model.sourceToolsAllowed}
        try require(merge.model.document?.base==baseText && merge.model.document?.mine==mineText && merge.model.encoding == .shiftJIS,"Standalone Merge regional decode")
        merge.model.chooseStandaloneOutput={_,_ in mine}
        let result="解決済み\r\n最後";merge.model.result=result;completed=nil
        merge.model.save(markResolved:false) {completed=$0};try await wait {completed != nil}
        try require(completed==true && Data(contentsOf:mine)==ComparisonTextEncoding.shiftJIS.encode(result),"Merge legacy Save")
        try require(try Data(contentsOf:base)==baseBytes && Data(contentsOf:theirs)==baseBytes,"Merge input bytes changed")
        merge.close();try await wait {MergeRegexOperations.activeRequests==0}
        print("PASS legacy format family: Settings Apply/Cancel, configured Compare and three-way Merge decoding, retained open-pane codec across preference change, source nine-item prompt, failed conversion preservation and exact CP1251/Shift-JIS saves; source/mode preserved; owned windows closed")
    }
}
