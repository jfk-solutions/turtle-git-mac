// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// One drawing scene backs the native chart, PDF, raster and enhanced metafiles.
struct StatisticsChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let graph:LogStatisticsGraph
    let style:LogStatisticsStyle
    let byAuthor:Bool
    var exporting=false
    // Position is the identity, even when names are canonically equivalent or a
    // real author is named like the synthetic Others aggregate.
    func groupKey(for point:LogStatisticsGraph.Point)->String {"group-\(byAuthor ? point.category:point.series)"}
    var groupKeys:[String] {(byAuthor ? graph.categoryLabels.indices:graph.seriesLabels.indices).map{"group-\($0)"}}
    static func backgroundColor(dark:Bool)->Color {dark ? Color(.sRGB,red:32.0/255,green:32.0/255,blue:32.0/255,opacity:1):.white}
    var body:some View {
        GeometryReader {geometry in
            StatisticsVectorView(graph:graph,style:style,size:geometry.size,dark:colorScheme == .dark,interactive:!exporting)
        }
    }
}

@MainActor private struct StatisticsVectorView:NSViewRepresentable {
    let graph:LogStatisticsGraph
    let style:LogStatisticsStyle
    let size:CGSize
    let dark:Bool
    let interactive:Bool
    func makeNSView(context:Context)->StatisticsVectorNativeView {StatisticsVectorNativeView()}
    func updateNSView(_ view:StatisticsVectorNativeView,context:Context) {
        view.update(graph:graph,style:style,size:size,dark:dark,interactive:interactive)
    }
    static func dismantleNSView(_ view:StatisticsVectorNativeView,coordinator:()) {view.retire()}
}

@MainActor final class StatisticsVectorNativeView:NSView,NSViewToolTipOwner {
    private(set) var drawing:StatisticsVectorScene?
    private var elements:[NSAccessibilityElement]=[]
    private var interactive=false
    override var isFlipped:Bool {true}
    override init(frame:NSRect) {super.init(frame:frame);identifier=NSUserInterfaceItemIdentifier("Statistics vector chart");setAccessibilityElement(true);setAccessibilityRole(.group)}
    convenience init(){self.init(frame:.zero)}
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func update(graph:LogStatisticsGraph,style:LogStatisticsStyle,size:CGSize,dark:Bool,interactive:Bool) {
        self.interactive=interactive
        let value=StatisticsVectorScene.make(graph:graph,style:style,size:size,dark:dark)
        drawing=value;removeAllToolTips()
        if interactive {addToolTip(CGRect(origin:.zero,size:size),owner:self,userData:nil)}
        setAccessibilityLabel(graph.metric.title)
        elements=value.hits.map {hit in
            let element=NSAccessibilityElement()
            element.setAccessibilityRole(.staticText);element.setAccessibilityLabel(hit.label)
            element.setAccessibilityParent(self);element.setAccessibilityFrameInParentSpace(hit.bounds)
            return element
        }
        // Every value remains accessible, including zero values, dense lines
        // and stacked areas which deliberately have no source hover regions.
        elements += value.accessibilityLabels.map {label in
            let element=NSAccessibilityElement();element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(label);element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(value.plotBounds);return element
        }
        setAccessibilityChildren(elements);needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let drawing,let context=NSGraphicsContext.current?.cgContext else{return}
        do {try MacGraphVectorRenderer.draw(scene:drawing.scene,in:context)}
        catch {toolTip=error.localizedDescription}
    }
    func view(_ view:NSView,stringForToolTip tag:NSView.ToolTipTag,point:NSPoint,userData:UnsafeMutableRawPointer?)->String {
        guard interactive else{return ""};return drawing?.tooltip(at:point) ?? ""
    }
    func retire(){removeAllToolTips();drawing=nil;elements=[];setAccessibilityChildren([]);interactive=false}
}
