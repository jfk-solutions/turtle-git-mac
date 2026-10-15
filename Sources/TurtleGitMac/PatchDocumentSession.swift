// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore
import UniformTypeIdentifiers

/// Standalone UDiff documents own their file permission, panels and save point.
/// Commit and embedded import previews never enable this session.
@MainActor final class PatchDocumentSession {
    enum Decision { case save, discard, cancel }
    enum Failure: LocalizedError {
        case tooLarge, encoding, changed
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The patch is too large to open (250 MiB limit)."
            case .encoding: return "The edited text cannot be represented in this patch’s original encoding. No file was written."
            case .changed: return "The patch file changed outside TurtleGit. Use Save As to keep your edits in another file."
            }
        }
    }
    static private(set) var activeOperations = 0
    private weak var owner: PatchWindowController?
    private(set) var fileURL: URL?
    private var fileAccess: RepositoryAccessLease?
    private var diskBytes: Data?
    private var working = false, retired = false
    private var generation = 0
    private var cancellation: OperationCancellation?
    var askChanges: (NSWindow, @escaping (Decision) -> Void) -> Void = { window, reply in
        let alert = NSAlert(); alert.messageText = "Save changes to this patch before continuing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in reply(result == .alertFirstButtonReturn ? .save : result == .alertSecondButtonReturn ? .discard : .cancel) }
    }
    var chooseOpen: (NSWindow, @escaping (URL?) -> Void) -> Void = { window, reply in
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { reply($0 == .OK ? panel.url : nil) }
    }
    var chooseSave: (NSWindow, String, @escaping (URL?) -> Void) -> Void = { window, name, reply in
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { reply($0 == .OK ? panel.url : nil) }
    }
    var acquireAccess: (URL) -> RepositoryAccessLease = { RepositoryAccessLease(url: $0) }
    var readFile: (URL, OperationCancellation) async throws -> Data = { url, token in
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var bytes = Data()
            while true {
                try token.check()
                let part = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if part.isEmpty { break }
                guard bytes.count + part.count < 250 * 1024 * 1024 else { throw Failure.tooLarge }
                bytes.append(part)
            }
            try token.check(); return bytes
        }.value
    }
    init(owner: PatchWindowController) {
        self.owner = owner
        owner.model.documentChanged = { [weak self] in self?.owner?.window?.isDocumentEdited = self?.dirty == true }
        owner.model.requestReplacement = { [weak self] bytes in
            Task { @MainActor [weak self] in self?.replace(bytes) }
        }
        owner.model.requestReload = { [weak self] paths, staged in
            self?.launch { session in
                guard await session.resolveChanges(), let model = session.owner?.model else { return }
                model.reload(paths: paths, staged: staged, discardingEdits: true)
            }
        }
    }
    var enabled: Bool { !retired && owner?.model.allowsDocumentEditing == true && owner?.model.readOnly == true }
    var dirty: Bool { enabled && owner?.model.documentDirty == true }
    private func launch(_ operation: @escaping (PatchDocumentSession) async -> Void) {
        guard enabled, !working, let owner, !owner.model.busy, !owner.model.confirmingQuit, owner.window?.attachedSheet == nil else { return }
        working = true; Self.activeOperations += 1
        Task {
            defer { working = false; Self.activeOperations -= 1 }
            await operation(self)
        }
    }
    func openDocument() {
        launch { session in
            guard await session.resolveChanges(), let window = session.owner?.window else { return }
            session.owner?.model.busy = true
            let url = await withCheckedContinuation { reply in session.chooseOpen(window) { reply.resume(returning: $0) } }
            session.owner?.model.busy = false
            guard !session.retired, let url else { return }
            await session.load(url)
        }
    }
    func saveDocument(as newFile: Bool = false) { launch { _ = await $0.save(as: newFile) } }
    func requestClose() { launch { if await $0.resolveChanges() { $0.owner?.close() } } }
    func replace(_ bytes: Data) {
        launch { session in
            guard await session.resolveChanges(), let model = session.owner?.model else { return }
            session.fileURL = nil; session.fileAccess = nil; session.diskBytes = nil
            model.setReadOnlyDiff(bytes, discardingEdits: true)
        }
    }
    func resolveChanges() async -> Bool {
        guard !retired, let owner, !owner.model.busy, let window = owner.window, window.attachedSheet == nil else { return false }
        guard dirty else { return true }
        let wasConfirming = owner.model.confirmingQuit; owner.model.confirmingQuit = true
        defer { owner.model.confirmingQuit = wasConfirming }
        let decision = await withCheckedContinuation { reply in askChanges(window) { reply.resume(returning: $0) } }
        guard !retired else { return false }
        switch decision { case .cancel: return false; case .discard: return true; case .save: return await save() }
    }
    private func load(_ url: URL) async {
        guard !retired, let owner else { return }
        let access = acquireAccess(url), token = OperationCancellation(), request = generation
        if GitRuntime.isAppStoreBuild && !access.hasSecurityScope { owner.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        owner.model.busy = true; cancellation = token
        defer { withExtendedLifetime(access) {}; owner.model.busy = false; cancellation = nil }
        do {
            let bytes = try await readFile(url, token)
            guard !retired, generation == request, !token.isCancelled else { return }
            fileURL = url; fileAccess = access; diskBytes = bytes
            owner.model.setReadOnlyDiff(bytes, discardingEdits: true)
            owner.model.refreshAvailable = false; owner.model.customRefresh = nil
            owner.model.comparisonTitle = url.lastPathComponent
            owner.model.readOnlyInformation = "Patch document. Edits are saved to the selected patch file."
            owner.window?.title = url.lastPathComponent + " – Unified Diff – TurtleGit"
        } catch { if !retired && !token.isCancelled { owner.model.error = error.localizedDescription } }
    }
    func encodedBytes() throws -> Data {
        guard let model = owner?.model else { return Data() }
        if !model.documentDirty { return model.exportDocument.bytes }
        let original = model.savedDocumentBytes
        let signatures: [([UInt8], String.Encoding)] = [([0xff,0xfe,0,0], .utf32LittleEndian), ([0,0,0xfe,0xff], .utf32BigEndian), ([0xff,0xfe], .utf16LittleEndian), ([0xfe,0xff], .utf16BigEndian), ([0xef,0xbb,0xbf], .utf8)]
        var prefix = Data(), encoding: String.Encoding = String(data: original, encoding: .utf8) == nil ? .windowsCP1252 : .utf8
        for (signature, candidate) in signatures where original.starts(with: signature) { prefix = Data(signature); encoding = candidate; break }
        guard let body = model.document.text.data(using: encoding, allowLossyConversion: false) else { throw Failure.encoding }
        prefix.append(body); return prefix
    }
    func save(as newFile: Bool = false) async -> Bool {
        guard !retired, let owner, !owner.model.busy, let window = owner.window, window.attachedSheet == nil else { return false }
        Self.activeOperations += 1
        defer { Self.activeOperations -= 1 }
        let request = generation, snapshot: Data
        do { snapshot = try encodedBytes() } catch { owner.model.error = error.localizedDescription; return false }
        owner.model.busy = true
        defer { owner.model.busy = false }
        let target: URL?, access: RepositoryAccessLease?
        if newFile || fileURL == nil {
            target = await withCheckedContinuation { reply in chooseSave(window, fileURL?.lastPathComponent ?? "changes.patch") { reply.resume(returning: $0) } }
            guard !retired, let target else { return false }; access = acquireAccess(target)
        } else { target = fileURL; access = fileAccess }
        guard !retired, let target else { return false }
        if GitRuntime.isAppStoreBuild && access?.hasSecurityScope != true { owner.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return false }
        let expected = !newFile && target == fileURL ? diskBytes : nil, token = OperationCancellation()
        cancellation = token
        defer { withExtendedLifetime(access) {}; cancellation = nil }
        do {
            try await Task.detached {
                try token.check()
                if let expected, try Data(contentsOf: target) != expected { throw Failure.changed }
                try token.check(); try snapshot.write(to: target, options: .atomic)
            }.value
            guard !retired, generation == request, !token.isCancelled else { return false }
            fileURL = target; fileAccess = access; diskBytes = snapshot
            owner.model.markDocumentSaved(snapshot); owner.window?.representedURL = target
            return true
        } catch { if !retired && !token.isCancelled { owner.model.error = error.localizedDescription }; return false }
    }
    static func permitOwnerClose(_ documents: [PatchWindowController]) -> Bool {
        guard let child = documents.first(where: { $0.documentSession.dirty }) else { return true }
        child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
    }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1; cancellation?.cancel()
        if let window = owner?.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.close() }
        fileAccess = nil
    }
}
