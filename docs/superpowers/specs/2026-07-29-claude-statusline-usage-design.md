# Claude Status-Line Usage Source

**Date:** 2026-07-29
**Status:** Approved direction; revised after independent written-spec review
**Scope:** Replace Climeter's automatic reads of Claude Code's macOS Keychain item with a credential-free status-line file on this installation.

## Problem

Climeter repeatedly asks macOS for the secret stored in
`Claude Code-credentials`. Claude Code periodically updates that item and resets
its access-control partition list. Climeter then loses its previous authorization
and macOS asks for the login-keychain password again.

The prompts multiply because Climeter has independent credential reads during
launch, delayed account detection, usage refresh, wake/unlock, 401 recovery, and
manual refresh. On this machine, the file log recorded four reads during a single
launch, including three within the same 20 ms interval.

The previous file mode avoided prompts by copying Claude's OAuth credential to
`~/.claude/.credentials.json`. It was removed because the copy became stale and
Climeter consumed the same rotating refresh token that Claude Code owned. This
could force Claude Code to log in again.

Claude Code now supplies the exact non-secret data Climeter displays through its
supported status-line JSON:

- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`

## Goals

- Produce no automatic password or Keychain-access prompts.
- Never read, copy, persist, refresh, or mutate Claude Code-owned OAuth
  credentials.
- Update Climeter after each Claude Code response that includes rate-limit data.
- Continue showing the last known values when Claude Code is closed or idle.
- Preserve the existing five-hour, seven-day, reset-time, and stale-state UI.
- Leave Codex credential and usage behavior unchanged.

## Non-Goals

- Poll Claude usage while Claude Code is closed.
- Reflect usage from another computer before this Mac runs a Claude request.
- Restore Climeter-managed OAuth refresh or the old credential-file mode.
- Add automatic installation for every possible third-party status-line tool.
- Solve multi-account attribution in the first file-source version.

## Decisions

### 1. Claude usage comes from a sanitized status-line file

The existing status-line command at
`~/.config/claude/statusline-simple.sh` already reads Claude Code's JSON from
standard input. It will additionally export a strict whitelist of rate-limit
fields to:

```text
~/Library/Application Support/Climeter/claude-usage.json
```

The exporter must never write the complete status-line input. The input can
contain project paths, transcript paths, repository information, and other data
Climeter does not need.

File schema:

```json
{
  "schema_version": 1,
  "updated_at": 1785290000,
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "resets_at": 1785300000
    },
    "seven_day": {
      "used_percentage": 41.2,
      "resets_at": 1785800000
    }
  }
}
```

`updated_at` and both `resets_at` values are Unix epoch seconds. Reset values may
be absent or null because `UsageWindow.resetsAt` is already optional. Each
window may be independently absent because Claude Code documents that behavior.
The exporter merges present windows with the last valid aggregate. Climeter
publishes `UsageData` only after both windows have been observed at least once.

### 2. Writes are atomic and owner-readable only

Before writing, the exporter creates the destination directory with mode `0700`
and creates or tightens the persistent lock file to mode `0600`. All writers
then enter one short critical section using macOS
`/usr/bin/lockf -k -t 1`; `-k` keeps every writer on the same persistent inode.
If the lock cannot be obtained, that invocation skips the export rather than
delaying or breaking the visible status line.

The script reads standard input once before locking so its existing visible
output does not depend on the export succeeding. Inside the lock, the exporter:

1. Builds only the whitelisted schema with `jq`.
2. Merges independently present windows with the existing valid aggregate,
   publishing a valid partial file until both windows have been observed.
3. Rejects a candidate window whose non-null `resets_at` is older than the
   stored window; for equal reset times, keeps the higher percentage.
   When either reset time is unknown, it retains a known stored reset and uses
   the higher percentage.
4. Preserves `updated_at` when the merged `rate_limits` object is semantically
   unchanged and stamps the current time only when at least one rate-limit
   value changes.
5. Uses `mktemp` to create a unique file in the destination directory and
   registers a cleanup trap.
6. Sets mode `0600`.
7. Atomically renames the temporary file over `claude-usage.json`.

The lock serializes concurrent Claude Code sessions; atomic rename protects
Climeter readers. A delayed render from a session with older reset data cannot
replace a newer window. If reset times are equal, usage is treated as monotonic
within that window. This may temporarily preserve a slightly high percentage if
Claude later reconciles usage downward, but it prevents an idle session from
making usage regress and appear fresh.

Status-line commands also run for UI-only changes such as permission or Vim mode.
Those renders carry the prior `rate_limits`; preserving `updated_at` prevents
them from resetting Climeter's stale clock. This is intentionally conservative:
a new Claude response with byte-for-byte identical rate limits does not advance
freshness, so Climeter may show a stale treatment even though the unchanged
values were recently confirmed. It never labels old values newly fresh.

If the input has no rate-limit window, the exporter leaves the last good file
untouched. Export failure must not prevent the existing status line from
rendering.

### 3. Climeter polls the file, not the Keychain

Add a focused `ClaudeStatusLineUsageStore` that:

- Locates the file under Application Support.
- Decodes schema version 1.
- Validates finite percentages in the inclusive range `0...100`.
- Converts reset epochs into `Date`.
- Maps directly into the existing `UsageData`.
- Returns the file's `updated_at` as `lastSuccessAt`.

A lightweight timer checks the file every one second. Polling is deliberately
used instead of a file-descriptor watcher because atomic rename replaces the
inode and would require watcher re-registration.

The store remembers the last successfully decoded value in memory. A missing,
partial, or malformed replacement does not erase valid on-screen data.

### 4. Status-line mode is the default Claude source

Introduce a persisted Claude usage-source setting with:

- `statusLineFile` — default and recommended.
- `keychainManual` — optional compatibility fallback, never accessed
  automatically.

In `statusLineFile` mode:

- `ProfileManager` does not call `ClaudeCodeSyncService.keychainItemExists()`.
- It does not start CLI credential monitoring.
- It does not create read-only coordinators backed by a Keychain reader.
- Wake/unlock only resumes file observation.
- The refresh button immediately rereads the file.
- No migration, launch, timer, 401, or account-detection path reads
  `Claude Code-credentials`.
- Automatic session-start requests and account auto-switching are unavailable
  because both require an OAuth credential or reliable account attribution.

The existing Keychain code can remain temporarily for explicit compatibility
mode, but switching to that mode must explain that the user may receive a macOS
prompt. Automatic fallback from file mode to Keychain is forbidden.

`ProfileManager` receives a `ProfileManagerDependencies` value. Its live value
provides separate status-line and manual-Keychain provider factories plus
closures for every Claude Keychain operation. Tests replace those closures with
fail-fast spies. Source routing is centralized: the status-line branch never
constructs the manual provider and therefore has no incidental Keychain reader
available to launch, wake, refresh, or polling code.

The existing read-only migration is split:

- Pure profile-schema/default migrations still run. Status-line mode does not
  call the current `readOnlyMigrationCredential` path, which reads Climeter's
  legacy secret stores to derive account metadata before purging them.
- Status-line mode never performs the current `keychainItemExists()` probe.
- It never automatically reads, moves, or deletes
  `~/.claude/.credentials.json`. The app cannot prove that file belongs to an
  old Climeter version without inspecting protected credential state, and the
  attempted existence probes on this machine did not establish a prompt-free
  path.

Any future credential-file cleanup requires a separate, explicit user action.
The already-persisted migration flags are retained but do not authorize
automatic Keychain access. Stale presentation is keyed to the selected Claude
usage source instead of `Profile.credentialSource`, so skipping the
credential-derived migration does not suppress the waiting state.

### 5. First-run and stale behavior

When no usage file exists, Climeter shows:

> Open Claude Code and send one prompt to initialize usage.

Status-line mode chooses the persisted CLI-active profile when it is valid;
otherwise it chooses the first/default profile and persists that ID as
`cliActiveProfileID`. While this source is enabled, the chosen ID is included in
the in-memory `authenticatedProfileIDs` set used by `authenticatedProfiles`,
even before the first file appears. Here that existing collection represents
display availability, not proof of authentication; no authenticated-secret
marker is persisted. This makes the missing-file instruction reachable on a
fresh install. The ID is removed from the source-derived portion of the set only
when Claude is disabled or the source changes, not when the file later becomes
stale or malformed, so the last good values remain visible.

Every `refreshAuthenticatedIDs()` recomputation unions this source-derived ID
after loading credential and marker state, including launch and wake paths, so a
refresh cannot accidentally close the display gate.

The menu-bar label, popover profile list, and refresh button all use that same
chosen profile. A first launch with empty `UserDefaults` and a valid file must
therefore render usage instead of `—` or the `/login` instruction.

The existing ten-minute stale threshold remains. Because `lastSuccessAt` comes
from `updated_at`, reading an old file at app launch does not incorrectly mark it
fresh.

When Claude Code is closed or idle, Climeter keeps the previous values and shows
the existing “waiting for Claude Code” stale treatment.

### 6. Account handling

Status-line JSON contains rate limits but no stable account UUID. The first
version applies each update to the currently selected/default Claude profile.
This is correct for the one-profile configuration currently present on this
machine.

Multi-account attribution is deferred. The UI must not claim it detected an
account switch from status-line data. Existing extra profiles retain their last
known values and may be selected manually. Account auto-switch controls are
disabled with an explanation in status-line mode; they remain available in
explicit manual-Keychain compatibility mode.

## Components

### Status-line exporter

Modify the existing local script without changing its current visible output.
The export block is independent from `claude-limitline`; it reads
`.rate_limits` directly from the already-captured JSON.

### `ClaudeStatusLineUsageStore`

A new deep module owns file location, decoding, per-window merging, validation,
mapping, and file freshness. Callers receive either one validated usage snapshot
or a typed absence/error; they do not parse JSON themselves.

### `ProfileManager`

Selects the Claude source, starts/stops file observation, establishes the
file-backed profile display gates, publishes snapshots into the existing profile
dictionaries, and guarantees zero automatic Keychain reads in status-line mode.
The injected dependency boundary makes that guarantee behavior-testable.

### Settings and popover

Settings identifies the source as:

> Claude Code status line — password-free

Compatibility mode is explicit. The popover reuses current usage rows and stale
presentation, with only the missing-file instruction added.

## Error Handling

- File missing: show initialization instruction; do not access Keychain.
- Rate limits absent: keep the last good file and UI value.
- Only one window seen: merge it with the previous window. Before the first
  complete aggregate, show “Claude supplied partial usage; waiting for both
  windows” rather than the generic closed/idle state.
- Unsupported schema version: keep the last good UI value and show “Climeter
  usage exporter needs an update.”
- Other invalid schema or values: keep last good UI value and log only the
  validation category, never the file contents.
- File read races: atomic rename prevents partial reads; retry on the next
  one-second tick.
- Exporter dependency missing (`jq`): preserve the existing status-line display
  and leave the prior usage file untouched.
- Explicit compatibility mode denied by macOS: show an actionable error; do not
  retry automatically.

## Security

- No access token, refresh token, session cookie, transcript, prompt, project
  path, or account identifier is written.
- The export is a strict allowlist, not a blacklist.
- The destination directory is mode `0700`; the usage and lock files are mode
  `0600`.
- Logs contain status and timestamps only.
- Climeter never shells out to `security`.
- Climeter never refreshes or mutates Claude Code credentials.

## Testing

### Exporter behavior

- Feed a fixture containing rate limits plus fake credential/path fields; assert
  the file contains only the documented schema.
- Assert mode `0600`.
- Start without the destination directory and assert it is created with mode
  `0700`.
- Run concurrent exporters and assert output remains valid, unique temporary
  files do not collide, older reset data cannot replace newer data, and no
  temporary files remain.
- Assert a UI-only rerender with unchanged rate limits preserves `updated_at`.
- Assert independently missing windows merge with prior values; when no prior
  value exists, assert the partial-window state is distinguishable.
- Assert the existing human-readable status-line output is unchanged.

### Store behavior

- Decode valid percentages and reset epochs into `UsageData`.
- Accept null/missing reset times.
- Accept independently missing windows as partial input.
- Reject non-numeric values, NaN/infinity, and percentages outside `0...100`.
- Preserve the last good snapshot after a malformed update.
- Use `updated_at`, not read time, for `lastSuccessAt`.
- Distinguish a future schema version from a missing or stale file.

### Integration boundaries

- Launch in `statusLineFile` mode with a valid file and assert usage appears.
- Repeat that launch with empty `UserDefaults`; assert the default profile
  becomes display-available, `cliActiveProfileID` is set, the menu-bar label is
  not `—`, and the popover does not request `/login`.
- Launch without a file and assert the initialization instruction appears.
- Update the file atomically and assert the new values appear within five
  seconds.
- Let the file age beyond ten minutes and assert stale presentation.
- Trigger launch, wake, periodic observation, and manual refresh while injecting
  a Keychain reader that fails the test if called; assert zero calls.
- Assert pure profile-schema/default migration still runs in status-line mode
  while the legacy credential reader, Keychain existence, and credential-file
  migration closures receive zero calls.
- Assert auto-start and account auto-switching are disabled in status-line mode.
- Verify Codex tests and existing UI behavior remain green.

## Rollout

1. Ship status-line mode as the default.
2. Update this machine's existing status-line script during local installation.
3. Keep explicit manual Keychain compatibility for rollback.
4. After field verification, consider a separate design for safely installing a
   status-line wrapper on machines with unknown existing commands.

## Success Criteria

- A Claude response updates Climeter within five seconds.
- Closing Claude leaves the last result visible and later marks it stale.
- Repeated launch, wake, refresh, and day-long observation produce zero automatic
  reads of `Claude Code-credentials`.
- The exported file contains no credential or unrelated status-line fields.
- Claude Code login and token refresh behavior are untouched.
