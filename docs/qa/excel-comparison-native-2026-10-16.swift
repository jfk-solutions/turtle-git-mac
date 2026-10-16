import AppKit
import TurtleGitCore
@main struct ExcelComparisonNativeVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    @MainActor static var owners:[NSWindowController]=[]
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line)async throws{for _ in 0..<1500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Excel native timeout at \(line)")}
    @MainActor static func main()async {
        NSApplication.shared.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_EXCEL_CAPTURE"] == nil ? .prohibited : .accessory)
        do{try await verify();owners.forEach{$0.close()};DiffToolApplication.discardAll()}catch{owners.forEach{$0.close()};DiffToolApplication.discardAll();fputs("Excel comparison failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),a=root.appendingPathComponent("old \" 雪.xlsx"),b=root.appendingPathComponent("new.xlsx")
        let old=try Data(contentsOf:a),new=try Data(contentsOf:b),suite="TurtleGit.ExcelNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let saved=DiffToolApplication.compareExcel,presenter=DiffToolApplication.presentExcelWarning
        defer{DiffToolApplication.compareExcel=saved;DiffToolApplication.presentExcelWarning=presenter}
        var copies:[URL]=[],calls=0,modes:[Bool]=[],warnings:[ExcelComparisonWarningController]=[]
        defer{for folder in copies{try? FileManager.default.removeItem(at:folder)}}
        DiffToolApplication.compareExcel={preview,_ in
            calls += 1;modes.append(preview.fast);copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==old && (try Data(contentsOf:preview.destination))==new,"Excel changed workbook bytes")
            let event=ExcelComparisonAutomation.event(preview),args=event.paramDescriptor(forKeyword:0x2d2d2d2d)
            try require(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="compareworkbooks" && args?.numberOfItems==3 && args?.atIndex(1)?.stringValue==preview.base.path && args?.atIndex(2)?.stringValue==preview.destination.path && args?.atIndex(3)?.booleanValue==preview.fast,"Excel descriptor paths/mode were interpolated or changed")
            return .init(warnings:["Unable to mark differences in Protected sheet; worksheet contents are protected.","Using fast comparison because the new workbook is protected. Keep both workbooks open."])
        }
        DiffToolApplication.presentExcelWarning={controller in warnings.append(controller);owners.append(controller);return true}
        func controller()throws->FileComparisonWindowController{let value=try FileComparisonWindowController(comparison:WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true);owners.append(value);return value}
        let full=try controller();full.model.beginTransferredDocument();try await wait{!full.model.busy && calls==1 && warnings.count==1}
        try require(full.model.error==nil && modes==[false] && warnings[0].outcome.warnings.count==2,"Full Excel route/warnings lost")
        try require(warnings[0].window!.contentView!.bounds.width>=520 && warnings[0].window!.contentView!.bounds.height>=260,"Excel warning window collapsed")
        if let capture=ProcessInfo.processInfo.environment["TURTLEGIT_EXCEL_CAPTURE"] {
            let folder=URL(fileURLWithPath:capture);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                let window=warnings[0].window!;window.appearance=NSAppearance(named:theme);window.contentView?.appearance=window.appearance;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:350_000_000)
                let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");child.arguments=["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent("excel-comparison-warning-"+name+".png").path];try child.run();child.waitUntilExit();try require(child.terminationStatus==0,"Owned Excel warning capture failed");window.orderOut(nil)
            }
        }
        var settings=DiffToolPreferences.load(from:prefs);let index=settings.associations.firstIndex{$0.pattern==".xlsx"}!;settings.associations[index].program.builtIn = .excelWorkbookFast;try settings.save(to:prefs)
        let fast=try controller();fast.model.beginTransferredDocument();try await wait{!fast.model.busy && calls==2};try require(modes==[false,true],"Fast Excel mode lost")
        let raw=try controller();raw.model.captureToolChoice(true);raw.model.beginTransferredDocument();try await wait{!raw.model.busy};try require(calls==2 && raw.model.document?.destination.bytes==new,"Excel Shift did not preserve raw bytes")
        DiffToolApplication.discardAll();try require(copies.allSatisfy{FileManager.default.fileExists(atPath:$0.path)},"Excel accepted workbook lifetime ended with native notices")
        var denied:URL?
        DiffToolApplication.compareExcel={preview,_ in denied=preview.directory;copies.append(preview.directory);throw ExcelComparisonFailure.automation(-1743,"denied",possiblyOpened:false)}
        let failure=try controller();failure.model.beginTransferredDocument();try await wait{!failure.model.busy};try require(failure.model.error?.contains("Automation")==true && denied != nil && !FileManager.default.fileExists(atPath:denied!.path),"Excel denied receipt lost recovery/cleanup")
        var answer:CheckedContinuation<ExcelComparisonOutcome,Error>?,late:URL?
        DiffToolApplication.compareExcel={preview,_ in late=preview.directory;copies.append(preview.directory);return try await withCheckedThrowingContinuation{answer=$0}}
        let closing=try controller();closing.model.beginTransferredDocument();try await wait{answer != nil};closing.close()
        try require(DiffToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired Excel worker released Quit early")
        let noticeCount=warnings.count;answer?.resume(returning:.init(warnings:["late warning"]));answer=nil;try await wait{DiffToolApplication.activeRequests==0}
        try require(late != nil && FileManager.default.fileExists(atPath:late!.path) && warnings.count==noticeCount && closing.model.error==nil,"Retired Excel result deleted accepted inputs or opened late warning/error")
        if ProcessInfo.processInfo.environment["TURTLEGIT_CHECK_EXCEL_TERMINOLOGY"]=="1"{_=try ExcelComparisonAutomation.compile();print("PASS: Excel handler compiled against installed terminology; no workbook operation executed")}
        try require((try Data(contentsOf:a))==old && (try Data(contentsOf:b))==new,"Excel route modified originals")
        print("PASS: shipping full/fast Excel dispatch and literal descriptors, warnings/light-dark notices, raw Shift, denied cleanup, accepted/retired input and Quit ownership; unchanged original workbooks")
    }
}
