// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum UnifiedDiffZoomCommand:String,CaseIterable,Sendable {
    case zoomIn,zoomOut,reset
}

/// Temporary editor-local Scintilla zoom, independent of the persisted base
/// font size. Interactive commands match Editor::KeyCommand's -10...60 limits.
public struct UnifiedDiffZoom:Equatable,Sendable {
    public private(set) var level:Int=0
    public init() {}
    public func canPerform(_ command:UnifiedDiffZoomCommand)->Bool {
        switch command {
        case .zoomIn:return level<60
        case .zoomOut:return level > -10
        case .reset:return level != 0
        }
    }
    @discardableResult public mutating func perform(_ command:UnifiedDiffZoomCommand)->Bool {
        guard canPerform(command) else{return false}
        switch command {
        case .zoomIn:level+=1
        case .zoomOut:level-=1
        case .reset:level=0
        }
        return true
    }
    /// ViewStyle::FontRealised clamps the effective size, not the zoom level.
    /// The caller supplies its validated base setting (currently 1...1000).
    public func effectiveFontSize(base:Int)->Int {
        let (value,overflow)=base.addingReportingOverflow(level)
        return overflow ? (level>0 ? Int.max:1):max(1,value)
    }
}

/// Source-unit wheel accumulation from ScintillaWin's MouseWheelDelta. Positive
/// source deltas zoom in. Each delivered event produces at most one command,
/// even when several complete 120-unit ticks were accumulated. Cocoa point and
/// device-axis conversion belong to the native consumer, not this policy.
public struct UnifiedDiffZoomWheelAccumulator:Equatable,Sendable {
    private var remainder:Double=0
    public init() {}
    public mutating func reset() {remainder=0}
    public mutating func command(sourceDelta:Double)->UnifiedDiffZoomCommand? {
        guard sourceDelta.isFinite else{return nil}
        remainder-=sourceDelta
        guard abs(remainder)>=120 else{return nil}
        let command:UnifiedDiffZoomCommand=remainder<0 ? .zoomIn:.zoomOut
        // truncatingRemainder has C/C++ remainder's sign (unlike floor-based
        // modulo), retaining the correct partial tick after direction changes.
        remainder=remainder.truncatingRemainder(dividingBy:120)
        return command
    }
}
