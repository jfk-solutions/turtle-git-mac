# Historical file menus and dialog handoffs

This connected family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It connects Browser's folder and
contents menus, Log's changed-file report, and Blame toolbar customization.
Implemented controls do not certify the complete dialogs or port.

## Browser entry and historical navigation

The [Browser continuation](BROWSER-HISTORY-CONTEXT-PARITY.md) supplies keyboard
and accessibility entry to the existing native menus. Source Open remains the
default action. Literal names, selected items, menu availability and ownership
remain separate from localized captions and focus.

`RepositoryBrowser.cpp:818–828` passes both `/endrev` and `/rev` for ordinary
history and recorded submodule history. Root now passes both the history limit
revision and selected revision, together with the accepted repository context,
original preferences and lease. File and folder history keep their paths after
selected-revision configuration; the shared reference-log setup previously
cleared them by configuring whole-project history afterward.

A new Root-owned Log is configured before its first reload. It no longer starts
a default HEAD query and then cancels/replaces that plan while setting its scope.
An existing Log with an owned read, chooser, note, modal state or reset is not
reconfigured behind its current operation. Its independent replacement gets its
own identity and close callback.

## Log changed files

`LogDlg.cpp:308` explicitly permits Path, Extension, Status and added/removed
statistics. This is narrower than Resolve/Sync's optional-column mask. The native
Log report retains those five definitions, persisted layout and stable headers,
while parent-specific file IDs and nonselectable parent headings remain intact.
Native divider double-click fits contents and Shift restores the default width
while clearing the saved adjustment.

The pointer, selected-row keyboard and accessibility menus share captured model
receipts, command availability, icons and working/historical/raw-path policies.
The full comparison, revision-file delivery, conflict, index/LFS, ignore and
history commands remain present. Extensions and visible-order Copy All join
pointed-column copy. Display formatting does not change action identities.
Double-click uses the activated row, as `GitStatusListCtrl::OnNMDblclk` does;
deliberate multi-file actions remain selection-based.

The existing file-drag probe remains responsible for native gesture admission
and accepted transfer lifetime. Replacing the report does not revoke bytes
already promised to a receiving application. Reset questions retain ownership
through actual child/parent detachment, including forced closure.

## Blame toolbars

The toolbar continuation follows `MainFrm.cpp`'s docking/customization and pane
menu setup. Toolbar handles, bars and buttons offer native keyboard/accessibility
menus with the icon preference, current bar/pane choices and authenticated hosts.
Built-in MFC framework menu artwork has no one-to-one project-resource mapping;
native window-management items use the existing application icon roles.

Toolbar management keeps a dedicated editor/Quit lease. Done, Escape, native
close requests and forced document retirement wait for actual paired sheet
detachment before reporting completion. A sheet close-delegate check does not
prove a physical titlebar click; attached sheets may offer no close button. Existing docking, floating bars, command dragging
and the native customization palette retain their separate behavior.

## Checkpoint and remaining scope

The [connected checkpoint](qa/history-file-context-family-2026-11-22.json)
records successful Debug builds and 22 distinct native case/Git passes
cumulatively. Passing Browser cases precede the isolated Log divider repair;
retained selection/identity/drag, Browser delivery, Blame customization/placement
and the focused new Log/Blame cases accompany them. Compiler failures, the Help
regeneration interruption and fixture repairs remain in the record. All 43 logged
native compiler/receiver PIDs are absent. No Core suite was repeated for these
native consumer changes.

The checkpoint uses actual native table input and menu actions with owned-window
key-state injection in the invisible receiver. Blame Done uses its real default
Return action when SwiftUI omits public AX button proxies; native sheet closure
is checked at the delegate boundary. These do not prove physical focus or
close-button clicks. No shipping screenshots or signed acceptance are claimed.

A separate source review found a real remaining primary-action gap: Return on
multiple conflicts or mixed conflict/ordinary files enters comparisons instead
of opening each conflict editor. Log conflict handoffs also omit the Log's
preferences and accepted backend. These require a related activation and child
ownership batch; the current native-report passes do not certify those paths.

Physical pointer/keyboard/VoiceOver use, translated distribution appearance,
external receiving applications, all optional Git/LFS/gitlink combinations,
signed Finder grants, Intel/minimum-macOS execution and full hosted acceptance
remain separate. Installed52 and the frozen signed54 package are unchanged;
this newer source is excluded from54.
