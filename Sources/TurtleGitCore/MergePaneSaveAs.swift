import Foundation

/// Ports CBaseView::SaveFile's view-row selection. Display gaps are not file
/// content; removed rows are retained only for the left pane's Save As command.
public enum MergePaneSaveAs {
    public static func sourceText(rows: [MergeSourceRow], mine: Bool, keepRemoved: Bool) -> String {
        func chosen(_ index: Int) -> MergeSourceCell { mine ? rows[index].mine : rows[index].theirs }
        func realConflict(_ cell: MergeSourceCell) -> Bool { cell.state == .conflicted && cell.lineNumber != nil }
        var output = "", index = 0
        while index < rows.count {
            let cell = chosen(index)
            if realConflict(cell) {
                var end = index + 1
                while end < rows.count && realConflict(chosen(end)) { end += 1 }
                // The pinned source adds these marker lines with NoEnding.
                // Keep their literal serialization rather than inserting an
                // unrequested Base section or normalizing source line endings.
                output += "<<<<<<< .mine"
                for row in rows[index..<end] { output += row.mine.text }
                output += "======="
                for row in rows[index..<end] { output += row.theirs.text }
                output += ">>>>>>> .theirs"
                index = end; continue
            }
            if cell.state != .empty && (keepRemoved || !cell.state.isExcludedFromResult) { output += cell.text }
            index += 1
        }
        return output
    }
    public static func sourceBytes(rows: [MergeSourceRow], mine: Bool, encoding: ComparisonTextEncoding) throws -> Data {
        try encoding.encode(sourceText(rows: rows, mine: mine, keepRemoved: !mine))
    }
}

extension MergePaneSaveAs {
    /// FileSave redirects read-only destinations to Save As instead of changing
    /// their permissions. The captured mode also matters when running as root.
    public static func requiresSaveAs(at url:URL, permissions:Int?, absent:Bool = false) -> Bool {
        guard !absent else {return false}
        if let permissions,permissions & 0o222 == 0 {return true}
        guard (try? FileManager.default.attributesOfItem(atPath:url.path)) != nil else {return false}
        return !FileManager.default.isWritableFile(atPath:url.path)
    }
    /// An explicit Save As establishes a new normal-save target. Preserve the
    /// selected existing regular file's mode and refuse links/read-only targets.
    public static func write(_ bytes:Data,to url:URL) throws {
        let manager=FileManager.default,location=url.standardizedFileURL
        guard location.isFileURL else {throw FileComparisonEditFailure.unsupported}
        let original:ComparisonFileContent?
        do {original=try WorkingFileComparison.workingContent(at:location)}
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {original=nil}
        if let original {
            guard ["100644","100755"].contains(original.mode ?? "") else {throw FileComparisonEditFailure.unsupported}
            guard !requiresSaveAs(at:location,permissions:original.permissions) else {throw FileComparisonEditFailure.readOnly}
        }
        try MergeWorkingFileSave.write(at:location,original:original?.bytes,permissions:original?.permissions ?? 0o644,bytes:bytes,delete:false,backup:false) {
            let current:ComparisonFileContent?
            do {current=try WorkingFileComparison.workingContent(at:location)}
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {current=nil}
            guard current?.bytes==original?.bytes,current?.mode==original?.mode,current?.permissions==original?.permissions else {throw FileComparisonEditFailure.changed}
        }
    }
}
