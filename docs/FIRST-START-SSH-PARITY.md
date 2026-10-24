# First Start SSH setup continuation — October 24, 2026

The pinned `FirstStartWizardAuthentication.cpp:94–100,192–205` displays the
configured SSH client and saves a changed selection before writing the HTTP
credential helper. Opening the wizard must not replace an existing custom client
with a fixed OpenSSH caption or write authentication preferences.

The native Authentication page now loads `SSHClientPreferences` from its owning
preference store. Automatic OpenSSH and Custom OpenSSH select the existing native
SSH policy; Custom displays the actual configured path. Switching to Automatic
and back retains the unsaved custom path and bookmark. Path edits clear an old
bookmark. This is the same executable, security-scope, environment-override and
OpenSSH validation policy used by Network settings; the implementation does not
introduce another transport or alter Git/repository SSH command overrides.

Browse is an owned file sheet. Only a regular executable may acquire a security
bookmark. The reply captures the owner, page visit, choice and draft; duplicate,
closed, changed and retired replies cannot replace the current draft. Navigation
and normal Close stay blocked until the real sheet detaches. Forced retirement
cancels presentation and keeps operation accounting until sheet drain.

Check now runs the selected client's real `-V` inspection through the existing
cancellable process policy. A pending check blocks Back/Finish and field changes,
while Cancel check and normal window Close can cancel the read. Cancellation keeps
Quit accounting until the worker actually returns; cancelled or retired versions
and errors do not publish. Automatic checks report the existing automatic policy,
without claiming that a particular repository's override has been executed.

Finish validates a changed client, saves the submitted SSH preference, then writes
the selected HTTP helper. A helper failure leaves the accepted earlier SSH save
intact, keeps completion false and allows retry, matching source save order.
Don't store on HTTP affects only the helper, not SSH. Existing unchanged custom
preferences are preserved without requiring their executable to be available just
to finish unrelated setup. Invalid changed clients and empty Custom choices block
Finish. Earlier Language/Git/User page saves retain their existing behavior.

App Store builds show bundled Automatic OpenSSH, disable custom selection,
Browse/Check, and leave ignored external custom preferences untouched. The wizard
does not offer Windows PuTTY/Plink. The pinned Authentication page has no Network
settings handoff; the native Network page remains independently available in
Settings rather than adding a new source-unrelated wizard operation.

## Grouped verification

`FirstStartSSHPolicyTests` exercises real private executable validation, exact
preference persistence, Automatic clearing, repository-command precedence,
App Store suppression, invalid clients and cancellation. The native receiver
`qa/first-start-ssh-native-2026-10-24.swift` and cached
`scripts/test-first-start-ssh.py` cover three cases with system and bundled Git:

- actual configured Custom controls and real check; invalid Finish; source-ordered
  SSH save before failed helper; retry/Don't store and once-only completion;
- actual owned picker with duplicate/stale replies, bookmark check and Finish;
- held read cancellation and forced-close drain, plus late closed picker refusal.

All repositories/configuration, preferences, scripts and windows are private.
Receivers prohibit activation and keep windows/sheets invisible. The grouped checkpoint passed both Core policy methods and all six native
case/engine pairs. Light/dark Authentication captures were inspected at the
700×560 content minimum; labels and footer controls fit. A callback capture
compile error was repaired with explicit self references before native checks.
All six receiver PIDs were independently confirmed absent. See the
[batch evidence](qa/reference-ssh-overlay-family-2026-10-24.json).
Physical input, all helper/platform variants, signed
security-scope renewal and App Store execution remain unverified. No complete
First Start, authentication or application parity claim is made.
