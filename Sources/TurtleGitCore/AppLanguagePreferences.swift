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


/// Counts use named integer fields rather than executing translated printf
/// strings. A translator may reorder fields, but cannot omit, duplicate or add
/// one. Malformed translations fall back to the validated English template.
public enum LocalizedCountTemplate {
    private static func fields(_ text:String)->[String]? {
        var names=[String](),index=text.startIndex
        while index<text.endIndex {
            let character=text[index]
            if character=="}" {return nil}
            if character=="{" {
                guard let end=text[index...].firstIndex(of:"}") else{return nil}
                let name=String(text[text.index(after:index)..<end])
                guard !name.isEmpty,name.utf8.allSatisfy({(97...122).contains($0) || $0==95}) else{return nil}
                names.append(name);index=text.index(after:end)
            } else {index=text.index(after:index)}
        }
        return names
    }
    public static func accepts(_ translation:String,for english:String)->Bool {
        guard !translation.isEmpty,!translation.contains("%"),let expected=fields(english),let actual=fields(translation),!expected.isEmpty else{return false}
        return expected.sorted()==actual.sorted() && Set(expected).count==expected.count
    }
    public static func render(_ english:String,translation:String,values:[String:Int])->String {
        guard let names=fields(english),!names.isEmpty,Set(names)==Set(values.keys),Set(names).count==names.count else{return english}
        let template=accepts(translation,for:english) ? translation:english
        // Scan once; only integer values are inserted, never text or format code.
        var output="",index=template.startIndex
        while index<template.endIndex {
            if template[index]=="{",let end=template[index...].firstIndex(of:"}") {
                let name=String(template[template.index(after:index)..<end])
                output += String(values[name]!);index=template.index(after:end)
            } else {output.append(template[index]);index=template.index(after:index)}
        }
        return output
    }
}
