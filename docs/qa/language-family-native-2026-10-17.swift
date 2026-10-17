import AppKit
import SwiftUI
import ScreenCaptureKit
import PDFKit
import TurtleGitCore

@main struct LanguageFamilyVerification {
    struct Failure: Error, CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Language wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow,name:String)async throws {
        guard let output=ProcessInfo.processInfo.environment["TURTLEGIT_LANGUAGE_CAPTURE"] else{return}
        if #available(macOS 14.4,*) {
            let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned language window absent")}
                let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.includeChildWindows=false;config.showsCursor=false
                let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
                try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+"-language-de-"+suffix+".png"))
            };window.alphaValue=0
        } else {throw Failure(description:"Language capture needs macOS 14.4")}
    }
    @MainActor static func main()async throws {
        NSApp.setActivationPolicy(.prohibited)
        defer {NSApp.windows.forEach{$0.close()};if let id=Bundle.main.bundleIdentifier {UserDefaults.standard.removePersistentDomain(forName:id)}}
        let locale=CommandLine.arguments[1]
        let expected=["de":"Abbrechen","fr":"Annuler","en":"Cancel"][locale]!
        try require(Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview.language") == true,"Receiver did not use its private app bundle")
        try require(Bundle.main.preferredLocalizations.first==locale,"Process language selection: \(Bundle.main.preferredLocalizations)")
        try require(NSLocalizedString("Cancel",comment:"")==expected,"Compiled catalog did not localize native lookup")
        try require(NSLocalizedString("TurtleGit native translation missing",comment:"")=="TurtleGit native translation missing","Missing translation did not retain English")
        let renderer=ImageRenderer(content:VStack {
            CommandLabel(title:"Commit",icon:.commit)
            CommandLabel(title:"Commit",icon:.branch,localized:false)
        }.frame(width:400,height:140).environment(\.locale,Locale(identifier:locale)))
        let pdf=NSMutableData();var media=CGRect(x:0,y:0,width:400,height:140)
        let context=CGContext(consumer:CGDataConsumer(data:pdf)!,mediaBox:&media,nil)!
        renderer.render {_,draw in context.beginPDFPage(nil);draw(context);context.endPDFPage()};context.closePDF()
        let captions=PDFDocument(data:pdf as Data)?.string ?? ""
        try require(captions.contains(NSLocalizedString("Commit",comment:"")) && captions.contains("Commit"),"Localized command or verbatim branch caption was lost: \(captions)")
        try require(TurtleGitHelpService(bundle:Bundle.main).localURL(for:.languages)?.lastPathComponent=="LANGUAGES.html","Language Help guide was not bundled")
        if locale != "de" {print("PASS language resource process \(locale): native bundle selection, compiled label and English fallback");return}
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.main.url(forResource:"LocalizationManifest",withExtension:"json")!)) as! [String:Any]
        let records=manifest["languages"] as! [[String:Any]]
        try require(records.count==37,"Missing bundled source locale records")
        for record in records {
            let id=record["id"] as! String
            let url=Bundle.main.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:id)!
            let strings=try PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as! [String:String]
            try require(strings.count==record["translated_keys"] as! Int,"Compiled locale inventory mismatch: \(id)")
        }
        let suite="TurtleGit.Language.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let model=GeneralGitSettingsModel(preferences:prefs);model.activate()
        model.inspectEngine={_,_ in throw Failure(description:"Language-only Apply inspected Git")}
        var languagePublications = [String](), languageNotifications = 0
        model.publishFinderLanguage = { id in languagePublications.append(id); return true }
        model.notifyFinderLanguage = { languageNotifications += 1 }
        let old=model.languageBinding();old.wrappedValue="de";old.wrappedValue="fr"
        try require(model.language=="de" && model.languageModified,"Stale language binding changed a newer draft")
        model.cancelLanguage();old.wrappedValue="ja"
        try require(model.language==AppLanguageChoice.system && !model.languageModified && prefs.object(forKey:"TurtleGit.AppLanguage")==nil,"Cancel wrote or revived old language choice")
        let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="General – TurtleGit";window.isReleasedWhenClosed=false;window.alphaValue=0
        let transaction=SettingsTransaction(),appearance=SettingsAppearanceDraft(appearance:AppAppearance(preferences:prefs))
        let host=NSHostingView(rootView:GeneralSettings(appearance:appearance,model:model,preferences:prefs).environment(\.settingsTransaction,transaction).defaultAppStorage(prefs))
        let viewport=SettingsPageViewport(frame:window.contentLayoutRect);viewport.autoresizingMask=[.width,.height];window.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        window.orderFront(nil);model.languageBinding().wrappedValue="de"
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(!model.languageModified && prefs.stringArray(forKey:"AppleLanguages")==["de"] && AppLanguageChoice.selected(in:prefs)=="de","Language-only property-sheet Apply failed")
        model.languageBinding().wrappedValue="fr";model.cancelLanguage();try require(model.language=="de","Cancel lost applied choice")
        try await capture(window,name:"general")
        let wizard=FirstStartWizardController(preferences:prefs,makeRepository:{_,_ in throw Failure(description:"Language page accessed Git configuration")})
        wizard.window?.alphaValue=0;wizard.window?.orderFront(nil)
        let first=wizard.model.formContext,field=wizard.model.language(context:first)
        field.wrappedValue="fr";field.wrappedValue="ja"
        try require(wizard.model.git.language=="fr","Wizard language callback survived a new draft")
        wizard.model.language(context:wizard.model.formContext).wrappedValue="de"
        try await capture(wizard.window!,name:"first-start")
        wizard.model.language(context:wizard.model.formContext).wrappedValue="fr"
        wizard.model.next(context:wizard.model.formContext)
        try require(wizard.model.page == .welcome && AppLanguageChoice.selected(in:prefs)=="fr","Wizard Next did not persist its language page")
        field.wrappedValue="ja";wizard.close()
        try require(AppLanguageChoice.selected(in:prefs)=="fr","Later wizard closure rolled back a saved page")
        model.suspend();old.wrappedValue="ja";model.activate()
        try require(model.language=="fr","Returning General page missed newly saved wizard choice")
        model.languageBinding().wrappedValue="ja"
        model.publishFinderLanguage = { _ in throw Failure(description:"private publication failed") }
        let accepted = AppLanguageChoice.selected(in:prefs), sent = languageNotifications
        try require(!model.applyLanguage() && model.languageModified && AppLanguageChoice.selected(in:prefs)==accepted && languageNotifications==sent,"Failed Finder language publication changed accepted preferences")
        model.publishFinderLanguage = { id in languagePublications.append(id);return true }
        try require(model.applyLanguage() && model.error==nil && AppLanguageChoice.selected(in:prefs)=="ja" && languageNotifications==sent+1,"Finder language Retry did not persist then notify")
        model.languageBinding().wrappedValue=AppLanguageChoice.system;try require(model.applyLanguage(),"System reset failed")
        try require(languagePublications.last=="system" && languageNotifications>=3,"Finder did not receive System reset")
        try require(prefs.persistentDomain(forName:suite)?["AppleLanguages"]==nil,"System reset retained app-owned language override")
        var acceptedMenu: FinderMenuSettings?
        let menus = FinderContextMenuSettingsModel(defaults:prefs,publish:{ acceptedMenu=$0; return true },notify:{})
        menus.draft.topLevelMask = 0
        try AppLanguageChoice.save("fr",to:prefs)
        try require(menus.apply() && acceptedMenu?.language=="fr" && acceptedMenu?.topLevelMask==0,"Older Context Menu draft overwrote General language")
        try AppLanguageChoice.save("de",to:prefs)
        try require(!menus.modified,"General language change dirtied Context Menu policy")
        menus.cancel()
        try require(menus.draft.language=="de","Cancel restored a stale Finder language")
        window.close();model.suspend()
        try require(GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0 && FirstStartWizardModel.activeWrites==0,"Language selection leaked owners")
        print("PASS language family de: all compiled locale tables, process label/fallback, General Apply/Cancel/stale callbacks, Wizard page save/late reply/close, system reset and owned light/dark forms; no Git/global preferences touched")
    }
}
