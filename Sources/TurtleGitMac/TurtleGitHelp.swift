// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Stable anchors shared by dialog Help, contextual keyboard help and the book.
enum TurtleGitHelpTopic: String, CaseIterable {
    case overview, clone, createRepository, workingTree, add, commit, log, reflog
    case browser, references, branchTag, checkout, fetch, pull, push, merge, resolve
    case rebase, cherryPick, stash, revert, reset, clean, submodules, worktrees
    case synchronization, ignore, lfs
    case patches, export, bisect, settings, finder, folderAccess, statistics
    case revisionGraph, blame, compare, images, unifiedDiff, svn, authentication
    case ssh, savedData, privacy, notes, moving, languages
}

@MainActor final class TurtleGitHelpService {
    struct Topic: Decodable {
        let id: String
        let document: String
        let fragment: String?
    }
    private struct Catalog: Decodable { let book_name: String; let bundle_id: String; let topics: [Topic] }
    let bundle: Bundle
    private(set) var bookURL: URL?
    private(set) var topics: [String: Topic] = [:]
    private(set) var bookName = "TurtleGit for Mac Help"
    private(set) var bookIdentifier = "org.turtlegit.macos.help"
    var registerBook: (Bundle) -> Bool = { NSHelpManager.shared.registerBooks(in: $0) }
    var openAnchor: (String, String) -> Void = { NSHelpManager.shared.openHelpAnchor($0, inBook: $1) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var registrationSucceeded = false
    init(bundle: Bundle) {
        self.bundle = bundle
        bookURL = bundle.url(forResource: "TurtleGitHelp", withExtension: "help")
        if let url = bookURL?.appendingPathComponent("Contents/Resources/en.lproj/topics.json"),
           let bytes = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: bytes) {
            bookName = catalog.book_name; bookIdentifier = catalog.bundle_id
            for topic in catalog.topics where TurtleGitHelpTopic(rawValue: topic.id) != nil && !topic.document.contains("/") && topic.document.hasSuffix(".md") {
                topics[topic.id] = topic
            }
        }
    }
    func localURL(for topic: TurtleGitHelpTopic) -> URL? {
        guard let bookURL, let entry = topics[topic.rawValue] else { return nil }
        let page = bookURL.appendingPathComponent("Contents/Resources/en.lproj").appendingPathComponent(String(entry.document.dropLast(3)) + ".html")
        guard FileManager.default.fileExists(atPath: page.path) else { return nil }
        var url = URLComponents(url: page, resolvingAgainstBaseURL: false)
        url?.fragment = entry.fragment
        return url?.url
    }
    func onlineURL(for topic: TurtleGitHelpTopic) -> URL {
        let entry = topics[topic.rawValue]
        let page = entry.map { String($0.document.dropLast(3)) } ?? "GETTING-STARTED"
        var url = URLComponents(string: "https://jfk-solutions.github.io/turtle-git-mac/manual/" + page + ".html")!
        url.fragment = entry?.fragment
        return url.url!
    }
    func show(_ topic: TurtleGitHelpTopic) {
        guard let local = localURL(for: topic) else { openURL(onlineURL(for: topic)); return }
        // The main app provides the registration metadata. SwiftPM and missing
        // registration retain the same offline content in the default browser.
        if bundle.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String == bookIdentifier {
            if !registrationSucceeded { registrationSucceeded = registerBook(bundle) }
            if registrationSucceeded { openAnchor("topic-" + topic.rawValue, bookIdentifier); return }
        }
        openURL(local)
    }
}

@MainActor enum TurtleGitHelp {
    static var service = TurtleGitHelpService(bundle: resourceBundle)
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
    private final class Binding {
        weak var window: NSWindow?
        let topic: TurtleGitHelpTopic
        init(_ window: NSWindow, _ topic: TurtleGitHelpTopic) { self.window = window; self.topic = topic }
    }
    private static var bindings: [ObjectIdentifier: Binding] = [:]
    private static var closeObserver: NSObjectProtocol?
    private static var keyMonitor: Any?
    static func install() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { _ = bindings.removeValue(forKey: ObjectIdentifier(window)) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handleHelpKey(event) }
            return handled ? nil : event
        }
    }
    static func attach(_ window: NSWindow?, topic: TurtleGitHelpTopic) {
        guard let window else { return }
        install()
        bindings = bindings.filter { $0.value.window != nil }
        bindings[ObjectIdentifier(window)] = Binding(window, topic)
    }
    static func context(_ window: NSWindow?) -> TurtleGitHelpTopic {
        var candidate = window, seen = Set<ObjectIdentifier>()
        while let current = candidate, seen.insert(ObjectIdentifier(current)).inserted {
            if let binding = bindings[ObjectIdentifier(current)], binding.window === current { return binding.topic }
            candidate = current.sheetParent ?? current.parent
        }
        return .overview
    }
    @discardableResult static func handleHelpKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, [UInt16(122), 114].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let window = event.window ?? NSApp.keyWindow
        guard let window, window.isVisible else { return false }
        show(context(window)); return true
    }
    static func show(_ topic: TurtleGitHelpTopic) { service.show(topic) }
    static func showContext() { show(context(NSApp.keyWindow ?? NSApp.mainWindow)) }
    static func topic(dialog: String) -> TurtleGitHelpTopic {
        let name = dialog.lowercased()
        if name.contains("lfs") { return .lfs }
        if name.contains("request pull") { return .patches }
        if name.contains("synchronization") { return .synchronization }
        if name.contains("ignore") { return .ignore }
        if name.contains("svn") { return .svn }
        if name.contains("cherry") { return .cherryPick }
        if name.contains("rebase") { return .rebase }
        if name.contains("reflog") { return .reflog }
        if name.hasPrefix("log") { return .log }
        if name.contains("commit") { return .commit }
        if name.contains("working tree") { return .workingTree }
        if name.contains("repository browser") { return .browser }
        if name.contains("reference") { return .references }
        if name.contains("revision graph") { return .revisionGraph }
        if name.contains("statistics") { return .statistics }
        if name.contains("worktree") { return .worktrees }
        if name.contains("submodule") { return .submodules }
        if name.contains("push") { return .push }
        if name.contains("pull") { return .pull }
        if name.contains("fetch") { return .fetch }
        if name.contains("stash") { return .stash }
        if name.contains("revert") { return .revert }
        if name.contains("reset") { return .reset }
        if name.contains("clean") { return .clean }
        if name.contains("merge") { return .merge }
        if name.contains("switch") { return .checkout }
        if name.contains("branch") || name.contains("tag") { return .branchTag }
        if name.contains("resolve") { return .resolve }
        if name.contains("bisect") { return .bisect }
        if name.contains("export") { return .export }
        if name.contains("patch") || name.contains("send email") || name.contains("request pull") { return .patches }
        if name.contains("unified diff") { return .unifiedDiff }
        if name.contains("changed files") { return .compare }
        if name == "add" { return .add }
        if name.contains("copy") || name.contains("move") { return .moving }
        return .overview
    }
    static func settingsTopic(_ page: SettingsPageID) -> TurtleGitHelpTopic {
        switch page {
        case .overlays, .overlayHandlers, .overlayIcons, .contextMenu, .contextMenu2: return .finder
        case .savedData: return .savedData
        case .credential: return .authentication
        case .network: return .ssh
        case .unifiedDiff: return .unifiedDiff
        case .diff, .mergeTool, .mergeEditor, .mergeColors: return .compare
        case .blame: return .blame
        default: return .settings
        }
    }
}
