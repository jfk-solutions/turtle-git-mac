import AppKit
import TurtleGitCore

struct MergeExternalReloadVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"External reload timeout at \(line): \(message)")
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ExternalReload."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        MergeComparisonOptions.exact.save(to:prefs);MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        prefs.set(false,forKey:"TurtleGitMerge.EnableEditorConfig")
        var comparisons:[FileComparisonWindowController]=[],conflicts:[TextConflictWindowController]=[]
        var held:FileComparisonWindowController?,release:CheckedContinuation<MergeExternalSourceProbe,Never>?
        func cleanup()async {
            release?.resume(returning:.init(observations:[:],changed:["base"]));release=nil
            held?.close();held=nil
            for owner in comparisons {owner.close()};for owner in conflicts {owner.close()}
            for _ in 0..<2500 {
                if MergeExternalReloadCoordinator.activeRequests==0 && FileListComparisonSession.activeOperations==0 && MergeRegexOperations.activeRequests==0 && comparisons.allSatisfy({$0.window?.isVisible != true && $0.window?.attachedSheet==nil}) && conflicts.allSatisfy({$0.window?.isVisible != true && $0.window?.attachedSheet==nil}) {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite)
        }
        do {
            let left=root.appendingPathComponent("left"),right=root.appendingPathComponent("right"),saved=root.appendingPathComponent("saved-pane")
            try Data("left accepted\n".utf8).write(to:left);try Data("right accepted\n".utf8).write(to:right)
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs,deferInitialLoad:true)
            comparisons.append(owner);owner.window!.alphaValue=0;owner.window!.appearance=NSAppearance(named:.darkAqua);owner.window!.orderFront(nil)
            let model=owner.model,detector=owner.externalReload!
            model.saveFolderAccess.requireScope=false
            detector.isActive={_ in true};detector.delayNanoseconds=10_000_000
            var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?,questions=0,savePrompts=0
            detector.presentQuestion={alert,parent,answer in
                question=alert;reply=answer;questions += 1
                alert.window.alphaValue=parent.alphaValue;parent.beginSheet(alert.window,completionHandler:nil)
            }
            model.presentProjectionQuestion={_,_,answer in savePrompts += 1;answer(.cancel)}
            model.useInternalMergeViewer();model.beginTransferredDocument()
            try await wait("initial comparison and baseline") {!model.busy && !model.filtering && model.document != nil && model.externalReloadReady}
            detector.activate();try await wait("initial observation") {!detector.hasPendingWork}
            try require(questions==0 && model.externalReloadSources.count==2,"Accepted initial bytes prompted or lost source URLs")
            // A format-only owned write can replace the inode without changing
            // any ASCII bytes; it still needs a fresh observer metadata receipt.
            let equalBytes=try Data(contentsOf:right)
            let equalIdentity=try FileManager.default.attributesOfItem(atPath:right.path)[.systemFileNumber] as? NSNumber
            let sameByteEncoding:ComparisonTextEncoding=model.encoding(base:false) == .windows1252 ? .utf8 : .windows1252
            model.changeEncoding(sameByteEncoding,base:false)
            try require(model.dirty && model.encoding(base:false)==sameByteEncoding,"Format-only same-byte comparison change was not accepted")
            var equalSaved:Bool?;model.saveAll{equalSaved=$0}
            try await wait("same-byte comparison save") {equalSaved != nil && model.externalReloadReady}
            try require(equalSaved==true && !model.dirty && (try Data(contentsOf:right))==equalBytes,"Same-byte comparison Save failed: \(model.error ?? "none")")
            let equalWrittenIdentity=try FileManager.default.attributesOfItem(atPath:right.path)[.systemFileNumber] as? NSNumber
            try require(equalWrittenIdentity != equalIdentity,"Same-byte comparison Save did not exercise an actual file replacement")
            detector.activate();try await wait("same-byte comparison baseline") {!detector.hasPendingWork}
            try require(questions==0,"Owned same-byte comparison Save was reported as an external edit")
            // Actual native controller activation is debounced and uses captured inputs.
            try Data("left outside\n".utf8).write(to:left)
            owner.windowDidBecomeKey(Notification(name:NSWindow.didBecomeKeyNotification,object:owner.window))
            owner.windowDidBecomeKey(Notification(name:NSWindow.didBecomeKeyNotification,object:owner.window))
            try await wait("owned warning") {question != nil && owner.window?.attachedSheet === question?.window}
            try require(questions==1 && detector.blocksCommands && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Warning lost debounce/Close/Quit ownership")
            let warningTitles=question!.buttons.map(\.title),warningKeys=question!.buttons.map(\.keyEquivalent)
            let warningAppearance=question!.window.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]),ownerAppearance=owner.window!.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua])
            try require(warningTitles==["Load changes","Ignore changes","Cancel"] && (warningKeys[0]=="\r" || question!.window.defaultButtonCell === question!.buttons[0].cell) && warningKeys[2]=="\u{1b}" && question!.window.alphaValue==0 && warningAppearance == .darkAqua,"Warning controls/default/appearance differ: titles=\(warningTitles), keys=\(String(reflecting:warningKeys)), loadIsDefault=\(question!.window.defaultButtonCell === question!.buttons[0].cell), alpha=\(question!.window.alphaValue), ownerAlpha=\(owner.window!.alphaValue), appearance=\(String(describing:warningAppearance)), ownerAppearance=\(String(describing:ownerAppearance)), explicitOwner=\(String(describing:owner.window!.appearance?.name)), sheetAttached=\(owner.window?.attachedSheet === question?.window)")
            reply?(.alertSecondButtonReturn);reply=nil;question=nil
            try await wait("Ignore actual detach") {!detector.hasPendingWork && owner.window?.attachedSheet==nil && model.dirty}
            try require(model.draftText(base:true)=="left accepted\n" && savePrompts==0,"Ignore replaced retained pane or requested Save")
            detector.activate();try await wait("acknowledged Ignore") {!detector.hasPendingWork};try require(questions==1,"Ignore repeatedly prompted unchanged metadata")
            try Data("right outside\n".utf8).write(to:right);detector.activate()
            try await wait("Cancel warning") {question != nil}
            reply?(.cancel);reply=nil;question=nil
            try await wait("Cancel actual detach") {!detector.hasPendingWork && owner.window?.attachedSheet==nil}
            try require(model.draftText(base:false)=="right accepted\n" && model.dirty,"Cancel did not preserve source view")
            detector.activate();try await wait("acknowledged Cancel") {!detector.hasPendingWork};try require(questions==2,"Cancel repeated same change")
            // Reload explicitly discards retained panes, without the manual Reload save chooser.
            try Data("right reloaded\n".utf8).write(to:right);detector.activate();try await wait("dirty Load warning") {question != nil}
            try require(question!.informativeText.contains("unsaved"),"Dirty warning omitted edit loss")
            reply?(.alertFirstButtonReturn);reply=nil;question=nil
            try await wait("dirty Load settled") {!model.busy && !model.filtering && !detector.hasPendingWork && owner.window?.attachedSheet==nil && model.draftText(base:false)=="right reloaded\n"}
            try require(!model.dirty && !model.canUndo && savePrompts==0,"External Load reused manual save prompt or retained undo/dirtiness")
            // Save As becomes the watched live input; our own save never prompts.
            model.chooseExportLocation={_,_,_ in saved};model.saveAs(base:false)
            try await wait("Save As rebound") {!model.busy && !model.filtering && model.savedPaneURL(base:false)==saved && !model.hasPendingEditorChoice}
            detector.activate();try await wait("self Save As baseline") {!detector.hasPendingWork};try require(questions==3,"Owned Save As warned as an external edit")
            try Data("changed copy\n".utf8).write(to:saved);detector.activate();try await wait("rebound target warning") {question != nil}
            try require(question!.informativeText.contains(saved.path) && !question!.informativeText.contains("unsaved"),"Save As did not update monitored path/clean warning")
            reply?(.alertFirstButtonReturn);reply=nil;question=nil
            try await wait("copy reload") {!model.busy && !model.filtering && !detector.hasPendingWork && model.draftText(base:false)=="changed copy\n"}
            model.updateDraft("owned save\n",base:false);model.recordTypingEdit(base:false);model.updateHistoryState()
            var savedReply:Bool?;model.saveAll{savedReply=$0}
            try await wait("owned save") {savedReply != nil && !model.busy && !model.filtering}
            try require(savedReply==true,"Owned save failed: \(model.error ?? "none")")
            detector.activate();try await wait("owned save observed") {!detector.hasPendingWork};try require(questions==4,"Owned Save prompted itself")
            // A held native answer cannot acknowledge metadata while Quit has
            // revoked readiness during actual sheet release. Reoffer afterward.
            try Data("outside during quit\n".utf8).write(to:saved);detector.activate()
            try await wait("held answer before Quit") {question != nil}
            let heldQuestions=questions
            model.confirmingQuit=true
            reply?(.alertSecondButtonReturn);reply=nil;question=nil
            try await wait("Quit-held answer detached") {!detector.hasPendingWork && owner.window?.attachedSheet==nil}
            try require(!model.dirty && model.draftText(base:false)=="owned save\n","Answer acknowledged/kept while deferred Quit revoked readiness")
            model.confirmingQuit=false;detector.activate()
            try await wait("unacknowledged change reoffered") {question != nil && questions==heldQuestions+1}
            reply?(.alertSecondButtonReturn);reply=nil;question=nil
            try await wait("reoffered Ignore detached") {!detector.hasPendingWork && owner.window?.attachedSheet==nil && model.dirty}
            owner.close();try await wait("comparison closed") {owner.window?.isVisible != true && !detector.hasPendingWork}
            // A source single-file view watches only Your, even though the
            // internal comparison document carries both logical pane records.
            let singleLeft=root.appendingPathComponent("single-left"),singleRight=root.appendingPathComponent("single-right")
            try Data("single base\n".utf8).write(to:singleLeft);try Data("single your\n".utf8).write(to:singleRight)
            let single=FileComparisonWindowController(comparison:try WorkingFileComparison(base:singleLeft,destination:singleRight),permissions:[],preferences:prefs,deferInitialLoad:true)
            comparisons.append(single);single.model.singleFileMode=true;single.window!.alphaValue=0;single.window!.orderFront(nil)
            let singleModel=single.model,singleWatch=single.externalReload!
            singleWatch.isActive={_ in true};singleWatch.delayNanoseconds=1
            var singleQuestion:NSAlert?,singleReply:((NSApplication.ModalResponse)->Void)?,singleQuestions=0
            singleWatch.presentQuestion={alert,parent,answer in singleQuestion=alert;singleReply=answer;singleQuestions += 1;alert.window.alphaValue=0;parent.beginSheet(alert.window,completionHandler:nil)}
            singleModel.useInternalMergeViewer();singleModel.beginTransferredDocument()
            try await wait("single-file loaded") {singleModel.externalReloadReady && !singleWatch.hasPendingWork}
            try require(singleModel.externalReloadSources.map(\.id)==["destination"],"Single-file observer included hidden Base")
            try Data("hidden base outside\n".utf8).write(to:singleLeft);singleWatch.activate()
            try await wait("single hidden Base observation") {!singleWatch.hasPendingWork}
            try require(singleQuestions==0 && !singleModel.dirty,"Single-file hidden Base change prompted or dirtied Your")
            try Data("single outside\n".utf8).write(to:singleRight);singleWatch.activate()
            try await wait("single Your warning") {singleQuestion != nil}
            singleReply?(.alertSecondButtonReturn);singleReply=nil;singleQuestion=nil
            try await wait("single Ignore detached") {!singleWatch.hasPendingWork && single.window?.attachedSheet==nil}
            try require(singleModel.dirty && singleModel.activeDirty && singleModel.unsavedFilesDescription==singleRight.path && singleModel.draftText(base:false)=="single your\n","Single Ignore failed to mark only retained Your dirty")
            single.close();try await wait("single closed") {single.window?.isVisible != true && !singleWatch.hasPendingWork}
            // Combined one-pane comparison watches both sources, but ignoring a
            // Base-only change must not dirty a hidden left-side editor.
            let combinedLeft=root.appendingPathComponent("combined-left"),combinedRight=root.appendingPathComponent("combined-right")
            try Data("combined base\n".utf8).write(to:combinedLeft);try Data("combined your\n".utf8).write(to:combinedRight)
            let combined=FileComparisonWindowController(comparison:try WorkingFileComparison(base:combinedLeft,destination:combinedRight),permissions:[],preferences:prefs,deferInitialLoad:true)
            comparisons.append(combined);combined.window!.alphaValue=0;combined.window!.orderFront(nil)
            let combinedModel=combined.model,combinedWatch=combined.externalReload!
            combinedWatch.isActive={_ in true};combinedWatch.delayNanoseconds=1
            var combinedQuestion:NSAlert?,combinedReply:((NSApplication.ModalResponse)->Void)?,combinedQuestions=0
            combinedWatch.presentQuestion={alert,parent,answer in combinedQuestion=alert;combinedReply=answer;combinedQuestions += 1;alert.window.alphaValue=0;parent.beginSheet(alert.window,completionHandler:nil)}
            combinedModel.useInternalMergeViewer();combinedModel.beginTransferredDocument()
            try await wait("combined input loaded") {combinedModel.externalReloadReady && !combinedWatch.hasPendingWork}
            combinedModel.switchPaneMode(true)
            try await wait("combined view accepted") {combinedModel.onePaneActive && combinedModel.externalReloadReady && !combinedWatch.hasPendingWork}
            try require(Set(combinedModel.externalReloadSources.map(\.id))==["base","destination"],"Combined comparison lost one live source")
            try Data("combined Base outside\n".utf8).write(to:combinedLeft);combinedWatch.activate()
            try await wait("combined Base warning") {combinedQuestion != nil}
            combinedReply?(.alertSecondButtonReturn);combinedReply=nil;combinedQuestion=nil
            try await wait("combined Ignore detached") {!combinedWatch.hasPendingWork && combined.window?.attachedSheet==nil}
            try require(!combinedModel.dirty && !combinedModel.activeDirty && combinedModel.draftText(base:true)=="combined base\n","Combined Base-only Ignore dirtied hidden Base/Your or replaced retained text")
            combinedWatch.activate();try await wait("combined acknowledged Base") {!combinedWatch.hasPendingWork}
            try require(combinedQuestions==1,"Combined ignored Base change repeated")
            combinedModel.switchPaneMode(false)
            try await wait("combined returned to split panes") {!combinedModel.onePaneActive && combinedModel.externalReloadReady}
            combinedModel.activatePane(base:true)
            try require(combinedModel.activeBase && !combinedModel.activeDirty && !combinedModel.dirty,"Revealed Base retained hidden forced dirtiness")
            combined.close();try await wait("combined closed") {combined.window?.isVisible != true && !combinedWatch.hasPendingWork}
            prefs.set(false,forKey:"TurtleGitMerge.OnePane")
            // With no explicit /merged target, Save overwrites original Mine.
            // Equal result bytes still replace the file and must refresh its
            // source observation, rather than preserving an obsolete inode.
            let equalBase=root.appendingPathComponent("equal-base"),equalMine=root.appendingPathComponent("equal-mine"),equalTheirs=root.appendingPathComponent("equal-theirs"),equalText=Data("equal original\n".utf8)
            for url in [equalBase,equalMine,equalTheirs] {try equalText.write(to:url)}
            let equalMerge=TextConflictWindowController(repository:GitRepository(root:root,executable:git),access:nil,path:"equal-mine",workingMerge:try WorkingTextMerge(base:equalBase,theirs:equalTheirs,mine:equalMine),preferences:prefs,deferInitialLoad:true)
            conflicts.append(equalMerge);equalMerge.window!.alphaValue=0;equalMerge.window!.orderFront(nil)
            let equalModel=equalMerge.model,equalWatch=equalMerge.externalReload!
            equalModel.saveFolderAccess.requireScope=false;equalWatch.isActive={_ in true};equalWatch.delayNanoseconds=1
            var equalQuestions=0
            equalWatch.presentQuestion={alert,parent,answer in equalQuestions += 1;alert.window.alphaValue=0;parent.beginSheet(alert.window,completionHandler:nil);answer(.cancel)}
            guard let equalInvocation=try MergeToolInvocation.parse(arguments:["--merge-tool","--base",equalBase.path,"--theirs",equalTheirs.path,"--mine",equalMine.path],currentDirectory:root.path) else {throw Failure(description:"Could not parse default-Mine Merge invocation")}
            try require(equalInvocation.merged==nil,"Default-Mine regression accidentally selected an explicit merged output")
            try equalModel.configureMergeTool(equalInvocation)
            equalModel.beginTransferredDocument()
            try await wait("default-Mine equal-byte loaded") {equalModel.externalReloadReady && !equalWatch.hasPendingWork}
            equalWatch.activate();try await wait("default-Mine initial observation") {!equalWatch.hasPendingWork}
            try require(equalModel.result==String(decoding:equalText,as:UTF8.self) && equalQuestions==0,"Default-Mine equal-byte source baseline invalid")
            let equalMineIdentity=try FileManager.default.attributesOfItem(atPath:equalMine.path)[.systemFileNumber] as? NSNumber
            var equalMergeSaved:Bool?;equalModel.save(markResolved:false){equalMergeSaved=$0}
            try await wait("default-Mine equal-byte saved") {equalMergeSaved != nil && equalModel.externalReloadReady}
            try require(equalMergeSaved==true && (try Data(contentsOf:equalMine))==equalText,"Default-Mine equal-byte Save failed: \(equalModel.error ?? "none")")
            let equalMineWrittenIdentity=try FileManager.default.attributesOfItem(atPath:equalMine.path)[.systemFileNumber] as? NSNumber
            try require(equalMineWrittenIdentity != equalMineIdentity,"Default-Mine equal-byte Save did not replace the actual file")
            equalWatch.activate();try await wait("default-Mine owned-write observation") {!equalWatch.hasPendingWork}
            try require(equalQuestions==0,"Owned default-Mine same-byte Save was reported as an external source edit")
            equalMerge.close();try await wait("default-Mine closed") {equalMerge.window?.isVisible != true && !equalWatch.hasPendingWork}
            // Three-file Base change keeps source metadata but does not dirty result.
            let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs"),output=root.appendingPathComponent("output")
            for (url,text) in [(base,"one\ntwo\nthree\n"),(mine,"ONE\ntwo\nthree\n"),(theirs,"one\ntwo\nTHREE\n"),(output,"ONE\ntwo\nTHREE\n")] {try Data(text.utf8).write(to:url)}
            let merge=TextConflictWindowController(repository:GitRepository(root:root,executable:git),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output),preferences:prefs)
            conflicts.append(merge);merge.window!.alphaValue=0;merge.window!.orderFront(nil)
            let three=merge.model,watch=merge.externalReload!
            watch.isActive={_ in true};watch.delayNanoseconds=10_000_000
            var threeQuestion:NSAlert?,threeReply:((NSApplication.ModalResponse)->Void)?,threeQuestions=0,manualReloads=0
            watch.presentQuestion={alert,parent,answer in threeQuestion=alert;threeReply=answer;threeQuestions += 1;alert.window.alphaValue=0;parent.beginSheet(alert.window,completionHandler:nil)}
            three.chooseReload={manualReloads += 1;return .cancel};three.load()
            try await wait("three-file loaded") {!three.busy && !three.preparing && three.externalReloadReady && three.externalReloadSources.count==3}
            watch.activate();try await wait("three initial baseline") {!watch.hasPendingWork}
            let result=three.result
            try require(result=="ONE\ntwo\nTHREE\n" && !three.dirty && !three.hasUnsavedEditorWork && three.keptExternalSources.isEmpty,"Three-file baseline must be clean before outside Base edit: result=\(String(reflecting:result)), dirty=\(three.dirty), unsaved=\(three.hasUnsavedEditorWork), kept=\(three.keptExternalSources), error=\(three.error ?? "none")")
            try Data("base outside\n".utf8).write(to:base);watch.activate();try await wait("Base warning") {threeQuestion != nil}
            threeReply?(.cancel);threeReply=nil;threeQuestion=nil
            try await wait("Base Cancel detach") {!watch.hasPendingWork && merge.window?.attachedSheet==nil}
            try require(three.result==result && !three.dirty && three.keptExternalSources.isEmpty && !three.hasUnsavedEditorWork,"Base-only change dirtied result/source panes: resultUnchanged=\(three.result==result), dirty=\(three.dirty), kept=\(three.keptExternalSources), unsaved=\(three.hasUnsavedEditorWork), error=\(three.error ?? "none")")
            try Data("output outside\n".utf8).write(to:output);watch.activate();try await wait("output-only observation") {!watch.hasPendingWork};try require(threeQuestions==1,"Separate output incorrectly triggered source warning")
            try Data("mine outside\n".utf8).write(to:mine);watch.activate();try await wait("Mine warning") {threeQuestion != nil}
            threeReply?(.alertSecondButtonReturn);threeReply=nil;threeQuestion=nil
            try await wait("Mine keep") {!watch.hasPendingWork && three.keptExternalSources==[true]}
            try require(three.result==result && !three.dirty && three.hasUnsavedEditorWork,"Kept Mine lost independent source preservation state")
            let keptMine=root.appendingPathComponent("kept-mine")
            var exportReply:((NSApplication.ModalResponse)->Void)?,exportPanel:NSSavePanel?,preserved:Bool?
            three.sourceExporter.saveFolderAccess.requireScope=false
            three.sourceExporter.selectedURL={_ in keptMine}
            three.sourceExporter.present={panel,parent,answer in exportPanel=panel;exportReply=answer;panel.alphaValue=0;parent.beginSheet(panel,completionHandler:nil)}
            three.saveEditorWork(includeResult:false){preserved=$0}
            try await wait("kept source actual Save As") {exportPanel != nil && merge.window?.attachedSheet === exportPanel}
            // The intercepted native panel still detaches through the production callback.
            merge.window!.endSheet(exportPanel!,returnCode:.OK);exportReply?(.OK);exportReply=nil;exportPanel=nil
            try await wait("kept source copied") {preserved != nil && !three.preservingSourceCopies && !three.exportingSource && merge.window?.attachedSheet==nil}
            try require(preserved==true && three.keptExternalSources.isEmpty && three.sourceTargetURL(mine:true)==keptMine,"Kept source did not become an independent saved pane: \(three.error ?? "none")")
            try require(try Data(contentsOf:keptMine)==Data("ONE\ntwo\nthree\n".utf8),"Saved kept pane used outside bytes")
            try require(try Data(contentsOf:mine)==Data("mine outside\n".utf8),"Source preservation overwrote external Mine")
            watch.activate();try await wait("source copy self-write baseline") {!watch.hasPendingWork};try require(threeQuestions==2,"Owned source copy warned itself")
            try await wait("three native result editor") {three.nativeEditorReady && three.replaceEntireResult != nil}
            three.replaceEntireResult?("unsaved result\n")
            try require(three.dirty && three.result=="unsaved result\n","Native result edit was not accepted before dirty external Load")
            try Data("theirs outside\n".utf8).write(to:theirs);watch.activate();try await wait("three dirty Load") {threeQuestion != nil}
            threeReply?(.alertFirstButtonReturn);threeReply=nil;threeQuestion=nil
            try await wait("three reload without second chooser") {!three.busy && !three.preparing && !watch.hasPendingWork && three.keptExternalSources.isEmpty && three.result != "unsaved result\n"}
            try require(manualReloads==0 && merge.window?.attachedSheet==nil && !three.canUndo,"Three-file Load requested manual Save or retained history")
            merge.close();try await wait("three closed") {merge.window?.isVisible != true && !watch.hasPendingWork}
            // Actual Open replacement transfers the window while the old probe drains.
            let replace=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs,deferInitialLoad:true)
            comparisons.append(replace);replace.window!.alphaValue=0;replace.window!.orderFront(nil)
            let oldDetector=replace.externalReload!,replacementOwner=MergeEditorReplacementOwner(onClosed:{})
            replace.sharedReplacementOwner=replacementOwner;oldDetector.isActive={_ in true};oldDetector.delayNanoseconds=1
            oldDetector.probe={_,_,_ in await withCheckedContinuation{release=$0}}
            replace.model.useInternalMergeViewer();replace.model.beginTransferredDocument()
            try await wait("replacement held probe") {release != nil}
            let transferred=replace.window!
            try replace.replaceEditor(.compare(base:left,mine:saved,single:false),permissions:[])
            guard let adopted=replacementOwner.current as? FileComparisonWindowController else{throw Failure(description:"Replacement owner missing")}
            comparisons.append(adopted)
            try require(adopted.window === transferred && replace.window==nil && oldDetector.hasPendingWork,"Open did not retain old detector while transferring actual window")
            release?.resume(returning:.init(observations:[:],changed:["base"]));release=nil
            try await wait("retired old replacement probe drained") {!oldDetector.hasPendingWork && !replacementOwner.hasPendingRetiredWork && adopted.model.externalReloadReady}
            let adoptedDetector=adopted.externalReload!;adoptedDetector.isActive={_ in true};adoptedDetector.delayNanoseconds=1
            var replacementQuestion:NSAlert?,replacementReply:((NSApplication.ModalResponse)->Void)?
            adoptedDetector.presentQuestion={alert,parent,answer in replacementQuestion=alert;replacementReply=answer;alert.window.alphaValue=0;parent.beginSheet(alert.window,completionHandler:nil)}
            adoptedDetector.activate();try await wait("adopted baseline") {!adoptedDetector.hasPendingWork}
            try Data("post adoption outside\n".utf8).write(to:saved);adoptedDetector.activate()
            try await wait("adopted detector watches actual host") {replacementQuestion != nil && transferred.attachedSheet === replacementQuestion?.window}
            replacementReply?(.alertSecondButtonReturn);replacementReply=nil;replacementQuestion=nil
            try await wait("adopted warning detached") {!adoptedDetector.hasPendingWork && transferred.attachedSheet==nil}
            adopted.close();try await wait("adopted closed") {transferred.isVisible==false}
            // Noncooperative worker retains its captured grant and Quit fence after forced close.
            var permission:RepositoryAccessLease?=RepositoryAccessLease(url:root)
            weak var weakPermission=permission
            held=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[permission!],preferences:prefs,deferInitialLoad:true)
            held!.window!.alphaValue=0;held!.window!.orderFront(nil)
            let pending=held!.externalReload!;pending.isActive={_ in true};pending.delayNanoseconds=1
            held!.model.useInternalMergeViewer();held!.model.beginTransferredDocument()
            try await wait("held owner initialload") {held?.model.externalReloadReady==true && !pending.hasPendingWork}
            pending.probe={_,_,_ in await withCheckedContinuation{release=$0}}
            pending.activate();try await wait("held probe accepted") {release != nil}
            held!.close();held=nil;permission=nil
            try require(weakPermission != nil && MergeExternalReloadCoordinator.activeRequests>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released grant/Quit while probe still live")
            release?.resume(returning:.init(observations:[:],changed:["base"]));release=nil
            try await wait("late probe actualdrain") {!pending.hasPendingWork && MergeExternalReloadCoordinator.activeRequests==0 && weakPermission==nil}
            try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path),"Standalone external reload created a repository")
            await cleanup()
            try require(MergeExternalReloadCoordinator.activeRequests==0 && comparisons.allSatisfy{$0.window?.isVisible != true} && conflicts.allSatisfy{$0.window?.isVisible != true},"Owned external-reload windows/requests survived cleanup")
            print("PASS: activation debounce; source Ignore/Cancel acknowledgment; actual owned warning controls and detachment; dirty Load without save recursion; Save As/self-save baselines; three-file Base/Mine/output isolation; forced-close grant/Quit drain")
        } catch {await cleanup();throw error}
    }
}
