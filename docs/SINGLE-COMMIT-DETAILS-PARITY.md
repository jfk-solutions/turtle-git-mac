# Single-commit details and message workflows

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family ports the string `GitRev::GetCommit` selection and its connected
native consumers. It does not replace bulk history or every Git `show` command.

## Source behavior

`GitRev.cpp:246` selects command14 (`0x4000`), enabled by the source default
`0x66780` mask. The repository/string reader at line148 resolves `ref + ^{}`
before commit lookup, including annotated and signed tags. With `allowTree`,
the library branch retries the original reference as a tree; a tag pointing to a
tree therefore requires an explicit tree expression. The Git command equivalent
of the source gitdll fallback uses `ref + ^{tree}` and can peel such a tag.

`ParserFromCommit` at lines98–136 decodes author and committer names/emails and
the raw message using the declared encoding, with the source code-page aliases
and UTF-8 default. The first LF separates subject and body. Paragraph folding,
leading/trailing body whitespace removal and `git_commit_summary` would change
the displayed data. Raw bytes, timestamps and offsets remain available apart
from decoded display text. Mailmap is a separate display choice; it must not
rewrite the raw identity used for amendment.

The typed Working Tree choice bypasses object lookup. Ordinary revision strings
still require actual objects. Explicit trees have their own type, with no
fabricated author, message or commit date. Hash-based `GetCommitFromHash`,
`GetParentFromHash`, structural replay metadata and bulk history keep their
separate readers. Returning parent IDs with a detail object does not select a
new parent-list or history-walk engine.

## Connected consumers

| Source | Native workflow |
| --- | --- |
| `CommitDlg.cpp:1529/2753/2996/3091` | Amend identity, message and author date, retaining checked author/date controls and editable drafts |
| `CommitDlg.cpp:2206` | Fresh message lookup after accepting a revision from Log; hash insertion remains a separate action |
| `RebaseDlg.cpp:776` | Branch/upstream tooltips |
| `RebaseDlg.cpp:1704/2556` | Edit-to-Squash metadata and the applied HEAD message when Add cherry-picked-from is enabled |
| `RebaseDlg.cpp:3099` | Explicitly added replay revisions |
| `CommitIsOnRefsDlg.cpp:452` | Containing-reference commit details |
| `FileDiffDlg.cpp:279` | Comparison endpoint details with explicit tree allowance |
| `GitLogListBase.cpp:1711`, `GitStatusListCtrl.cpp:4585`, `RebaseDlg.cpp:2021` | Parent-menu captions shared by history, Reflog, replay and changed-file consumers |

Accepted reads retain the chosen backend through asynchronous metadata,
questions and publication. Changing settings cannot retarget the accepted read.
Refresh starts a new read; caches must distinguish the selected backend. User
edits, changed selection/HEAD and retired owners prevent stale publication.
Required message/identity reads retain the draft and report errors rather than
manufacture empty editable fields. Optional parent captions retain their source
hash fallback when details are unavailable, and cannot reuse captions from a
different backend. Native ownership includes any helper and child picker lifetime.
Saved user-authored amend drafts remain drafts, rather than automatic metadata
caches to discard when the backend changes.

For the native Git replay sequence, first-author metadata is consumed when the
pending Squash is approved, rather than stored in a new Windows-style reset
sidecar. Every date policy requires the selected detail read. The first-date
policy uses that signature's date; latest/current retain their own date choice.
Lossless UTF-8 identities can feed the author environment. Legacy signatures
retain Git's existing author bytes instead of rewriting them as UTF-8 under a
different declared encoding. Hash-only and non-Squash mutation reads remain
independent.

The helper protocol carries exact raw byte fields in ordered bounded chunks,
with strict metadata, object identity, counts and terminal framing. It permits
16MiB message bytes, 1MiB per identity/encoding field, 4,096 parents and 64MiB
total wire output. A requested missing runtime or incomplete reply fails
explicitly. These limits do not certify arbitrary oversized/corrupt Git objects.

## Checkpoint and remaining acceptance

The [dated checkpoint](qa/single-commit-details-2026-10-20.json) records actual
outcomes, initial failures and focused repairs. The relevant Core methods,
universal helper contracts and Debug build have passing local evidence. Native
validation found and repaired an Add publication race with background column
metadata. All eight native case/engine pairs now have passing evidence, including
a controlled overlap of Add and cosmetic refresh. Required editable reads,
backend cache replacement and owned cancellation/retirement are covered.
No pass is inferred from this source map. Full hosted integration, physical
keyboard/accessibility and layout acceptance, minimum-version/Intel acceptance,
all legacy code pages and installed signed grants remain separate requirements.
Remaining history/submodule ancestry and Combine-commits clean-state consumers
are tracked with the [inspection family](REPLAY-INSPECTION-PARITY.md).
