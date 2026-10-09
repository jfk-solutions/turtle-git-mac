# Revision Export

TurtleGit for Mac now provides **Export this version…** in the single-revision
Log menu, with TortoiseGit's original Export icon. It is available in bare
repositories too; stash entries do not offer it. A selected tag is preferred
as the initial revision, otherwise the selected commit hash is used.

The native Export window follows upstream `IDD_EXPORT`: **Export Zip File**
with a destination field and file picker, **Revision** with HEAD, Branch, Tag
and Commit choices, reference browsing and a Log commit picker, then **Whole
Project**, OK, Cancel and Help. HEAD includes the current branch name. The
Whole Project control is checked and disabled for a repository-root export.
A Log scoped to one existing directory can instead export that directory.
The repository sidebar also offers Export, and Finder offers it for one
repository folder or a bare repository. Finder preserves the selected directory
in its captured URL request; choosing the repository root opens Whole Project.
The shell position follows upstream, after Create Tag.
A file-scoped Log exports the whole repository, matching upstream's directory
check. Native branch/tag popup controls share the other revision dialogs.

OK exports a ZIP using `git archive`. It reads the chosen revision, rather
than dirty working files or staged contents. Git handles `export-ignore`,
`export-subst`, executable modes and symlinks. Directory exports run from the
selected directory so Git removes the directory prefix and keeps the commit
metadata used for substitution. Submodule contents follow Git archive behavior;
this command does not recursively archive checked-out submodule repositories.

An existing file requires Replace confirmation. The archive is produced in a
unique temporary file and only replaces the destination after Git succeeds.
Failures and cancellation preserve an existing archive; temporary files are
removed. Export owns a separate native progress sheet with live verbose output,
source completion colors and **Close** / **Abort** controls. Abort cancels the
owned Git process; Close is disabled until completion. Success offers **Show in
Finder** with the original Explorer icon and split menu. Captured auto-close
preferences govern acknowledgement without automatically invoking Finder.
Failed acknowledgement restores the options for another reviewed export.
Forced closure cancels and reaps the operation before releasing the owner; a
late overwrite answer cannot start an archive after the options owner closes.
See [Export parity](EXPORT-PARITY.md) for progress and cancellation evidence.

The destination picker retains its security-scoped lease for the operation.
The AppStore configuration requires a grant for the exact chosen output file
and a retained repository grant. A typed alternate path requires a new picker
grant. Signed sandbox execution, including creation of the adjacent temporary
archive under a save-panel grant, remains **unverified**. No App Store readiness
is claimed by the unsigned build.

## Evidence and limits

The upstream comparison uses pinned TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`, `ExportDlg.cpp`, `IDD_EXPORT` in
`TortoiseProcENG.rc`, `CAppUtils::Export` in `AppUtils.cpp`, and the normal Git
`ID_EXPORT` handler in `GitLogListAction.cpp`. The older SVN handler is not the
basis of this implementation.

`RevisionArchiveTests` verifies exact committed binary bytes despite working
changes, archive attributes, commit substitution, executable mode, symlinks,
whole-project versus directory scope, annotated tags, bare export, rejected
revision/scope/metadata destinations, pre-cancelled operations, unchanged HEAD
and index, preserved output on failure and temporary-file cleanup.

The headless native receiver checks the actual Log menu icon and selector,
selected-tag handoff, tag/hash model presets, archive generation and both
Cancel and Replace responses through the real model. It does not display the
window or click the native save/confirmation panels. A follow-up hidden
controller check hosts the real Export dialog and verifies HEAD/Branch presets,
root/subdirectory scope normalization, the busy-close guard and window cleanup. Screenshot/layout,
keyboard/accessibility, signed sandbox, activated Finder dispatch and broader
Export entry-point parity remain pending. Full Log and application parity remain
incomplete.

Finder uses the same pinned `MenuInfo.cpp` Export clauses (single folder in Git,
or bare repository). The native menu-builder receiver verifies source order,
original icons, enabled state, captured folder request and URL round-trip,
file/multiple-file exclusion, and the bare menu. This uses cached repository
metadata without activating the Finder extension. Application Quit refuses an
active Export operation or attached sheet so a pending archive is not abandoned.
