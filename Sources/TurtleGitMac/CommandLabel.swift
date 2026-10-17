import SwiftUI
import TurtleGitCore

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
                    Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).resizable().frame(width: 16, height: 16)
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
    /// A localized header is presentation, never a persisted column identifier.
    /// Resolve only an unambiguous current-locale caption; callers retain their
    /// declared-order fallback when multiple headers translate to the same text.
    static func column(named title:String)->StatusListColumn? {
        if let exact=StatusListColumn(rawValue:title) {return exact}
        let matches=StatusListColumn.allCases.filter {caption($0.rawValue)==title}
        return matches.count==1 ? matches[0]:nil
    }
}
