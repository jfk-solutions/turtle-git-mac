# Workspace ownership, retired documents and report lists

Actual installed acceptance of the `beadb01b` development-signed build exposed
three related native usability defects: Finder commands created extra main
workspace windows, empty rounded table stripes continued below real files, and
Quit resurfaced a previously closed Commit window and failed to finish. This
family implements the connected window/report ownership correction. Debug,
signed compilation and ten local native case/engine pairs pass after recorded
repairs. Static auditing, bounded repaired installed acceptance and owned cleanup
are complete. Remaining Status refresh/close usability, incomplete global app
window inventory and changed raw index bytes are recorded below.

## Source relationship

Pinned TortoiseGit is `7338078f8ddd924b8cddee35f512f2286072136d`.
`LogCommand.cpp:25–92` launches the requested Log dialog with `DoModal`;
`CommitCommand.cpp:40` and `DiffCommand.cpp:30` similarly dispatch their requested
workflows. These entry points do not imply creating a new repository workspace
behind each command. The Mac app retains one identified workspace scene while
owning its independent repository and editor dialogs.

The pinned resource report controls are `IDD_CHANGEDFILES` /
`IDC_CHANGEDLIST` at `TortoiseProcENG.rc:187–193`, `IDD_LOGMESSAGE` /
`IDC_LOGMSG` at `210–230`, and `IDD_COMMITDLG` / `IDC_FILELIST` at `245–278`.
They use `LVS_REPORT`, rather than a rounded inset list extending empty stripes
through unused space. This correction retains native macOS controls, source
status colors/icons and the existing row interactions.

## Implementation scope

- Reuse a single identified workspace scene for ordinary launch, Finder URLs,
  Services and reopen. Queue accepted external delivery until that workspace is
  attached, preserving the actual selected paths and captured request. Closing
  the workspace does not terminate an active owned child or disable future
  routing. Standalone TurtleGitMerge entry must not create a repository workspace.
- Apply report appearance only to Commit files, Working Tree files and Log
  changed files, using SwiftUI's own `.bordered(alternatesRowBackgrounds: false)`
  table style. Disable alternating empty backgrounds without altering other
  tables globally. Preserve checkboxes, selection, grouped rows, fonts, colors,
  menus, sorting and copy/drag behavior. SwiftUI remains the sole style owner;
  the adapter must not race it by changing or restoring `NSTableView.style`.
- Exclude retired document controllers from new unsaved-document Quit prompts,
  and recheck retirement before each asynchronous prompt dispatch. A closed
  Commit must not be shown again as a disabled, unanswerable window. Live dirty
  documents retain Save/Discard/Cancel behavior, and operation/release counters
  continue to protect draining workers.

The implementation touches `TurtleGitMacApp.swift`, `ApplicationDelegate.swift`
and the three report-table consumers. The attempted imperative styling changes
to `CommitFileInteraction.swift` have been removed; its existing selection and
interaction bridge retains its original ownership. These are native scene,
presentation and ownership changes; they do not change Git content or treat
forced termination as successful cancellation.

## Actual failure and bounded installed evidence

[Installed-family evidence](qa/installed-current-family-2026-10-24.json) records
the measured build/install, real Finder Commit/Log/Diff routes, Settings draft
handling and Status cancellation. It also preserves the failed Quit of PID
54430: Command-Q timed out, a retired Commit resurfaced with disabled controls,
and the exact owned app required SIGTERM. A fresh application later quit normally
during cleanup; that does not erase the original failure.

After the failed GUI Quit, the independent cache helper updated a private watched
file and folder from normal to modified and back to normal while the GUI was
absent. Actual Finder states and cache snapshots support that bounded refresh
observation. The watch was removed, background mode restored off, the fixture's
saved permission forgotten and owned windows closed while preserving the user's
Downloads window. The installed Finder extension remained alive. This is not a
pass for the complete graceful-Quit/background lifecycle.

## Checkpoint failure and repair in progress

The first Debug build (session 3790) exited zero while retaining five
contradictory exit-zero diagnostics. The grouped native attempt (session 39879)
then failed on its first Commit/system-Git case: receiver PID 63821 exited with
SIGSEGV 11 and was reaped. `build/qa/report-workspace-family-native-2026-10-25.log`
and the macOS diagnostic report
`receiver-bbad4c1881ea90de36b701222e6273fe527dda6699784df14702965-2026-10-25-002140.ips`
record the failure. This is an actual crash, not a passing native checkpoint.

The crash points to the new native `.fullWidth` table mutation racing SwiftUI's
`.inset` style ownership. The repair removes that adapter style ownership and
restoration entirely and selects the supported SwiftUI bordered, non-alternating
style at the three table declarations. This retains the intended presentation
without two frameworks competing over the same native table style.

The parallel signed build (session 75039) was deliberately interrupted after the
actual crash and exited 75. It was not a timeout, a completed candidate or a
successful signed validation. The earlier measured build-input receipt beginning
`105506…` is invalidated by the repair; current inputs must be measured again
once implementation freezes.

## Verification and remaining limits

The affected Debug repair build (session 2495) exited zero; four contradictory
exit-zero diagnostics remain in that log. The repaired native attempt (session 97771) exited one on a new fixture
assertion, not a production crash: it incorrectly required discarded native
highlight to survive the unchanged bridge's teardown. Source review confirmed
that teardown restores the framework delegate and clears that discarded
selection. The corrected check requires a retired adapter to refuse drag and
remove its artwork; all live row, color, selection, checkbox, sort, drag,
light/dark and replacement assertions remain.

The focused Commit recheck (session 78300) passed with both Git engines; the
remaining eight case/engine pairs (session 31826) also passed. All ten distinct
pairs pass cumulatively after the recorded repairs. Passing cases were not
repeated; cached app objects were reused and only the changed fixture was
recompiled. All ten receiver PIDs were reaped and independently confirmed absent.

The measured repaired signed build (session 99954) exited zero, retaining one
contradictory exit-zero diagnostic. The static candidate audit (session 15360)
passed: measured repair inputs remain unchanged, eight owned code items are
universal, 206 runtime code items and 6,356 inventory members are verified, and
all three app/Finder/cache identities use the expected team and App Group.
Signing, runtime placement and structural caches pass. Installation (session
21342) exited zero; the installed bundle matches the audited inventory and
executable SHA-256 `d3fe9dae34d25ebe037a30d5afd381ad1b5cdb3cbe13e95ddfe52660226929c9`.
The previous bead installation remains recoverable. The Finder executable itself
is unchanged; public registration operations selected one installed plug-in,
and the old extension retired naturally without a direct kill. The new input
receipt captures 1,471 files at
`beadb01b` with fingerprint `198a84fb…`, including protected existing WIP unchanged.

[Family evidence](qa/workspace-report-family-2026-10-25.json) preserves the first
crash and stopped signed build, superseded/current input receipts and actual
validation scope. Core was not rerun for these app-only changes. A complete
current hosted result is not available: the latest bead run is pending, while
an older build 56 was still in Git integration at parent observation. Neither
validates these uncommitted repairs. The earlier installed `beadb01b` evidence
above remains historical, including its real Quit failure; the repaired installed
observations below do not erase it.

### Actual repaired installed observations

Finder pair Commit showed only the two selected files, then Cancel Yes retired
it. Single-file Log retained `alpha.txt` scope, two revisions and the front graph,
with the unrelated beta file shown in source gray. Closing Log retained the
workspace identified as `workspace`. After closing that workspace, Finder pair
Diff reopened the identified scene with the intended alpha/beta contents;
closing Diff retained that same workspace ID. Grouped Working Tree showed the
three fixture files in the plain report.

The parent individually reviewed six real installed captures: readable source
colors and complete footers, without empty rounded stripes. Copies below retain
the exact captured bytes; they were not edited.

| Report | Dark | Light |
| --- | --- | --- |
| Commit | [Capture](site/assets/workspace-report-commit-dark-2026-10-25.png) | [Capture](site/assets/workspace-report-commit-light-2026-10-25.png) |
| Log | [Capture](site/assets/workspace-report-log-dark-2026-10-25.png) | [Capture](site/assets/workspace-report-log-light-2026-10-25.png) |
| Working Tree | [Capture](site/assets/workspace-report-status-dark-2026-10-25.png) | [Capture](site/assets/workspace-report-status-light-2026-10-25.png) |

Follow System appearance was restored. Command-Q then exited the repaired GUI
PID 67908 immediately, without SIGTERM, after those child workflows had retired.
The installed Finder extension PID 67907 remained independent.

These observations do not establish an absolute global window count: CUA's
application inventory timed out and was reset, and the Window menu did not list
the identified workspace. The evidence establishes the identified scene and its
observed reopen/retention only.

Status refresh can recur between close attempts; normal Command-W cancels it,
and rapid primary Cancel followed by Command-W closed the window. That remaining
refresh/cancel usability needs investigation and is not full Status acceptance.
Two stale accessibility actions while opening Status Appearance are retained;
keyboard Return closed it, then it was reopened under Light from the stable
workspace for the actual capture.

Final cleanup removed only the fixture's saved permission through Recent
remove/Forget, removed its repository/watch entries, restored Follow System and
quit the fresh cleanup app normally. The owned Harbor Finder window was closed;
the Finder accessibility window inventory confirmed the user's Downloads window
was preserved. No GUI, cache or receiver processes remained; Finder extension
PID 67907 was preserved. The private repository is retained intentionally.
Measured build inputs still match `198a84fb…` after the installed interaction.

HEAD, config and all six original working files are unchanged. Raw index bytes
**did change**: SHA-256 is now
`e0b7f9450006a85c5d07c1de36c980bc6d23e69460bcb169167a3650778db0b4`,
versus baseline
`1dc9d64e2412a0729dc1b64da3bef8c667f735d9e1f14616ddd5c85b36d8ea7e`.
Staged content matches unchanged HEAD (`git diff --cached --quiet` exits zero),
and all four index entries retain ordinary `H` flags without assume-unchanged
or skip-worktree flags. A metadata-only refresh is inferred, not proven; this
new installed checkpoint does not claim raw-index byte preservation. The earlier
historical bead observation remains its own separate evidence.

Remaining scope includes physical focus/reopen and external grant variants,
other upstream dialogs, minimum-version/Intel and a complete current hosted CI
result. Neither the source anchors nor these bounded fixes certify the full port.
