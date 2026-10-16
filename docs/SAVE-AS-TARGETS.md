# Save As targets in Compare, Review and Merge

The pinned TortoiseMerge source distinguishes source panes from the merged
result: `CMainFrame::OnFileSaveAs` sends Left/Right to `CBaseView::SaveFileTo`,
which changes the pane's working filename and saved baseline. Bottom uses the
separate merged-result save path. Source pin:
`7338078f8ddd924b8cddee35f512f2286072136d`.

Compare's left/right Save As writes the current draft with its chosen encoding,
then binds that pane to the selected file. It becomes clean; later Save and
Reload use that path. Each pane can be bound independently. Reload does not
require obsolete original source paths. External changes are rejected before a
subsequent Save; explicit Reload establishes a fresh baseline. Ordinary bound
Save retains the shared backup and empty-file choices. The initial Save As uses
an atomic write and does not create the ordinary Save backup.

In Review Patch, a rebound result's later Save and Quit Save write its selected
file without applying or staging the proposal's original repository path.
Selecting a different proposal still uses the existing dirty-draft decision.
The internal copy-export helper remains a separate copy operation.

Three-pane source Save As retains the current merged draft while changing the
source used by Reload and Compare with Base. A changed source is detected before
merged Save. Repository merged-result Save As remains a copy; standalone merged
output retains its existing guarded output-target workflow. The Save As menu
also offers Continue resolving conflicts when conflict markers remain.

Save choices capture bytes and encoding before presentation. Operations own their
permissions and block conflicting mutations, Close and Quit. After the user
approves saving during Quit, Compare/Merge use a dedicated owner-approved save
route; the normal Quit mutation fence remains in effect. Cancel and failures
retain state; retirement prevents late sheet responses from writing. Private
read-only source snapshots can only become editable through Save As to a file
outside their private directory.

This is partial parity. Exact cross-platform source serialization, aliasing and
all overwrite variants, physical sheets/keyboard/VoiceOver, signed sandbox grants
and complete application equivalence remain unverified. Automated checks use
private files and injected panel decisions, not physical panel acceptance.

The [dated batch record](qa/save-as-targets-2026-10-15.json) separates accepted
checks, failures and repairs. The affected 55 Core cases passed cumulatively;
the final Debug build and both target-binding/native Import Patch Git-engine
runs passed. Ninety focused rebase/Fetch checks passed with the corrected CI
headless-editor path. A hosted green run remains unverified.

Read-only normal saves now redirect to Save As and establish a target in both
Compare and the merged-result editor. A repository conflict saved elsewhere keeps
its original index conflict; later normal saves, backups and Reload use the new
file. See [save ownership](MERGE-SAVE-WORKFLOWS-PARITY.md#read-only-save-as-and-owned-save-decisions--october-16-2026).
