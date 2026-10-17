// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct AppLanguageChoice: Identifiable, Equatable, Sendable {
    public static let system = "system"
    public let id: String
    public init(id: String) { self.id = id }
    public var title: String {
        if id == Self.system { return "System Language" }
        let displayID = id == "sr" ? "sr-Cyrl" : id
        let english = Locale(identifier: "en").localizedString(forIdentifier: displayID) ?? id
        let native = Locale(identifier: displayID).localizedString(forIdentifier: displayID) ?? english
        return native == english ? native : native + " — " + english
    }
    public static var choices: [Self] { [.init(id: system), .init(id: "en")] + bundledIDs.filter { $0 != "en" }.map { .init(id: $0) } }
    public static func isAvailable(_ id: String) -> Bool { id == system || bundledIDs.contains(id) }
    public static func selected(in preferences: UserDefaults = .standard) -> String {
        guard let selected = preferences.string(forKey: "TurtleGit.AppLanguage"), isAvailable(selected) else { return system }
        return selected
    }
    /// Only change this application's preference domain. Returning to System
    /// removes its override; the system/global language order remains untouched.
    public static func save(_ id: String, to preferences: UserDefaults = .standard) throws {
        guard isAvailable(id) else { throw AppLanguageFailure.unavailable }
        if id == system {
            preferences.removeObject(forKey: "AppleLanguages"); preferences.removeObject(forKey: "TurtleGit.AppLanguage")
        } else {
            preferences.set([id], forKey: "AppleLanguages"); preferences.set(id, forKey: "TurtleGit.AppLanguage")
        }
    }
}
public enum AppLanguageFailure: LocalizedError {
    case unavailable
    public var errorDescription: String? { "Choose an available language." }
}
