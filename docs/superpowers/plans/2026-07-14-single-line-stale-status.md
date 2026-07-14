# Single-Line Claude Stale Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the redundant Claude-card Retry action and render its stale-status message on one slightly shrinkable line.

**Architecture:** Keep stale-message generation and refresh coordination unchanged. Simplify `ProfileCard` so its footer is a full-width static text element, while the popover-level Refresh button remains the only manual refresh entry point. Verify the real SwiftUI layout through a hosted accessibility tree at production card geometry.

**Tech Stack:** Swift 5, SwiftUI, AppKit accessibility, XCTest, Xcode/macOS 14+

## Global Constraints

- Keep the popover width at 280 points.
- Keep stale-status copy unchanged.
- Keep the status font at 10 points with a minimum scale factor of `0.9` (9-point effective minimum).
- Never wrap the stale-status message; truncate only if a future message still exceeds the width after tightening and scaling.
- Remove the card-level Retry button and `onRetry` callback.
- Keep the global Refresh button and `ProfileManager.refresh()` behavior unchanged.
- Do not change polling, credential, cooldown, rate-limit, or Codex behavior.

---

### Task 1: Compact the Claude stale footer

**Files:**
- Modify: `ClimeterTests/ClimeterTests.swift`
- Modify: `Climeter/PopoverView.swift:67-77,256-360`

**Interfaces:**
- Consumes: `ClaudeStalePresentation.waitingMessage(...) -> String?` and the existing 280-point `PopoverView` geometry.
- Produces: `ProfileCard` without an `onRetry` initializer argument; stale status exposed with accessibility identifier `claude-stale-status`.

- [ ] **Step 1: Add a hosted-view accessibility helper and failing behavior test**

Add `AppKit` and `SwiftUI` imports to `ClimeterTests/ClimeterTests.swift`, then add this helper and test inside `ClimeterTests`:

```swift
import AppKit
import SwiftUI

private struct AccessibilitySnapshot {
    let role: NSAccessibility.Role?
    let label: String?
    let value: String?
    let identifier: String?
    let frame: NSRect
}

@MainActor
private func accessibilitySnapshots(from root: NSView) -> [AccessibilitySnapshot] {
    var snapshots: [AccessibilitySnapshot] = []
    var visited = Set<ObjectIdentifier>()

    func walk(_ element: any NSAccessibilityProtocol, depth: Int) {
        guard depth <= 12 else { return }
        let objectID = ObjectIdentifier(element as AnyObject)
        guard visited.insert(objectID).inserted else { return }

        snapshots.append(AccessibilitySnapshot(
            role: element.accessibilityRole(),
            label: element.accessibilityLabel(),
            value: element.accessibilityValue() as? String,
            identifier: element.accessibilityIdentifier(),
            frame: element.accessibilityFrame()
        ))

        for child in element.accessibilityChildren() ?? [] {
            if let accessible = child as? any NSAccessibilityProtocol {
                walk(accessible, depth: depth + 1)
            }
        }
    }

    walk(root, depth: 0)
    return snapshots
}

@MainActor
func test_profileCardStaleStatusIsOneLineWithoutRetryControl() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let expectedStatus = "Updated 4h 6m ago — rate limited, retrying"
    let card = ProfileCard(
        profile: Profile(name: "Claude", credentialSource: .cliSynced),
        usageData: UsageData(
            fiveHour: UsageWindow(utilization: 5, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(48 * 3_600))
        ),
        errorMessage: "Rate limited — retrying soon",
        lastSuccessAt: now.addingTimeInterval(-(4 * 3_600 + 6 * 60)),
        isStale: true,
        isCLIActive: false,
        showProfileName: false,
        currentTime: now,
        onRetry: {}
    )
    .padding(10)
    .frame(width: 260)

    let host = NSHostingView(rootView: card)
    host.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
    host.layoutSubtreeIfNeeded()

    let snapshots = accessibilitySnapshots(from: host)
    XCTAssertFalse(snapshots.contains {
        $0.role == .button && ($0.label == "Retry" || $0.value == "Retry")
    })

    let status = try XCTUnwrap(snapshots.first {
        $0.identifier == "claude-stale-status"
    })
    XCTAssertEqual(status.label ?? status.value, expectedStatus)

    let singleLineHeight = ceil(NSFont.systemFont(ofSize: 10).boundingRectForFont.height)
    XCTAssertLessThanOrEqual(status.frame.height, singleLineHeight + 1)
}
```

The `.frame(width: 260)` plus the card's 10-point internal padding reproduces the production 240-point text width inside a 280-point popover.

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
xcodebuild test \
  -project Climeter.xcodeproj \
  -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClimeterTests/test_profileCardStaleStatusIsOneLineWithoutRetryControl
```

Expected: FAIL because the current hosted card exposes the Retry button and has no `claude-stale-status` accessibility identifier. If the hosted tree does not expose a distinct static-text frame, remove only the line-height assertion; keep the real no-Retry accessibility assertion and verify line layout in Step 5. Do not replace it with a source-text or modifier-constant test.

- [ ] **Step 3: Remove the redundant card action**

In the `ProfileCard` call within `PopoverView`, replace:

```swift
showProfileName: profileManager.authenticatedProfiles.count > 1,
currentTime: currentTime,
onRetry: { profileManager.refresh() }
```

with:

```swift
showProfileName: profileManager.authenticatedProfiles.count > 1,
currentTime: currentTime
```

Remove this property from `ProfileCard`:

```swift
let onRetry: () -> Void
```

Update the test initializer at the same time by removing:

```swift
onRetry: {}
```

- [ ] **Step 4: Replace the stale footer with one full-width text line**

Replace the existing `HStack` containing stale text, spacer, and Retry button with:

```swift
if let staleWaitingText {
    Text(staleWaitingText)
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .allowsTightening(true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("claude-stale-status")
}
```

- [ ] **Step 5: Run focused and full verification**

Run the focused test from Step 2. Expected: PASS with no Retry accessibility node and a one-line stale-status frame.

Then run:

```bash
xcodebuild test \
  -project Climeter.xcodeproj \
  -scheme Climeter \
  -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **` with zero failures.

Then run:

```bash
xcodebuild build \
  -project Climeter.xcodeproj \
  -scheme Climeter \
  -configuration Debug \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

Inspect the hosted/live Accessibility tree at 280-point popover width and confirm all three behaviors:

1. `Updated 4h 6m ago — rate limited, retrying` occupies one static-text line.
2. No card-level Retry button is present.
3. The footer-level Refresh button remains present.

- [ ] **Step 6: Commit the implementation**

```bash
git add Climeter/PopoverView.swift ClimeterTests/ClimeterTests.swift
git commit -m "fix(ui): compact Claude stale status"
```

### Task 2: Independent cross-review

**Files:**
- Review: `docs/superpowers/specs/2026-07-14-single-line-stale-status-design.md`
- Review: `docs/superpowers/plans/2026-07-14-single-line-stale-status.md`
- Review: `Climeter/PopoverView.swift`
- Review: `ClimeterTests/ClimeterTests.swift`

**Interfaces:**
- Consumes: the committed implementation from Task 1.
- Produces: a skeptical Claude review and, if needed, committed fixes for every Critical or Important finding.

- [ ] **Step 1: Run `$cross-review` targeting Claude**

Use `~/.config/claude/skills/cross-review/scripts/run-review.sh` with a self-contained prompt that points to the spec, plan, and implementation commit. Expected: a result grouped into Critical, Important, Minor, and Assessment.

- [ ] **Step 2: Resolve review findings**

If the reviewer reports Critical or Important findings, fix them test-first, commit the fixes, and resume the same review until no Critical or Important findings remain. If it reports none, make no review-driven code changes.

- [ ] **Step 3: Re-run verification after any review fix**

Run the full `xcodebuild test` and `xcodebuild build` commands from Task 1 Step 5. Expected: both succeed.
