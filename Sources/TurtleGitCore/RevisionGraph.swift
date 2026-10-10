// Adapted from TortoiseGit CRevisionGraphWnd::FetchRevisionData.
// Copyright (C) 2003-2011 TortoiseSVN; 2012-2023, 2025-2026 TortoiseGit.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The two branch checkboxes and From/To fields of IDD_REVGRAPHFILTER.
public struct RevisionGraphOptions: Sendable {
    public var from = ""
    public var to = ""
    public var onlyCurrentBranch = false
    public var onlyLocalBranches = false
    public var showBranchingsAndMerges = false
    public var showAllTags = true
    public var showSuperprojectPointers = true
    public init() {}
}

public struct RevisionGraphNode: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    /// Simplified graph edges, not the commit object's original parent list.
    public var parents: [String]
    public var references: [RevisionReference]
    public var isHead: Bool
    /// An excluded parent is still drawn, without expanding its own ancestry.
    public var isBoundary: Bool
    public let author: String
    public let authorDate: String
    public let message: String
    public init(hash: String, parents: [String] = [], references: [RevisionReference] = [], isHead: Bool = false, isBoundary: Bool = false, author: String = "", authorDate: String = "", message: String = "") {
        self.hash = hash; self.parents = parents; self.references = references
        self.isHead = isHead; self.isBoundary = isBoundary
        self.author = author; self.authorDate = authorDate; self.message = message
    }
}

public struct RevisionGraphData: Sendable {
    public let nodes: [RevisionGraphNode]
    public let head: String?
    public let superprojectLabels: [String: [String]]
    public var superprojectHashes: Set<String> { Set(superprojectLabels.keys) }

    /// Port the source's ordered child-map rewrite. A node immediately before a
    /// merge is deliberately retained, even when it has only one child.
    public static func simplify(_ input: [RevisionGraphNode], showAllTags: Bool, showBranchingsAndMerges: Bool, protectedHashes: Set<String> = [], cancellation: OperationCancellation? = nil) throws -> [RevisionGraphNode] {
        try cancellation?.check()
        guard !showAllTags || showBranchingsAndMerges else { return input }
        var nodes = input
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.hash, $0.offset) })
        var children: [String: [String]] = [:]
        for node in nodes {
            try cancellation?.check()
            for parent in node.parents { children[parent, default: []].append(node.hash) }
        }
        var skipped = Set<String>()
        for index in nodes.indices {
            try cancellation?.check()
            let node = nodes[index]
            if protectedHashes.contains(node.hash) { continue }
            if !node.references.isEmpty {
                if showAllTags { continue }
                let hasNonTag = node.references.contains {
                    let kind = $0.kind ?? HistoryReferenceLabel.shortName($0.name).kind
                    return kind != .tag && kind != .annotatedTag
                }
                if hasNonTag { continue }
            }
            guard node.parents.count == 1, let childHashes = children[node.hash], childHashes.count == 1,
                  let childIndex = indices[childHashes[0]], nodes[childIndex].parents.count == 1 else { continue }
            skipped.insert(node.hash)
            nodes[childIndex].parents[0] = node.parents[0]
            if let offset = children[node.parents[0]]?.firstIndex(of: node.hash) {
                children[node.parents[0]]?[offset] = childHashes[0]
            }
            children.removeValue(forKey: node.hash)
        }
        return nodes.filter { !skipped.contains($0.hash) }
    }
}

extension GitRepository {
    /// A separate unlimited decoration-simplified walk; Log's row limit and path
    /// filters must not change the Revision Graph's topology.
    public func revisionGraph(options: RevisionGraphOptions = RevisionGraphOptions(), cancellation: OperationCancellation? = nil) async throws -> RevisionGraphData {
        func read(_ arguments: [String], codes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(arguments, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: codes, cancellation: cancellation)
        }
        func tokens(_ text: String) -> [String] {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        }
        func resolve(_ text: String) throws -> String {
            try read(["rev-parse", "--verify", "--end-of-options", text + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        }
        try cancellation?.check()
        let headResult = try read(["rev-parse", "--verify", "--quiet", "HEAD"], codes: 0...1)
        let head = headResult.exitCode == 0 ? headResult.text.trimmingCharacters(in: .newlines) : nil
        let branchResult = try read(["symbolic-ref", "--quiet", "HEAD"], codes: 0...1)
        let currentBranch = branchResult.exitCode == 0 ? branchResult.text.trimmingCharacters(in: .newlines) : nil
        let rawRefs = try read(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00"]).text.components(separatedBy: "\0")
        var refs: [String: [RevisionReference]] = [:]
        var i = 0
        while i + 2 < rawRefs.count {
            try cancellation?.check()
            let hash = (rawRefs[i + 1].isEmpty ? rawRefs[i] : rawRefs[i + 1]).trimmingCharacters(in: .newlines)
            let name = rawRefs[i + 2]
            let kind: HistoryReferenceKind = name.hasPrefix("refs/tags/") && !rawRefs[i + 1].isEmpty ? .annotatedTag : HistoryReferenceLabel.shortName(name).kind
            refs[hash, default: []].append(RevisionReference(name: name, isCurrent: currentBranch.map { GitReferenceName.equal($0, name) } ?? false, kind: kind))
            i += 3
        }
        var arguments = ["log", "--encoding=UTF-8", "--format=%H%x00%P%x00%an%x00%aI%x00%B%x00", "--topo-order", "--parents", "--simplify-by-decoration"]
        if options.showBranchingsAndMerges { arguments.append("--sparse") }
        // Upstream gives Only Local Branches precedence if both flags are set.
        if options.onlyLocalBranches { arguments.append("--branches") }
        else if options.onlyCurrentBranch {
            guard let head else { return RevisionGraphData(nodes: [], head: nil, superprojectLabels: [:]) }
            arguments.append(head)
        } else if !tokens(options.to).isEmpty {
            arguments += try tokens(options.to).map { try resolve($0) }
        } else { arguments.append("--all") }
        arguments += try tokens(options.from).map { "^" + (try resolve($0)) }
        arguments.append("--")
        let output = try read(arguments).text
        var nodes: [RevisionGraphNode] = []
        let fields = output.components(separatedBy: "\0")
        var record = 0
        while record + 4 < fields.count {
            try cancellation?.check()
            let hash = fields[record].trimmingCharacters(in: .newlines)
            let parents = fields[record + 1].split(separator: " ").map(String.init)
            nodes.append(RevisionGraphNode(hash: hash, parents: parents, references: refs[hash] ?? [], isHead: hash == head, author: fields[record + 2], authorDate: fields[record + 3], message: fields[record + 4]))
            record += 5
        }
        var pointerLabels: [String: [String]] = [:]
        if options.showSuperprojectPointers {
            let parent = try read(["rev-parse", "--show-superproject-working-tree"]).text.trimmingCharacters(in: .newlines)
            if !parent.isEmpty {
                let parentURL = URL(fileURLWithPath: parent).standardizedFileURL
                let prefix = parentURL.path + "/"
                if root.path.hasPrefix(prefix) {
                    let path = String(root.path.dropFirst(prefix.count))
                    let superproject = GitRepository(root: parentURL, executable: executable)
                    let entries = try await superproject.run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
                    var stages: [(String, String)] = []
                    for record in entries.split(separator: 0) {
                        let header = record.split(separator: 9, maxSplits: 1).first?.split(separator: 32) ?? []
                        guard header.count == 3, header[0] == Data("160000".utf8) else { continue }
                        stages.append((String(decoding: header[2], as: UTF8.self), String(decoding: header[1], as: UTF8.self)))
                    }
                    var rebasing = false
                    if stages.contains(where: { $0.0 == "2" || $0.0 == "3" }) {
                        // Native Git also uses rebase-merge; resolve worktree-local
                        // admin paths rather than inspecting the submodule's state.
                        for name in ["rebase-apply", "rebase-merge", "tgitrebase.active"] {
                            var bytes = try await superproject.run(["rev-parse", "--git-path", name], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
                            if bytes.last == 10 { bytes.removeLast() }
                            let path = String(decoding: bytes, as: UTF8.self)
                            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : parentURL.appendingPathComponent(path)
                            var directory: ObjCBool = false
                            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { rebasing = true; break }
                        }
                    }
                    for (stage, hash) in stages {
                        let label: String
                        switch stage {
                        case "0": label = "super-project-pointer"
                        case "2": label = rebasing ? "super-project-rebase-head" : "super-project-head"
                        case "3": label = rebasing ? "super-project-head" : "super-project-merge-head"
                        default: continue // The ancestor (stage one) is not a pointer.
                        }
                        pointerLabels[hash, default: []].append(label)
                    }
                }
            }
        }
        nodes = try RevisionGraphData.simplify(nodes, showAllTags: options.showAllTags, showBranchingsAndMerges: options.showBranchingsAndMerges, protectedHashes: Set(pointerLabels.keys), cancellation: cancellation)
        // FetchRevisionData appends missing parents after rewriting. Its cache has
        // cleared parent lists for these placeholders, so they are terminal nodes.
        var known = Set(nodes.map(\.hash))
        for node in nodes {
            for parent in node.parents where known.insert(parent).inserted {
                try cancellation?.check()
                nodes.append(RevisionGraphNode(hash: parent, references: refs[parent] ?? [], isHead: parent == head, isBoundary: true))
            }
        }
        return RevisionGraphData(nodes: nodes, head: head, superprojectLabels: pointerLabels)
    }
}
