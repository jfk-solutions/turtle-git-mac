# Log reference metadata and native interaction

This partial workflow review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/GitLogListBase.cpp::OnToolTipText`, `GetToolTipText` and
`IsMouseOnRefLabel`, plus `src/Git/Git.cpp::GetBranchDescriptions`.
The Log dialog is `src/Resources/TortoiseProcENG.rc` / `IDD_LOGMESSAGE`.
It does not certify every control or every shared-list consumer.

## Source hover metadata

A pointer over a **local branch** badge prefers `Description:\n` followed by
that branch's local Git description. This also applies with right-side labels;
right-side mode disables only the ordinary message/subject tooltip. Remote,
tag, stash and other labels do not acquire an invented annotation tooltip.
When no description exists, the original subject fallback remains in left-label
mode and remains absent in right-label mode. A deliberately empty description
still displays its heading, matching the source map lookup.

The read uses repository-local configuration and preserves the first duplicate
entry, multiline content, case and exact UTF-8 name/value identity. Global
branch descriptions are not inherited. Ref names remain canonical, even when
the badge shows a symbolized/shortened upstream name. The source wide tooltip
buffer reserves a terminator and literal `...` from 8192 UTF-16 units; native
text follows that bound. Arbitrary malformed UTF-8/UTF-16 equivalence remains
outside this review.

History reload captures descriptions with its owned metadata read. Entering a
local badge, requesting its tooltip or reading its accessible help also refreshes
local descriptions without walking history or modifying selection. Native reads
are asynchronous: the existing captured description supplies immediate help
while the new read finishes, rather than blocking the main thread on Git as the
Windows handler does. A failed read restores ordinary tooltip fallback. Requests
capture history generation, hash, canonical ref, cancellation and access. Hover
changes, reload and closure cancel the original request; the existing reference
read counter retains its actual work/scopes through late completion and Quit.
Retired or superseded replies cannot replace current metadata.

## Painted hit geometry and native accessibility

The existing colored, rounded tracking and pointed-tag painter remains in use.
Pointer hit testing and native badge accessibility use the same clipped,
half-open rectangles and canonical names; repeated upstream names retain the
last painted rectangle as in the source map. New attributed text, font or size
invalidates old hit geometry immediately, before repaint. Repaint publishes a
new accessibility generation when label geometry changes.

Visible badges are native accessibility buttons within the message group. Their
label uses the displayed badge, their value retains the canonical reference,
and their help follows the source tooltip policy. Press/Show Menu selects the
owning row and opens the existing icon-bearing pointed-reference popup at the
badge, scrolling it into view. This is a macOS accessibility adaptation of the
source pointer target, not a new Git operation. The normal row keyboard menu
continues to use its unpointed/background policy.
The pointed popup explicitly prepares its delegate-owned items and one-shot
action receipt before first presentation; it does not rely on menu tracking
to populate an initially empty menu.

Buttons retain weak owners and the painter generation. Hidden columns, detached
fields, changed geometry, busy/child/Quit states, reload and retired models refuse
stale actions. Context callbacks re-resolve the same commit and canonical ref;
clipboard/menu dispatch still uses the existing one-shot menu receipt. No
symbolized label becomes an operation argument.

## Grouped verification scope

`HistoryReferenceTooltipTests` covers source precedence/fallback, empty and
multiline descriptions, UTF-16 bounds, first duplicate, case/NFC/NFD identity,
actual local Git reading, cancellation and unchanged configuration/index state.
`docs/qa/log-reference-interaction-native-2026-10-18.swift` exercises the real Log
model/table/painter, fresh hover reads, original subject fallback, accessible
canonical context/copy, busy refusal, invalidation before redraw, held late-read
cancellation/accounting and unchanged HEAD/index/input bytes. The parent owns
the grouped checkpoint and records results; fixture existence alone is no pass.

Physical tooltip timing/placement, pointer/VoiceOver menu discovery, source GDI
versus AppKit clipping/Retina behavior, all font extremes, signed sandbox access
and other shared-list consumers remain unverified. These checks do not certify
complete Log visuals, complete localization or whole-app parity.

Actual build/check outcomes and remaining acceptance limits are recorded in the
[grouped batch evidence](qa/metadata-port-2026-10-18.json).

## Message text alongside reference badges — October 29, 2026

The custom message field previously exposed an accessibility group containing
only its painted reference buttons. A commit without references consequently
had no message-text child, and a labeled commit exposed its badges without its
subject. This was a native semantic omission, separate from the displayed-row
selection race fixed in `956335f4` and documented in [Log parity](LOG-PARITY.md).
The selection fix accepts still-current displayed hashes across a pending model
projection; it does not reinterpret an old row number against newer history.

Log and the Rebase replay table now supply the actual configured message as a
passive native static-text child alongside the existing reference buttons. The
value contains the complete configured single-line/full-message presentation,
including text hidden by visual truncation. It excludes badge padding and
attachment characters. Reference labels retain their separate canonical values,
help and existing pointed-menu actions. The text child adds no press action and
does not take selection or keyboard handling away from the native table.

Semantics carry the owning model and commit identity. Rebase additionally uses
the replay occurrence identity, so repeated occurrences of the same hash remain
distinct. Reused fields retire old text and badge children when their semantic
owner changes. Hidden message columns, removed occurrences, detached or retired
owners and unavailable visible geometry expose no stale text value or frame.
The text frame follows the field's clipped native screen geometry. A font or
reference-paint invalidation retires badge hit rectangles without unnecessarily
retiring unchanged message text; badge actions still require both current
semantic ownership and current painted geometry, with the original busy/modal/
Quit gates.

A prior physical observation of installed build27 showed that mouse and Down-key
selection could display the selected commit message and changed files while
history loaded, even though its accessibility tree omitted row subjects. That
observation establishes neither delivery of this later semantic change nor
spoken VoiceOver output. In the same limited Settings observation, `origin` was
present in the native Remote list, and no-edit Cancel and OK closed Settings;
there is no new Settings repair or general Settings certification in this batch.

The [native semantic checkpoint](qa/log-message-accessibility-2026-10-29.json)
records the actual parent validation result. Its private fixture covers plain
and reference-bearing Log rows, native selection/message/files, full Rebase
messages and duplicate occurrences, provider replacement, hidden/retired owners,
and retained badge/hover cancellation behavior. Fixture existence is not a
pass. No Core operation changed for these semantics. Physical VoiceOver speech,
compositor hit testing, signed delivery of this change, complete hosted CI and
whole-dialog/whole-port parity remain separate acceptance scope. RefLog and
Blame use ordinary native text fields, and Revision Graph already has semantic
nodes; this change does not claim they shared the omitted-text defect.
