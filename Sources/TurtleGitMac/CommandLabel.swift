import SwiftUI
import TurtleGitCore

struct CommandLabel: View {
    let title: String
    let icon: MenuIcon
    var localized = true
    @Environment(\.turtleGitContextMenu) private var contextMenu
    @AppStorage("ShowAppContextMenuIcons") private var showContextIcons = true
    @ViewBuilder private var caption: some View {
        if localized { Text(LocalizedStringKey(title)) } else { Text(verbatim: title) }
    }
    var body: some View {
        if contextMenu && !showContextIcons {
            caption
        } else {
            Label {
                caption
            } icon: {
                if let image = icon.image() {
                    Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).resizable().frame(width: 16, height: 16)
                }
            }
        }
    }
}

private struct TurtleGitContextMenuKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var turtleGitContextMenu: Bool {
        get { self[TurtleGitContextMenuKey.self] }
        set { self[TurtleGitContextMenuKey.self] = newValue }
    }
}
struct TurtleGitContextMenu<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.environment(\.turtleGitContextMenu, true) }
}
