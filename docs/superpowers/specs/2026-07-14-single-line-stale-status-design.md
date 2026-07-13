# Single-Line Claude Stale Status

**Date:** 2026-07-14  
**Status:** Approved design

## Problem

The Claude card's stale-status footer shares a 280-point popover with a card-level **Retry** button. The button duplicates the popover's global **Refresh** action and takes enough horizontal space to wrap messages such as:

> Updated 4h 6m ago — rate limited, retrying

This makes the card taller and makes a cooldown-controlled refresh look like a separate retry action.

## Goals

- Show the stale-status message on one line at the existing popover width.
- Preserve the complete message by allowing slight font scaling.
- Remove the card-level **Retry** button and its callback.
- Keep the existing global **Refresh** button as the only manual refresh action.

## Non-goals

- Change polling, credential, cooldown, or rate-limit behavior.
- Change stale-status wording.
- Change Codex/provider-card layout.
- Resize the popover.

## Design

`ProfileCard` will no longer accept an `onRetry` closure. Its stale footer will contain only the existing status `Text`, aligned to the leading edge and given the full available card width.

The status text will retain its 10-point secondary style and use:

- one-line layout;
- up to 10% downscaling, producing a minimum effective size of 9 points;
- character tightening before fallback truncation.

The current English status strings fit within the card under those constraints. Unexpectedly longer future strings may truncate rather than wrap, preserving the one-line requirement.

The popover's existing global **Refresh** button remains unchanged and continues to call `ProfileManager.refresh()` for all enabled providers.

## Accessibility

- The duplicate **Retry** accessibility control will be removed.
- The stale status remains exposed as static text.
- The global **Refresh** control remains available with its existing accessibility identity.

## Testing

Implementation will follow a red-green cycle:

1. Add a hosted SwiftUI behavior test at the effective card width that catches the current regression: the stale footer exposes a **Retry** control and occupies more than one text line.
2. Confirm the test fails against the current view.
3. Remove the callback/button and apply the one-line scaling rules.
4. Confirm the hosted-view test and full unit suite pass.
5. Build and run the app, then inspect its Accessibility tree to verify:
   - the complete stale message is presented on one line;
   - no card-level **Retry** control exists;
   - the global **Refresh** control still exists.

If AppKit's hosted Accessibility tree cannot provide a stable line-height signal, retain the no-**Retry** assertion as the regression test and use the live Accessibility check as the line-layout verification. Do not add a brittle implementation-detail test solely to satisfy coverage.

## Success Criteria

- The stale Claude card remains one line shorter than the current wrapped layout.
- The complete current stale messages fit on one line at 280 points.
- There is no per-card **Retry** button or callback.
- Global refresh behavior and provider refresh logic are unchanged.
