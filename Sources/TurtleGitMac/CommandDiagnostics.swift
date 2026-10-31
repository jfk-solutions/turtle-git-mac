// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import os
import TurtleGitCore

/// Explicit opt-in diagnostics go to this Mac's Console, never a report/upload.
@MainActor enum NativeCommandDiagnostics {
    private static let logger=Logger(subsystem:"org.turtlegit.macos",category:"CommandDiagnostics")
    static func configure(preferences:UserDefaults) {
        guard (preferences.object(forKey:"DebugOutputString") as? NSNumber)?.boolValue == true else {GitCommandDiagnostics.installSink(nil);return}
        let sinkLogger=logger
        GitCommandDiagnostics.installSink {event in sinkLogger.info("\(event.rendered,privacy:.public)")}
    }
    static func trace(_ event:String,arguments:[String],preferences:UserDefaults) {
        guard (preferences.object(forKey:"DebugOutputString") as? NSNumber)?.boolValue == true else{return}
        let value=event+" "+GitCommandDiagnostics.sanitizedArguments(arguments).joined(separator:" ")
        logger.info("\(String(value.prefix(4096)),privacy:.public)")
    }
}

private final class CommandDiagnosticWindow:NSWindow {
    override func cancelOperation(_ sender:Any?){performClose(sender)}
}

/// Acknowledgment owns one captured command; it grants no repository access.
@MainActor final class CommandDiagnosticPreviewController:NSWindowController,NSWindowDelegate {
    private var completion:((Bool)->Void)?
    private(set) var finished=false
    let commandText:String
    init(arguments:[String],completion:@escaping(Bool)->Void) {
        commandText=GitCommandDiagnostics.sanitizedArguments(arguments).enumerated().map{"[\($0.offset)] \($0.element)"}.joined(separator:"\n")
        self.completion=completion
        let window=CommandDiagnosticWindow(contentRect:.init(x:0,y:0,width:640,height:280),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title=NSLocalizedString("Command line",comment:"");window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        let root=NSView();window.contentView=root
        let text=NSTextView();text.isEditable=false;text.isSelectable=true;text.isRichText=false;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.string=commandText;text.textContainerInset = .init(width:8,height:8)
        text.setAccessibilityLabel(NSLocalizedString("Command line",comment:""))
        let scroll=NSScrollView();scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        text.isVerticallyResizable=true;text.autoresizingMask = [.width];text.textContainer?.widthTracksTextView=true
        let button=NSButton(title:NSLocalizedString("OK",comment:""),target:self,action:#selector(acknowledge));button.bezelStyle = .rounded;button.keyEquivalent="\r"
        for view in [scroll,button]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),scroll.topAnchor.constraint(equalTo:root.topAnchor,constant:16),scroll.bottomAnchor.constraint(equalTo:button.topAnchor,constant:-12),button.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),button.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-12),button.widthAnchor.constraint(greaterThanOrEqualToConstant:80)])
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func present(){window?.center();showWindow(nil);window?.makeKeyAndOrderFront(nil)}
    @objc func acknowledge(){finish(true)}
    func retire(){finished=true;completion=nil;close()}
    private func finish(_ accepted:Bool){guard !finished else{return};finished=true;let callback=completion;completion=nil;close();callback?(accepted)}
    func windowShouldClose(_ sender:NSWindow)->Bool {finish(true);return true}
    func windowWillClose(_ notification:Notification){finish(true)}
}
