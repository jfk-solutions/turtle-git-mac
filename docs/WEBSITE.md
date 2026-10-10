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

Submodule Update captures use the disposable two-module fixture. The light plan,
selective result and idle dark plan were visually inspected before copying.
Native checks verified scope/selection/Cancel, selective Init/No fetch and saved
options. A capture during F5 refresh was replaced with the idle dark window.
Each sequential test process exited before the next opened.

## Commit and Log capture refresh, 10 October 2026

The light/dark Commit pair and Log Messages gallery now use inspected current
native captures. Commit shows Modified, Added, Deleted and Untracked paths with
original colored status icons, the metadata and staging checkboxes, and a message
above the file list. The displayed action menu was inspected for Commit, ReCommit
and Commit & Push. Log shows the graph before revisions, colored references, the
full selected merge message and files grouped by parent. The external UI
automation tree also exposes graph image descriptions in its native table rows.

Comparisons used the pinned `doc/images/en/Commit.png` and `LogMessages.png` plus
the official [Commit](https://tortoisegit.org/docs/tortoisegit/tgit-dug-commit.html)
and [Log](https://tortoisegit.org/docs/tortoisegit/tgit-dug-showlog.html) manuals.
The capture exposed a vertically wrapped To label; keeping both native date
pickers at their intrinsic horizontal sizes corrected the default-size filter
row before the new Log screenshot was copied. Other locales, minimum sizes and
date editing still need broader layout acceptance.

Only one isolated preview process ran at a time. The Appearance menu could be
read but its automation actions failed, so the next preview used the helper's
dark preset. Each exact owned process was terminated and verified absent before
the next opened. No Commit action was invoked. The fixture's HEAD, status and
index bytes were preserved during capture. All PNGs were copied unchanged from
the Debug current-process screenshot helper; the native macOS capture indicator
is part of the window decoration. Earlier historical captures remain in the
asset directory. See [capture QA](qa/dialog-captures-2026-10-10.json); a local site
build does not verify publication or full application/VoiceOver/signed acceptance.

The opening section now offers Source, Native windows and Port progress. Detailed
audit links remain in Project documentation. Log is the first image below its
heading, and the screenshot note distinguishes the refreshed pair from historical
captures. The generated local page's introduction and Log section were inspected
in the in-app browser; the preview tab and exact owned HTTP server were closed.
The complete gallery, responsive layouts and hosted publication were not verified
in this capture refresh.
