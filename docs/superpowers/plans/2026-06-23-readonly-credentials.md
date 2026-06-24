# Read-Only Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Climeter a strictly read-only consumer of Claude Code's Keychain credential so it never rotates the shared OAuth refresh token (which breaks `/login`) and never goes permanently stale.

**Architecture:** Add a persisted `CredentialSource` (`cliSynced` vs `selfOwned`) on `Profile`. For `cliSynced` profiles, the per-poll decision lives in a **pure function** (`CLICredentialPolicy`) that can only return *fetch / reread-keychain / show-stale* — never *refresh*, never *write*. `UsageRefreshCoordinator` gains a `readOnly` mode with injected closures (keychain reader, usage fetcher) so the never-refresh invariant is unit-testable. Every Claude-Code-store mutation is removed. `cliSynced` tokens live **in memory only**; disk holds non-secret metadata + an authenticated marker. The `~/.claude/.credentials.json` path is abandoned on macOS.

**Tech Stack:** Swift 5, SwiftUI, XCTest, macOS Keychain (Security framework), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-06-23-readonly-credentials-design.md`

**Test command (use everywhere):**
```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' -only-testing:ClimeterTests 2>&1 | tail -30
```
Single test: append `-only-testing:ClimeterTests/<Class>/<method>`.
Build only: `xcodebuild build -project Climeter.xcodeproj -scheme Climeter -destination 'platform=macOS' 2>&1 | tail -15`.

---

## Complete inventory of sites to remove/gate (verified against source)

Every one of these MUST be addressed or the bug returns. Tasks reference these IDs.

| ID | Site | Current behavior | Required change |
|----|------|------------------|-----------------|
| A1 | `UsageRefreshCoordinator.recoverCredential:145` | refresh on expiry | not reached in readOnly mode |
| A2 | `UsageRefreshCoordinator.recoverCredential:164` | refresh CLI fallback | dead (`syncCLICredential` always nil) → remove |
| B  | `ProfileManager.identifyAndSyncAccount:219` | `refreshToken` on launch/wake | remove; no refresh |
| C  | `ProfileManager.setupCoordinator:484` `onCredentialRefreshed` | `writeCLICredential` to CC | readOnly: never write CC |
| D1 | `ProfileManager.activateForCLI:568` | `writeCLICredential` to CC | remove the write |
| D2 | `ProfileManager.checkAutoSwitch:549` → `activateForCLI` | switches CC account | gate to `selfOwned` (dead until paste-UI) |
| E  | `ProfileManager.migrateCredentialStorage:386` | `writeCLICredential` to CC file | remove block |
| P1 | `ProfileManager.saveAndActivate:288` | `saveCredentialModel` (secret→disk) | cliSynced: metadata only |
| P2 | `ProfileManager.identifyAndSyncAccount:261` | `saveCredentialModel` (secret→disk) | cliSynced: metadata only |
| P3 | `ProfileManager.backfillAccountUUIDs:323` | `saveCredentialModel` (secret→disk) | cliSynced: metadata only |
| R1 | `ProfileManager.detectCLIAccountChange:183` | `readCLICredential(preferFile:)` | `readCLICredential(interactive:false)` |
| R2 | `ProfileManager.startCLIMonitoring:169` | 30s keychain poll timer | remove timer |

> Re-verify before finishing: `grep -rn "refreshToken(\|writeCLICredential\|saveCredentialModel" Climeter/` — every hit must be in a `selfOwned` branch or removed.

---

## File Structure

| File | Change |
|------|--------|
| `Climeter/Profile.swift` | add persisted `credentialSource` |
| `Climeter/Credential.swift` | `isExpired(now:)`; `Equatable` (all fields) |
| `Climeter/CLICredentialPolicy.swift` | **NEW** pure decision |
| `Climeter/ClaudeCodeSyncService.swift` | keychain-read-only; `interactive:` probe; `keychainItemExists()` |
| `Climeter/UsageRefreshCoordinator.swift` | readOnly mode, injected closures, stale, 401 re-read |
| `Climeter/ProfileManager.swift` | remove A–E; gate P1–P3; R1–R2; cold-launch marker; migration |
| `Climeter/ProfileStore.swift` | account metadata + authenticated marker; scope file-toggle |
| `Climeter/SettingsView.swift`, `PopoverView.swift`, `MenuBarIcon.swift` | UI: remove toggle/Activate; stale indicator |
| `ClimeterTests/*` | new policy/coordinator/migration tests; delete obsolete file-read tests |

---

## Task 0: Baseline

- [ ] **Step 1:** Run the full test command. Expected `** TEST SUCCEEDED **`. If red, stop and report.

---

## Task 1: `CredentialSource` on Profile

**Files:** `Climeter/Profile.swift`; Test `ClimeterTests/ProfileCodableTests.swift` (create)

- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import Climeter

final class ProfileCodableTests: XCTestCase {
    func test_defaultSourceIsCLISynced() {
        XCTAssertEqual(Profile(name: "X").credentialSource, .cliSynced)
    }
    func test_legacyProfileWithoutSourceDefaultsToCLISynced() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: legacy).credentialSource, .cliSynced)
    }
    func test_roundTripPreservesSelfOwned() throws {
        var p = Profile(name: "Manual"); p.credentialSource = .selfOwned
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.credentialSource, .selfOwned)
    }
}
```
- [ ] **Step 2:** Run the class → fails (unknown member).
- [ ] **Step 3: Implement** — replace `Climeter/Profile.swift`:
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
    // CodingKeys + encode(to:) remain auto-synthesized; do NOT add a manual CodingKeys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        credentialSource = try c.decodeIfPresent(CredentialSource.self, forKey: .credentialSource) ?? .cliSynced
    }
}
```
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5: Commit** `feat: add CredentialSource to Profile (defaults cliSynced)`

---

## Task 2: Injectable expiry + full Equatable on `Credential`

**Files:** `Climeter/Credential.swift`; Test `ClimeterTests/CredentialExpiryTests.swift` (create)

- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import Climeter

final class CredentialExpiryTests: XCTestCase {
    private func cred(_ millis: Double) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(millis)}}"#)!
    }
    func test_notExpiredFarFuture() {
        XCTAssertFalse(cred(9_000_000 * 1000).isExpired(now: Date(timeIntervalSince1970: 1000)))
    }
    func test_expiredWithinFiveMinuteMargin() {
        // expires 4 min after now -> expired (5-min safety margin)
        XCTAssertTrue(cred((1000 + 240) * 1000).isExpired(now: Date(timeIntervalSince1970: 1000)))
    }
    func test_equalityIncludesAccountUUID() {
        let a = Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":1000,"accountUUID":"A"}}"#)!
        let b = Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":1000,"accountUUID":"B"}}"#)!
        XCTAssertNotEqual(a, b)
    }
}
```
- [ ] **Step 2:** Run → fails.
- [ ] **Step 3: Implement** — in `Climeter/Credential.swift`, replace the `isExpired` computed property with:
```swift
    func isExpired(now: Date) -> Bool { expiresAt < now.addingTimeInterval(5 * 60) }
    var isExpired: Bool { isExpired(now: Date.now) }
```
and add at end of file (compare ALL stored fields, incl. account identity):
```swift
extension Credential: Equatable {
    static func == (l: Credential, r: Credential) -> Bool {
        l.accessToken == r.accessToken && l.refreshToken == r.refreshToken &&
        l.expiresAt == r.expiresAt && l.subscriptionType == r.subscriptionType &&
        l.rateLimitTier == r.rateLimitTier && l.accountUUID == r.accountUUID
    }
}
```
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5: Commit** `feat: injectable Credential.isExpired(now:) + full Equatable`

---

## Task 3: Pure poll-decision policy

**Files:** `Climeter/CLICredentialPolicy.swift` (create); Test `ClimeterTests/CLICredentialPolicyTests.swift` (create)

- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import Climeter

final class CLICredentialPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func cred(_ secsFromNow: Double, _ token: String) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":\#((10_000 + secsFromNow) * 1000)}}"#)!
    }
    func test_cachedValid_fetchesCached() {
        let c = cred(3600, "cached")
        XCTAssertEqual(CLICredentialPolicy.action(cached: c, keychain: nil, now: now), .fetchUsage(c))
    }
    func test_cachedExpired_noKeychainYet_rereads() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: nil, now: now), .rereadKeychain)
    }
    func test_cachedExpired_keychainFresh_fetchAndCache() {
        let fresh = cred(3600, "fresh")
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: fresh, now: now), .fetchUsageAndCache(fresh))
    }
    func test_bothExpired_stale() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: cred(60, "old2"), now: now), .showStale)
    }
    func test_noCached_keychainFresh_fetchAndCache() {
        let fresh = cred(3600, "fresh")
        XCTAssertEqual(CLICredentialPolicy.action(cached: nil, keychain: fresh, now: now), .fetchUsageAndCache(fresh))
    }
    func test_noCached_noKeychain_rereads() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: nil, keychain: nil, now: now), .rereadKeychain)
    }
}
```
- [ ] **Step 2:** Run → fails.
- [ ] **Step 3: Implement** `Climeter/CLICredentialPolicy.swift`:
```swift
import Foundation

/// Pure decision for a read-only (cliSynced) profile's poll cycle.
/// Deliberately NO `refresh` case — Climeter must never rotate the shared token.
enum CLIRefreshAction: Equatable {
    case fetchUsage(Credential)          // cached access token still valid
    case fetchUsageAndCache(Credential)  // use freshly-read keychain token, update cache
    case rereadKeychain                  // need a keychain read to decide
    case showStale                       // nothing usable; keep last usage, mark stale
}

enum CLICredentialPolicy {
    static func action(cached: Credential?, keychain: Credential?, now: Date) -> CLIRefreshAction {
        if let cached, !cached.isExpired(now: now) { return .fetchUsage(cached) }
        guard let keychain else { return .rereadKeychain }
        return keychain.isExpired(now: now) ? .showStale : .fetchUsageAndCache(keychain)
    }
}
```
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5: Commit** `feat: pure CLICredentialPolicy with no refresh path`

---

## Task 4: `ClaudeCodeSyncService` — keychain-read-only

**Files:** `Climeter/ClaudeCodeSyncService.swift`; delete `ClimeterTests/CLISyncFileReadTests.swift`; Test `ClimeterTests/ClaudeCodeSyncServiceTests.swift` (create)

> Tasks 4 and 5 add NEW code without deleting callers yet, so the project still
> compiles after each. Task 6 removes the old `ProfileManager` usages. To keep Task 4
> green, **keep the old methods as thin deprecated shims** that the new code/tests
> ignore; Task 6 deletes them. (Avoids an un-compilable intermediate — reviewer M8.)

- [ ] **Step 1:** `git rm ClimeterTests/CLISyncFileReadTests.swift`
- [ ] **Step 2: Failing test**
```swift
import XCTest
@testable import Climeter

final class ClaudeCodeSyncServiceTests: XCTestCase {
    func test_credentialFromRawParses() {
        let raw = #"{"claudeAiOauth":{"accessToken":"kc","refreshToken":"r","expiresAt":1700000000000}}"#
        XCTAssertEqual(ClaudeCodeSyncService.credential(fromRaw: raw)?.accessToken, "kc")
    }
    func test_credentialFromRawNilForGarbage() {
        XCTAssertNil(ClaudeCodeSyncService.credential(fromRaw: "nope"))
    }
}
```
- [ ] **Step 3:** Run → fails (`credential(fromRaw:)` unknown).
- [ ] **Step 4: Implement** — add the new read-only surface to `ClaudeCodeSyncService` (keep old `readCLICredential(preferFile:)`/`writeCLICredential` as `@available(*, deprecated)` shims until Task 6):
```swift
    static func credential(fromRaw raw: String) -> Credential? {
        let c = Credential(jsonString: raw)
        if c == nil { Log.cliSync.warning("Keychain data parsed-fail as Credential") }
        return c
    }

    /// Read-only. interactive=false uses kSecUseAuthenticationUIFail (never prompts).
    static func readCLICredential(interactive: Bool) -> Credential? {
        guard let raw = readCLICredentialRaw(interactive: interactive) else { return nil }
        return credential(fromRaw: raw)
    }

    static func readCLICredentialRaw(interactive: Bool) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        Log.cliSync.info("readCLICredential(interactive=\(interactive)): \(Log.keychainStatus(status))")
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// True iff the Keychain item exists & is readable (used to guard file backup).
    static func keychainItemExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName, kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
```
- [ ] **Step 5:** Run the suite → green (old shims keep callers compiling).
- [ ] **Step 6: Commit** `feat: keychain-read-only API on ClaudeCodeSyncService`

---

## Task 5: `UsageRefreshCoordinator` — readOnly mode

**Files:** `Climeter/UsageRefreshCoordinator.swift`; Test `ClimeterTests/UsageRefreshCoordinatorReadOnlyTests.swift` (create)

- [ ] **Step 1: Failing tests** (never-refresh + stale + 401 re-read)
```swift
import XCTest
@testable import Climeter

@MainActor
final class UsageRefreshCoordinatorReadOnlyTests: XCTestCase {
    private func cred(_ secs: Double, _ t: String) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"\#(t)","refreshToken":"r","expiresAt":\#((Date.now.timeIntervalSince1970 + secs) * 1000)}}"#)!
    }
    private func make(cached: Credential?, keychain: @escaping () -> Credential?,
                      fetch: @escaping (Credential) async throws -> UsageData,
                      refresh: @escaping (Credential) async throws -> Credential) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(profileID: UUID(), readOnly: true,
            credentialProvider: { cached }, keychainReader: keychain,
            onCredentialCached: { _ in }, onAutoStart: nil,
            usageFetcher: fetch, refresher: refresh)
    }
    func test_expiredCached_freshKeychain_fetchesNoRefresh() async {
        var refreshed = false; var token: String?
        let c = make(cached: cred(60, "old"), keychain: { self.cred(3600, "fresh") },
            fetch: { token = $0.accessToken; return .empty },
            refresh: { _ in refreshed = true; throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        XCTAssertFalse(refreshed); XCTAssertEqual(token, "fresh")
    }
    func test_bothExpired_staleNoRefreshNoFetch() async {
        var refreshed = false; var fetched = false
        let c = make(cached: cred(60, "old"), keychain: { self.cred(60, "old2") },
            fetch: { _ in fetched = true; return .empty },
            refresh: { _ in refreshed = true; throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        XCTAssertFalse(refreshed); XCTAssertFalse(fetched); XCTAssertTrue(c.isStale)
    }
    func test_401_rereadsKeychainOnce_noRefresh() async {
        var refreshed = false; var reads = 0; var calls = 0
        let c = make(cached: cred(3600, "cachedValid"), keychain: { reads += 1; return self.cred(3600, "fromKeychain") },
            fetch: { _ in calls += 1; if calls == 1 { throw ClaudeAPIError.httpError(401) }; return .empty },
            refresh: { _ in refreshed = true; throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)         // never refresh on 401 in readOnly
        XCTAssertEqual(reads, 1)          // re-read keychain exactly once
        XCTAssertEqual(calls, 2)          // retried fetch with keychain token
    }
}

extension UsageData {
    static var empty: UsageData {
        try! JSONDecoder().decode(UsageData.self, from: Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":0}}"#.utf8))
    }
}
```
> If `UsageData.empty` fails to decode, open `Climeter/UsageData.swift`, read the real
> `CodingKeys`, and adjust the JSON to the actual schema. Do not invent fields.

- [ ] **Step 2:** Run → fails.
- [ ] **Step 3: Implement.** Add stored properties and a designated initializer; keep the existing initializer as a convenience that delegates with `readOnly:false`.

New stored properties:
```swift
    let readOnly: Bool
    private let keychainReader: (() -> Credential?)?
    private let onCredentialCached: ((Credential) -> Void)?
    private let usageFetcher: (Credential) async throws -> UsageData
    private let refresher: (Credential) async throws -> Credential
    @Published var isStale: Bool = false
```
Designated initializer (preserve `onAutoStart`; drop the dead `syncCLICredential`):
```swift
    init(profileID: UUID,
         readOnly: Bool,
         credentialProvider: @escaping () -> Credential?,
         keychainReader: (() -> Credential?)? = nil,
         onCredentialRefreshed: ((Credential) -> Void)? = nil,
         onCredentialCached: ((Credential) -> Void)? = nil,
         onAutoStart: ((Credential) -> Void)? = nil,
         usageFetcher: @escaping (Credential) async throws -> UsageData = ClaudeAPIService.fetchUsage,
         refresher: @escaping (Credential) async throws -> Credential = ClaudeAPIService.refreshToken) {
        self.profileID = profileID
        self.readOnly = readOnly
        self.credentialProvider = credentialProvider
        self.keychainReader = keychainReader
        self.onCredentialRefreshed = onCredentialRefreshed
        self.onCredentialCached = onCredentialCached
        self.onAutoStart = onAutoStart
        self.usageFetcher = usageFetcher
        self.refresher = refresher
    }
```
> Note `ClaudeAPIService.fetchUsage`/`refreshToken` are static `async throws` funcs whose
> signatures match the closure types, so they can be used as default values directly.

At the top of `refresh()`:
```swift
        if readOnly { activeTask = Task { @MainActor in await self.runReadOnlyCycle() }; return }
```
Read-only engine (uses `usageFetcher`; never `refresher`):
```swift
    func refreshForTest() async { await runReadOnlyCycle() }   // test seam

    @MainActor
    private func runReadOnlyCycle() async {
        let cached = credentialProvider()
        var action = CLICredentialPolicy.action(cached: cached, keychain: nil, now: Date.now)
        if action == .rereadKeychain {
            action = CLICredentialPolicy.action(cached: cached, keychain: keychainReader?(), now: Date.now)
        }
        switch action {
        case .fetchUsage(let c):          await fetchReadOnly(c, fromKeychain: false)
        case .fetchUsageAndCache(let c):  onCredentialCached?(c); await fetchReadOnly(c, fromKeychain: true)
        case .rereadKeychain, .showStale: isStale = true
        }
    }

    @MainActor
    private func fetchReadOnly(_ credential: Credential, fromKeychain: Bool) async {
        do {
            let data = try await usageFetcher(credential)
            publishSuccess(data, credential: credential, fromKeychain: fromKeychain)
        } catch ClaudeAPIError.httpError(401) {
            // Spec: on 401, re-read Keychain ONCE; retry if token changed; never refresh.
            guard let kc = keychainReader?(), kc != credential, !kc.isExpired else { isStale = true; return }
            onCredentialCached?(kc)
            if let data = try? await usageFetcher(kc) {
                publishSuccess(data, credential: kc, fromKeychain: true)
            } else { isStale = true }
        } catch {
            isStale = true
            if usageData == nil { errorMessage = Self.describeError(error, context: "fetch") }
        }
    }

    @MainActor
    private func publishSuccess(_ data: UsageData, credential: Credential, fromKeychain: Bool) {
        usageData = data; errorMessage = nil; lastSuccessAt = Date(); isStale = false
        // Auto-start only with a FRESH keychain token (spec §8), never a cached one.
        if fromKeychain { checkAutoStart(credential: credential, usage: data) }
        stepDownBackoff()
    }
```
Remove `recoverCredential`'s `syncCLICredential?()` branch (A2, dead) and the
`syncCLICredential` parameter.

- [ ] **Step 4:** Run → pass (the existing convenience initializer keeps `ProfileManager` compiling because we kept `onCredentialRefreshed`; the old call site passes `readOnly:false` once updated in Task 6 — until then, add `readOnly:false` to the existing init by giving the OLD initializer signature a default? No: update the single call site now). **Update `ProfileManager.setupCoordinator` minimally here** only to add `readOnly: false` so it compiles; full rewrite is Task 6.
- [ ] **Step 5: Commit** `feat: read-only mode + 401 re-read in UsageRefreshCoordinator`

---

## Task 6: `ProfileManager` — remove A–E, gate P1–P3, R1–R2, migration

**Files:** `Climeter/ProfileManager.swift`, `Climeter/ProfileStore.swift`; extend `ClimeterTests/ProfileManagerMigrationTests.swift`

- [ ] **Step 1: ProfileStore — metadata + authenticated marker.** Add to `ProfileStore`:
```swift
    private static let accountMetaKey = "accountMeta"          // [uuid:[field:val]]
    private static let authenticatedKey = "authenticatedProfiles" // [uuidString]

    static func saveAccountMetadata(_ cred: Credential, for id: UUID) {
        var dict = defaults.dictionary(forKey: accountMetaKey) as? [String: [String: String]] ?? [:]
        var e = dict[id.uuidString] ?? [:]
        if let v = cred.accountUUID { e["uuid"] = v }
        if let v = cred.subscriptionType { e["subscriptionType"] = v }
        if let v = cred.rateLimitTier { e["rateLimitTier"] = v }
        dict[id.uuidString] = e; defaults.set(dict, forKey: accountMetaKey)
        markAuthenticated(id)
    }
    static func accountUUID(for id: UUID) -> String? {
        (defaults.dictionary(forKey: accountMetaKey) as? [String: [String: String]])?[id.uuidString]?["uuid"]
    }
    static func markAuthenticated(_ id: UUID) {
        var s = Set(defaults.stringArray(forKey: authenticatedKey) ?? [])
        s.insert(id.uuidString); defaults.set(Array(s), forKey: authenticatedKey)
    }
    static func clearAuthenticated(_ id: UUID) {
        var s = Set(defaults.stringArray(forKey: authenticatedKey) ?? [])
        s.remove(id.uuidString); defaults.set(Array(s), forKey: authenticatedKey)
    }
    static func authenticatedMarkers() -> Set<UUID> {
        Set((defaults.stringArray(forKey: authenticatedKey) ?? []).compactMap(UUID.init))
    }
```

- [ ] **Step 2: Helper to persist a cliSynced credential safely (metadata only).** Add a private method in `ProfileManager`:
```swift
    /// cliSynced: keep token in memory only; persist metadata + authenticated marker.
    /// selfOwned: persist the secret as before.
    private func persistCredential(_ cred: Credential, for id: UUID) {
        let source = profiles.first { $0.id == id }?.credentialSource ?? .cliSynced
        cachedCredentials[id] = cred
        if source == .selfOwned {
            try? ProfileStore.saveCredentialModel(cred, for: id)
        } else {
            ProfileStore.saveAccountMetadata(cred, for: id)
        }
    }
```
Now replace **every** `try? ProfileStore.saveCredentialModel(...)` for CLI credentials with `persistCredential(...)`:
  - **P1** `saveAndActivate:288` → `persistCredential(credential, for: profileID)` (drop the direct `cachedCredentials[...] =` + `saveCredentialModel`).
  - **P2** `identifyAndSyncAccount:260-261` (UUID-resolution loop) → `persistCredential(updated, for: profile.id)`.
  - **P3** `backfillAccountUUIDs:322-323` → `persistCredential(updated, for: profile.id)`.

- [ ] **Step 3: B — no refresh in identifyAndSyncAccount.** Delete `:216-222` (the `isExpired`→`refreshToken` block). If the token is expired, proceed to `fetchProfile` anyway; on failure, return (next scheduled keychain read retries). No refresh.

- [ ] **Step 4: Cold-launch — `refreshAuthenticatedIDs` honors markers.** Replace `:121-134` so a profile counts as authenticated if it has a persisted secret (selfOwned) OR an authenticated marker (cliSynced):
```swift
    private func refreshAuthenticatedIDs() {
        var cache: [UUID: Credential] = [:]
        for p in profiles {
            if let c = ProfileStore.loadCredentialModel(for: p.id) { cache[p.id] = c }
            else if let existing = cachedCredentials[p.id] { cache[p.id] = existing }
        }
        cachedCredentials = cache
        authenticatedProfileIDs = Set(cache.keys).union(ProfileStore.authenticatedMarkers())
    }
```
> Coordinators for cliSynced profiles start without an in-memory token; the first
> `runReadOnlyCycle` reads the keychain and populates it.

- [ ] **Step 5: C + setupCoordinator full rewrite (both branches).** Replace the coordinator construction in `setupCoordinator:471-495` with:
```swift
        let source = profiles.first { $0.id == profileID }?.credentialSource ?? .cliSynced
        let coordinator: UsageRefreshCoordinator
        if source == .cliSynced {
            coordinator = UsageRefreshCoordinator(
                profileID: profileID, readOnly: true,
                credentialProvider: { [weak self] in self?.cachedCredentials[profileID] },
                keychainReader: { ClaudeCodeSyncService.readCLICredential(interactive: false) },
                onCredentialCached: { [weak self] c in self?.cachedCredentials[profileID] = c },
                onAutoStart: { [weak self] credential in
                    guard let self, self.claudeEnabled, self.cliActiveProfileID == profileID else { return }
                    self.autoStartTask?.cancel()
                    self.autoStartTask = Task { await ClaudeAPIService.startSession(credential: credential) }
                })
        } else {
            coordinator = UsageRefreshCoordinator(
                profileID: profileID, readOnly: false,
                credentialProvider: { [weak self] in self?.cachedCredentials[profileID] },
                onCredentialRefreshed: { [weak self] refreshed in            // selfOwned only
                    guard self?.claudeEnabled == true else { return }
                    self?.cachedCredentials[profileID] = refreshed
                    try? ProfileStore.saveCredentialModel(refreshed, for: profileID)
                },                                                            // NB: never writes CC store
                onAutoStart: { [weak self] credential in
                    guard let self, self.claudeEnabled, self.cliActiveProfileID == profileID else { return }
                    self.autoStartTask?.cancel()
                    self.autoStartTask = Task { await ClaudeAPIService.startSession(credential: credential) }
                })
        }
```
Keep the existing `$usageData/$errorMessage/$lastSuccessAt` sinks; add an `$isStale` sink (Task 8).

- [ ] **Step 6: D1 + D2.** Rewrite `activateForCLI:565-571` (no CC write):
```swift
    func activateForCLI(profileID: UUID) {
        // Climeter no longer switches Claude Code's active account (that wrote CC's
        // keychain). Switch accounts inside Claude Code; Climeter follows via §5.
        cliActiveProfileID = profileID
        ProfileStore.saveCLIActiveProfileID(profileID)
    }
```
In `checkAutoSwitch:540-544`, restrict candidates to `selfOwned` (auto-switch can no
longer flip CC's account; effectively dead until a paste-key UI exists):
```swift
        let candidate = profiles.first { p in
            p.id != activeID && p.credentialSource == .selfOwned
                && authenticatedProfileIDs.contains(p.id)
                && (allUsageData[p.id]?.fiveHour.utilization ?? 100) < autoSwitchThreshold
        }
```

- [ ] **Step 7: E.** Delete the `:383-387` block that calls `writeCLICredential(..., preferFile:true)`.

- [ ] **Step 8: R1 + R2.** In `startCLIMonitoring:164-172` delete the 30s `cliMonitorTimer` repeat (keep the one-shot launch check). In `detectCLIAccountChange:179-187` change the read to `ClaudeCodeSyncService.readCLICredential(interactive: false)` (drop `preferFile`). Account-switch matching already happens in `processCLICredential`/`identifyAndSyncAccount` by `accountUUID`; this stays intact so the read-only path attaches usage to the correct profile (reviewer: account-match). Also call `detectCLIAccountChange()` from `resumeAfterWake` (already present).

- [ ] **Step 9: Migration on upgrade (pure helper + caller).** Add:
```swift
    static func performReadOnlyMigration(
        keychainExists: Bool,
        fileURL: URL,
        backupURL: URL,
        fileExists: (URL) -> Bool,
        moveFile: (URL, URL) -> Void,
        profiles: [Profile],
        hasStoredSecret: (UUID) -> Bool,
        purgeSecret: (UUID) -> Void,
        markAuthenticated: (UUID) -> Void
    ) -> [Profile] {
        // 1. Back up the stale CC file ONLY when the Keychain is the real store.
        if keychainExists, fileExists(fileURL) { moveFile(fileURL, backupURL) }
        // 2. All existing profiles are cliSynced (no paste-key UI exists yet).
        var updated = profiles
        for i in updated.indices {
            updated[i].credentialSource = .cliSynced
            // Preserve "authenticated" across the secret purge.
            if hasStoredSecret(updated[i].id) { markAuthenticated(updated[i].id) }
            purgeSecret(updated[i].id)   // remove any on-disk cliSynced token
        }
        return updated
    }
```
Call once early in `init()` (before `setupAllCoordinators`), wiring real closures:
`keychainExists: ClaudeCodeSyncService.keychainItemExists()`,
`fileURL/backupURL` under `FileManager.default.homeDirectoryForCurrentUser/.claude`,
`fileExists: { FileManager.default.fileExists(atPath: $0.path) }`,
`moveFile: { try? FileManager.default.moveItem(at: $0, to: $1) }`,
`hasStoredSecret: { ProfileStore.loadCredentialModel(for: $0) != nil }`,
`purgeSecret: { try? ProfileStore.deleteCredential(for: $0) }`,
`markAuthenticated: ProfileStore.markAuthenticated`. Save the returned profiles via
`ProfileStore.saveProfiles` and guard with a one-time `UserDefaults` flag
(`readOnlyMigrationDone`) so it runs once.

- [ ] **Step 10: Tests** — extend `ProfileManagerMigrationTests`:
```swift
    func test_migrationBacksUpFileOnlyWhenKeychainExists() {
        var moved: (URL, URL)?
        let p = [Profile(name: "A")]
        _ = ProfileManager.performReadOnlyMigration(
            keychainExists: true, fileURL: URL(fileURLWithPath: "/h/.claude/.credentials.json"),
            backupURL: URL(fileURLWithPath: "/h/.claude/.credentials.json.climeter-bak"),
            fileExists: { _ in true }, moveFile: { s, d in moved = (s, d) },
            profiles: p, hasStoredSecret: { _ in false }, purgeSecret: { _ in }, markAuthenticated: { _ in })
        XCTAssertEqual(moved?.1.lastPathComponent, ".credentials.json.climeter-bak")
    }
    func test_migrationLeavesFileWhenNoKeychain() {
        var moved = false
        _ = ProfileManager.performReadOnlyMigration(
            keychainExists: false, fileURL: URL(fileURLWithPath: "/h/x"), backupURL: URL(fileURLWithPath: "/h/y"),
            fileExists: { _ in true }, moveFile: { _, _ in moved = true },
            profiles: [], hasStoredSecret: { _ in false }, purgeSecret: { _ in }, markAuthenticated: { _ in })
        XCTAssertFalse(moved)
    }
    func test_migrationMarksAllCliSyncedAndPreservesAuth() {
        let withSecret = Profile(name: "S"); let without = Profile(name: "N")
        var marked: [UUID] = []; var purged: [UUID] = []
        let out = ProfileManager.performReadOnlyMigration(
            keychainExists: true, fileURL: URL(fileURLWithPath: "/h/x"), backupURL: URL(fileURLWithPath: "/h/y"),
            fileExists: { _ in false }, moveFile: { _, _ in },
            profiles: [withSecret, without],
            hasStoredSecret: { $0 == withSecret.id }, purgeSecret: { purged.append($0) }, markAuthenticated: { marked.append($0) })
        XCTAssertTrue(out.allSatisfy { $0.credentialSource == .cliSynced })
        XCTAssertEqual(marked, [withSecret.id])
        XCTAssertEqual(Set(purged), Set([withSecret.id, without.id]))
    }
```

- [ ] **Step 11: Remove the deprecated shims** in `ClaudeCodeSyncService` (old `readCLICredential(preferFile:)`, `writeCLICredential*`, file helpers, `makeSharedAccess`, `cliCredentialFileExists`) now that `ProfileManager` no longer calls them.

- [ ] **Step 12: Compile + run the WHOLE suite.** Fix any residual references until `** TEST SUCCEEDED **`.

- [ ] **Step 13: Grep guard** — expect NO output except `selfOwned` branches:
```bash
grep -rn "refreshToken(\|writeCLICredential\|readCLICredentialFromFile\|cliCredentialFileExists\|\.credentials.json\"" Climeter/ \
  | grep -v "climeter-bak\|performReadOnlyMigration\|selfOwned"
```

- [ ] **Step 14: Commit** `feat: read-only CLI sync — remove all CC store mutations + migration`

---

## Task 7: Settings & Popover UI

**Files:** `Climeter/SettingsView.swift`, `Climeter/PopoverView.swift`, `Climeter/ProfileManager.swift`, maybe delete `ClimeterTests/ProfileStoreStorageTests.swift`

- [ ] **Step 1:** Delete the `Section("Credential Storage")` block (`SettingsView.swift:27-46`). Change `:54` text to `"macOS Keychain via Claude Code (read-only)"`.
- [ ] **Step 2:** Remove the Activate buttons calling `activateForCLI` for Claude profiles: `SettingsView.swift:142`, `PopoverView.swift:76`.
- [ ] **Step 3:** Grep `grep -rn "fileBasedStorage" Climeter/`. If only the now-dead `@Published var fileBasedStorage` + `migrateCredentialStorage(toFileBased:)` remain, delete them (`ProfileManager.swift:50-55` and the instance method) and the static `migrateCredentialStorage(...)` helper if unused. Keep `FileCredentialStore` for `selfOwned` storage via `ProfileStore`.
- [ ] **Step 4:** If `fileBasedStorage` is removed, also `git rm ClimeterTests/ProfileStoreStorageTests.swift` (it round-trips the removed key); otherwise leave it.
- [ ] **Step 5:** Build → `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** `ui: remove file-storage toggle and Claude Activate button`

---

## Task 8: Stale indicator

**Files:** `Climeter/ProfileManager.swift`, `Climeter/PopoverView.swift`, `Climeter/MenuBarIcon.swift`

- [ ] **Step 1:** Add `@Published var allStale: [UUID: Bool] = [:]`; in `setupCoordinator` add a sink: `coordinator.$isStale.receive(on: DispatchQueue.main).sink { [weak self] s in self?.allStale[profileID] = s }` (append to `cancellables[profileID]`).
- [ ] **Step 2:** In `PopoverView.swift`, when `allStale[id] == true` OR `allLastSuccess[id]` older than 10 min, show `"Updated <relative> ago — waiting for Claude Code"` + a **Retry** button calling `profileManager.refresh()`.
- [ ] **Step 3:** In `MenuBarIcon.swift`, dim the glyph (reduced opacity) when the CLI-active profile is stale.
- [ ] **Step 4:** Build → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `ui: stale indicator (menu bar dim + popover retry)`

---

## Task 9: Full suite + guard

- [ ] **Step 1:** Run the grep guard from Task 6 Step 13 → no unexpected output.
- [ ] **Step 2:** Full test command → `** TEST SUCCEEDED **`.
- [ ] **Step 3: Commit** any test-support tweaks.

---

## Task 10: Manual verification (real macOS behavior)

- [ ] **Step 1:** Build & run from this branch.
- [ ] **Step 2:** `security find-generic-password -s "Claude Code-credentials" 2>&1 | grep mdat` (note value).
- [ ] **Step 3:** Confirm backup + original removed (only if keychain existed):
```bash
ls -la ~/.claude/.credentials.json.climeter-bak 2>/dev/null
test ! -e ~/.claude/.credentials.json && echo "original removed: OK"
```
- [ ] **Step 4:** `/login` once in Claude Code; grant "Always Allow" if prompted; leave both running ~10 min; confirm usage shows.
- [ ] **Step 5:** After hours of use:
```bash
grep -hE "refreshToken: POST|invalid_grant" ~/Library/Logs/Climeter/climeter.log | tail
```
Expected: **no** `refreshToken: POST` for the CLI profile, **no** `invalid_grant`, and Claude Code does **not** force `/login` the next day.
- [ ] **Step 6:** Open a PR (only when the user asks).

---

## Self-Review (author)

- **All inventory IDs A1–E, P1–P3, R1–R2 → tasks:** A1/A2/401 → Task 5; B → 6.3; C → 6.5; D1/D2 → 6.6; E → 6.7; P1–P3 → 6.2; R1/R2 → 6.8. ✓
- **Reviewer blockers:** missed P2/P3 persistence (6.2), account-match retained (6.8), 401 re-read (Task 5 test+impl), all-cliSynced migration (6.9), cold-launch marker (6.1/6.4), explicit initializer & call sites (Task 5 + 6.5), Equatable all fields (Task 2), auto-start provenance (Task 5 `fromKeychain`), file-rename keychain guard (6.9). ✓
- **Compile integrity:** shims keep Tasks 4–5 green; Task 6 removes them (4.shims → 6.11). ✓
- **Placeholders:** only the `UsageData.empty` fixture, explicitly flagged to verify against the real schema. ✓
- **Type consistency:** `CLIRefreshAction`, `readCLICredential(interactive:)`, `keychainItemExists`, `credentialSource`, `persistCredential`, `performReadOnlyMigration`, `isExpired(now:)`, `onCredentialCached`, `allStale` used consistently. ✓
