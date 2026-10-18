# Use TurtleGitMerge with Git

TurtleGitMerge can open native two-file comparison, three-file merge, and patch
review directly from a terminal. The waiting wrapper is
[`scripts/turtlegit-merge`](../scripts/turtlegit-merge). By default it uses
`/Applications/TurtleGit for Mac.app`; set `TURTLEGIT_APP` to another app bundle,
or `TURTLEGIT_MERGE_EXECUTABLE` to a development executable.

Use the wrapper's absolute path in your Git configuration. For example, after
placing it at `~/bin/turtlegit-merge`:

```sh
git config --global diff.tool turtlegit
git config --global difftool.turtlegit.cmd '"$HOME/bin/turtlegit-merge" --base "$LOCAL" --mine "$REMOTE" --readonly'
git config --global merge.tool turtlegit
git config --global mergetool.turtlegit.cmd '"$HOME/bin/turtlegit-merge" --base "$BASE" --theirs "$REMOTE" --mine "$LOCAL" --merged "$MERGED" --saverequired'
git config --global mergetool.turtlegit.trustExitCode true
```

Then use `git difftool` or `git mergetool`. Each command starts its own tool
process, waits for the editor to close and returns its result to Git. A three-file
merge reports success only after the result was saved, has no remaining conflict
markers and has no newer unsaved edits. Discarding a requested merge result does
not mark the Git merge successful. Saving a separate merged output preserves the
Base/Theirs/Mine inputs. No automatic staging occurs in this standalone editor.

Direct examples:

```sh
~/bin/turtlegit-merge --base old.txt --mine new.txt --readonly
~/bin/turtlegit-merge --base base.txt --theirs remote.txt --mine local.txt --merged result.txt --saverequired
~/bin/turtlegit-merge --diff change.patch --patchpath ./target
~/bin/turtlegit-merge --diff change.patch --patchpath ./target --reversedpatch
~/bin/turtlegit-merge --createunifieddiff --origfile old.txt --modifiedfile new.txt --outfile change.patch
```

With no file arguments the tool opens its native Open dialog. A patch without a
target asks for the target directory; a target without a patch asks for the patch.
`--wc` uses a supplied patch's containing folder as its default target. Read-only
and Blame requests retain navigation while refusing file mutations. `--line` is
one-based. Descriptive names such as `--basename` and `--mergedname` affect
captions; reflected names affect display metadata, never the filesystem paths.
Missing merge inputs are shown as empty panes. A file appearing or changing while
an edit is open requires Reload before it can be accepted as the new baseline.

A sandboxed App Store build requires file/folder authorization for command-line
paths, including a missing output's parent directory. A terminal path is not a
security-scoped grant. The tool retains its input/output grants until the
command finishes. Store distribution and physical signed acceptance remain
separate release checks.

`--deletebasetheirsmineonclose` is intended for disposable tool inputs. It removes
only explicitly supplied input objects whose identity and contents still match
the captured input, after owned editor work drains; it preserves changed inputs
and the merged output. It never removes a symlink target. This is a deliberate
macOS ownership adaptation to the source cleanup flag.

See [the source entry review](MERGE-TOOL-ENTRY-PARITY.md) and
[two-file behavior review](MERGE-TOOL-COMPARISON-PARITY.md) for remaining states and
platform differences. This does not certify complete TortoiseMerge parity.
