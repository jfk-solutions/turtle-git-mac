# Historical Browser folder archives

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`RepositoryBrowser.cpp` recursively delivers selected historical folders;
`AppUtils.cpp::Export` uses Git archive for committed-content archives. The
explicit Browser archive entry is a macOS delivery adaptation joining those
existing workflow families, not a claim that the source Browser has this exact
additional menu item.

## Namespace and output contract

A Browser snapshot pins its accepted tree-ish and root tree. Archive export
validates that relationship and the selected directory in that historical tree.
It does not require that directory to exist in the working tree, and works in a
bare repository. Exact Git path bytes are sent through the existing byte-aware
argument transport as literal pathspecs; display escaping and opaque selection
keys are never filenames or effective process arguments.

The archive retains full Git-relative member names, including the selected
folder's prefix. Its outer filename is a normal user-chosen macOS location.
Git's filename-selected archive writer preserves committed content,
`export-ignore`, commit-based `export-subst`, executable and symlink metadata.
Submodules follow Git archive behavior; their external repositories are not
recursively included. Historical Open/Save's checkout-filter materialization is
a separate operation, and archive export does not run that smudge route.

A changed working tree, moved branch or changed current Browser selection cannot
retarget an accepted request. The owner retains its source grants, chooser,
cancellation and actual archive work through settlement. Output is prepared in a
private replacement workspace; successful Git execution is distinct from final
destination publication. The accepted destination identity/content/absence is
revalidated before replacement. Failure or cancellation retains an existing
archive and removes temporary output.

## Explicit boundaries

An archive can store names that the receiving filesystem cannot create. On the
observed development volume, creating a raw `0xFF` filename failed with EILSEQ;
that is a private host capability observation, not a universal filesystem claim.
Archive support does not rename members, enable original-path checkout, make raw
working-tree mutation safe, or implement literal folder/file promises containing
unrepresentable names. Extraction depends on the receiving tool and filesystem.
A ZIP reader's decoded display name is not proof of its original header bytes.

Complete source layout, physical menu/picker interaction, signed sandbox output
grants, external archive writers and full hosted integration remain separate
acceptance gates. A tree-only snapshot retains Git's tree-only archive behavior;
commit substitution requires a commit context. Existing output receipts compare
full destination bytes, so bounded-memory processing of a large existing archive
is not claimed.

## Grouped checkpoint

The [checkpoint receipt](qa/browser-folder-archive-2026-10-29.json) records 11
distinct focused Core methods cumulatively passing and both native Git-engine
workflows. The initial command composition incorrectly put a second `--` after
the tree-ish, which Git archive treats as a filename. The focused repair removes
that separator while retaining literal raw pathspec transport. The TAR fixture
then needed an explicit private `tar.umask=0022` for its exact executable-mode
assertion; the assertion remains intact.

Native checks use actual menus and injected Save responses in invisible private
owners. They cover raw/deleted/current/root/bare scopes, archive attributes and
complete bytes, moved named references, stale menu/panel ownership, denied output
grants, destination replacement and actual process cancellation/close drain.
HEAD, index, working bytes and private Git configuration remain unchanged. The
receiver's initial async oracle compile error and its fixture-only repair remain
recorded. These checks do not establish physical picker or signed acceptance.
