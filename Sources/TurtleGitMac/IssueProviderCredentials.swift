// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import Security
import TurtleGitCore

protocol IssueProviderCredentialStore: Sendable {
    func token(for endpoint:URL) async throws -> String?
    func setToken(_ token:String?,for endpoint:URL) async throws
}
struct IssueProviderKeychainFailure:LocalizedError {
    let status:OSStatus
    var errorDescription:String? {"Issue provider credentials could not be accessed in Keychain (\(status))."}
}
struct IssueProviderKeychainAPI:Sendable {
    var copy:@Sendable([String:Any])->(OSStatus,Data?)
    var update:@Sendable([String:Any],[String:Any])->OSStatus
    var add:@Sendable([String:Any])->OSStatus
    var delete:@Sendable([String:Any])->OSStatus
    static let live=Self(copy:{ query in var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result);return(status,result as? Data)},update:{SecItemUpdate($0 as CFDictionary,$1 as CFDictionary)},add:{SecItemAdd($0 as CFDictionary,nil)},delete:{SecItemDelete($0 as CFDictionary)})
}
/// App-private, non-synchronizing bearer tokens, scoped to one exact endpoint.
/// Security calls are serialized off the main actor; no secrets enter defaults.
actor IssueProviderKeychainStore:IssueProviderCredentialStore {
    static let shared=IssueProviderKeychainStore()
    private let api:IssueProviderKeychainAPI
    init(api:IssueProviderKeychainAPI = .live){self.api=api}
    private func query(_ endpoint:URL)throws->[String:Any] {
        guard let c=URLComponents(url:endpoint,resolvingAgainstBaseURL:false),let scheme=c.scheme?.lowercased(),let host=c.host,c.user==nil,c.password==nil,c.fragment==nil,c.query==nil,(scheme=="https" || scheme=="http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host.lowercased())) else{throw NativeIssueProviderFailure.configuration("Enter a valid issue provider endpoint.")}
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.turtlegit.macos.issue-provider",kSecAttrAccount as String:endpoint.absoluteString,kSecUseDataProtectionKeychain as String:true,kSecAttrSynchronizable as String:false,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
    func token(for endpoint:URL)throws->String? {
        var q=try query(endpoint);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        let (status,bytes)=api.copy(q)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess else{throw IssueProviderKeychainFailure(status:status)}
        guard let bytes,bytes.count<=8192,let text=String(data:bytes,encoding:.utf8),Self.valid(text) else{throw NativeIssueProviderFailure.configuration("The saved bearer credential is invalid.")}
        return text
    }
    static func valid(_ text:String)->Bool {
        let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=")
        return !text.isEmpty && text.utf8.count<=8192 && text.unicodeScalars.allSatisfy{allowed.contains($0)}
    }
    func setToken(_ token:String?,for endpoint:URL)throws {
        var q=try query(endpoint)
        guard let token else {let status=api.delete(q);guard status==errSecSuccess || status==errSecItemNotFound else{throw IssueProviderKeychainFailure(status:status)};return}
        guard Self.valid(token) else{throw NativeIssueProviderFailure.configuration("Enter a single HTTP bearer token (up to 8192 bytes).")}
        let values:[String:Any]=[kSecValueData as String:Data(token.utf8)]
        var status=api.update(q,values)
        if status==errSecItemNotFound {q.removeValue(forKey:kSecUseAuthenticationUI as String);q.merge(values,uniquingKeysWith:{$1});q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;status=api.add(q)}
        guard status==errSecSuccess else{throw IssueProviderKeychainFailure(status:status)}
    }
}

@MainActor final class IssueProviderCredentialDrafts:ObservableObject {
    enum Mutation:Equatable {case store(String),remove;var value:String? {if case .store(let token)=self{return token};return nil}}
    private(set) static var activeOperations=0
    let store:any IssueProviderCredentialStore
    private var drafts:[String:(URL,Mutation)]=[:]
    @Published private(set) var revision=UUID()
    @Published private(set) var busy=false
    private var retired=false
    var modified:Bool {!drafts.isEmpty}
    init(store:any IssueProviderCredentialStore = IssueProviderKeychainStore.shared){self.store=store}
    func stage(token:String?,for endpoint:URL){guard !busy,!retired else{return};drafts[endpoint.absoluteString]=(endpoint,token.map(Mutation.store) ?? .remove);revision=UUID()}
    func token(for endpoint:URL)async throws->String? {if let draft=drafts[endpoint.absoluteString]{return draft.1.value};return try await store.token(for:endpoint)}
    func cancel(){guard !busy else{return};drafts.removeAll();revision=UUID()}
    func retire(){retired=true;if !busy {drafts.removeAll();revision=UUID()}}
    /// Save secrets only as part of Settings Apply, rolling back exact prior
    /// credentials if configuration publication or owner validity fails.
    func apply(publish:()->Bool = {true},isValid:()->Bool = {true})async throws->Bool {
        guard !busy,!retired else{return false}
        busy=true;Self.activeOperations += 1
        defer{busy=false;Self.activeOperations -= 1}
        let captured=drafts.sorted{$0.key<$1.key}.map{$0.value}
        var writes:[(URL,String?,String?)]=[]
        do {
            for (url,mutation) in captured {
                guard !retired,isValid() else{throw OperationCancellationFailure.cancelled}
                let old=try await store.token(for:url)
                guard !retired,isValid() else{throw OperationCancellationFailure.cancelled}
                try await store.setToken(mutation.value,for:url);writes.append((url,old,mutation.value))
                guard !retired,isValid() else{throw OperationCancellationFailure.cancelled}
            }
            guard !retired,isValid(),publish() else{throw NativeIssueProviderFailure.configuration("Issue provider settings were not saved.")}
            drafts.removeAll();revision=UUID();return true
        } catch {
            var rollbackFailed=false
            for (url,old,written) in writes.reversed() {
                do {let current=try await store.token(for:url);guard current==written else{rollbackFailed=true;continue};try await store.setToken(old,for:url)}catch{rollbackFailed=true}
            }
            if retired{drafts.removeAll();revision=UUID()}
            if rollbackFailed {throw NativeIssueProviderFailure.configuration("Settings failed and a bearer credential could not be restored. Review Keychain credentials before trying again.")}
            throw error
        }
    }
}

@MainActor final class IssueProviderCredentialEditor:NSWindowController,NSWindowDelegate {
    let model:IssueProviderCredentialEditorModel
    private var completion:((IssueProviderCredentialDrafts.Mutation?)->Void)?
    init(endpoint:URL,read:@escaping()async throws->String?,completion:@escaping(IssueProviderCredentialDrafts.Mutation?)->Void){
        model=IssueProviderCredentialEditorModel(endpoint:endpoint);self.completion=completion
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:570,height:225),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Issue provider credentials";window.isReleasedWhenClosed=false
        window.contentViewController=NSHostingController(rootView:IssueProviderCredentialDialog(model:model))
        super.init(window:window);window.delegate=self
        model.finish={ [weak self] in self?.finish($0) };model.load(read)
    }
    func finish(_ value:IssueProviderCredentialDrafts.Mutation?){guard let done=completion else{return};completion=nil;model.retire();if let window{window.sheetParent?.endSheet(window);window.close()};done(value)}
    override func close(){finish(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{finish(nil);return false}
    func windowWillClose(_ notification:Notification){finish(nil)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor final class IssueProviderCredentialEditorModel:ObservableObject {
    private(set) static var activeReads=0
    let endpoint:URL
    @Published var secret=""
    @Published private(set) var loading=true
    @Published private(set) var stored=false
    @Published private(set) var error:String?
    private var retired=false
    var finish:(IssueProviderCredentialDrafts.Mutation?)->Void={_ in}
    init(endpoint:URL){self.endpoint=endpoint}
    func load(_ read:@escaping()async throws->String?){Self.activeReads += 1;Task{[self] in defer{Self.activeReads -= 1};do{let token=try await read();guard !retired else{return};stored=token != nil;loading=false}catch{guard !retired else{return};self.error=error.localizedDescription;loading=false}}}
    var canSave:Bool {!retired && !loading && IssueProviderKeychainStore.valid(secret)}
    func save(){guard canSave else{return};finish(.store(secret))}
    func remove(){guard !retired,!loading else{return};finish(.remove)}
    func cancel(){finish(nil)}
    func retire(){retired=true;secret="";finish={_ in}}
}
private struct IssueProviderCredentialDialog:View {
    @ObservedObject var model:IssueProviderCredentialEditorModel
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Text(model.endpoint.absoluteString).font(.caption).textSelection(.enabled)
            Text(model.loading ? "Reading Keychain…":model.stored ? "A bearer token is stored for this endpoint.":"No bearer token is stored for this endpoint.").font(.caption)
            SecureField("Bearer token",text:$model.secret).disabled(model.loading)
            Text("Changes are saved to Keychain only when Settings is applied.").font(.caption).foregroundStyle(.secondary)
            if let error=model.error{Text(error).font(.caption).foregroundStyle(.red)}
            HStack{Button("Remove"){model.remove()}.disabled(model.loading);Spacer();Button("Cancel"){model.cancel()}.keyboardShortcut(.cancelAction);Button("Save"){model.save()}.keyboardShortcut(.defaultAction).disabled(!model.canSave)}
        }.padding(16)
    }
}

/// The project fallback uses the same endpoint Keychain store without putting a
/// secret into tracked .tgitconfig or requiring a local association.
@MainActor final class IssueProviderFallbackCredentialsModel:ObservableObject {
    let drafts:IssueProviderCredentialDrafts
    @Published private(set) var hasChild=false
    @Published var error:String?
    private(set) var editor:IssueProviderCredentialEditor?
    weak var window:NSWindow?
    private var retired=false
    private var observation:AnyCancellable?
    init(store:any IssueProviderCredentialStore = IssueProviderKeychainStore.shared){drafts=IssueProviderCredentialDrafts(store:store);observation=drafts.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}}
    func edit(identifier:String,parameters:String){
        guard !retired,!hasChild,!drafts.busy,let window,window.attachedSheet==nil else{return}
        do{
            let provider=try NativeIssueProviderSession(identifier:identifier,parameters:parameters)
            guard let endpoint=provider.endpoint else{return}
            let child=IssueProviderCredentialEditor(endpoint:endpoint,read:{[drafts] in try await drafts.token(for:endpoint)}){[weak self] value in
                guard let self else{return};self.editor=nil;self.hasChild=false
                if !self.retired,let value{self.drafts.stage(token:value.value,for:endpoint)}
            }
            editor=child;hasChild=true;child.window?.alphaValue=window.alphaValue;child.window?.appearance=window.appearance
            if let sheet=child.window{window.beginSheet(sheet)}else{child.close()}
        }catch{self.error=error.localizedDescription}
    }
    func apply()async->Bool{guard !hasChild,!retired else{return false};do{return try await drafts.apply(isValid:{!self.retired})}catch{if !retired{self.error=error.localizedDescription};return false}}
    func suspend(){editor?.close();editor=nil;hasChild=false}
    func cancel(){suspend();drafts.cancel();error=nil}
    func retire(){guard !retired else{return};retired=true;suspend();drafts.retire()}
}
struct IssueProviderFallbackCredentials:View {
    let identifier:String,parameters:String
    @StateObject private var model=IssueProviderFallbackCredentialsModel()
    @Environment(\.settingsTransaction) private var transaction
    private var available:Bool {(try? NativeIssueProviderSession(identifier:identifier,parameters:parameters).endpoint) != nil}
    var body:some View {
        VStack(alignment:.leading){
            HStack{Button("Credentials…"){model.edit(identifier:identifier,parameters:parameters)}.disabled(!available || model.hasChild || model.drafts.busy);Text("Bearer tokens are stored only in Keychain.").font(.caption).foregroundStyle(.secondary)}
            if let error=model.error{Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
        }
            .background(IssueProviderCredentialWindowProbe(model:model).frame(width:0,height:0))
            .settingsParticipant("issueProviderFallbackCredentials",page:.issueTracker,value:model.drafts.revision,modified:{model.drafts.modified},validate:{model.hasChild ? "Close the issue provider credential editor before applying.":nil},apply:{await model.apply()},cancel:model.cancel)
            .onReceive(model.drafts.objectWillChange){_ in transaction?.notify()}
            .onChange(of:identifier){_ in model.suspend()}.onChange(of:parameters){_ in model.suspend()}
            .onDisappear{model.suspend()}
    }
}
private struct IssueProviderCredentialWindowProbe:NSViewRepresentable {
    let model:IssueProviderFallbackCredentialsModel
    func makeNSView(context:Context)->Probe{let view=Probe();view.model=model;return view}
    func updateNSView(_ view:Probe,context:Context){view.model=model;view.attach()}
    static func dismantleNSView(_ view:Probe,coordinator:()){view.detach();view.model=nil}
    final class Probe:NSView {
        weak var model:IssueProviderFallbackCredentialsModel?
        private var observer:NSObjectProtocol?
        private weak var owner:NSWindow?
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();attach()}
        func attach(){guard owner !== window else{return};detach();owner=window;model?.window=window
            if let window{observer=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak model] _ in MainActor.assumeIsolated{model?.retire()}}}
        }
        func detach(){if let observer{NotificationCenter.default.removeObserver(observer)};observer=nil;owner=nil}
        deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
    }
}
