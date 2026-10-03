import SwiftUI
import TurtleGitCore

struct CommandLabel: View {
    let title: String
    let icon: MenuIcon
    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = icon.image() {
                Image(nsImage: image).renderingMode(.original).resizable().frame(width: 16, height: 16)
            }
        }
    }
}
