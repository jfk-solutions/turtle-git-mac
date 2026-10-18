import AppKit
import Combine
import SwiftUI
import TurtleGitCore

enum BlameMenuAction:String,CaseIterable {
    case find,findNext,findPrevious,goTo,nextChange,previousChange,nextPane,previousPane
    case toolbar,log,properties,statusBar,logID,author,date,filename,original
    case zoomIn,zoomOut,actualSize
    case ignoreWhitespace,completeLog,followRenames,firstParent,colorAge,syntax,dark,wrap
    var title:String {
        switch self {
        case .find:return "Find…";case .findNext:return "Find Next";case .findPrevious:return "Find Previous";case .goTo:return "Go To Line…"
        case .nextPane:return "Next Pane";case .previousPane:return "Previous Pane"
        case .zoomIn:return "Zoom In";case .zoomOut:return "Zoom Out";case .actualSize:return "Actual Size"
        case .nextChange:return "Next Change";case .previousChange:return "Previous Change"
        case .toolbar:return "Toolbar";case .log:return "Log";case .properties:return "Properties";case .statusBar:return "Status Bar"
        case .logID:return "Show log ID instead of SHA-1";case .author:return "Show author";case .date:return "Show date";case .filename:return "Show file name";case .original:return "Show original line number"
        case .ignoreWhitespace:return "Ignore whitespace";case .completeLog:return "Show complete log";case .followRenames:return "Follow renames";case .firstParent:return "Only consider first parents on blame"
        case .colorAge:return "Color by age, continuous";case .syntax:return "Enable syntax highlighting";case .dark:return "Dark Mode";case .wrap:return "Wrap long lines"
        }
    }
    var icon:MenuIcon {
        switch self {
        case .zoomIn:return .imageZoomIn;case .zoomOut:return .imageZoomOut;case .actualSize:return .imageOriginal
        case .find:return .mergeFind;case .findNext,.nextChange:return .jumpDown;case .findPrevious,.previousChange:return .jumpUp
        case .goTo,.log,.logID:return .log;case .nextPane,.previousPane:return .imageInfo;case .properties:return .imageInfo
        default:return .settings
        }
    }
}
private struct BlameMenuState:Equatable {
    var owner:ObjectIdentifier?,model:ObjectIdentifier?
    var enabled=false
    var checked:[BlameMenuAction:Bool]=[:]
    var allowed:[BlameMenuAction:Bool]=[:]
    var encoding:GitBlameEncoding?
    var detection:GitBlameDetectionMode = .disabled
}
/// All menus resolve the current window again when invoked. A background Blame
/// view must never receive commands from a different editor or retired owner.
@MainActor final class BlameMenuContext:ObservableObject {
    @Published private var state=BlameMenuState()
    private let keyWindow:()->NSWindow?
    private weak var observedModel:BlameWindowModel?
    private var modelChanges:AnyCancellable?
    private var notifications:[AnyCancellable]=[]
    init(keyWindow:@escaping ()->NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow=keyWindow
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.willCloseNotification,NSWindow.didUpdateNotification,NSApplication.didBecomeActiveNotification,NSNotification.Name("TurtleGit.BlameDocumentChanged")] {
            notifications.append(NotificationCenter.default.publisher(for:name).sink { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        refresh()
    }
    var owner:BlameWindowController? { let value=BlameWindowController.focusedOwner(keyWindow());return value?.model.retired==false ? value : nil }
    var focused:Bool { state.owner != nil }
    var available:Bool { state.enabled }
    var encoding:GitBlameEncoding? { state.encoding }
    var detection:GitBlameDetectionMode { state.detection }
    func checked(_ action:BlameMenuAction)->Bool { state.checked[action] ?? false }
    func allowed(_ action:BlameMenuAction)->Bool { state.enabled && (state.allowed[action] ?? true) }
    func refresh() {
        let owner=owner,model=owner?.model
        if observedModel !== model {
            modelChanges=nil;observedModel=model
            modelChanges=model?.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
        var next=BlameMenuState();next.owner=owner.map(ObjectIdentifier.init);next.model=model.map(ObjectIdentifier.init)
        if let model,let owner {
            next.enabled=owner.commandsAvailable
            next.encoding=model.sourceEncoding;next.detection=model.detectionMode
            next.checked=[.toolbar:model.showToolbar,.log:model.showLog,.properties:model.showProperties,.statusBar:model.showStatusBar,.ignoreWhitespace:model.ignoreWhitespace,.completeLog:model.canShowCompleteLog && model.showCompleteLog,.followRenames:model.canShowCompleteLog && model.showCompleteLog && model.followRenames,.firstParent:model.onlyFirstParent,.colorAge:model.colorAge,.syntax:model.syntaxEnabled,.wrap:model.wrapLongLines,.dark:owner.window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua]
            for (action,field) in [(BlameMenuAction.logID,BlameMarginField.logID),(.author,.author),(.date,.date),(.filename,.filename),(.original,.original)] { next.checked[action]=model.marginFields.contains(field) }
            next.allowed=[.zoomIn:model.canZoomIn,.zoomOut:model.canZoomOut,.actualSize:model.canResetZoom,.nextChange:!model.selectedLogHashes.isEmpty,.previousChange:!model.selectedLogHashes.isEmpty,.completeLog:model.canShowCompleteLog,.followRenames:model.canShowCompleteLog && model.showCompleteLog]
        }
        if state != next { state=next }
    }
    func perform(_ action:BlameMenuAction) {
        refresh();guard allowed(action),let owner else { return };let model=owner.model
        switch action {
        case .zoomIn:model.zoomIn();case .zoomOut:model.zoomOut();case .actualSize:model.resetZoom()
        case .find:model.onFind?();case .findNext:model.findLine(previous:false);case .findPrevious:model.findLine(previous:true);case .goTo:model.onGoTo?()
        case .nextPane:owner.focusNextPane(previous:false);case .previousPane:owner.focusNextPane(previous:true)
        case .nextChange:model.navigateChange(previous:false);case .previousChange:model.navigateChange(previous:true)
        case .toolbar:model.showToolbar.toggle();case .log:model.showLog.toggle();case .properties:model.showProperties.toggle();case .statusBar:model.showStatusBar.toggle()
        case .logID:model.setMargin(.logID,visible:!model.marginFields.contains(.logID));case .author:model.setMargin(.author,visible:!model.marginFields.contains(.author));case .date:model.setMargin(.date,visible:!model.marginFields.contains(.date));case .filename:model.setMargin(.filename,visible:!model.marginFields.contains(.filename));case .original:model.setMargin(.original,visible:!model.marginFields.contains(.original))
        case .ignoreWhitespace:model.setIgnoreWhitespace(!model.ignoreWhitespace);case .completeLog:model.setShowCompleteLog(!model.showCompleteLog);case .followRenames:model.setFollowRenames(!model.followRenames);case .firstParent:model.setOnlyFirstParent(!model.onlyFirstParent)
        case .colorAge:model.colorAge.toggle();case .syntax:model.setSyntaxEnabled(!model.syntaxEnabled);case .dark:owner.setDarkMode(!checked(.dark));case .wrap:model.setWrapLongLines(!model.wrapLongLines)
        }
        refresh()
    }
    func setEncoding(_ value:GitBlameEncoding?) { refresh();guard available else { return };owner?.model.setEncoding(value) }
    func setDetection(_ value:GitBlameDetectionMode) { refresh();guard available else { return };owner?.model.setDetectionMode(value) }
    func followSystemAppearance() { refresh();guard available else { return };owner?.followSystemAppearance();refresh() }
}
struct BlameCommands:Commands {
    @ObservedObject var context:BlameMenuContext
    private func item(_ action:BlameMenuAction)->some View {
        Button { context.perform(action) } label: { CommandLabel(title:action.title,icon:action.icon) }.disabled(!context.allowed(action))
    }
    private func toggle(_ action:BlameMenuAction)->some View {
        Toggle(isOn:Binding(get:{context.checked(action)},set:{ _ in context.perform(action) })) { CommandLabel(title:action.title,icon:action.icon) }.disabled(!context.allowed(action))
    }
    // Keep each builder fragment small for the hosted SDK while preserving the
    // View menu's relative order and resolving the focused owner on every action.
    @ViewBuilder private var paneAndZoomChoices:some View {
        Menu("Toolbars and Panes") { toggle(.toolbar);toggle(.log);toggle(.properties);if let model=context.owner?.model { Divider();BlamePaneLayoutMenu(model:model) } }
        toggle(.statusBar)
        item(.nextChange);item(.previousChange)
        Divider()
        item(.zoomIn).keyboardShortcut("+",modifiers:.command)
        item(.zoomOut).keyboardShortcut("-",modifiers:.command)
        item(.actualSize).keyboardShortcut("0",modifiers:.command)
        Divider()
    }
    @ViewBuilder private var attributionChoices:some View {
        ForEach([BlameMenuAction.logID,.author,.date,.filename,.original],id:\.self) { toggle($0) }
        Divider()
        Picker("Detect moved or copied lines",selection:Binding(get:{context.detection},set:{context.setDetection($0)})) {
            ForEach(GitBlameDetectionMode.allCases) { Text($0.title).tag($0) }
        }.disabled(!context.available)
        toggle(.ignoreWhitespace);Divider()
    }
    @ViewBuilder private var historyChoices:some View {
        toggle(.completeLog);toggle(.followRenames);toggle(.firstParent);Divider()
    }
    @ViewBuilder private var appearanceChoices:some View {
        toggle(.colorAge);toggle(.syntax);toggle(.dark)
        Button("Follow System Appearance") { context.followSystemAppearance() }.disabled(!context.available)
        Divider();toggle(.wrap)
    }
    var body:some Commands {
        CommandGroup(after:.newItem) {
            if context.focused,let store=context.owner?.recentDocuments { BlameRecentFileMenu(store:store,open:{ context.owner?.openRecent($0) }).disabled(!context.available) }
        }
        CommandGroup(after:.textEditing) {
            if context.focused {
                Divider()
                item(.find).keyboardShortcut("f",modifiers:.command)
                item(.findNext).keyboardShortcut("g",modifiers:.command)
                item(.findPrevious).keyboardShortcut("g",modifiers:[.command,.shift])
                item(.goTo).keyboardShortcut("l",modifiers:.command)
                Divider()
                item(.nextPane).keyboardShortcut(KeyEquivalent("\u{F709}"),modifiers:[])
                item(.previousPane).keyboardShortcut(KeyEquivalent("\u{F709}"),modifiers:.shift)
                BlameEncodingMenu(selection: Binding(get: { context.encoding }, set: { context.setEncoding($0) })).disabled(!context.available)
            }
        }
        CommandGroup(after:.toolbar) {
            if context.focused {
                paneAndZoomChoices
                attributionChoices
                historyChoices
                appearanceChoices
            }
        }
    }
}

/// The document/window router validates native window identity before calling
/// this helper. Recognized shortcuts remain consumed while the owner is blocked.
@MainActor enum BlameZoomKeyRouting {
    static func route(_ event:NSEvent, owner:BlameWindowController)->Bool {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        let key=event.charactersIgnoringModifiers ?? ""
        let action:BlameMenuAction
        if (flags == .command || flags == [.command,.shift]), key == "+" || key == "=" { action = .zoomIn }
        else if flags == .command,key == "-" { action = .zoomOut }
        else if flags == .command,key == "0" { action = .actualSize }
        else { return false }
        guard owner.commandsAvailable else { return true }
        switch action {
        case .zoomIn:if owner.model.canZoomIn { owner.model.zoomIn() }
        case .zoomOut:if owner.model.canZoomOut { owner.model.zoomOut() }
        case .actualSize:if owner.model.canResetZoom { owner.model.resetZoom() }
        default:break
        }
        return true
    }
}

/// Shared by the main menu and the window menu so both expose every source codec.
struct BlameEncodingMenu: View {
    @Binding var selection: GitBlameEncoding?
    private func choice(_ choice: GitBlameEncodingChoice) -> some View {
        Toggle(choice.title, isOn: Binding(get: {
            selection?.windowsCodePage == choice.codePage
        }, set: { _ in if let encoding = choice.encoding { selection = encoding } }))
        .disabled(choice.encoding == nil)
    }
    var body: some View {
        Menu("Encode") {
            ForEach(GitBlameEncodingMenu.unicode) { choice($0) }
            ForEach(GitBlameEncodingMenu.groups) { group in
                Menu(group.title) { ForEach(group.choices) { choice($0) } }
            }
            Divider()
            Toggle("Automatic", isOn: Binding(get: { selection == nil }, set: { _ in selection = nil }))
            Menu("Additional macOS Encodings") {
                ForEach(GitBlameEncodingMenu.additional) { encoding in
                    Toggle(encoding.rawValue, isOn: Binding(get: { selection?.id == encoding.id }, set: { _ in selection = encoding }))
                }
            }
        }
    }
}
