# Task 3 Report: Route ProfileManager Away From Keychain by Default

## Status

Implemented Task 3 in the isolated `claude-statusline-usage` worktree from base
commit `76a04059ed474d8aa534715ba20335a2c17fdc27`.

The default Claude usage source is now the sanitized status-line file. The
legacy Keychain/coordinator path is retained behind explicit
`keychainManual` selection.

The subsequent review findings were reproduced and resolved: provider work is
now cancellable and generation-gated, injected managers route all
`UserDefaults` state through their injected store, and the disabled Claude
state closes the status-line authentication gate.

## Hypothesis and evidence

### Hypothesis

`ProfileManager` coupled initialization, migration, refresh, delayed CLI
detection, wake/unlock, enable toggles, and coordinator setup directly to
Claude credential access. A persisted source enum plus an injected dependency
boundary and source-specific provider lifecycle would allow the default file
mode to avoid every credential closure without changing explicit compatibility
mode.

### Direct evidence

Before implementation, `ProfileManager`:

- ran credential migration on every initialization;
- called `ClaudeCodeSyncService.keychainItemExists()` directly;
- called `ClaudeCodeSyncService.readCLICredential(interactive:)` directly from
  both coordinator and delayed account-detection paths;
- created `UsageRefreshCoordinator` instances and started account backfill and
  CLI monitoring whenever Claude was enabled;
- restarted those credential paths after wake/unlock and forced Keychain reads
  on manual refresh.

The focused RED build failed because the desired source enum, persistence API,
dependency boundary, injectable initializer, and power-monitor protocol did not
exist.

## Strict TDD evidence

### RED

Tests were added before production changes:

- default and persisted source;
- zero credential dependency calls across launch, polling, refresh,
  sleep/wake/unlock, enable toggles, and delayed detection;
- selected/default profile authentication and display gates;
- status-line publication into all four ProfileManager dictionaries;
- valid persisted profile selection and authentication recomputation;
- store stop/restart behavior across Claude enable toggles;
- explicit Keychain compatibility selection and file-provider teardown.

Command:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ProfileManagerStatusLineSourceTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 65. Compilation failed for the expected missing Task 3 interfaces,
including `ProfileManagerDependencies`, `PowerStateMonitoring`,
`ProfileStore.loadClaudeUsageSource`, `ProfileStore.saveClaudeUsageSource`, and
the injectable `ProfileManager` initializer.

RED log: `/tmp/climeter-task3-red.log`.

### GREEN

The same focused suite passed all 6 tests after the minimal routing
implementation.

### Review-fix RED/GREEN cycles

The review identified four concrete gaps. Each was covered before its
production fix:

- Injected-defaults isolation and disabled-authentication tests first failed to
  compile because `ProfileStore` did not accept an injected `UserDefaults` for
  all relevant operations. RED log:
  `/tmp/climeter-task3-review-defaults-red.log`.
- After routing those APIs and the manager call sites, the expanded focused
  suite passed 9/9. GREEN log:
  `/tmp/climeter-task3-review-defaults-green.log`.
- Deterministic stale-provider tests then failed to compile because delayed CLI
  detection and credential work were not injectable or cancellable. RED log:
  `/tmp/climeter-task3-review-generation-red.log`.
- The first generation implementation exposed an additional behavioral defect:
  initialization scheduled three Keychain detections instead of one because
  property observers started providers before the explicit initialization
  start. The focused run passed 9/11 and recorded the failing assertions before
  the initialization guard was added.
- The final focused suite passed 11/11, including deliberate execution of a
  cancelled old-generation operation. GREEN log:
  `/tmp/climeter-task3-review-generation-green.log`.

## Implementation

### Source and dependency boundary

- Added `ClaudeUsageSource` with `statusLineFile` and `keychainManual`.
- Added `ProfileManagerDependencies` for CLI credential reads, Keychain item
  existence, migration credential reads, legacy file moves, status-line store
  construction, power monitoring, cancellable delayed detection, and
  cancellable credential work.
- Added source load/save methods to `ProfileStore`, using injectable
  `UserDefaults` and defaulting missing or invalid values to `statusLineFile`.
- Routed every `UserDefaults`-backed `ProfileStore` operation used by an
  injected `ProfileManager` through that manager's injected defaults. Live
  callers retain `.standard` via default arguments.
- Added `PowerStateMonitoring` and made the live monitor conform.

### ProfileManager routing

- Loads the source before any credential migration.
- Skips credential migration entirely in status-line mode; profile decoding and
  default-profile creation remain the pure schema/default migration path.
- Selects a valid persisted Claude profile or the first profile and persists
  that ID.
- Recomputes status-line authentication without credential reads, clears
  cached credentials, and unions the selected profile into the authenticated
  set.
- Subscribes the status-line store to `allUsageData`, `allErrors`,
  `allLastSuccess`, and `allStale`.
- Routes start, stop, refresh, sleep, wake, unlock, enable toggles, selected
  profile changes, and source switching to the active provider.
- Defensively gates coordinator creation, CLI detection, account backfill,
  session auto-start, and auto-switch logic to `keychainManual`.
- Routes legacy migration and CLI credential reads exclusively through the
  injected closures.
- Cancels tasks, timers, subscriptions, and coordinators when changing
  providers.
- Tracks delayed detection and credential work cancellation handles and a
  lock-protected monotonically increasing provider generation. The generation
  is checked immediately before a credential dependency read and again on the
  main queue immediately before processing its result.
- Keeps Claude source/enabled reads for provider dispatch on the main queue;
  background credential work observes only the thread-safe generation token.
- Suppresses Claude source/enabled property-observer side effects during
  initialization so the provider starts exactly once.
- Closes and reopens status-line authentication/display gates when Claude is
  disabled and re-enabled, including persisted-disabled launches.

### Compatibility and Codex behavior

- `keychainManual` uses the existing migration, coordinator, CLI monitoring,
  backfill, and wake/unlock flows with live closures equivalent to the previous
  direct calls.
- A self-review found and removed an unnecessary compatibility-mode behavior
  change in `activateForCLI`; its previous behavior remains intact.
- Codex coordinator setup, enable behavior, refresh behavior, and unlock/delayed
  resume gate were not changed. Status-line file polling may resume immediately
  on wake, while Codex retains its prior unlock/delayed resume timing.

## Verification

### Selected suites

Command:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ProfileManagerStatusLineSourceTests \
  -only-testing:ClimeterTests/ProfileManagerMigrationTests \
  -only-testing:ClimeterTests/UsageRefreshCoordinatorReadOnlyTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: 34/34 tests passed, zero failures.

- `ProfileManagerStatusLineSourceTests`: 11/11
- `ProfileManagerMigrationTests`: 8/8
- `UsageRefreshCoordinatorReadOnlyTests`: 15/15

Selected-suite log: `/tmp/climeter-task3-review-selected.log`.

### Full suite

Command:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Result: 99/99 tests passed, zero failures.

Full-suite log: `/tmp/climeter-task3-review-full.log`.

### Static inspection

- `git diff --check`: clean.
- All four project deployment-target entries remain `14.0`.
- The final build/test log contains no compiler warnings.
- Status-line source tests remove only their unique suite domain; an isolation
  test proves injected manager operations leave sentinel standard preferences
  unchanged.
- Every `UserDefaults`-backed `ProfileStore` call in the injected
  `ProfileManager` passes its injected defaults; credential-store operations
  remain unchanged.
- The only direct `ClaudeCodeSyncService` accesses in Task 3 production changes
  are inside `ProfileManagerDependencies.live`; status-line mode never invokes
  those closures.
- No automatic file-to-Keychain fallback exists.
- Task 3 does not change the exporter schema or filesystem permissions from
  Tasks 1 and 2.

## Constraint audit

- macOS deployment target remains 14.0: verified.
- `statusLineFile` default: implemented and tested.
- Zero `Claude Code-credentials` reads in status-line lifecycle: implemented
  through routing and dependency-counter test covering init, timer, refresh,
  wake/unlock, delayed detection window, recomputation, and toggles.
- Stale provider work: deterministic tests cover
  `keychainManual -> statusLineFile` and rapid
  `keychainManual -> statusLineFile -> keychainManual` transitions; cancelled
  old generations cannot enqueue or perform a credential read.
- Disabled authentication gate: tested at persisted-disabled launch and across
  disable/re-enable transitions.
- No automatic fallback: verified by code inspection.
- Export schema allowlist and file permissions: unchanged from prior tasks.
- Codex behavior: existing full suite passes; source routing does not enter
  Codex credential or refresh code.
- Multi-account attribution: not added; one selected profile receives the
  snapshot.
- Keychain compatibility: explicit opt-in, with prior migration/coordinator
  tests passing.

## Deviations and concerns

- The brief's sample was expanded from four to six tests so lifecycle stop/start
  and valid persisted-profile selection are independently observable.
- A cross-review process was launched because the change affects credential and
  migration routing, but it exceeded the handoff window and was stopped without
  emitting findings; its result file reported only `Execution error` and its
  stderr was empty. A later independent review produced the four concrete
  findings documented above; all four were reproduced and fixed with focused
  tests.
- No known implementation blocker remains.
