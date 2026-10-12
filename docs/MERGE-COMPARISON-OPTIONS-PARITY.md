# Merge comparison options

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`. Reviewed
DiffData.cpp options, MainFrm.cpp comparison handlers, SetMainPage.cpp defaults,
FileTextLines.cpp conversion ordering and Subversion's normalize_buffer.

Both native comparison windows provide Compare whitespaces, Ignore whitespace
changes, Ignore all whitespace changes, Ignore line endings and Ignore case
changes. Merge Editor settings exposes the same defaults through its existing
Apply/Cancel transaction. Source defaults are compare whitespace, case-sensitive,
and IgnoreEOL=true. Low-level engine APIs retain an explicit exact mode for
callers that need byte/EOL-sensitive comparison.

The three whitespace choices preserve whitespace, collapse runs of ASCII
space/tab/VT/FF, or remove them. A run is distinct from absent whitespace in
Ignore changes mode. Non-ASCII spaces are retained. Regex replacement happens
before whitespace/case normalization. Line-ending comparison normalizes each
recognized ending to LF when requested, retaining the distinction between an
ended final line and no final newline. Case uses macOS Unicode lowercase with
the POSIX locale, not full case folding. Windows locale/Unicode edge equivalence
remains unverified.

Comparison keys are separate from original text and encoding metadata. Filtered
rows retain original bytes, numbers and the green palette. Block transfers use
original source content and existing target-ending normalization. Two-pane
changes recompute current drafts with debounce, cancellation and selection/mark
remapping. Three-pane changes use dirty Save/discard/Cancel before regeneration;
Cancel or an engine failure retains the prior option/result. Preferences are
saved only after successful three-pane regeneration. Saved settings become the
defaults for subsequent explicit Reload and new windows.

Remaining: comment-language profiles/lexer, full source Unicode locale behavior,
source whitespace-difference visibility categories, all ending/regex edge cases,
physical menu/settings interaction, complete visual captures, signed helper and
App Store acceptance. This advances the complete port without certifying all
TortoiseGitMerge comparison or settings behavior.

Grouped evidence: 28 Core tests passed, the unsigned Debug build completed with
existing diagnostics, and both native receivers passed together in one frontend
compilation/process. They verify Cancel versus successful persistence, option
choices and the existing native editing/save/cancellation paths. Settings controls
compiled; their physical Apply/Cancel interaction remains unverified. All owned
windows/helpers exited. See `qa/comparison-options-2026-10-12.json`.
