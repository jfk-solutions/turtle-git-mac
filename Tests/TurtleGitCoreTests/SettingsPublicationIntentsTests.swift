import XCTest
@testable import TurtleGitCore

final class SettingsPublicationIntentsTests: XCTestCase {
    private func withDefaults(_ body: (String, UserDefaults) throws -> Void) throws {
        let suite = "TurtleGit.SettingsPublication.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(suite, defaults)
    }

    func testAcceptedRequestsSurviveHelperAndDefaultsReplacementWithoutPayloads() throws {
        try withDefaults { suite, defaults in
            let intents = SettingsPublicationIntents(defaults: defaults)
            defaults.set(false, forKey: "CacheTrayIcon")
            let token = intents.request(.cacheTray)
            XCTAssertNotNil(UUID(uuidString: token))
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let reopened = SettingsPublicationIntents(defaults: reopenedDefaults)
            XCTAssertEqual(reopened.pending(.cacheTray), token)
            // Retrying consumes accepted defaults, rather than a stale persisted
            // publication payload. Only the request identity belongs here.
            defaults.set(true, forKey: "CacheTrayIcon")
            XCTAssertEqual(reopened.pending(.cacheTray), token)
            XCTAssertTrue(reopenedDefaults.bool(forKey: "CacheTrayIcon"))
            let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
            XCTAssertEqual(Set(stored.keys), ["CacheTrayIcon", "TurtleGit.SettingsPublicationIntent.cacheTray"])
            XCTAssertEqual(stored["TurtleGit.SettingsPublicationIntent.cacheTray"] as? String, token)
        }
    }

    func testStaleAndDuplicateCompletionCannotEraseNewerAcceptedRequest() throws {
        try withDefaults { _, defaults in
            let first = SettingsPublicationIntents(defaults: defaults)
            let second = SettingsPublicationIntents(defaults: defaults)
            let older = first.request(.finderMenu)
            let newer = second.request(.finderMenu)
            XCTAssertNotEqual(older, newer)
            XCTAssertFalse(first.complete(.finderMenu, request: older))
            XCTAssertEqual(first.pending(.finderMenu), newer)
            XCTAssertTrue(second.complete(.finderMenu, request: newer))
            XCTAssertNil(first.pending(.finderMenu))
            XCTAssertFalse(second.complete(.finderMenu, request: newer))
            XCTAssertFalse(first.complete(.finderMenu, request: older))
        }
    }

    func testEachPublicationChannelRetainsItsIndependentFailureAndCompletion() throws {
        try withDefaults { _, defaults in
            let intents = SettingsPublicationIntents(defaults: defaults)
            let tokens = Dictionary(uniqueKeysWithValues: SettingsPublicationChannel.allCases.map { ($0, intents.request($0)) })
            XCTAssertEqual(Set(tokens.values).count, 3)
            XCTAssertFalse(intents.complete(.finderMenu, request: tokens[.cacheTray]!))
            XCTAssertTrue(intents.complete(.cacheTray, request: tokens[.cacheTray]!))
            XCTAssertNil(intents.pending(.cacheTray))
            XCTAssertEqual(intents.pending(.finderMenu), tokens[.finderMenu])
            XCTAssertEqual(intents.pending(.cachePersistence), tokens[.cachePersistence])
            XCTAssertTrue(intents.complete(.finderMenu, request: tokens[.finderMenu]!))
            XCTAssertEqual(intents.pending(.cachePersistence), tokens[.cachePersistence])
        }
    }

    func testLegacyTrueMigratesOnceAndCannotResurrectAfterMatchingCompletion() throws {
        try withDefaults { suite, defaults in
            let legacy = "TurtleGit.CacheSavePublicationPending"
            defaults.set(true, forKey: legacy)
            let first = SettingsPublicationIntents(defaults: defaults)
            XCTAssertNil(first.pending(.cacheTray))
            XCTAssertNil(first.pending(.finderMenu))
            let migrated = try XCTUnwrap(first.pending(.cachePersistence))
            XCTAssertNotNil(UUID(uuidString: migrated))
            XCTAssertTrue(defaults.bool(forKey: legacy), "Interrupted migration retains a conservative retry witness")
            let reopened = SettingsPublicationIntents(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.pending(.cachePersistence), migrated)
            XCTAssertFalse(reopened.complete(.cachePersistence, request: UUID().uuidString))
            XCTAssertEqual(first.pending(.cachePersistence), migrated)
            XCTAssertTrue(reopened.complete(.cachePersistence, request: migrated))
            XCTAssertNil(defaults.object(forKey: legacy))
            XCTAssertNil(first.pending(.cachePersistence))
            XCTAssertNil(SettingsPublicationIntents(defaults: defaults).pending(.cachePersistence))
        }
    }

    func testLegacyFalseDoesNotEraseTokenAndNewRequestSupersedesMigration() throws {
        try withDefaults { _, defaults in
            let legacy = "TurtleGit.CacheSavePublicationPending"
            let intents = SettingsPublicationIntents(defaults: defaults)
            defaults.set(false, forKey: legacy)
            XCTAssertNil(intents.pending(.cachePersistence))
            defaults.set(true, forKey: legacy)
            let migrated = try XCTUnwrap(intents.pending(.cachePersistence))
            let accepted = intents.request(.cachePersistence)
            defaults.set(false, forKey: legacy)
            XCTAssertEqual(intents.pending(.cachePersistence), accepted)
            XCTAssertFalse(intents.complete(.cachePersistence, request: migrated))
            XCTAssertEqual(intents.pending(.cachePersistence), accepted)
            XCTAssertTrue(intents.complete(.cachePersistence, request: accepted))
            XCTAssertNil(intents.pending(.cachePersistence))
        }
    }
}
