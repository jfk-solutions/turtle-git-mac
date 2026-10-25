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

Remaining entry differences are explicit: the dedicated upstream executable
with no arguments attempts stdin (`TortoiseUDiff.cpp:107–129`), whereas native
`--unified-diff` without input deliberately opens an empty document. Native
stdin requires `--stdin` or `/p`. Upstream also accepts an unmarked filename in
its dedicated executable; the combined native app requires the explicit
`--unified-diff` marker for that entry. Upstream failed loading returns exit 1;
native input errors stay visible on their owner instead of automatically
exiting. This checkpoint does not claim complete upstream UDiff parity.

Full menu/keyboard/VoiceOver/visual source
acceptance, signed sandbox grants, all exceptional stream/filesystem conditions,
complete hosted CI and App Store delivery remain open. Existing repository patch
and standalone Merge workflows retain their separate acceptance scopes.
