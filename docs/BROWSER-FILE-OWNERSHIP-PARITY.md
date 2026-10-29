# Repository Browser file delivery ownership

This connected native family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RepositoryBrowser.cpp::OnOK`,
`OnNMDblclk_RepoList`, `ShowContextMenu`, `OpenFile` and `FileSaveAs`.
The source opens a selected historical file or completes its chooser before the
same dialog can navigate elsewhere. The Mac implementation keeps these actions
asynchronous while retaining their original file and dialog ownership.

Open, Open With, alternative editor and Save revision to now share one captured
read workflow. Historical stored-file delivery and bounded stored-blob inspection
use the same ownership rule. Directory navigation and submodule routing retain
their distinct operations; raw Git names retain their safe temporary namespace.
No working-tree mutation or Git staging is added by these file actions.

The accepted read captures its Browser owner, request, navigation and refresh
generations, requested revision, immutable tree/object and directory, exact entry,
action, materialization engine and alternative-editor settings. A normal file
read now reserves the dialog immediately, rather than leaving navigation and
another Open available until its eventual panel appears. Refresh, revision and
folder commands cannot replace that reservation. Cancel or closing the owner
requests cancellation and retains accounting/access until the actual read drains.
A revision changed by another owner, a retired Browser or an interrupted request
cannot deliver its late content or error to the current dialog.

Successful delivery transfers synchronously to the existing Save/Open With panel
or preview/launch operation before read accounting releases. The presentation
continues to validate the original captured context instead of recapturing the
Browser's later directory. The same cancellation token covers the read and its
subsequent delivery. Quit ownership, native sheet release, duplicate replies,
forced closure and noncooperative writer/launch drain remain guarded. A new Quit
interruption cancels pending delivery even if that interruption is later refused.
Pending Save and Open With panels receive their own once-only Cancel response
when delivery is canceled, including during a Quit decision; token cancellation
does not leave a dead sheet waiting for another user click. Panel ownership lasts
through actual detachment. An already-started writer or application launch stays
owned until its real callback drains. An external application that has already
accepted a preview retains its existing ownership; closing this Browser does not
terminate an unrelated receiving app.

The optional native `readFile` seam, alongside the existing stored-file and blob
readers, permits holding actual immutable content through native selection/menu
and panel dispatch. The [focused batch receipt](qa/file-comparison-browser-ownership-2026-10-29.json)
records the passing grouped system/bundled-Git checks and retained failures;
implementation alone is not a pass. Existing file-action, historical materialization and transfer records
retain their separately dated results.

Remaining acceptance includes physical file menus and pointer/keyboard delivery,
real receiving applications, signed sandbox grants, minimum-version/Intel SDKs,
large histories and complete Browser layout/source parity. This family does not
certify the complete Repository Browser or the whole port.
