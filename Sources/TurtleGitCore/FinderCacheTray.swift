// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of TGitCache.cpp's optional tray and fifteen-row activity window.
import AppKit
import Darwin

public struct FinderCacheTrayPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var showMenuIcons: Bool
    public init(enabled: Bool = false, showMenuIcons: Bool = true) { self.enabled=enabled;self.showMenuIcons=showMenuIcons }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("cache-tray-settings.json") }
    public static let notification = "org.turtlegit.macos.cachePresentationChanged"
    public static func from(defaults: UserDefaults = .standard) -> Self {
        Self(enabled: (defaults.object(forKey:"CacheTrayIcon") as? NSNumber)?.uint32Value == 1,
             showMenuIcons: MenuPresentationSettings.applicationContextIcons(defaults:defaults))
    }
    public static func read(from url: URL?) -> Self {
        guard let url,let data=try? Data(contentsOf:url),data.count<=4096,
              let value=try? JSONDecoder().decode(Self.self,from:data) else { return Self() }
        return value
    }
    @discardableResult public func write(to url: URL? = sharedURL) throws -> Bool {
        guard let url else {return false}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(self).write(to:url,options:.atomic);return true
    }
}
public struct FinderCacheActivityLog: Sendable {
    public private(set) var lines:[String]=[]
    public init() {}
    public mutating func append(_ text:String) {
        var line="",units=0
        for character in text {
            let size=String(character).utf16.count
            if units+size>520 { break };line.append(character);units += size
        }
        lines.append(line);if lines.count>15 {lines.removeFirst(lines.count-15)}
    }
}
public struct FinderCacheActivitySnapshot: Sendable {
    public var running:Bool
    public var cachedDirectories:Int
    public var watchedPaths:Int
    public var lines:[String]
    public init(running:Bool,cachedDirectories:Int=0,watchedPaths:Int=0,lines:[String]=[]) {
        self.running=running;self.cachedDirectories=cachedDirectories;self.watchedPaths=watchedPaths;self.lines=Array(lines.suffix(15))
    }
    public var summary:String { "TurtleGit Overlay Icon Server\nCached directories: \(cachedDirectories)\nWatched paths: \(watchedPaths)" }
}

/// Runs in the independent agent. Private activity never enters Finder's shared
/// snapshot or the authenticated IPC report. Exit is supplied by its process host.
/// The service menu owns only CacheType. Its shared-record merge and policy
/// fence must participate in the same transaction as the application settings.
enum FinderCacheTrayStatusPolicy {
    static func setCacheMode(_ mode:FinderOverlayCacheMode,overlaysURL:URL,statusURL:URL? = nil) throws {
        let statusURL=statusURL ?? overlaysURL.deletingLastPathComponent().appendingPathComponent("status.json")
        var original:Data?,permissions:Any?,next=FinderOverlaySettings()
        try FinderSnapshotStore(url:statusURL).configureStatusPolicy(policy:{
            var info=stat()
            if lstat(overlaysURL.path,&info)==0 {
                guard info.st_mode&S_IFMT==S_IFREG,info.st_size>=0,info.st_size<=1048576 else{throw GitConfigurationFailure.invalidValue}
                original=try Data(contentsOf:overlaysURL);permissions=try FileManager.default.attributesOfItem(atPath:overlaysURL.path)[.posixPermissions]
            } else if errno != ENOENT {throw GitConfigurationFailure.invalidValue}
            next=try FinderOverlaySettings.readChecked(from:overlaysURL);next.cacheMode=mode
            return FinderStatusPolicy(settings:next,preferences:try FinderStatusPolicyPreferences.read(from:statusURL))
        },publish:{_ = try next.write(to:overlaysURL)},rollback:{
            if let original {try original.write(to:overlaysURL,options:.atomic);if let permissions {try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:overlaysURL.path)}}
            else if FileManager.default.fileExists(atPath:overlaysURL.path) {guard try FileManager.default.attributesOfItem(atPath:overlaysURL.path)[.type] as? FileAttributeType == .typeRegular else{throw GitConfigurationFailure.invalidValue};try FileManager.default.removeItem(at:overlaysURL)}
        })
    }
}

@MainActor public final class FinderCacheTrayController:NSObject,NSMenuDelegate {
    public let menu=NSMenu()
    public private(set) var activityWindow:NSWindow?
    public private(set) var stopping=false
    public private(set) var retired=false
    public private(set) var tooltip=""
    public private(set) var failure:String?
    private let preferencesURL:URL?
    private let overlaysURL:URL?
    private let installStatusItem:Bool
    private let snapshot:()->FinderCacheActivitySnapshot
    private let notify:()->Void
    private let exitService:() async -> Void
    private var statusItem:NSStatusItem?
    private var observers:[NSObjectProtocol]=[]
    private var textView:NSTextView?
    private var summaryField:NSTextField?
    private var generation=0
    private var lastEnabled=false
    private var stopTask:Task<Void,Never>?
    public init(preferencesURL:URL?=FinderCacheTrayPreferences.sharedURL,overlaysURL:URL?=FinderOverlaySettings.sharedURL,
                installStatusItem:Bool=true,snapshot:@escaping ()->FinderCacheActivitySnapshot,
                notify:@escaping ()->Void={DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil)},
                exitService:@escaping () async -> Void) {
        self.preferencesURL=preferencesURL;self.overlaysURL=overlaysURL;self.installStatusItem=installStatusItem
        self.snapshot=snapshot;self.notify=notify;self.exitService=exitService;super.init();menu.delegate=self;menu.autoenablesItems=false
        for name in [FinderCacheTrayPreferences.notification,FinderIntegration.notification] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.refresh()}})
        }
        refresh()
    }
    public func refresh() {
        guard !retired else{return}
        let preferences=FinderCacheTrayPreferences.read(from:preferencesURL),value=snapshot()
        if preferences.enabled != lastEnabled {lastEnabled=preferences.enabled;generation += 1}
        tooltip=stopping ? "TurtleGit Overlay Icon Server — stopping…" : value.summary
        if preferences.enabled && installStatusItem && statusItem==nil {
            let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);statusItem=item;item.menu=menu
            item.button?.setAccessibilityLabel("TurtleGit status cache")
        } else if !preferences.enabled,let item=statusItem {NSStatusBar.system.removeStatusItem(item);statusItem=nil}
        statusItem?.button?.image=(stopping ? MenuIcon.remove : MenuIcon.turtle).image(size:18)
        statusItem?.button?.toolTip=tooltip
        if !preferences.enabled {activityWindow?.orderOut(nil)}
        summaryField?.stringValue=tooltip
        textView?.string=(value.lines + (failure.map{["Error: "+$0]} ?? [])).joined(separator:"\n")
    }
    public func menuNeedsUpdate(_ menu:NSMenu) {
        guard menu === self.menu else{return};rebuildMenu()
    }
    public func rebuildMenu() {
        refresh();generation += 1;let request=generation;menu.removeAllItems()
        guard !retired else{return}
        let preferences=FinderCacheTrayPreferences.read(from:preferencesURL),current=FinderOverlaySettings.read(from:overlaysURL)
        func add(_ title:String,_ icon:MenuIcon,_ action:@escaping ()->Void) {
            let target=Action{[weak self] in guard let self,!self.retired,!self.stopping,self.generation==request,FinderCacheTrayPreferences.read(from:self.preferencesURL).enabled else{return};action()}
            let item=NSMenuItem(title:title,action:#selector(Action.activateCacheMenuItem(_:)),keyEquivalent:"");item.target=target;item.representedObject=target;item.isEnabled = !stopping
            if preferences.showMenuIcons {item.image=icon.image(size:16)};menu.addItem(item)
        }
        add(activityWindow?.isVisible == true ? "Hide Cache Activity" : "Show Cache Activity",.status){[weak self] in self?.toggleActivity()}
        menu.addItem(.separator())
        let desired:FinderOverlayCacheMode=current.cacheMode == .none ? .standard : .none
        add(desired == .none ? "Disable Status Cache" : "Enable Status Cache",.status){[weak self] in self?.setCacheMode(desired)}
        add("Exit",.remove){[weak self] in self?.stop()}
    }
    public func toggleActivity() {
        guard !retired,!stopping else{return}
        if activityWindow?.isVisible == true {activityWindow?.orderOut(nil);return}
        if activityWindow==nil {
            let window=NSWindow(contentRect:.init(x:0,y:0,width:720,height:370),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.title="TurtleGit Overlay Icon Server";window.isReleasedWhenClosed=false;window.contentMinSize = .init(width:480,height:240)
            let summary=NSTextField(labelWithString:"");summary.font = .systemFont(ofSize:12);summary.maximumNumberOfLines=3
            let text=NSTextView(frame:.init(x:0,y:0,width:688,height:280));text.isEditable=false;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textColor = .textColor;text.backgroundColor = .textBackgroundColor;text.isHorizontallyResizable=true
            text.minSize = .init(width:0,height:0);text.maxSize = .init(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);text.isVerticallyResizable=true
            text.textContainer?.widthTracksTextView=false;text.textContainer?.containerSize = .init(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            let scroll=NSScrollView();scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .bezelBorder
            let stack=NSStackView(views:[summary,scroll]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
            let view=NSView();view.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-16),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor)])
            window.contentView=view;window.center();activityWindow=window;summaryField=summary;textView=text
        }
        refresh();activityWindow?.makeKeyAndOrderFront(nil)
    }
    private func setCacheMode(_ mode:FinderOverlayCacheMode) {
        do {
            guard let overlaysURL else {throw FinderServiceAuthorizationFailure.invalidRequest}
            try FinderCacheTrayStatusPolicy.setCacheMode(mode,overlaysURL:overlaysURL);failure=nil;DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderStatusPolicyPreferences.notification),object:nil);notify()
        }catch{failure=error.localizedDescription;if activityWindow?.isVisible != true {toggleActivity()}}
        refresh()
    }
    public func beginStopping() {
        guard !retired,!stopping else{return};stopping=true;generation += 1;for item in menu.items{item.isEnabled=false};refresh()
    }
    private func stop() {
        guard !retired,!stopping else{return};beginStopping()
        stopTask=Task{[self] in await exitService();stopTask=nil;retire()}
    }
    public func retire() {
        guard !retired else{return};retired=true;generation += 1
        for observer in observers{DistributedNotificationCenter.default().removeObserver(observer)};observers=[]
        if let statusItem{NSStatusBar.system.removeStatusItem(statusItem)};statusItem=nil
        activityWindow?.close();activityWindow=nil;textView=nil;summaryField=nil;menu.removeAllItems()
    }
    @MainActor private final class Action:NSObject {
        var action:(()->Void)?
        init(_ action:@escaping ()->Void){self.action=action}
        @objc func activateCacheMenuItem(_ sender:NSMenuItem){let value=action;action=nil;value?()}
    }
}
