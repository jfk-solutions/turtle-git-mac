// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One invocation's progress completion choice. Absence is carried separately
/// so an explicit manual choice can override a persistent automatic preference.
/// This value grants no authority to start a command or dismiss a failed result.
public enum CommandProgressAutoClose: Int, CaseIterable, Equatable, Sendable {
    case manual = 0, noOptions = 1, noErrors = 2

    /// CCmdLineParser::GetLongVal uses _wtol: optional C whitespace/sign,
    /// decimal prefix, and zero when no number starts. The progress constructors
    /// recognize only 1/2; every other value (including overflow) is manual.
    /// Do not reinterpret this source option as a strict enum validation error.
    public init(sourceArgument: String) {
        let bytes=Array(sourceArgument.utf8)
        var index=0
        while index<bytes.count,[UInt8(9),10,11,12,13,32].contains(bytes[index]) {index+=1}
        var negative=false
        if index<bytes.count,bytes[index]==43 || bytes[index]==45 {
            negative=bytes[index]==45;index+=1
        }
        var magnitude=0,hasDigits=false
        while index<bytes.count,(48...57).contains(bytes[index]) {
            hasDigits=true
            // Only 1 and 2 are observable active policies. Saturation here
            // avoids host Int-width/overflow differences without wrapping a
            // huge decimal back into an active policy.
            magnitude=min(3,magnitude*10+Int(bytes[index]-48));index+=1
        }
        self = hasDigits && !negative ? Self(rawValue:magnitude) ?? .manual:.manual
    }
}
