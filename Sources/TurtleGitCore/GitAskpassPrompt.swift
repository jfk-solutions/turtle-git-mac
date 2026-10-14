// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct GitAskpassPrompt: Sendable {
    public let text: String
    public let secret: Bool
    public let confirmation: Bool
    public let notification: Bool
    public let maximumResponseBytes: Int
    public init(_ text: String, ssh: Bool = false, hint: String? = nil, svn: Bool = false) {
        self.text = text
        notification = ssh && hint == "none"
        confirmation = ssh && !notification && (hint == "confirm" || text.contains("Are you sure you want to continue connecting") || text.contains("(yes/no") || text.hasPrefix("Please type 'yes'"))
        maximumResponseBytes = ssh ? 1023 : 65_535
        // Git emits English prompts under our LC_ALL=C transport environment.
        // Only a recognized username request is shown without masking.
        secret = !confirmation && !notification && !text.hasPrefix("Username for ") && !(svn && text == "Username: ")
    }
    public static func validResponse(_ value: String) -> Bool {
        value.utf8.count <= 65_535 && !value.utf8.contains(0) && !value.contains("\n") && !value.contains("\r")
    }
    public func accepts(_ value: String) -> Bool {
        Self.validResponse(value) && value.utf8.count <= maximumResponseBytes
    }
}
