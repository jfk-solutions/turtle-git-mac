// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum CloneCreateSourceVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Clone/Create timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    struct AccessibilitySnapshot {var help:[String]=[],diagnostics:[String]=[]}
    static func accessibilitySnapshot(_ roots:[Any])->AccessibilitySnapshot {
        var result=AccessibilitySnapshot(),seen=Set<ObjectIdentifier>(),remaining=4096
        func property(_ object:NSObject,_ name:String)->AnyObject? {
            let selector=NSSelectorFromString(name)
            guard object.responds(to:selector) else{return nil}
            return object.perform(selector)?.takeUnretainedValue()
        }
        func visit(_ value:Any,_ depth:Int) {
            guard depth<48,remaining>0 else{return}
            remaining -= 1
            let help:String?,role:String?,label:String?,children:[Any],navigation:[Any]
            if let element=value as? NSAccessibilityProtocol {
                guard seen.insert(ObjectIdentifier(element as AnyObject)).inserted else{return}
                help=element.accessibilityHelp();role=element.accessibilityRole()?.rawValue;label=element.accessibilityLabel()
                children=element.accessibilityChildren() ?? []
                // AppKit can return reparenting cell proxies despite this getter's
                // typed Swift [NSAccessibilityElement] import. Read its NSArray
                // through the public Objective-C selector to retain those nodes.
                navigation=(value as? NSObject).flatMap{property($0,"accessibilityChildrenInNavigationOrder") as? [Any]} ?? []
            } else if let object=value as? NSObject {
                guard seen.insert(ObjectIdentifier(object)).inserted else{return}
                help=property(object,"accessibilityHelp") as? String;role=property(object,"accessibilityRole") as? String;label=property(object,"accessibilityLabel") as? String
                children=property(object,"accessibilityChildren") as? [Any] ?? [];navigation=property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            } else {
                if result.diagnostics.count<200{result.diagnostics.append("Dropped public AX node type=\(type(of:value)) depth=\(depth)")}
                return
            }
            if let help,!help.isEmpty{result.help.append(help)}
            if result.diagnostics.count<200{result.diagnostics.append("\(type(of:value)): role=\(role ?? "nil") label=\((label ?? "nil").debugDescription) help=\((help ?? "nil").debugDescription) children=\(children.count) navigation=\(navigation.count)")}
            for child in children+navigation{visit(child,depth+1)}
        }
        for root in roots{visit(root,0)}
        return result
    }
    static func own(_ owner:NSWindowController){owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil)}
    static func capture(_ window:NSWindow?,_ name:String)async throws{
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_CLONE_CREATE_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*)else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance;defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture encoding failed")
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func finderInfo(_ folder:URL)->Data?{
        var buffer=[UInt8](repeating:0,count:32)
        let count=folder.path.withCString{path in "com.apple.FinderInfo".withCString{name in getxattr(path,name,&buffer,32,0,0)}}
        return count==32 ? Data(buffer):nil
    }
    static func customIcon(_ folder:URL)->Bool{guard let data=finderInfo(folder),data.count>=10 else{return false};return data[8]&4 != 0}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.CloneCreateSource."+UUID().uuidString,prefs:UserDefaults
        var owners:[NSWindowController]=[],clones:[CloneWindowModel]=[],release:[()->Void]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(false,forKey:"TGitAutoLoadSSHKey")}
        func directory(_ name:String)throws->URL{let value=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true);return value}
        func keep<T:NSWindowController>(_ owner:T)->T{owners.append(owner);own(owner);return owner}
        func clone(_ directory:URL?=nil)->CloneWindowController{let value=CloneWindowController(directory:directory ?? root,access:RepositoryAccessLease(url:root),preferences:prefs,executable:git,clipboardText:"");clones.append(value.model);return keep(value)}
        func source()async throws->GitRepository{
            let folder=try directory("source repository 雪"),repo=GitRepository(root:folder,executable:git)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Clone/Create QA"),("user.email","clone@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            try Data("source bytes\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"source")
            return repo
        }
        func cleanup()async{
            release.forEach{$0()};release=[];owners.reversed().forEach{$0.close()};clones.forEach{$0.invalidate()}
            for window in NSApp.windows{window.orderOut(nil);window.close()}
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
        func drained()->Bool{CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0 && CreateRepositoryWindowModel.activeOperations==0 && CreateRepositoryWindowController.activeReleases==0 && BareRepositoryResultSetup.activeOperations==0 && clones.allSatisfy{!$0.hasPendingWork}}
    }
    static func initRepository(_ c:Context,_ name:String,custom:Bool=false,failIcon:Bool=false)async throws->CreateRepositoryWindowController{
        let folder=try c.directory(name),owner=CreateRepositoryWindowController(folder:folder,access:RepositoryAccessLease(url:c.root),preferences:c.prefs)
        owner.model.executable=c.git;owner.model.bare=true
        if custom {try require(NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(for:.folder),forFile:folder.path,options:[]),"Could not establish private custom-icon fixture");try require(customIcon(folder),"Private custom icon lacks actual FinderInfo flag")}
        let before=finderInfo(folder);var writes=0,initialized=0,summary=""
        let setter=owner.model.bareResultSetup.setIcon
        owner.model.bareResultSetup.setIcon={image,target in writes += 1;return failIcon ? false:setter(image,target)}
        owner.model.onInitialized={_,_,bare,text in if bare{initialized += 1};summary=text}
        owner.presentQuestion={kind,_,_,reply in switch kind{case .warning:DispatchQueue.main.async{reply(.alertSecondButtonReturn)};default:DispatchQueue.main.async{reply(.alertFirstButtonReturn)}}}
        owner.model.prepare();_ = c.keep(owner);try await wait{owner.model.canEditForm};owner.model.initialize();try await wait{owner.model.completed && !owner.model.hasPendingWork}
        let repo=GitRepository(root:folder,executable:c.git);try require(try await repo.isBare(),"Actual Init did not create bare repository");try require(initialized==1,"Verified bare Init callback missing")
        if custom {try require(writes==0 && finderInfo(folder)==before && customIcon(folder),"Init replaced existing custom folder artwork")}
        else if failIcon {try require(writes==1 && owner.model.error==nil && owner.model.setupWarning != nil && owner.model.setupWarning.map{summary.contains($0)}==true,"Metadata failure was reported as failed Git initialization")}
        else {try require(writes==1 && customIcon(folder),"Successful bare Init did not install actual native custom icon")}
        return owner
    }
    static func cloneModel(_ c:Context,source:GitRepository,destination:URL,progress:Bool,failIcon:Bool=false)async throws->(CloneWindowController?,CloneWindowModel){
        let owner:CloneWindowController?,model:CloneWindowModel
        if progress {let controller=c.clone();owner=controller;model=controller.model}
        else {owner=nil;model=CloneWindowModel(directory:c.root,access:RepositoryAccessLease(url:c.root),preferences:c.prefs,executable:c.git,clipboardText:"");c.clones.append(model)}
        model.source=source.root.path;model.directory=destination.path;model.bare=true
        if failIcon {model.bareResultSetup.setIcon={_,_ in false}}
        var capturedWarnings:[String]=[]
        model.clone()
        if progress {try await wait{model.progress != nil && model.progress?.busy==false && model.progress?.hasPendingWork==false}}
        else {try await wait{model.completed != nil && !model.hasPendingWork}}
        if let result=model.progress {capturedWarnings=result.warnings;try require(result.success && result.commandSucceeded,"Bare Clone progress relabelled successful Git command: "+result.output);if failIcon{try require(!result.warnings.isEmpty && result.statusText.contains("warning"),"Bare metadata warning missing from successful Clone progress")};owner?.progressController?.model.close();try await wait{model.completed != nil && !model.hasPendingWork}}
        let repo=GitRepository(root:destination,executable:c.git);try require(try await repo.isBare(),"Actual Clone is not bare")
        let expected=try await source.run(["rev-parse","HEAD"]).stdout,actual=try await repo.run(["rev-parse","HEAD"]).stdout;try require(actual==expected,"Bare Clone changed source commit")
        if failIcon {
            let visibleWarning=progress ? !capturedWarnings.isEmpty && capturedWarnings.allSatisfy{model.output?.contains($0)==true}:model.completionWarning != nil
            try require(model.error==nil && visibleWarning,"Direct/result metadata failure became Git failure or lost its captured warning summary")
        }
        else{try require(customIcon(destination),"Bare Clone did not install actual native icon metadata")}
        return(owner,model)
    }
    static func creation(_ c:Context)async throws{
        _=try await initRepository(c,"fresh-bare.git");_=try await initRepository(c,"custom-bare.git",custom:true);_=try await initRepository(c,"metadata-failure.git",failIcon:true)
        let source=try await c.source(),before=try await source.run(["rev-parse","HEAD"]).stdout
        _=try await cloneModel(c,source:source,destination:c.root.appendingPathComponent("direct-bare.git"),progress:false)
        _=try await cloneModel(c,source:source,destination:c.root.appendingPathComponent("progress-bare.git"),progress:true)
        _=try await cloneModel(c,source:source,destination:c.root.appendingPathComponent("warning-bare.git"),progress:true,failIcon:true)
        _=try await cloneModel(c,source:source,destination:c.root.appendingPathComponent("direct-warning.git"),progress:false,failIcon:true)
        // An existing destination causes the first actual Git attempt to fail;
        // repairing it and choosing Retry must perform exactly one result setup.
        let destination=try c.directory("retry-bare.git");try Data("obstruction".utf8).write(to:destination.appendingPathComponent("existing"))
        // Preflight correctly refuses a nonempty destination, so start a failed
        // command with a private wrapper after otherwise-valid form validation.
        try FileManager.default.removeItem(at:destination)
        let wrapper=c.root.appendingPathComponent("retry-git"),release=URL(fileURLWithPath:wrapper.path+".allow")
        func q(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        try Data(("#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = clone ] && [ ! -f "+q(release.path)+" ]; then echo private-clone-refused >&2; exit 47; fi; done\nexec "+q(c.git.path)+" \"$@\"\n").utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let owner=c.keep(CloneWindowController(directory:c.root,access:RepositoryAccessLease(url:c.root),preferences:c.prefs,executable:wrapper,clipboardText:"")),model=owner.model;c.clones.append(model);model.source=source.root.path;model.directory=destination.path;model.bare=true
        var setups=0;let prepare=model.bareResultSetup.prepare;model.bareResultSetup.prepare={folder,token in setups += 1;try await prepare(folder,token)}
        model.clone();try await wait{model.progress != nil && model.progress?.busy==false}
        let result=try unwrap(model.progress,"Actual failed Clone progress missing");try require(!result.success && setups==0,"Failed Clone performed bare result setup")
        try Data().write(to:release);result.perform(.retry);try await wait{!result.busy && result.success}
        try require(setups==1 && customIcon(destination),"Retry did not install one captured bare setup receipt")
        owner.progressController?.model.close();try await wait{!model.hasPendingWork}
        let after=try await source.run(["rev-parse","HEAD"]).stdout;try require(after==before,"Creation workflows modified source repository")
    }
    static func navigation(_ c:Context)async throws{
        let source=try await c.source(),owner=c.clone(),model=owner.model
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.contains{$0.identifier?.rawValue=="Clone source navigation"}}
        let control=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.first{$0.identifier?.rawValue=="Clone source navigation"},"Actual Clone source split missing")
        var panels=0,opened:[URL]=[],revealed:[URL]=[]
        model.selectedPanelURL={_ in source.root};model.presentOpenPanel={_,_,reply in panels += 1;DispatchQueue.main.async{reply(.OK)}}
        model.openSourceURL={url,token in try token.check();opened.append(url);return true};model.revealSourceURL={url,token in try token.check();revealed.append(url);return true}
        func phase(_ name:String,_ predicate:()->Bool)async throws {
            do{try await wait(predicate)}catch{throw Failure(description:"Navigation \(name): source=\(model.source.debugDescription) native=\(views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Repository URL"}?.stringValue.debugDescription ?? "nil") enabled=\(control.isEnabled) accepts=\(model.canNavigateSource) pending=\(model.hasPendingWork) panels=\(panels) opened=\(opened.count) revealed=\(revealed.count) error=\(model.error ?? "nil"); \(error)")}
        }
        func ready()async throws {
            try await phase("native source readiness") {control.isEnabled && model.canNavigateSource && views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Repository URL"}?.stringValue==model.source}
        }
        func menu()async throws->NSMenu{try await ready();let value=try unwrap(control.menu(forSegment:1),"Source dropdown missing");value.delegate?.menuWillOpen?(value);try require(value.items.allSatisfy{$0.isEnabled},"Fresh source menu disabled after native readiness");return value}
        let browse=try await menu();try require(browse.items.map(\.title)==["Browse…","Open"] && browse.items.allSatisfy{$0.image != nil},"Source split order/icons differ")
        browse.performActionForItem(at:0);try await wait{!model.hasPendingWork && model.source==source.root.path}
        try require(panels==1 && model.sourceBrowseAction == .local && c.prefs.integer(forKey:"CloneBrowse")==0,"Local Browse did not accept selected authority/persist choice")
        model.source="https://example.invalid/repository%20name.git"
        let open=try await menu();open.performActionForItem(at:1);try await phase("Open remote"){!model.hasPendingWork && opened.count==1}
        try require(opened[0].absoluteString==model.source && model.sourceBrowseAction == .open && c.prefs.integer(forKey:"CloneBrowse")==1,"Open did not capture exact URL/sticky setting")
        try await wait{control.label(forSegment:0)=="Open"}
        model.source=source.root.absoluteString;try await ready();control.selectedSegment=0;control.performClick(nil);try await phase("sticky local Open"){!model.hasPendingWork && revealed.count==1}
        try require(revealed[0].path==source.root.path,"Sticky primary did not reveal local file URL")
        model.source=source.root.appendingPathComponent("missing/child").path;model.navigateSource(.open,receipt:model.navigationReceipt);try await wait{!model.hasPendingWork && revealed.count==2}
        try require(revealed[1].path==source.root.path,"Explore did not choose nearest existing source ancestor")
        model.directory=c.root.appendingPathComponent("relative-clone").path;model.source=source.root.lastPathComponent
        model.navigateSource(.open,receipt:model.navigationReceipt);try await wait{!model.hasPendingWork && revealed.count==3}
        try require(revealed[2].path==source.root.path,"Relative local source used process directory instead of captured clone destination context")
        let missing=source.root.appendingPathComponent("missing/original");model.source=missing.absoluteString
        model.revealSourceURL={url,token in try token.check();revealed.append(url);return false}
        model.navigateSource(.open,receipt:model.navigationReceipt);try await wait{!model.hasPendingWork && opened.count==2}
        try require(revealed.last?.path==source.root.path && opened.last?.path==missing.path,"Local navigation fallback lost captured original URL or nearest folder")
        let calls=opened.count
        let stale=try await menu();model.source="https://example.invalid/changed.git";stale.performActionForItem(at:1);for _ in 0..<5{await Task.yield()};try require(opened.count==calls,"Retained menu retargeted changed source draft")
        let quit=try await menu();model.confirmingQuit=true;model.confirmingQuit=false;quit.performActionForItem(at:1);for _ in 0..<5{await Task.yield()};try require(opened.count==calls,"Quit transition revived retained source menu")
        let closed=try await menu();owner.close();closed.performActionForItem(at:1);for _ in 0..<5{await Task.yield()};try require(opened.count==calls,"Retired source control opened URL")
        let reopened=c.clone();try require(reopened.model.sourceBrowseAction == .open,"New owner lost source split choice")
    }
    static func forms(_ c:Context,verifyAccessibility:Bool=false)async throws{
        let owner=c.clone(),model=owner.model
        model.source="https://example.invalid/"+String(repeating:"long-repository-component/",count:12)+"source.git";model.directory=c.root.appendingPathComponent(String(repeating:"long-destination-",count:9)).path
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.contains{$0.accessibilityLabel()=="Repository URL"}}
        let source=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Repository URL"},"Native repository URL field missing")
        let directory=try unwrap(views(owner.window?.contentView).compactMap{$0 as? PathEntryField.Field}.first{$0.accessibilityLabel()=="Destination directory"},"Native destination field missing")
        try await wait{source.toolTip==model.source && directory.stringValue==model.directory}
        try require(source.isEnabled && directory.isEnabled,"Editable Clone fields disabled")
        let window=try unwrap(owner.window,"Clone window missing"),content=try unwrap(window.contentView,"Clone content missing")
        content.layoutSubtreeIfNeeded()
        let minimum=window.contentMinSize
        try require(minimum.width>=779 && minimum.height>=479,"Clone minimum content bounds do not preserve complete source form")
        for field in [source as NSTextField,directory] {
            let rect=field.convert(field.bounds,to:content)
            try require(rect.width>=120 && rect.height>=18 && content.bounds.insetBy(dx:-1,dy:-1).contains(rect),"Long native Clone field escaped complete content bounds: \(rect)")
        }
        var accessibility=AccessibilitySnapshot(),help:[String]=[]
        for _ in 0..<(verifyAccessibility ? 100:0) {
            content.layoutSubtreeIfNeeded();window.displayIfNeeded()
            accessibility=accessibilitySnapshot([window]+views(content));help=accessibility.help+views(content).compactMap{$0.toolTip}
            if help.contains(where:{$0.contains("shallow clone")}) && help.contains(where:{$0.contains("without a working tree")}){break}
            try await Task.sleep(nanoseconds:10_000_000)
        }

        let native=try unwrap(owner.window as? ReferenceFormNativeWindow,"Clone command window missing"),router=try unwrap((owner.window as? ReferenceFormNativeWindow)?.formCommands,"Clone form command router missing"),privateMenu=NSMenu()
        router.keyWindow={ [weak native] in native};router.applicationMenu={privateMenu};router.install()
        try await wait{router.menu?.items.contains{$0.identifier?.rawValue=="TurtleGit.ReferenceForm.cloneURL" && $0.isEnabled}==true}
        func event(_ text:String,_ flags:NSEvent.ModifierFlags)throws->NSEvent{try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:native.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:32),"Native Clone key event missing")}
        try require(native.performKeyEquivalent(with:event("u",[.command,.option])),"Clone URL command not routed")
        try await wait{source.currentEditor() != nil && native.firstResponder === source.currentEditor()}
        try require(!router.performKeyEquivalent(try event("u",.option)),"Source mnemonic intercepted Option text composition")
        let captured=model.field(\.directory,context:model.formContext),before=model.directory
        model.confirmingQuit=true;captured.wrappedValue=c.root.appendingPathComponent("late destination").path;try require(model.directory==before,"Quit accepted stale Clone field binding");model.confirmingQuit=false
        captured.wrappedValue=c.root.appendingPathComponent("revived destination").path;try require(model.directory==before,"Old Clone field binding revived after Quit")
        try await wait{source.isEnabled && directory.isEnabled};try await capture(owner.window,"clone-source-long-fields")
        let folder=try c.directory("form-init"),initOwner=CreateRepositoryWindowController(folder:folder,access:RepositoryAccessLease(url:c.root),preferences:c.prefs);initOwner.model.executable=c.git;initOwner.model.prepare();_=c.keep(initOwner)
        try await wait{initOwner.model.canEditForm};let old=initOwner.model.bareBinding(initOwner.model.formContext);initOwner.model.confirmingQuit=true;old.wrappedValue=true;initOwner.model.confirmingQuit=false;old.wrappedValue=true
        try require(!initOwner.model.bare,"Stale Init checkbox mutated captured form after Quit")
        let initWindow=try unwrap(initOwner.window,"Init window missing")
        initWindow.contentView?.layoutSubtreeIfNeeded()
        let initSize=initWindow.contentRect(forFrameRect:initWindow.frame).size
        try require(abs(initSize.width-600)<1 && abs(initSize.height-190)<1,"Init confirmation grew beyond compact source layout: \(initSize)")
        try await capture(initWindow,"create-repository-form")
        // Retain this separate acceptance gate: this offscreen receiver currently
        // exposes AppKit peers but no SwiftUI virtual accessibility children.
        if verifyAccessibility {
        try require(help.contains{$0.contains("shallow clone")} && help.contains{$0.contains("without a working tree")},"Actual Clone options lack source shallow/bare help text; help=\(help); hierarchy="+accessibility.diagnostics.joined(separator:" | "))
        }
    }
    static func ownership(_ c:Context)async throws{
        let owner=c.clone(),model=owner.model;model.source="https://example.invalid/held.git"
        var open:CheckedContinuation<Bool,Error>?,token:OperationCancellation?,closed=false
        model.openSourceURL={_,request in token=request;return try await withCheckedThrowingContinuation{open=$0}}
        c.release.append{if let pending=open{open=nil;pending.resume(returning:true)}}
        owner.onClosed={closed=true};model.navigateSource(.open,receipt:model.navigationReceipt);try await wait{open != nil}
        owner.close();try require(token?.isCancelled==true && !closed && model.hasPendingWork,"Closing Clone released live source navigation")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held source navigation escaped Quit")
        open?.resume(returning:true);open=nil;try await wait{closed && !model.hasPendingWork};try require(model.error==nil,"Late navigation published error into retired owner")
        let picker=c.clone();picker.model.source="captured local source"
        var panelReply:((NSApplication.ModalResponse)->Void)?
        picker.model.selectedPanelURL={_ in c.root};picker.model.presentOpenPanel={_,_,reply in panelReply=reply}
        c.release.append{panelReply?(.cancel);panelReply=nil}
        picker.model.navigateSource(.local,receipt:picker.model.navigationReceipt);try await wait{picker.model.openPanel != nil && panelReply != nil}
        picker.model.confirmingQuit=true;picker.model.confirmingQuit=false
        panelReply?(.OK);panelReply=nil;try await wait{!picker.model.hasPendingWork}
        try require(picker.model.source=="captured local source","Late local picker accepted authority after Quit retired its captured form")
        let folder=try c.directory("held-init.git"),initial=CreateRepositoryWindowController(folder:folder,access:RepositoryAccessLease(url:c.root),preferences:c.prefs);initial.model.executable=c.git;initial.model.bare=true
        var prepare:CheckedContinuation<Void,Error>?,setupToken:OperationCancellation?,writes=0,adoptions=0,initClosed=false
        initial.model.bareResultSetup.prepare={_,request in setupToken=request;try await withCheckedThrowingContinuation{prepare=$0}}
        initial.model.bareResultSetup.setIcon={_,_ in writes += 1;return true};initial.model.onInitialized={_,_,_,_ in adoptions += 1}
        c.release.append{if let pending=prepare{prepare=nil;pending.resume()}}
        initial.model.prepare();_=c.keep(initial);initial.onClosed={initClosed=true};initial.model.initialize();try await wait{prepare != nil}
        let created=GitRepository(root:folder,executable:c.git);try require(try await created.isBare(),"Held setup did not follow actual successful Init")
        initial.close();try require(setupToken?.isCancelled==true && !initClosed && initial.model.hasPendingWork && BareRepositoryResultSetup.activeOperations>0,"Init owner released held result setup")
        prepare?.resume();prepare=nil;try await wait{initClosed && !initial.model.hasPendingWork};try require(writes==0 && adoptions==0,"Retired Init applied late icon/adoption")
        let source=try await c.source(),cloning=c.clone(),destination=c.root.appendingPathComponent("held-clone.git");cloning.model.source=source.root.path;cloning.model.directory=destination.path;cloning.model.bare=true
        var clonePrepare:CheckedContinuation<Void,Error>?,cloneToken:OperationCancellation?,cloneClosed=false,cloneWrites=0
        cloning.model.bareResultSetup.prepare={_,request in cloneToken=request;try await withCheckedThrowingContinuation{clonePrepare=$0}}
        cloning.model.bareResultSetup.setIcon={_,_ in cloneWrites += 1;return true}
        c.release.append{if let pending=clonePrepare{clonePrepare=nil;pending.resume()}}
        cloning.onClosed={cloneClosed=true};cloning.model.clone();try await wait{clonePrepare != nil}
        let result=try unwrap(cloning.model.progress,"Held Clone result missing");try require(result.commandSucceeded && result.commandCompleted && result.busy,"Held setup lost actual successful Git receipt")
        cloning.close();try require(cloneToken?.isCancelled==true && !cloneClosed && result.hasPendingWork,"Clone released held result setup")
        clonePrepare?.resume();clonePrepare=nil;try await wait{cloneClosed && !result.hasPendingWork};try require(result.commandSucceeded && cloneWrites==0,"Closing Clone rewrote successful Git status or applied late metadata")
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited);let context=Context(),which=CommandLine.arguments[3]
        do{switch which{case "navigation":try await navigation(context);case "forms":try await forms(context);case "accessibility":try await forms(context,verifyAccessibility:true);case "creation":try await creation(context);default:try await ownership(context)};await context.cleanup();try require(context.drained(),"Clone/Create owned work or native releases did not drain");print("PASS: Clone/Create "+which)}catch{await context.cleanup();fputs("Clone/Create failed: \(error)\n",stderr);exit(1)}
    }
}
@main struct CloneCreateSourceMain{static func main()async{await CloneCreateSourceVerification.main()}}
