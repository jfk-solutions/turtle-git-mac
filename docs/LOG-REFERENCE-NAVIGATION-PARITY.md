# Log reference navigation

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, LogDlg's
`IDC_STATIC_REF`, ShowStartRef, OnContextMenu, OnBnClickedBrowseRef, RegHistory,
GetLogCmd's reference masks, and BrowseRefs' two-reference OK menu.

The upper-left Log label now shows the actual start reference or scope and opens
its own native reference browser. Its original-icon context menu offers Browse
references, HEAD/current branch, FETCH_HEAD, all refs, basic refs, local branches,
and repository-specific recent selections in source order. The full reference
expression remains available as a tooltip when the display label is shortened.
Long recent labels are shortened for presentation while their underlying values
remain exact. The root path continues to identify the window in its title.

All refs uses --all. Basic refs uses --branches, --tags, --remotes,
--glob=stas[h] and --glob=bisect, including source stash/bisect namespaces while
excluding arbitrary other refs. Local branches uses --branches. These control
which history is walked independently of the existing reference-label visibility
filters. The native All Branches checkbox is mixed for basic/local scopes; clicking
it returns to the current scope. Reference-set commands are unavailable while
Follow Renames is active. Explicit multi-tip and range choices retain Follow Renames and its existing
single-file path preflight. They do not impose a single-tip restriction absent
from the pinned browser/range flow. Switching to an explicit
reference resets the reference-set masks.

Browser selections can contain one reference, multiple tips, either directional
two-ref range, or a symmetric range. Every supplied tip is resolved separately
through rev-parse --end-of-options before the history walk. No expression is sent
through a shell. Two selected references expose the source-style OK menu: the
combined selection, both directional ranges, and one symmetric range. Other
picker callers retain their normal OK button unless they explicitly opt into
this range menu. Native ranges retain qualified identities to avoid ambiguous
branch/tag names. Existing source reference comparison and context routes remain.

FETCH_HEAD is resolved again under an owned read before dispatch, so its last
loaded label does not silently pin a stale fetched commit. Missing FETCH_HEAD is
disabled; if it disappears during preparation no new history is selected. Branch
and FETCH_HEAD metadata share cancellation with the history refresh. No fetch or
other network operation is performed by these choices.

Recent selections use an exact per-repository history and MaxRefHistoryItems,
with source default 5. RegHistory reads one entry at limit zero and permits one
extra newly added entry when saving; the native store retains that distinction.
It reloads before adding, moves only an exact UTF-16 duplicate to the front, and
keeps case and canonically distinct Unicode spellings separate. HEAD, FETCH_HEAD
and reference-set quick choices do not add recent records. Picker/recent choices
do. This store is separate from ChooseVersion's session-only combo and does not
introduce an unsupported Saved Data clear button for log-refs.

The browser sheet owns its source Log until it closes. Accepted selections survive
windowWillClose's ordering; refused presentation, cancellation and forced parent
retirement release ownership once. A delayed old selection cannot change the
new range or persistent history. Reference-browser load/current-branch reads and
FETCH_HEAD preparation retain global accounting until their cancelled Git child
settles, including after the window has been removed; Quit remains blocked during
that work. The browser retains the parent's repository access lease.

The repaired Debug build passed. The 76-test affected Core group found one
legacy nested-remote fixture failure; its focused recheck passed, giving all 76
cumulative passing evidence without repeating the full group. Eight grouped native
cases passed across system and bundled Git, including the actual mixed NSButton
and range-picker callback ordering. A final source-alignment correction removed an added single-tip Follow restriction:
one affected Core walk and two native Log checks passed afterward. All ten
initial/final owned receivers were reaped. See
[actual results and repairs](qa/log-reference-navigation-2026-10-14.json).
Full physical pointer/keyboard/VoiceOver interaction, exact Windows long-label
truncation, whole-window visual acceptance, signed sandbox/Finder execution and
full application parity remain open.
