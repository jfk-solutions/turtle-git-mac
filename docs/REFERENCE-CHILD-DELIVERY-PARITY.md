# Captured reference child delivery

This continuation covers Browser and RefLog selection returning to Rebase,
Reset and Switch, together with Finder file-pair comparison and child-submodule
Log consumers. It does not mark those complete dialog families as fully ported.

Applicable pinned resources are `IDD_BROWSE_REFS` (selection and child return),
`IDD_REFLOG` (selected-entry return), `IDD_REBASE` and `IDD_GITSWITCH` (captured
reference handoffs), and the child-submodule Log actions reached through
`IDD_CHANGEDFILES` and `IDD_RESOLVE`. These are partial workflow reviews; naming a
resource does not certify its other controls, dialogs or visual parity.

The pinned source is TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. `BrowseRefsDlg.cpp` returns a selected
reference with `EndDialog(IDOK)` and reads the live branch in
`OnBnClickedCurrentbranch`. The macOS sheet equivalent must finish native
detachment before invoking the presenting workflow's selection or close callback.
Browser and RefLog now explicitly end their own sheet on forced controller close
and retain their existing worker/child retirement until both that sheet and their
owned children detach. Acceptance, Cancel and forced closure still deliver at
most one choice, followed by at most one close notification. A retired parent
continues to reject a late child result.

The ownership controls retain default native reference reads in ordinary dialog
flows. Held CLI cancellation phases explicitly capture the CLI backend so a valid
source7 local reference query cannot bypass an authored `for-each-ref` wrapper.
Rebase retains the complete original NUL-framed argv, atomic live shell/child PID
receipts and both processes' disappearance after model retirement. Switch retains
its held metadata, checkout validation, mutation and post-checkout drain checks.

This keeps the asynchronous release contract. Connected native consumers wait for
an actual delivered choice and retired child, rather than treating the model's
initial `closed` flag as completion. Rebase also waits for its picker request and
active picker ownership to clear before reading the replacement plan. Current
Branch continues to read the current repository instead of the browser's stale
catalog. Exact UTF-8 Git reference spellings remain asserted.

Finder file-pair comparison likewise reads files and obtains access before it
constructs the viewer. Its native consumer observes the actual newly created
controller before checking the captured default/alternate tool choice. The
private receiver injects a hidden presentation without changing production
presentation or tool selection.

`Git/GitStatusListCtrl.cpp` lines 2410–2431 launch Show Submodule Log against the
child working directory, optionally pinning a gitlink revision for a historical
view. This action does not inspect merge ancestry. The Changed Files working-view
consumer now asserts the accepted child root, captured backend and unpinned
revision, and refuses an unrelated merge-base query. The separate Submodule Diff
and conflict ancestry assertions remain. Resolve's child-directory consumer
compares exact path UTF-8 bytes, avoiding Foundation URL equality differences due
to the directory hint; it does not normalize Unicode reference or file names.

## Validation and remaining acceptance

`scripts/test-reference-child-delivery.py` groups seven connected native cases
under one cached receiver build. The existing hosted entry point
`scripts/test-reference-browser.py` forwards its ordered `--git` arguments to the
complete sheet and Browser cases in that same driver, so the new attachment
regression runs without a new workflow invocation. A static entry-point check
retains exact engine paths, including spaces, without repeating native checks.
Independent failures are collected only after an explicit native cleanup receipt;
missing cleanup or timeout stops later cases. It uses private repositories, HOME, CF defaults,
configuration and temporary storage. Native window ordering keeps windows and
sheets transparent and offscreen, and cleanup waits for owned worker and sheet
retirement before returning. The new sheet case exercises actual Browser and
RefLog attachments for acceptance, Cancel and forced close, checks callback order
and exactly-once delivery after detachment, and preserves HEAD/index bytes.

The [November 7 checkpoint](qa/reference-child-delivery-2026-11-07.json) records
one successful shared Debug build and fourteen distinct native case/engine passes
cumulatively: all seven cases with system and bundled Git. The sheet case covers
twelve actual native attachments across acceptance, Cancel and forced closure.
Initial compile, authored-control, stale-object, refresh-readiness and CLI-policy
failures remain recorded. Later repairs repeated only affected cases; the other
ten passing combinations were retained when repairing Rebase/Switch, and twelve
were retained for the final Switch-only repair. All 34 reported compiler/receiver
PIDs were independently absent, and observed private test roots were removed.

No complete corrected-source hosted run, physical/signed/VoiceOver acceptance or
full visual source parity is established by these hidden checks. Initial hidden
zero-size split-view warnings remain in the logs. Those acceptance areas and the
other unreviewed Browser, Rebase, RefLog and comparison controls remain open.
Installed build52 is unchanged.
