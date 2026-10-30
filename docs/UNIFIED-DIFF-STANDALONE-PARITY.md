# Standalone Unified Diff input and document ownership

This family connects native standalone Unified Diff launch, stdin/file input,
editable document menus and owned cancellation without requiring a Git
repository. Seventeen distinct Core methods cumulatively pass after a literal
Unicode path repair; all four native cases and an actual standalone Debug
pipe/scene acceptance also pass after the fixture actor-isolation repair. Final
review then found a startup-specific Quit routing bug; its focused repair now
passes the fifth native case.
[QA record](qa/unified-diff-standalone-2026-10-25.json).

## Pinned source

Upstream `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseUDiff/TortoiseUDiff.cpp:85–135`, chooses the explicit `/title`, patch
file name or pipe title, creates the window, then loads stdin for `/p` or loads
the requested file. `MainWindow.cpp:804–835` reads a handle to EOF and applies a
250 MiB document ceiling; the regular-file path at 839ff checks the same size
boundary. `SetTitle` at 962ff appends the UDiff product name. Source handle
loading is synchronous; macOS uses an owned background reader so its native
window can remain responsive and cancellable while a producer is open.

## Native workflow

The typed `UnifiedDiffInvocation` recognizes the explicit native tool marker,
stdin/file/title choices and source `/p`, `/patchfile:`, `/title:` spellings.
Repository `/command` invocations retain their own parser. Launch selection
chooses the standalone App scene before the repository workspace exists;
`RepositoryModel.handleUnifiedDiffCommandLine` creates a document-only
controller without a Git repository. File and stdin titles retain exact user
text in the comparison caption, with the native Unified Diff/TurtleGit window
suffix. Plain document viewing does not initialize Git or fail because a
custom Git preference is invalid; Apply acquires that runtime lazily and reports
its failure on the document owner.

`UnifiedDiffInputSession` prepares an empty editable document before reading.
The caller owns window presentation. It captures a CLOEXEC descriptor duplicate
synchronously, preventing caller close/reuse from redirecting a queued read;
the detached Core reader owns its own duplicate, polls with cancellation and
retains raw bytes through EOF. Neither caller stdin nor its shared status flags
are closed or modified. Empty EOF is valid. Input is bounded below 250 MiB;
file reading admits regular files (including symlinks to regular files), rejects
special streams without blocking, and retains the same bound.

Only the current live session/controller/window may publish. Raw bytes enter
the existing document session for encoding, editing, Find and Save semantics.
Read/limit errors appear on the owner without publishing partial input. The
native loading Cancel stops the read and leaves the empty document open. Close
cancels and waits for actual worker completion before retrying that exact
window's normal close delegate. Forced owner retirement cannot reopen or
publish late; the active registry retains the worker until it exits. Quit
cancels the entire active group, drains it, then continues the existing global
dirty-document decision pipeline from a single termination request.

File command-line paths are requests, not sandbox grants. Missing file scope
uses the owned Open panel, admits only the exact requested path bytes, and
reacquires the explicitly selected file's lease. Cancel performs no read; a
different file is rejected. This preserves the normal document Open path while
making standalone command launch usable in the sandbox. Signed grant acceptance
is separate from the injected native boundary checks below.

The focused document menu context resolves the actual owner at invocation:
Open, Save, Save As, Close (including pending input), Apply and existing editor
commands retain the document gates. Source File-menu Dark Mode
(`TortoiseUDiff.rc:90`) updates the owner's text and Find presentation as
window-local state, without writing preferences.
Other repository windows do not acquire the standalone document's commands.

## Authored checkpoint and gaps

Core tests exercise real stdin/file bytes, limits, cancellation, descriptor
ownership and invocation grammar. The [native fixture](qa/unified-diff-input-native-2026-10-25.swift)
and `scripts/test-unified-diff-input.py` author four repository-free cases:

- stream: real pipe raw UTF-8/CRLF, empty EOF, immutable title/editability, and
  accepted descriptor identity after caller close/reuse;
- lifetime: busy close waits, a forced closed owner remains in the active Quit
  registry, independent input succeeds, and the actual application delegate
  completes a single Quit only after the held worker drains;
- failure: invalid descriptors, bounded input and loading Cancel preserve the
  correct owner and leave caller descriptors usable;
- command: actual native launch/router, plain file Open despite invalid Git,
  lazy Apply failure, focused dark/light commands, and cancelled/wrong/exact
  file-scope selection with the real reader.

Checks use private preferences/directories and offscreen owned windows, including
error sheets. Held reads deliberately return late bytes to test the native
receipt independently of cooperative Core cancellation. The runner reuses
receiver compilation caches; it needs no Git engine matrix because these are
standalone document operations.

A fifth focused `startup` case now boots through the real application delegate,
with a private minimal workspace and injected offscreen presentation/services/
exit handler. It checks clean Quit, dirty-document discard and a held input
worker's single-Quit drain on that actual startup path.

Core run 23712 executed 17 methods: 16 passed and one failed four Unicode path
assertions. The parser now uses existing exact lexical/byte URL helpers instead
of Foundation normalization; focused run 87910 passed the affected method.
Initial Debug 84204 exited zero with 33 contradictory exit-zero diagnostics;
affected Debug 39120 exited zero with one such diagnostic. Native run 59803
failed fixture compilation before any receiver started: nested Context did not
inherit the outer enum's MainActor. Explicit Context actor isolation fixes all
reported owner/session/cleanup call errors; no behavioral assertion changed.
Native rerun 63564 exited zero with all four cases passing; receivers 85278,
85289, 85290 and 85293 were reaped. The original compile failure remains part of
the checkpoint rather than a successful native attempt.

Physical session 16706 launched the actual Debug app executable through
`App.main` with `--unified-diff --stdin --title 'Piped changes 🐢'` and a real
pipe. EOF produced an editable diff in the single captured-title viewer without
a repository workspace or first-start wizard. The composed PNG/accessibility
evidence at `build/qa/unified-diff-standalone-physical-2026-10-25` was reviewed for
source colors and controls. Command-W closed the viewer and the complete process
85302 exited zero and was reaped. Private HOME/CFFIXED_USER_HOME/TMPDIR were
supplied, but no private preference files were observed; persisted preference
isolation is therefore not proven by this physical run. Independent process
inspection found no GUI/cache/receiver remaining, preserving installed Finder
77954. No new signed installation was created.

Subsequent static final review found that Unified Diff startup had reused the
Merge-active flag. Clean or approved dirty Quit could consequently ask an empty
Merge launch collection to finish and never reply. The Unified Diff route now
avoids that flag, retaining its existing close/exit callback and ordinary
document Quit pipeline. The prior four native passes remain historical; the
physical Command-W check did not exercise Command-Q in actual startup mode.
Affected Debug 68902 exited zero with one contradictory exit-zero diagnostic.
Only the new startup case ran (70023 exit zero, receiver 85661 reaped), covering
actual-bootstrap clean Quit, dirty discard and held-input drain. These are five
distinct native cases cumulatively; neither Core nor the four previously
passing native cases were repeated for the flag-only correction. The physical
Command-W evidence predates it; physical Command-Q is not claimed.

Localization check passed 38 locales/1,318 labels. Reconciliation passed 130
resource dialogs/120 partial/10 pending/85 unmapped controls/zero certified;
those audit counts do not measure feature completion. The site built 452
documents with zero unresolved links before this final record update; final
regeneration belongs to the parent checkpoint.

The October 25 checkpoint had three explicit entry differences: no-input
`--unified-diff` opened empty instead of attempting stdin, an unmarked filename
needed the combined app's explicit marker, and input failure stayed visible
without a distinct failure result. The dedicated tool continuation below addresses
those entry paths without changing the combined application's empty-document
command. This historical checkpoint does not establish the later implementation
or complete upstream UDiff parity.

Full menu/keyboard/VoiceOver/visual source
acceptance, signed sandbox grants, all exceptional stream/filesystem conditions,
complete hosted CI and App Store delivery remain open. Existing repository patch
and standalone Merge workflows retain their separate acceptance scopes.

## Subsequent installed signed check

The [aggregate signed checkpoint](qa/viewer-families-installed-2026-10-25.json)
records actual installed stdin/title, native Save with matching raw bytes,
window-local Dark Mode and Command-Q. It found a duplicate custom Close beside
the standard macOS command. The custom item and unused context guard were
removed, then signed/static/recoverable installation repeated only for that
repair. The installed menu's accessibility text shows exactly one `Schließen`
with `performClose:`; `Alle schließen` is the separate standard Close All.
Clicking Close exited and reaped the viewer. The screenshot request returned no
image, so no repaired-menu PNG is claimed. A post-close CUA accessibility request
reopened a workspace; it was separately quit and shell inspection confirmed no
main app. Known two geometry preference keys were restored absent without
resetting other preferences. This selected signed acceptance does not certify
the complete source menu/visual or every signed file grant.

## Native line-number gutter continuation

The [gutter family](UNIFIED-DIFF-GUTTER-PARITY.md) connects the source line-number
margin to the existing standalone document and shared read-only previews. Numbering,
whole-line selection and dragging use the actual displayed UTF-16 text without
changing byte-backed editing, file/stream loading, Save, Apply or Quit ownership.
The family checkpoint records its own actual validation and remaining limits.

## Dedicated tool entry continuation — October 27, 2026

The `scripts/turtlegit-udiff` launcher invokes the combined executable with the
separate `--unified-diff-tool` marker. Its default input is stdin, including a
valid empty EOF; a positional filename selects a file. The original
`--unified-diff` entry retains its empty-document default. Literal Unicode paths,
option-looking filenames after `--`, explicit input/title options and the source
aliases share the typed parser. The dedicated marker owns malformed tool
requests so they cannot fall through into a repository workspace.

The launcher uses `exec`, preserving the caller's exact argument boundaries,
stdin and exit result. It follows the existing Merge wrapper's explicit app or
executable override and reports a missing executable as `127`. No filename is
reassembled into shell text. The default pipe title comes from upstream
`IDS_PIPETITLE` (`diff from pipe`); an explicit caption remains user text.

Dedicated initial loading captures a result owned by that document: success
returns `0`, failed/cancelled input returns `1`, and malformed arguments return
`2`. Input errors remain visible until the owner closes. Later editor/Apply
errors cannot overwrite the initial loading result. File permission choices,
held stdin cancellation, Close, Quit and accepted external handoffs retain their
existing owner and drain requirements. The combined empty-document entry keeps
its previous behavior.

The [dedicated tool checkpoint](qa/unified-diff-tool-2026-10-27.json) records this
continuation separately: 22 focused Core methods, the private executable wrapper
check, the unsigned Debug build and all six distinct native input cases passed.
The first grouped run exposed Quit/retirement defects; affected cases were
rechecked after repairing synchronous cancellation, retired-window admission
and delayed error alerts. A fixture then acknowledged the actual native error
sheet before retrying Quit, preserving its failure status assertion. Logs retain
all failures and repairs. Every owned receiver was reaped and independently
confirmed absent. These focused checks do not establish signed grants, physical
Terminal acceptance, full hosted CI or complete source visual parity.
The image-effect implementation in the same worktree remains a separate
unfinished batch and is not certified by a Unified Diff checkpoint.

## Local document admission and Git readiness — October 31, 2026

The pinned `TortoiseUDiff.cpp` creates its editor and reads the selected local
file or stdin directly; opening a document does not read repository configuration.
The native `--unified-diff` and `--unified-diff-tool` startup paths now likewise
admit their input owner without starting the unrelated Git configuration-grant
restoration. Their file scopes, raw-byte readers, loading cancellation, dirty
drafts, initial outcome and ordinary Close/Quit ownership are unchanged. Git
configuration and repository access remain lazy requirements of Apply.

Launch Services `.patch`/`.diff` file URLs use one shared typed classifier in the
handoff, router and actual opener. Supported local documents bypass Git readiness
and do not initialize a new saved-repository archive or Finder watch manager.
Existing workspace authority can still be shared. Nonlocal URLs, other file
extensions and NUL paths receive no such bypass. A preceding Git request keeps
its FIFO position: later local documents wait behind it until its configuration
restoration returns. Repository Services keep their original gate, and standalone
tool hosts retain the separate-host handoff for external URLs.

The input receiver now checks immediate empty/file editor startup without a
configuration callback, actual local URL reads and repeated dirty-owner reuse,
held Git-first FIFO and Services admission, lazy saved-authority initialization,
late-read close fencing and unchanged disk bytes. The
[grouped checkpoint](qa/local-document-startup-2026-10-31.json) records four
native cases passing cumulatively and two successful Debug builds. Its initial
admission failure exposed Foundation's encoded-NUL path normalization; the
shared classifier now refuses encoded NUL before using the filesystem path,
while preserving literal percent filenames. Only that affected case repeated.
All five current-batch receivers were reaped. Physical Launch Services, signed
external file grants and complete hosted integration remain separate acceptance;
this working-tree repair is newer than signed build42.
