// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@MainActor @main enum MetafileMaskedTransfersVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Sample { let x: Int, y: Int, red: Int, green: Int, blue: Int }
    static func require(_ value: Bool, _ message: String, line: Int = #line) throws { if !value { throw Failure(message: "\(line): " + message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Masked metafile native workflow did not settle at \(line)")
    }
    static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
    static func drained() -> Bool { FileListComparisonSession.activeOperations == 0 && ImageConflictWindowModel.activeOperations == 0 && ImageComparisonViewModel.activeFileReads == 0 && ImageLoadWindowController.activeReleases == 0 }
    static func pixel(_ image: ComparisonImage?, _ samples: [Sample], _ label: String) throws {
        guard let image else { throw Failure(message: "Missing actual decoded image " + label) }
        let width = image.pixels.width, height = image.pixels.height
        try require(width == 64 && height == 64, "Incorrect actual helper canvas " + label)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure(message: "Could not inspect helper pixels") }
            context.interpolationQuality = .none; context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for sample in samples {
            let offset = (sample.y * width + sample.x) * 4
            let actual = Array(bytes[offset..<(offset + 4)]), expected = [sample.red, sample.green, sample.blue]
            try require((0..<3).allSatisfy { abs(Int(actual[$0]) - expected[$0]) <= 1 } && actual[3] == 255,
                "\(label) pixel(\(sample.x),\(sample.y)) expected \(expected)+opaque, actual \(actual)")
        }
    }
    static let mask = [Sample(x: 16, y: 16, red: 255, green: 0, blue: 0), Sample(x: 32, y: 16, red: 0, green: 0, blue: 255), Sample(x: 4, y: 4, red: 0, green: 0, blue: 255)]
    static let transparent = [Sample(x: 16, y: 16, red: 0, green: 0, blue: 255), Sample(x: 32, y: 16, red: 0, green: 255, blue: 0), Sample(x: 4, y: 4, red: 0, green: 0, blue: 255)]
    // Independent premultiplied source-over: red128/255 over blue255 yields
    // (128,0,127), not straight-alpha red64 or uncomposited transparent bytes.
    static let alpha = [Sample(x: 16, y: 16, red: 128, green: 0, blue: 127), Sample(x: 4, y: 4, red: 0, green: 0, blue: 255)]
    // P=F0,S=CC,D=AA independently enumerate all eight truth-table input
    // rows in one byte. Every foreground byte n and background byte 255-n
    // must survive the opposite monochrome mask halves of its original cell.
    static let rop4: [Sample] = {
        var result: [Sample] = []
        for truth in 0..<256 {
            let x = (truth % 16) * 4, y = (truth / 16) * 4 + 2, inverse = 255 - truth
            result.append(Sample(x: x + 1, y: y, red: truth, green: truth, blue: truth))
            result.append(Sample(x: x + 3, y: y, red: inverse, green: inverse, blue: inverse))
        }
        return result
    }()
    static let shear = [Sample(x: 14, y: 24, red: 255, green: 0, blue: 0), Sample(x: 18, y: 25, red: 0, green: 0, blue: 255), Sample(x: 34, y: 28, red: 0, green: 0, blue: 255)]
    @MainActor final class Context {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), corpus = URL(fileURLWithPath: CommandLine.arguments[3])
        let suite: String, preferences: UserDefaults
        var owners: [NSWindowController] = [], inputs: [URL: Data] = [:], release: [() -> Void] = []
        init() { suite = "TurtleGit.MaskedMetafile.QA." + UUID().uuidString; preferences = UserDefaults(suiteName: suite)!; DialogGeometry.install(preferences: preferences) }
        func file(_ name: String) throws -> URL { let url = corpus.appendingPathComponent(name); inputs[url] = try Data(contentsOf: url); return url }
        func track<T: NSWindowController>(_ owner: T) -> T { owners.append(owner); owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); owner.showWindow(nil); return owner }
        func unchanged() throws { for (url, bytes) in inputs { let actual = try Data(contentsOf: url); try require(actual == bytes, "Actual helper rewrote original metafile " + url.lastPathComponent) } }
        func cleanup() async {
            owners.forEach { $0.close() }; release.forEach { $0() }; release = []
            for window in NSApp.windows { if let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }; window.close() }
            for _ in 0..<3000 { if drained() { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            owners.forEach { $0.window?.orderOut(nil) }; preferences.removePersistentDomain(forName: suite); DialogGeometry.install(preferences: .standard)
        }
    }
    static func run(_ body: (Context) async throws -> Void) async throws {
        let context = Context()
        do { try await body(context); try context.unchanged(); await context.cleanup(); try require(drained(), "Actual masked metafile consumers did not drain") }
        catch { await context.cleanup(); throw error }
    }
    static func consumers() async throws { try await run { context in
        // These are original source record fixtures, never a substituted image
        // protocol. Native IDiff must invoke the actual bundled metafile helper.
        for (leftName, rightName, leftSamples, rightSamples) in [
            ("classic-maskblt-copy.emf", "classic-transparentblt-key.emf", mask, transparent),
            ("classic-alphablend-pixel.emf", "classic-maskblt-copy.emf", alpha, mask),
            ("classic-maskblt-matrix.emf", "classic-plgblt-mask-shear.emf", rop4, shear),
            ("classic-maskblt-swapped-palette.emf", "classic-maskblt-copy.emf", mask, mask),
        ] {
            let left = try context.file(leftName), right = try context.file(rightName)
            let owner = context.track(FileComparisonWindowController(images: try ImageFileComparison(base: left, destination: right), permissions: [], preferences: context.preferences))
            owner.model.load()
            try await wait { owner.window?.contentView?.layoutSubtreeIfNeeded(); return !owner.model.busy && owner.model.document != nil && views(owner.window?.contentView).filter { $0 is ImageComparisonScrollView }.count == 2 }
            try require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff") == true, "Masked transfer fell back from native image panes: \(owner.model.error ?? "none")")
            try pixel(owner.model.imageComparison?.base, leftSamples, leftName); try pixel(owner.model.imageComparison?.destination, rightSamples, rightName)
            try require(owner.model.document?.base.bytes == context.inputs[left] && owner.model.document?.destination.bytes == context.inputs[right], "Comparison replaced original record bytes with rendered PNG")
            owner.close(); try await wait { FileListComparisonSession.activeOperations == 0 }
        }
        let refused = try context.file("unsupported-transfer-alpha-premultiplication.emf")
        let invalid = context.track(FileComparisonWindowController(images: try ImageFileComparison(base: refused, destination: nil), permissions: [], preferences: context.preferences))
        invalid.model.load(); try await wait { !invalid.model.busy && invalid.model.document != nil }
        try require(invalid.model.viewerSelection == .image && invalid.model.imageComparison?.base == nil && invalid.model.document?.base.bytes == context.inputs[refused], "Malformed premultiplied-alpha record lost explicit image failure/original bytes")
        invalid.close()
        // Hold the receipt only after the real helper has returned its pixels.
        let source = try context.file("classic-maskblt-copy.emf")
        let late = context.track(FileComparisonWindowController(comparison: try WorkingFileComparison(base: source, destination: source), permissions: [], preferences: context.preferences, deferInitialLoad: true))
        let decode = late.model.decodeImages
        var reply: CheckedContinuation<Void, Never>?, token: OperationCancellation?
        late.model.decodeImages = { document, request in
            let actual = try await decode(document, request); token = request
            await withCheckedContinuation { reply = $0 }; return actual
        }
        context.release.append { reply?.resume(); reply = nil }
        late.model.beginTransferredDocument(); try await wait { reply != nil }
        late.close()
        try require(token?.isCancelled == true && FileListComparisonSession.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Closed masked decode lost cancellation/worker/Quit ownership")
        reply?.resume(); reply = nil
        try await wait { FileListComparisonSession.activeOperations == 0 && !late.model.busy }
        try require(late.model.document == nil && late.model.imageComparison == nil, "Closed masked decoder published late pixels")
    } }
    static func conflict() async throws { try await run { context in
        let baseURL = try context.file("classic-maskblt-copy.emf"), theirsURL = try context.file("classic-transparentblt-key.emf"), mineURL = try context.file("classic-alphablend-pixel.emf")
        let base = try Data(contentsOf: baseURL), theirs = try Data(contentsOf: theirsURL), mine = try Data(contentsOf: mineURL)
        let directory = context.root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = GitRepository(root: directory, executable: context.git), path = "drawing [m]; 雪.emf", file = directory.appendingPathComponent(path)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Masked image QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] { _ = try await repository.run(["config", key, value]) }
        try base.write(to: file); try await repository.stage([path]); _ = try await repository.commit(message: "masked base")
        _ = try await repository.run(["switch", "-c", "side"])
        try theirs.write(to: file); try await repository.stage([path]); _ = try await repository.commit(message: "transparent theirs")
        _ = try await repository.run(["switch", "main"])
        try mine.write(to: file); try await repository.stage([path]); _ = try await repository.commit(message: "alpha mine")
        do { _ = try await repository.run(["merge", "--no-edit", "side"]); throw Failure(message: "Expected actual binary metafile conflict") }
        catch is GitFailure {}
        guard let document = try await repository.imageConflictDocument(path: path) else { throw Failure(message: "Masked conflict did not discover actual image stages") }
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: directory.appendingPathComponent(".git/index")), working = try Data(contentsOf: file)
        let mergeHead = try Data(contentsOf: directory.appendingPathComponent(".git/MERGE_HEAD"))
        let owner = context.track(ImageConflictWindowController(repository: repository, access: nil, document: document, preferences: context.preferences))
        try await wait { owner.window?.contentView?.layoutSubtreeIfNeeded(); return !owner.model.busy && owner.model.images.count == 3 && views(owner.window?.contentView).filter { $0 is ImageComparisonScrollView }.count == 3 }
        try require(ImageConflictSide.allCases.allSatisfy { owner.model.canSelect($0) }, "One masked transfer stage lost selectable native image routing")
        try pixel(owner.model.panes[.base]?.currentImage(base: true), mask, "mask conflict base")
        try pixel(owner.model.panes[.theirs]?.currentImage(base: true), transparent, "transparent conflict theirs")
        try pixel(owner.model.panes[.mine]?.currentImage(base: true), alpha, "alpha conflict mine")
        try require(owner.model.document.contents[.base] == base && owner.model.document.contents[.theirs] == theirs && owner.model.document.contents[.mine] == mine, "Conflict decoded pixels replaced original Git stage bytes")
        let ids = owner.model.images.mapValues(\.id), decode = owner.model.decodeImages
        var reply: CheckedContinuation<Void, Never>?, token: OperationCancellation?
        owner.model.decodeImages = { document, request in
            let actual = try await decode(document, request); token = request
            await withCheckedContinuation { reply = $0 }; return actual
        }
        context.release.append { reply?.resume(); reply = nil }
        owner.model.reload(); try await wait { reply != nil }
        owner.close()
        try require(token?.isCancelled == true && owner.model.retired && ImageConflictWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Closed masked conflict released actual decode receipt/Quit ownership")
        reply?.resume(); reply = nil
        try await wait { ImageConflictWindowModel.activeOperations == 0 }
        try require(owner.model.images.mapValues(\.id) == ids, "Retired masked conflict published late panes")
        let previewHead = try await repository.run(["rev-parse", "HEAD"]).stdout, previewIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index")), previewWorking = try Data(contentsOf: file)
        try require(previewHead == head && previewIndex == index && previewWorking == working, "Masked preview/cancel changed Git HEAD/index/worktree")
        // An explicit accepted resolution must write/stage original metafile
        // bytes, never the PNG used for displaying the same selected stage.
        let accepted = context.track(ImageConflictWindowController(repository: repository, access: nil, document: document, preferences: context.preferences))
        accepted.model.askMarkResolved = { _ in true }
        try await wait { !accepted.model.busy && accepted.model.images.count == 3 }
        accepted.model.select(.theirs)
        try await wait { !accepted.model.busy && ImageConflictWindowModel.activeOperations == 0 }
        let selectedBytes = try Data(contentsOf: file), staged = try await repository.run(["show", ":" + path]).stdout
        let unmerged = try await repository.run(["ls-files", "--unmerged", "--", path]).stdout
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout, afterMerge = try Data(contentsOf: directory.appendingPathComponent(".git/MERGE_HEAD"))
        try require(accepted.model.error == nil && selectedBytes == theirs && staged == theirs && unmerged.isEmpty, "Accepted masked conflict failed exact original-byte resolution")
        try require(afterHead == head && afterMerge == mergeHead, "Selected masked side implicitly committed or cleared merge metadata")
        accepted.close()
    } }
    static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitMaskedMetafileOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden); defer { method_exchangeImplementations(original, hidden) }
        try await ComparisonToolInvocation.$alternate.withValue(false) {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_MASKED_METAFILE_CASE"] {
            case "consumers": try await consumers()
            case "conflict": try await conflict()
            default: throw Failure(message: "Unknown masked metafile case")
            }
        }
        print("PASS: masked metafile native case completed")
    }
}
private extension NSWindow {
    @objc func turtleGitMaskedMetafileOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        alphaValue = 0; setFrameOrigin(NSPoint(x: -20000, y: -20000))
        turtleGitMaskedMetafileOrder(place, relativeTo: otherWindowNumber)
    }
}
