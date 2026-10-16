# Finder overlay settings — implementation in progress

Reference: pinned SetOverlayPage.cpp, SetOverlayHandlers.cpp, ShellCache.cpp's
CPathFilter, IconOverlay.cpp and their resource dialogs at
7338078f8ddd924b8cddee35f512f2286072136d.

The native Settings tree now includes Icon Overlays and its Overlay Handlers
and Icon Set children with the original Overlays.ico. Source group order is retained: overlay
propagation controls, status cache, drive types, exclude/include editors and
Show excluded folders as normal. Windows A:/B: drive and DLL/elevation switches
have no direct Finder Sync counterpart; Finder provides the extension surface.
Default uses the containing app's cached detailed status. None projects normal
badges on known repository folders, without file-state badges. The containing
app still reads status for its own UI and context-menu eligibility. Shell and
Shell Extended cache semantics are pending and are not exposed as working modes.
Unversioned/subrepository propagation controls are disabled in None mode.

Volume preferences cover fixed, removable, network, optical, RAM and unknown
volumes. Optical/RAM filesystem names and native local/removable volume metadata
supply classification. The extension classifies monitored roots on reload; mount
boundaries within a repository and native RAM-disk representations need acceptance.
Default source drive mask is fixed drives only. Include/exclude rules override
the drive mask. More specific paths win, equally specific include rules beat
excludes, and exact-only rules override recursive rules for that path. A terminal
* or no suffix applies to descendants; ? applies only to the named path. Native
~/$HOME expansion replaces Windows environment expansion without a shell. Rule
matching currently follows the cached path spelling; case-insensitive volume
behavior, duplicate mixed exact/recursive edge cases and symlink spelling remain
open. Invalid relative/NUL paths cannot be saved.

Overlay Handlers offers working ignored, unversioned, added and deleted toggles
with original status artwork. Normal, modified and conflicted remain enabled in
the UI. Skip-worktree and assume-valid/unchanged handlers now use the original LockedIcon
and ReadOnlyIcon artwork. The containing app reads NUL-delimited `ls-files -v`
index flags for main repositories and scanned submodules, preserving Unicode and
newline paths. They apply only to normal files: skip-worktree has precedence over
assume-unchanged; disabling a handler allows the other active flag or normal badge.
Changed/conflicted status has precedence. Refresh removes stale child flags while
preserving independently opened repositories. The complete source page is not certified.
Finder has no Explorer overlay-slot allocation or cross-Tortoise registry control.
Icon Set offers all 16 pinned source sets, including List and Symbols previews.
All 144 ICO assets are copied without modification, with original per-set notices
and SHA-256 provenance. Apply saves the selection with the shared overlay draft;
Finder re-registers all nine images and clears/reassigns cached badge identifiers
on a set change. Live Finder refresh acceptance remains pending.

Settings pages share one draft and property-sheet Apply/Cancel participant.
Apply atomically publishes overlay-settings.json in the signed App Group, saves
local preferences and posts the existing distributed status notification. Unsigned
builds save the draft locally and explain that signed group access is required.
Application startup publishes the saved settings when that container is available.
The extension reloads policy and recalculates badges, including clearing paths
whose badges were hidden. It continues monitoring all cached repository roots so
context menus remain available regardless of overlay policy. Finder launches no
Git processes.

FinderSnapshot now optionally retains direct overlayEntries independently from
its existing aggregated states. New snapshots compute parent badges from direct
entries: unversioned files keep their own unversioned badges, while their parent
contribution is normal or modified according to the checkbox. Ignored entries do
not dirty parents. Registered subrepository roots contribute above their roots
only when requested; the parent's own Git gitlink status remains meaningful.
Excluded known folders project normal when requested; excluded files lose their
badges. Hidden handlers suppress presentation without changing cached menu state.
Older cache JSON remains decodable and falls back to legacy states until refreshed.
Subtree replacement preserves direct entries for independent cached repositories.

Grouped Network/Finder validation: Debug arm64 Xcode build exited 0; 22 focused
Core tests passed, zero failures, 7.692 seconds. Coverage includes proxy URL/
credential/IPv6 round trips and invalid inputs, real global proxy writes with
local and URL-specific preservation, sanitized lock failure, SSH override/App
Store selection and real OpenSSH check/cancellation, path-policy precedence,
unversioned/handler/subrepository/None badge projection and persistence, snapshot
leaf round trips, existing Finder menu settings, child scans and subtree metadata.
No app was launched and no full suite was rerun. Xcode emitted existing warnings
and seven unusual SwiftCompile diagnostics reporting exit code 0 with no output;
this is not a clean diagnostics claim. See
`qa/network-finder-settings-batch-2026-10-11.json`.

Grouped icon/index/menu continuation: native Debug arm64 Xcode build exited 0;
34 focused Core tests passed with zero failures in 6.585 seconds. The native
framework contains all 144 overlay ICO assets. All nine badges in all 16 sets
decode to actual AppKit pixels at 16 and 32 points. Tests cover live Git flag
reads with Unicode/newline paths and both bits, unchanged index bytes, flag
clearing/cancellation, badge priority and disabled handlers, exclusions/None,
old/new preferences and snapshot compatibility, stale-child flag removal,
independent repository preservation and known-root menu classification.
Existing menu/icon/submodule/Network checks ran in the same grouped pass.
No app was launched and no full suite was rerun. Xcode again reported seven
exit-zero/no-output SwiftCompile diagnostics alongside existing warnings.
See `qa/finder-icons-batch-2026-10-11.json`.

Native Finder badge refresh, settings focus/layout/theme, mount classification,
App Group notification propagation and signed sandbox acceptance remain open.
Known repository roots now retain versioned menu classification even when their
aggregated status is unversioned, ignored or absent. Creation-menu classification
also recognizes those roots, preventing extended-menu Initialize there. Untracked
files retain their Add eligibility and are not classified as versioned. Raw cached
status remains unchanged; narrow tests do not prove complete context-menu parity. The full port and
inventory certification remain incomplete.


## Native shared Overlay pages — 2026-10-12

Compared the source main groups, six optional handler controls, and Icon Set's
List/Symbols selector and Apply behavior. The native pages now scroll so the
main controls remain reachable at a smaller window height. The list preview has
a bounded scrolling area; Symbols retain the existing grid. Handler artwork
uses the selected set rather than a fixed status icon. Path editors have named
accessibility labels. All pages still share one Settings participant and draft.

The model captures a validated policy for publication/local persistence, then
notifies Finder only after both succeed. Invalid input cannot invoke publication.
Publication failure retains unsaved fields and leaves local settings unchanged.
An unsigned local-only save has a separate informational notice; failures display
as errors. Cancel clears both messages and restores all shared fields. Preferences,
publication and notification adapters are injectable while production uses the
existing signed App Group and distributed notification.

Debug build exited 0. One object-linked native receiver compilation/process
passed and was reaped. Three private hosts at 760 × 530 were constructed in Aqua
and Dark Aqua, with native scrolling surfaces present. Shared Settings Apply,
Cancel and invalid-policy refusal, private atomic file publication/readback and
path-rule precedence, notification-after-preferences-save, failed-publication
draft retention and unsigned save/notice/no-notification behavior passed. No
Finder extension was activated; user preferences and App Group data were not
changed. Core projection/asset APIs were unchanged and their prior grouped
checks were not rerun. No full fourteen-case group or new screenshot is claimed.

The three source resources are now partial-native-replacement. Physical controls/
keyboard/VoiceOver and complete visual matching, Symbols switching, actual Finder
refresh/notification/volume boundaries, watched-root management and signed
sandbox/App Store acceptance remain open. Windows registry/elevation/overlay-slot
controls still require macOS adaptation; no dialog is certified complete.

## Volume-aware path rules and badge aliases — October 15, 2026

The active `ShellCache.cpp` CPathFilter parser/merge/lookup defines terminal
`*`/`?`, include/exclude ties, exact-path overrides and ancestor precedence.
Those rules now compile into literal and case-folded lookup tables once per badge
projection, instead of reparsing every path rule for every file. The deepest
recursive ancestor applies, exact-only entries override that same path without
changing descendants, and duplicate includes win within the same rule category.
CRLF editors and native `~`/`$HOME` expansion retain their source meanings.
Validation names the first invalid editor and line; invalid drafts cannot publish
or grant a partial include exception. The native page displays live diagnostics
and valid include/exclude entry counts, with Apply/Cancel still shared.

The Finder extension now resolves volume kind and name-case sensitivity for each
containing directory rather than assuming all paths use their repository root's
volume. Metadata is cached for files sharing a directory during a refresh; a
mounted child directory has its own result. Deleted items fall back to an existing
ancestor. Final symlink entries use their containing directory rather than the
link target's volume. Unknown volume/case information remains conservative.
Volume mount, unmount and rename notifications also rebuild the overlay policy.
This uses native filesystem metadata and starts no Git process in Finder.

Rule spelling and badge requests now follow the target volume's case behavior.
Insensitive-volume names fold case and canonical Unicode spellings. Sensitive
volumes retain literal byte distinctions. An immutable badge lookup handles an
alternate Finder spelling and chooses the highest-priority state for conflicting
cached aliases. Refresh-time assignments use that same lookup so clearing an old
spelling cannot erase its replacement alias. Path masks and optional index-flag
handlers share the per-path volume/case decision; menu eligibility keeps its
original cached Git status independently.

This supersedes the earlier cached-spelling/root-volume limitations for the
implemented lookup and projection. Real network/RAM/optical mounts, permission
failures, filesystem Unicode edge cases, mount churn during a snapshot read,
physical Finder activation and signed sandbox/App Store acceptance remain open.
Shell and Shell Extended's alternate Windows status engines remain unported and
are still not exposed as equivalent working modes. All 16 existing icon sets,
handler choices and the independent cache service retain their prior behavior.

Validation: Debug app/framework/Finder-extension build exited 0. The first grouped
Core run passed 18 of 19 checks; the Unicode rule test exposed Foundation path
normalization and passed after lexical normalization replaced it. All 19 grouped
checks passed after that repair; the 11 affected overlay checks passed after the
lazy metadata-lookup continuation. Both native shared Settings cases passed with
private preferences/publication and their receivers were reaped. Thirty current
controls now have explicit partial source mappings; alternate Windows engines and
unmapped platform controls remain pending. See [path-policy evidence](qa/overlay-path-policy-2026-10-15.json).

The helper's [optional cache menu](CACHE-MENU.md) now changes only cache mode in
the latest valid shared overlay record. App startup and new overlay Settings
owners honor that accepted shared record; private preference stores stay isolated.
Corrupt records are not overwritten by menu actions. Existing Settings drafts
retain their explicit Apply/Cancel semantics.
