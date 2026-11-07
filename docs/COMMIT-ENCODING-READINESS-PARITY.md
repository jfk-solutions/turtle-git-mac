# Commit draft, encoding and native readiness

This continuation reviews `IDD_COMMITDLG` and retains the pinned TortoiseGit Commit workflow and source
`7338078f8ddd924b8cddee35f512f2286072136d`. `CommitDlg.cpp` focuses the new-branch
input when enabled (around line 3033). The macOS equivalent must wait for its
native owner to be presented, while respecting later user focus, disabled state,
sheets, replacement and closure. A newly attached branch field now retains that
insertion's focus intent through presentation; it never acquires an editor while
the owner is hidden. Revoked or disabled insertion cannot steal focus later.
The author and branch native checks use transparent offscreen windows because
ordinary hidden windows deliberately lack automatic focus authority.

Commit's conflict preflight now uses the existing read-only status policy. It
still obtains current conflict facts; it does not refresh the actual on-disk
index merely to decide whether an attempted commit may proceed. Unsupported
encoding must leave HEAD, branch refs, actual index bytes and working files
unchanged. The selected-file operation now encodes its message before status
refresh, clean filters, index preparation or branch creation, retains that file
for the complete synchronous operation, and passes the same file to library,
checkbox-policy, ordinary and parent-based amendment consumers. Direct internal
library/separate-index entry points likewise create their message before index
preparation. Staging-index commits already create the message before branching.
Every owner removes its own private message file on success or failure.

This preserves the source codepage aliases, lossy replacement policy, message
newline handling and native Rebase edit transport. Unsupported macOS codepages
remain explicit errors; this change does not silently fall back to a different
encoding. Successful clean filters cannot redirect the accepted message through
a later configuration reread.

The captured-selection consumer now tests a newly modified descendant to prove
that an already open dialog retains its initial automatic-selection preference.
It also accounts for staged rows remaining visible across subpath scopes. The
report-row consumer waits until the actual native checkbox displays the accepted
checked state before dispatching its action; model publication alone does not
prove SwiftUI has delivered the native cell update. Highlight and inclusion
membership remain independently asserted.

## Validation boundary

The initial grouped native checkpoint passes selection preferences and report
geometry with both Git engines. It identifies a constrained offscreen test-window
assertion and a real unsupported-encoding mutation failure; both are retained in
the batch record. The subsequent focused Core checkpoint passes 11 methods, including refusal before
mutation across ordinary/checkbox/amend/message-only backend choices and a valid
encoded-commit control. The affected native author/focus and encoding/Rebase
continuation pass with both Git engines; together with the unchanged passing
selection and geometry cohorts, ten native case/engine combinations pass
cumulatively. The actual scope and initial failures are in
[the checkpoint](qa/commit-encoding-readiness-2026-11-07.json). These changes do not establish a complete hosted pass, physical typing
or frame-by-frame stability, all Commit controls, minimum-macOS acceptance or a
new installed distribution build.
