# Notes backend and owned editing

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This family implements the Notes storage boundary behind the existing native
Log, RefLog, Rebase and Synchronization editors. It does not replace their
already implemented editor or declare the broader history port complete.

## Exact source behavior

`Git.cpp:3747–3783`, `GetGitNotes` and `SetGitNotes`, open a libgit2 repository
unconditionally. They do not consult the master `UseLibgit2` preference or a
command-mask bit. Reading calls `git_note_read` with the default notes ref;
`GIT_ENOTFOUND` yields an empty displayed note, while other errors remain errors.
Writing calls `git_note_create` with overwrite enabled and the supplied text.
An empty string creates an empty note association; it does not delete the note.

`SetGitNotes` obtains one `git_signature_default` and supplies it as both author
and committer. The bundled library's `signature.c:191–205` reads `user.name` and
`user.email` and obtains the current time. Separate `author.*`/`committer.*`
configuration, `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment identities and dates do
not replace that signature. The library's `notes.c` default-ref lookup reads
`core.notesRef`, otherwise `refs/notes/commits`; it does not read `GIT_NOTES_REF`.
Additional `notes.displayRef` values describe Log display and do not become the
editable default note.

`AppUtils.cpp:3405–3432`, `EditNote`, first calls `CheckUserData`, then reads the
note, presents the project-configured Input dialog, saves on OK and rereads it.
`CheckUserData` at 3039–3063 checks all four effective author/committer fields and
offers Git Settings until they are available or the user declines. That UI
preflight is a separate source contract from the actual note-write signature.
Environment-only identity may satisfy the preflight while missing `user.name`
or `user.email` still makes `git_signature_default` fail. The native port must
show that failure rather than manufacture a signature from the preflight.

## Native storage and lifecycle

SHA-1 Notes read/write use the private owned libgit2 helper regardless of master
or mask settings. A missing helper or invalid reply is an error, without a generic
CLI fallback. Exact UTF-8 text, whitespace, line endings and empty associations
are preserved; NUL and non-UTF-8 note contents are refused rather than silently
rewritten. Project minimum length remains measured in UTF-16 units.

Existing native identity questions, Settings handoff, editor Undo, keyboard
acceptance, access leases and generation/retirement guards remain in place.
Reading failure does not open a blank replacement editor. A failed save retains
the draft; cancellation reaches owned work and waits for its process to drain.
A failed/cancelled process may already have published the note, so bounded
read-only recovery distinguishes confirmed saved content, unchanged state and
an uncertain outcome. Recovery never automatically retries the mutation.
Confirmed save followed by display-refresh failure is reported as saved and
kept separate from an ordinary write failure.

The accepted editor captures its exact commit and notes ref. Saving after
`core.notesRef` changes still updates that captured ref. This is an explicit
native adaptation: upstream passes a null/default ref independently at read and
write time. Post-save readback rereads that exact captured note; additional display refs and
current default-ref changes do not retarget the accepted mutation or returned
text. Existing Log entries/message panes
and owning history views use their established refresh callbacks. An existing
Notes search must still be refreshed to recalculate its match set.

## Explicit extension and wire bounds

The bundled libgit2 engine supports SHA-1 repositories. An explicit object-format
preflight retains the existing Git CLI extension for SHA-256 repositories; a
helper failure never triggers that route. Its note writes also use one configured
`user.name`/`user.email` signature at current time for author and committer, and
read/write use the literal captured ref through an owned environment override.
Git's builtin Notes command refuses refs outside `refs/notes/`; that explicit
SHA-256 extension limit is reported rather than normalizing the configured ref
or silently switching engines. SHA-1 libgit2 retains source configured-ref
semantics.

The private read/write verbs accept one bounded JSON stdin request. Text bytes
are canonical base64, as is the single versioned JSON reply frame. A raw note is
limited to 16 MiB; requests and frames are bounded at 32 MiB to allow both base64
layers and the bounded ref. JSON does not escape base64 slashes. Invalid frame
shape, object identities, base64, UTF-8 or incoherent blob/ref receipts are errors.
Recovery compares both ref and note-blob identities across two receipts, so a
torn note/ref read cannot falsely certify a concurrent replacement as saved.

## Scope and evidence

The initial grouped Core checkpoint passed 29 distinct methods: nineteen in
`NotesBackendTests`, six retained cancellation methods and four affected
`CommitHistoryTests` methods, with no failures. It includes real stored note bytes
and note-commit metadata, not only mocked protocol output. This Core result
precedes the later transient-config normalization repair. It was retained without
repetition because that repair is confined to helper config parsing; actual
affected contracts were subsequently validated on both runtime architectures.
The final native checkpoint also passed all ten case/engine pairs.
The suite includes actual maximum-size U+FFFF payload transport, typed malformed
receipts, source signatures/default refs, missing runtimes, live cancellation and
unchanged/completed/uncertain/torn recovery receipts, including an existing
identical note whose failed write must remain a failure. Retained command-intercepted
Core cancellation tests now explicitly exercise the SHA-256 extension, with
command parsing that tolerates internal configuration prefixes. Their marker,
PID-drain and repository-preservation assertions remain.

The first helper build failed because a callback omitted the
`CallbackContext` qualifier on `notificationString`. After that repair the
universal helper built and passed structural auditing, but execution validation
found a genuine transient-config defect: mixed-case `core.notesRef` was ignored
by the memory config backend, reading the default note instead. The helper now
normalizes ASCII section/variable key portions while retaining literal subsection
and value bytes. The second repair build exited successfully, reusing pinned
arm64/x86_64 static slices. Actual `--all-architectures` execution validation
passed, including mixed/uppercase transient settings, counted/quoted Notes refs,
exact dotted NFC/NFD remote subsections and Unicode/space local URL values through
`ls-remote` on both slices.
Both Debug app builds exited successfully. The initial log contained 47
contradictory “failed with exit code 0” diagnostics; the final build embedding
the repaired runtime contained none. The grouped native Notes checkpoint passed
all ten pairs on their first receiver attempts: editor, Log, outcomes, ownership
and identity with system and bundled Git. All ten owned receiver PIDs were reaped
and independently absent; no helper fallback cleanup was required. These are
offscreen native workflow checks, not physical or signed acceptance.

Help generation/check completed with 58 documents, 51 topics, 80 files and
3,869,089 bytes; the localization catalog retains 38 languages and 1,318 keys.
The checkpoint record includes final production/fixture hashes and helper
manifest, binary, cache-key and static-slice provenance.

The [current checkpoint record](qa/notes-backend-family-2026-10-24.json) retains
these failures and their distinct validation scope. Existing editor/lifecycle
coverage remains documented in [Edit Notes parity](EDIT-NOTES-PARITY.md); its
older evidence remains scoped to its own earlier source revision. The current
record establishes only this affected family, not full source/UI parity.

Remaining limitations include physical keyboard/menu/focus acceptance across
every host, signed sandbox/App Store deployment and wider malformed/configuration
compatibility. Native error and uncertain-write handling deliberately retains
stronger diagnostics than source paths that continue after a read error.
Notes search, general Jump/navigation, remote notes transport configuration and
new backend controls are outside this family.
