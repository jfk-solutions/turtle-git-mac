// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum ExcelComparisonAutomation {
    private static let queue=DispatchQueue(label:"org.turtlegit.excel-comparison")
    static let source="""
    on replaceText(oldText, newText, inputText)
        set previousDelimiters to AppleScript's text item delimiters
        try
            set AppleScript's text item delimiters to oldText
            set pieces to text items of inputText
            set AppleScript's text item delimiters to newText
            set outputText to pieces as text
            set AppleScript's text item delimiters to previousDelimiters
            return outputText
        on error messageText number errorCode
            set AppleScript's text item delimiters to previousDelimiters
            error messageText number errorCode
        end try
    end replaceText
    on unhideSheet(theSheet, theBook)
        tell application id "com.microsoft.Excel"
            set sheetLabel to "[" & (name of theBook) & "]" & (name of theSheet)
            if visible of theSheet is sheet visible then
                if color index of sheet tab of theSheet is not color index none then
                    if protect structure of theBook then
                        return {"Unable to reset tab color of " & sheetLabel & "; workbook structure is protected."}
                    else
                        set color index of sheet tab of theSheet to color index none
                    end if
                end if
            else if protect structure of theBook then
                return {"Unable to unhide " & sheetLabel & "; workbook structure is protected."}
            else
                set visible of theSheet to sheet visible
                set color index of sheet tab of theSheet to 10
            end if
        end tell
        return {}
    end unhideSheet
    on compareWorkbooks(basePath, newPath, requestedFast)
        set previousSecurity to missing value
        set baseBook to missing value
        set newBook to missing value
        set helperBook to missing value
        set warningMessages to {}
        try
            tell application id "com.microsoft.Excel"
                activate
                set previousSecurity to automation security
                set automation security to msoAutomationSecurityForceDisable
                set baseBook to open workbook workbook file name ((POSIX file basePath) as text) read only true update links do not update links add to mru false
                set newBook to open workbook workbook file name ((POSIX file newPath) as text) read only true update links do not update links add to mru false
                set useFast to requestedFast
                if protect windows of baseBook or protect windows of newBook then
                    set end of warningMessages to "Unable to arrange windows because one or both workbooks are protected."
                else
                    try
                        set area to bounds of window 1 of baseBook
                        set midpoint to ((item 2 of area) + (item 4 of area)) div 2
                        set bounds of window 1 of baseBook to {item 1 of area, item 2 of area, item 3 of area, midpoint}
                        set bounds of window 1 of newBook to {item 1 of area, midpoint, item 3 of area, item 4 of area}
                    on error
                        set end of warningMessages to "Unable to arrange the two comparison windows."
                    end try
                end if
                if not useFast and (protect windows of newBook or protect structure of newBook) then
                    set useFast to true
                    set end of warningMessages to "Using fast comparison because the new workbook is protected. Keep both workbooks open."
                end if
                set helperBook to make new workbook
                set originalCount to count of worksheets of newBook
                repeat with sheetIndex from 1 to originalCount
                    set newSheet to worksheet sheetIndex of newBook
                    set baseSheet to missing value
                    if sheetIndex is less than or equal to (count of worksheets of baseBook) then set baseSheet to worksheet sheetIndex of baseBook
                    if baseSheet is not missing value then set warningMessages to warningMessages & my unhideSheet(baseSheet, baseBook)
                    set warningMessages to warningMessages & my unhideSheet(newSheet, newBook)
                    set sheetFast to useFast
                        set comparisonName to ""
                        if baseSheet is not missing value and not sheetFast then
                            try
                                copy worksheet baseSheet after last sheet of newBook
                                set dummySheet to last worksheet of newBook
                                set comparisonName to "Dummy_for_Comparison" & sheetIndex
                                set suffixNumber to 0
                                repeat while exists worksheet comparisonName of newBook
                                    set suffixNumber to suffixNumber + 1
                                    set comparisonName to "TG_Base_" & sheetIndex & "_" & suffixNumber
                                end repeat
                                set name of dummySheet to comparisonName
                                set visible of dummySheet to sheet visible
                                set color index of sheet tab of dummySheet to 16
                            on error
                                set sheetFast to true
                                set end of warningMessages to "Unable to copy base worksheet " & sheetIndex & "; using fast comparison for this sheet."
                            end try
                        end if
                    if protect contents of newSheet then
                        set end of warningMessages to "Unable to mark differences in " & (name of newSheet) & "; worksheet contents are protected."
                    else
                        if baseSheet is missing value then
                            set formulaText to "=TRUE"
                            set targetCells to used range of newSheet
                            set conditionKind to expression
                        else
                            if sheetFast then
                                set comparisonName to "[" & (name of baseBook) & "]" & (name of baseSheet)
                            end if
                            set comparisonName to my replaceText("'", "''", comparisonName)
                            set referenceText to "'" & comparisonName & "'!"
                            set referenceText to my replaceText(quote, quote & quote, referenceText)
                            set formulaText to "=INDIRECT(" & quote & referenceText & quote & "&ADDRESS(ROW(),COLUMN()))"
                            set targetCells to cells of newSheet
                            set conditionKind to cell value
                        end if
                        set formula of range "A1" of worksheet 1 of helperBook to formulaText
                        set localFormula to formula local of range "A1" of worksheet 1 of helperBook
                        delete every format condition of targetCells
                        set differenceRule to make new format condition at end of format conditions of targetCells with properties {format condition type:conditionKind, condition operator:operator not equal, formula 1:localFormula}
                        set color index of interior object of differenceRule to 3
                    end if
                end repeat
                set saved of helperBook to true
                close helperBook saving no
                set helperBook to missing value
                if (count of worksheets of baseBook)>0 then activate object worksheet 1 of baseBook
                if (count of worksheets of newBook)>0 then activate object worksheet 1 of newBook
                set saved of baseBook to true
                set saved of newBook to true
                set automation security to previousSecurity
                activate
            end tell
            return {0, "", true, warningMessages}
        on error messageText number errorCode
            if helperBook is not missing value then
                try
                    tell application id "com.microsoft.Excel" to close helperBook saving no
                end try
            end if
            if previousSecurity is not missing value then
                try
                    tell application id "com.microsoft.Excel" to set automation security to previousSecurity
                end try
            end if
            return {errorCode, messageText, baseBook is not missing value or newBook is not missing value, warningMessages}
        end try
    end compareWorkbooks
    """
    static func compile() throws -> NSAppleScript {
        guard let script=NSAppleScript(source:source) else { throw ExcelComparisonFailure.automation(-1,"AppleScript is unavailable.",possiblyOpened:false) }
        var details:NSDictionary?
        guard script.compileAndReturnError(&details) else { throw ExcelComparisonFailure.automation((details?[NSAppleScript.errorNumber] as? Int) ?? -1,(details?[NSAppleScript.errorMessage] as? String) ?? "Could not compile the Excel comparison handler.",possiblyOpened:false) }
        return script
    }
    static func event(_ preview:ExcelComparisonPreview) -> NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list();arguments.insert(NSAppleEventDescriptor(string:preview.base.path),at:1);arguments.insert(NSAppleEventDescriptor(string:preview.destination.path),at:2);arguments.insert(NSAppleEventDescriptor(boolean:preview.fast),at:3)
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"compareworkbooks"),forKeyword:0x736e616d);event.setParam(arguments,forKeyword:0x2d2d2d2d);return event
    }
    @MainActor static func compare(_ preview:ExcelComparisonPreview,cancellation:OperationCancellation) async throws -> ExcelComparisonOutcome {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.Excel") != nil else { throw ExcelComparisonFailure.application }
        return try await withCheckedThrowingContinuation { reply in
            queue.async {
                do {
                    if cancellation.isCancelled { throw ExcelComparisonFailure.automation(-128,"Operation cancelled.",possiblyOpened:false) }
                    let script=try compile()
                    if cancellation.isCancelled { throw ExcelComparisonFailure.automation(-128,"Operation cancelled.",possiblyOpened:false) }
                    var details:NSDictionary?
                    let result=script.executeAppleEvent(event(preview),error:&details) as NSAppleEventDescriptor?
                    if let details { let code=(details[NSAppleScript.errorNumber] as? Int) ?? -1;throw ExcelComparisonFailure.automation(code,(details[NSAppleScript.errorMessage] as? String) ?? "Excel did not confirm the operation.",possiblyOpened:code != -1743) }
                    guard let result,result.numberOfItems==4 else { throw ExcelComparisonFailure.automation(-1,"Excel returned an incomplete result.",possiblyOpened:true) }
                    let code=Int(result.atIndex(1)?.int32Value ?? -1)
                    guard code==0 else { throw ExcelComparisonFailure.automation(code,result.atIndex(2)?.stringValue ?? "Comparison failed.",possiblyOpened:result.atIndex(3)?.booleanValue ?? true) }
                    let messages=result.atIndex(4);var warnings:[String]=[]
                    for index in 0..<(messages?.numberOfItems ?? 0) { warnings.append(messages?.atIndex(index+1)?.stringValue ?? "Workbook comparison warning.") }
                    reply.resume(returning:.init(warnings:warnings))
                } catch { reply.resume(throwing:error) }
            }
        }
    }
}

@MainActor final class ExcelComparisonWarningController:NSWindowController,NSWindowDelegate {
    let outcome:ExcelComparisonOutcome
    var onClosed:()->Void = {}
    private var closed=false
    init(outcome:ExcelComparisonOutcome) {
        self.outcome=outcome
        let window=NSWindow(contentRect:.init(x:0,y:0,width:640,height:360),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Excel comparison warnings – TurtleGit";window.isReleasedWhenClosed=false;window.contentMinSize = .init(width:520,height:260)
        super.init(window:window);window.delegate=self
        window.contentViewController=NSHostingController(rootView:ExcelComparisonWarningView(text:outcome.warningText,close:{[weak self] in self?.close()}));window.setContentSize(.init(width:640,height:360));window.center()
    }
    func windowWillClose(_ notification:Notification) { guard !closed else {return};closed=true;onClosed() }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
private struct ExcelComparisonWarningView:View {
    let text:String
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top,spacing:16) { Image(systemName:"exclamationmark.triangle.fill").font(.system(size:32)).foregroundStyle(.yellow);ScrollView{Text(text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)} }
            HStack{Spacer();Button("OK",action:close).keyboardShortcut(.defaultAction)}
        }.padding(20).onExitCommand(perform:close)
    }
}
