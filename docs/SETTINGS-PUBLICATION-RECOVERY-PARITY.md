# Accepted Settings publication and recovery

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Settings/SettingsAdvanced.cpp:36–71,136–143`. The source stores Advanced values
in the registry shared by the application, shell and cache. macOS separates the
application's preferences from the Finder/helper App Group files. A successful
local save therefore needs a separate publication outcome.

Related source pages: `IDD_SETTINGS_CONFIG`, `IDD_SETTINGSLOOKANDFEEL` and
`IDD_SETTINGSEXTMENU`. Their existing mappings remain partial; this continuation
reviews accepted publication and recovery, not every control or layout state.

## Connected workflow

The Advanced `CacheSave`, `CacheTrayIcon`, `ShowAppContextMenuIcons` and
`ShowContextMenuIcons` settings retain their existing native controls and defaults.
Accepted local values create durable pending publication requests for cache
persistence, cache-menu presentation and Finder-menu policy independently.
If one channel fails, successful peers stay accepted; each failed channel remains
available for Apply without another edit. Error dismissal and Cancel do not
forget an already accepted value. Reopening Settings recovers pending requests.
Unsaved edits retain the ordinary Cancel behavior.

A retry reconstructs the payload from current accepted preferences, retaining
newer language, menu placement and icon choices rather than replaying an old
whole-menu snapshot. Request identities keep an older completion from clearing
a newer request. This is process-local completion serialization around durable
UserDefaults intents, not a cross-process transactional database. A channel's
publisher still owns atomic shared-file writes and its consumer notification.
A superseded publication leaves Apply available and reports that another retry is
needed; the property sheet does not close as if synchronization succeeded.
No repository grant, watcher registration or Finder restart is introduced.

Unavailable App Group storage is a publication failure, not a successful update.
Pending state is distinct from unsaved edits: retrying it does not replay local
setting changes or their application callback. Owner retirement refuses later
channel dispatch; accepted pending work remains recoverable by a new owner.
Advanced retains accepted editor text after Apply, including a blank reset or an
overflowing number whose stored DWORD is clamped. Cancel/reopening reloads the
canonical stored value, matching the source list editor. The existing
status-policy transaction and rollback remain a separate operation.

Workspace startup captures accepted preferences when services actually start,
rather than when its model was constructed. Its detached publisher reports each
channel separately. Settlement acknowledges only matching requests and current
payloads; cancellation or owner retirement still preserves recovery for a late
old write. No UserDefaults or UI model crosses the worker boundary. The General language
and Context Menu pages retain their publish-before-local-save draft behavior;
an accepted local save without shared access also records a Finder retry.
The Advanced retry publishes its full current packet, including those choices. An old
in-flight worker can briefly publish an earlier shared payload before settlement
detects the mismatch; the latest saved choice remains pending for explicit Apply.
This recovery is not cross-process publication serialization.

## Evidence and limits

The [dated grouped record](qa/settings-publication-recovery-2026-10-29.json)
records the focused intent checks and actual native models/property-sheet
transaction checks, including failure, partial success, retry, reopening,
supersession and retirement. A fixture's existence is not evidence of a pass.
Installed build34 predates this continuation. Physical Finder/helper consumption,
signed App Group permissions, every Settings page, full hosted integration and
complete source layout parity remain separate acceptance gates.
