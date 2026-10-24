# Native file-list interaction ownership

This family preserves FullRowSelect, status colors, native selection and embedded
controls while making shared list decoration safe across row creation, reload,
sorting, delegate replacement and retirement. Implementation and grouped native
checks initially passed Debug and six native case/engine pairs after recorded
fixture-oracle repairs. A subsequent physical Debug Log check confirmed a real
duplicated-label defect; measured geometry and direct text drawing now pass
focused native consumers and bounded physical Log acceptance.
[QA record](qa/native-list-interactions-2026-10-25.json).

## Source contract

Pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d` defines
`FullRowSelect=true` in `Settings/SettingsAdvanced.cpp:46`.
`TortoiseProc/ResizableColumnsListCtrl.h:86–93` enables
`LVS_EX_FULLROWSELECT` conditionally alongside header drag/reorder. This is a
selection-painting preference, not a replacement selection model.
`Git/GitStatusListCtrl.cpp:1255ff` distinguishes selected/focused transitions
from checkbox changes. Its context menu uses the selection mark and hit-tested
column at 1639ff, and drag at 3767ff uses the selected file paths.
`StoreScrollPos`/`RestoreScrollPos` at 899–931 retain scroll position and the
selection/focus mark. The primary Log commit list explicitly uses full-row
selection at `TortoiseProc/GitLogListBase.cpp:264`; this family concerns the
shared native file/reference list decorator, not replacing that Log graph/list.

## Native implementation

`NativeListSelection` keeps the table's selected indexes, keyboard navigation,
context clicks, accessibility and embedded controls under native/consumer
ownership. Full-row mode uses ordinary AppKit selection; disabled mode draws
only the measured primary label, retaining row backgrounds, source status
colors, key-window emphasis and high-contrast behavior. The drawing overlay
does not accept mouse hits or become an accessibility element.

Row factories now configure only the supplied row. They do not request table
cells, enumerate table rows or reorder subviews while AppKit creates a row.
Deferred, coalesced reconciliation checks the current table/delegate/owner and
generation, then uses current row mappings to update cell backgrounds and
place the existing label overlay. Reload/sort cannot replay a captured obsolete
row index. This addresses a concrete reentrant construction path; earlier
NSTableView warnings had no stack proving that this was their sole cause.

Cross-table row reuse releases the previous owner's decoration and restores its
saved style before binding the new owner. Retirement invalidates queued work,
restores only rows it still owns and releases its overlay/observers. A late
update for a closed window cannot revive its owner. Explicit remove/reinstall
or reparenting into a different live window permits fresh attachment. Replacing
the native delegate retires the old proxy before capturing the replacement.
The SwiftUI probe preserves the primary column object through reorder, but
resolves a new one when the schema replaces that object.

Consumer replacement exposed a related ownership gap: a retired predecessor's
late teardown could remove decoration installed by its successor on the same
native table. Install/remove now accept a trailing optional client object,
retained weakly with exact identity. `CommitFileInteraction` and the shared
probe pass themselves consistently; predecessor removal cannot retire the new
client, and a closed client's late install cannot revive the same owner. Existing
callers without a client keep their previous API contract. Pending interaction
configuration also retains its existing active/generation fence.

The same delegate replacement could leave keyboard routing consulting the old
coordinator: `WorktreeListTable.swift:255` uses `originalDelegate(of:)` to route
F5. That accessor now unwraps only a live proxy which is still the table's actual
delegate; otherwise it returns the current native delegate. The lifecycle case
includes a real replacement delegate. This is bounded keyboard-routing
correctness, not full physical keyboard acceptance.

Commit, Log changed files and Working Tree continue using
`CommitFileInteraction` for menu snapshots, checkbox/focus independence, drag,
keyboard selection, column layout and refresh-position ownership. Its teardown
removes shared selection decoration; replacing a table removes the previous
table's owner with its own client receipt. Context clicks retain native highlight/anchor and resolve the
clicked row into a captured menu request, an existing macOS interaction
adaptation. The shared decorator does not dispatch Git operations or reinterpret
checked versus highlighted files. Bounded caller review found no additional
demonstrated menu/checkbox/drag action gap beyond that client handoff repair.

## Checkpoint and remaining scope

The authored [fixture](qa/native-list-interactions-native-2026-10-25.swift) and
`scripts/test-native-list-interactions.py` exercise `callbacks`, `lifecycle` and
`consumers` with both Git executables: row callbacks without recursive cell or
hierarchy work; forwarding/custom rows/colors/label/full-row/sort/reuse;
client/delegate replacement, retired callbacks and reparenting; and actual
Commit, Log and Working Tree checkbox/multiselection/sorted drag/watermark paths.
The consumer cases reuse the existing report/workspace fixture symbols.
Checks use private repositories,
preferences and pasteboards, offscreen owned windows and cached receivers.
Debug session 41727 exited zero, retaining three contradictory exit-zero
diagnostics. Localization session 23162 passed 38 locales/1,318 labels.
Initial native session 10240 failed callbacks/system with “Custom row subclass
was replaced” (receiver 79625 reaped). The fixture's exact class/cast oracle was
replaced with original object identity plus the runtime class chain, since
decoration deliberately subclasses a supplied row. Focused session 39362 then
failed “Native row absent” (79745 reaped); offscreen lazy row acquisition now
requests materialization. Session 9520 passes identity/class-chain assertions
but fails the custom background-color assertion (79826 reaped). Investigation
found that AppKit sets an attached selected row's background to RGB
`0.117647/0.117647/0.117647`, including without the adapter, instead of the
factory's requested `0.31/0.18/0.45`. The adapted row matches that independent
native baseline. Focused session 51524 passed callbacks/system (79972 reaped),
proving the exact original delegate-emitted object and superclass chain, plus
explicit reuse marker/object/class/background assertions. Delegate installation
itself recreates native rows, so no same-object claim is made across the entire
binding, nor a blanket arbitrary custom draw-color guarantee. All three previous
failures are retained as fixture acquisition/oracle issues; production source
did not change after Debug.

Session 29901 passed lifecycle/consumers with both Git executables (receivers
80002, 80019, 80308, 80318), and 12407 passed bundled callbacks (80565). Together
with system callbacks these are six distinct case/engine passes. All nine
attempted receivers, including the three earlier failures, were reaped and
independently absent; no GUI/cache remained, preserving installed Finder 77954.
None of the final logs emits the reentrant delegate warning. That bounded result
does not prove global resolution or the precise origin of the earlier warning:
the workloads differ and no original stack established its cause.

Six optional light/dark label-only consumer PNGs were captured under
`build/qa/native-list-interactions-captures-2026-10-25/receiver-80019`. The parent
reviewed all six and found transparent/incomplete compositing, missing normal
glyphs/icons and overlapping left label text in dark Log. They remain diagnostic
artifacts, unsuitable for full visual acceptance or website publication. A
subsequent deliberate physical Debug Log check independently showed original
`a`/`b` labels visible to the left of their highlighted overlay: that is a real
geometry defect, not merely offscreen compositing. Evidence remains under
`build/qa/native-list-interactions-physical-2026-10-25`.

The repair adds `NativeListSelectionLabelMarker`, a public NSView-backed
measurement of each primary Text label, wired into Commit, Log and Working Tree
cell backgrounds. The adapter can then cover the actual native label bounds
rather than approximate an unexposed SwiftUI text position. Actual geometry
assertions were added. The initial six passes remain historical evidence.

Geometry Debug session 6247 exited zero, retaining seven contradictory exit-zero
diagnostics. The fresh all-six native run 41843 checks compare
actual marker bounds converted into table coordinates against label text bounds
within 0.5 point, require the highlight to cover both label edges, and verify
hit/accessibility transparency, resize, path-column reorder/restore and both
appearances across all three tables. They run even when optional image capture
is disabled. Run 41843 passed all six pairs (reaped receivers 81365, 81375,
81415, 81713, 81723, 81733). This remains a historical geometry checkpoint,
rather than final physical acceptance: the next physical Log observation shows
the duplicate left glyphs fixed, but early `alpha....`/`beta....` truncation.
The initial padding hypothesis was not proven: an AppKit probe (session 41204)
showed identical drawing/title rectangles. Padding Debug 80509 exited zero with
one contradictory exit-zero diagnostic, but its physical check showed no visible
improvement. That inverse-frame helper was removed.

The final marker path draws attributed text directly into actual measured
content bounds; ordinary native-field fallback remains unchanged. Final Debug
9477 exited zero with two contradictory exit-zero diagnostics. Focused consumer
run 28727 passed both Git executables, including strengthened actual attributed
layout snapshots; receivers 82756 and 83046 were reaped. The prior fresh 41843
callback/lifecycle coverage remains applicable to this drawing-only repair.

Deliberate physical Debug Log checks in system dark and explicit Light show full
`alpha.txt`/`beta.txt`, without original left glyphs, while source icons, status
and graph remain unaffected. Final images are `log-system-text-repaired.png`
and `log-light-text-repaired.png` in the physical evidence directory above.
Earlier repaired/padding images remain failed attempts. This is bounded Log
acceptance, not complete visual acceptance of all three consumers.

Physical precheck cleanup restored the absent FullRowSelect preference baseline,
left Follow System unchanged, forgot only Harbor's fixture permission while
retaining TiaFileFormat, and quit Debug. The private index/config/six file hashes
are unchanged; one installed Finder registration remains elected and Finder
77954 is preserved. Temporary FullRowSelect=false/Harbor permission were retained
only across the physical repairs. Final cleanup restored Follow System through
the UI and removed FullRowSelect through Advanced empty Apply; after Debug quit,
the original absent appearance key was restored with defaults delete. Immediate
plist reads were stale, so authoritative defaults reads verified both keys
absent. Only Harbor was forgotten, preserving Tia Recent. No owned GUI/cache/
receiver remained; installed Finder 77954 and its single elected registration
are unchanged. HEAD, raw index, config and all six fixture file hashes remain
unchanged.

No Core behavior or Git command
change is included, so this native-only family does not require a full Core run.
No new signed build or installation was performed. The installed app remains
the prior `3a72244e` candidate; that earlier physical acceptance is separate
from this source-level/native checkpoint.

Remaining scope includes complete physical keyboard/VoiceOver/window focus
acceptance, every shared-list consumer, source visual identity of every dialog,
full current hosted CI and App Store archive/export/submission. These bounded
passes do not certify the whole port or retrospectively erase prior warnings.
