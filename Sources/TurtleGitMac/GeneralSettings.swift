// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class GeneralGitSettingsModel: ObservableObject {
    static private(set) var activeOperations = 0
    static private(set) var activeDialogs=0
    @Published private(set) var selecting=false
    @Published private(set) var confirmingUpdates=false
    @Published private(set) var checking=false
    @Published private(set) var cancellingCheck=false
    @Published var draft: GitEnginePreferences { didSet { if draft != oldValue { version = "" } } }
    @Published private(set) var busy = false
    @Published var version = ""
    @Published var error: String?
    private let preferences: UserDefaults
    @Published private(set) var language: String
    private var savedLanguage: String
    private var languageRevision = UUID()
    var languageModified: Bool { language != savedLanguage }
    func chooseLanguage(_ id: String) {
        guard canEditPage, AppLanguageChoice.isAvailable(id) else { return }
        language = id; languageRevision = UUID()
    }
    func languageBinding() -> Binding<String> {
        let context = lifecycle, revision = languageRevision
        return Binding(get: { self.language }, set: { id in
            guard self.lifecycle == context, self.languageRevision == revision else { return }
            self.chooseLanguage(id)
        })
    }
    var publishFinderLanguage: ((String) throws -> Bool)?
    var notifyFinderLanguage: () -> Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification), object: nil) }
    func applyLanguage() -> Bool {
        guard !busy, !selecting, !confirmingUpdates else { return false }
        guard languageModified else { return true }
        let acceptedLanguage=language,acceptedLifecycle=lifecycle,baseline=FinderMenuSettings.from(defaults:preferences)
        let intents=SettingsPublicationIntents(defaults:preferences),pending=intents.pending(.finderMenu)
        var published=baseline;published.language=acceptedLanguage
        func retainAcceptedIntent(){if FinderMenuSettings.from(defaults:preferences) != published,intents.pending(.finderMenu)==nil{_ = intents.request(.finderMenu)}}
        do {
            // Publish the accepted choice before changing local defaults so a
            // failed shared write leaves this draft available for Retry.
            let shared: Bool
            if let publishFinderLanguage { shared = try publishFinderLanguage(acceptedLanguage) }
            else if preferences === UserDefaults.standard {
                shared = try published.write()
            } else { shared = false }
            guard lifecycle==acceptedLifecycle else{if shared{retainAcceptedIntent()};return false}
            guard language==acceptedLanguage,FinderMenuSettings.from(defaults:preferences)==baseline else{
                if shared{retainAcceptedIntent()}
                error="The settings changed during Finder publication. The current draft is retained; apply it again.";return false
            }
            try AppLanguageChoice.save(acceptedLanguage, to: preferences)
            savedLanguage = acceptedLanguage; languageRevision = UUID(); error = nil
            if shared {
                if let pending,FinderMenuSettings.from(defaults:preferences)==published {_ = intents.complete(.finderMenu,request:pending)}
                notifyFinderLanguage()
            }else{
                _ = intents.request(.finderMenu)
                error="Preferences saved. Signed App Group access is required to update Finder. Apply Advanced Settings to retry."
            }
            return true
        }
        catch {
            if lifecycle != acceptedLifecycle || FinderMenuSettings.from(defaults:preferences) != baseline {retainAcceptedIntent()}
            guard lifecycle==acceptedLifecycle else{return false};self.error = error.localizedDescription; return false }
    }
    func cancelLanguage() { language = savedLanguage; languageRevision = UUID() }
    private var saved: GitEnginePreferences
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let value = GitEnginePreferences.load(from:preferences); draft = value; saved = value
        let language = AppLanguageChoice.selected(in: preferences); self.language = language; savedLanguage = language
    }
    private var token: OperationCancellation?
    private var request = UUID()
    private var updateAlert: NSAlert?
    private var panel: NSOpenPanel?
    @Published private var active=false
    private var lifecycle=UUID()
    private var live=false
    private var attachment:UUID?
    private var windowObserver:NSObjectProtocol?
    weak var window:NSWindow? {didSet {
        guard oldValue !== window else {return};cancelBrowse();cancelUpdateQuestion()
        if let windowObserver {NotificationCenter.default.removeObserver(windowObserver)};windowObserver=nil
        if let window {windowObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.suspend()} }}
    }}
    deinit {if let windowObserver {NotificationCenter.default.removeObserver(windowObserver)}}
    var inspectEngine:((GitEnginePreferences,OperationCancellation)async throws->String)?
    var presentPanel:((NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var selectedURL:(NSOpenPanel)->URL? = {$0.url}
    var bookmark:(URL)throws->Data = {try $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)}
    var presentUpdateQuestion:((NSAlert,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var canEditEngine:Bool {live && !busy && !selecting && !confirmingUpdates && !GitRuntime.isAppStoreBuild}
    var canCheck:Bool {live && !busy && !selecting && !confirmingUpdates}
    var canEditPage:Bool {live && !busy && !selecting && !confirmingUpdates}
    var validationError:String? {
        if selecting || confirmingUpdates {return "Finish the General settings question first."}
        if busy {return "Wait for the Git version check to finish, or cancel it."}
        return GitRuntime.isAppStoreBuild || draft.valid ? nil:"Choose a valid Git executable and absolute Extra PATH directories."
    }
    var modified: Bool { draft != saved }
    func attach(to owner:NSWindow?, attachment receipt:UUID) {
        guard let owner else { detach(attachment:receipt); return }
        guard attachment != receipt || window !== owner || !live else { return }
        attachment=receipt; window=owner; activate()
    }
    func detach(attachment receipt:UUID) { guard attachment == receipt else{return};attachment=nil;suspend() }
    func activate() {
        live=true;lifecycle=UUID();let generation=lifecycle
        DispatchQueue.main.async { [weak self] in
            guard let self,self.live,self.lifecycle==generation else{return}
            if !self.languageModified {
                let current=AppLanguageChoice.selected(in:self.preferences)
                if current != self.savedLanguage {self.language=current;self.savedLanguage=current;self.languageRevision=UUID()}
            }
            self.active=true
            if self.token == nil {self.busy=false;self.checking=false;self.cancellingCheck=false}
            self.selecting=self.panel != nil;self.confirmingUpdates=self.updateAlert != nil
        }
    }
    func suspend() {
        live=false;lifecycle=UUID();let generation=lifecycle
        request=UUID();token?.cancel();token=nil
        cancelBrowse();cancelUpdateQuestion()
        DispatchQueue.main.async { [weak self] in
            guard let self,self.lifecycle==generation,!self.live else{return}
            self.active=false;self.busy=false;self.checking=false;self.cancellingCheck=false
        }
    }
    private func releaseDialog(_ dialog:NSWindow, publication:@escaping (GeneralGitSettingsModel)->Void) {
        let parent=dialog.sheetParent ?? window
        if dialog.sheetParent != nil {parent?.endSheet(dialog,returnCode:.cancel)};dialog.orderOut(nil)
        Task { @MainActor [self] in
            while dialog.sheetParent != nil || parent?.attachedSheet === dialog {try? await Task.sleep(nanoseconds:10_000_000)}
            Self.activeDialogs -= 1
            publication(self)
        }
    }
    private func cancelBrowse() {
        guard let panel else{return};self.panel=nil
        releaseDialog(panel) { model in if model.panel == nil {model.selecting=false} }
    }
    private func cancelUpdateQuestion() {
        guard let alert=updateAlert else{return};updateAlert=nil
        releaseDialog(alert.window) { model in if model.updateAlert == nil {model.confirmingUpdates=false} }
    }
    private func executable(_ settings: GitEnginePreferences) throws -> URL {
        if !GitRuntime.isAppStoreBuild, settings.choice == .custom {
            guard settings.valid else { throw GitRuntimeFailure.customGitInvalid }
            return try settings.selectedExecutable()
        }
        if !GitRuntime.isAppStoreBuild, settings.choice == .system { return URL(fileURLWithPath: "/usr/bin/git") }
        let suite = "TurtleGit.EngineCheck." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { throw GitRuntimeFailure.customGitInvalid }
        defer { preferences.removePersistentDomain(forName: suite) }
        return try GitRuntime.executable(preferences: preferences)
    }
    private func inspect(_ settings: GitEnginePreferences, cancellation: OperationCancellation?) async throws -> String {
        let engine = try executable(settings)
        let suite = "TurtleGit.EngineCheck." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { throw GitRuntimeFailure.customGitInvalid }
        defer { preferences.removePersistentDomain(forName: suite) }
        if !GitRuntime.isAppStoreBuild { try settings.save(to: preferences) }
        var environment = GitRuntime.environment(executable: engine, preferences: preferences)
        if environment["PATH"] == nil { environment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin" }
        let directory = try TurtleGitTemporaryStorage.root
        let repository = GitRepository(root: directory, executable: engine)
        let response = try await repository.run(["--version"], environmentOverrides: environment, cancellation: cancellation)
        let version = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("git version ") else { throw GitRuntimeFailure.customGitInvalid }
        return version
    }
    private func inspectDraft(_ settings:GitEnginePreferences,token:OperationCancellation)async throws->String {
        if let inspectEngine {return try await inspectEngine(settings,token)}
        return try await inspect(settings,cancellation:token)
    }
    func check() {
        guard canCheck else {return}
        let cancellation=OperationCancellation(),generation=UUID(),settings=draft
        token=cancellation;request=generation;busy=true;checking=true;cancellingCheck=false;error=nil;version="";Self.activeOperations += 1
        Task {
            defer {Self.activeOperations -= 1;if request==generation {busy=false;checking=false;cancellingCheck=false;token=nil}}
            do {
                let result=try await inspectDraft(settings,token:cancellation)
                if live,request==generation,!cancellation.isCancelled,draft==settings {version=result}
            } catch {if live,request==generation,!cancellation.isCancelled,draft==settings {self.error=error.localizedDescription}}
        }
    }
    func cancelCheck() {guard live,checking,!cancellingCheck else {return};cancellingCheck=true;token?.cancel()}
    func apply(validateUnchanged:Bool = false,cancellation:OperationCancellation? = nil)async->Bool {
        guard !busy,!selecting,!confirmingUpdates else {return false}
        guard modified || validateUnchanged else {return true}
        let settings=draft,token=cancellation ?? OperationCancellation(),generation=UUID()
        request=generation;self.token=token;busy=true;error=nil;Self.activeOperations += 1
        defer {Self.activeOperations -= 1;if request==generation {busy=false;self.token=nil}}
        do {
            let version=try await inspectDraft(settings,token:token);try token.check()
            guard request==generation else {return false}
            guard draft==settings else {error="The Git engine changed during validation. Review it and apply again.";return false}
            if !GitRuntime.isAppStoreBuild {try settings.save(to:preferences)}
            self.version=version;saved=settings;return true
        } catch {if request==generation,!token.isCancelled {self.error=error.localizedDescription};return false}
    }
    func cancel() {if checking {cancelCheck()};draft=saved;error=nil}
    func confirmDisableUpdates(_ completion:@escaping ()->Void) {
        guard canEditPage,let window,window.attachedSheet == nil else {return}
        let context=lifecycle,alert=NSAlert();alert.messageText="Disable automatic update checks?"
        alert.informativeText="You can still check manually using Check now."
        alert.addButton(withTitle:"Disable update checks");alert.addButton(withTitle:"Abort")
        alert.buttons[0].keyEquivalent="";alert.buttons[1].keyEquivalent="\r";alert.window.defaultButtonCell=alert.buttons[1].cell as? NSButtonCell
        updateAlert=alert;confirmingUpdates=true;Self.activeDialogs += 1
        let reply:(NSApplication.ModalResponse)->Void = { [weak self,weak window] response in
            guard let self,self.updateAlert === alert else {return}
            self.updateAlert=nil
            self.releaseDialog(alert.window) { model in
                if model.updateAlert == nil {model.confirmingUpdates=false}
                if response == .alertFirstButtonReturn,model.live,model.lifecycle==context,model.window === window,window != nil {completion()}
            }
        }
        if let presentUpdateQuestion {presentUpdateQuestion(alert,window,reply)} else {alert.beginSheetModal(for:window,completionHandler:reply)}
    }
    func browse() {
        guard canEditEngine,let window,window.attachedSheet == nil else {return}
        let context=lifecycle,settings=draft,chooser=NSOpenPanel();chooser.title="Select Git executable";chooser.prompt="Select Git"
        chooser.canChooseFiles=true;chooser.canChooseDirectories=false;chooser.allowsMultipleSelection=false
        chooser.directoryURL=URL(fileURLWithPath:draft.path.isEmpty ? "/usr/bin":(draft.path as NSString).deletingLastPathComponent)
        error=nil;panel=chooser;selecting=true;Self.activeDialogs += 1
        let reply:(NSApplication.ModalResponse)->Void = { [weak self,weak window] response in
            guard let self,self.panel === chooser else {return}
            self.panel=nil
            self.releaseDialog(chooser) { model in
                if model.panel == nil {model.selecting=false}
            guard response == .OK,model.live,model.lifecycle==context,model.draft==settings,model.window === window,window != nil,let file=model.selectedURL(chooser) else {return}
            do {
                guard try file.resolvingSymlinksInPath().resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true,FileManager.default.isExecutableFile(atPath:file.path) else {throw GitRuntimeFailure.customGitInvalid}
                let grant=try model.bookmark(file)
                guard model.live,model.lifecycle==context,model.draft==settings,model.window === window else {return}
                var chosen=settings;chosen.bookmark=grant;chosen.path=file.path;chosen.choice = .custom;model.draft=chosen
            } catch {if model.live,model.lifecycle==context,model.draft==settings,model.window === window {model.error=error.localizedDescription}}
            }
        }
        if let presentPanel {presentPanel(chooser,window,reply)} else {chooser.beginSheetModal(for:window,completionHandler:reply)}
    }
    func environment() -> String {
        var values = ProcessInfo.processInfo.environment
        if let engine = try? executable(draft) {
            let suite = "TurtleGit.Environment." + UUID().uuidString
            if let preferences = UserDefaults(suiteName: suite) {
                defer { preferences.removePersistentDomain(forName: suite) }
                if !GitRuntime.isAppStoreBuild { try? draft.save(to: preferences) }
                values.merge(GitRuntime.environment(executable: engine, preferences: preferences)) { _, runtime in runtime }
            }
        }
        values["GIT_TERMINAL_PROMPT"] = "0"; values["GIT_PAGER"] = "cat"; values["LC_ALL"] = "C"
        values.merge(SSHClientPreferences.load(from:preferences).environment(existing: values)) { _, selected in selected }
        return values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "\n")
    }
}
struct AppLanguageLabel: View {
    let choice: AppLanguageChoice
    var body: some View {
        if choice.id == AppLanguageChoice.system { Text("System Language") }
        else { Text(verbatim: choice.title) }
    }
}

struct GeneralSettings: View {
    let appearanceManagedByOwner:Bool
    @ObservedObject var appearance: SettingsAppearanceDraft
    @StateObject private var model: GeneralGitSettingsModel
    private let preferences: UserDefaults
    @State private var environment: String?
    @State private var updates: Bool
    @State private var savedUpdates: Bool
    init(appearance: SettingsAppearanceDraft, preferences: UserDefaults = .standard, appearanceManagedByOwner:Bool=false) {
        self.appearanceManagedByOwner=appearanceManagedByOwner
        self.appearance = appearance; self.preferences = preferences
        _model = StateObject(wrappedValue:GeneralGitSettingsModel(preferences:preferences))
        let enabled = (preferences.object(forKey:"VersionCheck") as? NSNumber)?.boolValue ?? true
        _updates = State(initialValue:enabled); _savedUpdates = State(initialValue:enabled)
    }
    init(appearance:SettingsAppearanceDraft,model:GeneralGitSettingsModel,preferences:UserDefaults,appearanceManagedByOwner:Bool=false) {
        self.appearanceManagedByOwner=appearanceManagedByOwner
        self.appearance=appearance;self.preferences=preferences;_model=StateObject(wrappedValue:model)
        let enabled=(preferences.object(forKey:"VersionCheck") as? NSNumber)?.boolValue ?? true
        _updates=State(initialValue:enabled);_savedUpdates=State(initialValue:enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("TurtleGit for Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Language:", selection: model.languageBinding()) {
                        ForEach(AppLanguageChoice.choices) { AppLanguageLabel(choice: $0).tag($0.id) }
                    }
                    HStack(alignment: .top) {
                        Text("Restart TurtleGit to apply a language change. Some text is still in English.").font(.caption).foregroundStyle(.secondary)
                        Spacer(); Button("Language help") { TurtleGitHelp.show(.languages) }.buttonStyle(.link)
                    }
                    HStack {
                        LogPreferenceCheckbox(title: "Automatically check for newer versions every week", value: Binding(get: { updates }, set: { enabled in
                            if enabled { updates = true } else { model.confirmDisableUpdates { updates = false } }
                        })).frame(height:24).disabled(GitRuntime.isAppStoreBuild)
                        Spacer(); Button("Check now") { ReleaseUpdateService.shared.show(preferences: preferences) }
                    }
                    Button("Re-run First Start Wizard") { FirstStartWizardService.shared.show(preferences: preferences) }
                    Picker("Appearance:", selection: $appearance.choice) { ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) } }
                }.padding(10).disabled(!model.canEditPage)
            }
            GroupBox("Git for macOS") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Git engine:", selection: Binding(get: { GitRuntime.isAppStoreBuild ? .automatic : model.draft.choice }, set: { model.draft.choice = $0 })) {
                        Text("Automatic (bundled when available)").tag(GitEngineChoice.automatic)
                        Text("System Git").tag(GitEngineChoice.system)
                        Text("Custom Git").tag(GitEngineChoice.custom)
                    }.disabled(!model.canEditEngine)
                    HStack {
                        Text("Git executable:").frame(width:100,alignment:.leading)
                        PathEntryField(text:Binding(get:{model.draft.path},set:{model.draft.path=$0;model.draft.bookmark=nil}),label:"Git executable",preferences:preferences,mayEdit:{model.canEditEngine && model.draft.choice == .custom}).frame(height:24)
                        Button("Browse…", action: model.browse)
                    }.disabled(!model.canEditEngine || model.draft.choice != .custom)
                    HStack {Text("Extra PATH:").frame(width:100,alignment:.leading);TextField("",text:$model.draft.extraPath).accessibilityLabel("Git Extra PATH")}.disabled(!model.canEditEngine)
                    HStack { Text("Version:"); Text(verbatim: model.version); Spacer(); Button("Check now", action: model.check).disabled(!model.canCheck) }
                    Button("Show Environment Variables") { environment = model.environment() }.disabled(!model.canCheck)
                    if model.busy {HStack {ProgressView().controlSize(.small);if model.checking {Button(model.cancellingCheck ? "Cancelling…":"Cancel check",action:model.cancelCheck).disabled(model.cancellingCheck)}}}
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(10)
            }
            Text(GitRuntime.isAppStoreBuild ? "The App Store build uses the Git and SSH engines included in the app." : "Git engine changes apply to newly opened repositories and dialogs. Reopen the repository after changing the engine.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).background(GeneralSettingsProbe(model: model).frame(width: 0, height: 0))
        .onAppear { model.activate() }
        .modifier(SettingsAppearanceParticipant(draft:appearance,managedByOwner:appearanceManagedByOwner))
        .settingsParticipant("general.updates", page: .general, value: updates, modified: { updates != savedUpdates }, apply: { preferences.set(updates, forKey: "VersionCheck"); savedUpdates = updates; return true }, cancel: { updates = savedUpdates })
        .settingsParticipant("general.language", page: .general, value: model.language, modified: { model.languageModified }, apply: { model.applyLanguage() }, cancel: model.cancelLanguage)
        .settingsParticipant("general.git", page: .general, value: model.draft, modified: { model.modified }, validate: {model.validationError}, apply: { await model.apply() }, cancel: model.cancel)
        .sheet(isPresented: Binding(get: { environment != nil }, set: { if !$0 { environment = nil } })) {
            VStack(alignment: .leading) {
                Text("Git Environment Variables").font(.headline)
                ScrollView([.vertical, .horizontal]) { Text(environment ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(8) }
                HStack { Spacer(); Button("Close") { environment = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 760, height: 500)
        }
    }
}
private struct GeneralSettingsProbe: NSViewRepresentable {
    let model: GeneralGitSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.attach(to: view.window, attachment: view.attachment) }
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.model?.detach(attachment:view.attachment);view.model=nil}
    final class Probe: NSView {
        let attachment=UUID()
        weak var model: GeneralGitSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to: window, attachment: attachment) }
    }
}
