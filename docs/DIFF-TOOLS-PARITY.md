# Diff tools and associations — implementation in progress

Reference: pinned SettingsProgsDiff, SetProgsAdvDlg, ToolAssocDlg and
AppUtils::PickDiffTool/StartExtDiff at
`7338078f8ddd924b8cddee35f512f2286072136d`.

The native Diff Viewer page groups the two-file diff program and existing GNU
patch viewer controls, with Merge Editor as its child. Unified Diff's separate
page now holds appearance settings; the viewer draft has one owner. The two-file
program has internal/external selection, a saved application, arguments, Browse
and Advanced. Advanced has Extension/Program columns, Add/Edit/Remove, nested
association editing and separate OK/Cancel drafts. Parent Apply persists the
associations; dismissing Advanced leaves the parent draft unchanged. Extension
keys trim leading asterisks and compare without case, accepting filenames too.
Duplicate normalized keys and invalid enabled programs prevent Apply.

Selection follows destination filename → base filename → destination extension.
An explicit disabled association selects the internal tool. Default image
extensions retain the image viewer before the general text program. Shift
inverts enabled/disabled external programs; a disabled saved application remains
available. The October 16 image routing continuation below implements the source switch
between IDiff and Merge, including disabled explicit image associations.

A macOS .app or command-line executable plus an argument template replaces the
Windows executable command. The October 15 continuation below adds executable
launch and trusted merge exit status.
The source placeholders `%base`, `%mine`, `%bname`, `%yname`, `%bpath`, `%ypath`,
`%brev`, `%yrev`, `%wtroot` are supported. Absent both file placeholders, the two
file arguments are appended. Quote/escape parsing happens before single-pass
substitution, keeping paths with spaces or placeholder-looking text intact. No
shell interprets the template. NSWorkspace launches a new app-bundle instance with
arguments, because an existing app instance may ignore launch arguments. Executable
tools use a directly spawned process with the same expanded argument array.

The shared comparison window routes its first read through the selected program,
covering callers that use FileComparisonWindowController (including revision,
working-file and change-set comparisons). Successful external opening closes the
internal window after its load becomes idle. Closing fences late routing and
callbacks. Other specialized comparison helpers still require the source audit;
this is not a claim that every application compare command uses this route.

Regular working-tree files use their original URLs and retained folder grants,
so supported external tools may edit them. Historical, empty and symlink contents
are copied byte-for-byte into private read-only files. Copies persist until app
termination; failed launches delete their copies. Selected app bookmarks are
resolved without UI and retained through launch. AppStore builds require the
selected application and working-file security scopes. Active launch requests
block app termination; termination removes retained comparison copies. Browse
panels for both diff programs and unified viewers belong to their hosting window
and are canceled when their form disappears.

The implementation checkpoint was uncompiled and untested. The later grouped
validation below supersedes compilation and the focused argument/selection/
persistence checks only. Native association/table/sheet/keyboard acceptance,
actual receiving-app arguments, regular working-file edits, source image and
helper boundaries, failures/close races, retained copies, signed AppStore grants,
and light/dark screenshots remain in the grouped section validation. Older
Unified Diff QA covers its earlier viewer implementation, not these additions.
The external merge continuation below adds source Merge tool configuration;
existing Merge Editor controls cover built-in editor preferences.
Inventory counts remain unchanged; no dialog is newly certified.

## External merge continuation

Merge Tool is now a child of Diff Viewer and has internal/external program,
arguments, Browse, Advanced associations, Block while merging and a displayed
Trust exit-code control. Matching follows the source's `.` + filename key before
extension keys. Argument fallback adds base/theirs/mine/merged only when none of
those placeholders is present. Shared Apply/Cancel handles its draft.

The main conflict-editor dispatch now checks the external selection before
opening the image/text editor. Delete/modify and submodule conflicts retain their
specialized workflows. Exact stage bytes are copied into read-only inputs;
Mine/Theirs swap for rebase as in the source. The merged output is the working
file. Conflict stages are validated before and after input reads. No source blob
is decoded and rewritten just to launch an external tool. App bookmarks and
repository grants remain alive through launch/wait.

Nonblocking mode returns after launch and leaves resolution to the user.
Blocking mode observes the launched app's termination, then asks an owned visible
caller window whether to mark the file resolved. Resolve revalidates the original
conflict stages. If that window has closed or has another sheet, no resolution is
performed. Temporary inputs stay until application termination; active waits and
launches block quitting. Successful external dispatch refreshes repository panes.

NSWorkspace app launches do not expose a process exit status. Trust exit-code
selection is unavailable for .app programs; an existing enabled value may be
cleared in Settings and produces an explicit launch error until cleared. The October 15 continuation implements this
source mode for command-line tools. App-bundle exit status remains unavailable. Other direct conflict
helper launch paths, wait cancellation, tool process failures, stale app bookmark
renewal, exact source filename-key usability and signed sandbox receiving-app
behavior remain open.

A grouped Debug build has been started for the accumulated Dialogs/Colors/Tools
section. Its result and focused behavior tests will be recorded separately;
this document does not claim a passing build or native acceptance yet.


## Grouped validation result

The accumulated Debug Xcode build and Swift package build pass after fixing
continuation type inference and the current SDK's typed CoreFoundation locale
identifier bridge. Four tool tests pass with zero failures (0.773 seconds).
They verify selection/Shift/image precedence, literal argument parsing and
single-pass substitution, fallback file arguments, persistence/duplicate keys,
merge filename precedence, and real-Git exact stage bytes without index or
working-file mutation. See `docs/qa/settings-dialogs-tools-batch-2026-10-11.json`.
No application instances were launched. This evidence does not validate actual
receiving-app behavior, native sheets/layout, blocking mode or signed sandbox
permissions. Those checks and source exit-code trust remain open.


## Native association and parent Settings batch — 2026-10-12

Compared SetProgsAdvDlg's sorted columns, Add/Edit, double-click handler and
selection after Remove with the native controls. Advanced now uses an AppKit
NSTableView with single selection and the same next-row/previous-last-row removal
rule. Program cells include arguments and a full tooltip. Double-click routes
the clicked row to Edit; empty-area clicks do nothing. Editing keeps a separate
draft; Cancel preserves the list. Accepted extensions normalize and retain their
identity/selection when sorting moves the row. Duplicate/invalid entries cannot
replace another association. Merge Add uses the four merge file placeholders.
Parent Diff/Merge pages use a shared observable draft model with private-domain
injection, validation, Apply and Cancel; failed persistence retains the draft.

Debug Xcode build exited 0. One object-linked native receiver compilation/process
passed and was reaped. The receiver checked sorted native columns, row selection,
double-action wiring and argument display; model Add/Edit/Cancel/duplicate
refusal, next/previous Remove selection and merge Add defaults; both parent pages
registered with SettingsTransaction and persisted to a private UserDefaults
domain on Apply; validation failure and Cancel restored the saved draft; injected
persistence failure retained pending edits. Aqua/Dark Aqua hosts were constructed.
No receiving application launched, no signed grant was exercised, and no new
screenshot or physical double-click/sheet acceptance is claimed. Core selection/
argument/stage APIs were unchanged; their recorded four-test checkpoint was not
rerun. The full twelve-family receiver group was not rerun.

The Windows Restore Defaults button calls SetupDiffScripts for installed COM
document tools. Its macOS script/tool equivalents are not implemented, so this
control remains open; clearing all associations would not reproduce it. Actual
tool argument delivery/working-file edits, wait cancellation and exit status,
bookmark renewal, image Shift parity, owned native sheets and App Store sandbox
acceptance also remain open. Advanced, association editor and Merge Tool inventory
resources are now partial-native-replacement; no dialog is certified complete.


## External Merge session lifecycle — 2026-10-12

The blocking launch now creates an owned session before reading conflict inputs.
Caller closure retires the session; a late input read cannot launch another tool.
After an authorized launch, closure releases TurtleGit's wait without terminating
the external app. Successful-launch input copies remain retained by the existing
preview registry. Task cancellation likewise releases the wait and owned prompt.
The session owns the termination observer, close notification and confirmation
reply, disposes observations once and fences late replies. A closed caller cannot
be reused to accept an old Mark Resolved response. No is the default key action;
accepted resolution still validates the captured conflict stages through Core.
This supersedes the earlier unowned-wait cancellation gap only.

Debug build exited 0. The new object-linked native lifecycle receiver passed with
system and bundled Git, one compilation and two reaped processes. Mock completion
checks covered synchronous termination, caller-close and task cancellation, once-
only cleanup, late termination and late prompt responses. Private real Git
conflicts verified No preserves index bytes, Mark Resolved stages exact working
bytes and an already-resolved captured entry is rejected without index changes.
Owned windows were closed. Tool apps were neither launched nor killed; actual
NSWorkspace argument delivery, real tool KVO termination, physical owned sheets,
receiving-app edits, signed grants and exit-code trust remain open. Native-only
changes did not rerun Core or the complete thirteen-case group.

## Conflict-editor routing and cancellation — 14 October 2026

The workspace editor dispatcher now owns a captured repository, literal path,
initiating window, stage record and cancellation token before its first read.
Delete/Modify, Submodule, image and text routes share a native preparation panel
with Cancel. Repeated same-repository/path requests reuse the current preparation.
The panel closes before an editor/tool receives control. Window close or explicit
Cancel stops owned Git reads, and late results cannot open another editor, report
an obsolete error or retarget to the newly focused window. The permission and
shared Quit count remain held through actual settlement, including noncooperative
injected readers. Commit, Resolve, Log and Rebase handoffs now pass their actual
initiating owner where available.

Image read/selection/resolution and external merge inputs now carry cancellation
through stage validation and owned Git commands. Image/text reads revalidate
stages and rebase orientation before returning documents. External side files
are private/read-only; the real result remains the captured working path. The
prepared stages and result ownership are validated again before launch, and the
external input record must match the factory's captured entry.

External-tool preparation now counts as active before input reads. Private side
files are written off the UI thread, checking cancellation between copies; Task
cancellation also cancels the shared preparation token. A cooperative
token also retires its wait and owned resolution question; Task cancellation is
not required. Late Yes and duplicate observation callbacks cannot stage a result.
The same token reaches actual Mark Resolved commands. The receiving app is never
terminated by TurtleGit cancellation. If NSWorkspace returns a successful launch
after the owner has closed, the private inputs are retained for that app and no
native fallback or automatic resolution starts. Normal successful cleanup does
not cancel its caller's token. Retained copies still use explicit app-termination
cleanup; complete receiving-app/signed lifetime acceptance remains open.

[Grouped routing/cancellation evidence](qa/conflict-editor-routing-2026-10-14.json)
separates real Git reads/staging and private input files from injected native
presentation/SDK launch/wait replies. This is partial editor and tool parity:
all actual receiving apps, every binary/mixed/symlink/encoding case, physical
progress/prompt/Shift gestures, complete specialized editor behavior and signed
Finder/App Store grants still require acceptance.

## Executable tool family and trusted merge status — October 15, 2026

Diff and Merge defaults and Advanced associations now accept executable files as
well as `.app` bundles. Browse can select either kind; the other application-only
choosers keep their existing filtering. Existing saved program/argument/bookmark
records need no migration. An unbookmarked executable must be a regular executable
file (including a symlink to one). Bookmarked paths are validated after acquiring
the grant, so sandboxed Settings does not reject a selected executable merely
because its scope is not active during form validation.

Arguments retain source placeholder precedence, quote/escape parsing and literal
single-pass substitution. No shell expands the command template. A selected script
runs through its own shebang. The child starts in the repository root with null
standard input. Its launch completion and real process exit status are separate;
spawn failures are reported and the child is reaped. A command-line tool that
launches a GUI should use that tool's wait option for blocking merge behavior.

`SettingsProgsMerge::OnBnClickedMergeblock` clears Trust when blocking is disabled;
the native control now does the same. Trust becomes available for executable
programs/associations. App bundles retain their owned success question and cannot
supply a trusted exit code. At dispatch, the selected association's kind governs.
As pinned `AppUtils::StartExtMerge` does, blocking trusted exit zero resolves the
captured conflict with current working bytes; nonzero leaves it unresolved.
Blocking untrusted tools show the existing **Mark Resolved / No** question, with
No as default. Resolve still checks the captured conflict stages.

Nonblocking tools survive caller closure and retain executable/repository grants
until their child exits. The application retains private source files until its
normal termination. Live executable tools participate in the existing quit guard,
so normal termination cannot remove those files while a tool is using them.
Blocking caller retirement/cancellation stops and reaps that owned executable's
process group, including helper children. App-bundle instances retain the previous
observation-only behavior and are never killed by this process path.

[Grouped executable-tool evidence](qa/executable-tools-2026-10-15.json) records
focused Core and native settings/lifecycle checks. It does not certify third-party
tool argument conventions, daemonizing wrappers, physical Browse/VoiceOver, signed
sandbox execution or full source visual parity.


Unified Diff Viewer and Alternative Editor now share app/executable launch and
permission lifetime with the managed Diff/Merge process pool. UDiff adds the
source `%1`/`%title` argument field and implicit patch argument; Alternative Editor
keeps its source single-filename behavior. Their empty-template app choice
retains native URL opening. See [source scope](UNIFIED-DIFF-VIEWER-PARITY.md#external-viewer-arguments-and-executable-tools--october-15-2026)
and [dated native/Core evidence](qa/external-documents-2026-10-15.json). Signed
execution and complete external-program acceptance remain open.

## Bundled ZIP script and default associations — October 16, 2026

`contrib/diff-scripts/diff-zip.js` lists top-level Shell namespace names, dates,
sizes and item count, then opens a read-only TortoiseMerge comparison. The native
[ZIP adapter](ZIP-COMPARISON.md) now provides that workflow without WScript/COM.
ZIP64/Unicode central-directory reads do not extract payloads. A read-only native
comparison owns the generated inventory independently of the initiating window;
raw archive bytes remain unchanged. Cancellation fences prepared-window handoff.

Diff programs/associations now encode an optional built-in tool kind. Old JSON
without that key retains external/internal behavior. New unsaved defaults install
`.zip`; saved association lists remain authoritative. Advanced Restore Defaults
replaces bundled `.zip` only, retains row identity and other associations, and
uses the existing nested/parent drafts. Internal/External/ZIP program choice and
table labels reflect the selected kind. Shift, disabled associations and filename
precedence use the shared selection path. Merge rejects diff-only built-in kinds.
The remaining Windows document scripts are still open; this does not supersede
those gaps with a claim of full Restore Defaults equivalence.

Fourteen focused Core cases and one real-archive native workflow pass. The native
fixture uses shipping controller/view/model objects with hidden presentation.
A scoped build repair and the fixture's deferred-load Shift correction are recorded
in [dated evidence](qa/zip-inventory-2026-10-16.json). Both native receivers were
reaped and independently absent. No full Core suite, Store build, new screenshot
or physical/signed acceptance is claimed.

## Binary and Mathematica bundled workflow family — October 16, 2026

The [bundled comparison family](BUNDLED-COMPARISONS.md) now also adapts
`diff-dll.js` and `diff-nb.js`. Binary reports compare byte sizes and exact chunks,
read PE32/PE32+ fixed versions without loading code, and add native Mach-O dylib/
universal version metadata. Source Identical/Differs text and information/warning
roles appear in a selectable, scrollable native result with OK/Escape.

Notebook preparation captures exact read-only input files and an ASCII driver
with source Compare Notebooks/AuthorTools/NotebookDiff controls. Literal Wolfram
path escaping avoids command/string injection. Launch follows the associated
notebook receiver. Failure/cancellation cleans private files; successful handoff
retains them through normal app exit, matching the source driver's deferred
button lifetime. Active preparation/SDK callbacks keep the Quit guard after
owner closure. These paths spawn no shell or binary under inspection.

New defaults and Advanced Restore Defaults install ZIP, DLL/EXE/dylib and NB
associations; saved configurations stay authoritative and other associations are
preserved. Tool radio choices/table labels use the shared built-in catalogue.
Windows Office/OpenDocument comparison/merge adapters remain open. Native binary
captures and actual notebook receiver execution have separate evidence scopes.

Nineteen focused Core checks and both native family receivers passed on the first
behavioral run. The incomplete offscreen images were rejected; only the affected
receiver was rerun with real owned-window compositor capture. The resulting Aqua/
Dark Aqua images were inspected and published. All three receivers were reaped
and independently absent. [Dated evidence](qa/bundled-comparisons-2026-10-16.json)
separates actual framework-byte/version/native-window checks from intercepted
notebook launch callbacks. No real notebook application was launched, and no
Store/signed or complete source acceptance is claimed.

## Modern Word comparison family — October 16, 2026

The modern `diff-doc.js` branch now has a native [Word adapter](WORD-COMPARISON.md)
for document/template/ODT associations. It retains formatting and tracked changes:
open the base, compare against the new file into a new Word result, use Comparison
as author, mark the result saved, and close only its private opened input.
Literal Apple-event arguments replace COM/WScript/string interpolation. Exact
private read-only snapshots protect repository and unrelated Word documents.

An operation holds scope/Quit ownership through preparation and the serialized
AppleScript worker. Closure cancels before dispatch and fences late publication;
Word is never killed. Confirmed unopened/denied failures clean their copies;
success or uncertain opening retains inputs beyond normal app cleanup. New
associations and Restore Defaults share existing Settings/Shift behavior. Word
merge remains unavailable through the diff-only kind. AppStore's narrowly targeted
Word exception and usage description are source configuration, not signed/App
Review acceptance. Grouped evidence records actual validation scope separately.

Twenty-three focused Core cases, one Debug build/package audit and all three
native comparison cases passed on the first attempt. The fixed handler compiled
against the installed Word dictionary without executing a comparison or launching
Word. All receivers were reaped and independently absent. The
[dated evidence](qa/word-comparison-2026-10-16.json) records the dictionary hash,
actual checks, build diagnostics and intercepted executor boundary. Real Word
results, live TCC/file permissions and signed sandbox/App Review remain open.

## Word three-way merge and shared macro policy — October 16, 2026

The [Word merge family](WORD-MERGE.md) now adapts the modern `merge-doc.js`
three-way sequence with source selected-target comparisons and explicit manual
Save As of the original conflicting file. Stage bytes use editable, separate
private copies, including existing rebase orientation/stale checks. An owned
instruction sheet precedes dispatch; a configured blocking merge offers the
existing Mark Resolved/No question, with No default and no trusted Word status.
Closure/token cancellation retires questions and late publication while the
actual worker keeps its Quit/lease lifetime. Success/uncertain opening retains
private inputs; a confirmed denied/unopened failure removes them.

Merge defaults and Advanced Restore Defaults cover DOC/DOCX/DOCM only, retaining
saved/custom records and row identities. Word's shared kind now adapts behavior
to Diff versus Merge; other built-in kinds remain invalid for Merge. Active
associations can enable Block while merging even when the general program is
internal. Both Word scripts now suppress automatic macros and attempt restoration
of the prior security value through their serialized worker. Actual Word security
and rendered merge output are separate acceptance work, not inferred from the
script text or compilation.

Twenty-seven focused Core checks, one Debug build/package audit and five native
case/engine pairs passed on the first attempt. Both fixed Word handlers compiled
against the installed dictionary without executing Word. Real private Git
conflicts checked No, retired questions/workers, actual reviewed-result staging,
unchanged HEAD and both engines. [Dated evidence](qa/word-merge-2026-10-16.json)
records the intercepted-executor boundary and open live Word/macro/Save As/signed
acceptance. All five receivers were reaped and independently absent.

## Excel full/fast comparison family — October 16, 2026

The [Excel workbook family](EXCEL-COMPARISON.md) adapts `diff-xls.js` with exact
private workbook copies, full/fast program kinds, ordinal sheet pairing, gray
copied reference sheets, green unhidden tabs, red conditional-value comparisons,
locale conversion through an owned scratch book, protected-sheet warnings and
security restoration attempts. References quote sheet/workbook names; source
paths/mode are Apple-event arguments rather than script text. Native stacking is
limited to comparison windows; Windows synchronized scrolling remains open.

Worker/Quit ownership survives caller closure. Confirmed unopened/denied failure
removes copies; successful/uncertain receipts keep accepted inputs through normal
app cleanup. Protection/layout warnings have an independent native read-only
window, capped to ten messages plus a remaining count, and are suppressed for
retired/cancelled owners. Five source workbook extensions use full mode by default;
fast mode is explicit. Saved settings/other associations stay authoritative.
Excel is added to the narrowly targeted AppStore exception allowlist and usage
description; signed/runtime/review acceptance is not inferred from that declaration.

## Connected image/tool dispatch — October 16, 2026

`DiffToolSelection` now represents Merge, IDiff and an enabled configured program
separately. Source destination-name → base-name → destination-extension precedence
runs before the default image extension check and generic program. The fourteen
source image extensions select IDiff before the generic program; Shift selects
Merge. An explicit enabled image association selects its program, with Shift
selecting Merge; a disabled association selects Merge, with Shift activating the
saved program. Content decoding cannot reverse that selected Merge route.

The native owner captures the complete selection before asynchronous dispatch;
the shipping launcher consumes that same snapshot. Successful internal selection
persists across reloads and later Settings changes. Failed dispatch leaves the
selection retryable and never silently opens another viewer. Retired operations
keep their existing worker/scope/Quit lifetime and reject late viewer publication.

IDiff decodes each side independently: invalid/unsupported or empty images remain
in IDiff with existing missing/decode messages and image commands. The original
bytes remain intact. PNG content with an unregistered destination extension uses
Merge unless an explicit association selected another program. Native Load Images
is an explicit IDiff operation and bypasses external associations, including its
replacement inputs. Explicit Merge Open, editor replacement and captured Merge
source comparisons retain Merge and also bypass external associations.

This separates the two-file StartExtDiff behavior from StartExtMerge's image
conflict policy. The conflict route and external-merge settings are unchanged;
complete conflict/source masks, all image codecs and signed/physical acceptance
remain open. PowerPoint's inspected Mac scripting dictionary does not expose the
presentation Merge command used by `diff-ppt.js`; that adapter is still open.

Ten focused Core cases, the Debug build and all five native cases with both Git
engines pass. The initial Load Images fixture staging-name failure was repaired
without repeating passing checks. All eleven owned receiver processes (ten passes
and one failed fixture) were reaped and independently absent. See
[the dated record](qa/image-tool-routing-2026-10-16.json) for diagnostics, cached
compilation, native behavior scope and remaining physical/signed acceptance.

## Conflict handoff preferences — October 16, 2026

Conflict editor preparation captures Merge Tool preferences from its initiating
workspace before its first suspension. The actual merge launcher consumes that
snapshot along with the existing Shift/path/owner/stage identity. This fixes the
old default closure's use of global preferences. External merge bypass falls
back to the source extension-based image or text conflict workflow, with raw-side
and empty-Base selection handled by [image conflict selection](IMAGE-CONFLICT-PARITY.md).

## Source tool forms and Browse ownership — October 17, 2026

Diff, Merge, GNU patch viewer and extension association inputs now retain visible
External Program and Arguments labels when populated. Program fields use the
shared native literal filesystem completion adapter; changing a typed path drops
its old bookmark. The Windows command line remains split into program/arguments,
and built-in document adapters remain explicit macOS choices.

Browse starts in the folder of an existing configured path and otherwise Applications.
NSOpenPanel does not preselect the configured filename through its Save-panel name
field. Internal/External choices use the source horizontal row; a compact native
Program kind menu holds the additional document adapters. A
single owned chooser disables its form, blocks Settings close/navigation and
application Quit, validates a selected app directory or executable file before
creating its bookmark, and accepts it only for the unchanged captured draft and
owner. Duplicate replies, Cancel, dismantling and owner closure cannot install a
late bookmark or error. No receiving tool is launched by Browse.

Advanced now groups the Extension/Program table and Add/Edit/Remove/Restore
Defaults separately from the OK/Cancel footer, matching the resource structure.
The source extension instructions remain beside Advanced on both parent pages.
Add/Edit/Cancel and Remove request focus back to the native table, after a nested
sheet has ended, retaining the existing sorted selection behavior. An unsupported
Diff-only adapter is rejected before it can enter a Merge association draft,
rather than leaving an invalid parent waiting for Apply. Nested editor completions
capture a fresh presentation identity, so an old Cancel cannot dismiss a newer
editor even when reopening the same association.

All 36 static resource controls across these four dialogs now have partial native
mappings. Source filesystem completion is adapted to retained macOS scopes, so an
App Store file grant does not authorize sibling enumeration. Native locale
sorting, split command fields and built-in adapter choices are adaptations rather
than pixel-identical Windows controls. Physical keyboard/double-click, real
receiving applications, signed bookmarks and complete source acceptance remain
open. All three distinct native families pass after the recorded fixture/runner repairs, including actual Settings navigation; the two affected tool families pass again after the presentation-identity repair. Four raw light/dark captures were individually reviewed: the source group/footer and populated Extension/Program/Arguments captions fit without clipping. All eleven owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/tool-source-family-2026-10-17.json) for the build diagnostics, fixture failures and physical/signed limits.
