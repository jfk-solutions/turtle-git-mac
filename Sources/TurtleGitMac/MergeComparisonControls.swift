import SwiftUI
import TurtleGitCore

struct MergeComparisonControls: View {
    let options: MergeComparisonOptions
    let apply: (MergeComparisonOptions) -> Void
    var supportsComments = false
    private func changing(_ update: (inout MergeComparisonOptions) -> Void) {
        var next = options; update(&next); apply(next)
    }
    var body: some View {
        Menu("Comparison") {
            ForEach(MergeWhitespaceComparison.allCases, id: \.rawValue) { value in
                Button { changing { $0.whitespace = value } } label: {
                    if options.whitespace == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                }
            }
            Divider()
            Toggle("Ignore line endings", isOn: Binding(get: { options.ignoreEndings }, set: { value in changing { $0.ignoreEndings = value } }))
            Toggle("Ignore case changes", isOn: Binding(get: { options.ignoreCase }, set: { value in changing { $0.ignoreCase = value } }))
            Toggle("Ignore Comments", isOn: Binding(get: { options.ignoreComments }, set: { value in changing { $0.ignoreComments = value } })).disabled(!supportsComments)
        }.fixedSize()
    }
}
