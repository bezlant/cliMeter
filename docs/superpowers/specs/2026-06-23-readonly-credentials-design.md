# Climeter Read-Only Credential Design

**Date:** 2026-06-23
**Status:** Revised after cross-review (codex/GPT-5 + Claude). Open questions resolved.
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
   and rotating the shared refresh token — from **multiple** call sites (see below).
2. In file-mode, writes the rotated token to `~/.claude/.credentials.json`, never
   back to the Keychain.
3. Reads that file **first** (`readCLICredentialFromFile`), so it never picks up
   Claude Code's fresh Keychain credential.

Result: Climeter rotates the token → Claude Code's Keychain copy dies → on next ~8h
expiry Claude Code can't refresh → **forced `/login`**. After re-login Claude Code
writes a fresh Keychain token, but Climeter keeps reading its stale file →
`invalid_grant` → **no usage**, never self-heals.

### All current mutation/refresh call sites (must ALL be addressed)

Cross-review found the original spec missed several. The complete list:

| # | Location | What it does | Fix |
|---|----------|--------------|-----|
| A | `UsageRefreshCoordinator.recoverCredential` | refresh on expiry / 401 | remove for CLI-synced |
| B | `ProfileManager.identifyAndSyncAccount:216` | `refreshToken` on launch/wake if expired | skip refresh for CLI-synced |
| C | `ProfileManager.setupCoordinator:476` `onCredentialRefreshed` | writes refreshed cred to CC store | for CLI-synced, never write CC store |
| D | `ProfileManager.activateForCLI:566` + `checkAutoSwitch:549` | "Activate" button & auto-switch write CC Keychain | disable CLI switching of Claude accounts from Climeter |
| E | `ProfileManager.migrateCredentialStorage:384` | writes CC file on toggle | remove |

Any one of these left in place reintroduces the bug.

### Why file-mode cannot work (architectural, not config)

- On macOS, **Claude Code's Keychain is always primary**; `~/.claude/.credentials.json`
  is only a fallback read when the Keychain is unavailable (locked/headless/Linux).
- There is **no setting or env var** to force Claude Code to file-only on macOS
  (verified against the v2.1.170 binary).
- Climeter's `fileBasedCredentialStorage` toggle only controls where *Climeter*
  reads/writes — it has no effect on Claude Code.

Climeter's file was never a shared store; it is a private copy that goes stale the
instant Claude Code rotates the token.

### Evidence (this machine, 2026-06-22)

| | Keychain | `~/.claude/.credentials.json` |
|---|---|---|
| `expiresAt` | fresh (next day) | ~29h stale |
| refresh token | current | different / dead |
| last write | Claude Code, today | Climeter, yesterday 16:11 |

Logs: last good Climeter refresh `Jun 21 16:11` (8h token) → first `invalid_grant`
`Jun 22 00:07` (exactly at expiry) → looping `giving up` every poll.

## Goals

- Climeter never breaks Claude Code's login again.
- Climeter shows Claude usage reliably while Claude Code is in normal use.
- No recurring Keychain password popups.

## Non-Goals

- Keeping the meter live when the token is expired **and** Claude Code is not running
  (accepted: show stale).
- Changing Codex credential handling (separate subsystem, untouched).
- Switching the **active Claude Code account** from within Climeter (was a CC-store
  write; removed — see Decision D).

## Core Principle

**Climeter observes, never mutates, Claude Code's credential.** The Keychain item
`Claude Code-credentials` is read-only source of truth. Only the **access token**
(short-lived, non-destructive) is ever used. The **refresh token is never consumed.**

## Design

### 1. Explicit credential-ownership model (resolves Open Q5)

Add to the profile model:

```swift
enum CredentialSource: String, Codable { case cliSynced, selfOwned }
```

- `cliSynced` — mirrors Claude Code. **Read-only.** Never refreshed, never persisted
  to disk as a secret, never written to CC's store.
- `selfOwned` — manually pasted session key. Owns an independent token; unchanged
  behavior (may refresh, persisted in Climeter's own store).

This is **persisted** on the profile and is the single gate for all
refresh/persist/write/auto-start behavior. `cliActiveProfileID` remains only a
"which account does the CLI currently show" pointer — it is **not** used to decide
read-only behavior (a profile stays `cliSynced` even when not currently active).

### 2. The three credential stores

1. **Claude Code Keychain** (`Claude Code-credentials`) — source of truth for
   `cliSynced` profiles. **Read-only.** Read rarely (§4). Never written, ACL never
   modified.
2. **Claude Code file** (`~/.claude/.credentials.json`) — **abandoned on macOS.**
   Climeter never reads, writes, bootstraps, or falls back to it (resolves Open Q1:
   ignore entirely; a stale file is exactly the original bug).
3. **Climeter's own store** (`KeychainService` `com.bezlant.climeter` /
   `FileCredentialStore` app-support) — Climeter always has access, no popups. Stores
   `selfOwned` secrets and **non-secret metadata only** for `cliSynced` profiles
   (accountUUID, displayName, subscriptionType). **CLI OAuth tokens are never written
   here** (resolves codex BLOCKER #3 — prevents reviving stale tokens after restart).

### 3. Read strategy (cliSynced)

- Read the Keychain on: **app launch**, **wake/unlock**, **manual refresh**, a **401**
  from `fetchUsage`, and **scheduled near-expiry**.
- Cache the access token + `expiresAt` **in memory only**.
- Schedule the next Keychain read at `expiresAt - 5min` → ~1 read per token lifetime
  (~8h) in steady state (resolves Open Q3). The 180s usage poll reuses the cached
  access token between reads; it does **not** hit the Keychain each cycle.

### 4. Expiry handling (cliSynced)

- Cached access token valid → `fetchUsage` with it.
- Cached token expired → read Keychain once:
  - Keychain has newer valid token (Claude Code refreshed) → use it, fetch usage.
  - Keychain token also expired (Claude Code idle) → **do not refresh.** Show
    last-known usage + stale indicator (§7). **Back off** Keychain re-reads to every
    15 min while it stays expired (resolves codex MAJOR #7 — avoids hammering the
    Keychain on idle days); reset to normal cadence once a fresh token appears.
- `recoverCredential` refresh path (site A) is **removed** for `cliSynced`; the
  unused `syncCLICredential` callback is removed.

### 5. Account-switch detection (no 30s poll)

- Remove the 30s `detectCLIAccountChange` timer (main popup driver).
- On each (rare) Keychain read, compare `accountUUID`; switch the active profile if it
  changed. Worst-case detection lag = one token lifetime, acceptable per Non-Goals.
- **Optional, only if verified prompt-free:** an `FSEvents` watch on `~/.claude`
  (zero Keychain access) to trigger an immediate re-read on credential change. Do
  **not** use a Keychain `mdat` attribute probe unless empirically proven not to
  prompt on a signed/notarized build (resolves codex #7 / Open Q3 caveat).

### 6. Keychain access & popups (resolves codex MAJOR #6)

- Reading another app's Keychain item prompts unless Climeter is in the item's ACL.
  User grants **"Always Allow" once**. Climeter never modifies the ACL.
- Because Climeter no longer breaks login, Claude Code stops recreating the item
  (which reset the ACL), so the grant generally persists.
- **But do not assume permanence:** an app update / code-signing change can reset the
  grant. Therefore:
  - Probe non-interactively first with `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail`.
  - Only show the macOS prompt as a result of explicit user action (launch read or a
    **Retry** button), with a clear message: "Allow Keychain access to read Claude
    usage."
  - Budget for an occasional re-grant after updates; surface it as the actionable
    error state, never a silent failure.

### 7. Stale-indicator UX (resolves codex MAJOR — was unspecified)

- **Menu bar:** when displayed data is older than **10 min** OR the token is expired
  with no fresh Keychain token, render a dimmed icon / small dot so staleness is
  visible without opening the popover.
- **Popover:** show "Updated Xm ago" (from `lastSuccessAt`); when stale, add "waiting
  for Claude Code to refresh" and a **Retry** button.
- Clears as soon as a successful fetch updates `lastSuccessAt`.

### 8. Auto-start

- **Kept**, gated to `cliSynced` profiles **with a freshly-read, valid Keychain
  token** (never a cached/stale token). Implicitly inert when the token is expired
  (it would 401), which is correct. Login-safe (access token only, no rotation).

## Components Affected

- `Profile` model + `ProfileStore` — add persisted `credentialSource`; stop persisting
  `cliSynced` OAuth secrets (metadata only).
- `ClaudeCodeSyncService` — remove file read/write/bootstrap
  (`readCLICredentialFromFile`, `writeCLICredentialToFile`, `writeRawToCredentialFile`,
  bootstrap branch); remove `writeCLICredential` usage for CLI; keep
  `readCLICredentialRaw` (Keychain read), add the non-interactive probe option.
- `UsageRefreshCoordinator` — gate on `credentialSource`; for `cliSynced` replace
  `recoverCredential` with "re-read Keychain or show stale"; remove `syncCLICredential`.
- `ProfileManager` — remove sites B, C(write), D, E above; remove the 30s timer; add
  expiry-scheduled Keychain reads + backoff; thread `credentialSource`.
- `SettingsView` — remove the CLI "file-based storage" semantics; rename any remaining
  toggle to clearly mean **Climeter's own** store only (resolves Open Q2); remove the
  "Activate for CLI" control for Claude accounts (Decision D).
- `FileCredentialStore` — retained for Climeter's own `selfOwned` store only.

## Decision D — CLI account switching

`activateForCLI`/`checkAutoSwitch` wrote Climeter-chosen credentials into Claude
Code's Keychain. That is a CC-store mutation and is removed. **Switching the active
Claude Code account is done in Claude Code itself**; Climeter detects the switch
(§5) and follows. Climeter may still show multiple accounts' usage read-only if their
tokens are independently available, but it will not flip CC's active account.

## Error Handling

- Expired token + Claude Code idle → stale UI, no error toast.
- Keychain read denied → actionable message + Retry button; auto-retry on next
  scheduled read.
- `fetchUsage` 401 → re-read Keychain once; if token unchanged → stale, **no refresh**.
- 429 backoff unchanged.

## Testing (behavioral; each catches a concrete failure mode)

1. **Never-refresh invariant:** expired `cliSynced` credential + injected API client →
   assert **no HTTP POST to `/v1/oauth/token`** is issued and **no write to CC's
   store** occurs. (Inject the API client/keychain reader/clock; assert on the real
   request, not a mock callback.)
2. **identifyAndSyncAccount safety (site B):** launch/wake with expired `cliSynced`
   token → assert `refreshToken` never called; identification skipped or fails softly.
3. **No write-back (site C):** force a coordinator credential update for a `cliSynced`
   profile → assert `ClaudeCodeSyncService.writeCLICredential` never invoked.
4. **Self-heal:** cached token expired → `fetchUsage` 401 → Keychain returns token with
   later `expiresAt` → retry succeeds with the new token, no refresh.
5. **Stale-when-idle:** cached + Keychain both expired → last usage retained,
   `lastSuccessAt` unchanged, stale indicator set, no API refresh, no error; Keychain
   re-reads back off to 15 min.
6. **selfOwned still refreshes:** profile with `credentialSource == .selfOwned` and
   expired token → refresh path intact.
7. **Account switch via rare read:** Keychain `accountUUID` changes B→A → on next
   scheduled read, active profile switches and fetches A's usage; no 30s polling.
8. **File abandoned:** assert the CLI path never reads or writes
   `~/.claude/.credentials.json`.
9. **Keychain-denied flow:** probe returns denied → error state + Retry; Retry
   re-reads.
10. **Migration:** stale file present → backed up (not silently deleted); persisted
    `cliSynced` secrets purged from Climeter's store.

Replace/remove obsolete tests (e.g. `CLISyncFileReadTests`) that assert the old
file-read behavior.

## Migration / Cleanup (resolves Open Q4)

- On macOS the file is never authoritative, so removing it cannot break Claude Code.
  To stay safe and reversible, **rename** `~/.claude/.credentials.json` →
  `~/.claude/.credentials.json.climeter-bak` once on upgrade (don't hard-delete),
  and log it. No "did Climeter author it" guard needed.
- Purge any persisted `cliSynced` OAuth secrets from Climeter's own store; keep
  metadata.
- Set `credentialSource` for existing profiles: the CLI-active one → `cliSynced`;
  others with a stored session key → `selfOwned`.
- One-time user remedy for the currently-broken machine: this migration + `/login`
  once in Claude Code.

## Resolved Open Questions

1. Ignore `~/.claude/.credentials.json` entirely on macOS (no fallback read).
2. Remove the CLI meaning of the toggle; if retained, it controls only Climeter's own
   `selfOwned` store and is renamed accordingly.
3. Drive Keychain reads off `expiresAt` (~1/8h) + launch/wake/401/manual; optional
   FSEvents watch; no unverified `mdat` probe.
4. Rename the stale file to a `.climeter-bak`; no risky detection, no hard delete.
5. Add a persisted `credentialSource` flag; do not rely on `cliActiveProfileID`.

## Risks

- **ACL prompt UX:** declined grant → no usage; mitigated by clear message + Retry,
  and grant persistence now that login isn't broken.
- **Staleness on idle days:** accepted; surfaced via stale indicator.
- **Behavior change:** Climeter no longer refreshes 24/7 and no longer switches the
  CLI account; documented in release notes.
- **FSEvents/probe assumptions** must be verified on a signed/notarized build before
  relying on them.
