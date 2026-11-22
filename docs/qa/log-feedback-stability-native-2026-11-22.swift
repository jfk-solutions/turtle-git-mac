// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum LogFeedbackStabilityVerification {
    struct Failure:Error,LocalizedError {
        let text:String
        var errorDescription:String? {text}
    }
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {
        if !condition {throw Failure(text:"Log feedback \(line): \(message)")}
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {
        guard let value else {throw Failure(text:message)};return value
    }
    static func views(_ view:NSView?)->[NSView] {
        guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}
    }
    static func wait(_ label:String,window:NSWindow? = nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if ready(){return};try await Task.sleep(nanoseconds:10_000_000)
        }
        throw Failure(text:"Log feedback timeout \(line): "+label)
    }
    @MainActor final class Gate<Value> {
        var entered=false
        private var reply:CheckedContinuation<Value,Error>?
        private(set) var token:OperationCancellation?
        func read(_ token:OperationCancellation)async throws->Value {
            self.token=token;entered=true
            return try await withCheckedThrowingContinuation{self.reply=$0}
        }
        func finish(_ value:Result<Value,Error>) {
            let old=reply;reply=nil;old?.resume(with:value)
        }
    }
    @MainActor final class Context {
        let base:URL,git:URL,suite="TurtleGit.LogFeedback."+UUID().uuidString
        let preferences:UserDefaults,clipboard=NSPasteboard.withUniqueName()
        var original:GitRepository!,repository:GitRepository!,owner:LogWindowController?
        var patch:Gate<Data>?,note:Gate<(CommitNoteSnapshot,ProjectDialogSettings)>?
        var windows:[NSWindow]=[]
        var head="",index=Data(),bytes=Data(),initialConfig=Data()
        var root:URL {base.appendingPathComponent("repository")}
        var holdLog:URL {base.appendingPathComponent("hold-log")}
        var holdShow:URL {base.appendingPathComponent("hold-show")}
        var enteredLog:URL {base.appendingPathComponent("entered-log")}
        var enteredShow:URL {base.appendingPathComponent("entered-show")}
        init(base:URL,git:URL) {
            self.base=base.standardizedFileURL;self.git=git
            preferences=UserDefaults(suiteName:suite)!
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"] {preferences.set(false,forKey:key)}
        }
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            original=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _ = try await original.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Log Feedback QA"),("user.email","feedback@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await original.run(["config",key,value])}
            for n in 0..<3 {
                for file in 0..<4 {try Data("revision \(n) file \(file)\n".utf8).write(to:root.appendingPathComponent("file\(file).txt"))}
                try await original.stage((0..<4).map{"file\($0).txt"})
                _ = try await original.commit(message:"Feedback revision \(n)")
            }
            head=try await original.rebaseCommit("HEAD").hash
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            bytes=try Data(contentsOf:root.appendingPathComponent("file0.txt"))
            initialConfig=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            let wrapper=base.appendingPathComponent("held-helper")
            let script="""
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = log ] && [ -f \(quote(holdLog.path)) ]; then
                : > \(quote(enteredLog.path))
                while [ -f \(quote(holdLog.path)) ]; do /bin/sleep 0.05; done
              fi
              if [ "$argument" = show ] && [ -f \(quote(holdShow.path)) ]; then
                : > \(quote(enteredShow.path))
                while [ -f \(quote(holdShow.path)) ]; do /bin/sleep 0.05; done
              fi
            done
            exec \(quote(git.path)) "$@"
            """
            try script.write(to:wrapper,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            repository=GitRepository(root:root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
            let controller=LogWindowController(repository:repository,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owner=controller;controller.model.clipboard=clipboard
            controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-24000,y:-24000));controller.showWindow(nil)
            (controller.window as? LogHistoryWindow)?.commandKeyWindow={ [weak controller] in controller?.window }
            try await wait("Log native frame anchors",window:controller.window) {
                let all=views(controller.window?.contentView)
                return all.contains{$0.identifier?.rawValue=="Log.Footer"} && all.contains{($0 as? LogPaneLayoutBridge.Probe)?.restored==true}
            }
        }
        func remove(_ url:URL){try? FileManager.default.removeItem(at:url)}
        func preserve()async throws {
            try require(try await original.rebaseCommit("HEAD").hash==head,"Feedback changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Feedback changed index bytes")
            try require(try Data(contentsOf:root.appendingPathComponent("file0.txt"))==bytes,"Feedback changed working files")
        }
        func cleanup()async throws {
            remove(holdLog);remove(holdShow)
            patch?.finish(.failure(OperationCancellationFailure.cancelled))
            note?.finish(.failure(OperationCancellationFailure.cancelled))
            let model=owner?.model
            model?.closeFeedbackDetails();model?.readPatchPreview=nil;model?.readNote=nil
            model?.prepareNoteIdentity=nil;model?.onShowNote=nil
            owner?.close()
            for window in windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
            try await wait("owned Log workers drained") {
                LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 &&
                    LogWindowModel.activeNoteReads==0 && LogWindowModel.activeHistoryProjectionWorkers==0 &&
                    model?.patchPreviewLoading != true && model?.patchPreferenceSaving != true && model?.copyingDetails != true
            }
            if !initialConfig.isEmpty {try initialConfig.write(to:root.appendingPathComponent(".git/config"))}
            preferences.removePersistentDomain(forName:suite);clipboard.releaseGlobally()
        }
    }
    @MainActor final class InformationState:ObservableObject {@Published var text="One information line"}
    struct InformationHost:View {
        @ObservedObject var state:InformationState
        var body:some View {LogInformationBand(text:state.text)}
    }
    static func informationLines(_ context:Context)async throws {
        let state=InformationState()
        let host=NSHostingController(rootView:InformationHost(state:state));host.sizingOptions=[]
        let window=NSWindow(contentRect:NSRect(x:-24000,y:-24000,width:600,height:30),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0;window.contentViewController=host;context.windows.append(window)
        window.setContentSize(NSSize(width:600,height:30));window.orderFront(nil)
        defer{window.close()}
        try await wait("actual information component",window:window){views(window.contentView).contains{$0.identifier?.rawValue=="Log.Information"}}
        let band=try unwrap(views(window.contentView).first{$0.identifier?.rawValue=="Log.Information"},"Information component native anchor missing")
        window.contentView?.layoutSubtreeIfNeeded()
        let original=band.convert(band.bounds,to:nil),frame=window.frame
        try require(abs(original.height-30)<=0.5,"Information component lost fixed30-point slot")
        // Explicit breaks ensure exactly one and two logical lines, without
        // pretending that this small real repository's counts must soft-wrap.
        for text in ["One information line","First information line\nSecond information line",String(repeating:"More complete information remains in native help. ",count:30)] {
            state.text=text
            for _ in 0..<8 {
                window.contentView?.layoutSubtreeIfNeeded()
                try require(band.convert(band.bounds,to:nil)==original && window.frame==frame,"One/two/overflow information content moved its actual native slot")
                try await Task.sleep(nanoseconds:15_000_000)
            }
        }
    }
    static func geometry(_ window:NSWindow)throws->[String:NSRect] {
        let all=views(window.contentView)
        var result:[String:NSRect]=[:]
        for name in ["Log.Information","Log.Feedback","Log.Footer"] {
            let view=try unwrap(all.first{$0.identifier?.rawValue==name},"Missing actual native band "+name)
            result[name]=view.convert(view.bounds,to:nil)
        }
        let split=try unwrap(all.compactMap{$0 as? LogPaneLayoutBridge.Probe}.first?.split,"Missing actual Log split")
        result["panes"]=split.convert(split.bounds,to:nil)
        try require(split.arrangedSubviews.count==3,"Log lost its three panes")
        for (index,pane) in split.arrangedSubviews.enumerated() {result["pane\(index)"]=pane.convert(pane.bounds,to:nil)}
        if let history=views(split.arrangedSubviews[0]).compactMap({$0 as? HistoryTableView}).first,let header=history.headerView {result["history header"]=header.convert(header.bounds,to:nil)}
        if let files=views(split.arrangedSubviews[2]).compactMap({$0 as? NSTableView}).first,let header=files.headerView {result["file header"]=header.convert(header.bounds,to:nil)}
        try require(result["history header"] != nil && result["file header"] != nil,"Native report headers missing")
        return result
    }
    static func check(_ label:String,window:NSWindow,baseline:[String:NSRect])async throws {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            let next=try geometry(window)
            try require(next.keys.count==baseline.keys.count,"Geometry identity changed during "+label)
            for (key,expected) in baseline {
                let actual=try unwrap(next[key],"Missing "+key)
                try require(abs(actual.minX-expected.minX)<=0.5 && abs(actual.minY-expected.minY)<=0.5 && abs(actual.width-expected.width)<=0.5 && abs(actual.height-expected.height)<=0.5,
                    "\(label) moved \(key): expected=\(expected), actual=\(actual)")
            }
            try await Task.sleep(nanoseconds:15_000_000)
        }
    }
    static func settledGeometry(_ window:NSWindow)async throws->[String:NSRect] {
        var previous:[String:NSRect]?,same=0
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            let current=try geometry(window)
            same=previous==current ? same+1:0;previous=current
            if same>=3{return current}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw Failure(text:"Log native layout never settled before phase")
    }
    static func closeDetails(_ model:LogWindowModel,window:NSWindow)async throws {
        let owned=NSApp.windows.filter{$0.isVisible && views($0.contentView).contains{$0.identifier?.rawValue=="Log.FeedbackDetails"}}
        model.closeFeedbackDetails()
        try await wait("feedback popover detached",window:window) {
            model.feedbackDetails==nil && owned.allSatisfy{!$0.isVisible} &&
                !NSApp.windows.contains{$0.isVisible && views($0.contentView).contains{$0.identifier?.rawValue=="Log.FeedbackDetails"}}
        }
    }
    static func feedbackButton(_ window:NSWindow)throws->NSButton {
        try unwrap(views(window.contentView).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue=="Log.FeedbackDisclosure"},"Native Log feedback disclosure missing")
    }
    static func showDetails(_ context:Context,window:NSWindow)async throws->LogFeedbackDetailsSnapshot {
        let model=context.owner!.model,button=try feedbackButton(window)
        try await wait("rendered native feedback control",window:window) {button.isEnabled && button.toolTip==model.feedbackPresentation.text}
        try require(button.accessibilityValue() as? String==model.feedbackPresentation.text,"Native AX lost full unflattened status")
        button.performClick(nil)
        try await wait("actual feedback popover",window:window) {
            model.feedbackDetails != nil && NSApp.windows.contains{$0.isVisible && views($0.contentView).contains{$0.identifier?.rawValue=="Log.FeedbackDetails"}}
        }
        let snapshot=try unwrap(model.feedbackDetails,"Status snapshot missing")
        let popover=try unwrap(NSApp.windows.first{$0.isVisible && views($0.contentView).contains{$0.identifier?.rawValue=="Log.FeedbackDetails"}},"Native feedback popover missing")
        context.windows.append(popover)
        popover.contentView?.layoutSubtreeIfNeeded()
        let body=try unwrap(views(popover.contentView).first{$0.identifier?.rawValue=="Log.FeedbackDetails"},"Feedback details native content anchor missing")
        let content=body.convert(body.bounds,to:nil)
        let chrome=NSSize(width:popover.frame.width-content.width,height:popover.frame.height-content.height)
        let scrollFrames=views(popover.contentView).compactMap{$0 as? NSScrollView}.map{$0.convert($0.bounds,to:nil)}
        print("Log feedback dimensions: content=\(content), window=\(popover.frame), chrome=\(chrome), native scrolls=\(scrollFrames)")
        // The source body reserves a440pt viewport,24pt horizontal padding and
        // at most260pt of text. Its headline/Copy/spacing/padding stay within
        // the remaining100pt. NSPopover's native arrow/chrome are not text.
        try require(abs(content.width-464)<=0.5 && content.height>=30 && content.height<=360.5,
            "Feedback detail content escaped its viewport/body bounds: content=\(content), window=\(popover.frame)")
        try require(chrome.width>=0 && chrome.height>=0 && chrome.width<=64 && chrome.height<=64 && popover.frame.width<=520,
            "Feedback detail native window escaped bounded chrome: content=\(content), window=\(popover.frame), chrome=\(chrome)")
        try require(snapshot.text.utf8.elementsEqual(model.feedbackPresentation.text.utf8),"Popover snapshot altered diagnostic bytes")
        return snapshot
    }
    static func phases(_ context:Context,window:NSWindow,baseline:[String:NSRect],name:String)async throws {
        let model=context.owner!.model
        model.select([]);try await check(name+" no selection information",window:window,baseline:baseline)
        let short=HistoryLabels.information(model.information)
        model.select([context.head])
        try await wait("actual selected revision files",window:window) {!model.busy && model.files.count==4 && LogWindowModel.activeActionReads==0}
        let long=HistoryLabels.information(model.information)
        try require(long.count>short.count,"Information content did not exercise short/long states")
        try await check(name+" selected revision information",window:window,baseline:baseline)
        model.busy=true
        try await check(name+" generic owned activity",window:window,baseline:baseline)
        try require(model.feedbackMessages.contains(NSLocalizedString("Working…",comment:"")),"Busy feedback omitted its phase")
        model.busy=false
        let configLock=context.root.appendingPathComponent(".git/config.lock")
        try Data("held private config lock".utf8).write(to:configLock)
        defer{context.remove(configLock)}
        let patch=Gate<Data>();context.patch=patch
        model.readPatchPreview={_,_,token in try await patch.read(token)}
        model.setPatchPreview(true)
        try await wait("owned patch read and failed preference write",window:window) {patch.entered && model.patchPreviewLoading && !model.patchPreferenceSaving && model.patchPreferenceError != nil}
        try await check(name+" patch read/preference error",window:window,baseline:baseline)
        let heldSnapshot=try await showDetails(context,window:window)
        context.clipboard.clearContents();context.clipboard.setString("sentinel",forType:.string)
        try require(model.copyFeedbackDetails(heldSnapshot) && context.clipboard.string(forType:.string)==heldSnapshot.text,"Status copy lost full captured text")
        try require(patch.token?.isCancelled==false,"Passive status Copy cancelled actual patch read")
        try await closeDetails(model,window:window)
        let diagnostic="Actual patch reader refused\nraw diagnostic: 雪 e\u{301}\r\n"+String(repeating:"long line remains available ",count:40)
        patch.finish(.failure(Failure(text:diagnostic)))
        try await wait("actual patch diagnostic",window:window) {!model.patchPreviewLoading && model.patchPreviewError==diagnostic}
        try require(!model.copyFeedbackDetails(heldSnapshot),"Replaced feedback retained Copy authority")
        try await check(name+" long multiline patch error",window:window,baseline:baseline)
        let snapshot=try await showDetails(context,window:window)
        try require(snapshot.text.contains(diagnostic),"Full raw error disappeared from status details")
        context.clipboard.clearContents();context.clipboard.setString("unchanged",forType:.string)
        let sheet=NSWindow(contentRect:NSRect(x:-24000,y:-24000,width:240,height:100),styleMask:.titled,backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;context.windows.append(sheet)
        window.beginSheet(sheet){_ in}
        try await wait("private native sheet attached",window:window){window.attachedSheet===sheet}
        try require(!model.copyFeedbackDetails(snapshot) && !model.showFeedbackDetails(),"Sheet-owned Log retained status authority")
        try await wait("sheet dismissed status popover",window:window){model.feedbackDetails==nil}
        try await check(name+" native sheet ownership",window:window,baseline:baseline)
        window.endSheet(sheet,returnCode:.abort);sheet.close()
        try await wait("private native sheet detached",window:window){sheet.sheetParent==nil && window.attachedSheet==nil}
        try await wait("native feedback restored after sheet",window:window){(try? feedbackButton(window).isEnabled)==true}
        for flag in 0..<4 {
            switch flag {case 0:model.confirmingQuit=true;case 1:model.findBlocked=true;case 2:model.orderingBlocked=true;default:model.referencePickerBlocked=true}
            try require(!model.copyFeedbackDetails(snapshot) && !model.showFeedbackDetails(),"Blocked owner accepted passive status command")
            switch flag {case 0:model.confirmingQuit=false;case 1:model.findBlocked=false;case 2:model.orderingBlocked=false;default:model.referencePickerBlocked=false}
        }
        try require(context.clipboard.string(forType:.string)=="unchanged","Rejected status Copy changed private clipboard")
        try await closeDetails(model,window:window);context.remove(configLock)
        model.setPatchPreview(false)
        try await wait("patch viewer/write retired",window:window) {!model.patchPreviewLoading && !model.patchPreferenceSaving && context.owner?.patchPreviewWindow==nil}
        // Actual held Notes path. No editor window is needed to verify the
        // reading phase and its subsequent draft ownership transition.
        let note=Gate<(CommitNoteSnapshot,ProjectDialogSettings)>();context.note=note
        model.prepareNoteIdentity={_ in true};model.readNote={_,token in try await note.read(token)};model.onShowNote={_,_ in}
        model.editNotes()
        try await wait("owned note reader",window:window) {note.entered && model.loadingNote}
        try await check(name+" notes read",window:window,baseline:baseline)
        let noteSnapshot=try await showDetails(context,window:window)
        note.finish(.success((CommitNoteSnapshot(revision:context.head,notesRef:"refs/notes/commits",text:"",minimumLength:0),ProjectDialogSettings())))
        try await wait("note draft ownership",window:window) {!model.loadingNote && model.noteRequest != nil}
        try require(!model.copyFeedbackDetails(noteSnapshot),"Returned Notes child retained feedback action")
        model.cancelNote();try await closeDetails(model,window:window)
        // The real clipboard read is held inside the private Git wrapper. A
        // passive status copy must neither cancel it nor overwrite its result.
        context.remove(context.enteredShow);try Data().write(to:context.holdShow)
        model.copyDetails(includePaths:false)
        try await wait("owned clipboard Git read",window:window) {model.copyingDetails && FileManager.default.fileExists(atPath:context.enteredShow.path)}
        try await check(name+" history clipboard read",window:window,baseline:baseline)
        let clipboardSnapshot=try await showDetails(context,window:window)
        context.clipboard.clearContents();context.clipboard.setString("owned reader",forType:.string)
        try require(!model.copyFeedbackDetails(clipboardSnapshot) && context.clipboard.string(forType:.string)=="owned reader","Passive status Copy stole an in-flight history clipboard")
        context.remove(context.holdShow)
        try await wait("actual clipboard result",window:window) {!model.copyingDetails && context.clipboard.string(forType:.string)?.contains("Revision: "+context.head)==true}
        try require(!model.copyFeedbackDetails(clipboardSnapshot),"Old reader feedback overwrote completed clipboard")
        try await closeDetails(model,window:window)
        try await check(name+" finished readers",window:window,baseline:baseline)
    }
    static func verify(base:URL,git:URL)async throws {
        let context=Context(base:base,git:git)
        do {
            try await context.prepare()
            let owner=try unwrap(context.owner,"Missing owned Log controller"),window=try unwrap(owner.window,"Missing owned Log window"),model=owner.model
            try await informationLines(context)
            for (name,size) in [("minimum",NSSize(width:1040,height:650)),("large",NSSize(width:1440,height:940))] {
                window.setContentSize(size);window.contentView?.layoutSubtreeIfNeeded()
                try await wait("settled Log split at "+name,window:window) {(views(window.contentView).compactMap{$0 as? LogPaneLayoutBridge.Probe}.first?.split?.bounds.height ?? 0)>0}
                let baseline=try await settledGeometry(window)
                let usable=window.contentLayoutRect.insetBy(dx:-1,dy:-1)
                for (key,rect) in baseline {try require(usable.contains(rect),"\(name) clips \(key): bounds=\(rect), usable=\(usable)")}
                try require(abs(baseline["Log.Information"]!.height-30)<=0.5 && abs(baseline["Log.Feedback"]!.height-24)<=0.5 && abs(baseline["Log.Footer"]!.height-32)<=0.5,"Reserved native band heights differ")
                context.remove(context.enteredLog);try Data().write(to:context.holdLog)
                model.reload()
                try await wait("actual history stream held",window:window) {model.loadingHistory && FileManager.default.fileExists(atPath:context.enteredLog.path)}
                try await check(name+" initial/history read footer",window:window,baseline:baseline)
                context.remove(context.holdLog)
                try await wait("actual history complete",window:window) {!model.busy && !model.loadingHistory && model.entries.count==3 && model.pendingHistoryLoads==0 && LogWindowModel.activeActionReads==0}
                try await check(name+" completed history footer",window:window,baseline:baseline)
                try await phases(context,window:window,baseline:baseline,name:name)
            }
            let button=try feedbackButton(window)
            if model.feedbackMessages.isEmpty {model.busy=true}
            let snapshot=try await showDetails(context,window:window)
            owner.close()
            try require(model.isInvalidated && model.feedbackDetails==nil && !model.copyFeedbackDetails(snapshot),"Retired Log retained feedback state/actions")
            button.performClick(nil);try require(model.feedbackDetails==nil,"Retired native disclosure revived status")
            try await context.preserve();try await context.cleanup()
            print("PASS: actual one/two/overflow information component and Log fixed information/feedback/footer geometry at minimum/large sizes; actual history, patch/error/preferences, Notes and clipboard readers; full native help/AX and bounded details; captured private Copy and blocked/replaced/retired ownership")
        } catch {
            let failure=error
            do{try await context.cleanup()}catch{throw Failure(text:"\(failure); cleanup: \(error)")}
            throw failure
        }
    }
}
