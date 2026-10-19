# Historical file materialization

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` and its
libgit2 gitlink `f7164261c9bc0a7e0ebf767c584e5192810a8b24` (1.9.4).
This records a partial workflow-family port, not complete app certification.

## Source behavior

`CGit::GetOneFile` (`src/Git/Git.cpp:2777–2881`) selects
`GIT_CMD_GETONEFILE`, command index9 / mask `0x200`. The source default `0x66780`
includes that bit. Its libgit2 branch peels signed/annotated tags, obtains the
selected tree entry and blob, rejects gitlinks, then calls `git_blob_filter`
with `GIT_BLOB_FILTER_CHECK_FOR_BINARY` cleared before writing output. It does
not check out the file or update the index. Its CLI fallback uses raw
`cat-file -p`; selecting another backend changes filter behavior in the source.
The Windows GitDLL path is not a macOS dependency.

`RepositoryBrowser.cpp:1244,1296` uses GetOneFile for Save As, Open, Open With and
Alternative Editor. `FileDiffDlg.cpp:766` uses it during selected-file export.
`Commands/CatCommand.cpp` applies the same command gate to its blob filter and
GetOneFile routes. Its disabled-backend blob route uses raw `cat-file -p`,
while its nonblob route uses `git show` with the selected path, including the
commit/patch presentation that command produces. Native standalone Cat now
retains this source distinction rather than unconditionally applying Git filters.
Browser recursive historical transfer also materializes files
through the source historical data-object workflow.

`src/libgit2/filter-filter.c`, copyright 2014, 2016–2021, 2023, 2026 TortoiseGit,
GPL-2.0-or-later, supplies the registered custom filter adaptation. Git.cpp:2493–2517
registers it at `GIT_FILTER_DRIVER_PRIORITY`. It uses `filter.<driver>.smudge`
in checkout direction, expands the source path in `%f`, and distinguishes required
filter failures from optional passthrough. The pinned built-in filter list
contains CRLF and ident; working-tree-encoding conversion and Git filter-process
protocol must not be inferred from that list.

## Native workflow scope

The implementation batch connects historical Open/Open With/Alternative Editor,
Save As and selected/recursive file export to explicit materialization APIs.
Raw comparison and Blame readers remain independently defined, so a display-only
read cannot silently acquire a smudge subprocess. Byte identities, literal Git
paths, pinned objects and link-target text retain their existing validation.
Symlink blobs do not cause the target file to be read.

An accepted operation captures private/production libgit2 settings before native
panels or asynchronous preparation. Output belongs to that accepted operation;
subsequent Settings or selection changes cannot choose another engine halfway
through it. A second private filter-drain lock complements the existing prompt
lock: cancellation publishes its marker first and waits for actual smudge
process-group settlement before interrupting the parent helper. Nested Git
authentication can retain the independent prompt lock without deadlocking
filter ownership. Owned filters, temporary files, output grants and worker counts remain
retained through actual cancellation/failure settlement. Existing destinations
are published only after successful preparation and the owner's final acceptance.

## Validation and remaining work

The [dated QA record](qa/historical-materialization-2026-10-19.json) records
actual implementation hashes, grouped checks and focused repairs. Source CLI Cat
nonblob semantics, bare attribute sources, custom filter command quoting,
required/optional failure handling, large binary streams and actual subprocess
cancellation belong to this implementation review.

Physical native menu/panel/keyboard/VoiceOver acceptance, signed filter executables
and sandbox scopes, minimum-OS execution, broad real-world filters/LFS/provider
combinations and full hosted CI remain separate acceptance requirements. This
batch does not certify all optional-engine consumers or complete TortoiseGit parity.

## October 19 grouped checkpoint

The universal build and both-architecture actual helper group pass first attempts,
reusing exact upstream C-library slices. Retained clone/fetch/list/delete checks
and new 1MiB binary/CRLF/literal-path/%f/%%/directblob/optional-required-missing
filter and source-invariant checks pass. 21 focused Core methods and Debug also
pass first attempts. Tag fixtures prove peeling, not signature validation.

The actual packaged-helper native group passes Browser/Log/Comparison/Cat outputs,
delayed provider capture, picker cancellation/duplicates/detachment, raw baselines,
required-filter errors and held-child cancellation/Quit. Initial URL equality
compared directory hints; its fixture repair retains exact paths and bytes. A
later fixture directly cleared SwiftUI error state then immediately started work
during NSAlert dismissal, causing an AppKit sheet-animation crash. The corrected
fixture acknowledges the actual error with native OK and waits both native sheet
relationships detached. No production suppression or assertion removal was used.
Only affected native fixture checks were repeated; Core/runtime/Debug passes remain.

PIDs 45712, 45969 and 46328 were reaped. The final receiver drains owned workers,
windows and sheets and uses a private temporary root. Packaged signed/unsigned
mapping and all source/pin hashes match the prepared runtime. This Debug app is
not a distribution-signed candidate. Clone and recursive checkout custom-filter
consumers remain a related open family; historical support does not provide them.


The later [Clone checkout-filter family](CLONE-CHECKOUT-FILTERS-PARITY.md)
connects the shared custom adapter to initial and recursive checkout. The dated
historical checkpoint above remains evidence for its recorded scope; the later
family supplies separate Clone/LFS and partial-destination evidence.
