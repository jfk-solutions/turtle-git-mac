# Commit native focus readiness — October 24, 2026

The hosted macOS 15.5/Swift 6.1.2 primary-dialog receiver failed its immediate
author field-editor assertion after the author metadata read completed. Model
readiness and SwiftUI's native field update are distinct events. The original
fixture already waited for actual new-branch focus, but checked author/date
focus synchronously.

The Commit controller now accepts branch, author, author-date and author-time
focus commands against the current form receipt and original window. It attempts
native focus immediately, then permits a bounded cancellable readiness retry for
an attached, enabled control with the expected editability. Text fulfillment
requires the actual field editor and selects the entire value. Date/time
fulfillment requires the picker or its native descendant to own first responder.
A newer request supersedes the previous request. Changed form/options, busy/Quit,
modal sheets, retirement, another owner, or another responder revoke the request.
The retry retains its controller/window weakly between attempts and ends after
three seconds. It does not activate a window.

Pinned source: `src/TortoiseProc/CommitDlg.cpp` at
`7338078f8ddd924b8cddee35f512f2286072136d`,
`OnBnClickedCheckNewBranch` (3026 onward) focuses and selects the new branch;
`OnBnClickedCommitSetauthor` (3081 onward) preserves selection/copy while changing
read-only state; `OnBnClickedCommitSetDateTime` and
`OnBnClickedCommitAsCommitDate` (2986–3023) control date/time availability. The
native Focus menu commands adapt these controls to macOS command routing.

The retained primary Commit options fixture now waits for actual author/date/time
responders, tests a real attached field whose editability is not yet ready, and
checks pending-request refusal across Quit, form-option changes and owner close.
These are automated native-control assertions, not physical keyboard acceptance.
The affected native Commit group passes with system and bundled Git. The shared
final Debug build exits zero; five contradictory generic compiler exit-zero
diagnostics are retained in the [dated checkpoint](qa/commit-focus-readiness-family-2026-10-24.json).
All 18 receivers attempted across the connected Sync/Stash/Commit checkpoint are
independently confirmed absent. No new Core behavior or literal UI labels were
introduced by the focus change. A full hosted rerun with the older SDK remains
required; the original [95df5f46 macOS run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40096089548)
failed, and a focused local pass does not replace it.
