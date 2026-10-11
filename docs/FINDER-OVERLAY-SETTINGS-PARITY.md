# Finder overlay settings — implementation in progress

Reference: pinned SetOverlayPage.cpp, SetOverlayHandlers.cpp, ShellCache.cpp's
CPathFilter, IconOverlay.cpp and their resource dialogs at
7338078f8ddd924b8cddee35f512f2286072136d.

The native Settings tree now includes Icon Overlays and its Overlay Handlers
child with the original Overlays.ico. Source group order is retained: overlay
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
the UI. Skip-worktree and assume-valid/unchanged overlays require additional
index metadata/artwork and are pending; the complete source page is not certified.
Finder has no Explorer overlay-slot allocation or cross-Tortoise registry control.
The original icon set is retained; source icon-set switching is still pending.

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

Native Finder badge refresh, settings focus/layout/theme, mount classification,
App Group notification propagation and signed sandbox acceptance remain open.
Legacy aggregated menu status for roots containing only unversioned files also
needs a separate menu-eligibility review. This batch preserves that raw status;
narrow badge tests do not prove complete context-menu parity. The full port and
inventory certification remain incomplete.
