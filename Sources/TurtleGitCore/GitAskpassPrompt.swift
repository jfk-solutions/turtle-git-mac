// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct GitAskpassPrompt: Sendable {
    public let text: String
    public let secret: Bool
    public init(_ text: String) {
        self.text = text
        // Git emits English prompts under our LC_ALL=C transport environment.
        // Only a recognized username request is shown without masking.
        secret = !text.hasPrefix("Username for ")
    }
    public static func validResponse(_ value: String) -> Bool {
        value.utf8.count <= 65_535 && !value.utf8.contains(0) && !value.contains("\n") && !value.contains("\r")
    }
}
