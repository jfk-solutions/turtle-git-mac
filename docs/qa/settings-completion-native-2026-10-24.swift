// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore
extension NSWindow {
 @objc func settingsCompletionFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
 @objc func settingsCompletionOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=SettingsCompletionVerification.captureWindow === self ? 1:0;settingsCompletionOrder(mode,relativeTo:number)}
}
@MainActor @main struct SettingsCompletionVerification {
 static weak var captureWindow:NSWindow?
 final class RefusingDelegate:NSObject,NSWindowDelegate{var allow=false,calls=0,closed=0;func windowShouldClose(_ sender:NSWindow)->Bool{calls += 1;return allow};func windowWillClose(_ notification:Notification){closed += 1}}
 struct Failure:Error,CustomStringConvertible{let description:String}
 static func require(_ value:Bool,_ message:String,line:UInt = #line)throws{if !value{throw Failure(description:"Settings completion \(line): "+message)}}
 static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Settings completion timeout \(line)")}
 static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
 static func button(_ title:String,_ owner:SettingsSheetController)throws->NSButton{guard let button=views(owner.window?.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title})else{throw Failure(description:"Missing real footer "+title)};return button}
 static func click(_ title:String,_ owner:SettingsSheetController)async throws{let b=try button(title,owner);try await wait{b.isEnabled};try require(b.isEnabled,"Footer disabled: "+title);try require(NSApp.sendAction(b.action!,to:b.target,from:b),"Footer action not dispatched")}
 static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
 static func drained()->Bool{GitConfigurationSettingsModel.activeReads==0 && GitConfigurationSettingsModel.activeSaves==0 && GitConfigurationSettingsModel.activeFolderChoosers==0 && GitConfigurationSettingsModel.activeSheetReleases==0 && CredentialSettingsModel.activeReads==0 && CredentialSettingsModel.activeSaves==0 && CredentialSettingsModel.activeSelections==0 && CredentialSettingsModel.activeSheetReleases==0 && NetworkSettingsModel.activeReads==0 && NetworkSettingsModel.activeSaves==0 && NetworkSettingsModel.activeSSHChoosers==0 && NetworkSettingsModel.activeSheetReleases==0 && GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0 && ToolApplicationChooser.activeChoosers==0 && MergeEditorSettingsModel.activeProfileEditors==0 && HookSettingsModel.activeReads==0 && HookSettingsModel.activeSaves==0 && HookConfigurationController.activeReleases==0 && HookConfigurationController.activeChoosers==0 && EmailSettingsModel.activeOperations==0 && EmailSettingsModel.activeCredentialEditors==0 && RemoteSettingsWindowModel.activeOperations==0 && RemoteSettingsWindowModel.activeRetirements==0 && SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0 && SettingsSheetController.activeSheets==0}
 @MainActor final class Context {
  let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
  let suite="TurtleGit.SettingsCompletion."+UUID().uuidString,prefs:UserDefaults
  var root:URL{base.appendingPathComponent("repository")};var wrapper:URL{base.appendingPathComponent("settings-git")};var hold:URL{base.appendingPathComponent("hold")};var started:URL{base.appendingPathComponent("started")};var release:URL{base.appendingPathComponent("release")}
  var repo:GitRepository!,workspace:RepositoryModel!,host:NSWindow!,owners:[SettingsSheetController]=[],results:[ObjectIdentifier:[Bool]]=[:],releases:[()->Void]=[],managers:[FinderWatchManager]=[]
  init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"HintHierarchicalConfig")}
  func prepare()async throws{
   try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
   let plain=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
   _=try await plain.run(["init","--template=","-b","main"])
   for(k,v)in[("user.name","Settings QA"),("user.email","settings@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await plain.run(["config",k,v])}
   try Data("unchanged\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await plain.stage(["."]);_=try await plain.commit(message:"base")
   for name in ["origin","backup"]{_=try await plain.run(["remote","add",name,base.appendingPathComponent(name+".git").path])}
   let resource=base.appendingPathComponent("owned-resource");try Data().write(to:resource)
   let script="""
   #!/bin/sh
   exec 9< \(quote(resource.path))
   match=false
   for word in "$@";do case "$word" in *svn-remote*) match=true ;; esac;done
   if test "$match" = true && test -f \(quote(hold.path));then : > \(quote(started.path));while ! test -f \(quote(release.path));do /bin/sleep .02;done;fi
   exec \(quote(git.path)) "$@"
   """
   try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
   repo=GitRepository(root:root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
   workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.root=root;workspace.settingsContextOverride=(repo,RepositoryAccessLease(url:root),true)
   host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil)
  }
  func open(_ page:SettingsPageID = .remote)async throws->SettingsSheetController{
   let owner=SettingsSheetController(workspace:workspace,preferences:prefs,initialPage:page,title:"Settings QA");owners.append(owner);let id=ObjectIdentifier(owner);results[id]=[];owner.onClosed={ [weak self] result in self?.results[id,default:[]].append(result)};owner.window?.alphaValue=0;owner.presentSheet(for:host)
   try await wait{owner.navigation.selected==page && owner.navigation.canDismiss && (try? button("Cancel",owner).isEnabled)==true && (page != .remote || owner.navigation.remote != nil)};return owner
  }
  func remote(_ owner:SettingsSheetController)async throws->RemoteSettingsWindowModel{guard let remote=owner.navigation.remote else{throw Failure(description:"Remote page not realized")};try await wait{!remote.busy && !remote.hasPendingWork};return remote}
  func closed(_ owner:SettingsSheetController,normal:Bool=true)async throws{try await wait{self.results[ObjectIdentifier(owner)]?.count==1 && owner.window?.sheetParent==nil && self.host.attachedSheet==nil};try require(results[ObjectIdentifier(owner)]==[normal],"Settings completion Bool/exactly-once semantics changed")}
  func clean()async{try? Data().write(to:release);let unblock=releases;releases=[];unblock.forEach{$0()};for owner in owners.reversed(){owner.retire()};for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()};workspace?.stopMonitoringForTermination();for manager in managers{await manager.shutdown()};for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
 }
 static func close(_ c:Context)async throws{
  let before=try Data(contentsOf:c.root.appendingPathComponent(".git/config"))
  let cached=try await c.open();_=try await c.remote(cached);let retiredTable=views(cached.window?.contentView).compactMap{$0 as? NSTableView}.first{$0.identifier?.rawValue=="RemoteSettings.Remotes"}!;cached.navigation.requestCommandPage(.git);try await wait{cached.navigation.selected == .git && cached.navigation.canDismiss};try await click("Cancel",cached);try await c.closed(cached);try require(retiredTable.dataSource==nil && retiredTable.delegate==nil && !retiredTable.isEnabled && retiredTable.numberOfRows==0,"Retired Remote table retained an active source/delegate")
  let dirty=try await c.open(),remote=try await c.remote(dirty);remote.edit(.url){$0.url="private-discarded-url"};try await wait{!remote.hasPendingWork};try require(dirty.navigation.transaction.modified,"Remote draft was not registered");try await click("Cancel",dirty);try await c.closed(dirty)
  try require(try Data(contentsOf:c.root.appendingPathComponent(".git/config"))==before,"Cancel persisted Git configuration")
  let escape=try await c.open();_=try await c.remote(escape);let b=try button("Cancel",escape);try require(b.keyEquivalent=="\u{1b}","Cancel lost Escape binding");let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:escape.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!;try require(b.performKeyEquivalent(with:key),"Native Escape action was refused");try await c.closed(escape)
  let titlebar=try await c.open();titlebar.window?.performClose(nil);try await c.closed(titlebar)
 }
 static func apply(_ c:Context)async throws{
  let owner=try await c.open(),remote=try await c.remote(owner)
  remote.select(GitReferenceName("origin"));try await wait{!remote.busy && !remote.hasPendingWork}
  let saved=c.base.appendingPathComponent("applied.git").path;remote.edit(.url){$0.url=saved};try await wait{!remote.hasPendingWork};try await click("Apply",owner);try await wait{!owner.navigation.transaction.busy && !remote.busy && !remote.hasPendingWork}
  let actual=try await c.repo.run(["config","remote.origin.url"]).text.trimmingCharacters(in:.newlines);try require(actual==saved && c.results[ObjectIdentifier(owner)]==[] && owner.window?.sheetParent===c.host,"Apply did not save/stay open")
  var dirty=true,valid=false,succeed=false,cancelled=0
  owner.navigation.transaction.register("completion-fixture",participant:.init(page:.git,modified:{dirty},validate:{valid ? nil:"PRIVATE VALIDATION FAILURE"},apply:{if succeed{dirty=false};return succeed},cancel:{cancelled += 1;dirty=false}))
  try await click("OK",owner);try await wait{!owner.navigation.transaction.busy};try require(owner.navigation.transaction.error?.contains("PRIVATE VALIDATION FAILURE")==true && owner.window?.sheetParent===c.host,"Validation closed Settings")
  valid=true;owner.navigation.transaction.notify();try await wait{owner.navigation.canDismiss && (try? button("OK",owner).isEnabled)==true};try await click("OK",owner);try await wait{!owner.navigation.transaction.busy};try require(owner.navigation.transaction.error != nil && dirty && owner.window?.sheetParent===c.host,"Failed Apply closed/accepted draft")
  succeed=true;owner.navigation.transaction.notify();try await wait{owner.navigation.canDismiss && (try? button("OK",owner).isEnabled)==true};try await click("OK",owner);try await c.closed(owner);try require(!dirty && cancelled<=1,"Successful OK did not settle once")
 }
 static func ownership(_ c:Context)async throws{
  let owner=try await c.open(),remote=try await c.remote(owner)
  let child=NSWindow(contentRect:.init(x:-24000,y:-24000,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false);child.isReleasedWhenClosed=false;child.alphaValue=0;owner.window!.beginSheet(child,completionHandler:nil)
  try await wait{!(try! button("Cancel",owner)).isEnabled};owner.window?.performClose(nil);try require(c.results[ObjectIdentifier(owner)]==[],"Child sheet bypassed close guard");owner.window!.endSheet(child);child.close();try await wait{owner.navigation.canDismiss && (try! button("Cancel",owner)).isEnabled}
  try Data().write(to:c.hold);remote.edit(.url){$0.url="pending-collision"};try await wait{FileManager.default.fileExists(atPath:c.started.path) && remote.hasPendingWork}
  let cancel=try button("Cancel",owner);try await wait{!cancel.isEnabled};owner.window?.performClose(nil)
  try require(c.results[ObjectIdentifier(owner)]==[] && owner.window?.sheetParent===c.host,"Pending Git read bypassed close guard")
  try Data().write(to:c.release);try await wait{!remote.hasPendingWork && owner.navigation.canDismiss};try await click("Cancel",owner);try await c.closed(owner)
  try? FileManager.default.removeItem(at:c.hold)
  let retired=try await c.open();try await click("Cancel",retired);try require(retired.navigation.completionPending,"Cancel did not own its completion intent");retired.navigation.requestCommandPage(.blame);try require(retired.navigation.selected == .remote,"Pending completion replaced the accepted page");retired.retire();retired.retire();try await c.closed(retired,normal:false)
  let replacement=try await c.open(.git);try require(c.results[ObjectIdentifier(replacement)]==[] && replacement.window?.sheetParent===c.host,"Old completion closed replacement owner");try await click("Cancel",replacement);try await c.closed(replacement)
  let changed=try await c.open(.git);var contextFinish:CheckedContinuation<Bool,Never>?,contextEntered=false,oldDirty=true
  changed.navigation.transaction.register("context-participant",participant:.init(page:.git,modified:{oldDirty},validate:{nil},apply:{contextEntered=true;let result=await withCheckedContinuation{contextFinish=$0};oldDirty=false;return result},cancel:{}))
  c.releases.append{if let reply=contextFinish{contextFinish=nil;reply.resume(returning:false)}}
  try await click("OK",changed);try await wait{contextEntered}
  changed.navigation.transaction.unregister("context-participant")
  changed.navigation.transaction.register("context-participant",participant:.init(page:.git,modified:{false},validate:{nil},apply:{true},cancel:{}))
  contextFinish?.resume(returning:true);contextFinish=nil;try await wait{!changed.navigation.transaction.busy}
  try require(changed.navigation.transaction.error?.contains("context changed")==true && c.results[ObjectIdentifier(changed)]==[] && changed.window?.sheetParent===c.host,"Stale async Apply closed replacement context")
  try await click("Cancel",changed);try await c.closed(changed)
  let delegate=RefusingDelegate(),native=NSWindow(contentRect:.init(x:-24000,y:-24000,width:1040,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  native.isReleasedWhenClosed=false;native.alphaValue=0;native.delegate=delegate
  let nav=SettingsNavigationController(workspace:c.workspace,appearance:AppAppearance(preferences:c.prefs),preferences:c.prefs,initialPage:.remote);native.contentViewController=nav;native.orderFront(nil)
  defer{nav.invalidate();native.delegate=nil;native.close()}
  try await wait{nav.remote != nil && nav.canDismiss};let old=nav.remote!;old.edit(.url){$0.url="delegate-preserved-draft"};try await wait{!old.hasPendingWork && nav.canDismiss}
  let footer=views(nav.view).compactMap{$0 as? NSButton}.first{$0.title=="Cancel"}!
  try require(NSApp.sendAction(footer.action!,to:footer.target,from:footer),"Delegate Cancel was not dispatched")
  try require(!nav.completionPending && old.draft.url=="delegate-preserved-draft" && nav.transaction.modified && delegate.calls==1,"Refused Cancel discarded Remote draft")
  delegate.allow=true;try require(NSApp.sendAction(footer.action!,to:footer.target,from:footer),"Accepted delegate Cancel was not dispatched");delegate.allow=false
  try await wait{!nav.completionPending && nav.remote != nil && nav.remote !== old && nav.canDismiss}
  try require(delegate.closed==0 && delegate.calls==3,"Final delegate refusal repeated or closed the owner")
  nav.remote!.edit(.url){$0.url="continued-editing"};try await wait{!nav.remote!.hasPendingWork};try require(nav.transaction.modified && nav.remote!.draft.url=="continued-editing","Refused completion retained terminal Remote model")
  nav.invalidate();native.delegate=nil;native.close()
  let pending=try await c.open(.git);var finish:CheckedContinuation<Bool,Never>?,entered=false
  pending.navigation.transaction.register("held-apply",participant:.init(page:.git,modified:{true},validate:{nil},apply:{entered=true;return await withCheckedContinuation{finish=$0}},cancel:{}))
  c.releases.append{if let reply=finish{finish=nil;reply.resume(returning:false)}}
  try await click("OK",pending);try await wait{entered};pending.retire();finish?.resume(returning:true);finish=nil;try await c.closed(pending,normal:false)
  try require(c.results[ObjectIdentifier(pending)]==[false],"Retired transaction emitted a late normal completion")
 }
 static func watchOwnership(_ c:Context)async throws{
  let hold=c.base.appendingPathComponent("watch-hold"),started=c.base.appendingPathComponent("watch-started"),release=c.base.appendingPathComponent("watch-release")
  let script="""
  #!/bin/sh
  match=false
  for word in "$@";do if test "$word" = --show-toplevel;then match=true;fi;done
  if test "$match" = true && test -f \(quote(hold.path));then : > \(quote(started.path));while ! test -f \(quote(release.path));do /bin/sleep .02;done;fi
  exec \(quote(c.git.path)) "$@"
  """
  try Data(script.utf8).write(to:c.wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:c.wrapper.path)
  c.releases.append{try? Data().write(to:release)}
  let permissions=try RepositoryAccessStore(storageURL:c.base.appendingPathComponent("private-watch-permissions.json"))
  let manager=FinderWatchManager(permissions:permissions,cache:nil,requireScope:false,repositoryFactory:{url in GitRepository(root:url,executable:c.wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))},volumeNotificationCenter:NotificationCenter(),notify:{})
  c.managers.append(manager)
  c.workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,finderWatches:manager);c.workspace.root=c.root;c.workspace.settingsContextOverride=(c.repo,RepositoryAccessLease(url:c.root),true)
  let remoteOwner=try await c.open(),remote=try await c.remote(remoteOwner)
  remote.select(GitReferenceName("origin"));try await wait{!remote.busy && !remote.hasPendingWork}
  try Data().write(to:hold)
  let external=Task{await manager.add(c.root)}
  try await wait{manager.busy && FileManager.default.fileExists(atPath:started.path)}
  try require(remoteOwner.navigation.canDismiss,"Unrelated watch registration blocked Remote Settings dismissal")
  try await click("Cancel",remoteOwner);try await c.closed(remoteOwner)
  try require(manager.busy,"Closing Settings canceled an application-owned registration")
  try Data().write(to:release);await external.value
  try require(!manager.busy,"External registration did not drain")
  try FileManager.default.removeItem(at:hold);try FileManager.default.removeItem(at:started);try FileManager.default.removeItem(at:release)
  let owned=try await c.open(.watchedRepositories)
  guard let controls=owned.navigation.watchControls else{throw Failure(description:"Actual watched-page owner missing")}
  try await wait{controls.canInteract && !manager.recoveryPending && manager.pendingOperations==0}
  try Data().write(to:hold)
  controls.chooseFolder={_,_,answer in answer(c.root)}
  controls.chooseRoot(renew:false,context:controls.context)
  try await wait{controls.hasPendingWork && manager.busy && FileManager.default.fileExists(atPath:started.path)}
  try require(!owned.navigation.canDismiss && !(try button("Cancel",owned)).isEnabled,"Accepted Settings watch action did not retain its own completion")
  let cancel=try button("Cancel",owned);_=NSApp.sendAction(cancel.action!,to:cancel.target,from:cancel)
  try require(c.results[ObjectIdentifier(owned)]?.isEmpty==true && owned.window?.sheetParent === c.host,"Cancel bypassed accepted page-owned work")
  try Data().write(to:release);try await wait{!controls.hasPendingWork && !manager.busy && owned.navigation.canDismiss}
  try await click("Cancel",owned);try await c.closed(owned)
  // Forced retirement hides the Settings owner, while the accepted application
  // mutation and its retained page lifetime still drain independently.
  try FileManager.default.removeItem(at:hold);try FileManager.default.removeItem(at:started);try FileManager.default.removeItem(at:release)
  let retiring=try await c.open(.watchedRepositories)
  guard let retained=retiring.navigation.watchControls else{throw Failure(description:"Replacement watched-page owner missing")}
  try await wait{retained.canInteract && !manager.recoveryPending && manager.pendingOperations==0};try Data().write(to:hold);retained.chooseFolder={_,_,answer in answer(c.root)};retained.chooseRoot(renew:false,context:retained.context)
  try await wait{retained.hasPendingWork && manager.busy && FileManager.default.fileExists(atPath:started.path)}
  retiring.retire();try await c.closed(retiring,normal:false)
  try require(retained.hasPendingWork && manager.busy,"Forced Settings retirement released accepted watch work early")
  try Data().write(to:release);try await wait{!retained.hasPendingWork && !manager.busy}
  try require(c.results[ObjectIdentifier(retiring)]==[false],"Retired watch completion reopened or re-completed Settings")
 }
 static func layout(_ c:Context)async throws{
  for page in [SettingsPageID.git,.remote]{let owner=try await c.open(page);if page == .remote{_=try await c.remote(owner)}
   try await wait{GitConfigurationSettingsModel.activeReads==0}
   for dark in [false,true]{owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);owner.window?.contentView?.layoutSubtreeIfNeeded();let window=owner.window!,root=window.contentView!
    try require(window.frame.width>=860 && window.frame.height>=540,"Settings collapsed below meaningful native size")
    for title in ["OK","Cancel","Apply","Help"]{let b=try button(title,owner),rect=b.convert(b.bounds,to:root);try require(rect.width>20 && rect.height>10 && root.bounds.insetBy(dx:-1,dy:-1).contains(rect),"Footer clipped: "+title)}
    let heading=views(root).compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue=="Settings.PageHeading"};try require(heading.map{!$0.stringValue.isEmpty && root.bounds.insetBy(dx:-1,dy:-1).contains($0.convert($0.bounds,to:root))}==true,"Settings heading clipped/missing")
    if page == .remote{let tables=views(root).compactMap{$0 as? NSTableView};try require(tables.contains{$0.identifier?.rawValue=="RemoteSettings.Remotes" && $0.numberOfRows==2 && $0.numberOfColumns>0 && $0.bounds.width>80 && ($0.enclosingScrollView?.bounds.height ?? 0) > 40} && owner.navigation.remote?.names.contains(GitReferenceName("origin"))==true && owner.navigation.remote?.names.contains(GitReferenceName("backup"))==true,"Remote list is not a usable actual native table")}
    if let output=ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_CAPTURE_DIR"]{let folder=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let target=folder.appendingPathComponent("settings-completion-"+(page == .git ? "git":"remote")+"-"+(dark ? "dark":"light")+".png")
     let original=window.frame
     do {
      defer{captureWindow=nil;window.alphaValue=0;window.setFrame(original,display:false)}
      if let screen=NSScreen.main{window.setFrameOrigin(.init(x:screen.visibleFrame.midX-window.frame.width/2,y:screen.visibleFrame.midY-window.frame.height/2))}
      captureWindow=window;window.alphaValue=1;window.orderFrontRegardless();window.displayIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
      let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");capture.arguments=["-x","-o","-l",String(window.windowNumber),target.path];try capture.run();capture.waitUntilExit()
      try require(capture.terminationStatus==0 && FileManager.default.fileExists(atPath:target.path),"Owned Settings compositor capture failed");print("Settings compositor capture: "+target.path)
     }}
   };try await click("Cancel",owner);try await c.closed(owner)
  }
 }
 static func main()async{
  NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_CAPTURE_DIR"] == nil ? .prohibited:.accessory);let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.settingsCompletionFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.settingsCompletionOrder(_:relativeTo:))))];for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
  let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
  do{try await c.prepare();let mode=CommandLine.arguments[3];switch mode{case "close":try await close(c);case "apply":try await apply(c);case "ownership":try await ownership(c);try await watchOwnership(c);default:try await layout(c)};await c.clean();try require(drained(),"Settings owned work survived cleanup");print("PASS: settings completion "+mode)}catch{await c.clean();fputs("Settings completion failure: \(error)\n",stderr);exit(1)}
 }
}
