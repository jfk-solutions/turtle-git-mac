// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import CryptoKit
import TurtleGitCore

struct ReleaseUpdateNativeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let bytes = Data("private release archive\n".utf8)
    static let repo = "jfk-solutions/turtle-git-mac"
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    static func release() throws -> PublishedRelease {
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
        let assets: [[String:Any]] = [(1,"TurtleGit-for-Mac.zip",digest),(2,"TurtleGit-symbols.zip",digest),(3,"legacy.zip",NSNull() as Any)].map { id,name,hash in ["id":id,"name":name,"size":bytes.count,"state":"uploaded","digest":hash,"browser_download_url":"https://github.com/\(repo)/releases/download/v2.0.0/\(name)"] }
        let value: [String:Any] = ["tag_name":"v2.0.0","name":"TurtleGit for Mac 2.0.0","body":"Sample release notes\n\n• Native Git dialogs and original icons\n• Finder integration improvements\n\nPrivate fixture metadata; no public release was created.","html_url":"https://github.com/\(repo)/releases/tag/v2.0.0","draft":false,"prerelease":false,"assets":assets]
        return try ReleaseUpdateFeed.releases(JSONSerialization.data(withJSONObject:[value]),repository:repo,includePreview:false)[0]
    }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2500 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description:"Update timeout at \(line)")
    }
    @MainActor static func capture(_ window: NSWindow, name: String, folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description:"Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height <= 900 && window.frame.width >= 600,"Update window escaped its native content bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID == CGWindowID(window.windowNumber)}) else {throw Failure(description:"Capture owner missing")}
            let options=SCStreamConfiguration();options.includeChildWindows=false;options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"PNG missing")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify() async throws {
        let suite="TurtleGit.UpdateSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitUpdateSource-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        let model=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:repo,appStore:false),value=try release()
        let owner=ReleaseUpdateWindowController(model:model);defer {owner.window?.close()}
        owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        var reply:CheckedContinuation<[PublishedRelease],Error>?,results=0,fetches=0
        model.fetch={repository,preview in try require(repository==repo && !preview,"Wrong captured channel");fetches+=1;return try await withCheckedThrowingContinuation {reply=$0}}
        model.onResult={results+=1};let stale=model.context
        model.check();model.check();try await wait {reply != nil}
        try require(fetches==1 && model.busy && ReleaseUpdateModel.activeOperations==1,"Duplicate feed request")
        reply?.resume(returning:[value]);reply=nil;try await wait {!model.busy}
        try require(results==1 && model.available && model.selected==[1] && prefs.object(forKey:"TurtleGit.LastVersionCheck") != nil,"Release result/default main archive missing")
        model.select(value.assets[1],checked:true,context:stale);model.select(value.assets[2],checked:true,context:model.context)
        try require(model.selected==[1] && !model.canSelect(value.assets[2]),"Stale or digest-less selection accepted")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_UPDATE_CAPTURE"] {try await capture(owner.window!,name:"release-update-source",folder:URL(fileURLWithPath:path))}
        owner.window?.orderFront(nil)
        var folderReply:CheckedContinuation<URL?,Never>?
        model.chooseFolder={_ in await withCheckedContinuation {folderReply=$0}}
        model.download();model.download();try await wait {folderReply != nil}
        try require(model.downloadPending && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Download chooser ownership missing")
        model.abort();model.abort()
        try require(model.cancelling && ReleaseUpdateModel.activeOperations==1,"Abort prematurely drained chooser")
        folderReply?.resume(returning:root);folderReply=nil;try await wait {!model.downloadPending && ReleaseUpdateModel.activeOperations==0}
        try require(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty,"Aborted chooser wrote files")
        model.chooseFolder=nil;model.download()
        try await wait {owner.window?.attachedSheet is NSOpenPanel}
        model.abort();try await wait {!model.downloadPending && owner.window?.attachedSheet==nil && ReleaseUpdateModel.activeOperations==0}
        model.chooseFolder={_ in root};var transfers=0
        model.transfer={_,stage,progress in transfers+=1;progress(Int64(bytes.count));try bytes.write(to:stage)}
        model.select(value.assets[1],checked:true,context:model.context)
        model.download();try await wait {!model.downloadPending}
        try require(transfers==2 && model.downloaded.count==2 && model.selected.isEmpty && model.progress==1 && model.error==nil,"Checked multi-download did not complete")
        for (index,url) in model.downloaded.enumerated() {
            let data=try Data(contentsOf:url);try require(data==bytes && model.statuses[value.assets[index].id]?.contains("SHA-256 verified")==true,"Unverified or wrong installed bytes")
        }
        var shown:[URL]=[],opened:URL?
        model.reveal={shown=$0};model.openURL={opened=$0;return true};model.showDownloads();model.openRelease()
        try require(shown==model.downloaded && opened==value.url,"Wrong captured reveal/release target")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_UPDATE_CAPTURE"] {try await capture(owner.window!,name:"release-download-source",folder:URL(fileURLWithPath:path))}
        owner.window?.orderFront(nil)
        model.fetch={_,_ in [value]};model.check();try await wait {!model.busy}
        model.download();try await wait {!model.downloadPending}
        try require(transfers==2 && model.error?.contains("already exists")==true,"Existing destination was downloaded over")
        for name in ["TurtleGit-for-Mac.zip","TurtleGit-symbols.zip"] {let data=try Data(contentsOf:root.appendingPathComponent(name));try require(data==bytes,"Existing file changed")}
        // Digest mismatch goes through the real final verifier and installs nothing.
        let bad=root.appendingPathComponent("bad");try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
        model.chooseFolder={_ in bad};model.transfer={_,stage,_ in try Data(repeating:0,count:bytes.count).write(to:stage)}
        model.download();try await wait {!model.downloadPending}
        let badFiles=try FileManager.default.contentsOfDirectory(atPath:bad.path)
        try require(model.error?.contains("SHA-256")==true && badFiles.isEmpty,"Digest mismatch published a file")
        model.disableAutomatic();try require(prefs.object(forKey:"VersionCheck") as? Bool == false && model.retired,"Don't ask preference/owned close failed")
        print("PASS native release downloads: source list/defaults, captured feed, original choices, owned/injected folder Cancel and Abort, two verified private-file installs, no overwrite, digest failure, Finder/release targets and private preference")
    }
}
struct ReleaseUpdateLifetimeVerification {
    @MainActor static func verify() async throws {
        typealias QA=ReleaseUpdateNativeVerification
        let suite="TurtleGit.UpdateLifetime."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitUpdateLifetime-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        let value=try QA.release(),model=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:false)
        let owner=ReleaseUpdateWindowController(model:model);defer {owner.window?.close()}
        model.fetch={_,_ in [value]};model.check();try await QA.wait {!model.busy}
        owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.chooseFolder={_ in root}
        var reply:CheckedContinuation<Void,Error>?,lateProgress:(@Sendable(Int64)->Void)?
        model.transfer={_,_,progress in lateProgress=progress;try await withCheckedThrowingContinuation {reply=$0}}
        model.download();try await QA.wait {reply != nil}
        owner.window?.close()
        try QA.require(model.retired && ReleaseUpdateModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed owner released transfer lifetime")
        let statuses=model.statuses;lateProgress?(Int64(QA.bytes.count));reply?.resume();reply=nil
        try await QA.wait {ReleaseUpdateModel.activeOperations==0}
        let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
        try QA.require(files.isEmpty && model.downloaded.isEmpty && model.statuses==statuses,"Late transfer/progress published after close")
        let reading=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:false),readOwner=ReleaseUpdateWindowController(model:reading)
        var pending:CheckedContinuation<[PublishedRelease],Error>?,results=0
        reading.fetch={_,_ in try await withCheckedThrowingContinuation {pending=$0}};reading.onResult={results+=1}
        reading.check();try await QA.wait {pending != nil};readOwner.window?.close()
        try QA.require(ReleaseUpdateModel.activeOperations==1,"Retired feed lost its drain")
        pending?.resume(returning:[value]);pending=nil;try await QA.wait {ReleaseUpdateModel.activeOperations==0}
        try QA.require(results==0 && reading.release==nil,"Retired feed published result")
        readOwner.window?.close()
        // A quiet network check is not a presented utility owner. A deliberate
        // forced check owns its pending presentation until actual drain/result.
        for forced in [false,true] {
            let service=ReleaseUpdateService(),background=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:false)
            var held:CheckedContinuation<[PublishedRelease],Error>?,displays=0
            defer{service.cancelBackground();let pending=held;held=nil;pending?.resume(returning:[]);service.controller?.close()}
            background.fetch={_,_ in try await withCheckedThrowingContinuation{held=$0}}
            service.createModel={_ in background};service.display={_ in displays += 1}
            service.showCommand(visible:false,force:forced,preferences:prefs)
            try await QA.wait{held != nil}
            try QA.require(service.hasOwnedUtilityWindow==forced && service.presentExistingUtility()==forced && service.controller==nil && displays==0,"Quiet background check claimed utility window or forced presentation lost intent")
            service.cancelBackground()
            try QA.require(!service.hasOwnedUtilityWindow && !service.presentExistingUtility() && ReleaseUpdateModel.activeOperations==1,"Cancelled background retained utility owner or lost actual worker drain")
            let finish=held;held=nil;finish?.resume(returning:[]);try await QA.wait{ReleaseUpdateModel.activeOperations==0}
            try QA.require(!service.hasOwnedUtilityWindow && service.controller==nil && displays==0,"Retired background created late update window")
        }
        let unpublished=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:true,appStoreListing:nil)
        let unpublishedOwner=ReleaseUpdateWindowController(model:unpublished);defer{unpublished.cancel();unpublishedOwner.close()}
        var unexpected=0
        unpublished.fetch={_,_ in unexpected += 1;return []};unpublished.openStore={_ in unexpected += 1;return true};unpublished.transfer={_,_,_ in unexpected += 1}
        try QA.require(!unpublished.canOpenAppStore && unpublished.message=="An App Store listing is not available for this build.","Unpublished Store-compatible build implied listing before Check")
        unpublished.check();unpublished.download();unpublished.openRelease();unpublished.openAppStore()
        try QA.require(unexpected==0 && !unpublished.busy && !unpublished.canDownload && !unpublished.message.contains("managed by") && unpublished.releaseNotesPlaceholder.contains("not available") && unpublished.updateSourceDescription=="Local test build","Unconfigured Store build opened generic Store/downloaded/claimed published updates")
        let listing=URL(string:"https://apps.apple.com/app/id123456789")!
        let store=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:true,appStoreListing:listing),storeOwner=ReleaseUpdateWindowController(model:store)
        defer {store.cancel();storeOwner.window?.close()}
        store.fetch={_,_ in throw QA.Failure(description:"App Store fetched outside metadata")};store.transfer={_,_,_ in throw QA.Failure(description:"App Store downloaded outside metadata")}
        var stores=[URL]();store.openStore={stores.append($0);return true};store.check();store.download();store.openRelease();store.openAppStore()
        try QA.require(!store.busy && !store.canDownload && store.canOpenAppStore && stores==[listing] && ReleaseUpdateModel.activeOperations==0,"Configured App Store page/isolation failed")
        store.openStore={_ in false};store.openAppStore();try QA.require(store.error != nil,"App Store page open failure hidden")
        store.cancel();store.openStore={stores.append($0);return true};store.openAppStore();try QA.require(stores==[listing],"Retired update owner opened Store page")
        print("PASS native release lifetime: held transfer/fetch, forced close/late progress refusal, real task drain and Quit ownership, App Store isolation and open failure")
    }
}
