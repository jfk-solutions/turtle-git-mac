# TurtleGit for Mac development

## Implementation batches

The user wants substantial porting batches followed by grouped validation.
Implement a complete related dialog/workflow family, including its model, Git
operations, native controls, source icons, persistence and documentation, before
running its tests. Compare behavior and layout with the pinned TortoiseGit source
and resources; retain an explicit list of missing behavior. Do not declare the
whole port complete from implemented screens alone.

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
needed for the current check. Do not terminate unrelated user-owned apps.

Record the actual validation scope and failures. A local focused pass does not
prove a complete hosted CI pass, physical Finder integration, signed deployment,
or visual parity of every upstream dialog.

## Dialog audit coverage

After changing parity documentation, source control mappings or dialog review
references, run `python3 scripts/reconcile-dialog-coverage.py` before committing.
The generated ledger covers every pinned resource/id pair and separates partial
family audits from unmapped controls. Do not describe its counts as a feature
completion percentage or mark a dialog complete from a file/class existing.
