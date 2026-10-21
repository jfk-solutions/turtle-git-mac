// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// The pinned property pages use thin group frames, compact captions and native
/// controls. Keep their grouping instead of macOS's large rounded card style.
struct SourceSettingsGroupBoxStyle:GroupBoxStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:0) {
            configuration.label.font(.body).padding(.horizontal,6).background(Color(nsColor:.windowBackgroundColor)).padding(.leading,8)
            configuration.content.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,4).padding(.bottom,4)
        }.frame(maxWidth:.infinity,alignment:.leading)
        .background(Rectangle().strokeBorder(Color(nsColor:.separatorColor),lineWidth:1).padding(.top,9))
    }
}

struct SettingsGraphPreview:NSViewRepresentable {
    let palette:LogColorPreferences
    func makeNSView(context:Context)->SettingsGraphPreviewView {SettingsGraphPreviewView()}
    func updateNSView(_ view:SettingsGraphPreviewView,context:Context) {view.palette=palette}
}
/// The sample uses the same stored RGB and theme transformation as Log. It
/// observes the draft directly; previewing never writes a temporary preference.
@MainActor final class SettingsGraphPreviewView:NSView {
    var palette=LogColorPreferences() {didSet {needsDisplay=true}}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityLabel(NSLocalizedString("Log graph preview",comment:""))}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    override var intrinsicContentSize:NSSize {.init(width:400,height:64)}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.textBackgroundColor.setFill();bounds.fill()
        let mode=StatusTextPalette.appearanceTraits(effectiveAppearance)
        let spacing=max(1,(bounds.width-32)/CGFloat(LogColorRole.lanes.count))
        for(index,role)in LogColorRole.lanes.enumerated() {
            let channels=StatusTextPalette.transform(palette.rgb(role),dark:mode.dark,highContrast:mode.highContrast)
            let color=NSColor(srgbRed:CGFloat(channels[0])/255,green:CGFloat(channels[1])/255,blue:CGFloat(channels[2])/255,alpha:1)
            let x=16+spacing*(CGFloat(index)+0.5),path=NSBezierPath()
            path.move(to:.init(x:x,y:8));path.line(to:.init(x:x,y:bounds.height-8));path.lineWidth=CGFloat(palette.lineWidth)
            color.setStroke();path.stroke()
            let size=CGFloat(palette.nodeSize),node=NSRect(x:x-size/2,y:bounds.midY-size/2,width:size,height:size)
            color.setFill();NSBezierPath(ovalIn:node).fill()
        }
        NSColor.separatorColor.setStroke();NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()
    }
}

struct SettingsPaletteSample:View {
    let rgb:[Int]
    let title:String
    let background:Bool
    var statusText=false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var color:NSColor {
        if statusText {return StatusTextPalette.text(rgb:rgb)}
        let channels=StatusTextPalette.transform(rgb,dark:colorScheme == .dark,highContrast:contrast == .increased)
        return NSColor(srgbRed:CGFloat(channels[0])/255,green:CGFloat(channels[1])/255,blue:CGFloat(channels[2])/255,alpha:1)
    }
    var body:some View {
        Text(verbatim:title).font(.system(.caption,design:.monospaced))
            .foregroundStyle(Color(nsColor:background ? LogPalette.foreground(background:color):color))
            .padding(.horizontal,5).padding(.vertical,2)
            .background(background ? Color(nsColor:color):Color(nsColor:.textBackgroundColor))
            .overlay(Rectangle().stroke(Color(nsColor:.separatorColor),lineWidth:1))
            .accessibilityLabel(Text("Color preview")+Text(": ")+Text(verbatim:title))
    }
}

struct SettingsSourceChoices<Value:Hashable>:View {
    let values:[Value]
    let selected:Value
    let title:(Value)->String
    let available:(Value)->Bool
    let choose:(Value)->Void
    var body:some View {
        HStack(spacing:8) {
            ForEach(Array(values.enumerated()),id:\.offset) {index,value in
                if index>0 {Text(index==1 ? "|":"<<").foregroundStyle(.secondary).accessibilityHidden(true)}
                let caption=NSLocalizedString(title(value),comment:"")
                BaseRadio(title:caption,selected:selected==value){choose(value)}
                    .frame(width:max(90,CGFloat(caption.count)*7+30),height:24).disabled(!available(value))
            }
            Spacer(minLength:0)
        }
    }
}

struct SettingsDraftCheckbox:NSViewRepresentable {
    let title:String,identifier:String
    @Binding var value:Bool
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSButton {NSButton(checkboxWithTitle:NSLocalizedString(title,comment:""),target:context.coordinator,action:#selector(Coordinator.clicked(_:)))}
    func updateNSView(_ button:NSButton,context:Context) {
        guard !context.coordinator.retired else{return}
        button.identifier = .init(identifier);button.title=NSLocalizedString(title,comment:"");button.state=value ? .on:.off;button.isEnabled=enabled
        context.coordinator.change={value=$0}
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator){coordinator.retired=true;coordinator.change={_ in};button.target=nil;button.action=nil;button.isEnabled=false}
    final class Coordinator:NSObject {
        var retired=false,change:(Bool)->Void={_ in}
        @objc func clicked(_ sender:NSButton){guard !retired,sender.isEnabled,sender.window != nil else{return};change(sender.state == .on)}
    }
}

/// Explicit AppKit numeric choices retain the source combo-box interaction on
/// SDKs whose automatic SwiftUI Picker uses a different presentation.
struct SettingsDraftIntegerChoice:NSViewRepresentable {
    let title:String
    let range:ClosedRange<Int>
    @Binding var value:Int
    @Environment(\.isEnabled) private var enabled
    @Environment(\.settingsTransaction) private var transaction
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->SettingsIntegerPopUpButton {
        let button=SettingsIntegerPopUpButton(frame:.zero,pullsDown:false)
        button.target=context.coordinator;button.action=#selector(Coordinator.changed(_:));return button
    }
    func updateNSView(_ button:SettingsIntegerPopUpButton,context:Context) {
        guard !context.coordinator.retired else{return}
        let titles=range.map{String($0)}
        if button.itemTitles != titles {button.removeAllItems();button.addItems(withTitles:titles)}
        button.selectItem(withTitle:String(value));button.isEnabled=enabled
        button.setAccessibilityLabel(NSLocalizedString(title,comment:""))
        context.coordinator.change={value=$0}
        context.coordinator.accepts={transaction?.busy != true}
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:SettingsIntegerPopUpButton,context:Context)->CGSize? {CGSize(width:80,height:26)}
    static func dismantleNSView(_ button:SettingsIntegerPopUpButton,coordinator:Coordinator) {
        coordinator.retired=true;coordinator.change={_ in};coordinator.accepts={false}
        button.target=nil;button.action=nil;button.isEnabled=false
    }
    @MainActor final class Coordinator:NSObject {
        var retired=false,change:(Int)->Void={_ in},accepts:()->Bool={false}
        @objc func changed(_ sender:SettingsIntegerPopUpButton) {
            guard !retired,sender.hasOriginalOwner,sender.isEnabled,sender.window?.attachedSheet==nil,accepts(),let title=sender.selectedItem?.title,let value=Int(title) else{return}
            change(value)
        }
    }
}
@MainActor final class SettingsIntegerPopUpButton:NSPopUpButton {
    private weak var originalOwner:NSWindow?
    private var attached=false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !attached,let window {attached=true;originalOwner=window}
    }
    var hasOriginalOwner:Bool {attached && originalOwner != nil && window === originalOwner}
}
