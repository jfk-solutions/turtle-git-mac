# TurtleGit for Mac development

## Implementation batches

The user wants substantial porting batches followed by grouped validation.
Implement a complete related dialog/workflow family, including its model, Git
operations, native controls, source icons, persistence and documentation, before
running its tests. Compare behavior and layout with the pinned TortoiseGit source
and resources; retain an explicit list of missing behavior. Do not declare the
whole port complete from implemented screens alone.

Keep several related missing behaviors in the same implementation batch rather
than making each small parity correction its own milestone. Finish the planned
functionality and layout work before validation; do not interrupt implementation
for repeated builds, screenshot runs or commits. A failure may require a focused
repair and recheck, but does not justify restarting the complete validation set.

At the start of a batch, state its concrete implementation scope and keep working
through that scope before the validation checkpoint. Prioritize missing end-user
port functionality; do not substitute test-harness, packaging or audit work for
that scope unless it directly blocks implementation or the user requests it.
Do not expand validation after the relevant checks pass. Record remaining gaps
and move to the next substantial implementation batch.

A single setting consumer, warning, menu action or parity defect is not normally
a complete implementation batch. Use the outstanding work in its workflow family
to define a substantial batch covering related menus, dialog behavior, Git actions,
ownership/cancellation and source parity. Implement the batch before its build or
verification checkpoint. Progress/status requests do not trigger another test run.
If a specific blocker requires an earlier compile, explain that blocker and run
only the check needed to resolve it, then continue the implementation batch.

Do not run tests on a timer or after every small edit. Perform one relevant Core
check and one grouped native check at the end of the implementation batch when
needed. Repeat only checks affected by an actual failure or subsequent change.
Do not rerun the full Core suite merely because a fixture, script, layout or
native-only setting changed. CI runs the complete integration suite.

Reuse native receiver compilation caches. A cache must include app sources,
receiver sources, imported framework binary/modules, architecture, flags and
compiler version. Do not remove behavioral assertions to shorten tests.

## Native verification ownership

Use private repositories, preferences and pasteboards and injected responses
where available. Close every test-owned window and terminate/wait for owned
helper processes on success, failure and timeout. Keep at most the app instances
needed for the current check. Do not terminate unrelated user-owned apps. Keep
automated receiver windows invisible or offscreen, including sheets and child
windows, so checks do not interrupt the user’s desktop. Use visible windows only
for a deliberate physical/visual acceptance check, then close them immediately.

Record the actual validation scope and failures. A local focused pass does not
prove a complete hosted CI pass, physical Finder integration, signed deployment,
or visual parity of every upstream dialog.

## Dialog audit coverage

After changing parity documentation, source control mappings or dialog review
references, run `python3 scripts/reconcile-dialog-coverage.py` before committing.
The generated ledger covers every pinned resource/id pair and separates partial
family audits from unmapped controls. Do not describe its counts as a feature
completion percentage or mark a dialog complete from a file/class existing.

## macOS command composition

Keep each SwiftUI CommandsBuilder body below ten children, including Debug-only
commands. The hosted SDK currently has that limit even when the newer local SDK
accepts a larger body. Add commands within cohesive App/editor/repository providers
rather than growing the Scene builder to its limit. Preserve provider placement,
relative order, shortcuts and observed model bindings when regrouping commands.


## Native translation resources

The Xcode app compiles Localizable.xcstrings from pinned TortoiseGit PO labels.
After changing literal native UI labels, run `python3 scripts/build-localizations.py
--write` before the batch build, then `--check` before committing. Preserve English
fallback for missing/fuzzy/ambiguous/formatted/plural entries; never translate Git
arguments, references, paths, user text or arbitrary server diagnostics. CommandLabel
uses localized captions by default; pass localized: false for user-derived titles.
Keep the generated locale IDs, manifest and translator notices together. Do not
claim complete localization from label-resource counts. The SwiftPM executable is
an unbundled development entry point; localized distribution uses the Xcode app.

## Bundled Mac Help

After changing a guide included by `docs/help-topics.json`, regenerate the tracked
help book with `scripts/build-help.py` after documentation freezes and before the
batch app build. Run `scripts/build-help.py --check` before committing. Use the
site Python environment when the system Python lacks the renderer dependency.
Keep the generated HTML, Info.plist and help manifest together; the Pages workflow
checks them before rendering the website.
