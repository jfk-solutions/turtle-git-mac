# Review/apply single patch — native implementation

Pinned source: `TortoiseShell/MenuInfo.cpp` and `ContextMenu.cpp`'s ApplyPatch
handoff, `TortoiseMerge/TortoiseMerge.cpp`'s `/diff`, `/patchpath` and `/wc`
handling, and the existing patch-review/editor audit in
[IMPORT-PATCH-PARITY.md](IMPORT-PATCH-PARITY.md), at
`7338078f8ddd924b8cddee35f512f2286072136d`.

Review/apply single patch is distinct from Apply Patch Serial (`git am`). Finder
now exposes its original patch icon, source preference ID/mask, position before
Send Mail, single-patch condition and Extended single-file condition. Placement,
Shift visibility, path exclusions and icon preferences use the same shared menu
settings as the other commands. Multiple patches do not expose this single-patch
command. The File menu also opens it without requiring an active repository.

A patch inside a known working copy defaults to its containing folder, matching
the source `/wc` behavior. An outside patch asks for its target folder; a command
without a patch opens a file chooser. The Extended non-patch-file route opens
the patch chooser instead of interpreting arbitrary file bytes as a diff. Native
owned panels retain real grants and fence late replies after closure. Finder
requests do not grant sandbox permission and do not change the app's active
repository.

Targets may be ordinary directories or Git folders, including nested folders.
The existing native TurtleGitMerge review shows the file list, Before/Patched
comparison, original patch, reverse/strip controls, checked-file application,
editing, draft-save/discard/cancel and completion states. Opening the workflow
does not apply anything. Original patch bytes remain unchanged. Send Mail's
outside-repository Review command now uses this same folder-capable workflow;
its Apply Patch Serial command continues to require a working Git repository.

Directory mode anchors patch paths to the chosen folder using disposable Git
administration outside the target. It preserves relevant apply/whitespace
configuration while preventing a nested working-directory prefix from dropping
or misplacing patch records. It never initializes `.git` inside a plain target
or borrows the real index. Git supports applying patches to files without a
repository or commit; see the [official git-apply documentation](https://git-scm.com/docs/git-apply).

The review records its directory mode and whether a Git working tree was
authorized. Subset checks, comparison preparation, stale-input validation,
application and edited-save preparation retain those facts. Plain targets use
an isolated SHA-1 workspace for before/after simulation and edited-result
generation; optional auto-add is disabled for them. In a Git subfolder, an
edited new-file save can still use the actual Git index for the existing optional
Add behavior. Whole/subset application itself does not stage or commit.

The chosen folder and source-file grants remain retained through review. During
sandboxed preflight, discovery is fenced at the largest retained folder grant;
an ungranted ancestor is not probed to infer a repository. A nested-only grant
can still support plain-directory review. A static preflight-load count fences
Quit through forced closure, and existing review/editor guards handle dirty
drafts, loads and saves. All disposable administration and patch files are
removed after each complete operation.

Still open: complete physical layout comparison, automatic source patch-path
guessing, source clipboard-patch integration, complete TortoiseGitMerge format
and conflict behavior, large-patch performance, and signed Finder/bookmark/
sandbox acceptance. This implements the missing command and directory-target
workflow; it does not certify complete TortoiseGitMerge or application parity.

Grouped validation, 2026-10-12: Debug arm64 build exited 0, with existing
compiler warning/exit-zero diagnostic noise. Forty-six focused Core tests passed,
zero failures, in 16.547 seconds, including plain-folder binary/rename/subset
application, edited saves, nested-folder path anchoring and real-index optional
Add, stale-input rejection, unsafe-path checks and the existing review suite.
The actual Finder menu builder passed all 57 implemented root entries against
the source order fixture; the condition oracle now contains 60 commands including
the three nested LFS commands. One combined native compilation/process exercised
the actual RepositoryModel Finder URL handoff, plain-folder before/after review,
checked subset, edited save, dirty-close guard, source-file preservation and a
late target reply after forced closure, alongside the existing daemon/LFS/mail
fixtures. No installed app or Finder extension was activated. See
[the dated record](qa/review-patch-batch-2026-10-12.json).


The [clipboard/target-matching batch](PATCH-CLIPBOARD-TARGET-PARITY.md) adds
explicit clipboard review, exact-byte Copy Patch and source-ordered target
suggestions with confirmation. Its audit supersedes the earlier path-guessing
and basic clipboard gaps for those implemented routes; broader source Open/
Finder clipboard, format and physical/signed acceptance remain incomplete.

The [native file-panel continuation](PATCH-FILE-PANEL-PARITY.md) uses highlighted
rows for explicit preview and selected/all application. It supersedes the earlier
checkbox description for the Review UI; the checked backend API remains separate.

The [recorded-base recovery continuation](PATCH-RECOVERY-PARITY.md) adds initial
Ready/Conflict/Error classification, versioned-base retry, an embedded native
three-pane preview and clean-merge Patch all/selected continuation. Earlier text
listing all initial-state and conflict preview behavior as absent is historical;
the continuation records the implemented paths and remaining special-file scope.
