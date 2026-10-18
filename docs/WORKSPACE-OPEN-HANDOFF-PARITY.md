# External workspace requests during standalone Merge

TortoiseGit uses distinct TortoiseProc and TortoiseMerge processes. TurtleGit's
single macOS application bundle must preserve that separation when Git invokes
its Merge entry and Launch Services subsequently delivers Finder actions or patch
files to the running application. This is a native process/lifetime adaptation,
not an upstream dialog certification. It complements `IDD_OPENDLG` in
`src/Resources/TortoiseMergeENG.rc` and the standalone frame audit.

`NSApplicationDelegate.application(_:open:)` is now the single external event
receiver. Workspace mode queues events before its routing model/startup command
are ready, then consumes that queue once in original order. Subsequent repeated
user events remain independent. RepositoryWindow no longer registers a second
SwiftUI onOpenURL handler.

Tool mode validates supported Finder request URLs with the existing typed parser
and accepts case-insensitive .patch/.diff file opens. It ignores unsupported
schemes, actions and file kinds. Each accepted batch passes unchanged URLs to
`NSWorkspace.open` with a new application instance, activation and empty
arguments. No Merge input/output arguments or scope is synthesized for the child.
The child's ordinary workspace routing and repository/file authorization apply.
A URL path/reflected name is not an access grant. Actual signed Launch Services
scope transfer remains an acceptance gate.

The handoff retains selected-file scope leases until the actual launch callback.
Launch success means Launch Services accepted the application, not that every
child Git action finished. The child has its own UI and action ownership. Failed
launches retain a native acknowledgment window or sheet; closing the original
sheet owner retires its acknowledgment exactly once. If the Merge editor closes
first, its captured Git status waits through accepted launches and failure
acknowledgments. Shutdown yields recheck pending work before exit. Quit refuses
active handoff ownership. Retirement keeps uncancellable launch receipts until
the real callback but neither publishes late failures nor terminates children.

The grouped private fixture covers unsupported-input refusal, literal URL order/
duplicates, actual new-instance/empty-argument configuration, one-shot launch and
failure replies, ownerless/sheet failure dismissal, retirement drain, early
workspace ordering and a real readonly Merge command close whose Git status
waits through a held failed workspace launch/acknowledgment. It opens no external
processes. [Batch evidence](qa/metadata-port-2026-10-18.json) records actual checks;
fixture existence alone is not a pass.

Physical Finder/document event dispatch, an actual independently launched signed
workspace, App Store terminal/Launch Services grants, minimum-OS/Intel, full
visual/keyboard/VoiceOver and whole-app parity remain open. The unbundled SwiftPM
entry cannot launch a workspace application bundle and reports an owned error.
