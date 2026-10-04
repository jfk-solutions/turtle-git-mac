import SwiftUI

struct CreateChangelistSheet: View {
    @ObservedObject var model: CommitWindowModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Changelist").font(.headline)
            Text("Enter a name for the changelist:")
            TextField("", text: $model.changelistName).accessibilityLabel("Changelist name").focused($nameFocused)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelChangelist() }.keyboardShortcut(.cancelAction)
                Button("OK") { model.createChangelist() }.keyboardShortcut(.defaultAction).disabled(model.changelistName.isEmpty)
            }
        }.padding(16).frame(width: 360)
        .task { await Task.yield(); nameFocused = true }
    }
}
