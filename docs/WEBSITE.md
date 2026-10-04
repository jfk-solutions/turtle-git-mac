# Project website and screenshots

Published site: https://jfk-solutions.github.io/turtle-git-mac/

The first deployment succeeded on 2026-10-03 after enabling the repository’s
GitHub Actions publishing source. Repository name: `jfk-solutions/turtle-git-mac`.

The GitHub Pages site is a static page at `docs/site`. Build it with:

```sh
python3 scripts/build-site.py
python3 -m http.server 8768 --bind 127.0.0.1 --directory build/site
```

The build reads `GITHUB_REPOSITORY` in Actions and derives it from `origin` locally.
Repository links therefore follow a later rename. No analytics, third-party scripts
or remote fonts are included. All screenshots use a disposable sample repository.
The page must describe the current development state without claiming full parity.

`.github/workflows/pages.yml` builds on changes to the site/docs and supports
manual dispatch. Configure the repository's Pages publishing source to **GitHub
Actions** to activate it. A successful Actions deployment must be verified before
calling the public website published; a local preview is not publication.

## Updating native screenshots

Do not use private repositories in screenshots. Create fresh sample data; the
script refuses to overwrite an existing directory:

```sh
python3 scripts/create-demo-repository.py /tmp/TurtleGitSample
./scripts/build.sh
python3 scripts/create-preview-app.py \
  build/Build/Products/Debug/TurtleGitMac.app \
  /tmp/TurtleGitDocumentation.app --repository /tmp/TurtleGitSample
```

If a local Xcode installation cannot build bundles, run `swift build` and add
`--swift-executable .build/debug/TurtleGitMac` to the preview-copy command. It copies
the Swift Package executable and its icon resource bundle into the temporary app.
It places resources inside Contents/Resources and signs the temporary app ad hoc
so its copied signature is valid. Use `--bundle-identifier` and `--name` for isolated
previews, and `--appearance light` or `--appearance dark` for comparisons.
This is for documentation QA only; it does not build or validate the Finder extension.

Open the preview app, select the relevant native window and use **Development →
Save Window Screenshot…** (Command-Option-Shift-S). The helper is Debug-only and requires
macOS 14.4 or later. It uses ScreenCaptureKit's current-process content API to
capture the selected app window, without requesting access to other applications
or displays. Save into `docs/site/assets`. Verify native controls, graph edges,
column layout and sample-only content before publishing. The screenshot build validates the current asset list, including light/dark
Commit and Rebase examples. Older captures document the pictured earlier UI.

If the native Save panel is unavailable, configure a new output file with
`--screenshot /tmp/turtlegit-capture.png` when creating the Debug preview. The same
Command-Option-Shift-S action captures its own selected window directly to that file.
Verify the image exists before quitting the preview, then copy the actual capture
into the website assets. This does not synthesize or alter the window image.

The preview has its own bundle identity and temporary recent-repository store; it
does not reuse the real app's saved permissions or URL handler.

For native keyboard QA, verify the host keyboard layout before interpreting
shortcut failures. On the current host, the automation key named `y` produces
logical `z`; `super+y` and `super+shift+y` therefore exercise Command-Z and
Shift-Command-Z. This was verified by inserting a visible `z`, undoing it and
redoing it in the merge editor. Do not change application shortcuts to compensate
for physical automation key names.

Close each disposable QA application immediately after its checks, including
failed observation attempts once the scenario has ended. Verify it is absent
from the running-app inventory without reacquiring its handle, which can launch
it again. Do not accumulate independent preview instances across goal turns.

The Restore after commit capture uses only `restore.txt` in a disposable fixture.
Its caption records the verified ReCommit/working-file behavior and distinguishes
the verified single-window Quit choices from pending close/failure variants. Keep at most one QA preview process open;
close it after the scenario and verify process absence before launching another.

The light/dark Revert captures use the disposable Revert dialog fixture. They
show the actual checked direct-file/addition plan, original artwork and complete
columns after native width/footer corrections. The gallery distinguishes URL
routing checks from signed Finder extension activation.

The Revert progress capture uses a disposable delayed-filter fixture. It records
actual cooperative cancellation after the running checkout finishes, completed
rows, the recovery location and terminal controls. It was inspected before being
copied unchanged. HEAD, indexed contents and the exact Trash copy were checked;
the preview was closed and its process absence verified.
