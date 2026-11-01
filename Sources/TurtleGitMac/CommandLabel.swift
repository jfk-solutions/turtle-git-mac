import SwiftUI
import TurtleGitCore

/// History captions are presentation only. Insert repository values after
/// translating a checked template; never look up or reinterpret those values.
enum HistoryLabels {
    private static let tokenExpression = try! NSRegularExpression(pattern: "\\{([a-z_]+)\\}")
    /// Core keeps English summaries for non-UI callers. Native presentation
    /// formats semantic fields instead of translating a string containing Git data.
    static func information(_ value: HistoryInformation, bundle: Bundle = .main) -> String {
        var result = text("Showing {revisions} revision(s), from revision {oldest} to revision {newest} - {selected_revisions} revision(s) selected, {selected_files} file(s) selected", values: [
            "revisions": String(value.revisionCount), "oldest": value.oldest, "newest": value.newest,
            "selected_revisions": String(value.selectedRevisionCount), "selected_files": String(value.selectedFileCount)
        ], bundle: bundle)
        if value.selectedRevisionCount == 1 {
            result += text("; line: {added_lines}(+) {removed_lines}(-) files: Modified = {modified} Added = {added} Deleted = {deleted} Renamed = {renamed}", values: [
                "added_lines": String(value.addedLines), "removed_lines": String(value.removedLines),
                "modified": String(value.modified), "added": String(value.added), "deleted": String(value.deleted), "renamed": String(value.renamed)
            ], bundle: bundle)
        }
        return result
    }
    static func deletion(_ value: HistoryReferenceDeletion, bundle: Bundle = .main) -> String {
        switch value.kind {
        case .ordinary:
            return text("Do you really want to delete \"{reference}\"?", values: ["reference": value.name], bundle: bundle)
                + (value.unmerged ? "\n\n" + caption("This branch is not fully merged into HEAD.", bundle: bundle) : "")
        case .remote:
            return text("The branch \"{reference}\" is a remote-tracking branch which locally represents a remote branch.\n\nDo you really want to delete it?", values: ["reference": value.name], bundle: bundle)
        case .stash:
            return text("Do you really want to delete ALL {count} stash?", values: ["count": String(value.stashEntries.count)], bundle: bundle)
        }
    }
    static func deletion(_ value: ReferenceBrowserDeletionConfirmation, bundle: Bundle = .main) -> String {
        var result = value.references.count == 1
            ? text("Do you really want to delete \"{reference}\"?", values: ["reference": value.name], bundle: bundle)
            : text("Do you really want to permanently delete the {count} selected refs? It can NOT be recovered!", values: ["count": String(value.references.count)], bundle: bundle)
        if value.unmerged { result += "\n\n" + caption("This branch is not fully merged into HEAD.", bundle: bundle) }
        if value.uncheckedMerge { result += "\n\n" + caption("It has not been checked if these branches have been fully merged into HEAD.", bundle: bundle) }
        if value.kind == .remoteBranch { result += "\n\n" + caption("This action will remove the branches on the remote.", bundle: bundle) }
        return result
    }
    static func caption(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func text(_ key: String, values: [String: String], bundle: Bundle = .main) -> String {
        let expression = tokenExpression
        func fields(_ text: String) -> [String]? {
            let source = text as NSString
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            let remainder = expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: source.length), withTemplate: "")
            guard !remainder.contains("{"), !remainder.contains("}") else { return nil }
            return matches.map { source.substring(with: $0.range(at: 1)) }
        }
        guard let expected = fields(key), Set(expected) == Set(values.keys), Set(expected).count == expected.count else { return key }
        let translated = caption(key, bundle: bundle)
        let template = fields(translated).map { $0.sorted() == expected.sorted() } == true ? translated : key
        let source = template as NSString
        var result = "", end = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: end, length: match.range.location - end))
            result += values[source.substring(with: match.range(at: 1))]!
            end = NSMaxRange(match.range)
        }
        return result + source.substring(from: end)
    }
}

struct CommandLabel: View {
    let title: String
    let icon: MenuIcon
    var localized = true
    @Environment(\.turtleGitContextMenu) private var contextMenu
    @AppStorage("ShowAppContextMenuIcons") private var showContextIcons = true
    @ViewBuilder private var caption: some View {
        if localized { Text(LocalizedStringKey(title)) } else { Text(verbatim: title) }
    }
    var body: some View {
        if contextMenu && !showContextIcons {
            caption
        } else {
            Label {
                caption
            } icon: {
                if let image = icon.image() {
                    Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).resizable().scaledToFit().frame(width: 16, height: 16)
                }
            }
        }
    }
}

private struct TurtleGitContextMenuKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var turtleGitContextMenu: Bool {
        get { self[TurtleGitContextMenuKey.self] }
        set { self[TurtleGitContextMenuKey.self] = newValue }
    }
}
struct TurtleGitContextMenu<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.environment(\.turtleGitContextMenu, true) }
}

/// Reflow source command bands without constructing alternate copies of fields.
/// Flexible controls retain their ideal width and share unused room in their row.
struct DialogCommandRows: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6
    struct Flexible: LayoutValueKey { static let defaultValue = false }
    private struct Row { var indices: [Int] = []; var widths: [CGFloat] = []; var height: CGFloat = 0 }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var result: [Row] = [], row = Row(), used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposed = min(width, max(0, size.width.isFinite ? size.width : 0))
            if !row.indices.isEmpty && used + spacing + proposed > width {
                result.append(row); row = Row(); used = 0
            }
            if !row.indices.isEmpty { used += spacing }
            row.indices.append(index); row.widths.append(proposed); used += proposed
            row.height = max(row.height, subviews[index].sizeThatFits(.init(width: proposed, height: nil)).height)
        }
        if !row.indices.isEmpty { result.append(row) }
        for index in result.indices {
            let flexible = result[index].indices.indices.filter { subviews[result[index].indices[$0]][Flexible.self] }
            let occupied = result[index].widths.reduce(0,+) + spacing * CGFloat(max(0,result[index].indices.count-1))
            let extra = max(0,width-occupied) / CGFloat(max(1,flexible.count))
            for item in flexible { result[index].widths[item] += extra }
            result[index].height = zip(result[index].indices,result[index].widths).map {
                subviews[$0.0].sizeThatFits(.init(width:$0.1,height:nil)).height
            }.max() ?? 0
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Minimum width and minimum height are independent probes, like wrapped
        // text. A zero-width probe must not claim every possible wrapped row as
        // the window's minimum height even when its real width is much larger.
        if proposal.width == 0 {
            return CGSize(width:subviews.map{$0.sizeThatFits(.zero).width}.max() ?? 0,
                          height:subviews.map{$0.sizeThatFits(.unspecified).height}.max() ?? 0)
        }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0,+) + spacing * CGFloat(max(0,subviews.count-1))
        let offered = proposal.width ?? ideal
        let width = max(0,offered.isFinite ? offered : ideal)
        let bands = rows(subviews,width:width)
        return CGSize(width:width,height:bands.map(\.height).reduce(0,+) + rowSpacing * CGFloat(max(0,bands.count-1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews,width:bounds.width) {
            var x = bounds.minX
            for (index,width) in zip(row.indices,row.widths) {
                let height = subviews[index].sizeThatFits(.init(width:width,height:nil)).height
                subviews[index].place(at:.init(x:x,y:y+(row.height-height)/2),anchor:.topLeading,proposal:.init(width:width,height:height))
                x += width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}


/// Only semantic file-list captions enter the catalog. Repository text and Git
/// codes never pass through localization, even when a path is named "Modified".
/// English model values remain stable for sorting, persistence and Git actions.
enum FileListLabels {
    private static let statuses:Set<String> = ["Normal","Modified","Added","Deleted","Renamed","Copied","Type changed","Untracked","Unversioned","Ignored","Conflicted","Missing","Assume unchanged","Skip-worktree"]
    static func caption(_ raw:String)->String {caption(raw,bundle:.main)}
    static func caption(_ raw:String,bundle:Bundle)->String {
        let suffix=" (staged)"
        if raw.hasSuffix(suffix) {
            let status=String(raw.dropLast(suffix.count))
            guard statuses.contains(status) else {return raw}
            return caption(status,bundle:bundle)+" ("+bundle.localizedString(forKey:"staged",value:"staged",table:nil)+")"
        }
        guard statuses.contains(raw) || StatusListColumn.allCases.contains(where:{$0.rawValue==raw}) else {return raw}
        return bundle.localizedString(forKey:raw,value:raw,table:nil)
    }
    static func groupTitle(_ group:StatusListGroup)->String {
        if case .changelist(let name)=group {return name}
        return NSLocalizedString(group.title,comment:"")
    }
    static func counts(_ english:String,values:[String:Int])->String {
        LocalizedCountTemplate.render(english,translation:NSLocalizedString(english,comment:""),values:values)
    }
    static func selectionSummary(checked:Int,shown:Int)->String {
        let template:String
        switch (checked==1,shown==1) {
        case (true,true):template="{checked} file checked, {shown} file shown"
        case (true,false):template="{checked} file checked, {shown} files shown"
        case (false,true):template="{checked} files checked, {shown} file shown"
        case (false,false):template="{checked} files checked, {shown} files shown"
        }
        return counts(template,values:["checked":checked,"shown":shown])
    }
    static func stagingSummary(staged:Int,unstaged:Int)->String {
        counts(unstaged==1 ? "{staged} staged, {unstaged} unstaged file shown":"{staged} staged, {unstaged} unstaged files shown",values:["staged":staged,"unstaged":unstaged])
    }
    /// A localized header is presentation, never a persisted column identifier.
    /// Resolve only an unambiguous current-locale caption; callers retain their
    /// declared-order fallback when multiple headers translate to the same text.
    static func column(named title:String)->StatusListColumn? {
        if let exact=StatusListColumn(rawValue:title) {return exact}
        let matches=StatusListColumn.allCases.filter {caption($0.rawValue)==title}
        return matches.count==1 ? matches[0]:nil
    }
}
