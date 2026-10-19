import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

struct FileOperationProgressRow: Identifiable {
    enum Kind { case command, file, finished, error, skipped }
    let id: UUID
    let action: String
    let path: String
    let kind: Kind
    let status: String?
    init(action:String,path:String,kind:Kind,status:String?=nil,id:UUID=UUID()) {self.id=id;self.action=action;self.path=path;self.kind=kind;self.status=status}
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
    func record(id:UUID,action:String,path:String,status:String) {
        let row=FileOperationProgressRow(action:action,path:path,kind:.file,status:status,id:id)
        if let index=rows.firstIndex(where:{$0.id==id}) {rows[index]=row} else {rows.append(row)}
    }
    func finish(success:Bool,cancelled:Bool,started:Date) {
        let footer=SubmoduleProgressCompletion(success:success,cancelled:cancelled,exitCode:nil,elapsed:Date().timeIntervalSince(started),preferences:preferences,showTimings:true)
        let text=footer.text.trimmingCharacters(in:.newlines)
        append("Finished",(success ? "Success":"Failed")+String(text.dropFirst(footer.currentWork.count)),kind:.finished)
    }
    func retire() {generation=UUID()}
    func color(_ row:FileOperationProgressRow)->NSColor {
        if row.status == "Failed" {return StatusTextPalette.text(.conflict,preferences:preferences)}
        if row.status == "Cancelled" {return .systemOrange}
        if row.status == "Completed" {return StatusTextPalette.text(.modified,preferences:preferences)}
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
    var fileRowIcons=false
    var actionAvailability:()->Bool = {true}
    var actionsAllowed:Bool {available && actionAvailability()}
    var perform:(FileOperationProgressAction,String)->Void = {_,_ in}
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.make()}
    func updateNSView(_ view:NSScrollView,context:Context) {context.coordinator.parent=self;if context.coordinator.generation != state.generation{context.coordinator.resetAttempt()};context.coordinator.reloadPreservingSelection()}
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator){coordinator.table.makeMenu={nil};coordinator.table.copySelection={};coordinator.table.resultAvailable={false};coordinator.table.retainedMenuTargets=[];coordinator.table.target=nil;coordinator.table.delegate=nil;coordinator.table.dataSource=nil}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var parent:FileOperationProgressTable
        let table:FileOperationProgressNativeTable
        var generation:UUID
        private var selectionGeneration=UUID()
        private var sorting:(String,Bool)?
        private var acceptedSortDescriptors:[NSSortDescriptor]=[]
        private var restoringSort=false
        private var displayedRowIDs:[UUID]=[]
        private var preservingSelection=false
        func reloadPreservingSelection() {
            let selected=Set(table.selectedRowIndexes.compactMap{displayedRowIDs.indices.contains($0) ? displayedRowIDs[$0]:nil})
            displayedRowIDs=rows.map(\.id)
            preservingSelection=true
            table.reloadData()
            table.selectRowIndexes(IndexSet(displayedRowIDs.indices.filter{selected.contains(displayedRowIDs[$0])}),byExtendingSelection:false)
            preservingSelection=false
            if Set(displayedRowIDs.filter{selected.contains($0)}) != selected {selectionGeneration=UUID()}
        }
        func resetAttempt() {
            generation=parent.state.generation;sorting=nil;acceptedSortDescriptors=[];displayedRowIDs=[]
            restoringSort=true;table.sortDescriptors=[];restoringSort=false;table.deselectAll(nil)
        }
        var rows:[FileOperationProgressRow] {
            guard let (key,ascending)=sorting else{return parent.state.rows}
            var result=parent.state.rows
            var start=0
            while start < result.count {
                guard result[start].kind == .file else {start += 1;continue}
                var end=start+1
                while end < result.count,result[end].kind == .file {end += 1}
                result.replaceSubrange(start..<end,with:result[start..<end].sorted{a,b in
                    var order=key=="action" ? a.action.compare(b.action,options:.literal):.orderedSame
                    if order == .orderedSame {order=a.path.compare(b.path,options:.literal)}
                    return order == (ascending ? .orderedAscending:.orderedDescending)
                });start=end
            }
            return result
        }
        init(_ parent:FileOperationProgressTable) {self.parent=parent;generation=parent.state.generation;table=FileOperationProgressNativeTable(icon:parent.icon,defaults:parent.state.preferences)}
        func make()->NSScrollView {
            let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .bezelBorder
            displayedRowIDs=rows.map(\.id)
            table.dataSource=self;table.delegate=self;table.rowHeight=22;table.allowsMultipleSelection=true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id,title,width) in [("action","Action",120.0),("path","Path",560.0)] {let column=NSTableColumn(identifier:.init(id));column.title=NSLocalizedString(title,comment:"");column.width=width;column.sortDescriptorPrototype=NSSortDescriptor(key:id,ascending:true);table.addTableColumn(column)}
            table.target=self;table.doubleAction=#selector(openRow(_:));table.makeMenu={ [weak self] in self?.menu() };table.copySelection={ [weak self] in self?.copySelected() };table.resultAvailable={ [weak self] in self?.parent.keyboardAvailable==true && self?.parent.actionAvailability()==true };scroll.documentView=table;return scroll
        }
        func numberOfRows(in tableView:NSTableView)->Int {rows.count}
        func tableViewSelectionDidChange(_ notification:Notification){if !preservingSelection {selectionGeneration=UUID()}}
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
            guard !restoringSort else{return}
            guard parent.actionsAllowed else {
                restoringSort=true;table.sortDescriptors=acceptedSortDescriptors;restoringSort=false;return
            }
            guard let sort=table.sortDescriptors.first,let key=sort.key else{return}
            sorting=(key,sort.ascending);acceptedSortDescriptors=table.sortDescriptors
            reloadPreservingSelection()
        }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            let snapshot=rows;guard snapshot.indices.contains(row) else{return nil};let value=snapshot[row],field=NSTextField(labelWithString:tableColumn?.identifier.rawValue == "action" ? NSLocalizedString(value.action,comment:""):value.path)
            field.lineBreakMode = .byTruncatingMiddle;field.textColor=parent.state.color(value);field.toolTip=value.path+(value.status.map{"\n"+$0} ?? "")
            guard parent.fileRowIcons,value.kind == .file,tableColumn?.identifier.rawValue == "action" else{return field}
            let width=tableColumn?.width ?? 120,cell=NSTableCellView(frame:NSRect(x:0,y:0,width:width,height:22))
            let image=NSImageView(frame:NSRect(x:2,y:3,width:16,height:16));image.image=parent.icon.contextImage(defaults:parent.state.preferences)
            cell.imageView=image;cell.textField=field;cell.toolTip=field.toolTip;cell.addSubview(image)
            field.frame=NSRect(x:23,y:2,width:max(0,width-26),height:18);field.autoresizingMask=[.width];cell.addSubview(field);return cell
        }
        @objc func openRow(_ sender:Any?) {let snapshot=rows;guard parent.actionsAllowed,snapshot.indices.contains(table.clickedRow) else{return};let row=snapshot[table.clickedRow];guard row.kind == .file else{return};parent.perform(.open,row.path)}
        func copySelected(){guard parent.keyboardAvailable,parent.actionAvailability() else{return};let snapshot=rows;let text=table.selectedRowIndexes.compactMap{snapshot.indices.contains($0) ? snapshot[$0].action+": "+snapshot[$0].path+"  \r\n":nil}.joined();if !text.isEmpty{parent.state.publishClipboard(text)}}
        func menu()->NSMenu? {
            guard parent.actionsAllowed,!table.selectedRowIndexes.isEmpty else{return nil}
            let snapshot=rows,captured=table.selectedRowIndexes.compactMap{snapshot.indices.contains($0) ? snapshot[$0]:nil},generation=parent.state.generation,selection=selectionGeneration
            let menu=NSMenu();var targets:[FileOperationProgressMenuTarget]=[]
            func add(_ title:String,_ icon:MenuIcon,_ body:@escaping()->Void) {let target=FileOperationProgressMenuTarget{ [weak self] in guard let self,self.parent.actionsAllowed,self.parent.state.generation==generation,self.selectionGeneration==selection else{return};body()};targets.append(target);let item=NSMenuItem(title:NSLocalizedString(title,comment:""),action:#selector(FileOperationProgressMenuTarget.invoke(_:)),keyEquivalent:"");item.target=target;item.image=icon.contextImage(defaults:parent.state.preferences);menu.addItem(item)}
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
    private var selectionReply:((NSApplication.ModalResponse)->Void)?
    var chooseApplication:((NSOpenPanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var selectedApplication:(NSOpenPanel)->URL? = {$0.url}
    var reveal:([URL])->Void = {NSWorkspace.shared.activateFileViewerSelecting($0)}
    var open:(URL,URL?)async throws->Void = {url,app in
        if let app {try await withCheckedThrowingContinuation{(reply:CheckedContinuation<Void,Error>) in NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()){_,error in if let error {reply.resume(throwing:error)}else{reply.resume()}}}}
        else if !NSWorkspace.shared.open(url){throw CocoaError(.fileReadUnknown)}
    }
    private static func identity(_ url:URL)throws->[UInt64] {
        let values=try FileManager.default.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)
        guard let device=values[.systemNumber] as? NSNumber,let inode=values[.systemFileNumber] as? NSNumber else {throw CocoaError(.fileReadUnknown)}
        return [device.uint64Value,inode.uint64Value]
    }
    init(repository:GitRepository,access:RepositoryAccessLease?){self.repository=repository;self.access=access}
    func retire(){retired=true;panel?.cancel(nil);selectionReply?(.cancel)}
    func perform(_ action:FileOperationProgressAction,path:String) {
        guard !retired,!busy,available(),let window,window.attachedSheet == nil else{return}
        if action == .log {onLog(path);return}
        busy=true;onBusy(true)
        Task { [self] in
            var applicationAccess:RepositoryAccessLease?
            defer{busy=false;onBusy(false);withExtendedLifetime(access){};withExtendedLifetime(applicationAccess){}}
            do {
                var application:URL?
                let destination=try await repository.fileRevealDestination(path:path)
                guard !retired,available() else{return}
                let initial:URL
                var existing=false
                switch destination {case .select(let url):initial=url;existing=true;case .openDirectory(let url):initial=url}
                guard !GitRuntime.isAppStoreBuild || access?.permits(initial)==true else {throw RepositoryAccessFailure.securityScopeUnavailable}
                if action == .explore || existing && (try? initial.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true {
                    guard !retired,available() else{return}
                    if existing {reveal([initial])} else {try await open(initial,nil)}
                    return
                }
                let original=try await repository.workingFileOpenLocation(path:path)
                guard !retired,available() else{return}
                let identity=try Self.identity(original)
                if action == .openWith {
                    let chooser=NSOpenPanel();panel=chooser;chooser.title="Open With";chooser.prompt="Open";chooser.canChooseDirectories=false;chooser.canChooseFiles=true;chooser.allowsMultipleSelection=false;chooser.allowedContentTypes=[.applicationBundle];chooser.directoryURL=URL(fileURLWithPath:"/Applications",isDirectory:true);chooser.alphaValue=window.alphaValue;chooser.appearance=window.appearance
                    let answer:NSApplication.ModalResponse=await withCheckedContinuation{reply in var answered=false;let accept:(NSApplication.ModalResponse)->Void={value in guard !answered else{return};answered=true;reply.resume(returning:value)};selectionReply=accept;if let chooseApplication {chooseApplication(chooser,window,accept)}else{chooser.beginSheetModal(for:window,completionHandler:accept)}}
                    await FileOperationWindowDrain.detach(chooser);panel=nil;selectionReply=nil
                    guard answer == .OK,let selected=selectedApplication(chooser),!retired,available() else{return};applicationAccess=RepositoryAccessLease(url:selected);guard !GitRuntime.isAppStoreBuild || applicationAccess?.hasSecurityScope==true else{throw RepositoryAccessFailure.securityScopeUnavailable};application=selected
                }
                guard !retired,available() else{return}
                let url=try await repository.workingFileOpenLocation(path:path)
                guard !retired,available() else{return}
                let current=try Self.identity(url)
                guard identity == current,
                      !GitRuntime.isAppStoreBuild || access?.permits(url)==true else {throw WorkingFileExportFailure.location}
                guard !retired,available() else{return};try await open(url,application)
            }catch{if !retired,available(){onError(error.localizedDescription)}}
        }
    }
}
