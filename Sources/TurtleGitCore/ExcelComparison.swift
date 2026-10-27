// SPDX-License-Identifier: GPL-2.0-or-later
// Native preparation for contrib/diff-scripts/diff-xls.js.
import Foundation
public enum ExcelComparisonFailure:LocalizedError,Sendable {
    case application,absent
    case automation(Int,String,possiblyOpened:Bool)
    public var possiblyOpened:Bool { if case .automation(_,_,let value)=self { return value };return false }
    public var errorDescription:String? {
        switch self {
        case .application:return "Microsoft Excel is required for workbook comparison. Install Excel or choose another diff tool in Settings."
        case .absent:return "Excel comparison requires two existing workbook files."
        case .automation(let code,let message,_):
            if code == -1743 { return "Allow TurtleGit to control Microsoft Excel in macOS System Settings → Privacy & Security → Automation, then retry the comparison." }
            return "Excel could not prepare the comparison (\(code)): "+message
        }
    }
}
public struct ExcelComparisonOutcome:Sendable {
    public let warnings:[String]
    public init(warnings:[String]=[]) { self.warnings=warnings }
    public var warningText:String {
        guard !warnings.isEmpty else { return "" }
        var lines=["The following warnings occurred while processing."]
        for (index,message) in warnings.prefix(10).enumerated() { lines.append("[\(index+1)] "+message) }
        if warnings.count>10 { lines.append("... And more \(warnings.count-10) messages") }
        return lines.joined(separator:"\n")
    }
}
public struct ExcelComparisonPreview:Sendable {
    public let directory:URL
    public let base:URL
    public let destination:URL
    public let fast:Bool
    public static func prepare(_ document:FileComparisonDocument,in root:URL,fast:Bool,cancellation:OperationCancellation) throws -> Self {
        try cancellation.check();guard !document.base.isDeleted,!document.destination.isDeleted else { throw ExcelComparisonFailure.absent }
        let manager=FileManager.default,directory=root.appendingPathComponent("TurtleGitExcelDiff-"+UUID().uuidString,isDirectory:true)
        try manager.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            func copy(_ content:ComparisonFileContent,side:String) throws -> URL {
                try cancellation.check()
                let original=HistoricalGitPath.filename(content.path) ?? ""
                let name:String
                if !content.path.utf8.contains(0),["",".",".."].contains(original) {name="workbook.xlsx"}
                else {name=try ComparisonPreviewInputName.leaf(for:content,other:side=="base" ? document.destination:document.base,side:side,fallbackExtension:"xlsx")}
                let target=directory.appendingPathComponent(side+"-"+name)
                try content.bytes.write(to:target,options:.withoutOverwriting);try manager.setAttributes([.posixPermissions:0o444],ofItemAtPath:target.path);try cancellation.check();return target
            }
            let base=try copy(document.base,side:"base"),destination=try copy(document.destination,side:"new")
            return Self(directory:directory,base:base,destination:destination,fast:fast)
        } catch { try? manager.removeItem(at:directory);throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at:directory) }
}
