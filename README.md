# TurtleGit for Mac

<img src="docs/site/assets/application-icon.png" alt="TurtleGit application icon" width="96" height="96">

Native Git tools for macOS, inspired by [TortoiseGit](https://tortoisegit.org/).
Browse history, review changes, commit your work and resolve conflicts in native
Mac windows, with Git commands and status badges in Finder.

TurtleGit is an independent, unofficial project based on TortoiseGit. It is under
development and requires macOS 13 or later. Distribution is planned through the
Mac App Store; the app is not yet available for purchase.

## Features

- Finder context menus and file status badges.
- Commit, staging, branches, tags, remotes and synchronization.
- Searchable history, blame and revision graphs.
- Text comparison, three-way conflict resolution and partial staging.
- Native light and dark appearances and bundled offline help.

See the [user manual](docs/GETTING-STARTED.md) for workflows and
[documentation index](docs/README.md) for detailed guides and known limitations.

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
