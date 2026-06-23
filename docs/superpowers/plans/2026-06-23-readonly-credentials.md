# Read-Only Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Climeter a strictly read-only consumer of Claude Code's Keychain credential so it never rotates the shared OAuth refresh token (which breaks `/login`) and never goes permanently stale.

**Architecture:** Introduce a persisted `CredentialSource` (`cliSynced` vs `selfOwned`) on `Profile`. For `cliSynced` profiles, isolate the "what to do on each poll" decision into a **pure function** (`CLICredentialPolicy`) that can only ever return *fetch / reread-keychain / show-stale* — never *refresh* and never *write*. Refactor `UsageRefreshCoordinator` to take injected closures (keychain reader, usage fetcher, optional refresher) so the never-refresh invariant is unit-testable. Remove all five Claude-Code-store mutation sites. Abandon the `~/.claude/.credentials.json` path on macOS.

**Tech Stack:** Swift 5, SwiftUI, XCTest, macOS Keychain (Security framework), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-06-23-readonly-credentials-design.md`

**Test command (use everywhere below):**
```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' -only-testing:ClimeterTests 2>&1 | tail -30
```
Single test: append `-only-testing:ClimeterTests/<Class>/<method>`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Climeter/Profile.swift` | Profile model | add persisted `credentialSource` |
| `Climeter/Credential.swift` | OAuth credential value | add `isExpired(now:)` for injectable time |
| `Climeter/CLICredentialPolicy.swift` | **NEW** pure poll-decision logic | create |
| `Climeter/ClaudeCodeSyncService.swift` | read CC Keychain | remove file + write paths; keep keychain read |
| `Climeter/UsageRefreshCoordinator.swift` | per-profile polling | inject closures; read-only mode; stale + backoff |
| `Climeter/ProfileManager.swift` | orchestration | remove 5 mutation sites; wire `credentialSource`; in-memory CLI tokens; rare reads |
| `Climeter/ProfileStore.swift` | persistence | rename file-storage toggle scope; migration helper |
| `Climeter/SettingsView.swift` | settings UI | remove/rename toggle; remove Activate for Claude |
| `Climeter/PopoverView.swift` | menu UI | remove Activate; stale text + Retry |
| `Climeter/MenuBarIcon.swift` | menu bar glyph | dim/dot when stale |
| `ClimeterTests/*` | tests | new policy/migration tests; delete obsolete file-read tests |

---

## Task 0: Baseline

- [ ] **Step 1: Confirm the suite is green before changes**

Run:
```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' -only-testing:ClimeterTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`. If not, stop and report — do not build on a red baseline.

---

## Task 1: `CredentialSource` on the Profile model

**Files:**
- Modify: `Climeter/Profile.swift`
- Test: `ClimeterTests/ProfileCodableTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `ClimeterTests/ProfileCodableTests.swift`:
```swift
import XCTest
@testable import Climeter

final class ProfileCodableTests: XCTestCase {
    func test_defaultSourceIsCLISynced() {
        let p = Profile(name: "X")
        XCTAssertEqual(p.credentialSource, .cliSynced)
    }

    func test_decodingLegacyProfileWithoutSourceDefaultsToCLISynced() throws {
        // Profiles persisted before this field existed have no `credentialSource` key.
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(Profile.self, from: legacy)
        XCTAssertEqual(p.credentialSource, .cliSynced)
    }

    func test_roundTripPreservesSelfOwned() throws {
        var p = Profile(name: "Manual")
        p.credentialSource = .selfOwned
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(back.credentialSource, .selfOwned)
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run the single-class test. Expected: compile failure (`credentialSource` unknown).

- [ ] **Step 3: Implement**

Replace `Climeter/Profile.swift` contents:
```swift
import Foundation

enum CredentialSource: String, Codable {
    case cliSynced   // mirrors Claude Code; read-only, never refreshed/written
    case selfOwned   // manually pasted session key; Climeter owns the token
}

struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    var credentialSource: CredentialSource

    init(id: UUID = UUID(), name: String, credentialSource: CredentialSource = .cliSynced) {
        self.id = id
        self.name = name
        self.credentialSource = credentialSource
    }

    // Custom decode so profiles persisted before this field default to .cliSynced.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        credentialSource = try c.decodeIfPresent(CredentialSource.self, forKey: .credentialSource) ?? .cliSynced
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run the class. Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Climeter/Profile.swift ClimeterTests/ProfileCodableTests.swift
git commit -m "feat: add CredentialSource to Profile (defaults cliSynced)"
```

---

## Task 2: Injectable expiry on `Credential`

**Files:**
- Modify: `Climeter/Credential.swift`
- Test: `ClimeterTests/CredentialExpiryTests.swift` (create)

- [ ] **Step 1: Failing test**

Create `ClimeterTests/CredentialExpiryTests.swift`:
```swift
import XCTest
@testable import Climeter

final class CredentialExpiryTests: XCTestCase {
    private func cred(expiresAtMillis: Double) -> Credential {
        Credential(jsonString: """
        {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\(expiresAtMillis)}}
        """)!
    }

    func test_notExpiredWellBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1000)
        let c = cred(expiresAtMillis: 1000_000 * 1000) // far future
        XCTAssertFalse(c.isExpired(now: now))
    }

    func test_expiredWithinFiveMinuteMargin() {
        let now = Date(timeIntervalSince1970: 1000)
        // expires 4 min after now -> considered expired (5 min safety margin)
        let c = cred(expiresAtMillis: (1000 + 240) * 1000)
        XCTAssertTrue(c.isExpired(now: now))
    }
}
```

- [ ] **Step 2: Run, verify fails** (`isExpired(now:)` unknown).

- [ ] **Step 3: Implement** — in `Climeter/Credential.swift` replace the `isExpired` computed property:
```swift
    func isExpired(now: Date) -> Bool {
        expiresAt < now.addingTimeInterval(5 * 60)
    }

    var isExpired: Bool { isExpired(now: Date.now) }
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**
```bash
git add Climeter/Credential.swift ClimeterTests/CredentialExpiryTests.swift
git commit -m "feat: add injectable Credential.isExpired(now:)"
```

---

## Task 3: Pure poll-decision policy (the never-refresh invariant)

**Files:**
- Create: `Climeter/CLICredentialPolicy.swift`
- Test: `ClimeterTests/CLICredentialPolicyTests.swift`

This pure function encodes the entire cliSynced decision. It has **no `refresh` case**, so the regression is impossible by construction, and it is trivially testable.

- [ ] **Step 1: Failing test**

Create `ClimeterTests/CLICredentialPolicyTests.swift`:
```swift
import XCTest
@testable import Climeter

final class CLICredentialPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func cred(at expiresSecsFromNow: Double, token: String) -> Credential {
        let millis = (10_000 + expiresSecsFromNow) * 1000
        return Credential(jsonString: """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(millis)}}
        """)!
    }

    func test_cachedValid_fetchesWithCached() {
        let cached = cred(at: 3600, token: "cachedAT")
        let action = CLICredentialPolicy.action(cached: cached, keychain: nil, now: now)
        XCTAssertEqual(action, .fetchUsage(cached))
    }

    func test_cachedExpired_noKeychainGiven_rereadsKeychain() {
        let cached = cred(at: 60, token: "old") // within 5-min margin -> expired
        let action = CLICredentialPolicy.action(cached: cached, keychain: nil, now: now)
        XCTAssertEqual(action, .rereadKeychain)
    }

    func test_cachedExpired_keychainFresh_fetchesAndCachesKeychain() {
        let cached = cred(at: 60, token: "old")
        let fresh = cred(at: 3600, token: "freshAT")
        let action = CLICredentialPolicy.action(cached: cached, keychain: fresh, now: now)
        XCTAssertEqual(action, .fetchUsageAndCache(fresh))
    }

    func test_cachedExpired_keychainAlsoExpired_showsStale() {
        let cached = cred(at: 60, token: "old")
        let staleKeychain = cred(at: 60, token: "alsoOld")
        let action = CLICredentialPolicy.action(cached: cached, keychain: staleKeychain, now: now)
        XCTAssertEqual(action, .showStale)
    }

    func test_noCached_keychainFresh_fetchesAndCaches() {
        let fresh = cred(at: 3600, token: "freshAT")
        let action = CLICredentialPolicy.action(cached: nil, keychain: fresh, now: now)
        XCTAssertEqual(action, .fetchUsageAndCache(fresh))
    }

    func test_noCached_noKeychain_rereadsKeychain() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: nil, keychain: nil, now: now), .rereadKeychain)
    }
}
```
(`Credential` must be `Equatable` for `.fetchUsage(cred)` comparisons — added in Step 3.)

- [ ] **Step 2: Run, verify fails.**

- [ ] **Step 3: Implement**

In `Climeter/Credential.swift`, add `Equatable` conformance (compare on the fields that matter):
```swift
extension Credential: Equatable {
    static func == (l: Credential, r: Credential) -> Bool {
        l.accessToken == r.accessToken &&
        l.refreshToken == r.refreshToken &&
        l.expiresAt == r.expiresAt
    }
}
```

Create `Climeter/CLICredentialPolicy.swift`:
```swift
import Foundation

/// Pure decision for a read-only (cliSynced) profile's poll cycle.
/// There is deliberately NO `refresh` case: Climeter must never rotate
/// Claude Code's shared refresh token.
enum CLIRefreshAction: Equatable {
    case fetchUsage(Credential)          // cached access token still valid
    case fetchUsageAndCache(Credential)  // use this freshly-read keychain token, update cache
    case rereadKeychain                  // need a keychain read to decide
    case showStale                       // nothing usable; keep last usage, mark stale
}

enum CLICredentialPolicy {
    /// - Parameters:
    ///   - cached: in-memory access token from a previous keychain read (if any)
    ///   - keychain: a just-read keychain credential, or nil if not yet read this cycle
    static func action(cached: Credential?, keychain: Credential?, now: Date) -> CLIRefreshAction {
        if let cached, !cached.isExpired(now: now) {
            return .fetchUsage(cached)
        }
        guard let keychain else { return .rereadKeychain }
        if !keychain.isExpired(now: now) {
            return .fetchUsageAndCache(keychain)
        }
        return .showStale
    }
}
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**
```bash
git add Climeter/CLICredentialPolicy.swift Climeter/Credential.swift ClimeterTests/CLICredentialPolicyTests.swift
git commit -m "feat: pure CLICredentialPolicy with no refresh path"
```

---

## Task 4: `ClaudeCodeSyncService` — keychain-read only

**Files:**
- Modify: `Climeter/ClaudeCodeSyncService.swift`
- Delete: `ClimeterTests/CLISyncFileReadTests.swift`
- Test: `ClimeterTests/ClaudeCodeSyncServiceTests.swift` (create)

- [ ] **Step 1: Delete the obsolete file-read tests**
```bash
git rm ClimeterTests/CLISyncFileReadTests.swift
```

- [ ] **Step 2: Failing test for the new surface**

Create `ClimeterTests/ClaudeCodeSyncServiceTests.swift`:
```swift
import XCTest
@testable import Climeter

final class ClaudeCodeSyncServiceTests: XCTestCase {
    func test_credentialFromRawParsesKeychainJSON() {
        let raw = """
        {"claudeAiOauth":{"accessToken":"kc-at","refreshToken":"kc-rt","expiresAt":1700000000000}}
        """
        let cred = ClaudeCodeSyncService.credential(fromRaw: raw)
        XCTAssertEqual(cred?.accessToken, "kc-at")
    }

    func test_credentialFromRawReturnsNilForGarbage() {
        XCTAssertNil(ClaudeCodeSyncService.credential(fromRaw: "not json"))
    }
}
```

- [ ] **Step 3: Rewrite the service** — replace `Climeter/ClaudeCodeSyncService.swift` with a keychain-read-only version. Remove `readCLICredentialFromFile`, `writeCLICredentialToFile`, `writeRawToCredentialFile`, `writeCLICredential`, `writeCLICredentialToKeychain`, `makeSharedAccess`, `cliCredentialFileExists`, and the `preferFile` bootstrap. Keep the keychain read; add a non-interactive `probe` variant and a small testable parse helper:

```swift
import Foundation
import Security

enum ClaudeCodeSyncService {
    private static let serviceName = "Claude Code-credentials"
    private static let account = NSUserName()

    /// Read Claude Code's credential from the macOS Keychain. Read-only.
    /// `interactive == false` uses kSecUseAuthenticationUIFail so it never
    /// shows a password prompt (used for background/scheduled reads).
    static func readCLICredential(interactive: Bool) -> Credential? {
        guard let raw = readCLICredentialRaw(interactive: interactive) else { return nil }
        return credential(fromRaw: raw)
    }

    static func credential(fromRaw raw: String) -> Credential? {
        let c = Credential(jsonString: raw)
        if c == nil {
            Log.cliSync.warning("Keychain data read OK but failed to parse as Credential")
        }
        return c
    }

    static func readCLICredentialRaw(interactive: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        Log.cliSync.info("readCLICredential (interactive=\(interactive)): \(Log.keychainStatus(status))")

        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound && status != errSecInteractionNotAllowed {
                Log.cliSync.error("readCLICredential failed: \(Log.keychainStatus(status))")
            }
            return nil
        }
        return str
    }
}
```

- [ ] **Step 4: Fix call sites so the project compiles.** Build will now fail wherever the deleted methods were used (`ProfileManager`). That is expected and is fixed in Task 6. To keep this task self-contained, temporarily compile by running only this test target file is not possible (whole target compiles). Therefore: **do Task 5 and Task 6 before running the full build.** Mark this task's test deferred to the end of Task 6.

> NOTE: Tasks 4–6 form one compile unit. Implement all three, then run the suite once at the end of Task 6.

- [ ] **Step 5: Commit (WIP, compiles after Task 6)**
```bash
git add Climeter/ClaudeCodeSyncService.swift ClimeterTests/ClaudeCodeSyncServiceTests.swift
git commit -m "refactor: ClaudeCodeSyncService is keychain-read-only (WIP, compiles w/ Task 6)"
```

---

## Task 5: `UsageRefreshCoordinator` — injected closures + read-only mode

**Files:**
- Modify: `Climeter/UsageRefreshCoordinator.swift`
- Test: `ClimeterTests/UsageRefreshCoordinatorReadOnlyTests.swift` (create)

Add a `readOnly` flag and an injected `keychainReader`. When `readOnly`, the coordinator drives off `CLICredentialPolicy` and **never** calls `refreshToken`/`onCredentialRefreshed`.

- [ ] **Step 1: Failing test (never-refresh invariant at the coordinator level)**

Create `ClimeterTests/UsageRefreshCoordinatorReadOnlyTests.swift`:
```swift
import XCTest
@testable import Climeter

@MainActor
final class UsageRefreshCoordinatorReadOnlyTests: XCTestCase {
    private func cred(expiresSecsFromNow: Double, token: String) -> Credential {
        let millis = (Date.now.timeIntervalSince1970 + expiresSecsFromNow) * 1000
        return Credential(jsonString: """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(millis)}}
        """)!
    }

    func test_readOnly_expiredCached_freshKeychain_fetchesWithoutRefresh() async {
        var refreshCalled = false
        var fetchedToken: String?
        let coord = UsageRefreshCoordinator(
            profileID: UUID(),
            readOnly: true,
            credentialProvider: { self.cred(expiresSecsFromNow: 60, token: "old") },
            keychainReader: { self.cred(expiresSecsFromNow: 3600, token: "fresh") },
            usageFetcher: { c in fetchedToken = c.accessToken; return UsageData.empty },
            refresher: { _ in refreshCalled = true; throw ClaudeAPIError.invalidResponse }
        )
        await coord.refreshForTest()
        XCTAssertFalse(refreshCalled, "read-only coordinator must never refresh")
        XCTAssertEqual(fetchedToken, "fresh")
    }

    func test_readOnly_bothExpired_showsStaleNoRefresh() async {
        var refreshCalled = false
        var fetchCalled = false
        let coord = UsageRefreshCoordinator(
            profileID: UUID(),
            readOnly: true,
            credentialProvider: { self.cred(expiresSecsFromNow: 60, token: "old") },
            keychainReader: { self.cred(expiresSecsFromNow: 60, token: "alsoOld") },
            usageFetcher: { _ in fetchCalled = true; return UsageData.empty },
            refresher: { _ in refreshCalled = true; throw ClaudeAPIError.invalidResponse }
        )
        await coord.refreshForTest()
        XCTAssertFalse(refreshCalled)
        XCTAssertFalse(fetchCalled)
        XCTAssertTrue(coord.isStale)
    }
}
```

You will need a tiny test helper on `UsageData`:
```swift
// in the test file or a test support file
extension UsageData {
    static var empty: UsageData {
        // Build a minimal valid instance; mirror the real initializer.
        // If UsageData has no memberwise init, decode from a minimal JSON fixture instead.
        return try! JSONDecoder().decode(UsageData.self, from: Data("""
        {"five_hour":{"utilization":0},"seven_day":{"utilization":0}}
        """.utf8))
    }
}
```
> If this fixture does not match `UsageData`'s shape, open `Climeter/UsageData.swift`, read the `Codable` keys, and adjust the JSON to the real schema. Do not invent fields.

- [ ] **Step 2: Run, verify fails** (new initializer/`refreshForTest`/`isStale` unknown).

- [ ] **Step 3: Implement** — extend `UsageRefreshCoordinator`:
  - Add stored properties: `let readOnly: Bool`, `let keychainReader: (() -> Credential?)?`, `let usageFetcher: (Credential) async throws -> UsageData`, `let refresher: ((Credential) async throws -> Credential)?`, and `@Published var isStale: Bool = false`.
  - Add a designated initializer carrying these (keep the old one delegating to it with `readOnly: false`, `usageFetcher: ClaudeAPIService.fetchUsage`, `refresher: ClaudeAPIService.refreshToken`, `keychainReader: nil`).
  - Add the read-only path:
```swift
    /// Test seam: run one read-only cycle synchronously.
    @MainActor
    func refreshForTest() async { await runReadOnlyCycle() }

    @MainActor
    private func runReadOnlyCycle() async {
        let cached = credentialProvider()
        var action = CLICredentialPolicy.action(cached: cached, keychain: nil, now: Date.now)
        if action == .rereadKeychain {
            let kc = keychainReader?()
            action = CLICredentialPolicy.action(cached: cached, keychain: kc, now: Date.now)
        }
        switch action {
        case .fetchUsage(let c):
            await fetchAndPublish(c, cache: nil)
        case .fetchUsageAndCache(let c):
            await fetchAndPublish(c, cache: c)
        case .rereadKeychain:
            // keychain unavailable (e.g. denied / locked) -> stale
            isStale = true
        case .showStale:
            isStale = true
        }
    }

    @MainActor
    private func fetchAndPublish(_ credential: Credential, cache: Credential?) async {
        if let cache { onCredentialCached?(cache) }
        do {
            let data = try await usageFetcher(credential)
            usageData = data
            errorMessage = nil
            lastSuccessAt = Date()
            isStale = false
            checkAutoStart(credential: credential, usage: data)
        } catch {
            // 401 -> force a keychain reread next cycle by leaving cache stale;
            // never refresh in read-only mode.
            isStale = true
            if usageData == nil { errorMessage = Self.describeError(error, context: "fetch") }
        }
    }
```
  - In `refresh()` (the timer entry point), branch at the top: `if readOnly { activeTask = Task { await self.runReadOnlyCycle() }; return }` before the existing self-owned logic.
  - Add `onCredentialCached: ((Credential) -> Void)?` (replaces the CC-writing `onCredentialRefreshed` for read-only profiles — it only updates the in-memory cache).
  - Remove the `syncCLICredential` parameter and its dead use in `recoverCredential` (it was always nil).

- [ ] **Step 4:** Defer running until end of Task 6 (shared compile unit).

- [ ] **Step 5: Commit (WIP)**
```bash
git add Climeter/UsageRefreshCoordinator.swift ClimeterTests/UsageRefreshCoordinatorReadOnlyTests.swift
git commit -m "feat: read-only mode in UsageRefreshCoordinator (WIP)"
```

---

## Task 6: `ProfileManager` — remove all 5 mutation sites; wire read-only

**Files:**
- Modify: `Climeter/ProfileManager.swift`, `Climeter/ProfileStore.swift`
- Test: `ClimeterTests/ProfileManagerMigrationTests.swift` (extend)

- [ ] **Step 1: Site B — `identifyAndSyncAccount` must not refresh.** In `ProfileManager.swift:216-222`, delete the expired-refresh block:
```swift
        // Refresh expired token before identifying account
        if credential.isExpired { ... ClaudeAPIService.refreshToken ... }
```
Replace with: if `credential.isExpired`, attempt `fetchProfile` anyway; on failure just return (identification retries on the next scheduled keychain read). No refresh.

- [ ] **Step 2: Site C — read-only coordinators never write CC store.** In `setupCoordinator` (`:471-495`), construct the coordinator with the new initializer. Determine read-only from the profile:
```swift
let source = profiles.first { $0.id == profileID }?.credentialSource ?? .cliSynced
let readOnly = (source == .cliSynced)
```
For read-only, pass `readOnly: true`, `keychainReader: { ClaudeCodeSyncService.readCLICredential(interactive: false) }`, `onCredentialCached: { [weak self] c in self?.cachedCredentials[profileID] = c }`, and **no** `onCredentialRefreshed` write to `ClaudeCodeSyncService`. For `selfOwned`, keep the existing refresh+persist closure (it writes only to Climeter's own store via `ProfileStore`, never to `ClaudeCodeSyncService`).

- [ ] **Step 3: Site D — stop writing CC store on activate.** Rewrite `activateForCLI` (`:565-571`) to not call `ClaudeCodeSyncService.writeCLICredential`:
```swift
    func activateForCLI(profileID: UUID) {
        // Climeter no longer switches Claude Code's active account (that was a
        // write to CC's keychain). Switching is done in Claude Code itself.
        cliActiveProfileID = profileID
        ProfileStore.saveCLIActiveProfileID(profileID)
    }
```
Remove the `checkAutoSwitch` → `activateForCLI` call for Claude profiles: in `checkAutoSwitch` (`:529-550`), since it can no longer switch CC's account, gate it to `selfOwned` profiles only, or remove auto-switch for Claude. Implement: only consider candidates whose `credentialSource == .selfOwned`; if none, return. (Auto-switch across read-only CC accounts is no longer possible without writing CC's store — documented in spec Decision D.)

- [ ] **Step 4: Site E — `migrateCredentialStorage` must not write CC file.** Delete the block at `:383-387`:
```swift
        if toFileBased, let activeID = cliActiveProfileID, ... {
            ClaudeCodeSyncService.writeCLICredential(credential, preferFile: true)
        }
```

- [ ] **Step 5: Remove the 30s keychain poll.** In `startCLIMonitoring` (`:164-172`), delete the `cliMonitorTimer` 30s repeat. Keep a single launch read. Trigger re-reads from: launch, `resumeAfterWake`, and the read-only coordinators' scheduled cycles. Replace `detectCLIAccountChange`'s `readCLICredential(preferFile:)` with `readCLICredential(interactive: false)` (and an interactive read on explicit launch where a prompt is acceptable).

- [ ] **Step 6: In-memory-only CLI tokens.** In `saveAndActivate` (`:285-297`) and `identifyAndSyncAccount`, for `cliSynced` profiles do **not** call `ProfileStore.saveCredentialModel` with the secret; instead persist only metadata. Add to `ProfileStore`:
```swift
    // Non-secret metadata for cliSynced profiles (no tokens on disk).
    static func saveAccountMetadata(uuid: String?, displayName: String?, for profileID: UUID) {
        var dict = defaults.dictionary(forKey: "accountMeta") as? [String: [String: String]] ?? [:]
        var entry = dict[profileID.uuidString] ?? [:]
        if let uuid { entry["uuid"] = uuid }
        if let displayName { entry["name"] = displayName }
        dict[profileID.uuidString] = entry
        defaults.set(dict, forKey: "accountMeta")
    }
```
Keep `cachedCredentials` (in-memory) as the only home for cliSynced tokens. `selfOwned` profiles still persist via `ProfileStore.saveCredentialModel`.

- [ ] **Step 7: Migration on upgrade (extend the pure helper).** Add a new pure static used at launch:
```swift
    static func performReadOnlyMigration(
        homeDirectory: URL,
        renameStaleFile: (URL, URL) -> Void,
        purgeCLISecret: (UUID) -> Void,
        cliSyncedProfileIDs: [UUID]
    ) {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        let src = claudeDir.appendingPathComponent(".credentials.json")
        let dst = claudeDir.appendingPathComponent(".credentials.json.climeter-bak")
        renameStaleFile(src, dst) // implementation no-ops if src absent
        for id in cliSyncedProfileIDs { purgeCLISecret(id) }
    }
```
Call it once from `init()` with real closures (FileManager move guarded by existence; `ProfileStore.deleteCredential` for purge). Set `credentialSource` for existing profiles: CLI-active → `cliSynced`; any with a stored session key but never CLI-active → `selfOwned`.

- [ ] **Step 8: Update `ProfileManagerMigrationTests`** — add:
```swift
    func test_readOnlyMigrationRenamesStaleFileAndPurgesSecrets() {
        var renamed: (URL, URL)?
        var purged: [UUID] = []
        let id = UUID()
        ProfileManager.performReadOnlyMigration(
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            renameStaleFile: { s, d in renamed = (s, d) },
            purgeCLISecret: { purged.append($0) },
            cliSyncedProfileIDs: [id]
        )
        XCTAssertEqual(renamed?.0.lastPathComponent, ".credentials.json")
        XCTAssertEqual(renamed?.1.lastPathComponent, ".credentials.json.climeter-bak")
        XCTAssertEqual(purged, [id])
    }
```

- [ ] **Step 9: Compile + run the WHOLE suite (Tasks 4–6 land together).**

Run the full test command. Expected: `** TEST SUCCEEDED **`, including the Task 3/4/5 tests. Fix compile errors (remaining references to deleted methods) until green.

- [ ] **Step 10: Commit**
```bash
git add Climeter/ProfileManager.swift Climeter/ProfileStore.swift ClimeterTests/ProfileManagerMigrationTests.swift ClimeterTests/ClaudeCodeSyncServiceTests.swift ClimeterTests/UsageRefreshCoordinatorReadOnlyTests.swift
git commit -m "feat: remove all Claude Code store mutations; read-only CLI sync"
```

---

## Task 7: Settings & Popover UI

**Files:** `Climeter/SettingsView.swift`, `Climeter/PopoverView.swift`

- [ ] **Step 1: Remove the file-storage toggle's CLI meaning.** In `SettingsView.swift:27-46`, delete the "Use file-based storage" `Section("Credential Storage")` block (Climeter now always reads CC's keychain read-only; the toggle only ever affected the buggy path). Update the Claude section text (`:54`, `:59`) to remove the "File-based via Claude Code" wording — replace `:54` Text with `"macOS Keychain via Claude Code (read-only)"`.

- [ ] **Step 2: Remove the Activate control for Claude.** In `SettingsView.swift:142` and `PopoverView.swift:76`, remove the buttons that call `profileManager.activateForCLI(...)` for Claude profiles (switching is done in Claude Code now). Leave profile display/rename/delete intact.

- [ ] **Step 3: Remove `fileBasedStorage` published + toggle plumbing** if now unused: delete the `@Published var fileBasedStorage` (`ProfileManager.swift:50-55`) and its `migrateCredentialStorage(toFileBased:)` instance method only if no remaining references (grep first). Keep `FileCredentialStore` for `selfOwned` storage. (If `selfOwned` profiles still need a storage choice, leave `ProfileStore.loadFileBasedStorage` but stop surfacing it as a CC-related toggle.)

```bash
grep -rn "fileBasedStorage" Climeter/   # must be empty (or only selfOwned-scoped) before deleting
```

- [ ] **Step 4: Build the app target** (UI has no unit tests here):
```bash
xcodebuild build -project Climeter.xcodeproj -scheme Climeter -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Climeter/SettingsView.swift Climeter/PopoverView.swift Climeter/ProfileManager.swift
git commit -m "ui: remove file-storage toggle and Claude Activate button"
```

---

## Task 8: Stale indicator

**Files:** `Climeter/PopoverView.swift`, `Climeter/MenuBarIcon.swift`

- [ ] **Step 1: Surface staleness.** The coordinator now publishes `isStale`. Expose it on `ProfileManager` (e.g. `@Published var allStale: [UUID: Bool]`, fed by a `coordinator.$isStale` sink alongside the existing sinks in `setupCoordinator:497-513`).

- [ ] **Step 2: Popover.** In `PopoverView.swift`, where usage + "updated" time render, when `allStale[id] == true` OR `allLastSuccess[id]` is older than 10 minutes, show `"Updated \(relative) ago — waiting for Claude Code"` and a **Retry** button calling `profileManager.refresh()`.

- [ ] **Step 3: Menu bar.** In `MenuBarIcon.swift`, when the CLI-active profile is stale, render the glyph dimmed (e.g., reduce opacity) so staleness is visible without opening the popover.

- [ ] **Step 4: Build**
```bash
xcodebuild build -project Climeter.xcodeproj -scheme Climeter -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**
```bash
git add Climeter/PopoverView.swift Climeter/MenuBarIcon.swift Climeter/ProfileManager.swift
git commit -m "ui: stale indicator (menu bar dim + popover retry)"
```

---

## Task 9: Full suite + grep guard

- [ ] **Step 1: Guard test — no Claude Code store mutation remains.** Create `ClimeterTests/NoCCMutationGuardTests.swift` is not feasible at runtime; instead add a source grep to the plan's verification:
```bash
grep -rn "writeCLICredential\|\.credentials.json\"" Climeter/ \
  | grep -v "climeter-bak" \
  | grep -v "performReadOnlyMigration"
```
Expected: **no output** (no remaining write paths or file-credential reads).

- [ ] **Step 2: Run full suite**
```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' -only-testing:ClimeterTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit any test-support tweaks**, then this task is done.

---

## Task 10: Manual verification (real behavior)

Automated tests can't prove the macOS Keychain/login behavior. Do this on the dev machine:

- [ ] **Step 1:** Build & run the app from this branch.
- [ ] **Step 2:** Note the current keychain `mdat`:
```bash
security find-generic-password -s "Claude Code-credentials" 2>&1 | grep mdat
```
- [ ] **Step 3:** Confirm the stale file got backed up:
```bash
ls -la ~/.claude/.credentials.json.climeter-bak 2>/dev/null && \
  (test ! -e ~/.claude/.credentials.json && echo "original removed: OK")
```
- [ ] **Step 4:** `/login` once in Claude Code. Then leave both running ~10 min and confirm Climeter shows usage (grant "Always Allow" if prompted).
- [ ] **Step 5:** After several hours of use, re-check keychain `mdat` and Climeter logs:
```bash
grep -hE "refreshToken: POST|invalid_grant" ~/Library/Logs/Climeter/climeter.log | tail
```
Expected: **no** `refreshToken: POST` from Climeter for the CLI profile, **no** `invalid_grant`, and Claude Code does **not** prompt for `/login` the next day.

- [ ] **Step 6:** Open a PR (only when the user asks).

---

## Self-Review (completed by author)

- **Spec coverage:** sites A–E → Tasks 4/5/6; CredentialSource → Task 1; in-memory tokens → Task 6.6; rare reads/backoff → Tasks 4/5; ignore file → Task 4; rename stale file → Task 6.7; toggle removal → Task 7; stale UX → Task 8; ACL probe → Task 4 (`interactive:`); tests 1–10 → Tasks 1/3/5/6/9. All spec sections mapped.
- **Placeholder scan:** UsageData.empty fixture flagged with explicit instruction to match the real schema (read `UsageData.swift`); no other placeholders.
- **Type consistency:** `CLIRefreshAction` cases, `readCLICredential(interactive:)`, `credentialSource`, `isExpired(now:)`, `onCredentialCached`, `performReadOnlyMigration` used consistently across tasks.
