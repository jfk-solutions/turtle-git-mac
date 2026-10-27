import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderPublicationTests:XCTestCase {
    func fixture() throws -> (URL,FinderSnapshotStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPublication-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return (root,FinderSnapshotStore(url:root.appendingPathComponent("status.json")))
    }
    func snapshot(_ root:URL,_ state:FileState) -> FinderSnapshot {
        FinderSnapshot(roots:[root.path],states:[root.path:state,root.appendingPathComponent("file").path:state],repositories:[root.path:FinderRepositoryMetadata()])
    }
    func testIndependentRootsMergeAndTicketsAreConsumedOnce() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let a=URL(fileURLWithPath:"/repo-a"),b=URL(fileURLWithPath:"/repo-b")
        let ticketA=try store.begin(root:a),ticketB=try store.begin(root:b)
        XCTAssertTrue(try store.publish(ticketB,snapshots:[snapshot(b,.added)]).published)
        let result=try store.publish(ticketA,snapshots:[snapshot(a,.modified)])
        XCTAssertTrue(result.published);XCTAssertEqual(Set(result.snapshot.roots),[a.path,b.path])
        XCTAssertEqual(result.snapshot.states[b.appendingPathComponent("file").path],.added)
        let bytes=try Data(contentsOf:store.url)
        XCTAssertFalse(try store.publish(ticketA,snapshots:[snapshot(a,.normal)]).published)
        XCTAssertEqual(bytes,try Data(contentsOf:store.url))
    }
    func testSupersededAndOverlappingReadsCannotOverwriteFreshData() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),nested=root.appendingPathComponent("nested")
        let old=try store.begin(root:root),new=try store.begin(root:root)
        _ = try store.publish(new,snapshots:[snapshot(root,.conflicted)])
        XCTAssertFalse(try store.publish(old,snapshots:[snapshot(root,.normal)]).published)
        let parent=try store.begin(root:root),child=try store.begin(root:nested)
        _ = try store.publish(child,snapshots:[snapshot(nested,.modified)])
        XCTAssertFalse(try store.publish(parent,snapshots:[snapshot(root,.normal)]).published)
        let freshParent=try store.begin(root:root)
        let result=try store.publish(freshParent,snapshots:[snapshot(root,.normal)])
        XCTAssertTrue(result.published);XCTAssertEqual(result.snapshot.states[nested.appendingPathComponent("file").path],.modified)
    }
    func testRemovalInvalidatesReadsAndPreservesOtherRoots() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let a=URL(fileURLWithPath:"/repo-a"),b=URL(fileURLWithPath:"/repo-b")
        _ = try store.publish(store.begin(root:a),snapshots:[snapshot(a,.modified)])
        _ = try store.publish(store.begin(root:b),snapshots:[snapshot(b,.normal)])
        let pending=try store.begin(root:a),removed=try store.remove(root:a)
        XCTAssertEqual(removed.roots,[b.path]);XCTAssertFalse(try store.publish(pending,snapshots:[snapshot(a,.modified)]).published)
        XCTAssertFalse(try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.url)).roots.contains(a.path))
    }
    func testInvalidPayloadAndCorruptionNeverReplacePreviousSnapshot() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),ticket=try store.begin(root:root)
        _ = try store.publish(ticket,snapshots:[snapshot(root,.normal)])
        let original=try Data(contentsOf:store.url),fresh=try store.begin(root:root)
        let escaped=FinderSnapshot(roots:[root.path],states:["/other/file":.modified])
        XCTAssertThrowsError(try store.publish(fresh,snapshots:[escaped]));XCTAssertEqual(original,try Data(contentsOf:store.url))
        try Data("invalid json".utf8).write(to:store.url)
        XCTAssertThrowsError(try store.publish(fresh,snapshots:[snapshot(root,.modified)]));XCTAssertEqual(try Data(contentsOf:store.url),Data("invalid json".utf8))
    }
    func testLockCancellationAndForeignStoreTickets() async throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),ticket=try store.begin(root:root)
        let foreign=FinderSnapshotStore(url:folder.appendingPathComponent("foreign.json"));_ = try foreign.begin(root:root)
        XCTAssertFalse(try foreign.publish(ticket,snapshots:[snapshot(root,.normal)]).published)
        let descriptor=Darwin.open(store.url.path+".lock",O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor,0);defer { flock(descriptor,LOCK_UN);Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor,LOCK_EX),0)
        let token=OperationCancellation(),operation=Task.detached { try store.begin(root:root,cancellation:token) }
        try await Task.sleep(nanoseconds:30_000_000);token.cancel()
        do { _ = try await operation.value;XCTFail("Cancelled lock wait acquired a ticket") } catch OperationCancellationFailure.cancelled {}
    }
    private enum OverlappingField: String, CaseIterable {
        case states, repositories, overlayEntries, indexFlags, overlayPolicies
        func inserting(_ path: String, in value: FinderSnapshot) -> FinderSnapshot {
            var next = value
            switch self {
            case .states: next.states[path] = .conflicted
            case .repositories: next.repositories[path] = .init(mergeActive: true)
            case .overlayEntries: next.overlayEntries?[path] = .conflicted
            case .indexFlags: next.indexFlags?[path] = .init(skipWorktree: true)
            case .overlayPolicies: next.overlayPolicies[path] = .init(identity: "untrusted", caseSensitive: true)
            }
            return next
        }
    }
    private func overlappingSnapshot(_ root: String, state: FileState = .normal) -> FinderSnapshot {
        let file = root + "/file"
        return FinderSnapshot(roots: [root], states: [root: state, file: state],
                              repositories: [root: .init(), file: .init()],
                              overlayEntries: [root: state, file: state],
                              indexFlags: [root: .init(assumeUnchanged: true), file: .init(skipWorktree: true)],
                              overlayPolicies: [root: .init(identity: "accepted", caseSensitive: true),
                                                file: .init(identity: "accepted", caseSensitive: true)])
    }
    func testInvalidPathsInEveryOverlappingMapRejectWholePublicationAndPreserveTicket() throws {
        let (folder, store) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileTransferPaths.fileURL("/repo"), valid = overlappingSnapshot("/repo")
        XCTAssertTrue(try store.publish(store.begin(root: root), snapshots: [valid]).published)
        let raw = try Data(contentsOf: store.url), control = URL(fileURLWithPath: store.url.path + ".writers")
        let ticket = try store.begin(root: root), controlBytes = try Data(contentsOf: control)
        for field in OverlappingField.allCases {
            for path in ["/repo/nested/../escape", "/outside/file", "/repo/bad\0name"] {
                let poisoned = field.inserting(path, in: valid)
                // Earlier valid snapshots and repeated keys in every map must
                // not conceal the final snapshot's invalid path.
                XCTAssertThrowsError(try store.publish(ticket, snapshots: [valid, valid, poisoned]), "\(field.rawValue): \(path.debugDescription)")
                XCTAssertEqual(try Data(contentsOf: store.url), raw)
                XCTAssertEqual(try Data(contentsOf: control), controlBytes)
            }
        }
        XCTAssertTrue(try store.publish(ticket, snapshots: [valid, valid, valid]).published, "Refused payload consumed a valid ticket or valid overlapping snapshots were refused")
    }
    func testFreshUntrustedControlLoadsCannotReuseTrustFromEarlierValidOperations() throws {
        let (folder, store) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileTransferPaths.fileURL("/repo"), valid = overlappingSnapshot("/repo")
        XCTAssertTrue(try store.publish(store.begin(root: root), snapshots: [valid]).published)
        let control = URL(fileURLWithPath: store.url.path + ".writers"), accepted = try Data(contentsOf: control)
        let raw = try Data(contentsOf: store.url)
        for field in OverlappingField.allCases {
            try accepted.write(to: control, options: .atomic)
            XCTAssertEqual(try store.readLive().states["/repo/file"], .normal)
            // Preserve all real contribution/session/ticket framing, changing
            // only its snapshot payload at the persisted untrusted boundary.
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted) as? [String: Any])
            var contributions = try XCTUnwrap(object["contributions"] as? [[String: Any]])
            XCTAssertFalse(contributions.isEmpty)
            let poisoned = field.inserting("/repo/hidden/../file", in: valid)
            let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(poisoned))
            let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
            contributions[0]["snapshots"] = [good, payload]
            object["contributions"] = contributions
            let tampered = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try tampered.write(to: control, options: .atomic)
            XCTAssertThrowsError(try store.readLive(), "Same reader trusted changed \(field.rawValue)")
            let fresh = FinderSnapshotStore(url: store.url)
            XCTAssertThrowsError(try fresh.readLive(), "Fresh reader trusted changed \(field.rawValue)")
            XCTAssertThrowsError(try store.persistence(), "A new locked operation trusted changed \(field.rawValue)")
            XCTAssertEqual(try Data(contentsOf: control), tampered, "Validation repaired/discarded untrusted evidence")
            XCTAssertEqual(try Data(contentsOf: store.url), raw)
        }
        try accepted.write(to: control, options: .atomic)
        XCTAssertEqual(try store.readLive().states["/repo/file"], .normal)
    }
    func testOverlappingPublicationMapsRetainCanonicallyEquivalentDistinctUTF8Paths() throws {
        let (folder, store) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = "/repo/caf\u{00e9}", b = "/repo/cafe\u{301}"
        XCTAssertEqual(a, b) // Native String equality is not a Git path identity.
        XCTAssertNotEqual(Data(a.utf8), Data(b.utf8))
        var first = overlappingSnapshot(a, state: .modified), second = overlappingSnapshot(b, state: .conflicted)
        first.repositories[a] = .init(hasStash: true)
        second.repositories[b] = .init(mergeActive: true)
        first.indexFlags?[a + "/file"] = .init(assumeUnchanged: true)
        second.indexFlags?[b + "/file"] = .init(skipWorktree: true)
        first.overlayPolicies[a] = .init(identity: "composed-policy", caseSensitive: true)
        second.overlayPolicies[b] = .init(identity: "decomposed-policy", caseSensitive: false)
        let root = FileTransferPaths.fileURL("/repo"), ticket = try store.begin(root: root)
        let published = try store.publish(ticket, snapshots: [overlappingSnapshot("/repo"), first, second])
        XCTAssertTrue(published.published)
        let independent = FinderSnapshotStore(url: store.url)
        for value in [published.snapshot, try store.readLive(), try independent.readLive()] {
            XCTAssertTrue(value.roots.contains { Data($0.utf8) == Data(a.utf8) })
            XCTAssertTrue(value.roots.contains { Data($0.utf8) == Data(b.utf8) })
            XCTAssertEqual(value.states[a + "/file"], .modified); XCTAssertEqual(value.states[b + "/file"], .conflicted)
            XCTAssertEqual(value.overlayEntries?[a + "/file"], .modified); XCTAssertEqual(value.overlayEntries?[b + "/file"], .conflicted)
            XCTAssertEqual(value.repositories[a]?.hasStash, true); XCTAssertEqual(value.repositories[b]?.hasStash, false)
            XCTAssertEqual(value.repositories[a]?.mergeActive, false); XCTAssertEqual(value.repositories[b]?.mergeActive, true)
            XCTAssertEqual(value.indexFlags?[a + "/file"], .init(assumeUnchanged: true))
            XCTAssertEqual(value.indexFlags?[b + "/file"], .init(skipWorktree: true))
            XCTAssertEqual(value.overlayPolicies[a]?.identity, "composed-policy")
            XCTAssertEqual(value.overlayPolicies[b]?.identity, "decomposed-policy")
            XCTAssertEqual(value.overlayPolicies[a]?.caseSensitive, true)
            XCTAssertEqual(value.overlayPolicies[b]?.caseSensitive, false)
        }
    }

}
