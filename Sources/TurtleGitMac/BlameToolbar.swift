// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import TurtleGitCore

/// Each document owns its native items and targets. Only layout is shared via
/// the injected preferences; AppKit identifiers never synchronize live owners.
@MainActor final class BlameToolbarController:NSObject,ObservableObject,NSToolbarDelegate,NSToolbarItemValidation,NSMenuItemValidation {
    let toolbar:NSToolbar
    @Published private(set) var configuration:BlameToolbarConfiguration
    private weak var owner:BlameWindowController?
    private weak var original:BlameWindowModel?
    private let store:BlameToolbarConfigurationStore
    private var observations:[AnyCancellable]=[]
    private var modeObservation:NSKeyValueObservation?,visibilityObservation:NSKeyValueObservation?
    private var restoring=true,retired=false,queued=false
    private var lastState="",configurationGeneration=UUID(),standardGeneration=UUID(),lastPaletteRunning=false
    var showAbout:()->Void={TurtleGitAboutService.shared.show(.blame)}
    var presentPalette:(NSToolbar)->Void={$0.runCustomizationPalette(nil)}
    private(set) var editor:BlameToolbarEditorController?
    var presentEditor:(NSWindow,NSWindow)->Void={owner,panel in owner.beginSheet(panel)}
    init(owner:BlameWindowController,preferences:UserDefaults) {
        self.owner=owner;original=owner.model;store=BlameToolbarConfigurationStore(defaults:preferences)
        configuration=store.load();toolbar=NSToolbar(identifier:"TurtleGit.Blame."+UUID().uuidString)
        super.init();toolbar.delegate=self;toolbar.allowsUserCustomization=true;toolbar.autosavesConfiguration=false
        owner.window?.toolbarStyle = .expanded;owner.window?.toolbar=toolbar
        owner.model.showToolbar=configuration.standard.isVisible
        restoreStandard();restoring=false
        observations.append(owner.model.objectWillChange.sink{[weak self] _ in self?.scheduleRefresh()})
        for name in [NSWindow.willBeginSheetNotification,NSWindow.didEndSheetNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.didUpdateNotification] {
            observations.append(NotificationCenter.default.publisher(for:name).sink{[weak self] _ in self?.scheduleRefresh()})
        }
        modeObservation=toolbar.observe(\.displayMode,options:[.new]){[weak self] _,_ in MainActor.assumeIsolated{self?.saveStandard()}}
        visibilityObservation=toolbar.observe(\.isVisible,options:[.new]){[weak self] value,_ in MainActor.assumeIsolated{
            guard let self,!self.restoring,self.live else{return};self.owner?.model.showToolbar=value.isVisible;self.saveStandard()
        }}
        observations.append(NotificationCenter.default.publisher(for:UserDefaults.didChangeNotification).sink{[weak self] _ in DispatchQueue.main.async{self?.synchronizePreferences()}})
        refresh()
    }
    var live:Bool {!retired && owner?.model === original && original?.retired == false}
    var available:Bool {live && owner?.window != nil && owner?.commandsAvailable == true && NSApp.modalWindow == nil}
    private func scheduleRefresh(){guard !queued,!retired else{return};queued=true;DispatchQueue.main.async{[weak self] in self?.queued=false;self?.refresh()}}
    private static func identifier(_ id:String)->NSToolbarItem.Identifier {id=="space" ? .space:id=="flexibleSpace" ? .flexibleSpace:.init("TurtleGit.Blame.Command."+id)}
    private static func itemID(_ id:NSToolbarItem.Identifier)->String? {
        if id == .space{return "space"};if id == .flexibleSpace{return "flexibleSpace"}
        let prefix="TurtleGit.Blame.Command.";return id.rawValue.hasPrefix(prefix) ? String(id.rawValue.dropFirst(prefix.count)):nil
    }
    static func title(_ id:String)->String {NSLocalizedString(BlameToolbarCommand.title(for:id),comment:"")}
    static func icon(_ id:String)->MenuIcon {MenuIcon(rawValue:BlameToolbarCommand.iconName(for:id)) ?? .settings}
    private func restoreStandard(){
        restoring=true;standardGeneration=UUID();defer{restoring=false}
        for index in toolbar.items.indices.reversed(){toolbar.removeItem(at:index)}
        for (index,id) in configuration.standard.items.enumerated(){toolbar.insertItem(withItemIdentifier:Self.identifier(id),at:index)}
        toolbar.displayMode=configuration.standard.displayMode == .icons ? .iconOnly:configuration.standard.displayMode == .labels ? .labelOnly:.iconAndLabel
        toolbar.isVisible=configuration.standard.isVisible
    }
    private func saveStandard(){
        guard !restoring,live else{return}
        var standard=configuration.standard
        standard.items=toolbar.items.compactMap{Self.itemID($0.itemIdentifier)}
        standard.displayMode=toolbar.displayMode == .iconOnly ? .icons:toolbar.displayMode == .labelOnly ? .labels:.iconsAndLabels
        standard.isVisible=owner?.model.showToolbar ?? toolbar.isVisible
        guard standard != configuration.standard else{return}
        standardGeneration=UUID()
        var latest=store.load();latest.standard=standard;configuration=latest;store.save(latest)
        for item in toolbar.items{update(item)}
    }
    private func synchronizePreferences(){
        guard live,editor==nil,!toolbar.customizationPaletteIsRunning else{return}
        let latest=store.load();guard latest != configuration else{return}
        configurationGeneration=UUID();configuration=latest;owner?.model.showToolbar=latest.standard.isVisible;restoreStandard();refresh()
    }
    func toolbarWillAddItem(_ notification:Notification){if !restoring{standardGeneration=UUID()};scheduleSave()}
    func toolbarDidRemoveItem(_ notification:Notification){if !restoring{standardGeneration=UUID()};scheduleSave()}
    private func scheduleSave(){guard !restoring else{return};DispatchQueue.main.async{[weak self] in self?.saveStandard()}}
    func refresh(){
        guard live else{return}
        let paletteRunning=toolbar.customizationPaletteIsRunning
        let finishedPalette=lastPaletteRunning && !paletteRunning;lastPaletteRunning=paletteRunning
        if finishedPalette{synchronizePreferences()}
        if let show=owner?.model.showToolbar,toolbar.isVisible != show {restoring=true;toolbar.isVisible=show;restoring=false;saveStandard()}
        for item in toolbar.items {update(item)}
        let state=BlameToolbarCommand.availableItemIDs.map{String(enabled($0))+String(checked($0))}.joined()
        if state != lastState {lastState=state;objectWillChange.send()}
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{BlameToolbarConfiguration.defaults.standard.items.map(Self.identifier)}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{BlameToolbarCommand.availableItemIDs.map(Self.identifier)+[.space,.flexibleSpace]}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        guard live,let id=Self.itemID(identifier),BlameToolbarCommand.isKnownItem(id),id != "space",id != "flexibleSpace" else{return nil}
        let item=NSToolbarItem(itemIdentifier:identifier);item.label=Self.title(id);item.paletteLabel=item.label;item.toolTip=item.label
        item.image=Self.icon(id).image(size:20);item.target=self;item.action=#selector(invoke(_:));item.autovalidates=false
        if Self.toggle(id){item.view=button(id,mode:.icons,barID:BlameToolbarConfiguration.standardID)}
        update(item);return item
    }
    private func update(_ item:NSToolbarItem){
        guard let id=Self.itemID(item.itemIdentifier),BlameToolbarCommand.isKnownItem(id) else{return}
        item.isEnabled=enabled(id)
        if let button=item.view as? BlameToolbarButton {button.isEnabled=item.isEnabled;button.state=checked(id) ? .on:.off;let receipt=BlameToolbarReceipt(id:id,barID:BlameToolbarConfiguration.standardID,generation:standardGeneration);receipt.nativeItem=item;button.receipt=receipt}
        let menu=menuItem(id);(menu.representedObject as? BlameToolbarReceipt)?.nativeItem=item;item.menuFormRepresentation=menu
    }
    func menuItem(_ id:String,barID:UUID? = nil,standalone:Bool=false)->NSMenuItem {
        let item=NSMenuItem(title:Self.title(id),action:#selector(invoke(_:)),keyEquivalent:"");item.target=self;item.representedObject=BlameToolbarReceipt(id:id,barID:barID ?? BlameToolbarConfiguration.standardID,generation:barID==nil || barID==BlameToolbarConfiguration.standardID ? standardGeneration:configurationGeneration,standalone:standalone)
        item.image=Self.icon(id).contextImage(defaults:owner?.model.labelDefaults ?? .standard);item.isEnabled=enabled(id);item.state=checked(id) ? .on:.off;return item
    }
    private func receiptAvailable(_ receipt:BlameToolbarReceipt)->Bool {
        guard available else{return false}
        if receipt.standalone{return receipt.generation==standardGeneration}
        if receipt.barID==BlameToolbarConfiguration.standardID {
            guard receipt.generation==standardGeneration,toolbar.isVisible,owner?.window?.toolbar === toolbar else{return false}
            if let item=receipt.nativeItem{return toolbar.items.contains{$0 === item}}
            return toolbar.items.contains{Self.itemID($0.itemIdentifier)==receipt.id}
        }
        guard receipt.generation==configurationGeneration else{return false}
        return configuration.customBars.contains{$0.id==receipt.barID && $0.isVisible && $0.items.contains(receipt.id)}
    }
    @objc private func invoke(_ sender:Any?) {
        if let item=sender as? NSToolbarItem,toolbar.isVisible,toolbar.items.contains(where:{$0 === item}),let id=Self.itemID(item.itemIdentifier){perform(id)}
        else if let item=sender as? NSMenuItem,let receipt=item.representedObject as? BlameToolbarReceipt,receiptAvailable(receipt){perform(receipt.id)}
        else if let control=sender as? BlameToolbarButton,let receipt=control.receipt,receiptAvailable(receipt){perform(receipt.id)}
    }
    private static func toggle(_ id:String)->Bool {let toggles:Set<String>=["toolbar","log","properties","statusBar","logID","author","date","filename","original","ignoreWhitespace","completeLog","followRenames","firstParent","colorAge","syntax","dark","wrap","followSystemAppearance","detectDisabled","detectWithinFile","detectModifiedFiles","detectFileCreation","detectExistingFiles"];return toggles.contains(id) || id.hasPrefix("encoding.")}
    func button(_ id:String,mode:BlameToolbarDisplayMode,barID:UUID)->NSButton {
        let button=BlameToolbarButton(title:mode == .icons ? "":Self.title(id),target:self,action:#selector(invoke(_:)));button.receipt=BlameToolbarReceipt(id:id,barID:barID,generation:barID==BlameToolbarConfiguration.standardID ? standardGeneration:configurationGeneration)
        button.image=mode == .labels ? nil:Self.icon(id).image(size:20);button.imagePosition=mode == .icons ? .imageOnly:.imageLeading
        button.setButtonType(Self.toggle(id) ? .toggle:.momentaryPushIn);button.state=checked(id) ? .on:.off;button.bezelStyle = .texturedRounded;button.toolTip=Self.title(id);button.setAccessibilityLabel(Self.title(id));button.setAccessibilityIdentifier("TurtleGit.Blame.Toolbar."+id);button.isEnabled=enabled(id);button.sizeToFit();return button
    }
    func validateToolbarItem(_ item:NSToolbarItem)->Bool {Self.itemID(item.itemIdentifier).map(enabled) ?? false}
    func validateMenuItem(_ item:NSMenuItem)->Bool {(item.representedObject as? BlameToolbarReceipt).map{receiptAvailable($0) && enabled($0.id)} ?? false}
    func enabled(_ id:String)->Bool {
        guard available,let owner else{return false};let model=owner.model
        switch id {
        case "previousChange","nextChange":return !model.selectedLogHashes.isEmpty
        case "zoomIn":return model.canZoomIn
        case "zoomOut":return model.canZoomOut
        case "actualSize":return model.canResetZoom
        case "completeLog":return model.canShowCompleteLog
        case "followRenames":return model.canShowCompleteLog && model.showCompleteLog
        case "copy":return Self.copyTarget(owner) != nil
        default:return id != "space" && id != "flexibleSpace" && BlameToolbarCommand.isKnownItem(id)
        }
    }
    private static func copyTarget(_ owner:BlameWindowController)->AnyObject? {
        guard let window=owner.window,owner.commandKeyWindow() === window else{return nil}
        let action=NSSelectorFromString("copy:"),probe=NSMenuItem(title:"Copy",action:NSSelectorFromString("copy:"),keyEquivalent:"")
        var responder=window.firstResponder,seen=Set<ObjectIdentifier>()
        while let current=responder,seen.insert(ObjectIdentifier(current)).inserted {
            if current.responds(to:action) {
                if let validator=current as? NSMenuItemValidation,!validator.validateMenuItem(probe){return nil}
                if let validator=current as? NSUserInterfaceValidations,!validator.validateUserInterfaceItem(probe){return nil}
                return current
            }
            if current === window {break};responder=current.nextResponder
        }
        return nil
    }
    func checked(_ id:String)->Bool {
        guard let model=owner?.model else{return false}
        let field:[String:BlameMarginField]=["logID":.logID,"author":.author,"date":.date,"filename":.filename,"original":.original];if let value=field[id]{return model.marginFields.contains(value)}
        if id=="encoding.automatic" {return model.sourceEncoding==nil}
        if let encoding=BlameToolbarCommand.encoding(for:id){return model.sourceEncoding?.id==encoding.id}
        let detection:[String:GitBlameDetectionMode]=["detectDisabled":.disabled,"detectWithinFile":.withinFile,"detectModifiedFiles":.modifiedFiles,"detectFileCreation":.fileCreation,"detectExistingFiles":.existingFiles]
        if let value=detection[id]{return model.detectionMode==value}
        switch id {case "dark":return owner?.window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        case "followSystemAppearance":return model.labelDefaults.object(forKey:"Blame.DarkMode")==nil
        case "toolbar":return model.showToolbar;case "log":return model.showLog;case "properties":return model.showProperties;case "statusBar":return model.showStatusBar;case "wrap":return model.wrapLongLines;case "ignoreWhitespace":return model.ignoreWhitespace;case "completeLog":return model.canShowCompleteLog && model.showCompleteLog;case "followRenames":return model.canShowCompleteLog && model.showCompleteLog && model.followRenames;case "firstParent":return model.onlyFirstParent;case "colorAge":return model.colorAge;case "syntax":return model.syntaxEnabled;default:return false}
    }
    func perform(_ id:String){
        guard enabled(id),let owner else{return};let model=owner.model
        if let action=BlameMenuAction(rawValue:id){owner.performToolbarMenuAction(action);refresh();return}
        switch id {
        case "open":owner.openDocument()
        case "reload":model.reload(saveThresholds:true)
        case "copy":if let target=Self.copyTarget(owner){NSApp.sendAction(NSSelectorFromString("copy:"),to:target,from:owner.window)}
        case "about":showAbout()
        case "settings":model.showSettings()
        case "close":owner.window?.performClose(nil)
        case "followSystemAppearance":owner.followSystemAppearance()
        case "detectDisabled":model.setDetectionMode(.disabled)
        case "detectWithinFile":model.setDetectionMode(.withinFile)
        case "detectModifiedFiles":model.setDetectionMode(.modifiedFiles)
        case "detectFileCreation":model.setDetectionMode(.fileCreation)
        case "detectExistingFiles":model.setDetectionMode(.existingFiles)
        case "encoding":owner.showToolbarEncodingMenu()
        case "encoding.automatic":model.setEncoding(nil)
        default:if let encoding=BlameToolbarCommand.encoding(for:id){model.setEncoding(encoding)}
        }
        refresh()
    }
    func customize(){guard available,owner?.window?.toolbar === toolbar else{return};presentPalette(toolbar)}
    func edit(){
        guard available,editor==nil,let window=owner?.window else{return}
        let controller=BlameToolbarEditorController(chrome:self);editor=controller
        controller.onClosed={[weak self,weak controller] in if self?.editor === controller {self?.editor=nil;self?.synchronizePreferences()}}
        guard let panel=controller.window else{return};panel.appearance=window.appearance;panel.alphaValue=window.alphaValue;presentEditor(window,panel)
    }
    private func canConfigure(_ session:UUID?)->Bool {
        guard live,let owner,owner.model.canFind,!owner.hasBlockingHistoryChild,owner.goToWindow==nil else{return false}
        if let session,editor?.sessionID != session{return false}
        if editor != nil,session != editor?.sessionID{return false}
        if let sheet=owner.window?.attachedSheet {return session != nil && sheet === editor?.window}
        return NSApp.modalWindow==nil
    }
    private func adoptLatestConfiguration(){
        let latest=store.load(),changed=latest.standard != configuration.standard
        configuration=latest
        if changed{owner?.model.showToolbar=latest.standard.isVisible;restoreStandard()}
    }
    func update(_ bar:BlameToolbarBar,session:UUID?=nil){guard canConfigure(session) else{return};configurationGeneration=UUID();adoptLatestConfiguration();configuration.updateBar(bar);store.save(configuration);if bar.id==BlameToolbarConfiguration.standardID {owner?.model.showToolbar=configuration.standard.isVisible;restoreStandard()};refresh()}
    @discardableResult func createBar(name:String,session:UUID?=nil)->UUID? {guard canConfigure(session) else{return nil};configurationGeneration=UUID();adoptLatestConfiguration();let id=configuration.createBar(name:name);store.save(configuration);refresh();return id}
    func removeBar(_ id:UUID,session:UUID?=nil){guard canConfigure(session) else{return};configurationGeneration=UUID();adoptLatestConfiguration();_ = configuration.removeBar(id:id);store.save(configuration);refresh()}
    func moveBar(_ id:UUID,offset:Int,session:UUID?=nil){guard canConfigure(session) else{return};adoptLatestConfiguration();var latest=configuration;guard let i=latest.customBars.firstIndex(where:{$0.id==id}),latest.customBars.indices.contains(i+offset) else{return};configurationGeneration=UUID();latest.customBars.swapAt(i,i+offset);configuration=latest;store.save(latest);refresh()}
    func reset(session:UUID?=nil){guard canConfigure(session) else{return};configurationGeneration=UUID();configuration=store.reset();owner?.model.showToolbar=configuration.standard.isVisible;restoreStandard();refresh()}
    func retire(){guard !retired else{return};saveStandard();retired=true;observations=[];modeObservation=nil;visibilityObservation=nil
        editor?.closeEditor();editor=nil
        for item in toolbar.items{item.isEnabled=false};if owner?.window?.toolbar === toolbar {owner?.window?.toolbar=nil};owner=nil;original=nil
    }
}
private final class BlameToolbarReceipt:NSObject {let id:String;let barID:UUID;let generation:UUID;let standalone:Bool;weak var nativeItem:NSToolbarItem?;init(id:String,barID:UUID,generation:UUID,standalone:Bool=false){self.id=id;self.barID=barID;self.generation=generation;self.standalone=standalone}}
@MainActor private final class BlameToolbarButton:NSButton {var receipt:BlameToolbarReceipt?}
