import AppKit
import TurtleGitCore

@main struct P4MergeLayoutVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.P4Layout."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(true,forKey:"TurtleGit.Comparison.CurvedInterface")
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        DialogGeometry.install(preferences:prefs)
        let base=folder.appendingPathComponent("Base.swift"),theirs=folder.appendingPathComponent("Incoming.swift"),mine=folder.appendingPathComponent("Settings.swift"),output=folder.appendingPathComponent("Merged.swift")
        let a="struct Settings {\n    let title = \"Harbor\"\n    let refreshInterval = 30\n\n    func welcome() {\n        print(\"Welcome\")\n    }\n}\n"
        let b=a.replacingOccurrences(of:"refreshInterval = 30",with:"refreshInterval = 60\n    let retryCount = 3")
        let c=a.replacingOccurrences(of:"refreshInterval = 30",with:"refreshInterval = 15").replacingOccurrences(of:"print(\"Welcome\")",with:"print(\"Welcome back\")")
        for (url,text) in [(base,a),(theirs,b),(mine,c),(output,c)] {try text.write(to:url,atomically:true,encoding:.utf8)}
        let working=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output)
        let owner=TextConflictWindowController(repository:GitRepository(root:folder),access:nil,path:"Merged.swift",workingMerge:working,preferences:prefs,deferInitialLoad:true)
        let model=owner.model,window=owner.window!
        model.chooseStandaloneOutput={_,_ in output};model.saveFolderAccess.requireScope=false
        defer {DialogGeometry.install(preferences:.standard)}
        do {
            window.alphaValue=0;window.setFrameOrigin(NSPoint(x:-20000,y:-20000));window.orderFront(nil);model.beginTransferredDocument()
            try await MergeConflictInspectionVerification.wait {model.document != nil && !model.busy && model.nativeEditorReady && model.p4Scroll(.base) != nil}
            window.contentView?.layoutSubtreeIfNeeded()
            try await MergeConflictInspectionVerification.wait {window.toolbar?.isVisible != true}
            let sources:[P4MergePane:String]=[.base:a,.theirs:b,.mine:c]
            for (pane,value) in sources {
                let editor=model.p4Scroll(pane)?.documentView as? NSTextView
                try MergeConflictInspectionVerification.require(editor?.string == value,"P4 source \(pane) contains padding or another source")
            }
            let result=model.p4Scroll(.result)!.documentView as! NSTextView
            let bottom=result.convert(result.bounds,to:nil)
            for pane in [P4MergePane.theirs,.base,.mine] {
                let scroll=model.p4Scroll(pane)!,frame=scroll.convert(scroll.bounds,to:nil)
                try MergeConflictInspectionVerification.require(bottom.maxY<frame.minY,"Result is not below all three sources")
            }
            let connections=MergeConflictInspectionVerification.descendants(window.contentView,CurvedDiffConnectionView.self)
            try MergeConflictInspectionVerification.require(connections.count==2 && connections.allSatisfy{$0.leftRanges != nil && $0.rightRanges != nil},"Source connection character coordinates missing")
            try MergeConflictInspectionVerification.require(connections.contains{view in zip(view.leftRanges ?? [],view.rightRanges ?? []).contains{$0.length != $1.length}},"Unequal source block heights were flattened")
            guard let chunk=model.p4Chunks.first(where:{$0.conflict}) else {throw MergeConflictInspectionVerification.Failure(description:"Missing conflict fixture")}
            model.p4SelectedChunk = -1
            let conflictTarget=model.p4NavigationTarget(1,conflictsOnly:true)
            try MergeConflictInspectionVerification.require(conflictTarget != nil,"Unresolved conflict navigation unavailable")
            model.p4Navigate(1,conflictsOnly:true)
            try MergeConflictInspectionVerification.require(model.p4SelectedChunk==conflictTarget,"Conflict navigation did not select its target")
            try MergeConflictInspectionVerification.require(model.p4Scroll(.base)?.borderType == .noBorder && model.p4Scroll(.base)?.scrollerStyle == .overlay,"Source edges reserve a scrollbar or bezel gap: border=\(String(describing:model.p4Scroll(.base)?.borderType.rawValue)) style=\(String(describing:model.p4Scroll(.base)?.scrollerStyle.rawValue))")
            let initial=model.resultPresentation
            try MergeConflictInspectionVerification.require(model.hasUnresolvedConflicts && !result.string.contains("<<<<<<<") && result.string.contains("refreshInterval = 30") && result.string.contains("refreshInterval = 60") && result.string.contains("refreshInterval = 15"),"Unresolved candidates or retained conflict status missing")
            model.confirmUnresolvedSave={_ in false}
            var saveRejected=false
            model.save(markResolved:false,completion:{_ in saveRejected=true})
            try await MergeConflictInspectionVerification.wait {saveRejected && !model.busy}
            try MergeConflictInspectionVerification.require(model.hasUnresolvedConflicts && String(contentsOf:output,encoding:.utf8)==c,"Projected display bypassed unresolved save checks")
            if CommandLine.arguments.count>2 {try await MergeConflictInspectionVerification.capture(window,directory:URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("unresolved"))}
            let candidate=(result.string as NSString).range(of:"refreshInterval = 30")
            result.setSelectedRange(candidate);result.insertText("refreshInterval = 45",replacementRange:candidate)
            try await MergeConflictInspectionVerification.wait {model.result.contains("refreshInterval = 45") && !model.hasUnresolvedConflicts}
            try MergeConflictInspectionVerification.require(model.result.contains("refreshInterval = 60") && model.result.contains("refreshInterval = 15"),"Editing a displayed candidate lost alternatives")
            model.undo()
            try await MergeConflictInspectionVerification.wait {model.resultPresentation==initial && model.nativeEditorReady}
            let allButtons=MergeConflictInspectionVerification.descendants(window.contentView,NSButton.self)
            let button=allButtons.first{$0.accessibilityLabel()=="Theirs, chunk 1"}
            try MergeConflictInspectionVerification.require(button?.isEnabled==true,"Inline source toggle unavailable")
            button?.performClick(nil)
            try await MergeConflictInspectionVerification.wait {model.resultPresentation != initial}
            try MergeConflictInspectionVerification.require(model.result.contains("refreshInterval = 60") && !model.result.contains("<<<<<<<"),"Theirs chunk not applied")
            let selectedIndex=model.p4SelectedChunk
            model.p4SelectedChunk = -1
            try MergeConflictInspectionVerification.require(model.p4NavigationTarget(1,conflictsOnly:true) == nil,"Resolved conflict remains in conflict navigation")
            try MergeConflictInspectionVerification.require(model.p4NavigationTarget(1) != nil,"Resolved differences disappeared from change navigation")
            model.p4SelectedChunk=selectedIndex
            let chosen=model.resultPresentation
            button?.performClick(nil)
            try MergeConflictInspectionVerification.require(model.resultPresentation==chosen,"Stale source-button receipt mutated a newer result")
            model.p4Toggle(.mine,chunk:chunk,expected:model.resultPresentation)
            try await MergeConflictInspectionVerification.wait {model.result.contains("refreshInterval = 15")}
            try MergeConflictInspectionVerification.require(model.result.contains("refreshInterval = 60"),"Combining inputs discarded first source")
            model.undo()
            try await MergeConflictInspectionVerification.wait {model.resultPresentation==chosen}
            model.redo()
            try await MergeConflictInspectionVerification.wait {model.resultPresentation.selectedInputs(for:chunk)==[.theirs,.mine]}
            model.confirmingQuit=true
            let blocked=model.resultPresentation;model.p4Toggle(.base,chunk:chunk,expected:blocked)
            try MergeConflictInspectionVerification.require(model.resultPresentation==blocked,"Closing owner accepted chunk action")
            model.confirmingQuit=false
            model.p4UseFile(.base)
            try await MergeConflictInspectionVerification.wait {model.result==a}
            model.undo()
            try await MergeConflictInspectionVerification.wait {model.resultPresentation.selectedInputs(for:chunk)==[.theirs,.mine]}
            // Result editing remains the real undoable editor, including selections.
            result.setSelectedRange(NSRange(location:0,length:0));result.insertText("// reviewed\n",replacementRange:NSRange(location:0,length:0))
            try await MergeConflictInspectionVerification.wait {model.result.hasPrefix("// reviewed")}
            model.undo()
            try await MergeConflictInspectionVerification.wait {!model.result.hasPrefix("// reviewed")}
            let retained=model.result
            prefs.set(false,forKey:"TurtleGit.Comparison.CurvedInterface")
            try await MergeConflictInspectionVerification.wait {MergeConflictInspectionVerification.descendants(window.contentView,CurvedDiffConnectionView.self).isEmpty}
            try MergeConflictInspectionVerification.require(model.result==retained && window.attachedSheet==nil,"Classic switch reloaded or changed result")
            prefs.set(true,forKey:"TurtleGit.Comparison.CurvedInterface")
            try await MergeConflictInspectionVerification.wait {MergeConflictInspectionVerification.descendants(window.contentView,CurvedDiffConnectionView.self).count==2 && model.nativeEditorReady}
            if CommandLine.arguments.count>2 {
                try await MergeConflictInspectionVerification.capture(window,directory:URL(fileURLWithPath:CommandLine.arguments[2]))
            }
            model.p4UseFile(.theirs)
            try await MergeConflictInspectionVerification.wait {model.result==b}
            model.save(markResolved:false)
            MergeConflictInspectionVerification.diagnostics={"save busy=\(model.busy) dirty=\(model.dirty) error=\(model.error ?? "none") sheet=\(String(describing:window.attachedSheet))"}
            try await MergeConflictInspectionVerification.wait {!model.busy && !model.dirty}
            MergeConflictInspectionVerification.diagnostics={""}
            try MergeConflictInspectionVerification.require(try String(contentsOf:output,encoding:.utf8)==b,"Chosen result was not saved to output")
            try MergeConflictInspectionVerification.require(try String(contentsOf:base,encoding:.utf8)==a && String(contentsOf:theirs,encoding:.utf8)==b && String(contentsOf:mine,encoding:.utf8)==c,"Input file changed")
            owner.close()
            try await MergeConflictInspectionVerification.wait {!model.mergeToolHasPendingWork}
            try MergeConflictInspectionVerification.require(!window.isVisible && window.attachedSheet==nil,"Owned window survived close")
            print("PASS P4Merge layout: raw sources, bottom result, unequal curved bands, inline source toggles, combined order, undo/redo, stale/closing gates, manual edit, classic switch, save and cleanup")
        } catch {
            owner.close();NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.close()}
            try? await MergeConflictInspectionVerification.wait {!model.mergeToolHasPendingWork}
            throw error
        }
    }
}
