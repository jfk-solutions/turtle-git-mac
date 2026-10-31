// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import CryptoKit
import Combine
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
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func ax(_ object:NSObject,_ name:String)->Any? {
        let selector=NSSelectorFromString(name)
        let modern=object.responds(to:selector) ? object.perform(selector)?.takeUnretainedValue():nil
        if let modern,!(modern is NSArray && (modern as? NSArray)?.count==0),!(modern is NSString && (modern as? NSString)?.length==0){return modern}
        let attributes=["accessibilityRole":"AXRole","accessibilityChildren":"AXChildren","accessibilityValue":"AXValue","accessibilityIdentifier":"AXIdentifier","accessibilityLabel":"AXDescription","accessibilityEnabled":"AXEnabled"]
        guard let attribute=attributes[name],object.responds(to:NSSelectorFromString("accessibilityAttributeValue:")) else{return modern}
        let names=NSSelectorFromString("accessibilityAttributeNames")
        if object.responds(to:names),let supported=object.perform(names)?.takeUnretainedValue() as? [String],!supported.contains(attribute){return modern}
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"),with:attribute)?.takeUnretainedValue() ?? modern
    }
    @MainActor static func hostingTreeAbsent(_ window:NSWindow)->Bool {
        guard let view=window.contentView else{return false}
        // Legacy AXChildren may expose mounted AppKit list descendants even
        // when SwiftUI supplies no semantic hosting subtree. Classify the
        // modern host directly; keep legacy rows available to other probes.
        return (view.accessibilityChildren() ?? []).isEmpty && (ax(view,"accessibilityChildrenInNavigationOrder") as? [Any] ?? []).isEmpty
    }
    @MainActor static func accessibility(_ window:NSWindow)->(frames:[String:NSRect],labels:Set<String>,ids:[String],diagnostics:[String]) {
        var frames=[String:NSRect](),labels=Set<String>(),ids=[String](),diagnostics=[String](),seen=Set<ObjectIdentifier>(),budget=4096
        func property(_ object:NSObject,_ name:String)->Any? {ax(object,name)}
        func visit(_ value:Any,_ depth:Int) {
            guard depth<48,budget>0 else{return};budget -= 1
            guard let object=value as? NSObject else {if diagnostics.count<180 {diagnostics.append("Unvisited AX type=\(type(of:value))")};return}
            guard seen.insert(ObjectIdentifier(object)).inserted else{return}
            let element=value as? NSAccessibilityProtocol
            let label=element?.accessibilityLabel() ?? property(object,"accessibilityLabel") as? String
            if let label {labels.insert(label)}
            if let title=property(object,"accessibilityTitle") as? String {labels.insert(title)}
            let id=property(object,"accessibilityIdentifier") as? String
            let respondsFrame=object.responds(to:NSSelectorFromString("accessibilityFrame"))
            // SwiftUI's public AX proxies may expose selectors without adopting
            // the Swift-imported protocol. KVC safely boxes NSRect; perform()
            // must never be used to invoke a struct-returning getter.
            let frame=element?.accessibilityFrame() ?? (id != nil && respondsFrame ? (object.value(forKey:"accessibilityFrame") as? NSValue)?.rectValue:nil)
            if let id {ids.append(id);if let frame {frames[id]=frame}}
            let direct=element?.accessibilityChildren() ?? property(object,"accessibilityChildren") as? [Any] ?? []
            let navigation=property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            let children=direct+navigation
            if diagnostics.count<180 || id != nil {
                let role=element?.accessibilityRole()?.rawValue ?? property(object,"accessibilityRole") as? String ?? "none"
                diagnostics.append("\(type(of:value)) id=\(String(reflecting:id)) role=\(role) protocol=\(element != nil) frameSelector=\(respondsFrame) frame=\(String(describing:frame)) label=\(String(reflecting:label)) children=\(direct.count) navigation=\(navigation.count)")
            }
            for child in children {visit(child,depth+1)}
            if let view=value as? NSView {for child in view.subviews {visit(child,depth+1)}}
        }
        if let content=window.contentView {visit(content,0)}
        return (frames,labels,ids,diagnostics)
    }
    @MainActor static func geometry(_ owner:ReleaseUpdateWindowController)throws->[String:NSRect] {
        guard let window=owner.window else {throw Failure(description:"Update geometry owner missing")}
        window.contentView?.layoutSubtreeIfNeeded()
        let snapshot=accessibility(window),frames=snapshot.frames,ids=["release-assets-list","release-update-feedback","release-download-operations"]
        if ids.contains(where:{frames[$0]?.isEmpty != false}),hostingTreeAbsent(window) {
            // A prohibited receiver can have zero SwiftUI AX children while
            // its real AppKit scroll/list/control views are fully mounted.
            let all=views(window.contentView)
            guard let table=all.compactMap({$0 as? NSTableView}).first(where:{$0.numberOfRows==owner.model.assets.count}),let list=table.enclosingScrollView,
                  let feedback=all.compactMap({$0 as? NSScrollView}).first(where:{abs($0.bounds.height-48)<1}) else {throw Failure(description:"No actual native Updates feedback/list geometry; "+snapshot.diagnostics.joined(separator:"\n"))}
            let listFrame=list.convert(list.bounds,to:nil)
            // Retain the smallest mounted native ancestor extending below the
            // list into its Download operations area. No private view classes,
            // synthesized AX attributes or test-only production anchors.
            var ancestor=list.superview,group=window.contentView!
            while let candidate=ancestor {
                let frame=candidate.convert(candidate.bounds,to:nil)
                if frame.minY<listFrame.minY-1 && frame.maxY>=listFrame.maxY-1 {group=candidate;break}
                ancestor=candidate.superview
            }
            return [ids[0]:listFrame,ids[1]:feedback.convert(feedback.bounds,to:nil),ids[2]:group.convert(group.bounds,to:nil),"native-window":window.frame]
        }
        var result=[String:NSRect]()
        for id in ids {
            guard let frame=frames[id],frame.width>0,frame.height>0 else {throw Failure(description:"Update native geometry missing "+id+"; ids="+snapshot.ids.sorted().joined(separator:",")+"; AX="+snapshot.diagnostics.joined(separator:"\n"))}
            result[id]=frame
        }
        return result
    }
    @MainActor static func requireGeometry(_ expected:[String:NSRect],_ owner:ReleaseUpdateWindowController,_ phase:String)throws {
        let actual=try geometry(owner)
        for (id,frame) in expected {
            guard let next=actual[id] else {throw Failure(description:"Update geometry lost "+id)}
            let positionMatches = abs(frame.minX-next.minX)<1 && abs(frame.minY-next.minY)<1 && abs(frame.width-next.width)<1 && abs(frame.height-next.height)<1
            try require(positionMatches,"Updates native list/feedback/operations shifted at "+phase+": "+id+" \(frame) -> \(next)")
        }
    }
    @MainActor static func observeNativePresentation(_ owner:ReleaseUpdateWindowController,expected:[String],phase:String)throws {
        guard let window=owner.window,let view=window.contentView else{throw Failure(description:"Updates rendering owner missing")}
        view.layoutSubtreeIfNeeded()
        let snapshot=accessibility(window)
        if !hostingTreeAbsent(window) {
            let text=snapshot.labels.joined(separator:" ")
            try require(expected.allSatisfy{text.localizedCaseInsensitiveContains($0)},"Populated Updates AX tree omitted text at "+phase+": "+snapshot.diagnostics.joined(separator:"\n"));return
        }
        print("Updates observation \(phase): actual native list/scroll/group geometry checked; prohibited host has zero SwiftUI AX children/navigation. Public labels/IDs and VoiceOver acceptance remain unverified. PublicIDs="+snapshot.ids.sorted().joined(separator:",")+"; nativeViews=\(views(window.contentView).count)")
    }
    @MainActor static func verifyNativeRows(_ table:NSTableView,owner:ReleaseUpdateWindowController)async throws {
        var buttons=[NSButton](),checkboxes=[NSObject]()
        func checkbox(_ root:NSView)->NSObject? {
            var seen=Set<ObjectIdentifier>(),budget=256
            func visit(_ value:Any)->NSObject? {
                guard budget>0,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return nil};budget -= 1
                if ax(object,"accessibilityRole") as? String == "AXCheckBox" {return object}
                let children=ax(object,"accessibilityChildren") as? [Any] ?? []
                for child in NSAccessibility.unignoredChildren(from:children) {if let found=visit(child){return found}}
                if let view=value as? NSView {for child in view.subviews {if let found=visit(child){return found}}}
                return nil
            }
            return visit(root)
        }
        for row in owner.model.assets.indices {
            guard let view=table.rowView(atRow:row,makeIfNecessary:true) else{throw Failure(description:"Release native row missing: \(row)")}
            view.layoutSubtreeIfNeeded()
            let candidates=views(view).compactMap{$0 as? NSButton}
            if candidates.count==1 {buttons.append(candidates[0])}
            if let value=checkbox(view){checkboxes.append(value)}
            try require(table.rect(ofRow:row).height>0,"Release row has no actual native geometry")
        }
        if buttons.count==owner.model.assets.count {
            for (index,button) in buttons.enumerated() {
                let asset=owner.model.assets[index]
                try require(button.isEnabled==owner.model.canSelect(asset) && (button.state == .on)==owner.model.selected.contains(asset.id),"Actual release checkbox checked/enabled state differs: \(asset.name)")
            }
            let asset=owner.model.assets[1],selection=owner.model.selected
            buttons[1].performClick(nil);try await wait{owner.model.selected==selection.union([asset.id])}
            buttons[1].performClick(nil);try await wait{owner.model.selected==selection}
            buttons[2].performClick(nil)
            try require(owner.model.selected==selection && !buttons[2].isEnabled,"Disabled digest-less native checkbox changed selection")
            print("Updates actual native row checkbox states/enabledness and exact asset-binding actions passed")
        } else if checkboxes.count==owner.model.assets.count {
            for (index,checkbox) in checkboxes.enumerated() {
                let asset=owner.model.assets[index],enabled=(checkbox as? NSAccessibilityProtocol)?.isAccessibilityEnabled() ?? (ax(checkbox,"accessibilityEnabled") as? NSNumber)?.boolValue
                try require(enabled==owner.model.canSelect(asset) && ((ax(checkbox,"accessibilityValue") as? NSNumber)?.intValue==1)==owner.model.selected.contains(asset.id),"Public native checkbox state/enablement differs from exact asset")
            }
            func press(_ checkbox:NSObject)->Bool {
                if let element=checkbox as? NSAccessibilityProtocol {return element.accessibilityPerformPress()}
                let selector=NSSelectorFromString("accessibilityPerformAction:")
                guard checkbox.responds(to:selector) else{return false}
                _ = checkbox.perform(selector,with:"AXPress");return true
            }
            let selection=owner.model.selected,id=owner.model.assets[1].id
            try require(press(checkboxes[1]),"Native row checkbox refused public press")
            try await wait{owner.model.selected==selection.union([id])}
            try require(press(checkboxes[1]),"Native row checkbox refused second public press")
            try await wait{owner.model.selected==selection}
            print("Updates public native/legacy AX checkbox states/enabledness and exact asset-binding actions passed")
        } else {
            // SwiftUI may draw the Toggle inside a CellHostingView without an
            // NSButton or public AX descendants in a prohibited receiver.
            // Retain real row structure/rendering and original model gates;
            // do not manufacture an accessibility action or certify VoiceOver.
            try require(hostingTreeAbsent(owner.window!),"Populated Updates accessibility tree has no actual row checkbox observer")
            print("Updates checkbox observation unavailable: prohibited host supplies no SwiftUI AX subtree and \(buttons.count)/\(owner.model.assets.count) native row buttons; actual list rows and original exact asset/context/selection/digest gates remain checked, native toggle labels/gestures and VoiceOver unverified")
        }
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
        try require(TurtleGitHelp.context(owner.window) == .updates,"Update window lost its contextual manual")
        owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        var reply:CheckedContinuation<[PublishedRelease],Error>?,results=0,fetches=0
        model.fetch={repository,preview in try require(repository==repo && !preview,"Wrong captured channel");fetches+=1;return try await withCheckedThrowingContinuation {reply=$0}}
        model.onResult={results+=1};let stale=model.context
        model.check();model.check();try await wait {reply != nil}
        try require(fetches==1 && model.busy && ReleaseUpdateModel.activeOperations==1,"Duplicate feed request")
        reply?.resume(returning:[value]);reply=nil;try await wait {!model.busy}
        try require(results==1 && model.available && model.selected==[1] && prefs.object(forKey:"TurtleGit.LastVersionCheck") != nil,"Release result/default main archive missing")
        try await wait {views(owner.window?.contentView).compactMap{$0 as? NSTableView}.contains{$0.numberOfRows==value.assets.count}}
        let list=views(owner.window?.contentView).compactMap{$0 as? NSTableView}.first{$0.numberOfRows==value.assets.count}!
        try require(list.enclosingScrollView != nil && list.usesAlternatingRowBackgroundColors && list.rowHeight>0,"Release files are not actual alternating native list rows")
        let stableGeometry=try geometry(owner),assetIDs=accessibility(owner.window!).frames
        if !hostingTreeAbsent(owner.window!) {
            for asset in value.assets {try require(assetIDs["release-asset-\(asset.id)"]?.isEmpty==false,"Native release row lacks exact asset identity: \(asset.id)")}
        }
        try await verifyNativeRows(list,owner:owner)
        try observeNativePresentation(owner,expected:value.assets.map(\.name)+["Download"],phase:"available assets")
        model.select(value.assets[1],checked:true,context:stale);model.select(value.assets[2],checked:true,context:model.context)
        try require(model.selected==[1] && !model.canSelect(value.assets[2]),"Stale or digest-less selection accepted")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_UPDATE_CAPTURE"] {try await capture(owner.window!,name:"release-update-source",folder:URL(fileURLWithPath:path))}
        owner.window?.orderFront(nil)
        var folderReply:CheckedContinuation<URL?,Never>?
        model.chooseFolder={_ in await withCheckedContinuation {folderReply=$0}}
        model.download();model.download();try await wait {folderReply != nil}
        try require(model.downloadPending && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Download chooser ownership missing")
        await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded()
        try observeNativePresentation(owner,expected:["Abort"],phase:"held chooser");try requireGeometry(stableGeometry,owner,"held chooser")
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
        await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded()
        try observeNativePresentation(owner,expected:["Show in Finder"],phase:"completed downloads");try requireGeometry(stableGeometry,owner,"completed downloads")
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
        model.transfer={_,_,_ in throw NSError(domain:"TurtleGit.PrivateUpdateLayout",code:27,userInfo:[NSLocalizedDescriptionKey:String(repeating:"Long private download diagnostic\n",count:100)])}
        model.download();try await wait{!model.downloadPending && model.error?.contains("Long private download diagnostic")==true}
        try requireGeometry(stableGeometry,owner,"multiline download failure")
        model.disableAutomatic();try require(prefs.object(forKey:"VersionCheck") as? Bool == false && model.retired,"Don't ask preference/owned close failed")
        try await verifyNativeFolderFence(root:root.appendingPathComponent("native-folder-fence"),preferences:prefs,release:value)
        try await verifyDownloadProgressIdentity(root:root.appendingPathComponent("progress-identity"),preferences:prefs,release:value)
        print("PASS native release downloads: source list/defaults, captured feed, original choices, owned/injected folder Cancel and Abort, two verified private-file installs, no overwrite, digest failure, Finder/release targets and private preference")
    }
    @MainActor static func verifyNativeFolderFence(root:URL,preferences:UserDefaults,release:PublishedRelease)async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for mode in ["accepted","aborted","closed"] {
            let destination=root.appendingPathComponent(mode);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            let model=ReleaseUpdateModel(preferences:preferences,installed:"1.0.0",repository:repo,appStore:false)
            let owner=ReleaseUpdateWindowController(model:model);owner.window?.alphaValue=0;owner.window?.orderFront(nil)
            defer{model.abort();owner.close()}
            model.fetch={_,_ in [release]};model.check();try await wait{!model.busy}
            var panel:NSOpenPanel?,earlyReply:((URL?)->Void)?,transfers=0,closed=0
            owner.onClosed={closed += 1}
            model.presentFolder={ [weak owner] chooser,parent,reply in
                panel=chooser;earlyReply=reply
                precondition(parent===owner?.window && chooser.canChooseDirectories && !chooser.canChooseFiles && !chooser.allowsMultipleSelection && chooser.alphaValue==0)
                chooser.beginSheetModal(for:parent){reply($0 == .OK ? chooser.url:nil)}
            }
            model.transfer={_,stage,progress in transfers += 1;progress(Int64(bytes.count));try bytes.write(to:stage)}
            model.download();try await wait{panel?.sheetParent === owner.window}
            earlyReply?(destination);earlyReply?(nil)
            model.download()
            try require(model.downloadPending && ReleaseUpdateModel.activeOperations==1 && transfers==0 && model.downloaded.isEmpty,"Early native folder reply released ownership or began transfer before detach")
            try require(!owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Native folder handoff lost Close/Quit ownership")
            if mode=="accepted" {
                owner.window?.endSheet(panel!,returnCode:.cancel);panel?.orderOut(nil)
                try await wait{!model.downloadPending && ReleaseUpdateModel.activeOperations==0}
                try require(transfers==1 && model.downloaded.count==1 && model.error==nil,"Accepted native folder handoff did not resume once after detach")
                let saved=try Data(contentsOf:destination.appendingPathComponent(release.assets[0].name))
                try require(saved==bytes && model.statuses[release.assets[0].id]?.contains("SHA-256 verified")==true,"Native folder handoff published unverified content")
                owner.close();try await wait{closed==1}
            } else {
                if mode=="aborted" {model.abort();model.abort()}
                else {owner.close();try require(model.retired && closed==0,"Forced Close released its callback before native folder drainage")}
                try require(model.downloadPending && ReleaseUpdateModel.activeOperations==1 && transfers==0,"Abort/Close prematurely retired native chooser operation")
                earlyReply?(destination)
                try await wait{!model.downloadPending && panel?.sheetParent==nil && owner.window?.attachedSheet==nil && ReleaseUpdateModel.activeOperations==0}
                let files=try FileManager.default.contentsOfDirectory(atPath:destination.path)
                try require(transfers==0 && files.isEmpty && model.downloaded.isEmpty,"Cancelled/retired native folder reply transferred or published files")
                if mode=="closed" {try await wait{closed==1}}
                else {owner.close();try await wait{closed==1}}
            }
            earlyReply?(destination)
            try require(panel?.sheetParent==nil && owner.window?.attachedSheet==nil && ReleaseUpdateModel.activeOperations==0,"Late folder reply revived a retired operation or sheet")
        }
        print("PASS: Updates actual hidden folder sheet early acceptance, exact-once detach handoff, Abort/forced Close and late-reply ownership")
    }
    @MainActor static func verifyDownloadProgressIdentity(root:URL,preferences:UserDefaults,release:PublishedRelease)async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let model=ReleaseUpdateModel(preferences:preferences,installed:"1.0.0",repository:repo,appStore:false)
        let current=ReleaseUpdateWindowController(model:model);current.window?.alphaValue=0;defer{model.abort();current.close()}
        model.fetch={_,_ in [release]};model.check();try await wait{!model.busy}
        model.chooseFolder={_ in root}
        var firstProgress:(@Sendable(Int64)->Void)?,secondProgress:(@Sendable(Int64)->Void)?
        var first:CheckedContinuation<Void,Error>?,second:CheckedContinuation<Void,Error>?,attempts=0
        defer{let a=first,b=second;first=nil;second=nil;a?.resume(throwing:CancellationError());b?.resume(throwing:CancellationError())}
        model.transfer={_,stage,progress in
            attempts += 1
            if attempts==1 {firstProgress=progress;try await withCheckedThrowingContinuation{first=$0}}
            else {secondProgress=progress;try await withCheckedThrowingContinuation{second=$0};try bytes.write(to:stage)}
        }
        model.download();try await wait{first != nil};model.abort()
        let finishFirst=first;first=nil;finishFirst?.resume()
        try await wait{!model.downloadPending && ReleaseUpdateModel.activeOperations==0}
        try require(model.downloaded.isEmpty,"Aborted first batch published content")
        model.download();try await wait{second != nil}
        let statuses=model.statuses
        var watching=true,staleProgress=false
        let observation=model.$progress.dropFirst().sink{value in if watching && value>0.6 {staleProgress=true}}
        defer{observation.cancel()}
        firstProgress?(Int64(bytes.count))
        secondProgress?(Int64(bytes.count/3))
        try await wait{model.progress>0 && model.progress<0.6}
        await Task.yield();await Task.yield()
        try require(!staleProgress && model.statuses==statuses && model.downloaded.isEmpty && ReleaseUpdateModel.activeOperations==1,"Previous batch progress retargeted held successor")
        watching=false
        let finishSecond=second;second=nil;finishSecond?.resume()
        try await wait{!model.downloadPending && ReleaseUpdateModel.activeOperations==0}
        try require(attempts==2 && model.downloaded.count==1 && model.progress==1 && model.error==nil,"Current successor download did not publish independently")
        print("PASS: Updates previous-batch progress cannot retarget a held successor with the same asset ID")
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
        // The retired controller owns its old worker drain, while a fresh forced
        // quiet request must still be able to create and present its own result.
        do {
            let service=ReleaseUpdateService()
            let old=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:false)
            let fresh=ReleaseUpdateModel(preferences:prefs,installed:"1.0.0",repository:QA.repo,appStore:false)
            var oldReply:CheckedContinuation<[PublishedRelease],Error>?,freshReply:CheckedContinuation<[PublishedRelease],Error>?
            var creates=0,oldFetches=0,freshFetches=0,oldClosed=0,displayed=[ReleaseUpdateWindowController]()
            defer {
                old.cancel();fresh.cancel();service.cancelBackground()
                let a=oldReply,b=freshReply;oldReply=nil;freshReply=nil
                a?.resume(throwing:CancellationError());b?.resume(throwing:CancellationError())
                displayed.forEach{$0.close()}
            }
            old.fetch={_,_ in oldFetches += 1;return try await withCheckedThrowingContinuation{oldReply=$0}}
            fresh.fetch={_,_ in freshFetches += 1;return try await withCheckedThrowingContinuation{freshReply=$0}}
            service.createModel={_ in creates += 1;return creates==1 ? old:fresh}
            service.display={controller in controller.window?.alphaValue=0;controller.window?.orderFront(nil);displayed.append(controller)}
            service.showCommand(visible:true,force:false,preferences:prefs)
            try await QA.wait{oldReply != nil}
            guard let prior=service.controller else{throw QA.Failure(description:"Held old Updates controller missing")}
            let retiredRelease=prior.onClosed
            prior.onClosed={oldClosed += 1;retiredRelease()}
            prior.close()
            try QA.require(old.retired && oldClosed==0 && ReleaseUpdateModel.activeOperations==1,"Old Updates owner did not retain held fetch drainage")
            service.showCommand(visible:false,force:true,preferences:prefs)
            try await QA.wait{freshReply != nil}
            try QA.require(creates==2 && oldFetches==1 && freshFetches==1 && service.background === fresh && service.controller==nil && ReleaseUpdateModel.activeOperations==2,"Retired controller suppressed or duplicated fresh forced quiet request")
            let finishFresh=freshReply;freshReply=nil;finishFresh?.resume(returning:[value])
            try await QA.wait{service.controller?.model === fresh && !fresh.busy}
            guard let next=service.controller else{throw QA.Failure(description:"Fresh forced Updates result did not present")}
            try QA.require(next !== prior && displayed.count==2 && oldClosed==0 && ReleaseUpdateModel.activeOperations==1,"Fresh result reused old owner or lost old worker lease")
            let finishOld=oldReply;oldReply=nil;finishOld?.resume(returning:[value])
            try await QA.wait{oldClosed==1 && ReleaseUpdateModel.activeOperations==0}
            retiredRelease();prior.close()
            try QA.require(service.controller === next && next.model === fresh && !fresh.retired && displayed.count==2 && creates==2 && oldFetches==1 && freshFetches==1 && oldClosed==1,"Retired Updates completion cleared/reopened/refetched the successor")
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
