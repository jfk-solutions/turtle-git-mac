// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Docking preserves simultaneous bars around the document; floating bars
/// remain owned native child panels. The standard top bar is AppKit's toolbar.
struct BlameToolbarDockLayout<Content:View>:View {
    @ObservedObject var chrome:BlameToolbarController
    @ViewBuilder let content:()->Content
    var body:some View {
        VStack(spacing:2){edge(.top)
            HStack(spacing:2){edge(.left);content().frame(maxWidth:.infinity,maxHeight:.infinity);edge(.right)}
            edge(.bottom)
        }.overlay(alignment:.topLeading){if let placement=chrome.dockingPreview {Text(LocalizedStringKey(placement.title)).font(.caption).padding(6).background(.regularMaterial).allowsHitTesting(false)}}
    }
    @ViewBuilder private func edge(_ placement:BlameToolbarPlacement)->some View {
        if placement == .left || placement == .right {
            HStack(spacing:2){ForEach(chrome.bars(at:placement)){bar in BlameToolbarStripView(chrome:chrome,bar:bar).frame(width:bar.displayMode == .icons ? 38:170)}}
        }else{
            VStack(spacing:2){ForEach(chrome.bars(at:placement)){bar in BlameToolbarStripView(chrome:chrome,bar:bar).frame(height:bar.displayMode == .iconsAndLabels ? 34:30)}}
        }
    }
}
struct BlameToolbarStripView:NSViewRepresentable {
    @ObservedObject var chrome:BlameToolbarController
    let bar:BlameToolbarBar
    func makeNSView(context:Context)->BlameToolbarStrip {BlameToolbarStrip()}
    func updateNSView(_ view:BlameToolbarStrip,context:Context){view.configure(chrome:chrome,bar:bar)}
    static func dismantleNSView(_ view:BlameToolbarStrip,coordinator:()){view.clear()}
}
@MainActor final class BlameToolbarStrip:NSView {
    private weak var chrome:BlameToolbarController?
    private var bar:BlameToolbarBar?
    var barID:UUID? {bar?.id}
    private var grip:BlameToolbarGrip?
    private var lastSignature=""
    override var isFlipped:Bool {true}
    private var controls:[(String,NSView)]=[]
    private let overflow=NSPopUpButton(frame:.zero,pullsDown:true)
    private let caption=NSTextField(labelWithString:"")
    override init(frame:NSRect){super.init(frame:frame);caption.font = .systemFont(ofSize:11);caption.textColor = .secondaryLabelColor;addSubview(caption);overflow.title=NSLocalizedString("More",comment:"");overflow.bezelStyle = .texturedRounded;overflow.setAccessibilityLabel(NSLocalizedString("Toolbar overflow",comment:""));addSubview(overflow)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func clear(){if let chrome {chrome.stripHosts.removeValue(forKey:ObjectIdentifier(self))};grip?.removeFromSuperview();grip=nil;for (_,view) in controls{view.removeFromSuperview()};controls=[];overflow.menu=nil;chrome=nil;bar=nil}
    func configure(chrome:BlameToolbarController,bar:BlameToolbarBar){
        let signature=chrome.configuration.generation.uuidString+chrome.presentationGeneration(bar.id).uuidString+String(chrome.available)+bar.items.map{String(chrome.enabled($0))+String(chrome.checked($0))}.joined()
        if self.chrome === chrome,self.bar==bar,lastSignature==signature{return}
        clear();lastSignature=signature;self.chrome=chrome;self.bar=bar;chrome.stripHosts[ObjectIdentifier(self)]=BlameToolbarWeakStrip(self)
        let grip=BlameToolbarGrip(chrome:chrome,barID:bar.id,frame:NSRect(x:0,y:0,width:20,height:28));self.grip=grip;addSubview(grip)
        setAccessibilityIdentifier("TurtleGit.Blame.ToolbarStrip."+bar.id.uuidString+"."+bar.placement.rawValue)
        caption.stringValue=bar.name;caption.setAccessibilityLabel(String(format:NSLocalizedString("%@ toolbar",comment:""),bar.name));caption.sizeToFit()
        for (index,id) in bar.items.enumerated() {
            let view:NSView
            if id=="space" || id=="flexibleSpace" {view=BlameToolbarSpacer(chrome:chrome,barID:bar.id,index:index)}
            else {view=chrome.button(id,mode:bar.displayMode,barID:bar.id)}
            controls.append((id,view));addSubview(view)
        }
        needsLayout=true
    }
    override func layout(){
        super.layout();guard let chrome,let bar else{return}
        let vertical=bar.placement == .left || bar.placement == .right
        grip?.frame=NSRect(x:0,y:vertical ? 0:bounds.midY-12,width:20,height:24)
        if vertical {
            caption.isHidden=true;var y:CGFloat=28;var hidden:[String]=[]
            let flexible=controls.filter{$0.0=="flexibleSpace"}.count,required=controls.reduce(CGFloat(0)){$0+($1.0=="flexibleSpace" ? 24:max(24,$1.1.frame.height))+3}
            let extra=flexible>0 ? max(0,bounds.height-56-required)/CGFloat(flexible):0
            for (id,view) in controls {let height=id=="flexibleSpace" ? 24+extra:max(24,view.frame.height);view.isHidden=y+height>bounds.height-28
                if !view.isHidden{view.frame=NSRect(x:2,y:y,width:max(24,bounds.width-4),height:height);y+=height+3}
                else if id != "space" && id != "flexibleSpace"{hidden.append(id)}}
            overflow.isHidden=hidden.isEmpty;overflow.frame=NSRect(x:0,y:max(0,bounds.height-26),width:bounds.width,height:26)
            let menu=NSMenu();menu.autoenablesItems=false;menu.addItem(withTitle:NSLocalizedString("More",comment:""),action:nil,keyEquivalent:"");for id in hidden{menu.addItem(chrome.menuItem(id,barID:bar.id))};overflow.menu=menu;overflow.isEnabled=chrome.available;return
        }
        caption.isHidden=false
        let captionWidth=min(130,caption.fittingSize.width);caption.frame=NSRect(x:20,y:bounds.midY-7,width:captionWidth,height:16)
        var x=captionWidth+28;let reserve:CGFloat=60;var hidden:[String]=[]
        let flexible=controls.filter{$0.0=="flexibleSpace"}.count
        let required=controls.reduce(CGFloat(0)){$0+($1.0=="flexibleSpace" ? 12:max(12,$1.1.frame.width))+4}
        let slack=max(0,bounds.width-reserve-x-required),extra=flexible>0 ? slack/CGFloat(flexible):0
        for (id,view) in controls {
            let width=id=="flexibleSpace" ? 12+extra:max(12,view.frame.width)
            let fits=x+width<=bounds.width-reserve;view.isHidden = !fits
            if fits {view.frame=NSRect(x:x,y:(bounds.height-view.frame.height)/2,width:width,height:view.frame.height);x+=width+4}
            else if id != "space" && id != "flexibleSpace" {hidden.append(id)}
        }
        overflow.isHidden=hidden.isEmpty;overflow.frame=NSRect(x:max(0,bounds.width-reserve),y:bounds.midY-13,width:reserve,height:26)
        let menu=NSMenu();menu.autoenablesItems=false;menu.addItem(withTitle:NSLocalizedString("More",comment:""),action:nil,keyEquivalent:"")
        for id in hidden{menu.addItem(chrome.menuItem(id,barID:bar.id))};overflow.menu=menu;overflow.isEnabled=chrome.available
    }
    func ownsCommandControl(_ view:NSView)->Bool {controls.contains{$0.1 === view}}
    func ownsGrip(_ view:BlameToolbarGrip)->Bool {grip === view}
    func ownsSpacer(_ view:NSView,index:Int)->Bool {controls.indices.contains(index) && controls[index].1 === view}
    override func menu(for event:NSEvent)->NSMenu? {guard let bar,let chrome,chrome.stripHosts[ObjectIdentifier(self)]?.view === self,lastSignature.hasPrefix(chrome.configuration.generation.uuidString) else{return nil};return chrome.contextMenu(barID:bar.id)}
    func insertionIndex(at point:NSPoint)->Int {
        guard let bar else{return 0};let vertical=bar.placement == .left || bar.placement == .right
        for (index,pair) in controls.enumerated() where !pair.1.isHidden {
            if vertical ? point.y<pair.1.frame.midY:point.x<pair.1.frame.midX{return index}
        }
        return bar.items.count
    }

}

@MainActor final class BlameToolbarEditorController:NSWindowController {
    var onClosed:()->Void={}
    private var finished=false
    let sessionID=UUID()
    init(chrome:BlameToolbarController){
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:520),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        panel.title=NSLocalizedString("Toolbars",comment:"");panel.isReleasedWhenClosed=false;panel.minSize=NSSize(width:680,height:420)
        super.init(window:panel);panel.contentViewController=NSHostingController(rootView:BlameToolbarEditor(chrome:chrome,session:sessionID,done:{[weak self] in self?.closeEditor()}))
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func closeEditor(){guard !finished else{return};finished=true;if let window{window.sheetParent?.endSheet(window,returnCode:.OK);window.close()};onClosed()}
}
private struct BlameToolbarEditor:View {
    @ObservedObject var chrome:BlameToolbarController
    let session:UUID
    let done:()->Void
    @State private var selected=BlameToolbarConfiguration.standardID
    @State private var newName=""
    @State private var selection:Int?
    @State private var addID="reload"
    @State private var warning=""
    private var bar:BlameToolbarBar? {chrome.configuration.allBars.first{$0.id==selected}}
    private func modify(_ body:(inout BlameToolbarBar)->Void){guard var bar else{return};body(&bar);chrome.update(bar,session:session)}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HSplitView {
                VStack(alignment:.leading){
                    List(selection:$selected){ForEach(chrome.configuration.allBars){bar in Text(bar.name).tag(bar.id)}}
                    HStack {TextField("New toolbar name",text:$newName);Button("New"){if let id=chrome.createBar(name:newName,session:session){selected=id;newName="";warning=""}else{warning="Choose a unique toolbar name."}}.disabled(newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    HStack {Button("Delete"){chrome.removeBar(selected,session:session);selected=BlameToolbarConfiguration.standardID}.disabled(selected==BlameToolbarConfiguration.standardID)
                        Button("Move Up"){chrome.moveBar(selected,offset:-1,session:session)}.disabled(selected==BlameToolbarConfiguration.standardID)
                        Button("Move Down"){chrome.moveBar(selected,offset:1,session:session)}.disabled(selected==BlameToolbarConfiguration.standardID)}
                }.frame(minWidth:220,idealWidth:240)
                if let bar {
                    VStack(alignment:.leading,spacing:10){
                        TextField("Toolbar name",text:Binding(get:{self.bar?.name ?? ""},set:{name in modify{$0.name=name}})).disabled(selected==BlameToolbarConfiguration.standardID)
                        HStack {Toggle("Visible",isOn:Binding(get:{self.bar?.isVisible ?? false},set:{value in modify{$0.isVisible=value}}));Spacer()
                            Picker("Display",selection:Binding(get:{self.bar?.displayMode ?? .iconsAndLabels},set:{value in modify{$0.displayMode=value}})){ForEach(BlameToolbarDisplayMode.allCases,id:\.self){Text(LocalizedStringKey($0.title)).tag($0)}}.frame(width:240)}
                        Picker("Placement",selection:Binding(get:{self.bar?.placement ?? .top},set:{value in modify{$0.placement=value}})){ForEach(BlameToolbarPlacement.allCases){Text(LocalizedStringKey($0.title)).tag($0)}}
                        List(selection:$selection){ForEach(Array(bar.items.enumerated()),id:\.offset){index,id in Text(BlameToolbarController.title(id)).tag(index)}}
                        HStack {Button("Remove"){guard let index=selection else{return};modify{if $0.items.indices.contains(index){$0.items.remove(at:index)}};selection=nil}.disabled(selection==nil)
                            Button("Move Up"){move(-1)}.disabled(selection==nil || selection==0)
                            Button("Move Down"){move(1)}.disabled(selection==nil || selection==bar.items.count-1)}
                        HStack {Picker("Command",selection:$addID){ForEach(BlameToolbarCommand.availableItemIDs+["space","flexibleSpace"],id:\.self){Text(BlameToolbarController.title($0)).tag($0)}}
                            Button("Add"){modify{$0.items.append(addID)}}.disabled(bar.items.count>=BlameToolbarConfiguration.maximumItemsPerBar || (bar.items.contains(addID) && addID != "space" && addID != "flexibleSpace"))}
                    }.padding(.leading,8).frame(minWidth:390)
                }
            }
            if !warning.isEmpty {Text(warning).foregroundStyle(.orange)}
            HStack {Button("Reset All Toolbars"){chrome.reset(session:session);selected=BlameToolbarConfiguration.standardID;selection=nil};Spacer();Button("Done",action:done).keyboardShortcut(.defaultAction)}
        }.padding(16).onChange(of:selected){_ in selection=nil}
    }
    private func move(_ offset:Int){guard let index=selection,let bar else{return};let next=index+offset;guard bar.items.indices.contains(index),bar.items.indices.contains(next) else{return};modify{$0.items.swapAt(index,next)};selection=next}
}

struct BlameCustomToolbarMenu:View {
    @ObservedObject var chrome:BlameToolbarController
    var body:some View {ForEach(chrome.configuration.customBars){bar in
        Toggle(bar.name,isOn:Binding(get:{chrome.configuration.customBars.first{$0.id==bar.id}?.isVisible ?? false},set:{value in var changed=bar;changed.isVisible=value;chrome.update(changed)})).disabled(!chrome.available)
    }}
}
