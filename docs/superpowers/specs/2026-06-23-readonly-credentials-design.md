# Climeter Read-Only Credential Design

**Date:** 2026-06-23
**Status:** Draft (pending cross-review)
**Author:** bezlant (+ Claude)

## Problem

Climeter has been **breaking Claude Code's login** (forcing `/login` ~daily) and
**failing to show Claude usage**. Both are one root cause.

### Root cause (proven)

Claude Code and Climeter share **one OAuth credential**. The refresh token is
**single-use / rotating** — confirmed by Claude Code v2.1.170 binary strings
(`[gateway-refresh] IdP rejected refresh token; clearing it`, `invalid_grant`,
`auth changed mid-refresh`) and by Anthropic returning
`{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}`.

Climeter currently:
1. Performs its **own** OAuth refresh (`ClaudeAPIService.refreshToken`), consuming
   and rotating the shared refresh token.
2. In file-mode, writes the rotated token **only** to `~/.claude/.credentials.json`,
   never back to the Keychain.
3. Reads that file **first** (`readCLICredentialFromFile`), so it never picks up
   Claude Code's fresh Keychain credential.

Result:
- Climeter rotates the token → Claude Code's Keychain copy dies → next time
  Claude Code's ~8h access token expires it can't refresh → **forced `/login`**.
- After re-login, Claude Code writes a fresh token to the **Keychain**, but Climeter
  keeps reading its stale **file** → refresh fails with `invalid_grant` → **no usage**,
  and it never self-heals.

### Why file-mode cannot work (architectural, not config)

- On macOS, **Claude Code's Keychain is always primary**; the file
  `~/.claude/.credentials.json` is only a fallback read when the Keychain is
  unavailable (locked / headless / Linux).
- There is **no setting or env var** to force Claude Code to file-only on macOS
  (verified against the v2.1.170 binary).
- Climeter's `fileBasedCredentialStorage` toggle only controls where *Climeter*
  reads/writes — it has no effect on Claude Code.

Therefore Climeter's file was never a shared store; it was a private copy that goes
stale the instant Claude Code rotates the token.

### Evidence (this machine, 2026-06-22)

| | Keychain | `~/.claude/.credentials.json` |
|---|---|---|
| `expiresAt` | fresh (next day) | ~29h stale |
| refresh token | current | different / dead |
| last write | Claude Code, today | Climeter, yesterday 16:11 |

Logs: last good Climeter refresh `Jun 21 16:11` (8h token) → first `invalid_grant`
`Jun 22 00:07` (exactly at expiry) → then looping `giving up` every poll.

## Goals

- Climeter never breaks Claude Code's login again.
- Climeter shows Claude usage reliably while Claude Code is in normal use.
- No recurring Keychain password popups.

## Non-Goals

- Keeping the meter live when the token is expired **and** Claude Code is not
  running to refresh it (accepted: show stale).
- Changing Codex credential handling (separate subsystem, untouched).
- Changing manually-added "paste your own session key" profiles, which own
  independent tokens not shared with Claude Code.

## Core Principle

**Climeter observes, never mutates, Claude Code's credential.** The Keychain item
`Claude Code-credentials` is read-only source of truth. Only the **access token**
(short-lived, non-destructive) is ever used. The **refresh token is never consumed.**

## Design

### Credential ownership model

Introduce an explicit distinction between two profile kinds:

- **CLI-synced profile** (the one mirroring Claude Code): **read-only**. Climeter
  never refreshes or writes its credential.
- **Self-owned profile** (manually pasted session key): unchanged — Climeter owns
  the token and may refresh it (independent token, safe to rotate).

This is likely already implied by `cliActiveProfileID`; the design makes it an
explicit, enforced property used to gate refresh/write behavior.

### The three credential stores (and what happens to each)

1. **Claude Code Keychain** (`Claude Code-credentials`) — source of truth for the
   CLI profile. **Read-only.** Read rarely (see below). Never written.
2. **Claude Code file** (`~/.claude/.credentials.json`) — **dropped entirely.**
   Climeter no longer reads, writes, or bootstraps it. (It may *optionally* read it
   only if the Keychain read fails, mirroring Claude Code's own fallback order —
   open question for review.)
3. **Climeter's own profile store** (`KeychainService` under `com.bezlant.climeter`,
   or `FileCredentialStore` in app support) — Climeter always has access here, no
   popups. Used to cache profile data and self-owned credentials. The
   `fileBasedCredentialStorage` toggle, as it applies to **Claude / CLI sync**, is
   removed. (Whether to keep it for Climeter's own store is an open question.)

### Read strategy (CLI profile)

- On launch and when the **cached access token is at/near expiry**, read the
  Keychain once to get Claude Code's current access token + `expiresAt`.
- Cache the access token in memory; reuse it for `fetchUsage` until near expiry
  (~8h). This makes Keychain reads ~3x/day, not every poll.
- `fetchUsage` poll cadence is unchanged (`baseInterval` 180s with backoff); it
  just reuses the cached access token between Keychain reads.

### Expiry handling (CLI profile)

- If the cached access token is expired:
  - Re-read the Keychain.
  - If the Keychain has a **newer, valid** access token (Claude Code refreshed it):
    use it, fetch usage.
  - If the Keychain token is **also expired** (Claude Code not running): **do not
    refresh.** Show last-known usage with a subtle "stale" indicator. Retry next
    cycle.
- The current `recoverCredential` refresh path is **removed** for the CLI profile.

### Account-switch detection

- Remove the 30s Keychain poll (`detectCLIAccountChange` timer) — it was the main
  popup driver.
- Detect switches during the rare Keychain reads (compare account UUID / refresh
  token identity). Optionally use a cheap signal (Keychain item `mdat`, or
  `~/.claude` activity) to decide when to re-read. (Exact cheap signal: open
  question for review.)

### Auto-start

- **Keep as-is.** `startSession` only sends a message when a valid access token
  exists and does not rotate the refresh token, so it is login-safe.

### Popups

- Reading another app's Keychain item triggers a macOS prompt unless Climeter is in
  the item's ACL. The user grants **"Always Allow" once**.
- Because Climeter no longer breaks login, Claude Code stops recreating the Keychain
  item (which reset the ACL), so the grant **persists** → popups effectively stop.
- Climeter never modifies the item's ACL.

## Components Affected

- `ClaudeCodeSyncService.swift` — remove file read/write/bootstrap
  (`readCLICredentialFromFile`, `writeCLICredentialToFile`, `writeRawToCredentialFile`,
  bootstrap branch). Keep `readCLICredentialRaw` (Keychain read). Remove
  `writeCLICredentialToKeychain` use for CLI profile (never write CC's store).
- `UsageRefreshCoordinator.swift` — for read-only profiles, replace
  `recoverCredential` (refresh) with "re-read Keychain; if still expired, show
  stale." Keep refresh path for self-owned profiles.
- `ProfileManager.swift` — remove `fileBasedStorage` for the CLI path; remove the
  30s `detectCLIAccountChange` timer; remove `onCredentialRefreshed` write-back to
  CC's store for the CLI profile; thread the read-only/self-owned distinction.
- `SettingsView.swift` — remove the "Use file-based storage" toggle (or scope it to
  Climeter's own store only — open question).
- `FileCredentialStore.swift` — retain only if Climeter keeps a file-based own-store
  option; otherwise remove.

## Error Handling

- Expired token, Claude Code idle → stale UI state, no error toast.
- Keychain read denied (user declined Always-Allow) → clear actionable message:
  "Allow Keychain access to read Claude usage."
- 401 from `fetchUsage` → re-read Keychain once; if token unchanged, show stale, do
  **not** attempt refresh.
- 429 backoff behavior unchanged.

## Testing

Behavior tests (not mock-restatements):

1. **Never-refresh invariant (CLI profile):** given an expired CLI credential and a
   stubbed API, assert `refreshToken` is **never** called and no write to CC's store
   occurs. (Catches the exact regression.)
2. **Self-heal on Claude Code refresh:** cached token expired; Keychain returns a
   newer valid token; assert usage fetch uses the new token without refresh.
3. **Stale-when-idle:** cached + Keychain both expired; assert last usage retained,
   stale indicator set, no API refresh, no error.
4. **Self-owned profile still refreshes:** assert refresh path intact for pasted-key
   profiles.
5. **Account switch via rare read:** Keychain account UUID changes; assert profile
   switch handled without 30s polling.
6. **File path fully abandoned:** assert Climeter never reads/writes
   `~/.claude/.credentials.json` on the CLI path.

## Migration / Cleanup

- One-time on upgrade: delete the divergent `~/.claude/.credentials.json` **only if
  Climeter created it** (guard to avoid nuking a legitimate Linux-style file). Open
  question: how to safely detect Climeter-authored file.
- Disable/remove the `fileBasedCredentialStorage` default for Claude.
- User cleanup for the currently-broken machine: turn off file mode, remove the file,
  `/login` once.

## Open Questions (for cross-review)

1. Should Climeter read `~/.claude/.credentials.json` as a fallback **only** when the
   Keychain read fails (mirroring Claude Code), or ignore the file entirely?
2. Keep `fileBasedCredentialStorage` for Climeter's **own** profile store, or remove
   the toggle completely?
3. Cheapest reliable signal to trigger a Keychain re-read / detect account switch
   without per-poll Keychain access?
4. Safe way to detect a Climeter-authored `~/.claude/.credentials.json` for one-time
   cleanup.
5. Is `cliActiveProfileID` sufficient to identify the read-only profile, or do we
   need an explicit `isReadOnly`/`isCLISynced` flag on the profile model?

## Risks

- **ACL prompt UX:** if the user declines Always-Allow, usage won't load. Mitigated
  by a clear message and the fact that login no longer breaks (grant persists).
- **Staleness on idle days:** accepted non-goal; surfaced via stale indicator.
- **Behavior change for existing users** who relied on Climeter refreshing 24/7.
