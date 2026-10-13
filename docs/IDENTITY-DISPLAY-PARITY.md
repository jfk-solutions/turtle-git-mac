# Mailmap identity display across native viewers

The pinned `CGitMailmap::ShouldLoadMailmap` reads the `UseMailmap` preference with
a default of true. Its translation applies to author and committer identity
shown by revision readers. Settings → Dialogs 2 already exposed this preference,
and Log/Browse References already passed it to their queries. Graph, Blame's
history pane, Contains Commit, comparison revision summaries, and WCRev had
fixed raw or mapped formats, so they could disagree with the chosen setting.

`GitIdentityDisplay` centralizes raw/mapped author and committer format atoms.
Graph captures the window's supplied preferences on each load, applying the
same policy to ordinary nodes and excluded parent boundary nodes. Blame captures
its supplied preferences for each read and Copy Log request. Contains Commit
captures its supplied preferences before its completion/revision queries start.
Comparison summaries and WCRev capture the setting at their backend invocation;
these APIs also accept an explicit choice for isolated callers.

Git can translate porcelain blame identities independently of the viewer setting.
After the viewer fetches its ordinary history, it applies those policy-selected
identities to annotation display without another Git query. Attribution hashes,
original/final line numbers, dates, timezones, source paths, boundaries and exact
source bytes are retained. The lower history pane, annotation margin, properties
and copied Log details consequently use the same choice. The standalone porcelain
reader/parser still represents Git's response; display normalization is explicit.

These are display changes. Commit/amend identity defaults, editable author fields,
rebase replay signatures and commit objects continue to use their existing raw
metadata paths. A mapped display identity must not become the author of a new
commit simply because a user enabled mailmap.

The focused Core fixture compares both policy values across Graph, Blame history
and annotation display, Contains Commit, revision summaries, WCRev, copied Log,
Browse References and Log. It uses different original/canonical author and
committer contacts and checks exact commit object, index, source and mailmap bytes
before and after the reads. A private native receiver changes the preference
through both values, reloads Graph/Blame, and checks annotation/history/graph
identities and Copy Log through an injected clipboard writer. Its preferences,
clipboard and repositories are isolated, and owned windows/processes are closed.

Physical Settings Apply interactions, VoiceOver, editing mailmap during a query,
all inherited/global mailmap sources, copied-origin annotations whose commits
are absent from the loaded history (which retain Git's response), secondary graph
ancestry/tooltip paths,
large histories and signed App Store execution remain acceptance work. This
batch does not certify whole-dialog or whole-app parity.

The initial grouped Core run passed 51 tests. After adding explicit annotation
display normalization, the two affected identity tests passed again. The final
Debug build, two native receivers with system/bundled Git, unsigned app bundle
audit and two site documentation checks passed. Both owned native receivers were
reaped. [Evidence](qa/identity-display-2026-10-13.json) records these scopes.
