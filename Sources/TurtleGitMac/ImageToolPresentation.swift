// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import TurtleGitCore

@MainActor final class ImageToolMenuContext:ObservableObject {
    static let shared=ImageToolMenuContext()
    private weak var session:ImageToolLaunchSession?
    private var notifications:[AnyCancellable]=[]
    init(){
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.willCloseNotification,NSApplication.didUpdateNotification]{
            notifications.append(NotificationCenter.default.publisher(for:name).sink{[weak self] _ in Task{@MainActor in self?.refresh()}})
        }
    }
    @Published private(set) var canOpen=false
    @Published private(set) var canClose=false
    func install(_ value:ImageToolLaunchSession){session=value;refresh()}
    func refresh(){let current=session?.ownsCurrentFrame==true;canOpen=current && session?.canOpenImages==true;canClose=current && session?.canCloseWindow==true}
    func retire(_ value:ImageToolLaunchSession){if session === value{session=nil;canOpen=false;canClose=false}}
    func open(){refresh();guard canOpen else{return};session?.showOpenImages()}
    func close(){refresh();guard canClose else{return};session?.closeWindow()}
}
struct TurtleGitImageToolApp:App {
    @NSApplicationDelegateAdaptor(TurtleGitApplicationDelegate.self) private var applicationDelegate
    @StateObject private var context=ImageToolMenuContext.shared
    var body:some Scene {Settings{EmptyView()}.commands{ImageToolBaseCommands(context:context)}}
}
struct ImageToolBaseCommands:Commands {
    @ObservedObject var context:ImageToolMenuContext
    var body:some Commands {
        CommandGroup(replacing:.newItem){
            Button("Open…"){context.open()}.keyboardShortcut("o").disabled(!context.canOpen)
            Button("Close"){context.close()}.keyboardShortcut("w").disabled(!context.canClose)
        }
        CommandGroup(replacing:.appSettings){}
        CommandGroup(replacing:.appInfo){Button("About TurtleGitIDiff…"){TurtleGitAboutService.shared.show(.image)}}
        CommandGroup(replacing:.help){Button("TurtleGit Help"){TurtleGitHelp.showContext()}.keyboardShortcut("?",modifiers:.command)}
    }
}

enum ImageToolAuthorizationFailure:LocalizedError {
    case selection(URL,Bool),scope(URL,Bool)
    var errorDescription:String? {
        switch self {
        case let .selection(url,folder):return "Choose the requested "+(folder ? "folder":"file")+" to authorize TurtleGitIDiff: "+url.path
        case let .scope(url,folder):return "TurtleGitIDiff could not obtain access to the selected "+(folder ? "folder":"file")+": "+url.path
        }
    }
}
@MainActor final class ImageToolAuthorizationValidator:NSObject,NSOpenSavePanelDelegate {
    let requested:URL,folder:Bool
    init(requested:URL,folder:Bool){self.requested=requested;self.folder=folder}
    func panel(_ sender:Any,validate url:URL)throws {
        guard url.isFileURL,(folder || GitReferenceName.equal(url.standardizedFileURL.path,requested.standardizedFileURL.path)),RepositoryAccessLease.pathIsContained(requested,by:url) else{throw ImageToolAuthorizationFailure.selection(requested,folder)}
    }
}
