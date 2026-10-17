import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@main struct SendSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Send source wait at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func minimum(_ window:NSWindow,_ size:NSSize)->Bool {
        let constraints=window.contentView?.constraints.filter {$0.isActive && $0.relation == .greaterThanOrEqual} ?? []
        return constraints.contains {$0.firstAttribute == .width && $0.constant==size.width} && constraints.contains {$0.firstAttribute == .height && $0.constant==size.height}
    }
    @MainActor static func capture(_ window:NSWindow,name:String)async throws {
        guard let output=ProcessInfo.processInfo.environment["TURTLEGIT_SEND_SOURCE_CAPTURE"] else{return}
        if #available(macOS 14.4,*) {
            let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned Send capture absent")}
                let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
                guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"No Send PNG")}
                try png.write(to:directory.appendingPathComponent(name+"-"+theme+".png"))
            };window.alphaValue=0
        } else{throw Failure(description:"Capture requires macOS 14.4")}
    }
    @MainActor static func cleanup()async {
        for window in NSApp.windows {
            if let owner=window.delegate as? SendPatchWindowController {owner.close()}
            if let owner=window.delegate as? SendPatchProgressWindowController {owner.close()}
            if let owner=window.delegate as? ImportPatchWindowController {owner.close()}
            if let owner=window.delegate as? WorkingTreePatchWindowController {owner.close()}
        }
        for _ in 0..<3000 {if SendPatchWindowModel.activeLoads==0 && SendPatchWindowController.activeTargetReads==0{return};try? await Task.sleep(nanoseconds:10_000_000)}
    }
    @MainActor static func main()async {NSApp.setActivationPolicy(.prohibited);do{try await verify();await cleanup()}catch{await cleanup();fputs("FAIL Send source: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let files=[root.appendingPathComponent("first 雪.patch"),root.appendingPathComponent("second.patch")]
        for (index,file) in files.enumerated() {try Data("Subject: Source patch \(index)\n\nPrivate patch body \(index)\n".utf8).write(to:file)}
        let suite="TurtleGit.SendSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let nfc="René <one@example.invalid>",nfd="Rene\u{301} <one@example.invalid>"
        prefs.set([nfc,nfd],forKey:"SendMail.Addresses")
        let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
        let owner=SendPatchWindowController(files:files,delivery:.smtp,preferences:prefs,repository:repo,presentation:{_ in})
        defer {owner.close()};let model=owner.model;try require(minimum(owner.window!,NSSize(width:620,height:380)),"Options minimum lost after host attachment");owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        var submitted:SendPatchRequest?;model.onSubmit={submitted=$0}
        try await wait {model.pendingLoads==0 && views(owner.window?.contentView).compactMap {$0 as? SendPatchAddressCombo}.count==2}
        let combos=views(owner.window?.contentView).compactMap {$0 as? SendPatchAddressCombo}
        let to=combos.first {$0.accessibilityLabel()=="To addresses"}!,cc=combos.first {$0.accessibilityLabel()=="CC addresses"}!
        let delegate=to.delegate as! SendPatchAddressField.Coordinator
        to.stringValue=nfc;delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:to))
        cc.stringValue=nfd;(cc.delegate as! SendPatchAddressField.Coordinator).controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:cc))
        try require(model.to.utf8.elementsEqual(nfc.utf8) && model.cc.utf8.elementsEqual(nfd.utf8) && to.numberOfItems==2,"Native recipients/history lost exact spelling")
        let old=model.formContext,subject=model.subjectBinding(context:old)
        subject.wrappedValue="readonly";try require(model.combinedSubject.isEmpty,"Separate-patch subject accepted write")
        model.combineBinding(context:old).wrappedValue=true;model.subjectBinding(context:model.formContext).wrappedValue="Combined subject"
        let retiredSubject=model.subjectBinding(context:model.formContext)
        model.combineBinding(context:model.formContext).wrappedValue=false;model.combineBinding(context:model.formContext).wrappedValue=true
        retiredSubject.wrappedValue="stale";try require(model.combinedSubject=="Combined subject","Combine round trip revived subject callback")
        let retainedTo=model.field(\.to,context:model.formContext)
        var child=false;model.childActive={child}
        child=true;model.retireForm();retainedTo.wrappedValue="locked";child=false;model.retireForm();retainedTo.wrappedValue="stale"
        try require(model.to.utf8.elementsEqual(nfc.utf8),"Child lifetime revived recipient binding")
        let table=views(owner.window?.contentView).compactMap {$0 as? SendPatchTable}.first!
        model.showPatch={_ in};model.applyPatches={_ in};model.reviewPatch={_ in}
        model.setHighlighted([model.rows[0].id]);try await wait {table.selectedRowIndexes==IndexSet(integer:0)}
        let menu=table.contextMenuForSelection()!;var opened=0;model.showPatch={_ in opened+=1}
        model.retireForm();menu.performActionForItem(at:0)
        try require(opened==0,"Retired native menu opened a viewer")
        model.combineBinding(context:model.formContext).wrappedValue=false;model.refreshPreview()
        try await wait {model.pendingLoads==0 && model.subject=="Source patch 0" && to.isEnabled}
        to.isEnabled=false;to.stringValue="disabled";delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:to));to.isEnabled=true
        try require(model.to.utf8.elementsEqual(nfc.utf8),"Disabled address notification changed recipients")
        // Force a real view refresh after the direct disabled-control probe.
        model.retireForm();try await wait {to.stringValue.utf8.elementsEqual(model.to.utf8)}
        try await capture(owner.window!,name:"send-patch-source")
        model.combineBinding(context:model.formContext).wrappedValue=true
        model.subjectBinding(context:model.formContext).wrappedValue="Combined subject";model.field(\.attachment,context:model.formContext).wrappedValue=true
        model.submit(context:model.formContext);model.submit(context:model.formContext)
        try await wait {model.pendingLoads==0}
        guard let request=submitted else{throw Failure(description:"No captured prepared mail")}
        try require(request.files==files && request.messages.count==1 && request.options.subject=="Combined subject" && request.options.attachment,"Captured ordered combined preparation changed")
        let addresses=prefs.stringArray(forKey:"SendMail.Addresses")!
        try require(addresses.filter {$0.utf8.elementsEqual(nfc.utf8)}.count==1 && addresses.filter {$0.utf8.elementsEqual(nfd.utf8)}.count==1,"Source wcscmp history identity collapsed canonical spellings")
        try require(to.lifetime.retired && table.lifetime.retired,"Closed options controls did not retire")
        let before=model.to;delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:to));try require(model.to==before,"Retired native delegate changed address")
        let progressModel=SendPatchProgressModel(request:request,repository:repo,access:nil,preferences:prefs,submission:{_,notify in
            notify(.sending(index:0,total:1,attempt:1));notify(.accepted(index:0,response:250));return [SMTPReceipt(response:250)]
        })
        let progress=SendPatchProgressWindowController(model:progressModel);defer {progress.close()};progressModel.close={}
        try require(minimum(progress.window!,NSSize(width:600,height:320)),"Progress minimum lost after host attachment");progress.window!.alphaValue=0;progress.window!.orderFront(nil);progressModel.start();try await wait {!progressModel.busy}
        try require(progressModel.success && progressModel.accepted==1,"Injected local progress did not complete")
        try await capture(progress.window!,name:"send-progress-source")
        // A real held metadata helper belongs to its target chooser through forced close.
        let shim=root.appendingPathComponent("target-git"),marker=root.appendingPathComponent("target-started")
        let script="""
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = rev-parse ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > '\(marker.path)'
            wait "$task_child"
          fi
        done
        exec '\(git.path)' "$@"
        """
        try Data(script.utf8).write(to:shim);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
        var presentations=0,replies:[(NSApplication.ModalResponse)->Void]=[]
        let choosing=SendPatchWindowController(files:files,preferences:prefs,repository:GitRepository(root:root,executable:shim),presentation:{_ in presentations+=1},choosePatchTarget:true)
        defer {choosing.close()};choosing.presentTargetPanel={_,_,reply in replies.append(reply)};choosing.selectedTarget={_ in root}
        choosing.model.apply(Set(choosing.model.rows.map(\.id)),context:choosing.model.formContext)
        try require(replies.count==1 && !choosing.model.canInteract,"Target chooser not owned")
        replies[0](.OK);replies[0](.OK)
        try await wait {(try? String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).count)==2}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
        try require(SendPatchWindowController.activeTargetReads==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Target read lost Quit ownership or duplicated")
        choosing.close();replies[0](.OK)
        try await wait {SendPatchWindowController.activeTargetReads==0 && pids.allSatisfy {kill($0,0) != 0 && errno==ESRCH}}
        try require(presentations==0 && choosing.model.error==nil && choosing.targetPicker==nil,"Retired target read published a child or error")
        print("PASS Send source: native exact recipients/history, combined/separate subjects, captured list/forms and prepared bytes, owned target read cancellation/Quit; progress uses injected acceptance, no external mail")
    }
}
