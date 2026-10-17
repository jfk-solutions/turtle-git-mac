# Merge General settings

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseMerge SetMainPage.cpp and MainFrm.cpp's load-navigation selection.

Merge Editor Settings now provides Jump to first difference when loading,
Jump to first conflict when loading, Font family/size and Max line length for
inline diffs alongside the existing General options. Its content scrolls so
all controls remain reachable. The native fixed-pitch family popup previews
each family; the editable size combo shares the existing native font picker.
Apply persists valid drafts and notifies open panes; Cancel restores the draft.

Source defaults are Consolas, 10 points, an inline limit of 3000 UTF-16 units,
and both load-jump flags enabled. Missing or non-fixed-pitch families use the
native monospaced face while retaining the saved family name. macOS supports
6–72 point sizes and 0–100000 inline units; malformed preferences are bounded,
and invalid draft fields prevent Apply. These are explicit native input limits.

Font changes update both comparison panes and all three-way panes without
regenerating text, clearing Undo or changing file encodings. Tab intervals use
the new font metrics. Ruler fonts follow the editor size and their gutter grows
for the largest original line number, including large font sizes. Line ending
markers and locator viewport tracking use the updated native glyph geometry.

Two-pane inline calculation checks both lines against the configured bound,
including direct model requests. Changing the bound clears the inline cache.
Only changed rows within the limit run the existing character/word comparison;
this does not add full three-pane character differences.

Two-pane load navigation runs after authoritative engine results, once per load,
not after each edit or filter change. Selection/scroll requests wait for their
actual native pane registration; models without hosted panes do not queue an
unconsumable UI request. Turning FirstDiff off retains the normal no-auto-jump
state. Three-pane load chooses the first unresolved conflict, otherwise the
first changed result line, according to the saved flags. As upstream, FirstConflict
has independent runtime priority even though its Settings checkbox is disabled
when FirstDiff is off. Disabling both flags suppresses the initial selection.
Existing explicit navigation and block-choice commands retain their meanings.

## Evidence and remaining work

The grouped Core checkpoint passed 24 tests with zero failures: source defaults,
private persistence, input bounds, inline limits, independent conflict priority
and the existing whitespace/endings/engine-presentation cases. The Debug build
passed with existing diagnostic noise. The first native batch exposed pending
selection requests in unhosted models; they now defer until actual pane registration.
See [the batch record](qa/merge-general-2026-10-12.json).

The repaired combined receiver reached the new General test after passing its
three-pane live-font and existing comparison/locator/whitespace/save checks.
Its final assertion incorrectly expected disabled jumping to clear selected-
difference metadata; the actual caret is retained. The corrected focused native
General receiver passed fixed-pitch fallback, live sizes, inline-bound cache
invalidation, enabled/disabled jumping and unchanged selection/history/files.
The entire combined receiver was not repeated after that fixture correction.
All owned windows/helpers closed, and verified failed-fixture leftovers were
removed. Physical Settings interaction remains unverified.

Remaining: physical Settings font preview/input/Apply/Cancel, full General page
layout comparison, large-font/large-file rulers and locator resize acceptance,
all gap/adjacent-difference initial navigation boundaries, complete three-pane
inline behavior, signed/minimum-OS and complete application acceptance.

The inline workflow now applies the source length cutoff per displayed pane,
including the line-diff preview. Three-pane source inline painting, word mode,
cache invalidation and two-pane chunk navigation are implemented in the connected
[inline batch](MERGE-INLINE-PARITY.md). Complete result-state and physical/signed
acceptance remain open; this supersedes the earlier absence of three-pane source
inline behavior.

## Source form and comment-profile ownership — October 17, 2026

The native Misc group now retains source Auto Add order, the paired Use spaces /
Smart tab controls and the tab-size / EditorConfig row. Font family/size remain
native fixed-pitch previews/editable presets. Diffing retains inline length,
Ignore line endings/case and signed context controls. The Windows Ribbon mode
uses the native AppKit toolbar/menu; no Office Ribbon implementation is claimed.
Additional supported view/comment settings remain in a following group.

A coherent observable draft now supplies all settings, validation and shared
Apply/Cancel. Form bindings capture model/revision, expire on reset, Apply,
visibility or ownership changes, and refuse old hidden/retired edits. Hidden
cached-page Apply remains authorized. Native font, signed context and UTF-8
controls honor enabled/attached/retired state; font owners detach callbacks on
closure. Existing identifiers, presets, serialized settings and consumers remain.

Comment Profiles now has an owned one-session draft. Validation, Restore Defaults,
OK and Cancel check the captured session and original parent text. Invalid/old
responses cannot accept text or revive a closed owner. The editor participates in
Settings/Quit guards before its sheet attaches. Closing or leaving the page
retires the session. Profile-file read/save failures are shown inline; Reload
Profiles discards only that profile draft, retaining unrelated settings for retry.
A failed profile save writes no other preferences and sends no Apply notification.
Accepted profile text is saved before the captured settings. A context change
after an already-authorized file write can refuse later preference writes; no
rollback of a completed profile write is claimed.

All 24 static resource controls now have explicit partial mappings, including
the native Ribbon adaptation. The Debug build and four grouped native families have passing checks: source form/profile ownership, live fonts/preferences, default encoding and patch settings/export. The build catch-shadowing error and three fixture issues are recorded with their focused repairs; no app rebuild followed those fixture changes. Both raw light/dark captures were individually reviewed: source groups, paired controls, fonts and additional options fit. All seven owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/merge-editor-source-family-2026-10-17.json) for exact attempts, capture scope and acceptance limits. Physical sheets/fonts/completion/keyboard/VoiceOver, every consumer and
large-file/encoding boundary, signed sandbox and full application parity remain
open.


The [October 17 connected pane batch](EDITORCONFIG-PARITY.md#connected-pane-commands-and-read-ownership--october-17)
adds source writable/loaded indentation-menu gates, captured commands, retained
loaded flags and owned cancellable EditorConfig authorization/parser reads in
both comparison and conflict editors. It does not certify the full General page.
