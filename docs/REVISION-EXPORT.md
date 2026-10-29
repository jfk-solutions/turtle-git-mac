# Revision Export

## Save a historical Browser folder as an archive

In Repository Browser, use **Save as archive…** for a selected folder or the
displayed directory. Choose an outer filename, such as `sources.zip`, `sources.tar`
or `sources.tar.gz`. The filename selects Git's archive format. The archive
contains the displayed historical revision and keeps full Git-relative paths,
including the selected folder's prefix.

This works for folders deleted from the current working tree, bare repositories
and historical names that macOS cannot create as individual files. Their original
name bytes remain inside the archive. Extraction still depends on the receiving
tool and filesystem. This is an explicit archive command; ordinary folder export,
checkout and drag delivery retain their own filename requirements.

Git applies archive attributes, including `export-ignore` and commit-based
`export-subst`. The command reads committed content, preserves executable/symlink
metadata and follows Git's submodule archive behavior. It does not include dirty
working files or recursively fetch submodule repositories. An accepted request
keeps its captured revision and folder even if another branch moves.

Cancel leaves an existing output unchanged. If the destination changes while an
archive is being prepared, publication fails for review. The Browser retains its
owned chooser, process and grants until the operation has finished. See the
[historical folder archive record](BROWSER-ARCHIVE-PARITY.md) for its source
mapping and explicit limits.

## Export a revision from Log or Finder

TurtleGit for Mac now provides **Export this version…** in the single-revision
Log menu, with TortoiseGit's original Export icon. It is available in bare
repositories too; stash entries do not offer it. A selected tag is preferred
as the initial revision, otherwise the selected commit hash is used.

The native Export window follows upstream `IDD_EXPORT`: an archive destination
field and file picker, **Revision** with HEAD, Branch, Tag
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

The save chooser offers ZIP, TAR, TAR GZIP and All Files, matching the source
archive filter. Choose a filename appropriate to the archive you want. Explicit
suffixes are preserved, including configured Git archive formats; All Files does
not restrict you to a three-format whitelist. ZIP remains the ordinary default
for a filename without a supplied extension.

OK asks Git to export the format selected by that filename. ZIP, `.tar` and
`.tar.gz` produce their respective formats. Other suffixes follow the installed
Git configuration; an unrecognized suffix uses Git's default TAR format. Renaming
a resulting archive afterward does not convert its contents. A configured archive
writer can fail if its required command is unavailable; read the result before
continuing.

Export reads the chosen revision, rather
than dirty working files or staged contents. Git handles `export-ignore`,
`export-subst`, executable modes and symlinks. Directory exports run from the
selected directory so Git removes the directory prefix and keeps the commit
metadata used for substitution. Submodule contents follow Git archive behavior;
this command does not recursively archive checked-out submodule repositories.

An existing file requires Replace confirmation. The archive is produced in a
private replacement workspace on the destination volume, retaining the chosen
basename so Git can infer its format. It only replaces the destination after Git
succeeds.
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
Save and overwrite responses belong to the captured form and are consumed once.
Changing the form, Quit or closing its owner rejects a late response. Closing
retains actual metadata, picker, question and archive work until it has drained.
The AppStore configuration requires a grant for the exact chosen output file
and a retained repository grant. A typed alternate path requires a new picker
grant. Signed sandbox execution, including creation of the replacement workspace and
atomic replacement under a save-panel grant on deployment volumes, remains
**unverified**. No App Store readiness
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

## Selected historical files

Saving or exporting selected historical files from Log, Compare or Repository
Browser is a different workflow from revision archive Export. It pins the selected objects
and uses the GetOneFile backend captured when the action starts. The source
default applies libgit2 checkout filters and configured smudge commands; disabling
that backend reads raw blob bytes. Failed required filters preserve an existing
output. Browser drag and file promises keep their captured choice through later
receiver delivery. See [historical-file materialization](LIBGIT2-TRANSPORT.md#opening-and-exporting-historical-files)
for filter settings and remaining engine limits. Archive behavior above is unchanged.
