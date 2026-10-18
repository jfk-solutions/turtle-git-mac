# Reference comparison and action ownership

This October 18, 2026 batch compares the reference browser with
`src/TortoiseProc/BrowseRefsDlg.cpp::ShowContextMenu` at pinned upstream
`7338078f8ddd924b8cddee35f512f2286072136d`. It extends the partial
[reference browser audit](REFERENCE-BROWSER-PARITY.md); it does not establish
complete dialog or whole-app parity.

## Source behavior and native implementation

The single-leaf menu marks its first command as the default: Select in a picker,
Show log for a standalone commit, and Browse repository for a noncommit object.
The source menu ordering and individual command icons remain in place. Working
comparison is available only for commit references in a working-copy repository.
Shift is captured at command invocation and passed explicitly to the comparison
window, preserving the owning browser's preferences and canonical reference name.
The legacy callback retains the same alternate-tool task context.

The source distinguishes endpoint ownership. Normal pair comparison uses canonical
reference names; unified comparison uses the hashes captured with the menu's leaves.
TurtleGit retains that distinction, including when a reference moves after a menu
is displayed. Refresh, child transitions, and deferred application Quit retire old
menu and form receipts; cancelling Quit does not revive a previously displayed menu.
New child launches, reference mutations, selection and presentation changes are
fenced while Quit is pending. Already accepted work still drains and releases its
owned access.

Native child completion now keeps the browser blocked until AppKit has detached
the actual sheet. An independent release receipt retains its native ownership and
Quit accounting through forced owner closure. Tracking choice waits for both the
picker reply and actual sheet release before applying the selected upstream;
otherwise an asynchronous native close could silently reject the mutation behind
the old child flag. Description, Fetch, creation, remote management, remote tag
deletion, Switch and Merge refresh the live reference catalog after their owned
child has drained, retaining the selected canonical reference when it still exists.
Refreshing after Switch/Merge closure also covers external reference changes while
the native dialog was open; this is a macOS lifetime adaptation, not an assertion
that the source Switch/Merge cases explicitly call Refresh.

Unified reads retain their own cancellation, permission lease and actual-operation
counter until the read and presentation return, even if their browser is forcibly
closed. Late reads cannot publish into a retired owner. Default sheet presenters
inherit the owner's appearance and alpha before presentation so private automated
receivers remain invisible.

## Verification scope and remaining work

`qa/reference-comparison-ownership-native-2026-10-18.swift`, entry
`ReferenceComparisonOwnershipVerification.verify()`, exercises real native menus,
a real comparison model with private preferences, moving reference/hash endpoints,
actual tracking/Switch/Merge sheets and catalog refresh, bare-repository gating,
held-menu Quit refusal, noncooperative comparison cancellation and owned cleanup.
Its private repository deliberately changes references and tracking configuration;
HEAD, index and working-file bytes must remain unchanged. Fixture presence is not
a test result: the parent batch records the build and grouped native outcomes.

Physical Shift gestures and popup tracking, VoiceOver interaction, external-tool
process acceptance, complete pixel/control comparison, signed sandbox/Finder
integration and older macOS/Intel coverage remain open. This batch changes no Core
Git algorithms or translation labels. Existing broader reference-browser gaps
remain documented in the linked family audit.

Actual grouped outcomes: [connected history/reference evidence](qa/history-reference-workflows-2026-10-18.json).
