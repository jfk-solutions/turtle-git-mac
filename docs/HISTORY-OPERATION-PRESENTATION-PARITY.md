# Log feedback and Synchronization conflict recovery

This connected family follows TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It addresses operation presentation
and child-dialog ownership; it is not a complete Log, Sync or application audit.

## Log information, feedback and footer

Pinned `IDD_LOGMESSAGE` has fixed `IDC_LOGINFO` and `IDC_PROGRESS` bands.
`LogDlg.cpp` anchors the lower controls and constrains its splitters. The native
Log previously inserted separate progress/error rows below the file list, while
its information text could change between one and two lines. That changed the
space available to the three panes during ordinary reads and failures.

The native window now retains a 30-point information slot, a 24-point feedback
band and a 32-point footer. These are macOS dimensions, not Windows dialog-unit
equivalents. Generic work, patch reads and errors, patch-preference errors, notes
and clipboard reads share the bounded band in their existing order. Error text
retains its color. Initial history loading and the finished footer controls use
the same footer height. Split positions and their persistence remain separate.

The compact native status disclosure retains the complete raw text in its help
and accessibility value. It opens a bounded, selectable read-only snapshot.
Copy uses the owning Log's pasteboard. It refuses a replaced snapshot, blocked
owner, Quit or retirement, and stays unavailable while another Log clipboard
read owns the pasteboard. Passive reading can remain available during work.
Status changes retire the displayed snapshot. Server diagnostics and user text
are not translated as UI keys.

## Owned Synchronization resolution

Pinned `SyncDlg.cpp` restricts conflict rows to their source actions, and
`GitStatusListCtrl.cpp` runs quick Resolve with its confirmation/progress before
returning to the parent. Native Sync now presents a fresh owned Resolve sheet,
separate from the application's cached standalone Resolve windows. It retains
the submitted paths, repository, backend, folder access and originating
preferences. Edit and Log routes also retain those preferences.

The parent stays blocked through the child's confirmation, actual Git work,
result and native sheet detachment. Nested submodule Reset belongs to the same
chain. Forced parent closure cancels and drains its owned children; a late reply
cannot reopen or refresh the closed owner. Repository notifications and the
optional post-resolution refresh follow actual drainage, using the originating
`RefreshFileListAfterResolvingConflict` preference. Standalone Resolve retains
the shared interaction configuration and its existing lifecycle.

Initial Resolve loading is idempotent across its presenter and SwiftUI
attachment. This prevents a duplicate read from replacing the generation of an
already displayed confirmation. Explicit later refresh remains available.
No and completed Close follow controller policy instead of relying on a sheet's
titlebar-button action. Question drainage checks both the child and parent native
links before returning. Reset Cancel and forced retirement retain their tracked
workers until actual completion, excluding the release object itself from its
readiness predicate.

Conflict Clipboard now includes Extensions with the existing source copy icon.
It uses the captured file-menu selection and the shared file-list formatter;
stale or child-owned menu callbacks cannot copy a newer selection. The existing
model-only callback seam remains explicit in its retained routing fixture.

## Remaining work

The [dated checkpoint](qa/history-operation-presentation-2026-11-22.json) records
eight distinct native case/engine passes cumulatively, including retained Log
controls and Sync file actions. Failed driver/oracle attempts and actual initial
load/closure repairs remain recorded. Real-controller geometry covers normal
short/long information; explicit one/two/overflow lines separately exercise the
same production information component. Only affected cases were repeated.
All 23 recorded compiler/receiver PIDs and workspace runtime images are absent.
Installed52 and the frozen signed53 package are unchanged; signed54 has prepared
dependencies but no application build yet.

The SwiftUI conflict table still lacks its own standard accessibility Show Menu
bridge. This batch does not replace that table merely for one entry route.
Physical keyboard/pointer/VoiceOver behavior, complete light/dark layout parity,
signed/physical Finder and platform coverage, full hosted CI and whole-port
acceptance remain separate. The grouped native checkpoint must retain its actual
scope, including the difference between a nested Reset cancellation seam and a
real conflicted-gitlink workflow.
