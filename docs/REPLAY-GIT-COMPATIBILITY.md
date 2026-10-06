# Replay Git compatibility

Cherry Pick uses an interactive Rebase plan. Git 2.37.1 and 2.39.5 reject the
former `--empty=stop` argument; Git 2.39 documents `drop`, `keep` and `ask`.
Interactive replay already implies stopping when a patch becomes empty. TurtleGit
now relies on that behavior while retaining `--keep-empty` for commits that were
originally empty. No version detection or fallback changes the replay plan.
See the official [Git 2.39 documentation](https://git-scm.com/docs/git-rebase/2.39.0)
and [Git 2.50 documentation](https://git-scm.com/docs/git-rebase/2.50.0).

The regression fixture applies a selected patch to the destination first, then
adds a separate target commit. Replaying the selected patch must stop with no
conflicting files and retain its original identity through reopening. Skip must
finish without changing the destination HEAD or its files. The whole-native
receiver also checks the actual window model's error, selection and Skip action.

Local checks passed with Git 2.37.1, 2.39.5, system Git 2.50.1 (Apple Git-155)
and packaged Git 2.55.0 on arm64. All 21 focused Rebase tests, unsigned Debug and
App Store builds, both bundle audits and exact NOTICE comparisons also passed.
Evidence is recorded in `qa/replay-git-compatibility-2026-10-06.json`.

## Reproducing older Git checks

Build the Debug framework and SwiftPM editor before running the receiver. Build
the App Store product with its pinned Git runtime to include that executable.
The following commands assume both Xcode configurations use `build`:

```sh
python3 scripts/build-replay-test-git.py --version 2.37.1
python3 scripts/build-replay-test-git.py --version 2.39.5
python3 scripts/check-cherry-pick-native.py \
  --git /usr/bin/git \
  --git build/replay-test-git/2.37.1/bin/git \
  --git build/replay-test-git/2.39.5/bin/git \
  --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git
```

The builder verifies official source archives against pinned SHA-256 digests in
`Configuration/GitReplayTestRuntimes.json`, then builds only the current host
architecture with a macOS 13 deployment target. These binaries are test-only:
they omit HTTP/HTTPS transport and GUI/script dependencies and do not replace
system or packaged Git. Choose a fresh `--output` directory to rebuild.

GitHub Actions uses these same checks, with its App Store product under
`build-store`. Local verification does not establish a hosted CI pass. These
headless receivers do not verify displayed dialogs, gestures, accessibility or
signed sandbox execution; complete TortoiseGit parity remains unfinished.
