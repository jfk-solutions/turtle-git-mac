// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

private final class DialogFirstReadBookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
extension WorkspaceLaunchVerification {
    /// Actual native dialog/model routes while the private Finder writer is
    /// unavailable. This is an ordering regression, not a Ladybird benchmark.
    static func dialogFirstRead(_ c:Context)async throws {
        let repository=try await privateCommitRepository(c)
        let literal="tracked 雪.txt",file=repository.root.appendingPathComponent(literal)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        let indexURL=repository.root.appendingPathComponent(".git/index"),index=try Data(contentsOf:indexURL),working=try Data(contentsOf:file)
        let session=try c.cache.startSession()
        defer{_=try? c.cache.endSession(session)}
        let descriptor=Darwin.open(c.cache.url.path+".lock",O_RDWR)
        guard descriptor>=0 else{throw Failure(description:"Private Finder cache lock missing")}
        var locked=false
        defer{if locked{flock(descriptor,LOCK_UN)};Darwin.close(descriptor)}
        guard flock(descriptor,LOCK_EX|LOCK_NB)==0 else{throw Failure(description:"Private Finder cache already locked")}
        locked=true
        var children=[NSWindowController](),routers=[RepositoryModel]()
        let git=c.git
        do {
            for action in [RepositoryAction.commit,.status,.log] {
                let router=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotStore:c.cache,savedAccessStore:c.store,comparisonMarks:WorkingComparisonMarkStore(storageURL:c.folder.appendingPathComponent("fast-route-marks.json")),cachePersistenceDefaults:c.preferences)
                router.requiresRepositoryScope=true;router.repositoryBookmarkProvider=DialogFirstReadBookmarks();router.fileComparisonPreferences=c.preferences
                c.models.append(router);routers.append(router)
                let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),began=ProcessInfo.processInfo.systemUptime
                guard let url=FinderRequest(action:action,paths:[file]).url else{throw Failure(description:"Actual dialog request unavailable")}
                router.handle(url)
                func child()->NSWindowController? {
                    NSApp.windows.filter{!baseline.contains(ObjectIdentifier($0))}.compactMap(\.windowController).first {
                        switch action {case .commit:return $0 is CommitWindowController;case .status:return $0 is StatusWindowController;case .log:return $0 is LogWindowController;default:return false}
                    }
                }
                try await wait("actual \(action.rawValue) shown before private cache writer release"){router.error != nil || child()?.window?.isVisible==true}
                let shown=ProcessInfo.processInfo.systemUptime
                guard let controller=child() else{throw Failure(description:"Dialog route failed before cache release: "+(router.error ?? action.rawValue))}
                children.append(controller)
                try await wait("actual \(action.rawValue) rows before private cache writer release") {
                    if let value=controller as? CommitWindowController{return value.model.error != nil || !value.model.busy && value.model.fileListAvailable && value.model.visibleEntries.contains{GitReferenceName.equal($0.path,literal)}}
                    if let value=controller as? StatusWindowController{return value.model.error != nil || !value.model.busy && value.model.hasStatusSnapshot && value.model.files.contains{GitReferenceName.equal($0.entry.path,literal)}}
                    if let value=controller as? LogWindowController{return value.model.error != nil || !value.model.busy && value.model.entries.contains{!$0.hash.isEmpty}}
                    return false
                }
                let loaded=ProcessInfo.processInfo.systemUptime
                try require(router.error==nil && !router.busy && router.workspaceWindow==nil,"Standalone dialog retained parent busy/workspace or failed authority")
                try require(router.root?.path==repository.root.path,"Dialog lost actual discovered repository authority")
                if let value=controller as? CommitWindowController {
                    try require(value.model.error==nil && value.model.scopePaths.map{Data($0.utf8)}==[Data(literal.utf8)],"Commit lost exact selected file scope")
                }
                if let value=controller as? StatusWindowController {try require(value.model.error==nil,"Status own read failed")}
                if let value=controller as? LogWindowController {try require(value.model.error==nil,"Log own read failed")}
                var heartbeat=false;DispatchQueue.main.async{heartbeat=true}
                try await wait("MainActor responsive with unavailable Finder writer"){heartbeat}
                try require(locked,"Fixture released private cache lock before proving native rows")
                print(String(format:"DIALOG_FIRST_READ %@ window_seconds=%.6f rows_seconds=%.6f finder_writer_held=true",action.rawValue,shown-began,loaded-began))
            }
            flock(descriptor,LOCK_UN);locked=false
            try await wait("deferred Finder work released and drained"){routers.allSatisfy{!$0.busy && !$0.hasPendingRepositoryWork && !$0.dialogFinderRefreshPending}}
            for controller in children{controller.close()}
            try await wait("dialog readers drained"){CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && StatusWindowModel.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && children.allSatisfy{$0.window?.isVisible != true}}
            let after=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(after==head && (try Data(contentsOf:indexURL))==index && (try Data(contentsOf:file))==working,"Dialog routing/cache completion mutated HEAD/index/working bytes")
            try noWorkspace(c,"Self-loading dialog route created workspace")
        }catch{
            if locked{flock(descriptor,LOCK_UN);locked=false}
            for controller in children{controller.close()}
            for router in routers{router.stopMonitoringForTermination()}
            throw error
        }
    }
}
