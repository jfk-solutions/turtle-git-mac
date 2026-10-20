import Foundation
import AppKit
import SwiftUI
import TurtleGitCore

/// Native presentation of ProgressDlg::UpdateCmdOutput / UpdateProgressFromLine.
/// The parser owns producer bytes; this value owns the bounded visible log.
struct GitProgressOutputState {
    let presentation: GitCommandPresentation
    var limit: Int { presentation.outputLimit }
    private var bytes = Data(), truncated = false
    private(set) var output = "", currentWork = ""
    private(set) var percentage: Int?
    var hasOutput: Bool { !bytes.isEmpty }
    init(preferences: UserDefaults) {
        presentation = GitCommandPresentation(defaults: preferences)
    }
    mutating func presentFailure(_ error:Error,context:String="") {
        output=GitProgressFailureOutput.render(error,existing:output,limit:limit,context:context)
        percentage=nil
        if let failure=error as? GitFailure {currentWork=failure.summary}
        else if error is GitCommandCancellationFailure {currentWork="Operation cancelled."}
    }
    mutating func reset() { bytes.removeAll(); truncated = false; output = ""; currentWork = ""; percentage = nil }
    mutating func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !truncated else { return }
        if emission.erasePreviousLineBytes > 0 { bytes.removeLast(min(bytes.count, emission.erasePreviousLineBytes)) }
        let available = max(0, limit - bytes.count), clipped = emission.data.count > available
        bytes.append(emission.data.prefix(available))
        if clipped {
            // Do not leave the beginning of a UTF-8 scalar at the cut boundary.
            let tail = Array(bytes.suffix(4)); var cursor = tail.count - 1
            while cursor > 0 && tail[cursor] & 0xC0 == 0x80 { cursor -= 1 }
            if cursor >= 0 {
                let lead = tail[cursor]
                let expected = lead >= 0xF0 && lead <= 0xF4 ? 4 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xC2 && lead <= 0xDF ? 2 : 1
                if expected > tail.count - cursor { bytes.removeLast(tail.count - cursor) }
            }
        }
        output = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}\\[[0-9;]*m|\u{1b}\\[K", with: "", options: .regularExpression)
        for line in String(decoding: emission.data, as: UTF8.self).split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":"), let percent = line.firstIndex(of: "%") else { continue }
            currentWork = String(line[..<colon])
            let digits = line[..<percent].reversed().prefix { $0.isASCII && $0.isNumber }.reversed()
            if let value = Int(String(digits)), value > 0 { percentage = min(value, 100) }
        }
        if emission.limited || clipped || bytes.count >= limit {
            truncated = true; parser.activateDropMode()
            currentWork = "[Output truncated at about \(bytes.count / 1024) KiB]"; percentage = nil
            output += "\n\n...\n" + currentWork
        }
    }
}


/// One producer/consumer lifetime for local command dialogs. Result strings stay
/// original for repository callbacks; only presentation is bounded/CR-normalized.
@MainActor enum LocalGitCommandProgress {
    private(set) static var activeOperations = 0
    private static let finderOwner=UUID()
    static func begin() { activeOperations += 1;FinderCommandStatusActivity.update(finderOwner,active:true) }
    static func end() { activeOperations -= 1;if activeOperations==0 { FinderCommandStatusActivity.update(finderOwner,active:false) } }
    static func stream<T>(preferences: UserDefaults, update: @escaping (GitProgressOutputState) -> Void,
                          resultText: @escaping (T) -> String,
                          operation: @escaping (@escaping @Sendable (GitOutputChunk) -> Void) async throws -> T) async throws -> T {
        let dockOwner = UUID()
        DockProgressRegistry.shared.update(dockOwner, DockProgressState(.running))
        defer { DockProgressRegistry.shared.remove(dockOwner) }
        var state = GitProgressOutputState(preferences: preferences)
        let parser = GitCliOutputParser(limit: state.limit)
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            defer { continuation.finish() }
            return try await operation { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
        }
        for await _ in updates { state.consume(parser.processPending(), parser: parser); DockProgressRegistry.shared.update(dockOwner, DockProgressState(.running, percentage: state.percentage)); update(state) }
        state.consume(parser.processPending(), parser: parser); state.consume(parser.finish(), parser: parser); update(state)
        let result:T
        do {result=try await worker.value}
        catch let failure as GitFailure {
            state.presentFailure(failure);update(state)
            throw failure.markingOutputDelivered()
        } catch let failure as GitCommandCancellationFailure {
            state.presentFailure(failure);update(state)
            throw failure.markingOutputDelivered()
        }
        if state.output.isEmpty {
            let fallback = GitCliOutputParser(limit: state.limit)
            fallback.appendChunk(Data(resultText(result).utf8))
            state.consume(fallback.processPending(), parser: fallback); state.consume(fallback.finish(), parser: fallback); update(state)
        }
        return result
    }
    static func bounded(_ text: String, preferences: UserDefaults) -> String {
        var state = GitProgressOutputState(preferences: preferences); let parser = GitCliOutputParser(limit: state.limit)
        parser.appendChunk(Data(text.utf8)); state.consume(parser.processPending(), parser: parser); state.consume(parser.finish(), parser: parser)
        return state.output
    }
    static func failure(_ error: Error, existing: String, preferences: UserDefaults) -> String {
        if !existing.isEmpty {
            if let failure=error as? GitFailure,failure.outputWasDelivered {return existing}
            if let failure=error as? GitCommandCancellationFailure,failure.outputWasDelivered {return existing}
        }
        return GitProgressFailureOutput.render(error,existing:existing,limit:GitCommandPresentation(defaults:preferences).outputLimit)
    }
}


struct LocalGitProgressIndicator: View {
    let percentage: Int?
    var animate = true
    var body: some View {
        if let percentage { ProgressView(value: Double(percentage), total: 100).frame(width: 130) }
        else { GitCommandActivity(animate: animate) }
    }
}

/// DownloadAnimation controls the decorative activity animation, independently
/// of numeric progress, running status, output and cancellation controls.
struct GitCommandActivity: NSViewRepresentable {
    let animate: Bool
    func makeNSView(context: Context) -> GitCommandActivityView { GitCommandActivityView(frame: NSRect(x: 0, y: 0, width: 16, height: 16)) }
    func updateNSView(_ view: GitCommandActivityView, context: Context) { view.setAnimating(animate) }
}
final class GitCommandActivityView: NSView {
    let indicator = NSProgressIndicator()
    private let icon = NSImageView()
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        indicator.style = .spinning; indicator.controlSize = .small; indicator.isIndeterminate = true
        icon.image = MenuIcon.refresh.image(size: 14); icon.imageScaling = .scaleProportionallyDown
        for view in [indicator as NSView, icon] { view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view) }
        setAccessibilityElement(true); setAccessibilityLabel("Operation in progress")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setAnimating(_ enabled: Bool) {
        indicator.isHidden = !enabled; icon.isHidden = enabled
        if enabled { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
    }
}
struct GitCommandProgressBar: View {
    let percentage: Int?
    let animate: Bool
    var body: some View {
        Group {
            if let percentage { ProgressView(value: Double(percentage), total: 100) }
            else if animate { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: 0, total: 100).accessibilityValue("Running; progress unknown") }
        }
    }
}

/// One Dock tile represents the application's independently owned Git windows.
/// A retained error wins; running work wins over a separate paused session.
struct DockProgressState: Equatable {
    enum Kind: Int { case running, paused, failed }
    let kind: Kind
    let percentage: Int?
    init(_ kind: Kind, percentage: Int? = nil) {
        self.kind = kind; self.percentage = percentage.map { min(100, max(0, $0)) }
    }
    static func command(busy: Bool, success: Bool, waiting: Bool = false, percentage: Int?) -> Self? {
        if busy { return Self(waiting ? .paused : .running, percentage: percentage) }
        return success ? nil : Self(.failed, percentage: 100)
    }
    var accessibilityText: String {
        let title = kind == .failed ? "Git command failed" : kind == .paused ? "Git command waiting" : "Git command running"
        return title + (percentage.map { ", \($0) percent" } ?? "")
    }
}

@MainActor final class DockProgressRegistry {
    static let shared:DockProgressRegistry = {
        let registry=DockProgressRegistry { DockProgressPresenter.shared.present($0) }
        let owner=registry.finderOwner
        registry.commandActivity={ FinderCommandStatusActivity.update(owner,active:$0) }
        return registry
    }()
    private let finderOwner=UUID()
    var commandActivity:((Bool)->Void)?
    private var entries: [UUID: DockProgressState] = [:]
    private(set) var current: DockProgressState?
    var presentation: (DockProgressState?) -> Void
    init(presentation: @escaping (DockProgressState?) -> Void) { self.presentation = presentation }
    var ownerCount: Int { entries.count }
    func update(_ owner: UUID, _ value: DockProgressState?) {
        entries[owner] = value; publish()
    }
    func remove(_ owner: UUID) { entries.removeValue(forKey: owner); publish() }
    private func publish() {
        let values = Array(entries.values)
        commandActivity?(values.contains { $0.kind == .running || $0.kind == .paused })
        let kind: DockProgressState.Kind? = values.contains { $0.kind == .failed } ? .failed : values.contains { $0.kind == .running } ? .running : values.isEmpty ? nil : .paused
        let matching = values.filter { $0.kind == kind }
        let value = kind.map { DockProgressState($0, percentage: matching.contains { $0.percentage == nil } ? nil : matching.compactMap(\.percentage).min()) }
        guard value != current else { return }; current = value; presentation(value)
    }
}

/// An app-wide command lease survives individual progress updates and combines
/// explicit work counters with remote/Commit Dock progress. A retained error
/// does not block status after work has ended. Ordinary windows own no lease.
@MainActor enum FinderCommandStatusActivity {
    private static var owners=Set<UUID>()
    private static var lease:FinderStatusOperationLease?
    static var acquire:() throws -> FinderStatusOperationLease? = { try FinderStatusOperationLease.begin() }
    private(set) static var failure:String?
    static var activeOwnerCount:Int { owners.count }
    static func update(_ owner:UUID,active:Bool) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
        if owners.isEmpty { lease?.end();lease=nil;failure=nil }
        else if lease==nil {
            do { lease=try acquire();failure=nil }
            catch { failure=error.localizedDescription }
        }
    }
}

/// Native attachment follows the actual view lifetime, including sheet teardown.
/// Dismantled coordinators cannot recreate a retired Dock entry.
struct DockProgressAttachment: NSViewRepresentable {
    let value: DockProgressState?
    var registry: DockProgressRegistry = .shared
    func makeCoordinator() -> Coordinator { Coordinator(registry: registry) }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero); probe.coordinator = context.coordinator
        context.coordinator.update(value); return probe
    }
    func updateNSView(_ view: Probe, context: Context) { context.coordinator.update(value) }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.retire() }
    @MainActor final class Probe: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(window) }
    }
    @MainActor final class Coordinator {
        let registry: DockProgressRegistry
        private let owner = UUID()
        private var retired = false
        private var value: DockProgressState?
        private weak var window: NSWindow?
        private var observation: NSObjectProtocol?
        init(registry: DockProgressRegistry) { self.registry = registry }
        func update(_ value: DockProgressState?) {
            guard !retired else { return }; self.value = value
            registry.update(owner, window == nil ? nil : value)
        }
        func attach(_ window: NSWindow?) {
            guard !retired else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
            self.window = window
            if let window {
                observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retire() }
                }
            }
            registry.update(owner, window == nil ? nil : value)
        }
        func retire() {
            guard !retired else { return }; retired = true
            if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
            registry.remove(owner)
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
extension View {
    func gitDockProgress(_ value: DockProgressState?) -> some View {
        background(DockProgressAttachment(value: value).frame(width: 0, height: 0))
    }
}

/// Replaces only this app's Dock content while progress exists; restores any
/// previous custom content and leaves badge labels untouched.
@MainActor final class DockProgressPresenter: NSObject {
    static let shared = DockProgressPresenter(
        read: { NSApp.dockTile.contentView }, write: { NSApp.dockTile.contentView = $0 },
        display: { NSApp.dockTile.display() }, icon: { NSApp.applicationIconImage }, size: { NSApp.dockTile.size },
        allowed: { NSApp.activationPolicy() == .regular },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
    private let read: () -> NSView?, write: (NSView?) -> Void, display: () -> Void, icon: () -> NSImage?
    private let allowed: () -> Bool, reduceMotion: () -> Bool
    private let size: () -> NSSize
    private var previous: NSView?
    private(set) var tile: DockProgressTileView?
    private(set) var timer: Timer?
    init(read: @escaping () -> NSView?, write: @escaping (NSView?) -> Void, display: @escaping () -> Void,
         icon: @escaping () -> NSImage?, size: @escaping () -> NSSize = { NSSize(width: 128, height: 128) }, allowed: @escaping () -> Bool, reduceMotion: @escaping () -> Bool) {
        self.read = read; self.write = write; self.display = display; self.icon = icon
        self.allowed = allowed; self.reduceMotion = reduceMotion; self.size = size
    }
    func present(_ value: DockProgressState?) {
        guard let value, allowed() else { clear(); return }
        if tile == nil {
            previous = read()
            let view = DockProgressTileView(frame: NSRect(origin: .zero, size: size()))
            view.setAccessibilityElement(true); view.setAccessibilityRole(.progressIndicator)
            view.icon = icon(); tile = view; write(view)
        }
        tile?.state = value
        if value.kind == .running && value.percentage == nil && !reduceMotion() {
            if timer == nil {
                let next = Timer(timeInterval: 0.12, target: self, selector: #selector(advance), userInfo: nil, repeats: true)
                timer = next; RunLoop.main.add(next, forMode: .common)
            }
        } else { timer?.invalidate(); timer = nil }
        display()
    }
    @objc private func advance() {
        guard allowed(), let tile, read() === tile else { clear(); return }
        if reduceMotion() { timer?.invalidate(); timer = nil; tile.phase = 0 }
        else { tile.phase = (tile.phase + 0.08).truncatingRemainder(dividingBy: 1) }
        tile.needsDisplay = true; display()
    }
    func clear() {
        timer?.invalidate(); timer = nil
        if let tile, read() === tile { write(previous); display() }
        tile = nil; previous = nil
    }
}

@MainActor final class DockProgressTileView: NSView {
    var icon: NSImage?
    var state = DockProgressState(.running) { didSet { needsDisplay = true; setAccessibilityLabel(state.accessibilityText) } }
    var phase: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.11, y: bounds.height * 0.08, width: bounds.width * 0.78, height: bounds.height * 0.115)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let interior = bar.insetBy(dx: 2, dy: 2)
        let color: NSColor = state.kind == .failed ? .systemRed : state.kind == .paused ? .systemYellow : .systemGreen
        color.setFill()
        let fill: NSRect
        if let value = state.percentage { fill = NSRect(x: interior.minX, y: interior.minY, width: interior.width * CGFloat(value) / 100, height: interior.height) }
        else { fill = NSRect(x: interior.minX + (interior.width * 0.65) * phase, y: interior.minY, width: interior.width * 0.35, height: interior.height) }
        NSBezierPath(roundedRect: fill, xRadius: interior.height / 2, yRadius: interior.height / 2).fill()
        // A symbol keeps waiting/error states distinguishable without color.
        if state.kind != .running {
            let mark = state.kind == .failed ? "!" : "Ⅱ"
            let text = NSAttributedString(string: mark, attributes: [.font: NSFont.boldSystemFont(ofSize: bounds.height * 0.24), .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -3])
            text.draw(at: NSPoint(x: bounds.width * 0.73, y: bounds.height * 0.20))
        }
    }
}


struct GitProgressFailureOutput {
    static func render(_ error:Error,existing:String,limit:Int,context:String="")->String {
        let detail:String,summary:String
        if let failure=error as? GitFailure {
            detail=failure.outputWasDelivered && !existing.isEmpty ? "":failure.diagnosticText
            summary=failure.summary
        } else if let failure=error as? GitCommandCancellationFailure {
            detail=failure.outputWasDelivered && !existing.isEmpty ? "":String(decoding:failure.result.stderr.isEmpty ? failure.result.stdout:failure.result.stderr,as:UTF8.self)
            summary=failure.localizedDescription
        } else {detail=error.localizedDescription;summary=""}
        return renderDetails(detail,existing:existing,limit:limit,status:[context,summary].filter{!$0.isEmpty}.joined(separator:"\n"))
    }
    static func renderDetails(_ detail:String,existing:String,limit:Int,status:String="",preferTail:Bool=false)->String {
        let limit=max(256,limit),status=clip(status,bytes:512),reserve=128+status.utf8.count
        let budget=max(0,limit-reserve)
        let raw=clip(detail,bytes:budget,tail:preferTail),normalized=normalize(raw,limit:limit)
        let detailBudget=existing.isEmpty ? budget:min(normalized.utf8.count,budget/2)
        let shownDetail=clip(normalized,bytes:detailBudget,tail:preferTail)
        let shownExisting=clip(existing,bytes:max(0,budget-shownDetail.utf8.count))
        var parts=[shownExisting,shownDetail].filter{!$0.isEmpty}
        if shownExisting.utf8.count<existing.utf8.count || shownDetail.utf8.count<normalized.utf8.count || raw.utf8.count<detail.utf8.count {
            parts.append("[Output truncated at about \(limit/1024) KiB]")
        }
        if !status.isEmpty {parts.append(status)}
        return parts.joined(separator:"\n")
    }
    private static func normalize(_ text:String,limit:Int)->String {
        guard !text.isEmpty else{return ""}
        let parser=GitCliOutputParser(limit:limit);parser.appendChunk(Data(text.utf8))
        let first=parser.processPending(),last=parser.finish();var bytes=first.data
        bytes.removeLast(min(bytes.count,last.erasePreviousLineBytes));bytes.append(last.data)
        return String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"\u{1b}\\[[0-9;]*m|\u{1b}\\[K",with:"",options:.regularExpression)
    }
    private static func clip(_ text:String,bytes limit:Int,tail:Bool=false)->String {
        let bytes=Data(text.utf8)
        guard bytes.count>limit else{return text}
        if tail {
            var start=bytes.count-limit
            while start<bytes.count,bytes[start]&0xc0==0x80 {start+=1}
            return String(decoding:bytes.dropFirst(start),as:UTF8.self)
        }
        var end=max(0,limit)
        while end>0,bytes[end]&0xc0==0x80 {end-=1}
        return String(decoding:bytes.prefix(end),as:UTF8.self)
    }
}
