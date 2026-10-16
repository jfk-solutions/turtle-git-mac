import AppKit
import TurtleGitCore

@main struct ZIPInventoryNativeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "ZIP native timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await verify(); DiffToolApplication.discardAll() }
        catch { DiffToolApplication.discardAll(); fputs("ZIP native failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), a=root.appendingPathComponent("old.zip"), b=root.appendingPathComponent("new.zip")
        let beforeA=try Data(contentsOf:a), beforeB=try Data(contentsOf:b)
        let suite="TurtleGit.ZIPNative."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let savedPresenter=DiffToolApplication.presentInventory
        defer { DiffToolApplication.presentInventory=savedPresenter }
        var inventory: FileComparisonWindowController?, presentations=0
        DiffToolApplication.presentInventory={ controller in inventory=controller; presentations += 1; return true }
        let original=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs)
        defer { original.close(); inventory?.close() }
        original.model.load()
        try await wait { !original.model.busy && inventory != nil }
        try require(presentations==1 && original.model.error==nil,"ZIP association did not route the actual comparison")
        let viewer=inventory!; viewer.model.load()
        try await wait { !viewer.model.busy && !viewer.model.filtering && viewer.model.document != nil }
        let old=viewer.model.document!.base, new=viewer.model.document!.destination
        try require(old.path.hasSuffix("old.zip.inventory.txt") && new.path.hasSuffix("new.zip.inventory.txt") && old.text?.contains("old.txt")==true && new.text?.contains("雪.txt")==true && new.text?.contains("folder")==true,"Actual native viewer lost archive metadata")
        try require(!viewer.model.canEdit(base:true) && !viewer.model.canEdit(base:false) && !viewer.model.dirty,"Inventory viewer can overwrite an archive")
        viewer.model.load(); try await wait { !viewer.model.busy && !viewer.model.filtering }
        try require(presentations==1 && viewer.model.document?.destination.bytes==new.bytes,"Inventory reload recursed into tool dispatch")
        viewer.close(); inventory=nil
        let raw=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true)
        defer { raw.close() }; raw.model.captureToolChoice(true); raw.model.beginTransferredDocument(); try await wait { !raw.model.busy }
        try require(presentations==1 && raw.model.document?.destination.bytes==beforeB,"Shift did not retain raw archive comparison: alternate=\(raw.model.alternateTool), presentations=\(presentations), error=\(raw.model.error ?? "none"), loaded=\(raw.model.document != nil)")

        var custom=DiffToolAssociation(); custom.pattern=".txt"; custom.program.enabled=false
        var zip=DiffToolAssociation(); zip.pattern="*.ZIP"; zip.program.applicationPath="/Applications/Custom.app"
        let associations=ToolAssociationsModel(associations:[custom,zip],tool:"diff")
        associations.restoreDefaults()
        try require(associations.draft.count==2 && associations.draft.contains(custom) && associations.selected==zip.id && associations.draft.first { $0.id==zip.id }?.program.builtIn == .zipInventory,"Restore Defaults lost other associations or row identity")
        associations.add(); let frozen=associations.draft; associations.restoreDefaults()
        try require(associations.draft==frozen,"Restore Defaults changed a draft behind its child editor")
        associations.accept(nil)
        var initial=DiffToolPreferences(); initial.associations=[custom,zip]
        try initial.save(to:prefs)
        let parent=ToolSettingsDraft(initial,valid:{$0.valid},persist:{ try $0.save(to:prefs) })
        parent.value.associations=associations.draft
        try require(parent.modified && DiffToolPreferences.load(from:prefs)==initial,"Advanced changed saved defaults before parent Apply")
        parent.cancel(); try require(parent.value==initial,"Settings Cancel kept restored associations")
        parent.value.associations=associations.draft; try require(parent.apply(),"Parent Apply rejected native adapter")
        try require(DiffToolPreferences.load(from:prefs).associations.contains { $0.program.builtIn == .zipInventory },"Parent Apply lost adapter persistence")

        let malformed=root.appendingPathComponent("broken.zip"); try Data("not a ZIP".utf8).write(to:malformed)
        let bad=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:malformed),permissions:[],preferences:prefs)
        defer { bad.close() }; bad.model.load(); try await wait { !bad.model.busy }
        try require(bad.model.error != nil && presentations==1 && DiffToolApplication.activeRequests==0,"Malformed ZIP launched another viewer or leaked active request")
        let token=OperationCancellation(); token.cancel()
        do { _=try await DiffToolApplication.open(try WorkingFileComparison(base:a,destination:b).read(),root:root,permissions:[],alternate:false,preferences:prefs,cancellation:token); throw Failure(description:"Cancelled adapter opened") }
        catch is OperationCancellationFailure {} 
        try require(presentations==1 && DiffToolApplication.activeRequests==0,"Cancelled archive adapter presented")
        try require((try Data(contentsOf:a))==beforeA && (try Data(contentsOf:b))==beforeB,"ZIP comparison modified original bytes")
        print("PASS: actual ZIP association routing and read-only native viewer/reload, Shift raw bytes, Restore Defaults draft/Apply/Cancel/identity, malformed and cancelled ownership; unchanged archives")
    }
}
