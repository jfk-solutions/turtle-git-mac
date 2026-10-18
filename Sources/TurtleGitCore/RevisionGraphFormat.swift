// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RevisionGraphFormat: String, CaseIterable, Sendable {
    case svg, graphviz, png, jpeg, bmp, gif, pdf
    public var fileExtension: String { self == .graphviz ? "gv" : self == .jpeg ? "jpg" : rawValue }
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "gv", "dot": self = .graphviz
        case "jpg", "jpeg": self = .jpeg
        default: guard let value = Self(rawValue: fileExtension.lowercased()), value != .graphviz else { return nil }; self = value
        }
    }
}
