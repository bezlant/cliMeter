# Task 4 Report: Expose the Source and Honest Status in SwiftUI

## Status

Implemented Task 4 in the isolated `claude-statusline-usage` worktree from base
commit `580be284e4b6407d869a289039df5cdcb70bedcc`.

Settings now exposes the password-free status-line source as the default-facing
choice and identifies manual Keychain access as compatibility mode. The popover
and menu-bar stale treatment use the selected source, and file validation
errors remain visible alongside the last good usage snapshot. When a retained
snapshot is old, the validation error takes precedence over generic stale and
Claude Code waiting treatments.

## Hypothesis and evidence

### Hypothesis

Stale policy belongs in `ClaudeStalePresentation`, with `ClaudeUsageSource` as
the primary input and `Profile.credentialSource` retained only for manual
Keychain compatibility. Passing the selected source to the menu bar and each
`ProfileCard` would keep presentation consistent without changing provider
lifecycle or profile attribution.

### Evidence and challenge

- `ProfileManager` already publishes `claudeUsageSource` and routes one selected
  profile's file snapshot into `allUsageData`, `allErrors`, `allLastSuccess`,
  and `allStale`.
- `ClaudeStatusLineUsageStore` retains `usageData` after future-schema or
  malformed updates while publishing the corresponding `errorMessage`.
- The existing presentation helper considered only `CredentialSource`, so a
  status-line profile left as `.selfOwned` could suppress waiting semantics.
- Missing-file and partial-window states publish an error without usage, while
  future-schema and malformed states can publish both. A single card layout can
  therefore cover initialization and retained-data errors.
- Manual-Keychain rate-limit behavior was treated as a counterexample during
  self-review. The new "error plus usage" row is limited to status-line mode so
  compatibility mode keeps its prior presentation.
- Review then exposed a conflict within the status-line card: header stale age,
  footer waiting text, and validation error were derived independently. A stale
  retained snapshot therefore satisfied all three branches and displayed
  contradictory remediation.

The evidence supported implementing at the existing presentation seam; no
provider, credential, or persistence change was needed.

## Strict TDD evidence

### Baseline

Before edits:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result: 100/100 tests passed, zero failures.

### RED

Presentation tests were added before production changes for:

- status-line waiting semantics with a `.selfOwned` profile;
- preserved non-waiting behavior for manual `.selfOwned` profiles;
- retained Session and Week rows plus both future-schema and malformed-file
  messages.

The existing stale and rendered-card tests were updated to declare their usage
source.

Command:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClimeterTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 65. Compilation failed for the expected missing Task 4 interface:
`extra argument 'usageSource' in call` for `ClaudeStalePresentation` and
`ProfileCard`.

### GREEN

The same focused command passed 10/10 tests after the implementation. The
rendered-card test uses Vision OCR against the real SwiftUI card and verifies
that Session, Week, and every error-message token are present for both
validation errors.

### Review-fix RED/GREEN

The retained-data rendering test was changed first to use an export timestamp
601 seconds old with `isStale == true` for both validation messages. The focused
suite then failed four assertions: both fixtures rendered both forbidden
“waiting” and “stale” wording.

An ordered presentation contract was added next. Before production code, the
focused build failed to compile because `ClaudeProfileCardPresentation` did not
exist. The desired state was explicit:

```swift
staleAge == nil
rows == [.usage, .error(exactValidationMessage)]
```

After extracting that presentation model and rendering the card from its
ordered rows, the focused suite passed 11/11. The deterministic model test
proves ordering and exclusivity for both validation messages; the Vision OCR
integration test proves the real card retains Session, Week, and the exact
error while omitting generic “waiting” and “stale” text.

## Implementation

### Settings

- Replaced the fixed Keychain credential label with a native menu `Picker`.
- Identified `Claude Code status line — password-free` and
  `macOS Keychain — may ask for password` directly in the choices.
- Shows the no-OAuth status-line caption or the orange Keychain password-prompt
  warning according to selection.
- Disables the auto-switch toggle and threshold controls in status-line mode
  and explains that they require Keychain compatibility mode.

### Popover and menu bar

- Passed `claudeUsageSource` from `ProfileManager` through `PopoverView` to
  every `ProfileCard`.
- Passed the same source into the menu-bar stale calculation.
- Status-line mode now uses the existing ten-minute waiting semantics
  regardless of profile credential provenance.
- Manual Keychain `.selfOwned` profiles preserve their existing non-waiting
  behavior.
- `ClaudeProfileCardPresentation` derives header stale age and ordered body rows
  together. Status-line validation messages produce `[usage, error]`, so they
  render beneath retained usage while suppressing stale/waiting treatments.
- The existing no-data error, loading, ordinary waiting, and manual-Keychain
  rate-limit layouts remain represented by the same ordered model.
- Applied monospaced digits to the dynamic stale age/status text touched by the
  change, avoiding width jitter without adding animation or redesign.

## UI before/after

| Before | After |
| --- | --- |
| Claude settings showed a fixed Keychain credential label. | A native menu picker exposes the password-free status line and explicit Keychain compatibility choice. |
| No source-specific safety explanation. | Status-line mode says no OAuth credential is read; compatibility mode warns that macOS may prompt for a password. |
| Auto-switch remained editable even though status-line data cannot attribute accounts. | Auto-switch and its threshold are disabled in file mode with “Requires Keychain compatibility mode.” |
| Stale presentation depended only on profile credential provenance. | File mode always uses ten-minute Claude Code waiting semantics; manual `.selfOwned` behavior is unchanged. |
| A last-good snapshot hid future-schema or malformed-file errors. | Session and Week remain visible and the validation message appears below them. |
| A stale retained snapshot showed the validation error plus header “stale” and footer “waiting for Claude Code.” | The exact validation error is the sole status/remediation message; Session and Week remain above it. |
| Dynamic stale age text used proportional digits. | Touched stale age/status text uses monospaced digits for stable width. |

## Verification

### Focused presentation suite

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClimeterTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: 11/11 passed, zero failures, skips, or expected failures.

### Full suite

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result: 104/104 passed, zero failures, skips, or expected failures.

The counts were confirmed with `xcresulttool get test-results summary`.

### Static inspection

- `git diff --check`: clean.
- The compiler invocation targets `arm64-apple-macos14.0`.
- All `ClaudeStalePresentation` and `ProfileCard` call sites pass
  `usageSource`.
- The diff is limited to `SettingsView.swift`, `PopoverView.swift`,
  `ClimeterApp.swift`, `ClimeterTests.swift`, and this report.
- No exporter, file schema, file permission, `ProfileManager`, credential,
  Codex, or project-setting file changed.
- Xcode emits its existing multiple-destination notice. A focused rebuild also
  emitted the existing skipped App Intents metadata warning; there were no test
  failures or source diagnostics.

## Constraint audit

- macOS 14.0 deployment target: unchanged; build invocation verified.
- `statusLineFile` default: unchanged and presented as the password-free choice.
- Zero automatic Keychain reads and no fallback: provider routing is unchanged;
  the full suite includes the 12 status-line lifecycle tests.
- Exported allowlist and permissions: unchanged.
- Codex behavior: no Codex code changed; full suite passed.
- One selected profile receives the snapshot: profile selection/routing is
  unchanged.
- Native macOS semantics: uses SwiftUI `Picker`, `Toggle`, `Slider`, native
  disabled state, existing Form typography, and caption colors.
- No decorative animation or unrelated redesign was added.

## Deviations and concerns

- The brief's two new stale tests were supplemented with one rendered-card
  behavior test covering both future-schema and malformed-file messages. This
  directly protects the requested retained-data error placement.
- The error-plus-usage presentation is deliberately source-scoped instead of
  applying to manual Keychain profiles, preserving compatibility behavior.
- Validation precedence intentionally matches the two exact messages published
  by `ClaudeStatusLineUsageStore`; other status-line errors retain their prior
  waiting behavior.
- Settings picker wording and disabled modifiers were compiled and statically
  inspected; there is no UI automation dependency in this project to exercise
  picker interaction end to end.
- No known blocker remains.
