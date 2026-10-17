# Log external document opening

Source reference: `GitLogListAction.cpp` Open/Open With and the Log changed-file
commands at TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The Windows workflow retrieves a selected historical file into a read-only
revision-named temporary copy before handing it to Shell Open/Open With.
TurtleGit adapts that handoff to native application selection and Launch Services.
Working Tree Open uses the selected working file, including its symlink path;
it does not substitute a historical blob.

The connected Log workflow now captures the file-selection epoch before any
panel, preview write or application handoff. The source Open, Open With and
alternative-editor actions retain their original menus and icons. Reading a
historical blob and resolving a working file have owned cancellation and Quit
counters. Read completion hands ownership directly to the deferred native open
session. Forced closure cancels undispatched work, while actual reads and launch
callbacks retain independent lifetimes and repository/application permissions.

Open With uses the existing owned native application panel. Cancel or retirement
cannot launch a later selection. Alternative Editor captures its settings at the
start of the open session and uses an awaitable adapter, preserving default
TextEdit/custom application/executable behavior and native document arguments.
Default Open resolves the receiving application and uses the same asynchronous
handoff adapter. Missing applications and current errors remain visible; a stale
or retired callback cannot overwrite a newer selection's error state.

Historical previews are prepared off the main actor with original bytes and
read-only permissions. Undispatched copies are discarded. Once launch has been
attempted, the receiving app may already have consumed the input even if Launch
Services later reports failure; those previews remain until the shared temporary
preview cleanup. Cancellation is not rollback of an accepted external launch,
and TurtleGit does not terminate a user-owned receiving application.

The [grouped checkpoint](qa/log-document-open-family-2026-10-17.json) passed
twelve focused Core cases and four distinct native workflow/engine cases. Final
Close review found the generic busy guard blocked owner retirement during preview
preparation/launch; that exception was added and only the two affected handoff
cases were repeated. Both Debug builds passed, and all six receivers were reaped
and independently absent. Unaffected Core/file-action checks were not repeated.
Native Close during the initial Git file read retains its existing busy behavior;
selection changes and retirement cancel that owned read.

Physical application picker and receiving-app
interoperability, VoiceOver, signed security-scoped access, deferred/uncertain
Launch Services delivery, external CLI settlement and full Log parity remain
separate acceptance work.
