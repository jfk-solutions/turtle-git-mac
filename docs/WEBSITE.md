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
This is for documentation QA only; it does not build or validate the Finder extension.

Open the preview app, select the relevant native window and use **Development →
Save Window Screenshot…** (Command-Shift-7). The helper is Debug-only and requires
macOS 14.4 or later. It uses ScreenCaptureKit's current-process content API to
capture the selected app window, without requesting access to other applications
or displays. Save into `docs/site/assets`. Verify native controls, graph edges,
column layout and sample-only content before publishing. The current public images
are `log-messages.png`, `status.png`, `commit.png`, and `staging.png`.

The preview has its own bundle identity and temporary recent-repository store; it
does not reuse the real app's saved permissions or URL handler.
