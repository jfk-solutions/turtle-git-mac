# Help in TurtleGit for Mac

Choose **TurtleGit Help** from the Help menu, press Command-?, or use a dialog's
**Help** button. F1 (or Fn-F1 on keyboards that use the top row for hardware
controls) opens help for the active window. Settings also has a Help button for
its selected page. A child sheet normally inherits its parent's topic.

The application includes an English Mac help book with contextual workflow guides.
Its contents are available offline. The installed app requests the matching topic
in macOS Help Viewer. Use Help Viewer's search, or follow the topic links and
Getting started navigation. If help-book registration is unavailable, TurtleGit
opens the same local HTML chapter in the default browser. Browser Find searches
that chapter. If the book itself is missing, it opens the online Mac manual.

The [dialog guide](DIALOG-GUIDE.md) explains the implemented options in Commit,
Log, references, Push/Pull/Fetch, replay, conflict, working-file, patch, submodule,
worktree and settings workflows. Longer task guides cover topics such as
[Cherry Pick](CHERRY-PICK.md), [repository folder permissions](REPOSITORY-FOLDER-ACCESS.md)
and [saving comparison results](SAVE-AS-TARGETS.md).

Credential settings has its own [offline guide](CREDENTIAL-SETTINGS.md), including
Apply versus Add New/Save and inherited settings. Some related dialogs and
settings categories share a chapter. Links to source
audits and further online material require a network connection. The help book
describes a port in progress; it does not imply that every upstream dialog or
signed Finder/App Store workflow is complete.

## Maintaining the bundled book

`docs/help-topics.json` selects the Mac guides and stable topic anchors. HTML is
generated from those Markdown sources, without remote scripts or fonts. Run:

```sh
build/site-venv/bin/python scripts/build-help.py
build/site-venv/bin/python scripts/build-help.py --check
```

The checked-in book lives in `Sources/TurtleGitMac/Resources/TurtleGitHelp.help`.
The app build copies it and runs `scripts/index-help.py` to verify the copied
content and generate the local search/anchor index with Apple's `hiutil` before
signing. Ordinary app builds need no Markdown renderer. SwiftPM copies the same
HTML resources and can use the offline browser fallback.

The implementation follows Apple's
[help-book structure](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/ProvidingUserAssitAppleHelp/authoring_help/authoring_help_book.html)
and [topic-anchor API](https://developer.apple.com/documentation/appkit/nshelpmanager/openhelpanchor(_:inbook:)).
Physical Help Viewer registration/search/display, every keyboard layout,
localization and signed distribution still need acceptance. Native dispatch tests
inject viewer/browser opening; they do not launch those applications or claim
that acceptance.
