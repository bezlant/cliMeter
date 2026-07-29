import XCTest
@testable import Climeter

final class ProfileManagerStatusLineSourceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var usageFile: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        defaultsSuiteName = "ProfileManagerStatusLineSourceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        ProfileStore.saveCodexEnabled(false, defaults: defaults)
        ProfileStore.saveClaudeEnabled(true, defaults: defaults)

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        usageFile = temporaryDirectory.appendingPathComponent("claude-usage.json")
        try writeUsage(fiveHour: 23.5, sevenDay: 41.2)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func test_statusLineFileIsDefaultAndPersistedSource() {
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .statusLineFile)

        ProfileStore.saveClaudeUsageSource(.keychainManual, defaults: defaults)

        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .keychainManual)
    }

    func test_statusLineLifecycleNeverCallsCredentialDependencies() {
        let calls = CredentialCallRecorder()
        let power = TestPowerStateMonitor()
        let manager = ProfileManager(
            dependencies: dependencies(power: power, calls: calls),
            defaults: defaults
        )

        manager.refresh()
        power.onSleep?()
        power.onWake?()
        power.onScreenUnlocked?()
        manager.claudeEnabled = false
        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))

        XCTAssertEqual(calls.total, 0)
    }

    func test_freshStatusLineProfileOpensAllDisplayGates() throws {
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let profileID = try XCTUnwrap(manager.cliActiveProfileID)
        XCTAssertEqual(ProfileStore.loadCLIActiveProfileID(defaults: defaults), profileID)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(manager.cliActiveUsageData?.sevenDay.utilization, 41.2)
        XCTAssertNil(manager.allErrors[profileID] ?? nil)
        XCTAssertEqual(
            manager.allLastSuccess[profileID],
            Date(timeIntervalSince1970: 1_785_290_000)
        )
        XCTAssertEqual(manager.allStale[profileID], true)
        XCTAssertTrue(manager.hasAnyAuthenticated)
    }

    func test_statusLineUsesValidPersistedProfileAndSurvivesAuthenticationRecomputation() throws {
        let first = Profile(name: "First")
        let selected = Profile(name: "Selected")
        ProfileStore.saveProfiles([first, selected], defaults: defaults)
        ProfileStore.saveCLIActiveProfileID(selected.id, defaults: defaults)
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)

        manager.claudeEnabled = false
        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(manager.cliActiveProfileID, selected.id)
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(selected.id))
    }

    func test_injectedDefaultsDoNotReadOrWriteStandardPreferences() throws {
        let standard = UserDefaults.standard
        let keys = [
            "profiles",
            "cliActiveProfileID",
            "claudeEnabled",
            "codexEnabled",
            "claudeUsageSource"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, standard.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = originalValues[key] ?? nil {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }

        let standardProfile = Profile(name: "Standard sentinel")
        ProfileStore.saveProfiles([standardProfile])
        ProfileStore.saveCLIActiveProfileID(standardProfile.id)
        ProfileStore.saveClaudeEnabled(false)
        ProfileStore.saveCodexEnabled(true)
        ProfileStore.saveClaudeUsageSource(.keychainManual)

        let suiteProfile = Profile(name: "Suite profile")
        ProfileStore.saveProfiles([suiteProfile], defaults: defaults)
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        manager.createProfile(name: "Suite second profile")
        manager.claudeEnabled = false
        manager.claudeEnabled = true

        XCTAssertEqual(ProfileStore.loadProfiles().map(\.id), [standardProfile.id])
        XCTAssertEqual(ProfileStore.loadCLIActiveProfileID(), standardProfile.id)
        XCTAssertFalse(ProfileStore.loadClaudeEnabled())
        XCTAssertTrue(ProfileStore.loadCodexEnabled())
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(), .keychainManual)
        XCTAssertEqual(ProfileStore.loadProfiles(defaults: defaults).count, 2)
        XCTAssertEqual(manager.cliActiveProfileID, suiteProfile.id)
    }

    func test_persistedDisabledStatusLineLaunchKeepsFileAuthenticationGateClosed() throws {
        ProfileStore.saveClaudeEnabled(false, defaults: defaults)

        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let profileID = try XCTUnwrap(manager.cliActiveProfileID)
        XCTAssertFalse(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertFalse(manager.hasAnyAuthenticated)
        XCTAssertNil(manager.cliActiveUsageData)
    }

    func test_disablingAndReenablingClaudeClosesAndReopensFileAuthenticationGate() throws {
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let profileID = try XCTUnwrap(manager.cliActiveProfileID)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(profileID))

        manager.claudeEnabled = false

        XCTAssertFalse(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertFalse(manager.hasAnyAuthenticated)

        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertTrue(manager.hasAnyAuthenticated)
    }

    func test_disablingClaudeStopsFileRefreshUntilReenabled() throws {
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)

        manager.claudeEnabled = false
        try writeUsage(fiveHour: 77, sevenDay: 88)
        manager.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertNil(manager.cliActiveUsageData)

        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 77)
        XCTAssertEqual(manager.cliActiveUsageData?.sevenDay.utilization, 88)
    }

    func test_keychainCompatibilityReadsOnlyAfterExplicitSelectionAndTearsDownFileSource() {
        let calls = CredentialCallRecorder()
        let scheduler = ControlledCredentialScheduler()
        let manager = ProfileManager(
            dependencies: dependencies(calls: calls, scheduler: scheduler),
            defaults: defaults
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls.total, 0)
        XCTAssertNotNil(manager.cliActiveUsageData)

        manager.claudeUsageSource = .keychainManual
        scheduler.runDelayed(at: 0)
        scheduler.runCredentialWork(at: 0)

        XCTAssertGreaterThan(calls.total, 0)
        XCTAssertGreaterThan(calls.cliReads, 0)
        XCTAssertNil(manager.cliActiveUsageData)
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .keychainManual)
    }

    func test_keychainToStatusTransitionCancelsAndInvalidatesOldDelayedRead() throws {
        let calls = CredentialCallRecorder()
        let scheduler = ControlledCredentialScheduler()
        ProfileStore.saveClaudeUsageSource(.keychainManual, defaults: defaults)
        let manager = ProfileManager(
            dependencies: dependencies(calls: calls, scheduler: scheduler),
            defaults: defaults
        )
        XCTAssertEqual(scheduler.delayed.count, 1)

        manager.claudeUsageSource = .statusLineFile
        XCTAssertTrue(try XCTUnwrap(scheduler.delayed.first).isCancelled)

        scheduler.runDelayed(at: 0)

        XCTAssertTrue(scheduler.credentialWork.isEmpty)
        XCTAssertEqual(calls.cliReads, 0)
    }

    func test_rapidSourceTransitionsOnlyAllowNewestKeychainGenerationToRead() throws {
        let calls = CredentialCallRecorder()
        let scheduler = ControlledCredentialScheduler()
        ProfileStore.saveClaudeUsageSource(.keychainManual, defaults: defaults)
        let manager = ProfileManager(
            dependencies: dependencies(calls: calls, scheduler: scheduler),
            defaults: defaults
        )

        manager.claudeUsageSource = .statusLineFile
        manager.claudeUsageSource = .keychainManual
        XCTAssertEqual(scheduler.delayed.count, 2)
        XCTAssertTrue(scheduler.delayed[0].isCancelled)
        XCTAssertFalse(scheduler.delayed[1].isCancelled)

        scheduler.runDelayed(at: 0)
        scheduler.runDelayed(at: 0)
        XCTAssertTrue(scheduler.credentialWork.isEmpty)
        XCTAssertEqual(calls.cliReads, 0)

        scheduler.runDelayed(at: 1)
        XCTAssertEqual(scheduler.credentialWork.count, 1)
        scheduler.runCredentialWork(at: 0)

        XCTAssertEqual(calls.cliReads, 1)
    }

    func test_providerGenerationMakesReadAuthorizationAtomicWithInvalidation() {
        let providerGeneration = ProviderGeneration()
        let generation = providerGeneration.advance()
        let atAuthorizationBoundary = DispatchSemaphore(value: 0)
        let allowReadInitiation = DispatchSemaphore(value: 0)
        let invalidationAttempted = DispatchSemaphore(value: 0)
        let readInitiated = DispatchSemaphore(value: 0)
        let authorizedWorkFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        let events = ConcurrentEventRecorder()

        DispatchQueue.global(qos: .userInitiated).async {
            let authorized = providerGeneration.perform(ifCurrent: generation) {
                events.record("authorized")
                atAuthorizationBoundary.signal()
                _ = allowReadInitiation.wait(timeout: .now() + 2)
                events.record("read initiated")
                readInitiated.signal()
            }
            if authorized {
                authorizedWorkFinished.signal()
            }
        }

        XCTAssertEqual(
            atAuthorizationBoundary.wait(timeout: .now() + 2),
            .success
        )

        DispatchQueue.global(qos: .userInitiated).async {
            invalidationAttempted.signal()
            _ = providerGeneration.advance()
            events.record("invalidation finished")
            invalidationFinished.signal()
        }

        XCTAssertEqual(invalidationAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            invalidationFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "Invalidation must not complete between authorization and read initiation"
        )

        allowReadInitiation.signal()

        XCTAssertEqual(readInitiated.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(authorizedWorkFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            events.values,
            ["authorized", "read initiated", "invalidation finished"]
        )

        var staleReadInitiated = false
        let staleGenerationAuthorized = providerGeneration.perform(ifCurrent: generation) {
            staleReadInitiated = true
        }
        XCTAssertFalse(staleGenerationAuthorized)
        XCTAssertFalse(staleReadInitiated)
    }

    private func writeUsage(fiveHour: Double, sevenDay: Double) throws {
        let json = """
        {"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":\(fiveHour),"resets_at":1785300000},"seven_day":{"used_percentage":\(sevenDay),"resets_at":1785800000}}}
        """
        try Data(json.utf8).write(to: usageFile, options: .atomic)
    }

    private func dependencies(
        power: TestPowerStateMonitor = TestPowerStateMonitor(),
        calls: CredentialCallRecorder = CredentialCallRecorder(),
        scheduler: ControlledCredentialScheduler = ControlledCredentialScheduler()
    ) -> ProfileManagerDependencies {
        ProfileManagerDependencies(
            readCLICredential: { _ in
                calls.recordCLIRead()
                return nil
            },
            keychainItemExists: {
                calls.recordKeychainExistenceCheck()
                return false
            },
            readMigrationCredential: { _ in
                calls.recordMigrationRead()
                return nil
            },
            moveLegacyCredentialFile: { _, _ in
                calls.recordFileMove()
            },
            makeStatusLineStore: {
                ClaudeStatusLineUsageStore(fileURL: self.usageFile)
            },
            powerMonitor: power,
            scheduleCLIDetection: scheduler.scheduleDelayed,
            performCredentialWork: scheduler.scheduleCredentialWork
        )
    }
}

private final class ConcurrentEventRecorder {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: String) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private final class CredentialCallRecorder {
    private let lock = NSLock()
    private var recordedCLIReads = 0
    private var recordedKeychainExistenceChecks = 0
    private var recordedMigrationReads = 0
    private var recordedFileMoves = 0

    var cliReads: Int {
        withLock { recordedCLIReads }
    }

    var total: Int {
        withLock {
            recordedCLIReads
                + recordedKeychainExistenceChecks
                + recordedMigrationReads
                + recordedFileMoves
        }
    }

    func recordCLIRead() {
        withLock { recordedCLIReads += 1 }
    }

    func recordKeychainExistenceCheck() {
        withLock { recordedKeychainExistenceChecks += 1 }
    }

    func recordMigrationRead() {
        withLock { recordedMigrationReads += 1 }
    }

    func recordFileMove() {
        withLock { recordedFileMoves += 1 }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
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

private final class ControlledCredentialScheduler {
    final class ScheduledOperation {
        let operation: () -> Void
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        init(operation: @escaping () -> Void) {
            self.operation = operation
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private(set) var delayed: [ScheduledOperation] = []
    private(set) var credentialWork: [ScheduledOperation] = []

    func scheduleDelayed(_ operation: @escaping () -> Void) -> () -> Void {
        let scheduled = ScheduledOperation(operation: operation)
        delayed.append(scheduled)
        return scheduled.cancel
    }

    func scheduleCredentialWork(_ operation: @escaping () -> Void) -> () -> Void {
        let scheduled = ScheduledOperation(operation: operation)
        credentialWork.append(scheduled)
        return scheduled.cancel
    }

    func runDelayed(at index: Int) {
        delayed[index].operation()
    }

    func runCredentialWork(at index: Int) {
        credentialWork[index].operation()
    }
}
