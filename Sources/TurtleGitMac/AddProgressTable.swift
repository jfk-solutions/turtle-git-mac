import AppKit
import SwiftUI
import TurtleGitCore

struct AddProgressTable:View {
    @ObservedObject var model:AddProgressWindowModel
    var body:some View {
        FileOperationProgressTable(state:model.progress,icon:.addBackdrop,available:model.commandsAvailable && !model.busy && !model.confirmingCancellation && !model.fileActionBusy,repository:model.repository.root,keyboardAvailable:model.commandsAvailable,perform:model.onProgressFileAction)
    }
}
