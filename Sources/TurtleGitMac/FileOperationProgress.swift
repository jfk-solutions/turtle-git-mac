import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

struct FileOperationProgressRow: Identifiable {
    enum Kind { case command, file, finished, error, skipped }
    let id = UUID()
    let action: String
    let path: String
    let kind: Kind
}
enum FileOperationProgressAction { case log, open, openWith, explore }
/// CGitProgressList's notification/result surface, independent of transient
/// worker output. A menu captures row IDs and the attempt that produced them.
@MainActor final class FileOperationProgressState: ObservableObject {
    let preferences: UserDefaults
    @Published private(set) var rows: [FileOperationProgressRow] = []
    private(set) var generation = UUID()
    var publishClipboard: (String) -> Void = { text in NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string) }
    init(preferences:UserDefaults) {self.preferences=preferences}
    func begin(_ command:String) {generation=UUID();rows=[];append("Command",command,kind:.command)}
    func append(_ action:String,_ path:String,kind:FileOperationProgressRow.Kind) {rows.append(.init(action:action,path:path,kind:kind))}
    func finish(success:Bool,cancelled:Bool,started:Date) {
        let footer=SubmoduleProgressCompletion(success:success,cancelled:cancelled,exitCode:nil,elapsed:Date().timeIntervalSince(started),preferences:preferences,showTimings:true)
        let text=footer.text.trimmingCharacters(in:.newlines)
        append("Finished",(success ? "Success":"Failed")+String(text.dropFirst(footer.currentWork.count)),kind:.finished)
    }
    func retire() {generation=UUID()}
    func color(_ row:FileOperationProgressRow)->NSColor {
        switch row.kind {
        case .command:return ProgressNotificationColor.command(preferences:preferences)
        case .file:return row.action == "Added" ? StatusTextPalette.text(.added,preferences:preferences):.labelColor
        case .error:return StatusTextPalette.text(.conflict,preferences:preferences)
        case .skipped:return .secondaryLabelColor
        case .finished:
            let success=row.path.hasPrefix("Success")
            return NSColor(name:nil){appearance in
                if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast{return .labelColor}
                let dark=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
                return success ? NSColor(srgbRed:0,green:dark ? 178.0/255:0,blue:1,alpha:1):NSColor(srgbRed:dark ? 207.0/255:1,green:dark ? 47.0/255:0,blue:dark ? 47.0/255:0,alpha:1)
            }
        }
    }
    var output:String {rows.map{$0.action+": "+$0.path}.joined(separator:"\n")}
}
struct FileOperationProgressTable: NSViewRepresentable {
    @ObservedObject private var statusColorUpdates=StatusColorUpdates.shared
    @ObservedObject var state:FileOperationProgressState
    let icon:MenuIcon
    let available:Bool
    let repository:URL
    var keyboardAvailable=true
    var perform:(FileOperationProgressAction,String)->Void = {_,_ in}
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.make()}
    func updateNSView(_ view:NSScrollView,context:Context) {context.coordinator.parent=self;if context.coordinator.generation != state.generation{context.coordinator.generation=state.generation;context.coordinator.table.deselectAll(nil)};context.coordinator.table.reloadData()}
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator){coordinator.table.makeMenu={nil};coordinator.table.copySelection={};coordinator.table.resultAvailable={false};coordinator.table.retainedMenuTargets=[];coordinator.table.target=nil;coordinator.table.delegate=nil;coordinator.table.dataSource=nil}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var parent:FileOperationProgressTable
        let table:FileOperationProgressNativeTable
        var generation:UUID
        private var sorting:(String,Bool)?
        var rows:[FileOperationProgressRow] {
            guard let (key,ascending)=sorting else{return parent.state.rows}
            var result=parent.state.rows
            let indices=result.indices.filter{result[$0].kind == .file}
            let files=indices.map{result[$0]}.sorted{a,b in
                let left=key=="action" ? a.action:a.path,right=key=="action" ? b.action:b.path
                return left.compare(right,options:.literal) == (ascending ? .orderedAscending:.orderedDescending)
            }
            for (index,row) in zip(indices,files){result[index]=row};return result
        }
        init(_ parent:FileOperationProgressTable) {self.parent=parent;generation=parent.state.generation;table=FileOperationProgressNativeTable(icon:parent.icon,defaults:parent.state.preferences)}
        func make()->NSScrollView {
            let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .bezelBorder
            table.dataSource=self;table.delegate=self;table.rowHeight=22;table.allowsMultipleSelection=true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id,title,width) in [("action","Action",120.0),("path","Path",560.0)] {let column=NSTableColumn(identifier:.init(id));column.title=NSLocalizedString(title,comment:"");column.width=width;column.sortDescriptorPrototype=NSSortDescriptor(key:id,ascending:true);table.addTableColumn(column)}
            table.target=self;table.doubleAction=#selector(openRow(_:));table.makeMenu={ [weak self] in self?.menu() };table.copySelection={ [weak self] in self?.copySelected() };table.resultAvailable={ [weak self] in self?.parent.keyboardAvailable==true };scroll.documentView=table;return scroll
        }
        func numberOfRows(in tableView:NSTableView)->Int {rows.count}
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]){guard parent.available,let sort=table.sortDescriptors.first,let key=sort.key else{return};sorting=(key,sort.ascending);table.reloadData()}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            let snapshot=rows;guard snapshot.indices.contains(row) else{return nil};let value=snapshot[row],field=NSTextField(labelWithString:tableColumn?.identifier.rawValue == "action" ? NSLocalizedString(value.action,comment:""):value.path)
            field.lineBreakMode = .byTruncatingMiddle;field.textColor=parent.state.color(value);field.toolTip=value.path;return field
        }
        @objc func openRow(_ sender:Any?) {let snapshot=rows;guard parent.available,snapshot.indices.contains(table.clickedRow) else{return};let row=snapshot[table.clickedRow];guard row.kind == .file else{return};parent.perform(.open,row.path)}
        func copySelected(){guard parent.keyboardAvailable else{return};let snapshot=rows;let text=table.selectedRowIndexes.compactMap{snapshot.indices.contains($0) ? snapshot[$0].action+": "+snapshot[$0].path+"  \r\n":nil}.joined();if !text.isEmpty{parent.state.publishClipboard(text)}}
        func menu()->NSMenu? {
            guard parent.available,!table.selectedRowIndexes.isEmpty else{return nil}
            let snapshot=rows,captured=table.selectedRowIndexes.compactMap{snapshot.indices.contains($0) ? snapshot[$0]:nil},generation=parent.state.generation
            let menu=NSMenu();var targets:[FileOperationProgressMenuTarget]=[]
            func add(_ title:String,_ icon:MenuIcon,_ body:@escaping()->Void) {let target=FileOperationProgressMenuTarget{ [weak self] in guard let self,self.parent.available,self.parent.state.generation==generation else{return};body()};targets.append(target);let item=NSMenuItem(title:NSLocalizedString(title,comment:""),action:#selector(FileOperationProgressMenuTarget.invoke(_:)),keyEquivalent:"");item.target=target;item.image=icon.contextImage(defaults:parent.state.preferences);menu.addItem(item)}
            if captured.count==1,let row=captured.first,row.kind == .file {
                add("Show Log",.log){ [weak self] in self?.parent.perform(.log,row.path)};menu.addItem(.separator())
                let url=parent.repository.appendingPathComponent(row.path),directory=(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true
                if !directory {add("Open",.open){ [weak self] in self?.parent.perform(.open,row.path)};add("Open With",.open){ [weak self] in self?.parent.perform(.openWith,row.path)}}
                add("Explore to",.explore){ [weak self] in self?.parent.perform(.explore,row.path)};menu.addItem(.separator())
            }
            add("Copy to Clipboard",.copy){ [weak self] in
                var text=captured.map(\.path).joined(separator:"\r\n")
                while text.last?.isWhitespace==true{text.removeLast()}
                if !text.isEmpty{self?.parent.state.publishClipboard(text)}
            }
            table.retainedMenuTargets=targets;return menu
        }
    }
}
@MainActor final class FileOperationProgressMenuTarget:NSObject {let action:()->Void;private var consumed=false;init(_ action:@escaping()->Void){self.action=action};@objc func invoke(_ sender:Any?){guard !consumed else{return};consumed=true;action()}}
@MainActor final class FileOperationProgressNativeTable:NativeWatermarkTable {
    var makeMenu:()->NSMenu? = {nil}
    var retainedMenuTargets:[FileOperationProgressMenuTarget]=[]
    var copySelection:()->Void = {}
    var resultAvailable:()->Bool = {false}
    @objc func copy(_ sender:Any?){copySelection()}
    override func performKeyEquivalent(with event:NSEvent)->Bool{if routeKey(event){return true};return super.performKeyEquivalent(with:event)}
    override func keyDown(with event:NSEvent){if routeKey(event){return};super.keyDown(with:event)}
    private func routeKey(_ event:NSEvent)->Bool{
        let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if modifiers == .command,event.charactersIgnoringModifiers=="a"{if resultAvailable(){selectAll(nil)};return true}
        if modifiers == .command,event.charactersIgnoringModifiers=="c"{copySelection();return true}
        if event.keyCode==109,modifiers == .shift{return showKeyboardMenu()};return false
    }
    override func accessibilityPerformShowMenu()->Bool{showKeyboardMenu()}
    private func showKeyboardMenu()->Bool{guard selectedRow>=0,let menu=makeMenu() else{return false};let rect=rect(ofRow:selectedRow);menu.popUp(positioning:nil,at:NSPoint(x:rect.minX+20,y:rect.maxY),in:self);return true}
    override func menu(for event:NSEvent)->NSMenu? {let row=row(at:convert(event.locationInWindow,from:nil));if row>=0,!selectedRowIndexes.contains(row){selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)};return makeMenu()}
}
@MainActor enum FileOperationWindowDrain {
    static func detach(_ window:NSWindow)async {
        if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.orderOut(nil)
        while window.sheetParent != nil {try? await Task.sleep(nanoseconds:5_000_000)}
    }
}
/// Own the native Open With sheet and the launch callback independently of
/// the result view. Captured repository access stays alive until launch settles.
@MainActor final class FileOperationProgressFiles {
    weak var window:NSWindow?
    let repository:GitRepository
    let access:RepositoryAccessLease?
    var available:()->Bool = {true}
    var onLog:(String)->Void = {_ in}
    var onError:(String)->Void = {_ in}
    var onBusy:(Bool)->Void = {_ in}
    private(set) var busy=false
    private(set) var retired=false
    private var panel:NSOpenPanel?
    var chooseApplication:((NSOpenPanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var open:(URL,URL?)async throws->Void = {url,app in
        if let app {try await withCheckedThrowingContinuation{(reply:CheckedContinuation<Void,Error>) in NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()){_,error in if let error {reply.resume(throwing:error)}else{reply.resume()}}}}
        else if !NSWorkspace.shared.open(url){throw CocoaError(.fileReadUnknown)}
    }
    init(repository:GitRepository,access:RepositoryAccessLease?){self.repository=repository;self.access=access}
    func retire(){retired=true;panel?.cancel(nil)}
    func perform(_ action:FileOperationProgressAction,path:String) {
        guard !retired,!busy,available(),let window,window.attachedSheet == nil else{return}
        if action == .log {onLog(path);return}
        let root=repository.root.standardizedFileURL,url=root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path+"/"),!path.split(separator:"/").contains(".git"),!GitRuntime.isAppStoreBuild || access?.permits(url)==true else {onError(RepositoryAccessFailure.securityScopeUnavailable.localizedDescription);return}
        if action == .explore || (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true {
            NSWorkspace.shared.activateFileViewerSelecting([url]);return
        }
        busy=true;onBusy(true)
        Task { [self] in
            var applicationAccess:RepositoryAccessLease?
            defer{busy=false;onBusy(false);withExtendedLifetime(access){};withExtendedLifetime(applicationAccess){}}
            do {
                var application:URL?
                if action == .openWith {
                    let chooser=NSOpenPanel();panel=chooser;chooser.title="Open With";chooser.prompt="Open";chooser.canChooseDirectories=false;chooser.canChooseFiles=true;chooser.allowsMultipleSelection=false;chooser.allowedContentTypes=[.applicationBundle];chooser.directoryURL=URL(fileURLWithPath:"/Applications",isDirectory:true);chooser.alphaValue=window.alphaValue;chooser.appearance=window.appearance
                    let answer:NSApplication.ModalResponse=await withCheckedContinuation{reply in var answered=false;let accept:(NSApplication.ModalResponse)->Void={value in guard !answered else{return};answered=true;reply.resume(returning:value)};if let chooseApplication {chooseApplication(chooser,window,accept)}else{chooser.beginSheetModal(for:window,completionHandler:accept)}}
                    await FileOperationWindowDrain.detach(chooser);panel=nil
                    guard answer == .OK,let selected=chooser.url,!retired,available() else{return};applicationAccess=RepositoryAccessLease(url:selected);guard !GitRuntime.isAppStoreBuild || applicationAccess?.hasSecurityScope==true else{throw RepositoryAccessFailure.securityScopeUnavailable};application=selected
                }
                guard !retired,available() else{return};try await open(url,application)
            }catch{if !retired,available(){onError(error.localizedDescription)}}
        }
    }
}
