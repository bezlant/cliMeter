# Claude Status-Line Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Climeter display Claude Pro/Max usage from Claude Code's sanitized status-line JSON without automatically reading `Claude Code-credentials`.

**Architecture:** A standalone shell exporter serializes and sanitizes Claude Code status-line updates into one owner-only Application Support file. A focused Swift store validates and polls that file. `ProfileManager` routes either to that store (the default) or to the existing Keychain coordinator only after the user explicitly selects compatibility mode.

**Tech Stack:** Swift 5, SwiftUI, Combine, XCTest, Bash, `jq`, macOS `/usr/bin/lockf`, Xcode 15+ project files.

## Global Constraints

- macOS deployment target remains 14.0.
- `statusLineFile` is the default Claude source.
- Status-line mode performs zero reads of `Claude Code-credentials`.
- No automatic fallback from the status-line file to Keychain is permitted.
- Exported data is restricted to schema version, timestamp, and the two rate-limit windows.
- The destination directory is mode `0700`; usage, lock, and temporary files are mode `0600`.
- Existing Codex behavior remains unchanged.
- Multi-account attribution remains deferred; one selected/default Claude profile receives the file snapshot.

---

### Task 1: Decode and Poll Sanitized Claude Usage

**Files:**
- Create: `Climeter/ClaudeStatusLineUsageStore.swift`
- Create: `ClimeterTests/ClaudeStatusLineUsageStoreTests.swift`
- Modify: `Climeter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: existing `UsageData` and `UsageWindow`.
- Produces: `ClaudeStatusLineUsageStore`, `ClaudeStatusLineUsageSnapshot`, and `ClaudeStatusLineUsageError`.

- [ ] **Step 1: Add failing decoder tests**

Create tests that use literal JSON fixtures and a temporary file:

```swift
final class ClaudeStatusLineUsageStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func test_refreshPublishesCompleteValidatedSnapshot() throws {
        let file = try temporaryUsageFile(#"""
        {
          "schema_version": 1,
          "updated_at": 1785290000,
          "rate_limits": {
            "five_hour": {"used_percentage": 23.5, "resets_at": 1785300000},
            "seven_day": {"used_percentage": 41.2, "resets_at": null}
          }
        }
        """#)
        let store = ClaudeStatusLineUsageStore(fileURL: file)

        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.usageData?.sevenDay.utilization, 41.2)
        XCTAssertEqual(store.lastSuccessAt, Date(timeIntervalSince1970: 1_785_290_000))
        XCTAssertNil(store.errorMessage)
    }

    func test_refreshRejectsFutureSchemaWithoutDiscardingLastGoodUsage() throws {
        let file = try temporaryUsageFile(validFixture)
        let store = ClaudeStatusLineUsageStore(fileURL: file)
        store.refresh()
        try Data(#"{"schema_version":2,"updated_at":1785290100,"rate_limits":{}}"#.utf8)
            .write(to: file, options: .atomic)

        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.errorMessage, "Climeter usage exporter needs an update.")
    }

    func test_refreshMergesPartialWindowsBeforePublishingUsage() throws {
        let file = try temporaryUsageFile(fiveHourOnlyFixture)
        let store = ClaudeStatusLineUsageStore(fileURL: file)
        store.refresh()
        XCTAssertNil(store.usageData)
        XCTAssertEqual(store.errorMessage, "Claude supplied partial usage; waiting for both windows.")

        try Data(sevenDayOnlyFixture.utf8).write(to: file, options: .atomic)
        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.usageData?.sevenDay.utilization, 41.2)
    }

    func test_refreshRejectsNonFiniteOrOutOfRangePercentages() throws {
        for value in ["-1", "101", "1e999"] {
            let file = try temporaryUsageFile(invalidFixture(percentage: value))
            let store = ClaudeStatusLineUsageStore(fileURL: file)
            store.refresh()
            XCTAssertNil(store.usageData)
            XCTAssertEqual(store.errorMessage, "Claude usage file is invalid.")
        }
    }
}

private extension ClaudeStatusLineUsageStoreTests {
    var validFixture: String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785300000},"seven_day":{"used_percentage":41.2,"resets_at":null}}}"#
    }

    var fiveHourOnlyFixture: String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785300000}}}"#
    }

    var sevenDayOnlyFixture: String {
        #"{"schema_version":1,"updated_at":1785290010,"rate_limits":{"seven_day":{"used_percentage":41.2,"resets_at":1785800000}}}"#
    }

    func invalidFixture(percentage: String) -> String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":\#(percentage),"resets_at":1785300000},"seven_day":{"used_percentage":41.2,"resets_at":1785800000}}}"#
    }

    func temporaryUsageFile(_ contents: String) throws -> URL {
        let file = temporaryDirectory.appendingPathComponent("claude-usage.json")
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }
}
```

The production change each test catches is respectively: wrong field mapping, accepting an incompatible exporter, dropping independently delivered windows, and accepting unsafe numeric values.

- [ ] **Step 2: Run the focused test target and confirm RED**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClaudeStatusLineUsageStoreTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `ClaudeStatusLineUsageStore` does not exist.

- [ ] **Step 3: Implement the minimal store**

Implement these public shapes:

```swift
enum ClaudeStatusLineUsageError: Error, Equatable {
    case missingFile
    case incompleteWindows
    case unsupportedSchema(Int)
    case invalidFile
}

struct ClaudeStatusLineUsageSnapshot {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let updatedAt: Date

    var usageData: UsageData? {
        guard let fiveHour, let sevenDay else { return nil }
        return UsageData(fiveHour: fiveHour, sevenDay: sevenDay)
    }
}

final class ClaudeStatusLineUsageStore: ObservableObject {
    @Published private(set) var usageData: UsageData?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var isStale = false

    static let pollInterval: TimeInterval = 1
    static let staleThreshold: TimeInterval = 10 * 60

    init(
        fileURL: URL = Self.defaultFileURL(),
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    )
    func startPolling()
    func stopPolling()
    func refresh(now: Date = .now)
    static func defaultFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
}
```

Decode `schema_version`, `updated_at`, and optional windows using private `Decodable` DTOs. Reject a percentage unless `isFinite && 0...100 ~= value`. Merge each valid incoming window with the prior in-memory snapshot, retain the last complete `UsageData` after malformed reads, and derive `lastSuccessAt` from `updated_at`, never read time. Map errors to these exact user-facing messages:

```swift
case .missingFile:
    "Open Claude Code and send one prompt to initialize usage."
case .incompleteWindows:
    "Claude supplied partial usage; waiting for both windows."
case .unsupportedSchema:
    "Climeter usage exporter needs an update."
case .invalidFile:
    "Claude usage file is invalid."
```

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run the command from Step 2. Expected: all `ClaudeStatusLineUsageStoreTests` pass with zero failures.

- [ ] **Step 5: Commit the store**

```bash
git add Climeter/ClaudeStatusLineUsageStore.swift \
  ClimeterTests/ClaudeStatusLineUsageStoreTests.swift \
  Climeter.xcodeproj/project.pbxproj
git commit -m "feat: read Claude usage from statusline file"
```

---

### Task 2: Export Rate Limits Safely Across Concurrent Claude Sessions

**Files:**
- Create: `scripts/claude-usage-export.sh`
- Create: `ClimeterTests/ClaudeUsageExporterTests.swift`
- Modify: `Climeter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Claude Code status-line JSON on standard input.
- Produces: `${CLIMETER_USAGE_DIR:-$HOME/Library/Application Support/Climeter}/claude-usage.json`.

- [ ] **Step 1: Add failing behavior tests for the real script**

Launch the script with `Process`, pass fixtures through standard input, and set `CLIMETER_USAGE_DIR` to a new temporary directory. Assert:

```swift
final class ClaudeUsageExporterTests: XCTestCase {
    private var directory: URL!

    private var usageFile: URL {
        directory.appendingPathComponent("claude-usage.json")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

func test_exporterWritesOnlyAllowlistedFieldsAndOwnerPermissions() throws {
    let input = #"""
    {
      "session_id":"session-secret",
      "prompt_id":"prompt-secret",
      "transcript_path":"/private/transcript",
      "oauth":{"accessToken":"do-not-copy"},
      "rate_limits":{
        "five_hour":{"used_percentage":20,"resets_at":1785300000},
        "seven_day":{"used_percentage":40,"resets_at":1785800000}
      }
    }
    """#

    try runExporter(input: input, directory: directory)

    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: usageFile)) as? [String: Any]
    )
    XCTAssertEqual(Set(object.keys), ["schema_version", "updated_at", "rate_limits"])
    let contents = try XCTUnwrap(
        String(data: Data(contentsOf: usageFile), encoding: .utf8)
    )
    XCTAssertFalse(contents.contains("do-not-copy"))
    XCTAssertEqual(try permissions(of: directory), 0o700)
    XCTAssertEqual(try permissions(of: usageFile), 0o600)
}

func test_exporterSerializesConcurrentWritersAndRejectsOlderWindow() throws {
    try runExporter(input: newerFixture, directory: directory)
    try runConcurrently([olderFixture, newestFixture], directory: directory)
    try runExporter(input: newestFixture, directory: directory)

    let result = try decodedUsageFile()

    XCTAssertEqual(result.fiveHour.usedPercentage, 55)
    XCTAssertEqual(result.fiveHour.resetsAt, 1_785_400_000)
    XCTAssertTrue(try temporaryExporterFiles(in: directory).isEmpty)
}

func test_exporterPreservesUpdatedAtForUnchangedRateLimits() throws {
    try runExporter(input: completeFixture, directory: directory)
    let first = try decodedUsageFile()
    sleep(1)
    try runExporter(input: completeFixture, directory: directory)
    let second = try decodedUsageFile()

    XCTAssertEqual(second.updatedAt, first.updatedAt)
}

func test_exporterMergesIndependentlyPresentWindows() throws {
    try runExporter(input: fiveHourOnlyFixture, directory: directory)
    try runExporter(input: sevenDayOnlyFixture, directory: directory)

    XCTAssertEqual(try decodedUsageFile().rateLimits.count, 2)
}

    private var completeFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785300000},"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var fiveHourOnlyFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785300000}}}"#
    }

    private var sevenDayOnlyFixture: String {
        #"{"rate_limits":{"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var newerFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1785400000},"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var olderFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1785300000}}}"#
    }

    private var newestFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":1785400000}}}"#
    }

    private var exporterURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/claude-usage-export.sh")
    }

    private func makeExporter(input: String, directory: URL) -> (Process, Pipe) {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [exporterURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CLIMETER_USAGE_DIR": directory.path],
            uniquingKeysWith: { _, override in override }
        )
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try! stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try! stdin.fileHandleForWriting.close()
        return (process, stdin)
    }

    private func runExporter(input: String, directory: URL) throws {
        let (process, _) = makeExporter(input: input, directory: directory)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func runConcurrently(_ inputs: [String], directory: URL) throws {
        let processes = inputs.map { makeExporter(input: $0, directory: directory).0 }
        try processes.forEach { try $0.run() }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
    }

    private func permissions(of url: URL) throws -> Int {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        ) & 0o777
    }

    private func temporaryExporterFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(".tmp.") ||
                $0.lastPathComponent.contains(".candidate.") ||
                $0.lastPathComponent.contains(".old.")
        }
    }

    private func decodedUsageFile() throws -> ExportedUsageFile {
        try JSONDecoder().decode(ExportedUsageFile.self, from: Data(contentsOf: usageFile))
    }
}

private struct ExportedUsageFile: Decodable {
    let updatedAt: Int
    let rateLimits: [String: ExportedWindow]

    var fiveHour: ExportedWindow { rateLimits["five_hour"]! }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case rateLimits = "rate_limits"
    }
}

private struct ExportedWindow: Decodable {
    let usedPercentage: Double
    let resetsAt: Int?

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}
```

The production mutations caught are: copying the full stdin object, losing lock serialization, refreshing timestamps on UI-only renders, and requiring both windows in one response.

- [ ] **Step 2: Run the exporter tests and confirm RED**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClaudeUsageExporterTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: tests fail because `scripts/claude-usage-export.sh` is absent.

- [ ] **Step 3: Implement the exporter**

Implement this two-mode script:

```bash
#!/bin/bash

publish_locked() {
    candidate_file=$1
    usage_file=$2
    old_file=$(mktemp "${usage_file}.old.XXXXXX") || return 0
    output_file=
    trap 'rm -f "$old_file" "$output_file"' EXIT INT TERM
    output_file=$(mktemp "${usage_file}.tmp.XXXXXX") || return 0

    if [ -s "$usage_file" ] &&
        jq -e '.schema_version == 1 and (.rate_limits | type == "object")' \
            "$usage_file" >/dev/null 2>&1; then
        cp "$usage_file" "$old_file" || return 0
    else
        printf '%s\n' '{"schema_version":1,"updated_at":0,"rate_limits":{}}' \
            > "$old_file"
    fi

    now=$(date +%s)
    jq -n --argjson now "$now" \
      --slurpfile incoming "$candidate_file" \
      --slurpfile existing "$old_file" '
        def merge_window($old; $new):
          if $new == null then $old
          elif $old == null then $new
          elif (($old.resets_at // null) != null and
                ($new.resets_at // null) != null) then
            if $new.resets_at < $old.resets_at then $old
            elif $new.resets_at > $old.resets_at then $new
            else {
              used_percentage: ([$old.used_percentage, $new.used_percentage] | max),
              resets_at: $old.resets_at
            }
            end
          else {
            used_percentage: ([$old.used_percentage, $new.used_percentage] | max),
            resets_at: ($old.resets_at // $new.resets_at // null)
          }
          end;

        ($existing[0]) as $old |
        ($incoming[0]) as $new |
        ($old.rate_limits // {}) as $old_rates |
        {
          five_hour: merge_window(
            ($old_rates.five_hour // null),
            ($new.rate_limits.five_hour // null)
          ),
          seven_day: merge_window(
            ($old_rates.seven_day // null),
            ($new.rate_limits.seven_day // null)
          )
        } |
        with_entries(select(.value != null)) as $merged |
        {
          schema_version: 1,
          updated_at: (
            if $merged == $old_rates then ($old.updated_at // $now)
            else $now
            end
          ),
          rate_limits: $merged
        }
      ' > "$output_file" || return 0
    chmod 0600 "$output_file" || return 0
    mv -f "$output_file" "$usage_file"
}

if [ "${1:-}" = "--publish-locked" ]; then
    publish_locked "$2" "$3"
    exit 0
fi

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

usage_dir=${CLIMETER_USAGE_DIR:-"$HOME/Library/Application Support/Climeter"}
usage_file="$usage_dir/claude-usage.json"
lock_file="$usage_dir/claude-usage.lock"
umask 077
mkdir -p "$usage_dir" || exit 0
chmod 0700 "$usage_dir" || exit 0
: >> "$lock_file" || exit 0
chmod 0600 "$lock_file" || exit 0

candidate_file=$(mktemp "$usage_dir/.claude-usage.candidate.XXXXXX") || exit 0
trap 'rm -f "$candidate_file"' EXIT INT TERM
printf '%s' "$input" | jq -e -c '
  def valid_window($window):
    if ($window | type) != "object" then false
    else
      ($window.used_percentage | type) == "number" and
      $window.used_percentage >= 0 and
      $window.used_percentage <= 100 and
      (
        ($window | has("resets_at") | not) or
        $window.resets_at == null or
        ($window.resets_at | type) == "number"
      )
    end;

  {
    schema_version: 1,
    updated_at: (now | floor),
    rate_limits: (
      {}
      + (
        if valid_window(.rate_limits.five_hour) then {
          five_hour: {
            used_percentage: .rate_limits.five_hour.used_percentage,
            resets_at: (.rate_limits.five_hour.resets_at // null)
          }
        } else {} end
      )
      + (
        if valid_window(.rate_limits.seven_day) then {
          seven_day: {
            used_percentage: .rate_limits.seven_day.used_percentage,
            resets_at: (.rate_limits.seven_day.resets_at // null)
          }
        } else {} end
      )
    )
  }
  | select(.rate_limits | length > 0)
' > "$candidate_file" || exit 0
chmod 0600 "$candidate_file" || exit 0

script_path=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
/usr/bin/lockf -k -t 1 "$lock_file" \
    /bin/bash "$script_path" --publish-locked "$candidate_file" "$usage_file" \
    >/dev/null 2>&1
exit 0
```

Missing `jq`, invalid JSON, no usable rate-limit window, lock timeout, or write failure exits zero without printing stdout and leaves the last aggregate untouched. Register `EXIT INT TERM` cleanup for every temporary file.

- [ ] **Step 4: Run the focused exporter tests and confirm GREEN**

Run the command from Step 2. Expected: all exporter tests pass, including the real concurrent process test.

- [ ] **Step 5: Commit the exporter**

```bash
git add scripts/claude-usage-export.sh \
  ClimeterTests/ClaudeUsageExporterTests.swift \
  Climeter.xcodeproj/project.pbxproj
git commit -m "feat: export sanitized Claude rate limits"
```

---

### Task 3: Route ProfileManager Away From Keychain by Default

**Files:**
- Create: `Climeter/ClaudeUsageSource.swift`
- Create: `ClimeterTests/ProfileManagerStatusLineSourceTests.swift`
- Modify: `Climeter/ProfileStore.swift`
- Modify: `Climeter/ProfileManager.swift`
- Modify: `Climeter/PowerStateMonitor.swift`
- Modify: `Climeter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ClaudeStatusLineUsageStore`.
- Produces: persisted `ClaudeUsageSource`, injected `ProfileManagerDependencies`, and source-aware lifecycle routing.

- [ ] **Step 1: Add failing source and zero-Keychain tests**

Use a disposable `UserDefaults` suite, temporary usage file, and injected power monitor:

```swift
final class ProfileManagerStatusLineSourceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var usageFile: URL!

    override func setUpWithError() throws {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        ProfileStore.saveCodexEnabled(false)
        ProfileStore.saveClaudeEnabled(true)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        usageFile = temporaryDirectory.appendingPathComponent("claude-usage.json")
        try Data(#"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785300000},"seven_day":{"used_percentage":41.2,"resets_at":1785800000}}}"#.utf8)
            .write(to: usageFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }

    func test_statusLineFileIsDefaultSource() {
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(), .statusLineFile)
    }

    func test_statusLineLaunchWakePollingAndRefreshNeverCallClaudeKeychain() {
        var keychainCalls = 0
        let power = TestPowerStateMonitor()
        let manager = ProfileManager(dependencies: dependencies(
            power: power,
            readCLICredential: { _ in keychainCalls += 1; return nil },
            keychainItemExists: { keychainCalls += 1; return false },
            readMigrationCredential: { _ in keychainCalls += 1; return nil },
            moveLegacyCredentialFile: { _, _ in keychainCalls += 1 }
        ))

        manager.refresh()
        power.onScreenUnlocked?()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        XCTAssertEqual(keychainCalls, 0)
    }

    func test_freshStatusLineProfileOpensAllDisplayGates() throws {
        let manager = ProfileManager(dependencies: dependencies())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let profileID = try XCTUnwrap(manager.cliActiveProfileID)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertNotNil(manager.cliActiveUsageData)
        XCTAssertTrue(manager.hasAnyAuthenticated)
    }

    func test_keychainCompatibilityReadsOnlyAfterExplicitSelection() {
        var reads = 0
        let manager = ProfileManager(dependencies: dependencies(
            readCLICredential: { _ in reads += 1; return nil }
        ))
        XCTAssertEqual(reads, 0)

        manager.claudeUsageSource = .keychainManual
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))

        XCTAssertGreaterThan(reads, 0)
    }

    private func dependencies(
        power: TestPowerStateMonitor = TestPowerStateMonitor(),
        readCLICredential: @escaping (Bool) -> Credential? = { _ in nil },
        keychainItemExists: @escaping () -> Bool = { false },
        readMigrationCredential: @escaping (UUID) -> Credential? = { _ in nil },
        moveLegacyCredentialFile: @escaping (URL, URL) -> Void = { _, _ in }
    ) -> ProfileManagerDependencies {
        ProfileManagerDependencies(
            readCLICredential: readCLICredential,
            keychainItemExists: keychainItemExists,
            readMigrationCredential: readMigrationCredential,
            moveLegacyCredentialFile: moveLegacyCredentialFile,
            makeStatusLineStore: {
                ClaudeStatusLineUsageStore(fileURL: self.usageFile)
            },
            powerMonitor: power
        )
    }
}

private final class TestPowerStateMonitor: PowerStateMonitoring {
    var isScreenLocked = false
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onScreenUnlocked: (() -> Void)?
    func startMonitoring() {}
    func stopMonitoring() {}
}
```

The tests fail if a future launch, wake, timer, migration, or refresh branch regains automatic access to the Claude Code Keychain item.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ProfileManagerStatusLineSourceTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the source enum and dependency boundary do not exist.

- [ ] **Step 3: Add the source and dependency interfaces**

Implement:

```swift
enum ClaudeUsageSource: String, Codable, CaseIterable, Identifiable {
    case statusLineFile
    case keychainManual

    var id: String { rawValue }
}

protocol PowerStateMonitoring: AnyObject {
    var isScreenLocked: Bool { get }
    var onSleep: (() -> Void)? { get set }
    var onWake: (() -> Void)? { get set }
    var onScreenUnlocked: (() -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

struct ProfileManagerDependencies {
    var readCLICredential: (Bool) -> Credential?
    var keychainItemExists: () -> Bool
    var readMigrationCredential: (UUID) -> Credential?
    var moveLegacyCredentialFile: (URL, URL) -> Void
    var makeStatusLineStore: () -> ClaudeStatusLineUsageStore
    var powerMonitor: any PowerStateMonitoring

    static var live: ProfileManagerDependencies {
        ProfileManagerDependencies(
            readCLICredential: {
                ClaudeCodeSyncService.readCLICredential(interactive: $0)
            },
            keychainItemExists: {
                ClaudeCodeSyncService.keychainItemExists()
            },
            readMigrationCredential: {
                ProfileManager.readOnlyMigrationCredential(for: $0)
            },
            moveLegacyCredentialFile: { source, destination in
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try? FileManager.default.moveItem(at: source, to: destination)
            },
            makeStatusLineStore: {
                ClaudeStatusLineUsageStore()
            },
            powerMonitor: PowerStateMonitor()
        )
    }
}
```

Add `ProfileStore.loadClaudeUsageSource(defaults:)` and `saveClaudeUsageSource(_:defaults:)`, defaulting the parameter to `.standard`.

- [ ] **Step 4: Implement source-aware ProfileManager lifecycle**

`ProfileManager.init(dependencies:defaults:)` loads the source before migration. In `statusLineFile` mode it:

- chooses the valid persisted CLI profile or the first profile and persists its ID;
- unions that ID into `authenticatedProfileIDs` after every recomputation;
- runs only pure profile schema/default migration;
- subscribes the status-line store into `allUsageData`, `allErrors`, `allLastSuccess`, and `allStale`;
- starts/stops/refreshes that store on enable, sleep/wake, and manual refresh;
- never calls the injected Keychain or legacy credential-file closures;
- never creates `UsageRefreshCoordinator`, starts CLI monitoring/backfill, auto-starts a session, or auto-switches accounts.

In `keychainManual` mode, preserve the existing coordinator and migration behavior, routed exclusively through the injected closures. Switching sources tears down the previous provider before starting the selected provider.

- [ ] **Step 5: Run focused and existing ProfileManager tests**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ProfileManagerStatusLineSourceTests \
  -only-testing:ClimeterTests/ProfileManagerMigrationTests \
  -only-testing:ClimeterTests/UsageRefreshCoordinatorReadOnlyTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Commit source routing**

```bash
git add Climeter/ClaudeUsageSource.swift Climeter/ProfileStore.swift \
  Climeter/ProfileManager.swift Climeter/PowerStateMonitor.swift \
  ClimeterTests/ProfileManagerStatusLineSourceTests.swift \
  Climeter.xcodeproj/project.pbxproj
git commit -m "feat: default Claude usage to password-free file"
```

---

### Task 4: Expose the Source and Honest Status in SwiftUI

**Files:**
- Modify: `Climeter/SettingsView.swift`
- Modify: `Climeter/PopoverView.swift`
- Modify: `Climeter/ClimeterApp.swift`
- Modify: `ClimeterTests/ClimeterTests.swift`

**Interfaces:**
- Consumes: `ProfileManager.claudeUsageSource` and its file-backed profile state.
- Produces: source picker, compatibility warning, disabled auto-switch, initialization/schema messages, and source-aware stale presentation.

- [ ] **Step 1: Add failing presentation tests**

Add behavior tests:

```swift
func test_statusLineSourceUsesWaitingPresentationRegardlessOfCredentialSource() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(
        ClaudeStalePresentation.waitingMessage(
            usageSource: .statusLineFile,
            credentialSource: .selfOwned,
            isStale: false,
            lastSuccessAt: now.addingTimeInterval(-601),
            currentTime: now
        ),
        "Updated 10m ago — waiting for Claude Code"
    )
}

func test_manualSelfOwnedSourcePreservesExistingNonWaitingPresentation() {
    XCTAssertNil(ClaudeStalePresentation.waitingMessage(
        usageSource: .keychainManual,
        credentialSource: .selfOwned,
        isStale: true,
        lastSuccessAt: Date(timeIntervalSince1970: 1),
        currentTime: Date(timeIntervalSince1970: 1_000)
    ))
}
```

Update the existing rendered-card test to pass `usageSource`.

- [ ] **Step 2: Run the presentation tests and confirm RED**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' \
  -only-testing:ClimeterTests/ClimeterTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because stale presentation is not source-aware.

- [ ] **Step 3: Implement source-aware views**

In Settings, replace the current fixed Keychain label with:

```swift
Picker("Usage source", selection: $profileManager.claudeUsageSource) {
    Text("Claude Code status line — password-free")
        .tag(ClaudeUsageSource.statusLineFile)
    Text("macOS Keychain — may ask for password")
        .tag(ClaudeUsageSource.keychainManual)
}

if profileManager.claudeUsageSource == .keychainManual {
    Text("Compatibility mode may trigger a macOS password prompt.")
        .font(.caption)
        .foregroundColor(.orange)
} else {
    Text("Usage updates after Claude Code responds. No OAuth credential is read.")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

Disable the auto-switch controls in status-line mode and show “Requires Keychain compatibility mode.” Pass `claudeUsageSource` through `ClimeterApp` and `ProfileCard`. Update `ClaudeStalePresentation.isWaiting` so status-line mode always uses the ten-minute waiting semantics while manual `.selfOwned` profiles preserve current behavior. Show `errorMessage` below existing usage rows when a future schema or malformed file is present.

- [ ] **Step 4: Run the focused UI tests and confirm GREEN**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 5: Commit the UI**

```bash
git add Climeter/SettingsView.swift Climeter/PopoverView.swift \
  Climeter/ClimeterApp.swift ClimeterTests/ClimeterTests.swift
git commit -m "feat: expose password-free Claude usage source"
```

---

### Task 5: Install Locally and Verify the Original Symptom

**Files:**
- Modify locally: `~/.config/claude/statusline-simple.sh`
- Install locally: `~/Library/Application Support/Climeter/claude-usage-export.sh`
- Build output: `build/Build/Products/Release/Climeter.app`

**Interfaces:**
- Consumes: repository exporter and completed app.
- Produces: a working local status-line pipeline and verified installed app.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: zero test failures.

- [ ] **Step 2: Build Release**

Run:

```bash
xcodebuild -project Climeter.xcodeproj -scheme Climeter \
  -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Install the exporter and update the existing status line**

Back up the existing script once, install the reviewed exporter with mode `0700`, and add this call immediately after `input=$(cat)` without changing the current visible-output code:

```bash
printf '%s' "$input" |
    "$HOME/Library/Application Support/Climeter/claude-usage-export.sh" \
    >/dev/null 2>&1
```

Use `apply_patch` for the status-line edit. Do not read or copy any credential file.

- [ ] **Step 4: Verify exporter behavior with a credential-canary fixture**

Pipe a fixture containing fake token, transcript, and project fields plus valid rate limits through the installed status-line script. Confirm:

```bash
jq -e '
  keys == ["rate_limits","schema_version","updated_at"] and
  .schema_version == 1 and
  .rate_limits.five_hour.used_percentage == 23.5 and
  .rate_limits.seven_day.used_percentage == 41.2
' "$HOME/Library/Application Support/Climeter/claude-usage.json"
```

Also confirm modes with `stat -f '%Lp %N'`. Expected: directory `700`, usage/exporter/lock files `600` or stricter executable exporter `700`, and no canary string in the usage file.

- [ ] **Step 5: Install and launch the app**

Quit the running Climeter, preserve the current `/Applications/Climeter.app` as a recoverable backup, copy the Release app into `/Applications`, and launch it. These are explicit installation actions within the user's requested app scope.

- [ ] **Step 6: Verify zero Keychain reads and live file consumption**

Record the current end of `~/Library/Logs/Climeter/climeter.log`, then exercise:

1. app launch;
2. manual refresh;
3. one Claude Code response;
4. a sleep/wake-equivalent status store restart if practical.

Assert the new log segment contains no `readCLICredential` or `keychainItemExists` entry, the menu-bar usage changes within five seconds of the status-line file update, and the app displays the file's `updated_at`-based stale state.

- [ ] **Step 7: Run final repository verification and commit any installation documentation**

Run:

```bash
git diff --check
git status --short
xcodebuild test -project Climeter.xcodeproj -scheme Climeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: no whitespace errors, only intended repository changes, and zero test failures.
