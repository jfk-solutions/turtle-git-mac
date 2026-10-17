# Languages

Choose **Settings → General → Language**, then **Apply**. Restart TurtleGit to
apply the language throughout the app. **Cancel** discards an unapplied choice.
**System Language** follows macOS; choosing it removes TurtleGit's own language
override. These preferences belong to TurtleGit and do not change your system or
Git configuration.

The First Start Wizard offers the same bundled languages. **Next** saves its
language page. As with other wizard pages, cancelling a later page keeps that
saved choice. Unlike Windows' separate TortoiseGit processes, this native app does
not relaunch itself and discard other open windows after a language change.

English and 37 source translation catalogs are bundled. Language names appear in
their own language with an English description. They cover matching TortoiseGit
labels, including common buttons, checkboxes and command captions. Coverage varies:
Mac-specific wording, dynamic messages and remaining native AppKit captions can
still appear in English. This is partial localization, not a claim that every
window is fully translated. Git commands, repository/reference names, filenames,
user text and server diagnostics are not translated as labels.

Missing, fuzzy, ambiguous, plural and formatted source entries use English until
they have a reviewed native adapter. German includes a small set of Mac-specific
setup/navigation translations. No Windows language DLL is loaded or installed;
additional translations arrive with app updates. Bundled Help remains English.

For contributors, `python3 scripts/build-localizations.py --write` generates the
String Catalog, locale identifiers, manifest and retained translator notices from
the pinned upstream PO blobs. `--check` verifies the same artifacts without
changing them. `Configuration/NativeTranslations.json` contains reviewed native
wording adaptations. The app bundle audit checks all compiled locale tables and
English fallback. The SwiftPM executable is an unbundled development entry point;
localized distribution uses the Xcode app.
