# Connected history and reference workflows

This batch compares the shared-list consumers with pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`: `GitLogListBase.cpp`,
`GitLogListAction.cpp`, `RebaseDlg.cpp`, `BrowseRefsDlg.cpp`,
`TortoiseGitBlame/LogListBlameAction.cpp` and the Blame source popup.

The [Rebase reference context family](REBASE-REFERENCE-CONTEXT-PARITY.md) connects
reference labels and applicable shared Log commands to `IDD_REBASE`. Targets
retain full Git names, the captured occurrence/selection, menu policy and owner
state. Repository refreshes update the replay history context through its own
metadata lifecycle instead of replacing it with an ordinary Log history walk.

The [Blame parent action family](BLAME-PARENT-ACTION-PARITY.md) connects source and
embedded-history previous/compare/unified actions across renamed origin files and
merge parents. Base source actions survive failed optional parent lookup; delayed
lookups cannot replace a newer popup. Parent identities include their origin paths.

The [Reference Browser comparison and child family](REFERENCE-COMPARISON-OWNERSHIP-PARITY.md) retains the captured alternate
comparison choice, canonical reference names and native child ownership until
AppKit actually detaches the sheet. Switch/Merge closure refreshes the catalog so
HEAD/current-branch eligibility follows the repository. Cancelled unified readers
retain Quit and permission ownership until their actual return.

Shared workspace handoffs pass the initiating preference store through Log,
Export, Branch/Tag, Checkout, Repository Browser, Blame and file comparisons.
Reusable windows cannot silently cross preference stores. Comparison change-set
windows receive preferences before native controls and readers are created.
Blame Log restores the captured selected revision; its repository browser opens
the parent listing with the exact file selected, including nested renamed paths.
Blame commands also respect the application’s deferred Quit confirmation.

The grouped runner is `scripts/test-history-reference-workflows.py`; focused
Core coverage exercises Blame parent identities and actual renamed/merge origins.
Actual build, case/engine receipts, failures and cleanup are recorded in
[batch evidence](qa/history-reference-workflows-2026-10-18.json). New fixture or
source-file existence alone is not a verification result.

Remaining work includes exhaustive Windows command enabled/omitted comparisons,
all reference mutation races and remote authentication/error variants, complete
visual and physical keyboard/mouse/VoiceOver acceptance, minimum macOS/Intel and
current hosted CI. Signed sandbox/Finder integration and App Store distribution
remain separate gates. This batch does not certify whole-dialog or whole-port
completion.
