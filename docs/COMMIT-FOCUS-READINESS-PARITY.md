# Commit native focus readiness — October 24, 2026

The hosted macOS 15.5/Swift 6.1.2 primary-dialog receiver failed its immediate
author field-editor assertion after the author metadata read completed. Model
readiness and SwiftUI's native field update are distinct events. The original
fixture already waited for actual new-branch focus, but checked author/date
focus synchronously.

The Commit controller now accepts branch, author, author-date and author-time
focus commands against the current form receipt and original window. It defers
native focus past the current SwiftUI update, lays out the native content, then
permits a bounded cancellable readiness retry for an attached, enabled control
with the expected editability and current model value. Text fulfillment
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

The later [6de62e88 hosted run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40496135185)
also failed the author selection assertion. The October27 repair waits for both
the native value and editability instead of accepting an older editable value,
and defers the first attempt until native layout. New native cases hold a stale
author value, deliver its current value, and supersede a held author request with
branch focus. The request also captures its original editing control: AppKit can
reuse the same field-editor responder for another control, which now revokes the
old request. A native case explicitly exercises that shared-editor handoff.
Existing date/time, Quit, responder, modal and retirement assertions
remain intact. The first local repaired group passed with system Git but exposed
a date-focus race with bundled Git. Option actions now start author/date/amend/
comparison metadata transitions synchronously; the later SwiftUI observer
consumes that delivered transition instead of starting it again and retiring an
already accepted focus receipt. Native assertions check synchronous author/date
read admission and receipt stability through the view update.
The [October27 grouped checkpoint](qa/commit-focus-native-value-2026-10-27.json)
records both system and bundled Git Commit cases passing after that repair, with
all owned receivers reaped. It retains the earlier bundled failure. No Core
production changed, so the full Core suite was not rerun. The older checkpoint
above does not certify this change or resolve hosted acceptance.

Source review also identifies a separate focus-provider boundary: an older
queued automatic message-focus request can compete with a later explicit form
command. Message/issue/field/file-list intent priority remains to be unified;
this checkpoint does not certify that overlapping-provider behavior.
