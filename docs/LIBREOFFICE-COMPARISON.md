# LibreOffice document comparison and merge

The bundled LibreOffice adapter follows TortoiseGit's `diff-odt.js` and
`merge-odt.js`. It opens the captured new document and dispatches Show Tracked
Changes followed by Compare Documents against the captured base. LibreOffice
keeps the actual Writer/Calc document and formatting; TurtleGit does not export
plain text as a replacement for the source comparison.

New Diff Viewer and Merge Tool defaults include `.odt`, `.ods` and `.sxw`.
Previously saved choices, including an existing Word `.odt` association, remain
in effect. Advanced → Restore Defaults installs the LibreOffice associations,
retains unrelated records and existing row identities, and saves only after
accepting Advanced and applying Settings. Shift bypasses an enabled association.
LibreOffice is also available explicitly in the diff/merge program editors.
A Word comparison association automatically tries this adapter when Word is
unavailable, using fresh editable private copies of the same captured bytes.
Word permission denials, timeouts or uncertain handoffs do not start a second
comparison. Word merge remains Word-only; choose LibreOffice explicitly to use
its separate mine/theirs merge workflow.

## Requirements and handoff

Install LibreOffice separately, including its bundled Python framework. TurtleGit
locates the installed application and its nested Python application through macOS,
then starts a fresh runtime instance through Launch Services. It uses the fixed
bundled comparison worker and literal JSON arguments. No document path becomes
shell or Python source. The worker uses the installed UNO bridge, a UUID named
local pipe and an isolated LibreOffice profile. It never attaches to your running
LibreOffice desktop or reads its current frame. LibreOffice's bundled Python
layout and launch constraints differ between releases; an unavailable runtime
reports an error so another configured tool can be chosen.

Exact private editable document copies follow the source's writable-input
requirement; originals remain untouched. Opening explicitly requests UNO's
[NEVER_EXECUTE macro policy](https://api.libreoffice.org/docs/idl/ref/namespacecom_1_1sun_1_1star_1_1document_1_1MacroExecMode.html)
and [NO_UPDATE document policy](https://api.libreoffice.org/docs/idl/ref/namespacecom_1_1sun_1_1star_1_1document_1_1UpdateDocMode.html).
The dispatch targets the frame belonging to the newly loaded document. These
properties and dispatch semantics still need acceptance with actual installed
LibreOffice versions, including comparison-time loading of the reference file.

Cancellation before dispatch suppresses the handoff. During preparation, it
signals the worker and waits for its runtime to settle; a blocked worker receives
termination after 180 seconds and forced termination after another five seconds.
Only that newly created runtime application is targeted. An already opened
LibreOffice result can remain for review; cancellation does not undo its work.
The native owner retains Quit accounting until the runtime exits. Closing an
owner refuses late errors and resolution prompts.

Confirmed unopened failures remove private inputs and stop the private office
process when the worker can confirm it. Accepted or uncertain operations retain
copies and the isolated profile for the external result. Saved Data → Temp files
or system temporary cleanup can remove them later. LibreOffice is not installed,
reconfigured or removed by TurtleGit.

## Tracked-change merge

As in `merge-odt.js`, the adapter compares **mine against theirs**; the base stage
is not consumed. The existing Git conflict loader determines stage orientation,
including rebases, and revalidates the conflict immediately before handoff.
A native instruction sheet identifies the real working result path. Accept/reject
changes in LibreOffice and use **Save As** to that path. The private mine copy is
not the working result, and an ordinary Save of it does not resolve the conflict.

With Block while merging enabled, TurtleGit asks **Mark Resolved / No** after
preparation. Save As must finish before choosing Mark Resolved. No leaves the index
unchanged. Closing or cancelling refuses late answers. The existing conflict
validator checks current stages again when staging the saved working result.
Without blocking, review and resolve later through the ordinary conflict tools.
LibreOffice exposes no trusted merge exit code; Trust the exit code must be off.

## Verification and remaining acceptance

Core checks execute the shipping worker with injected UNO/process interfaces,
covering literal URLs, the owned frame, explicit properties, connection/cancel/
load/dispatch failures and completion receipts. Native fixtures exercise shipping
routing, settings Apply/Cancel, exact snapshots, Shift, unavailable cleanup,
Save As instructions, explicit resolution and retired-worker ownership in private
Git repositories. These checks launch no user office software.

LibreOffice is not installed in the current development environment. Live Writer/
Calc rendering, nested-runtime launch compatibility, actual document formats,
macro/reference loading, Save As, minimum OS and signed sandbox/App Store access
remain unverified. The app's preparation profile and Launch Services code do not
prove App Store acceptance. PowerPoint has native slide comparison and Open XML revision decisions with
editable-copy output; binary PPT editing and complete revision parity remain
open. Its inspected Mac scripting
dictionary lacks the Windows presentation Merge API.
