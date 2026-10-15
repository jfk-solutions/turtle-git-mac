# Commit filename completion audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This records a partial editor port; complete Commit parity remains outstanding.

## Source mapping

| Source | Native implementation | Behavior |
| --- | --- | --- |
| CommitDlg.cpp::GetAutocompletionList | MessageCompletion.fileCandidates | Every displayed path and every slash suffix, including unchecked and unversioned rows |
| SciEdit.cpp::DoAutoCompletion | MessageCompletion.request/matches | End-of-word gate, default three-character automatic trigger, original/lower/upper variants, hyphen-part matches and literal UTF-16 ordering |
| SetDialogs2.cpp / SettingsAdvanced.cpp | CommitEditorSettings | Saved Autocompletion (default true), AutoCompleteMinChars (default 3) and AutocompleteRemovesExtensions (default false) |
| IDI_FILE / Resources/file.ico | CommitCompletionPopup | Original unmodified file icon in a native AppKit popover |

The extension option adds only the last basename without its last extension;
a leading dot alone is retained. Canonically equivalent filenames remain
separate literal UTF-16 keys, as in the source map. Marker trimming retries the
full word when it finds no completion.

Ctrl-Space requests completion after one character. Option-Escape is a macOS
alias. Arrow keys select; Return, Tab or a mouse click accepts; Escape dismisses.
Acceptance replaces the requested prefix and forms a separate Undo operation.
The popup uses the caret's native layout geometry and dynamic light/dark colors.
A tooltip retains the entire filename when a long row is truncated.

## Verified behavior

Four focused completion tests cover path suffixes, extension rules, literal
Unicode identity/order, minimum lengths, casing/hyphen variants, end-of-word and
selection gates, marker fallback and replacement ranges. The full local suite
passed 389 tests with zero failures. Unsigned Debug and App Store builds and
bundle audits passed, including all 65 original icon resources.

Native acceptance used a disposable repository with a checked modified
`src/nested/Widget.swift` and unchecked unversioned `Window.swift`. Two typed
characters did not show the automatic popup; the third did. Tab acceptance and
Undo preserved the prefix. Manual Ctrl-Space, Option-Escape, arrow/Return and
mouse acceptance were exercised. A saved disabled switch suppressed Ctrl-Space;
re-enabling it with the extension option produced Widget, Widget.swift, Window
and Window.swift. Undo after mouse acceptance restored the one-character draft.
Actual light and dark captures were inspected. All QA processes quit normally,
and HEAD, raw index and tracked working bytes remained identical to baseline.

See [recorded acceptance](qa/commit-completion-2026-10-05.json).

## Still outstanding

- Complete Windows decoder equivalence and native acceptance of scanner
  settings, interruptions, icon appearance and signed file/helper access.
  Definitions, extraction and content gates are implemented in the audit below.
- Exact Windows ANSI decoding and embedded-NUL snippet behavior; native snippet
  loading, icons and expansion are accepted in the section below.
- Complete installed-language/personal-word coverage and physical spelling-menu
  acceptance. Source-aware native spelling and Ctrl-Tab suggestions are implemented
  in subsequent dated batches.
- Exact Windows locale casing/word classification, arbitrary DWORD minimums,
  empty-prefix edge cases, full Scintilla popup lifecycle and Tab focus behavior.
- Large catalogs, input methods, accessibility navigation, signed sandbox
  acceptance and the remaining Commit/settings controls.

The native minimum editor currently offers 1–100 characters. A filename/snippet
fallback is available while the source-style timed background scanner builds
the combined catalog. Complete settings and scanner acceptance remain required
before full parity can be claimed. GitHub verification of these
local changes is pending publication.

## Shipped and user snippet definitions

`MessageSnippets.swift` adapts CommitDlg.cpp::ParseSnippetFile and HandleSnippet.
The original shipped sample file remains unchanged; all sample definitions are
commented out. Resource provenance pins its Git blob
`301f52c0a1aacdcf53775677ec24b0be949b70d8`. The original snippet icon's blob is
`ceb1ca48619cea69a46d15e114b24d6fb4054f38`.

Create `snippet.txt` in `~/Library/Application Support/TurtleGit/` for an ordinary
build. A sandboxed distribution uses its private Application Support container.
Definitions are read off the main thread when the Commit file list loads or
refreshes. Press F5 after editing the file. User keys override shipped keys;
snippet keys win collisions with filename candidates, matching source insertion
order. Unreadable/missing definition files are skipped, as upstream does.

```text
fix=Fixed issue #42\nSecond line\tDetail
```

Only a '#' in the first position makes a comment. The first '=' separates a
nonempty key from its value. Neither side is trimmed; values can be empty or
contain additional '=' signs. Recognized escapes are `\t`, `\n`, `\r` and
`\\`. Unknown escapes remain literal, and a trailing unpaired backslash is
lost, preserving the source parser behavior. Keys retain literal UTF-16 identity.

The native loader accepts UTF-8 with optional BOM, UTF-16 LE/BE with BOM, and
Windows-1252 fallback. This is a deliberate macOS decoding adaptation; exact
Windows CStdioFile locale/ANSI behavior, embedded NULs and malformed encodings
remain under audit.

Selection displays the original colored snippet icon and replaces the current
word with the expanded value without an extra newline. Unlike a filename,
a snippet recomputes the styled word selection even if completion matched the
raw marker-prefixed key. Thus `_Spe` selecting `_Special` retains the leading
underscore and inserts the expansion after it, following HandleSnippet.
Expansion is one Undo operation and retains editor focus.

The full local suite passed 393 tests with zero failures. Unsigned Debug and
App Store builds, snippet-resource provenance and all 66 original icons passed
bundle audits. Four snippet tests cover escapes/whitespace/comments/overrides, empty values,
literal Unicode keys and filename collisions, marker-aware selection and
missing/custom UTF-8/UTF-16 files. Native checks verified multiline/tab expansion,
Undo to `fix`, filename collision priority, `_Special` replacement and changed
file reload. Actual expanded-message and light/dark popup screenshots were
inspected. The sole QA app quit normally and repository state remained identical.
See [snippet acceptance](qa/commit-snippets-2026-10-05.json).

Code-symbol extraction, spelling, full popup lifecycle/keyboard parity,
accessibility and signed sandbox workflows are still outstanding.

## Keyboard dispatch follow-up

The original native key handler requested completion after any nonempty key
character. Arrow and delete keys can have such characters despite inserting no
text. It now records actual NSTextView insertText calls during an ordinary typed
key event, matching SciEdit's SCN_CHARADDED trigger more closely. Navigation,
deletions, clipboard commands and programmatic snippet acceptance do not by
themselves request automatic completion.

With no active popup, Tab/Shift-Tab call the native window's next/previous key
view selection rather than inserting a tab in the message. This maps the source
WM_NEXTDLGCTL rule to macOS focus order and keyboard-navigation preferences.
Tab continues to accept an active popup. Ctrl-Tab spelling suggestions are implemented in the October 15 batch below.
Broader input-method composition and full popup lifecycle still need acceptance.

Unsigned Debug/App Store builds, bundle audits and eight completion/snippet
regression tests passed. At that stage, native acceptance was pending because
the Mac locked before controls could be inspected. The later code-scanner QA
verified arrows, Backspace, typed reopening, paste/explicit request and Tab focus;
input methods, forward Delete and complete lifecycle acceptance remain pending. The single disposable preview
was identified by its exact executable path and stopped with SIGTERM because
normal UI Quit was unavailable; the final process scan was empty.

When the Mac is available, verify the following against the same disposable
checked Widget.swift / unchecked Window.swift fixture:

1. Type Wid and verify automatic completion, then Right/Left without reopening.
2. Type a matching longer prefix, dismiss, then Backspace/Delete without reopening;
   type another character and verify completion returns.
3. Paste a matching prefix without opening automatic completion, then Ctrl-Space
   and Tab acceptance, followed by Undo to the prefix.
4. With no popup, Tab and Shift-Tab change native focus without changing the draft;
   with a popup, Tab accepts the candidate instead.
5. Verify HEAD, raw index and working bytes remain unchanged, and quit the sole
   preview normally after testing.

See [build and pending acceptance record](qa/commit-completion-keys-2026-10-05.json).

## Code-symbol scanner groundwork

The upstream definition parser and icase ECMAScript capture engine are now
ported and tested. Changed-file scanning and popup integration now use them,
as recorded in the following section. See the [code-symbol audit](COMMIT-CODE-SYMBOL-PARITY.md) for
source semantics, retained quirks and required decoding/gating/native acceptance.

## Changed-file code catalog integration

The Commit popup now combines filenames, snippets and code captures from the
changed-file scanner. It records candidate kind during source-order insertion
and selects original file/code/snippet artwork accordingly. Shipped/private
definitions, raw decoding, cache and content gates are implemented. Native code
acceptance, snippet collision, Undo, unchecked rows and F5 rescanning are recorded
in the [code-symbol audit](COMMIT-CODE-SYMBOL-PARITY.md). Complete decoding, visual,
keyboard-focus and signed sandbox acceptance remain partial.

## Explicit spelling suggestions across message editors — October 15, 2026

Pinned `SciEdit.cpp::SuggestSpellingAlternatives`, `GetWordUnderCursor` and the
Ctrl-Tab branch in `PreTranslateMessage` select the full word around the caret,
query the dictionary, display spelling entries and replace the suffix as well as
the prefix. CommitDlg registers `IDI_SPELL` for this completion kind. The native
shared message text view now implements that route for Commit, Merge and Rebase.
Ctrl-Shift-Tab also requests spelling, matching the source's modifier check.
Plain Tab retains Commit's existing focus/completion behavior.

The native popup reuses the original byte-identical `spell.ico` and the existing
caret-anchored light/dark suggestion presentation. Dictionary order is preserved;
empty/duplicate exact UTF-16 suggestions are removed. Up/Down selects, Return or
Tab accepts and Escape dismisses. Replacement preserves surrounding source-style
underscores and is a separate Undo operation. Spelling values bypass filename
completion/snippet expansion. A changed message or selection refuses the old
replacement. Read-only editors, disabled project/global spelling, an attached
sheet and active marked-text composition do not query suggestions. Closing or
removing the editor dismisses the popup.

macOS dictionaries supply guesses using the project's existing language mapping;
Windows Hunspell files are not loaded. An explicit request is independent of the
filename Autocompletion switch. The shared views now read spelling preferences
from the hosting Commit/Merge/Rebase preference domain, and Commit filename
completion reads that domain as well. Native macOS spelling/personal-word menus
remain available. This batch adds a Spelling suggestions context action with the
original icon; physical context-menu activation remains separate acceptance.

The Core whole-word adapter uses UTF-16 ranges, Unicode letters/marks/numbers and
the source apostrophe/underscore/hyphen word characters. Exact Windows locale and
Scintilla word classification are not certified. The native fixture uses injected
guesses to keep installed dictionaries and personal words unchanged; it does not
prove every installed dictionary, physical keyboard routing or VoiceOver.
[Recorded checks](qa/message-suggestions-2026-10-15.json) identify the actual
scope. Complete editor/dialog/application and signed sandbox parity remain open.

## Shared source-style presentation — October 15, 2026

The [shared message styling family](SHARED-MESSAGE-STYLES.md) connects issue/URL
hotspots and source text formatting to the native Input, Notes, Merge and Rebase
editors, with owning font/style preferences, IME protection and owned cancellation.
Descriptions keep the source non-project route. Earlier missing issue-styling
statements above are superseded only for this implemented scope; full physical,
Scintilla and signed acceptance remain open. See its dated evidence.
