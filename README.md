# TurtleGit for Mac

<img src="docs/site/assets/application-icon.png" alt="TurtleGit application icon" width="96" height="96">

A macOS fork of [TortoiseGit](https://tortoisegit.org/), with native Git tools for Mac.
Browse history, review changes, commit your work and resolve conflicts in native
Mac windows, with Git commands and status badges in Finder.

TurtleGit is an independent, unofficial project based on TortoiseGit and requires
macOS 13 or later. Mac App Store distribution is planned; there is no published
store listing or purchase available yet.

## Features

- Finder context menus and file status badges, with [folder registration and Clone entry points](docs/GETTING-STARTED.md#start-from-finder).
- Commit, staging, branches, tags, remotes and synchronization.
- Searchable history, blame and revision graphs.
- Text comparison, three-way conflict resolution and partial staging.
- Standalone editable patch documents and piped diffs, including the waiting `turtlegit-udiff` launcher; see [command-line usage](docs/COMMAND-LINE.md#standalone-unified-diff).
- Native light and dark appearances and bundled offline help.
- Included Git and OpenSSH in the sandboxed distribution build.

Finder commands can open their own dialogs without opening a repository workspace.
Use **Open Repository…** when you want the main repository window.

See the [user manual](docs/GETTING-STARTED.md) for workflows and
[documentation index](docs/README.md) for detailed guides and known limitations.

## Screenshots

![Native Log with revision graph and changed files](docs/site/assets/mac-log-light-2026-10-27.png)

[See Commit and dark-mode screenshots](https://jfk-solutions.github.io/turtle-git-mac/#screenshots) or follow the [illustrated Getting Started guide](docs/GETTING-STARTED.md).

## Development

Requires Xcode and its command-line tools, Git, Python 3 and CMake.
The generated Xcode project is checked in.

```sh
./scripts/build.sh
open build/Build/Products/Debug/TurtleGitMac.app
```

The first build prepares pinned runtime dependencies and can take some time.
See [testing](docs/TESTING.md), [Finder development](docs/SIGNED-FINDER-DEVELOPMENT.md)
and [distribution](docs/DISTRIBUTION.md) for development and release requirements.
The website sources are in `docs/site`; see [website maintenance](docs/WEBSITE.md).

## Contributing

Bug reports and contributions are welcome. Include your macOS version, steps to
reproduce and the expected behavior. Use a sample repository when sharing files
or screenshots. Read [AGENTS.md](AGENTS.md) before changing the code.

## License

GPL v2, matching TortoiseGit. See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[Licenses](Licenses) for copyright, artwork and bundled dependency notices.
Port and upstream contributors are credited in [AUTHORS.md](AUTHORS.md).
