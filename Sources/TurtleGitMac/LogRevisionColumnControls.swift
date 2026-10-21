// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// ColumnManager's divider double-click fits contents; Shift restores automatic
/// sizing. Keep the native header's ordinary click/order/resize behavior.
@MainActor final class LogRevisionColumnHeader:NSTableHeaderView {
    var makeMenu:()->NSMenu?={nil}
    var fitColumn:(Int,Bool)->Void={_,_ in}
    override func menu(for event:NSEvent)->NSMenu? {makeMenu()}
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2,let table=tableView {
            let point=convert(event.locationInWindow,from:nil)
            for(index,column)in table.tableColumns.enumerated() where !column.isHidden {
                if abs(point.x-headerRect(ofColumn:index).maxX)<=4 {
                    fitColumn(index,event.modifierFlags.contains(.shift));return
                }
            }
        }
        super.mouseDown(with:event)
    }
    func retire(){makeMenu={nil};fitColumn={_,_ in};menu=nil}
}

/// A closing Log retains an actual Reset question until its callback and sheet
/// have both settled. Late/duplicate replies cannot apply another column reset.
@MainActor final class LogRevisionColumnQuestion {
    private(set) static var activeCount=0
    let alert:NSAlert
    private weak var owner:NSWindow?
    private var answered=false,retired=false,finished=false,started=false
    private var response=NSApplication.ModalResponse.abort
    private var poll:Task<Void,Never>?
    private var completion:(Bool)->Void
    init(owner:NSWindow,alert:NSAlert,completion:@escaping(Bool)->Void) {
        self.owner=owner;self.alert=alert;self.completion=completion
    }
    func begin(present:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void) {
        guard !started else{return};started=true
        guard let owner,!retired else{let done=completion;completion={_ in};done(false);return}
        Self.activeCount += 1
        present(owner,alert){[self] result in
            guard !answered else{return};answered=true;response=result
            if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:result)}
            alert.window.orderOut(nil)
        }
        poll=Task{@MainActor [self] in
            while !answered || alert.window.sheetParent != nil || alert.window.attachedSheet != nil || self.owner?.attachedSheet === alert.window {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            guard !finished else{return};finished=true;poll=nil;Self.activeCount -= 1
            let done=completion;completion={_ in};done(!retired && response == .alertFirstButtonReturn)
        }
    }
    func retire() {
        guard !retired else{return};retired=true
        if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.abort)}
        alert.window.orderOut(nil)
    }
}
